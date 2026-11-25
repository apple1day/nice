package com.anxiong.nicevideos;

import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.media.AudioTrack;
import android.media.MediaCodecList;
import android.media.MediaFormat;
import android.net.Uri;
import android.opengl.Matrix;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.PixelCopy;
import android.view.View;
import android.view.ViewGroup;
import android.view.accessibility.AccessibilityNodeInfo;
import android.widget.LinearLayout;
import android.widget.SeekBar;
import android.widget.TextView;
import androidx.media3.common.Format;
import androidx.media3.common.MimeTypes;
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo;
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector;
import androidx.test.core.app.ActivityScenario;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import org.junit.Assume;
import org.junit.Test;
import org.junit.runner.RunWith;
import java.io.File;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import static org.junit.Assert.*;

/** Read pixels from the production decoder's on-screen GL surface, including when paused. */
@RunWith(AndroidJUnit4.class)
public final class PanoramaPlaybackTest {
    private final Context app = InstrumentationRegistry.getInstrumentation().getTargetContext();

    @Test public void enterDragRecenterAndSwitchHeadsetFromThePlayer() throws Exception {
        File file = fixture("sbs");
        try (ActivityScenario<PlayerActivity> player = open(file)) {
            MovieSurface movie = surface(player);
            await("Movie didn't start", () -> seconds(player) >= 1);
            press(player, "快进15秒");
            await("Clock did not seek", () -> seconds(player) >= 15);
            long before = seconds(player);
            press(player, "进入 VR");
            try (Screen screen = new Screen(movie)) {
                screen.frontMotion();
                swipeLeft(player, movie);
                screen.until("drag moves camera right", (center, l, r) ->
                        Color.red(center) > 145 && near(Color.green(center), 128) && leftEye(center));
                press(player, "视角回正");
                screen.single("recentered left-eye front", .50, .50);
                press(player, "切换眼镜显示");
                screen.eyes("headset front", .50, .50);
                press(player, "退出 VR");
                screen.eyes("restored flat SBS picture", .50, .50);
            }
            assertTrue("Entering and leaving VR reset the playhead", seconds(player) >= before);
        } finally { file.delete(); }
    }

    @Test public void draggingPanoramaAndScrubbingTimelineKeepAudioPlaying() throws Exception {
        File file = fixture("sbs");
        try (ActivityScenario<PlayerActivity> scene = open(file)) {
            await("Movie didn't start", () -> seconds(scene) >= 1);
            press(scene, "进入 VR");
            PlayerAudioProbe probe = new PlayerAudioProbe(scene);
            await("Platform audio output didn't start", () -> {
                AudioTrack track = probe.track();
                return track != null && track.getPlaybackHeadPosition() > 0;
            });
            dragWithAudio(scene, "视频画面", probe, MotionEvent.ACTION_UP);
            assertEquals("Looking around issued a seek", 0, probe.seeks.get());
            dragWithAudio(scene, "播放进度", probe, MotionEvent.ACTION_CANCEL);
            assertEquals("Cancelled preview issued a seek", 0, probe.seeks.get());
            dragWithAudio(scene, "播放进度", probe, MotionEvent.ACTION_UP);
            await("Release did not commit the target position", () ->
                    probe.seeks.get() == 1 && probe.mediaPosition() > 34000 && probe.mediaPosition() < 52000);
            await("Audio output did not resume after committed seek", () -> {
                AudioTrack track = probe.track();
                if (track == null || track.getPlayState() != AudioTrack.PLAYSTATE_PLAYING) return false;
                int start = track.getPlaybackHeadPosition();
                SystemClock.sleep(250);
                return probe.track() == track && track.getPlaybackHeadPosition() - start > track.getSampleRate() / 10;
            });
            assertEquals("Multiple seeks on one release", 1, probe.seeks.get());
        } finally { file.delete(); }
    }

