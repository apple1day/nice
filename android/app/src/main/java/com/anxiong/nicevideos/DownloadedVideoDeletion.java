package com.anxiong.nicevideos;

import android.os.Handler;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.system.ErrnoException;
import android.system.Os;
import android.system.StructStat;

import java.io.FileNotFoundException;
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Deletes the files the user confirmed, even when downloads complete or get retried meanwhile. */
final class DownloadedVideoDeletion {
    static final class Copy {
        final VideoLibrary.Entry entry;
        final StructStat file;

        Copy(VideoLibrary.Entry entry, StructStat file) { this.entry = entry; this.file = file; }

        boolean matches(Copy other) {
            if (other == null) return false;
            VideoLibrary.Entry e = other.entry;
            return entry.job == e.job && entry.publicDownload == e.publicDownload
                    && entry.restoredPrivate == e.restoredPrivate && entry.disk.equals(e.disk)
                    && entry.publicUri.equals(e.publicUri) && entry.source.equals(e.source)
                    && file.st_dev == other.file.st_dev && file.st_ino == other.file.st_ino
                    && file.st_size == other.file.st_size && file.st_mtime == other.file.st_mtime;
        }
    }

    static final class Plan {
        final List<Copy> copies = new ArrayList<>();
        int unavailable;
    }

    private final VideoLibrary library;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private Runnable listener;
    private boolean running;
    private String status = "";

    DownloadedVideoDeletion(VideoLibrary library) { this.library = library; }
    void listen(Runnable listener) { this.listener = listener; }
    boolean running() { return running; }
    String status() { return status; }
    void clearStatus() { if (!running) status = ""; }
    void close() { worker.shutdown(); } // A confirmed batch can finish after the screen closes.

    static boolean eligible(VideoLibrary.Entry e) {
        return e != null && e.downloaded() && e.document.isEmpty() && VideoLibrary.READY.equals(e.state);
    }

    private Copy inspect(VideoLibrary.Entry e) throws IOException {
        if (!eligible(e) || !library.atRecordedLocation(e)) return null;
        try (ParcelFileDescriptor fd = library.openMovie(e)) {
            return new Copy(e, Os.fstat(fd.getFileDescriptor()));
        } catch (FileNotFoundException missing) {
            return null;
        } catch (ErrnoException unavailable) {
            throw new IOException("无法核对本机文件。", unavailable);
        }
    }

    Plan prepare() {
        Plan plan = new Plan();
        for (VideoLibrary.Entry e : library.all()) {
            try {
                Copy copy = inspect(e);
                if (copy != null) plan.copies.add(copy);
            } catch (IOException | RuntimeException ex) { plan.unavailable++; }
        }
        return plan;
    }

    private void show(String text) {
        status = text;
        if (listener != null) listener.run();
    }

    void start(Plan plan) {
        if (running || plan.copies.isEmpty()) return;
        running = true;
        show("正在删除 " + plan.copies.size() + " 部已下载视频…");
        worker.execute(() -> {
            int deleted = 0, changed = 0, failed = 0;
            String firstError = "";
            for (Copy confirmed : plan.copies) {
                try {
                    synchronized (VideoLibrary.class) {
                        VideoLibrary.Entry latest = library.find(confirmed.entry.id);
                        if (!confirmed.matches(inspect(latest))) { changed++; continue; }
                        library.remove(latest);
                        deleted++;
                    }
                } catch (IOException | RuntimeException ex) {
                    failed++;
                    if (firstError.isEmpty()) firstError = confirmed.entry.name;
                }
            }
            String summary = "已删除 " + deleted + " 部已下载视频"
                    + (changed == 0 ? "" : "，跳过已变更的 " + changed + " 部")
                    + (failed == 0 ? "" : "，删除失败 " + failed + " 部（" + firstError + "）");
            main.post(() -> { running = false; show(summary); });
        });
    }
}
