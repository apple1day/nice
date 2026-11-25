package com.anxiong.nicevideos;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.MediaFormat;
import android.media.MediaPlayer;
import android.net.Uri;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.os.PersistableBundle;
import android.view.Surface;
import java.io.IOException;

/** A single decoder looper also keeps provider opens and codec retirement off the UI thread. */
final class MovieSession {
    interface Listener {
        void onPrepared(long duration, String mime);
        void onVideoSize(int width, int height);
        void onProgress(long position, boolean playing);
        void onBuffering(boolean buffering);
        void onEnded();
        void onError(String message);
    }

    private final Handler main = new Handler(Looper.getMainLooper());
    private final HandlerThread thread = new HandlerThread("NiceVideos-player");
    private final Handler decoder;
    private final Listener listener;
    private volatile boolean closed;
    private MediaPlayer player;
    private boolean ready, wantsPlay, seeking, ended;
    private long pendingSeek = -1, duration;
    private final Runnable ticker = new Runnable() {
        @Override public void run() {
            if (closed || !ready || seeking) return;
            long time = Math.max(0L, player.getCurrentPosition());
            boolean playing = player.isPlaying();
            deliver(() -> listener.onProgress(time, playing));
            if (wantsPlay && !ended) decoder.postDelayed(this, 350);
        }
    };

    MovieSession(Listener listener) {
        this.listener = listener;
        thread.start();
        decoder = new Handler(thread.getLooper());
    }

    private void deliver(Runnable callback) {
        main.post(() -> { if (!closed) callback.run(); });
    }

    void open(Context context, Uri uri, Surface surface, long start, boolean play) {
        Context app = context.getApplicationContext();
        decoder.post(() -> {
            if (closed) return;
            wantsPlay = play;
            pendingSeek = start > 0 ? start : -1;
            try {
                player = new MediaPlayer();
                player.setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build());
                player.setSurface(surface);
                player.setOnPreparedListener(mp -> {
                    if (closed) return;
                    ready = true;
                    duration = Math.max(0L, mp.getDuration());
                    String mime = null;
                    for (MediaPlayer.TrackInfo track : mp.getTrackInfo()) {
                        if (track.getTrackType() == MediaPlayer.TrackInfo.MEDIA_TRACK_TYPE_VIDEO) {
                            MediaFormat format = track.getFormat();
                            mime = format == null ? null : format.getString(MediaFormat.KEY_MIME);
                            if (mime == null) mime = "视频轨道";
                            break;
                        }
                    }
                    if (mime == null && mp.getVideoWidth() == 0 && mp.getVideoHeight() == 0) {
                        fail("没有可播放的视频轨道，请检查片源的编码。");
                        return;
                    }
                    // TrackInfo.getFormat() can omit video details. When available, the
                    // framework's own metrics describe the selected track and actual decoder.
                    PersistableBundle metrics = mp.getMetrics();
                    if (metrics != null) {
                        String reported = metrics.getString(MediaPlayer.MetricsConstants.MIME_TYPE_VIDEO);
                        String codec = metrics.getString(MediaPlayer.MetricsConstants.CODEC_VIDEO);
                        if (reported != null && !reported.isEmpty()) mime = reported;
                        if (codec != null && !codec.isEmpty()) mime = (mime == null ? "" : mime + " · ") + codec;
                    }
                    String info = mime;
                    deliver(() -> listener.onPrepared(duration, info));
                    size(mp.getVideoWidth(), mp.getVideoHeight());
                    applyIntent();
                });
                player.setOnVideoSizeChangedListener((mp,w,h) -> size(w,h));
                player.setOnInfoListener((mp, what, extra) -> {
                    if (what == MediaPlayer.MEDIA_INFO_BUFFERING_START || what == MediaPlayer.MEDIA_INFO_BUFFERING_END)
                        deliver(() -> listener.onBuffering(what == MediaPlayer.MEDIA_INFO_BUFFERING_START));
                    return false;
                });
                player.setOnSeekCompleteListener(mp -> {
                    if (!closed && ready) { seeking = false; applyIntent(); }
                });
                player.setOnCompletionListener(mp -> {
                    if (closed || !ready) return;
                    ended = true;
                    wantsPlay = false;
                    decoder.removeCallbacks(ticker);
                    deliver(listener::onEnded);
                });
                player.setOnErrorListener((mp, what, extra) -> {
                    String detail;
                    switch (extra) {
                        case MediaPlayer.MEDIA_ERROR_IO: detail = "文件读取失败，请检查存储设备或文件提供方"; break;
                        case MediaPlayer.MEDIA_ERROR_UNSUPPORTED: detail = "系统解码器不支持这个视频的格式或规格"; break;
                        case MediaPlayer.MEDIA_ERROR_MALFORMED: detail = "视频封装或数据异常"; break;
                        case MediaPlayer.MEDIA_ERROR_TIMED_OUT: detail = "读取超时，请检查云端文件是否已下载"; break;
                        default: detail = "系统播放器无法继续解码，请确认片源完整且设备支持其编码";
                    }
                    fail(detail + "（" + what + " / " + extra + "）");
                    return true;
                });
                player.setDataSource(app, uri);
                if (!closed) player.prepareAsync();
            } catch (IOException | RuntimeException e) {
                fail("无法打开视频。请从「文件」重新选择，或把云端文件下载到设备。"
                        + (e.getMessage() == null ? "" : "\n" + e.getMessage()));
            }
        });
    }

    private void size(int w, int h) { if (w > 0 && h > 0) deliver(() -> listener.onVideoSize(w,h)); }

    void setPlaying(boolean value) {
        decoder.post(() -> {
            if (closed || player == null) return;
            wantsPlay = value;
            if (value && ended) { ended = false; pendingSeek = 0; }
            if (!value && ready && player.isPlaying()) player.pause();
            applyIntent();
        });
    }

    void seek(long target) {
        decoder.post(() -> {
            if (closed || player == null) return;
            ended = false;
            pendingSeek = Math.max(0, target);
            applyIntent();
        });
    }

    private void applyIntent() {
        if (closed || !ready || seeking) return;
        if (pendingSeek >= 0) {
            long target = duration > 0 ? Math.min(duration, pendingSeek) : pendingSeek;
            pendingSeek = -1;
            seeking = true;
            player.seekTo(target, MediaPlayer.SEEK_CLOSEST);
            return;
        }
        if (wantsPlay && !player.isPlaying()) player.start();
        if (!wantsPlay && player.isPlaying()) player.pause();
        decoder.removeCallbacks(ticker);
        ticker.run();
    }

    private void fail(String message) {
        if (closed) return;
        release();
        deliver(() -> listener.onError(message));
    }

    private void release() {
        ready = false;
        decoder.removeCallbacks(ticker);
        if (player != null) {
            player.setOnPreparedListener(null);
            player.setOnVideoSizeChangedListener(null);
            player.setOnCompletionListener(null);
            player.setOnSeekCompleteListener(null);
            player.setOnErrorListener(null);
            player.setOnInfoListener(null);
            player.release();
            player = null;
        }
    }

    void close() {
        if (closed) return;
        closed = true;
        decoder.post(() -> { release(); thread.quitSafely(); });
    }
}