    @Test public void repeatedAccessibleSeekWhilePausedCommitsOnceAndStaysPaused() throws Exception {
        File file = fixture("sbs");
        try (ActivityScenario<PlayerActivity> scene = open(file)) {
            await("Movie didn't start", () -> seconds(scene) >= 1);
            PlayerAudioProbe probe = new PlayerAudioProbe(scene);
            press(scene, "播放或暂停");
            await("Pause didn't reach decoder", () -> probe.pauses.get() == 1);
            scene.onActivity(a -> {
                SeekBar slider = (SeekBar) control(a, "播放进度");
                for (float fraction : new float[]{.2f, .35f, .55f, .75f}) {
                    Bundle args = new Bundle();
                    args.putFloat(AccessibilityNodeInfo.ACTION_ARGUMENT_PROGRESS_VALUE, fraction * slider.getMax());
                    assertTrue("Accessible seek rejected", slider.performAccessibilityAction(
                            AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_PROGRESS.getId(), args));
                }
            });
            await("Accessible updates should seek once to 75%", () -> probe.seeks.get() == 1
                    && Math.abs(probe.mediaPosition() - 45000) < 1300);
            long pausedAt = probe.mediaPosition();
            SystemClock.sleep(400);
            assertEquals("Paused scrubbing started playback", pausedAt, probe.mediaPosition());
            AudioTrack track = probe.track();
            assertTrue("Paused scrubbing started platform audio",
                    track == null || track.getPlayState() != AudioTrack.PLAYSTATE_PLAYING);
            assertEquals("Additional seeks after debounce", 1, probe.seeks.get());
        } finally { file.delete(); }
    }

    private static void dragWithAudio(ActivityScenario<PlayerActivity> scene, String target,
                                      PlayerAudioProbe probe, int terminalAction) throws Exception {
        int[] bounds = new int[4];
        scene.onActivity(a -> {
            View v = control(a, target);
            if (!v.isShown()) control(a, "视频画面").performClick();
            assertTrue("Drag target hidden", v.isShown());
            int[] origin = new int[2];
            v.getLocationOnScreen(origin);
            bounds[0] = origin[0]; bounds[1] = origin[1];
            bounds[2] = v.getWidth(); bounds[3] = v.getHeight();
        });
        AudioTrack track = probe.track();
        assertNotNull(track);
        int underruns = track.getUnderrunCount();
        int rendererUnderruns = probe.underruns.get();
        int seeks = probe.seeks.get(), pauses = probe.pauses.get();
        float y = bounds[1] + bounds[3] * .5f;
        long down = SystemClock.uptimeMillis();
        float x = bounds[0] + bounds[2] * .25f;
        pointer(down, MotionEvent.ACTION_DOWN, x, y);
        try {
            for (int window = 0; window < 3; window++) {
                long start = SystemClock.elapsedRealtime();
                int first = track.getPlaybackHeadPosition();
                for (int i = 1; i <= 20; i++) {
                    x = bounds[0] + bounds[2] * (.25f + .45f * (window * 20 + i) / 60);
                    pointer(down, MotionEvent.ACTION_MOVE, x, y);
                    SystemClock.sleep(24);
                }
                long elapsed = SystemClock.elapsedRealtime() - start;
                long played = 1000L * (track.getPlaybackHeadPosition() - first) / track.getSampleRate();
                assertTrue(target + " PCM playout advanced " + played + " ms during " + elapsed + " ms",
                        played >= elapsed * .65 - 40);
                assertSame(target + " reopened platform audio output", track, probe.track());
            }
            assertEquals(target + " starved AudioTrack", underruns, track.getUnderrunCount());
            assertEquals(target + " reported audio underruns", rendererUnderruns, probe.underruns.get());
            assertEquals(target + " paused audio", pauses, probe.pauses.get());
            assertEquals(target + " issued a seek during movement", seeks, probe.seeks.get());
        } finally { pointer(down, terminalAction, x, y); }
    }

