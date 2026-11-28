package com.anxiong.nicevideos;

import android.os.ParcelFileDescriptor;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;

import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.function.BooleanSupplier;

/** Deletes server originals only when this installation still has the corresponding offline copy. */
final class DownloadedServerDeletion {
    private static final class Candidate {
        final ServerVideos.Movie movie;
        final String id, disk, publicUri;
        final boolean publicDownload, restoredPrivate;
        final long job;

        Candidate(ServerVideos.Movie movie, VideoLibrary.Entry record) {
            this.movie = movie;
            id = record.id;
            job = record.job;
            disk = record.disk;
            publicUri = record.publicUri;
            publicDownload = record.publicDownload;
            restoredPrivate = record.restoredPrivate;
        }

        boolean sameAttempt(VideoLibrary.Entry record) {
            return matches(movie, record) && record.job == job && record.disk.equals(disk)
                    && record.publicUri.equals(publicUri) && record.publicDownload == publicDownload
                    && record.restoredPrivate == restoredPrivate;
        }
    }

    static final class Plan {
        final String server;
        private final List<Candidate> candidates = new ArrayList<>();
        Plan(String server) { this.server = server; }
        int size() { return candidates.size(); }
    }

    static final class Result {
        int deleted, skipped, failed;
        private String reason = "";

        String summary() {
            return "已删除服务器视频 " + deleted + " 部，跳过 " + skipped + " 部，失败 " + failed
                    + " 部。本机下载保留。" + (reason.isEmpty() ? "" : "\n" + reason);
        }
    }

    private static boolean matches(ServerVideos.Movie movie, VideoLibrary.Entry record) {
        return movie != null && !movie.direct && movie.supportsOffline()
                && DownloadedVideoDeletion.eligible(record) && !record.direct
                && movie.url.equals(record.source) && movie.name.equals(record.name) && movie.bytes == record.bytes;
    }

    // Computing the button state is metadata-only. Open files only after the user starts a batch.
    static Plan plan(String base, List<ServerVideos.Movie> catalog, List<VideoLibrary.Entry> records) {
        String server;
        try { server = ServerVideos.address(base); }
        catch (IOException ex) { return new Plan(""); }
        Plan plan = new Plan(server);
        Map<String, ServerVideos.Movie> bySource = new HashMap<>();
        for (ServerVideos.Movie movie : catalog) {
            if (movie.url.equals(ServerVideos.downloadEndpoint(server, movie.name))) bySource.put(movie.url, movie);
        }
        for (VideoLibrary.Entry record : records) {
            ServerVideos.Movie movie = bySource.get(record.source);
            if (matches(movie, record)) {
                plan.candidates.add(new Candidate(movie, record));
                bySource.remove(movie.url); // At most one DELETE per server filename.
            }
        }
        return plan;
    }

    private static boolean hasLocalCopy(VideoLibrary library, Candidate item) {
        try {
            VideoLibrary.Entry current = library.find(item.id);
            if (!item.sameAttempt(current) || !library.atRecordedLocation(current)) return false;
            try (ParcelFileDescriptor fd = library.openMovie(current)) {
                return OsConstants.S_ISREG(Os.fstat(fd.getFileDescriptor()).st_mode)
                        && fd.getStatSize() == item.movie.bytes
                        && !VideoLibrary.invalidVideoPayload(fd, item.movie.contentType)
                        && item.sameAttempt(library.find(item.id));
            }
        } catch (IOException | ErrnoException | RuntimeException ex) {
            return false;
        }
    }

    private static boolean active(BooleanSupplier stillCurrent) {
        return !Thread.currentThread().isInterrupted() && stillCurrent.getAsBoolean();
    }

    /** Run on a worker thread. No library lock is held while waiting on the server. */
    static Result run(Plan plan, VideoLibrary library, BooleanSupplier stillCurrent) {
        Result result = new Result();
        if (plan.size() == 0 || !active(stillCurrent)) {
            result.skipped = plan.size();
            return result;
        }
        Map<String, ServerVideos.Movie> currentCatalog = new HashMap<>();
        try {
            for (ServerVideos.Movie movie : ServerVideos.list(plan.server)) currentCatalog.put(movie.url, movie);
        } catch (IOException | RuntimeException ex) {
            result.failed = plan.size();
            result.reason = "无法核对当前服务器片单：" + ex.getLocalizedMessage();
            return result;
        }
        for (int i = 0; i < plan.size(); i++) {
            Candidate item = plan.candidates.get(i);
            if (!active(stillCurrent)) {
                result.skipped += plan.size() - i;
                break;
            }
            ServerVideos.Movie remote = currentCatalog.get(item.movie.url);
            if (remote == null || !remote.supportsOffline() || remote.bytes != item.movie.bytes
                    || !hasLocalCopy(library, item) || !active(stillCurrent)) {
                result.skipped++;
                continue;
            }
            try {
                ServerVideos.delete(plan.server, remote);
                result.deleted++;
            } catch (IOException | RuntimeException ex) {
                result.failed++;
                if (result.reason.isEmpty()) result.reason = remote.name + "：" + ex.getLocalizedMessage();
            }
        }
        return result;
    }
}
