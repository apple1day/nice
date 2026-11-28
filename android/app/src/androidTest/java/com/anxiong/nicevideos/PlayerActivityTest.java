package com.anxiong.nicevideos;

import static org.junit.Assert.*;

import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.provider.MediaStore;
import android.view.PixelCopy;
import android.view.View;
import android.view.ViewGroup;
import android.view.accessibility.AccessibilityNodeInfo;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.SeekBar;
import android.widget.TextView;

import androidx.test.core.app.ActivityScenario;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.filters.SdkSuppress;
import androidx.test.platform.app.InstrumentationRegistry;

import org.junit.Test;
import org.junit.runner.RunWith;

import java.io.File;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.FileOutputStream;
import java.io.FileInputStream;
import java.io.RandomAccessFile;
import java.util.UUID;

import static org.junit.Assume.assumeTrue;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

@RunWith(AndroidJUnit4.class)
public class PlayerActivityTest {
    private final Context app = InstrumentationRegistry.getInstrumentation().getTargetContext();
    private final Context tests = InstrumentationRegistry.getInstrumentation().getContext();

    private ActivityScenario<PlayerActivity> launch(Uri uri) {
        Intent intent = new Intent(app, PlayerActivity.class).setData(uri).putExtra("title", "测试影片")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_GRANT_READ_URI_PERMISSION);
        return ActivityScenario.launch(intent);
    }

    @Test @SdkSuppress(minSdkVersion = 29)
    public void opensContentUriAndOperatesRealPlaybackControls() throws Exception {
        ContentValues entry = new ContentValues();
        entry.put(MediaStore.Video.Media.DISPLAY_NAME, "nice-playback-" + System.nanoTime() + ".mp4");
        entry.put(MediaStore.Video.Media.MIME_TYPE, "video/mp4");
        entry.put(MediaStore.Video.Media.RELATIVE_PATH, "Movies/NiceVideosTests");
        entry.put(MediaStore.Video.Media.IS_PENDING, 1);
        Uri uri = app.getContentResolver().insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, entry);
        assertNotNull(uri);
        try {
            try (InputStream in = tests.getAssets().open("moving-sbs.mp4");
                 OutputStream out = app.getContentResolver().openOutputStream(uri)) {
                assertNotNull(out);
                byte[] buffer = new byte[64 * 1024];
                for (int n; (n = in.read(buffer)) >= 0;) out.write(buffer, 0, n);
            }
            entry.clear();
            entry.put(MediaStore.Video.Media.IS_PENDING, 0);
            app.getContentResolver().update(uri, entry, null, null);
            try (ActivityScenario<PlayerActivity> scene = launch(uri)) {
                waitFor(scene, "content URI is playing", a -> elapsed(a) >= 1);
                scene.onActivity(a -> find(a, "播放或暂停").performClick());
                waitFor(scene, "paused", a -> ((Button) find(a, "播放或暂停")).getText().equals("播放"));
                scene.onActivity(a -> find(a, "快进15秒").performClick());
                waitFor(scene, "paused seek", a -> elapsed(a) >= 15);
                scene.onActivity(a -> find(a, "后退15秒").performClick());
                waitFor(scene, "backward seek", a -> elapsed(a) < 10);
                scene.onActivity(a -> find(a, "播放或暂停").performClick());
                waitFor(scene, "resumed", a -> ((Button) find(a, "播放或暂停")).getText().equals("暂停"));
            }
        } finally { app.getContentResolver().delete(uri, null, null); }
    }

    @Test public void decodesAndSeeksPastFourGiBFileOffsets() throws Exception {
        File clip = File.createTempFile("co64-", ".mp4", app.getCacheDir());
        try {
            try (FileOutputStream output = new FileOutputStream(clip)) {
                append(output, "co64-index.bin");
                output.getChannel().position(1L << 32);
                append(output, "co64-samples.bin");
            }
            assertTrue(clip.length() > (1L << 32));
            verifyLargeMovie(Uri.fromFile(clip));
        } finally { clip.delete(); }
    }

    @Test public void migratesAndSeeksInAnOfflineMovieLargerThanFourGiB() throws Exception {
        VideoLibrary library = new VideoLibrary(app);
        VideoLibrary.Entry entry = new VideoLibrary.Entry(UUID.randomUUID().toString());
        entry.name = "旧版大影片-" + entry.id + ".mp4";
        entry.disk = entry.id + ".mp4";
        File source = library.file(entry);
        final long sampleOffset = 1L << 32;
        byte[] expected = new byte[32];
        LegacyDownloadMigration migration = new LegacyDownloadMigration(library);
        if (android.os.Build.VERSION.SDK_INT < 29) {
            InstrumentationRegistry.getInstrumentation().getUiAutomation().grantRuntimePermission(
                    app.getPackageName(), android.Manifest.permission.WRITE_EXTERNAL_STORAGE);
        }
        try {
            try (FileOutputStream output = new FileOutputStream(source)) {
                append(output, "co64-index.bin");
                output.getChannel().position(sampleOffset);
                append(output, "co64-samples.bin");
            }
            entry.bytes = source.length();
            assertTrue(entry.bytes > sampleOffset + expected.length);
            long free = source.getParentFile().getUsableSpace();
            assumeTrue("Full migration needs room for a streamed copy: " + entry.bytes
                    + " bytes plus filesystem overhead, available: " + free,
                    free >= entry.bytes + (128L << 20));
            try (RandomAccessFile original = new RandomAccessFile(source, "r")) {
                original.seek(sampleOffset);
                original.readFully(expected);
            }
            assertTrue(library.saveCommitted(entry));
            Uri playback = library.uri(entry);
            assertTrue(migration.migrate(entry.id));
            VideoLibrary.Entry migrated = library.find(entry.id);
            assertNotNull(migrated);
            assertTrue(migrated.publicDownload);
            assertEquals(entry.bytes, migrated.bytes);
            assertEquals(playback, library.uri(migrated));
            assertFalse(source.exists());
            ParcelFileDescriptor descriptor = app.getContentResolver()
                    .openFileDescriptor(Uri.parse(migrated.publicUri), "r");
            assertNotNull(descriptor);
            assertEquals(entry.bytes, descriptor.getStatSize());
            try (FileInputStream input = new ParcelFileDescriptor.AutoCloseInputStream(descriptor)) {
                input.getChannel().position(sampleOffset);
                byte[] actual = new byte[expected.length];
                new java.io.DataInputStream(input).readFully(actual);
                assertArrayEquals(expected, actual);
            }
            verifyLargeMovie(playback);
        } finally {
            library.remove(entry);
            source.delete();
            migration.recover();
        }
    }

    @Test @SdkSuppress(minSdkVersion = 29)
    public void readsLargeVideoInPlaceFromAnAndroidContentProvider() throws Exception {
        ContentValues values = new ContentValues();
        values.put(MediaStore.Video.Media.DISPLAY_NAME, "nice-co64-" + System.nanoTime() + ".mp4");
        values.put(MediaStore.Video.Media.MIME_TYPE, "video/mp4");
        values.put(MediaStore.Video.Media.RELATIVE_PATH, "Movies/NiceVideosTests");
        values.put(MediaStore.Video.Media.IS_PENDING, 1);
        Uri uri = app.getContentResolver().insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values);
        assertNotNull(uri);
        try {
            ParcelFileDescriptor fd = app.getContentResolver().openFileDescriptor(uri, "rw");
            assertNotNull(fd);
            try (FileOutputStream stream = new ParcelFileDescriptor.AutoCloseOutputStream(fd)) {
                append(stream, "co64-index.bin");
                stream.getChannel().position(1L << 32);
                append(stream, "co64-samples.bin");
                assertTrue(stream.getChannel().size() > (1L << 32));
            }
            values.clear();
            values.put(MediaStore.Video.Media.IS_PENDING, 0);
            app.getContentResolver().update(uri, values, null, null);
            verifyLargeMovie(uri);
        } finally { app.getContentResolver().delete(uri, null, null); }
    }

    private void verifyLargeMovie(Uri uri) throws Exception {
        try (ActivityScenario<PlayerActivity> scene = launch(uri)) {
            waitFor(scene, "large movie clock advances", a -> elapsed(a) >= 1);
            assertTrue("Decoded color pattern at a sample offset beyond 4 GiB", hasColorFrame(scene));
            scene.onActivity(a -> {
                SeekBar seek = (SeekBar) find(a, "播放进度");
                Bundle b = new Bundle();
                b.putFloat(AccessibilityNodeInfo.ACTION_ARGUMENT_PROGRESS_VALUE, 0.6f * seek.getMax());
                assertTrue(seek.performAccessibilityAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_PROGRESS.getId(), b));
            });
            waitFor(scene, "clock after 60% seek", a -> elapsed(a) >= 6);
            assertTrue("Video continues after seeking into 64-bit samples", hasColorFrame(scene));
        }
    }

    private void append(OutputStream target, String asset) throws Exception {
        try (InputStream in = tests.getAssets().open(asset)) {
            byte[] buffer = new byte[64 * 1024];
            for (int n; (n = in.read(buffer)) >= 0;) target.write(buffer, 0, n);
        }
    }

    private static boolean hasColorFrame(ActivityScenario<PlayerActivity> scene) throws Exception {
        long deadline = SystemClock.uptimeMillis() + 7500;
        while (SystemClock.uptimeMillis() < deadline) {
            Bitmap shot = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888);
            CountDownLatch copied = new CountDownLatch(1);
            AtomicInteger result = new AtomicInteger(-1);
            scene.onActivity(a -> {
                MovieSurface movie = (MovieSurface) find(a, "视频画面");
                PixelCopy.request(movie, shot, r -> { result.set(r); copied.countDown(); }, new Handler(Looper.getMainLooper()));
            });
            assertTrue(copied.await(3, TimeUnit.SECONDS));
            Set<Integer> colors = new HashSet<>();
            if (result.get() == PixelCopy.SUCCESS) {
                for (int y = 0; y < 96; y += 2) for (int x = 0; x < 96; x += 2) {
                    int p = shot.getPixel(x, y), r = Color.red(p), g = Color.green(p), b = Color.blue(p);
                    if (Math.max(r, Math.max(g,b)) - Math.min(r, Math.min(g,b)) > 60)
                        colors.add(((r >> 6) << 4) | ((g >> 6) << 2) | (b >> 6));
                }
            }
            shot.recycle();
            if (colors.size() > 3) return true;
            SystemClock.sleep(120);
        }
        return false;
    }

    private interface Check { boolean evaluate(PlayerActivity activity); }

    private static void waitFor(ActivityScenario<PlayerActivity> scene, String description, Check condition) {
        long end = SystemClock.uptimeMillis() + 15000;
        AtomicBoolean done = new AtomicBoolean();
        while (!done.get() && SystemClock.uptimeMillis() < end) {
            scene.onActivity(a -> done.set(condition.evaluate(a)));
            if (!done.get()) SystemClock.sleep(120);
        }
        assertTrue(description, done.get());
    }

    private static long elapsed(PlayerActivity a) {
        SeekBar bar = (SeekBar) find(a, "播放进度");
        TextView elapsed = (TextView) ((LinearLayout) bar.getParent()).getChildAt(0);
        long sum = 0;
        for (String part : elapsed.getText().toString().split(":")) sum = sum * 60 + Long.parseLong(part);
        return sum;
    }

    private static View find(PlayerActivity a, String label) { return find(a.findViewById(android.R.id.content), label); }
    private static View find(View view, String label) {
        if (label.contentEquals(view.getContentDescription() == null ? "" : view.getContentDescription())) return view;
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) view;
            for (int index = 0; index < group.getChildCount(); index++) {
                View child = find(group.getChildAt(index), label);
                if (child != null) return child;
            }
        }
        return null;
    }
}
