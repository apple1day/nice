package com.anxiong.nicevideos;

import android.net.Uri;
import android.os.Handler;
import android.os.Looper;

import java.io.IOException;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Keeps a single export running across configuration changes without retaining the activity. */
final class MovieExportTask {
    private final MovieExporter exporter;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());
    private Runnable listener;
    private boolean running;
    private String status = "";

    MovieExportTask(VideoLibrary library) { exporter = new MovieExporter(library); }

    // UI state and the listener are accessed only on the main thread.
    void listen(Runnable listener) { this.listener = listener; }
    boolean running() { return running; }
    String status() { return status; }
    void clearStatus() { if (!running) status = ""; }

    private void show(String message) {
        status = message;
        if (listener != null) listener.run();
    }

    void start(List<VideoLibrary.Entry> selection, Uri tree) {
        if (running || selection.isEmpty()) return;
        running = true;
        show("正在导出 1/" + selection.size() + "：" + selection.get(0).name);
        worker.execute(() -> copy(selection, tree));
    }

    private void copy(List<VideoLibrary.Entry> selection, Uri tree) {
        int copied = 0, existing = 0, failed = 0;
        String firstError = "", actualName = "";
        for (int i = 0; i < selection.size(); i++) {
            if (Thread.currentThread().isInterrupted()) return;
            VideoLibrary.Entry entry = selection.get(i);
            if (i > 0) {
                String progress = "正在导出 " + (i + 1) + "/" + selection.size() + "：" + entry.name;
                main.post(() -> show(progress));
            }
            try {
                MovieExporter.Result result = exporter.export(entry.id, tree);
                actualName = result.name;
                if (result.existing) existing++;
                else copied++;
            } catch (IOException | RuntimeException e) {
                failed++;
                if (firstError.isEmpty())
                    firstError = entry.name + " · " + (e.getLocalizedMessage() == null ? "文件读写失败" : e.getLocalizedMessage());
            }
        }
        String summary = selection.size() == 1 && failed == 0
                ? (existing > 0 ? "所选文件夹中已有相同视频：" : "已导出到所选文件夹：") + actualName
                : "已导出 " + copied + " 部，已有相同文件 " + existing + " 部"
                    + (failed == 0 ? "" : "，失败 " + failed + " 部。 " + firstError);
        main.post(() -> { running = false; show(summary); });
    }

    void close() {
        worker.shutdownNow();
        main.removeCallbacksAndMessages(null);
    }
}
