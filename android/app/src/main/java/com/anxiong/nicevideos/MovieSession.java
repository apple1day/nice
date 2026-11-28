package com.anxiong.nicevideos;

import android.content.Context;
import android.net.Uri;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.util.Log;
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
import androidx.media3.exoplayer.ExoPlaybackException;
import androidx.media3.exoplayer.analytics.AnalyticsListener;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.DefaultAudioSink;
import androidx.media3.exoplayer.audio.DefaultAudioTrackBufferSizeProvider;
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
    private volatile int audioUnderruns;
    private volatile String trackReport = "视频轨道  等待识别";
    private volatile float fps = Format.NO_VALUE;
    private volatile String errorCode = "";
    private Format sourceFormat;
    private int formatSupport = -1;
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

    int audioUnderruns() { return audioUnderruns; }
    float frameRate() { return fps; }
    String diagnostics() {
        return trackReport + "\n本次播放音频缓冲耗尽  " + audioUnderruns + " 次"
                + (errorCode.isEmpty() ? "" : "\n播放错误  " + errorCode);
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
                DefaultRenderersFactory renderers = new DefaultRenderersFactory(app) {
                    @Override protected AudioSink buildAudioSink(Context context, boolean floatOutput,
                            boolean trackPlaybackParams) {
                        // A larger PCM queue absorbs short scheduling gaps while rendering a panorama.
                        // Media3 still uses its normal bounds for passthrough and offloaded audio.
                        return new DefaultAudioSink.Builder(context)
                                .setEnableFloatOutput(floatOutput)
                                .setEnableAudioTrackPlaybackParams(trackPlaybackParams)
                                .setAudioTrackBufferSizeProvider(new DefaultAudioTrackBufferSizeProvider.Builder()
                                        .setMinPcmBufferDurationUs(500_000).build())
                                .build();
                    }
                };
                renderers.setEnableDecoderFallback(true);
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
                    @Override public void onAudioUnderrun(EventTime eventTime, int bufferSize,
                            long bufferSizeMs, long elapsedSinceLastFeedMs) {
                        audioUnderruns++;
                    }
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
                errorCode = e.getClass().getSimpleName();
                fail("无法打开视频，请确认文件仍可读取。");
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
            updateTrack(tracks);
            if (!tracks.isTypeSelected(C.TRACK_TYPE_VIDEO)) {
                if (softwareOnly) {
                    fail("设备上的软件解码器无法播放这条视频轨道。请在「片源信息」恢复自动解码。");
                } else if (tracks.containsType(C.TRACK_TYPE_VIDEO)) {
                    fail("设备未能解码这条视频轨道。可在「片源信息」查看原片规格或尝试软件解码。");
                } else {
                    fail("所选文件没有可播放的视频轨道。");
                }
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

    @Override public void onTracksChanged(Tracks tracks) {
        if (closed || failed) return;
        updateTrack(tracks);
        publishFormat();
    }

    private void updateTrack(Tracks tracks) {
        Format candidate = null;
        int support = -1;
        for (Tracks.Group group : tracks.getGroups()) {
            if (group.getType() != C.TRACK_TYPE_VIDEO) continue;
            for (int i = 0; i < group.length; i++) {
                int available = group.getTrackSupport(i);
                if (group.isTrackSelected(i)) {
                    sourceFormat = group.getTrackFormat(i);
                    formatSupport = available;
                    return;
                }
                if (candidate == null || available > support) {
                    candidate = group.getTrackFormat(i);
                    support = available;
                }
            }
        }
        if (candidate != null) { sourceFormat = candidate; formatSupport = support; }
    }

    private static String supportDescription(int support) {
        switch (support) {
            case C.FORMAT_HANDLED: return "设备声明支持";
            case C.FORMAT_EXCEEDS_CAPABILITIES: return "超出设备声明能力";
            case C.FORMAT_UNSUPPORTED_SUBTYPE: return "设备未提供该编码的兼容解码器";
            case C.FORMAT_UNSUPPORTED_DRM: return "设备未支持此加密格式";
            case C.FORMAT_UNSUPPORTED_TYPE: return "设备未支持此轨道类型";
            default: return "尚未报告";
        }
    }

    private void publishFormat() {
        if (closed || failed || player == null) return;
        Format activeFormat = player.getVideoFormat();
        Format format = activeFormat != null ? activeFormat : sourceFormat;
        StringBuilder details = new StringBuilder();
        if (format != null) {
            if (format.sampleMimeType != null && format.sampleMimeType.matches("[A-Za-z0-9/+.\\-]{1,80}"))
                details.append(format.sampleMimeType);
            if (format.codecs != null && format.codecs.matches("[A-Za-z0-9.,_ \\-]{1,100}"))
                details.append(" · ").append(format.codecs);
            if (format.width > 0 && format.height > 0)
                details.append(" · ").append(format.width).append(" × ").append(format.height);
            fps = format.frameRate;
            if (fps > 0) details.append(String.format(Locale.ROOT, " · %.1f fps", fps));
            if (format.colorInfo != null) {
                String transfer = null;
                switch (format.colorInfo.colorTransfer) {
                    case C.COLOR_TRANSFER_ST2084: transfer = "PQ"; break;
                    case C.COLOR_TRANSFER_HLG: transfer = "HLG"; break;
                    case C.COLOR_TRANSFER_SDR: transfer = "SDR"; break;
                }
                if (transfer != null) details.append(" · ").append(transfer);
                if (format.colorInfo.lumaBitdepth > 0) details.append(" · ").append(format.colorInfo.lumaBitdepth).append(" bit");
            }
        }
        if (details.length() == 0) details.append("暂未识别");
        details.append("\n设备声明能力  ").append(supportDescription(formatSupport));
        details.append("\n解码器  ").append(codecName == null ? "尚未启动" : codecName);
        if (codecName != null && softwareOnly) details.append("（软件）");
        String info = details.toString();
        trackReport = "视频轨道  " + info;
        if (player.getPlaybackState() != Player.STATE_READY || !player.getCurrentTracks().isTypeSelected(C.TRACK_TYPE_VIDEO)) return;
        long duration = Math.max(0, player.getDuration());
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
        if (closed || failed) return;
        updateTrack(player.getCurrentTracks());
        if (error instanceof ExoPlaybackException) {
            ExoPlaybackException failure = (ExoPlaybackException) error;
            if (failure.rendererFormat != null && MimeTypes.isVideo(failure.rendererFormat.sampleMimeType)) {
                sourceFormat = failure.rendererFormat;
                formatSupport = failure.rendererFormatSupport;
            }
        }
        publishFormat();
        errorCode = error.getErrorCodeName();
        for (Throwable cause = error.getCause(); cause != null; cause = cause.getCause()) {
            if (cause instanceof android.media.MediaCodec.CodecException) {
                String code = ((android.media.MediaCodec.CodecException) cause).getDiagnosticInfo();
                if (code != null && code.matches("[A-Za-z0-9_.-]{1,100}")) errorCode += " · " + code;
                break;
            }
        }
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
        publishFormat();
        failed = true;
        Log.w("NiceVideos-session", message);
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
                // release() enqueues final analytics events on this looper.
                decoder.post(thread::quitSafely);
                if (released != null) main.post(released);
            }
        });
    }
}
