package com.anxiong.nicevideos;

import android.content.Context;
import android.net.Uri;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.view.Surface;

import androidx.media3.common.AudioAttributes;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.Tracks;
import androidx.media3.common.VideoSize;
import androidx.media3.datasource.DefaultDataSource;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.analytics.AnalyticsListener;
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo;
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector;
import androidx.media3.exoplayer.source.ProgressiveMediaSource;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/** One local input, audio clock and video surface across all VR projections. */
final class MovieSession implements Player.Listener {
    interface Listener {
        void onPrepared(long duration, String mime);
        void onVideoSize(int width, int height);
        void onProgress(long position, boolean playing);
        void onBuffering(boolean buffering);
        void onEnded();
        void onError(String message);
    }

    private final Listener listener;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final HandlerThread thread = new HandlerThread("NiceVideos-session");
    private final Handler decoder;
    private volatile boolean closed;
    private ExoPlayer player;
    private boolean failed;
    private boolean softwareOnly;
    private String codecName;
    private String lastInfo;
    private long lastDuration = -1;

    MovieSession(Listener listener) {
        this.listener = listener;
        thread.start();
        decoder = new Handler(thread.getLooper());
    }

    private void deliver(Runnable callback) {
        main.post(() -> { if (!closed) callback.run(); });
    }

    void open(Context context, Uri uri, Surface surface, long start, boolean play, boolean software) {
        Context app = context.getApplicationContext();
        decoder.post(() -> {
            if (closed) return;
            softwareOnly = software;
            try {
                DefaultRenderersFactory renderers = new DefaultRenderersFactory(app)
                        .setEnableDecoderFallback(true);
                if (software) {
                    renderers.setMediaCodecSelector((mime, secure, tunneled) -> {
                        List<MediaCodecInfo> choices = MediaCodecSelector.DEFAULT.getDecoderInfos(mime, secure, tunneled);
                        if (!MimeTypes.isVideo(mime)) return choices;
                        List<MediaCodecInfo> result = new ArrayList<>();
                        for (MediaCodecInfo choice : choices) if (choice.softwareOnly) result.add(choice);
                        return result;
                    });
                }
                player = new ExoPlayer.Builder(app, renderers).setLooper(thread.getLooper()).build();
                player.setAudioAttributes(new AudioAttributes.Builder().setUsage(C.USAGE_MEDIA)
                        .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(), false);
                player.addListener(this);
                player.addAnalyticsListener(new AnalyticsListener() {
                    @Override public void onVideoDecoderInitialized(EventTime eventTime, String name,
                            long initializedAtMs, long durationMs) {
                        codecName = name;
                        publishFormat();
                    }
                });
                player.setVideoSurface(surface);
                // Explicit progressive source: the selected content URI is the only input.
                ProgressiveMediaSource source = new ProgressiveMediaSource.Factory(
                        new DefaultDataSource.Factory(app)).createMediaSource(MediaItem.fromUri(uri));
                player.setMediaSource(source, Math.max(0L, start));
                player.setPlayWhenReady(play);
                player.prepare();
            } catch (RuntimeException e) {
                fail("无法打开视频：" + e.getLocalizedMessage());
            }
        });
    }

    void setPlaying(boolean play) {
        decoder.post(() -> {
            if (closed || failed || player == null) return;
            if (play && player.getPlaybackState() == Player.STATE_ENDED) player.seekTo(0);
            player.setPlayWhenReady(play);
            publishClock();
        });
    }

    void seek(long position) {
        decoder.post(() -> {
            if (closed || failed || player == null) return;
            player.seekTo(Math.max(0L, position));
            publishClock();
        });
    }

    @Override public void onIsPlayingChanged(boolean playing) { publishClock(); }