    private static void pointer(long down, int action, float x, float y) {
        MotionEvent event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, x, y, 0);
        event.setSource(android.view.InputDevice.SOURCE_TOUCHSCREEN);
        try { InstrumentationRegistry.getInstrumentation().sendPointerSync(event); }
        finally { event.recycle(); }
    }

    @Test public void gamepadPausesOnceSeeksAndRecentersInVr() throws Exception {
        File file = fixture("sbs");
        try (ActivityScenario<PlayerActivity> player = open(file)) {
            MovieSurface movie = surface(player);
            await("Movie didn't start", () -> seconds(player) >= 1);
            press(player, "进入 VR");
            sendButton(player, KeyEvent.KEYCODE_BUTTON_A);
            player.onActivity(a -> assertEquals("播放", ((TextView) control(a, "播放或暂停")).getText().toString()));
            sendButton(player, KeyEvent.KEYCODE_BUTTON_R1);
            await("Gamepad seek didn't reach the requested position", () -> seconds(player) >= 15);
            long at = seconds(player);
            swipeLeft(player, movie);
            try (Screen screen = new Screen(movie)) {
                screen.until("drag while paused moves the view", (c, l, r) -> Color.red(c) > 145 && leftEye(c));
                sendButton(player, KeyEvent.KEYCODE_BUTTON_X);
                screen.single("gamepad recentered a paused movie", .50, .50);
            }
            sendButton(player, KeyEvent.KEYCODE_BUTTON_Y);
            player.onActivity(a -> assertFalse(control(a, "播放或暂停").isShown()));
            sendButton(player, KeyEvent.KEYCODE_BUTTON_A);
            await("Gamepad resume didn't advance", () -> seconds(player) > at);
            sendButton(player, KeyEvent.KEYCODE_BUTTON_L1);
            await("Gamepad rewind didn't seek", () -> seconds(player) < 10);
        } finally { file.delete(); }
    }

    private static void sendButton(ActivityScenario<PlayerActivity> player, int code) {
        player.onActivity(a -> {
            long down = SystemClock.uptimeMillis();
            for (int repeat = 0; repeat <= 2; repeat++) {
                int action = repeat == 2 ? KeyEvent.ACTION_UP : KeyEvent.ACTION_DOWN;
                KeyEvent event = new KeyEvent(down, SystemClock.uptimeMillis(), action, code,
                        repeat == 1 ? 1 : 0, 0, 0, 0, 0, InputDevice.SOURCE_GAMEPAD);
                assertTrue(a.dispatchKeyEvent(event));
            }
        });
    }

    @Test public void projectedRaysSampleExpectedDirectionsAndTopBottomEyes() throws Exception {
        File file = fixture("tb");
        try (ActivityScenario<PlayerActivity> player = open(file)) {
            MovieSurface movie = surface(player);
            await("Movie didn't start", () -> seconds(player) >= 1);
            press(player, "播放或暂停");
            try (Screen screen = new Screen(movie)) {
                // With +X to the right and +Y up: 90° right on a full sphere is
                // 3/4 across, and 45° up is 1/4 down the source image.
                view(player, movie, VrFormat.Projection.EQUIRECT_360, VrFormat.Layout.TOP_BOTTOM, true, 90, 45);
                screen.eyes("360 right/up, top is left eye", .75, .25);
                view(player, movie, VrFormat.Projection.EQUIRECT_360, VrFormat.Layout.TOP_BOTTOM, true, -120, -36);
                screen.eyes("360 behind/low", 1.0 / 6, .70);
                // The unsplit layout must use the entire movie. The top quarter
                // of this stacked fixture is halfway down the top tile.
                view(player, movie, VrFormat.Projection.EQUIRECT_360, VrFormat.Layout.MONO, false, 90, 45);
                screen.single("mono panorama uses the whole source", .75, .50);
                view(player, movie, VrFormat.Projection.EQUIRECT_180, VrFormat.Layout.TOP_BOTTOM, true, 45, -45);
                screen.eyes("180 longitude spans a hemisphere", .75, .75);
                view(player, movie, VrFormat.Projection.EQUIRECT_180, VrFormat.Layout.TOP_BOTTOM, true, 120, 0);
                screen.until("180° rear must not wrap", (center, l, r) -> black(l) && black(r));
                view(player, movie, VrFormat.Projection.FISHEYE_180, VrFormat.Layout.TOP_BOTTOM, true, 80, 70);
                // Equidistant projection on a square eye tile for yaw=80°, pitch=70°.
                screen.eyes("calibrated fisheye diagonal", .663, .047);
            }
        } finally { file.delete(); }
    }

    @Test public void hdHevcDeliversChangingProjectedEyesWhenDeviceSupportsIt() throws Exception {
        requireHevcMotion("hevc-hd", 1280, 640);
    }

    @Test public void fourKHevcDeliversChangingProjectedEyesWhenDeviceSupportsIt() throws Exception {
        requireHevcMotion("hevc", 3840, 1920);
    }

    private void requireHevcMotion(String asset, int width, int height) throws Exception {
        String format = width + "×" + height + " HEVC";
        MediaFormat source = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, width, height);
        source.setInteger(MediaFormat.KEY_FRAME_RATE, 4);
        String decoder = new MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(source);
        Assume.assumeTrue("Device advertises no decoder for " + format + " at 4 fps", decoder != null);
        File file = fixture(asset);
        try (ActivityScenario<PlayerActivity> player = open(file)) {
            MovieSurface movie = surface(player);
            await(format + " time did not advance (" + decoder + ")", () -> seconds(player) >= 1);
            press(player, "进入 VR");
            try (Screen screen = new Screen(movie)) {
                screen.frontMotion();
                press(player, "切换眼镜显示");
                boolean[] seen = new boolean[2];
                screen.until(format + ": both eyes must pulse together", (c, l, r) -> {
                    if (at(l, .5, .5) && at(r, .5, .5) && leftEye(l) && rightEye(r)) {
                        if (Color.blue(l) < 57 && Color.blue(r) < 185) seen[0] = true;
                        if (Color.blue(l) >= 57 && Color.blue(r) >= 185) seen[1] = true;
                    }
                    return seen[0] && seen[1];
                });
            }
        } finally { file.delete(); }
    }

    @Test public void switchingAvcDecoderKeepsThePlayheadOrAllowsRecovery() throws Exception {
        exerciseSoftwareSwitch("sbs", softwareDecoders(MimeTypes.VIDEO_H264, 384, 192, 8));
    }

    @Test public void softwareDecoderCanActuallyRenderThePanorama() throws Exception {
        List<String> vp9 = softwareDecoders(MimeTypes.VIDEO_VP9, 384, 192, 8);
        if (!vp9.isEmpty()) {
            exerciseSoftwareSwitch("vp9", vp9);
            return;
        }
        List<String> hevc = softwareDecoders(MimeTypes.VIDEO_H265, 1280, 640, 4);
        Assume.assumeTrue("No compatible software VP9 or HEVC decoder for either motion fixture", !hevc.isEmpty());
        exerciseSoftwareSwitch("hevc-hd", hevc);
    }

    private static List<String> softwareDecoders(String mime, int width, int height, int fps) throws Exception {
        Format source = new Format.Builder().setSampleMimeType(mime).setWidth(width).setHeight(height)
                .setFrameRate(fps).build();
        List<String> names = new ArrayList<>();
        for (MediaCodecInfo codec : MediaCodecSelector.DEFAULT.getDecoderInfos(mime, false, false)) {
            if (codec.softwareOnly && codec.isFormatSupported(source)) names.add(codec.name);
        }
        return names;
    }

    private void exerciseSoftwareSwitch(String fixtureName, List<String> software) throws Exception {
        File file = fixture(fixtureName);
        try (ActivityScenario<PlayerActivity> player = open(file)) {
            MovieSurface movie = surface(player);
            await("Automatic playback didn't start", () -> seconds(player) >= 1);
            press(player, "快进15秒");
            await("Could not seek before switching decoder", () -> seconds(player) >= 15);
            press(player, "进入 VR");
            long before = seconds(player);
            press(player, "片源信息");
            dialogText("尝试软件解码", true);
            if (software.isEmpty()) {
                // The API 30 emulator's only AVC decoder is the goldfish codec.
                // A failed software retry must leave a usable path back to it.
                dialogText("设备上的软件解码器无法播放这条视频轨道", false);
                press(player, "片源信息");
                dialogText("恢复自动解码", true);
            }
            await("Decoder switch reset or stalled the clock at " + before,
                    () -> seconds(player) >= before + 2);
            try (Screen screen = new Screen(movie)) { screen.frontMotion(); }
            if (!software.isEmpty()) {
                press(player, "片源信息");
                await("Source details omitted the active software decoder " + software, () -> {
                    for (String name : software) {
                        if (inActiveWindow(name + "（软件）", false)) return true;
                    }
                    return false;
                });
                dialogText("关闭", true);
            }
        } finally { file.delete(); }
    }

    /** AlertDialog is a separate window, accessed through the real accessibility tree. */
    private static void dialogText(String text, boolean click) throws Exception {
        await("Missing " + (click ? "button " : "text ") + text, () -> inActiveWindow(text, click));
    }

    private static boolean inActiveWindow(String text, boolean click) {
        AccessibilityNodeInfo root = InstrumentationRegistry.getInstrumentation()
                .getUiAutomation().getRootInActiveWindow();
        if (root == null) return false;
        try {
            for (AccessibilityNodeInfo node : root.findAccessibilityNodeInfosByText(text)) {
                try {
                    if (!node.isVisibleToUser() || node.getText() == null) continue;
                    if (!click && node.getText().toString().contains(text)) return true;
                    if (click && text.contentEquals(node.getText()) && node.isClickable()
                            && node.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true;
                } finally { node.recycle(); }
            }
            return false;
        } finally { root.recycle(); }
    }

    @Test public void configuredDoubleTapTogglesOnlyAfterReleaseAndHoldingThenDraggingLooksAround() throws Exception {
        VrGestureSettings previous = VrGestureSettings.read(app);
        File file = fixture("sbs");
        new VrGestureSettings(VrGestureSettings.DoubleTap.PLAY_PAUSE, VrGestureSettings.Pinch.FINE).save(app);
        try (ActivityScenario<PlayerActivity> player = open(file)) {
            await("Movie didn't start", () -> seconds(player) >= 1);
            press(player, "进入 VR");
            MovieSurface movie = surface(player);
            // A stationary press followed by a drag must still turn the VR camera.
            long down = SystemClock.uptimeMillis();
            touchMovie(player, movie, down, MotionEvent.ACTION_DOWN, .74f);
            SystemClock.sleep(android.view.ViewConfiguration.getLongPressTimeout() + 75);
            touchMovie(player, movie, down, MotionEvent.ACTION_MOVE, .39f);
            touchMovie(player, movie, down, MotionEvent.ACTION_UP, .32f);
            try (Screen screen = new Screen(movie)) {
                screen.until("long hold then drag still looks right", (center, l, r) ->
                        Color.red(center) > 144 && near(Color.green(center), 128) && leftEye(center));
            }
            player.onActivity(a -> assertEquals("暂停", ((TextView) control(a, "播放或暂停")).getText().toString()));
            SystemClock.sleep(android.view.ViewConfiguration.getDoubleTapTimeout() + 75);
            down = SystemClock.uptimeMillis();
            touchMovie(player, movie, down, MotionEvent.ACTION_DOWN, .5f);
            touchMovie(player, movie, down, MotionEvent.ACTION_UP, .5f);
            SystemClock.sleep(75);
            down = SystemClock.uptimeMillis();
            touchMovie(player, movie, down, MotionEvent.ACTION_DOWN, .5f);
            player.onActivity(a -> assertEquals("Double tap paused before release", "暂停",
                    ((TextView) control(a, "播放或暂停")).getText().toString()));
            touchMovie(player, movie, down, MotionEvent.ACTION_UP, .5f);
            SystemClock.sleep(android.view.ViewConfiguration.getDoubleTapTimeout() + 75);
            player.onActivity(a -> assertEquals("Double tap did not pause exactly once", "播放",
                    ((TextView) control(a, "播放或暂停")).getText().toString()));
        } finally { previous.save(app); file.delete(); }
    }

    private static void touchMovie(ActivityScenario<PlayerActivity> scene, MovieSurface movie, long down,
                                   int action, float xFraction) {
        scene.onActivity(a -> {
            MotionEvent event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action,
                    xFraction * movie.getWidth(), .5f * movie.getHeight(), 0);
            event.setSource(android.view.InputDevice.SOURCE_TOUCHSCREEN);
            try { movie.dispatchTouchEvent(event); } finally { event.recycle(); }
        });
    }

    private File fixture(String packing) throws Exception {
        File file = File.createTempFile("viewer-", ".mp4", app.getCacheDir());
        try (InputStream in = InstrumentationRegistry.getInstrumentation().getContext()
                .getAssets().open("vr-chart-" + packing + ".mp4")) {
            Files.copy(in, file.toPath(), StandardCopyOption.REPLACE_EXISTING);
        }
        return file;
    }

    private ActivityScenario<PlayerActivity> open(File file) {
        return ActivityScenario.launch(new Intent(app, PlayerActivity.class)
                .setData(Uri.fromFile(file)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
    }

    private static void view(ActivityScenario<PlayerActivity> player, MovieSurface movie,
                             VrFormat.Projection projection, VrFormat.Layout layout,
                             boolean headset, float yaw, float pitch) {
        float[] camera = new float[16];
        Matrix.setIdentityM(camera, 0);
        Matrix.rotateM(camera, 0, -yaw, 0, 1, 0);
        Matrix.rotateM(camera, 0, pitch, 1, 0, 0);
        player.onActivity(a -> {
            movie.setFormat(new VrFormat(projection, layout, headset));
            movie.setViewOrientation(camera);
        });
    }

    private static MovieSurface surface(ActivityScenario<PlayerActivity> player) {
        AtomicReference<MovieSurface> result = new AtomicReference<>();
        player.onActivity(a -> result.set((MovieSurface) control(a, "视频画面")));
        return result.get();
    }

    private static long seconds(ActivityScenario<PlayerActivity> player) {
        AtomicInteger result = new AtomicInteger();
        player.onActivity(a -> {
            SeekBar slider = (SeekBar) control(a, "播放进度");
            String label = ((TextView) ((LinearLayout) slider.getParent()).getChildAt(0)).getText().toString();
            int t = 0;
            for (String field : label.split(":")) t = t * 60 + Integer.parseInt(field);
            result.set(t);
        });
        return result.get();
    }

    private static View control(PlayerActivity activity, String name) {
        View found = find(activity.findViewById(android.R.id.content), name);
        assertNotNull("Missing player control: " + name, found);
        return found;
    }

    private static View find(View v, String name) {
        if (name.equals(v.getContentDescription())) return v;
        if (v instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) v;
            for (int i = 0; i < group.getChildCount(); i++) {
                View match = find(group.getChildAt(i), name);
                if (match != null) return match;
            }
        }
        return null;
    }

    private static void press(ActivityScenario<PlayerActivity> player, String label) {
        player.onActivity(a -> {
            View button = control(a, label);
            if (!button.isShown()) control(a, "视频画面").performClick();
            assertTrue("Hidden control: " + label, button.isShown());
            assertTrue("Inactive control: " + label, button.performClick());
        });
    }

    private static void swipeLeft(ActivityScenario<PlayerActivity> player, MovieSurface movie) {
        int[] bounds = new int[4];
        player.onActivity(a -> {
            int[] origin = new int[2];
            movie.getLocationOnScreen(origin);
            bounds[0] = origin[0]; bounds[1] = origin[1];
            bounds[2] = movie.getWidth(); bounds[3] = movie.getHeight();
        });
        float cx = bounds[0] + bounds[2] * .5f, cy = bounds[1] + bounds[3] * .5f;
        float distance = Math.min(bounds[2], bounds[3]) * .68f;
        long down = SystemClock.uptimeMillis();
        for (int i = 0; i <= 8; i++) {
            int action = i == 0 ? MotionEvent.ACTION_DOWN : i == 8 ? MotionEvent.ACTION_UP : MotionEvent.ACTION_MOVE;
            MotionEvent event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action,
                    cx + (.5f - i / 8f) * distance, cy, 0);
            event.setSource(android.view.InputDevice.SOURCE_TOUCHSCREEN);
            try { InstrumentationRegistry.getInstrumentation().sendPointerSync(event); }
            finally { event.recycle(); }
            SystemClock.sleep(20);
        }
    }

    private interface Probe { boolean ready() throws Exception; }

    private static void await(String why, Probe probe) throws Exception {
        long deadline = SystemClock.uptimeMillis() + 10000;
        while (SystemClock.uptimeMillis() < deadline) {
            if (probe.ready()) return;
            SystemClock.sleep(100);
        }
        fail(why);
    }

    private interface Colors { boolean match(int center, int left, int right); }

    private static final class Screen implements AutoCloseable {
        final MovieSurface movie;
        final Bitmap bitmap = Bitmap.createBitmap(192, 96, Bitmap.Config.ARGB_8888);
        final Handler main = new Handler(Looper.getMainLooper());
        Screen(MovieSurface movie) { this.movie = movie; }

        void frontMotion() throws Exception {
            boolean[] seen = new boolean[2];
            until("forward left view must keep changing", (center, l, r) -> {
                if (at(center, .50, .50) && leftEye(center)) seen[Color.blue(center) < 57 ? 0 : 1] = true;
                return seen[0] && seen[1];
            });
        }

        void single(String label, double u, double v) throws Exception {
            until(label, (center, l, r) -> at(center, u, v) && leftEye(center));
        }

        void eyes(String label, double u, double v) throws Exception {
            until(label, (center, l, r) -> at(l, u, v) && at(r, u, v) && leftEye(l) && rightEye(r));
        }

        void until(String label, Colors colors) throws Exception {
            long deadline = SystemClock.uptimeMillis() + 8000;
            int center = 0, left = 0, right = 0;
            while (SystemClock.uptimeMillis() < deadline) {
                if (movie.getHolder().getSurface().isValid()) {
                    AtomicInteger status = new AtomicInteger();
                    CountDownLatch copied = new CountDownLatch(1);
                    PixelCopy.request(movie, bitmap, code -> { status.set(code); copied.countDown(); }, main);
                    assertTrue("Pixel copy timed out", copied.await(3, TimeUnit.SECONDS));
                    if (status.get() == PixelCopy.SUCCESS) {
                        center = bitmap.getPixel(96, 48);
                        left = bitmap.getPixel(48, 48);
                        right = bitmap.getPixel(144, 48);
                        if (colors.match(center, left, right)) return;
                    }
                }
                SystemClock.sleep(90);
            }
            fail(label + ": center/left/right RGB = " + Integer.toHexString(center) + "/"
                    + Integer.toHexString(left) + "/" + Integer.toHexString(right));
        }
        @Override public void close() { bitmap.recycle(); }
    }

    // Quantization, chroma subsampling and emulator display color conversion
    // are allowed; reversing a coordinate or confusing eyes is not.
    private static boolean at(int color, double u, double v) {
        return near(Color.red(color), (int) Math.round(32 + 192*u))
                && near(Color.green(color), (int) Math.round(32 + 192*v));
    }
    private static boolean near(int actual, int expected) { return Math.abs(actual - expected) <= 13; }
    private static boolean leftEye(int color) { return Color.blue(color) >= 15 && Color.blue(color) <= 95; }
    private static boolean rightEye(int color) { return Color.blue(color) >= 144 && Color.blue(color) <= 224; }
    private static boolean black(int color) {
        return Color.red(color) < 9 && Color.green(color) < 9 && Color.blue(color) < 9;
    }
}
