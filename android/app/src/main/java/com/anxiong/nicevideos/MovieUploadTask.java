package com.anxiong.nicevideos;

import android.content.ContentResolver;
import android.net.Uri;
import android.os.CancellationSignal;
import android.os.Handler;
import android.os.Looper;
import java.io.IOException;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Keeps selected files and their destination together when the activity rotates. */
final class MovieUploadTask {
    interface Listener { void changed(boolean finished); }
    private final ContentResolver resolver;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());
    private CancellationSignal active;
    private Listener listener;
    private String base = "", status = "";
    private boolean closed;

    MovieUploadTask(ContentResolver resolver) { this.resolver = resolver; }
    void listen(Listener listener) { this.listener = listener; }
    String status(String server) { return base.equals(server) ? status : ""; }
    boolean running() { return active != null; }

    void start(String server, List<Uri> files) {
        if (running() || files.isEmpty() || closed) return;
        base = server;
        CancellationSignal stop = new CancellationSignal();
        active = stop;
        update("正在读取本机文件…", false);
        worker.execute(() -> {
            int ok = 0;
            String lastName = "", problem = "";
            for (int i = 0; i < files.size() && !stop.isCanceled(); i++) {
                String prefix = "正在上传 " + (i + 1) + "/" + files.size() + " · ";
                try {
                    lastName = NativeVideoUpload.send(resolver, files.get(i), server, stop, (name, done, size) ->
                        main.post(() -> { if (active == stop && !stop.isCanceled())
                            update(prefix + name + " · " + (100L * done / size) + "%", false); }));
                    ok++;
                } catch (IOException | RuntimeException e) {
                    if (problem.isEmpty()) problem = e.getLocalizedMessage() == null ? "无法上传所选视频" : e.getLocalizedMessage();
                }
            }
            String summary = ok == 1 && files.size() == 1 ? "上传完成：" + lastName :
                    "已上传 " + ok + "/" + files.size() + " 部影片";
            String result = summary + (problem.isEmpty() ? "" : " · " + problem);
            main.post(() -> {
                if (closed || active != stop) return;
                active = null; update(result, true);
            });
        });
    }

    private void update(String message, boolean finished) {
        status = message;
        if (listener != null) listener.changed(finished);
    }

    void close() {
        closed = true;
        listener = null;
        CancellationSignal stop = active;
        if (stop != null) new Thread(stop::cancel, "CancelVideoUpload").start();
        worker.shutdownNow();
        main.removeCallbacksAndMessages(null);
    }
}