    @Override public void onPlaybackStateChanged(int state) {
        if (closed || failed) return;
        deliver(() -> listener.onBuffering(state == Player.STATE_BUFFERING));
        if (state == Player.STATE_READY) {
            Tracks tracks = player.getCurrentTracks();
            if (!tracks.isTypeSelected(C.TRACK_TYPE_VIDEO)) {
                fail(tracks.containsType(C.TRACK_TYPE_VIDEO)
                        ? "当前解码器无法处理该视频轨道，请在片源信息中切换解码方式。"
                        : "所选文件没有可播放的视频轨道。");
                return;
            }
            publishFormat();
        }
        if (state == Player.STATE_ENDED) {
            player.setPlayWhenReady(false);
            decoder.removeCallbacks(ticker);
            deliver(listener::onEnded);
        } else {
            publishClock();
        }
    }

    @Override public void onVideoSizeChanged(VideoSize size) {
        if (size.width <= 0 || size.height <= 0) return;
        int displayWidth = Math.max(1, Math.round(size.width * size.pixelWidthHeightRatio));
        deliver(() -> listener.onVideoSize(displayWidth, size.height));
        publishFormat();
    }

    private void publishFormat() {
        if (closed || failed || player == null || player.getPlaybackState() != Player.STATE_READY) return;
        Format format = player.getVideoFormat();
        StringBuilder details = new StringBuilder();
        if (format != null) {
            if (format.sampleMimeType != null) details.append(format.sampleMimeType);
            if (format.frameRate > 0) details.append(String.format(Locale.ROOT, " · %.1f fps", format.frameRate));
        }
        if (details.length() == 0) details.append("视频轨道");
        if (codecName != null) details.append(" · ").append(codecName);
        if (softwareOnly) details.append("（软件）");
        long duration = Math.max(0, player.getDuration());
        String info = details.toString();
        if (duration != lastDuration || !info.equals(lastInfo)) {
            lastDuration = duration;
            lastInfo = info;
            deliver(() -> listener.onPrepared(duration, info));
        }
    }

    private final Runnable ticker = this::publishClock;
    private void publishClock() {
        decoder.removeCallbacks(ticker);
        if (closed || failed || player == null || player.getPlaybackState() == Player.STATE_IDLE
                || player.getPlaybackState() == Player.STATE_ENDED) return;
        long position = Math.max(0, player.getCurrentPosition());
        boolean moving = player.isPlaying();
        deliver(() -> listener.onProgress(position, moving));
        if (moving) decoder.postDelayed(ticker, 250);
    }

    @Override public void onPlayerError(PlaybackException error) {
        String reason;
        if (error.errorCode == PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND
                || error.errorCode == PlaybackException.ERROR_CODE_IO_NO_PERMISSION) {
            reason = "无法读取原文件，请重新从「打开文件」选择。";
        } else if (error.errorCode >= PlaybackException.ERROR_CODE_DECODER_INIT_FAILED
                && error.errorCode <= PlaybackException.ERROR_CODE_DECODING_RESOURCES_RECLAIMED) {
            reason = softwareOnly ? "设备上的软件解码器无法播放这条轨道。可在片源信息中恢复自动解码。"
                    : "无法解码这部影片，可在片源信息中尝试软件解码。";
        } else {
            reason = "媒体读取或解析失败，请确认文件完整、存储仍可访问。";
        }
        fail(reason + "\n" + error.getErrorCodeName());
    }

    private void fail(String message) {
        if (closed || failed) return;
        failed = true;
        decoder.removeCallbacks(ticker);
        if (player != null) player.pause();
        deliver(() -> listener.onError(message));
    }

    void close() { close(null); }

    // Each session owns a separate decoder looper. Release the old codec and
    // its Surface producer before another session is allowed to open that Surface.
    void close(Runnable released) {
        if (closed) return;
        closed = true;
        decoder.post(() -> {
            try {
                decoder.removeCallbacks(ticker);
                if (player != null) {
                    player.removeListener(this);
                    player.release();
                    player = null;
                }
            } finally {
                thread.quitSafely();
                if (released != null) main.post(released);
            }
        });
    }
}
