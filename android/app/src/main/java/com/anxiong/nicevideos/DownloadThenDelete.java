package com.anxiong.nicevideos;

import java.io.IOException;
import java.util.Collections;
import java.util.List;
import java.util.function.BooleanSupplier;

/** Serial move: commit a verified offline copy before issuing a single remote DELETE. */
final class DownloadThenDelete {
    interface Progress { void changed(String message, boolean refreshCatalog); }
    private final VideoLibrary library;

    DownloadThenDelete(VideoLibrary library) { this.library = library; }

    private static boolean active(BooleanSupplier current) {
        return !Thread.currentThread().isInterrupted() && current.getAsBoolean();
    }

    private VideoLibrary.Entry find(ServerVideos.Movie movie) {
        for (VideoLibrary.Entry e : library.all()) {
            if (!e.direct && e.downloaded() && movie.url.equals(e.source)
                    && movie.name.equals(e.name) && movie.bytes == e.bytes) return e;
        }
        return null;
    }

    private VideoLibrary.Entry awaitCopy(ServerVideos.Movie movie, BooleanSupplier current,
                                         Progress progress, String prefix) throws IOException, InterruptedException {
        if (!active(current)) return null;
        VideoLibrary.Entry entry = find(movie);
        if (entry == null || VideoLibrary.FAILED.equals(entry.state)
                || library.missingPublicFile(entry)) {
            library.enqueue(movie, entry);
            entry = find(movie);
        }
        if (entry == null) throw new IOException("未找到下载任务");
        final String id = entry.id;
        final long job = entry.job;
        while (active(current)) {
            entry = library.find(id);
            if (entry == null || entry.job != job) throw new IOException("下载任务已变更");
            if (VideoLibrary.READY.equals(entry.state)) return entry;
            if (VideoLibrary.FAILED.equals(entry.state)) throw new IOException(entry.error);
            if (!VideoLibrary.TRANSFER.equals(entry.state)) throw new IOException("未知下载状态");
            VideoLibrary.Transfer transfer = library.check(entry);
            if (!VideoLibrary.TRANSFER.equals(transfer.state)) {
                synchronized (VideoLibrary.class) {
                    VideoLibrary.Entry latest = library.find(id);
                    if (latest == null || latest.job != job) throw new IOException("下载任务已变更");
                    if (VideoLibrary.TRANSFER.equals(latest.state)) {
                        latest.state = transfer.state;
                        latest.error = VideoLibrary.FAILED.equals(transfer.state) ? transfer.label : "";
                        if (VideoLibrary.READY.equals(transfer.state)) {
                            latest.bytes = transfer.bytes;
                            if (!transfer.publicUri.isEmpty()) latest.publicUri = transfer.publicUri;
                            if (!transfer.disk.isEmpty()) latest.disk = transfer.disk;
                        }
                        if (!library.saveCommitted(latest)) throw new IOException("无法持久化下载记录");
                    }
                }
                continue;
            }
            progress.changed(prefix + " · " + transfer.label + " · "
                    + android.text.format.Formatter.formatFileSize(library.context, transfer.bytes)
                    + " / " + android.text.format.Formatter.formatFileSize(library.context, movie.bytes), false);
            Thread.sleep(1000);
        }
        return null;
    }

    String run(String base, List<ServerVideos.Movie> movies, BooleanSupplier current, Progress progress) {
        int deleted = 0, skipped = 0, failed = 0;
        String firstError = "";
        for (int i = 0; i < movies.size(); i++) {
            if (!active(current)) break;
            ServerVideos.Movie movie = movies.get(i);
            String prefix = (i + 1) + "/" + movies.size() + " · 已删除 " + deleted + " 部 · " + movie.name;
            if (!movie.supportsOffline() || movie.direct
                    || !movie.url.equals(ServerVideos.downloadEndpoint(base, movie.name))) { skipped++; continue; }
            try {
                progress.changed(prefix + " · 正在准备下载", false);
                VideoLibrary.Entry copy = awaitCopy(movie, current, progress, prefix);
                if (copy == null || !active(current)) break;
                progress.changed(prefix + " · 正在核验并删除远端原片", false);
                DownloadedServerDeletion.Plan plan = DownloadedServerDeletion.plan(base,
                        Collections.singletonList(movie), Collections.singletonList(copy));
                if (plan.size() != 1) { skipped++; continue; }
                DownloadedServerDeletion.Result result = DownloadedServerDeletion.run(plan, library, current);
                deleted += result.deleted;
                skipped += result.skipped;
                failed += result.failed;
                if (result.failed > 0 && firstError.isEmpty()) firstError = movie.name + "：远端删除失败";
                progress.changed("已删除 " + deleted + " 部，跳过 " + skipped + " 部，失败 " + failed + " 部。", result.deleted > 0);
            } catch (InterruptedException ex) {
                Thread.currentThread().interrupt();
                break;
            } catch (IOException | RuntimeException ex) {
                failed++;
                if (firstError.isEmpty()) firstError = movie.name + "：" + ex.getLocalizedMessage();
            }
        }
        return (active(current) ? "处理完成" : "已停止") + " · 已删除远程视频 " + deleted + " 部，跳过 "
                + skipped + " 部，失败 " + failed + " 部。本机副本保留。"
                + (firstError.isEmpty() ? "" : "\n" + firstError);
    }
}
