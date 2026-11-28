package com.anxiong.nicevideos;

import android.os.Handler;
import android.os.Looper;
import java.io.IOException;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.function.BooleanSupplier;
import java.util.function.Function;

/** Retains an explicit server action across rotation, pinned to its original address. */
final class ServerBatchTask {
    interface Listener { void changed(boolean refreshCatalog); }
    private final VideoLibrary library;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());
    private volatile int generation;
    private boolean running;
    private String server = "", status = "";
    private Listener listener;

    ServerBatchTask(VideoLibrary library) { this.library = library; }
    void listen(Listener listener) { this.listener = listener; }
    boolean running() { return running; }
    String status(String base) { return server.equals(base) ? status : ""; }

    void serverChanged() {
        generation++;
        running = false;
        status = "";
    }

    void download(String base, List<ServerVideos.Movie> movies) {
        start(base, "正在加入下载队列…", false, current -> {
            int queued = 0, skipped = 0, failed = 0;
            String firstError = "";
            for (ServerVideos.Movie movie : movies) {
                if (!current.getAsBoolean()) break;
                try {
                    if (movie.supportsOffline() && library.enqueue(movie, null)) queued++;
                    else skipped++;
                } catch (IOException | RuntimeException ex) {
                    failed++;
                    if (firstError.isEmpty()) firstError = movie.name + " · " + ex.getLocalizedMessage();
                }
            }
            return "已加入下载队列 " + queued + " 部，跳过 " + skipped + " 部，失败 " + failed + " 部。"
                    + (firstError.isEmpty() ? "" : "\n" + firstError);
        });
    }

    void delete(String base, DownloadedServerDeletion.Plan plan) {
        start(base, "正在删除服务器原片…", true,
                current -> DownloadedServerDeletion.run(plan, library, current).summary());
    }

    private void start(String base, String message, boolean refresh, Function<BooleanSupplier, String> action) {
        if (running || !base.equals(library.serverAddress())) return;
        int ticket = ++generation;
        running = true;
        server = base;
        status = message;
        if (listener != null) listener.changed(false);
        worker.execute(() -> {
            BooleanSupplier current = () -> generation == ticket && base.equals(library.serverAddress());
            String result;
            try { result = action.apply(current); }
            catch (RuntimeException ex) { result = "服务器操作失败 · " + ex.getLocalizedMessage(); }
            String finalStatus = result;
            main.post(() -> {
                if (generation != ticket) return;
                running = false;
                status = finalStatus;
                if (listener != null) listener.changed(refresh);
            });
        });
    }

    void close() {
        serverChanged();
        listener = null;
        worker.shutdownNow();
    }
}
