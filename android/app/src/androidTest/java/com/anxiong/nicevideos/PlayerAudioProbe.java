package com.anxiong.nicevideos;

import android.media.AudioTrack;
import android.os.Handler;
import android.os.Looper;
import androidx.media3.common.C;
import androidx.media3.common.Player;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.Renderer;
import androidx.media3.exoplayer.analytics.AnalyticsListener;
import androidx.media3.exoplayer.audio.DefaultAudioSink;
import androidx.media3.exoplayer.audio.MediaCodecAudioRenderer;
import androidx.test.core.app.ActivityScenario;
import java.lang.reflect.Field;
import java.util.concurrent.Callable;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import static org.junit.Assert.*;

/** Inspect the installed player's actual platform output without adding hooks to the APK. */
final class PlayerAudioProbe implements AnalyticsListener {
    final AtomicInteger seeks = new AtomicInteger();
    final AtomicInteger underruns = new AtomicInteger();
    final AtomicInteger pauses = new AtomicInteger();
    private final ExoPlayer player;
    private final Renderer audioRenderer;

    PlayerAudioProbe(ActivityScenario<PlayerActivity> scene) throws Exception {
        AtomicReference<ExoPlayer> current = new AtomicReference<>();
        scene.onActivity(a -> {
            Object session = field(PlayerActivity.class, a, "session");
            current.set((ExoPlayer) field(MovieSession.class, session, "player"));
        });
        player = current.get();
        audioRenderer = on(player.getApplicationLooper(), () -> {
            player.addAnalyticsListener(this);
            for (int i = 0; i < player.getRendererCount(); i++) {
                if (player.getRendererType(i) == C.TRACK_TYPE_AUDIO) return player.getRenderer(i);
            }
            throw new AssertionError("Missing audio renderer");
        });
    }

    AudioTrack track() throws Exception {
        return on(player.getPlaybackLooper(), () -> {
            // Media3 1.6.1 exposes its renderer, but not the underlying AudioTrack.
            // Reading these two fields is confined to the owning playback thread.
            Object sink = field(MediaCodecAudioRenderer.class, audioRenderer, "audioSink");
            return (AudioTrack) field(DefaultAudioSink.class, sink, "audioTrack");
        });
    }

    long mediaPosition() throws Exception {
        return on(player.getApplicationLooper(), player::getCurrentPosition);
    }

    @Override public void onPositionDiscontinuity(EventTime event, Player.PositionInfo oldPosition,
            Player.PositionInfo newPosition, int reason) {
        if (reason == Player.DISCONTINUITY_REASON_SEEK) seeks.incrementAndGet();
    }

    @Override public void onAudioUnderrun(EventTime event, int bytes, long sizeMs, long elapsedMs) {
        underruns.incrementAndGet();
    }

    @Override public void onPlayWhenReadyChanged(EventTime event, boolean play, int reason) {
        if (!play) pauses.incrementAndGet();
    }

    private static Object field(Class<?> owner, Object instance, String name) {
        try {
            Field f = owner.getDeclaredField(name);
            f.setAccessible(true);
            return f.get(instance);
        } catch (ReflectiveOperationException e) {
            throw new AssertionError("Could not observe " + owner.getSimpleName() + "." + name, e);
        }
    }

    private static <T> T on(Looper looper, Callable<T> sample) throws Exception {
        FutureTask<T> done = new FutureTask<>(sample);
        assertTrue("Player thread stopped", new Handler(looper).post(done));
        return done.get(4, TimeUnit.SECONDS);
    }
}
