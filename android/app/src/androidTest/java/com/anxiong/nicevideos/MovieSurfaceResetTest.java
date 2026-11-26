package com.anxiong.nicevideos;

import static org.junit.Assert.*;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.PixelCopy;
import android.view.Surface;

import androidx.test.core.app.ActivityScenario;
import androidx.test.ext.junit.runners.AndroidJUnit4;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.Test;
import org.junit.runner.RunWith;

/** Exercises a replacement decoder target with real BufferQueues, GL draws and readback. */
@RunWith(AndroidJUnit4.class)
public final class MovieSurfaceResetTest {
    @Test public void replacementClearsCachedImageAndCountsOnlyNewProducerFrames() throws Exception {
        LinkedBlockingQueue<Surface> ready = new LinkedBlockingQueue<>();
        AtomicReference<MovieSurface> view = new AtomicReference<>();
        AtomicReference<String> error = new AtomicReference<>();
        AtomicInteger firstFrames = new AtomicInteger();
        try (ActivityScenario<MainActivity> scene = ActivityScenario.launch(MainActivity.class)) {
            scene.onActivity(activity -> {
                MovieSurface movie = new MovieSurface(activity, new MovieSurface.Listener() {
                    @Override public void onSurfaceReady(Surface surface) { ready.add(surface); }
                    @Override public void onRenderError(String detail) { error.set(detail); }
                    @Override public void onFirstFrameDrawn() { firstFrames.incrementAndGet(); }
                });
                view.set(movie);
                movie.expectNewDecoderFrame();
                movie.setVideoSize(16, 16);
                movie.setFormat(new VrFormat(VrFormat.Projection.EQUIRECT_360, VrFormat.Layout.SBS_FULL, false));
                activity.setContentView(movie);
            });
            MovieSurface movie = view.get();
            Surface first = ready.poll(12, TimeUnit.SECONDS);
            assertNotNull("First decoder target: " + error.get(), first);
            assertTrue(movie.maxTextureSize() > 0);
            postColor(first, Color.RED);
            awaitColor(movie, Color.RED, error);
            assertEquals(1, firstFrames.get());
            long samples = movie.presentedSamples();

            scene.onActivity(activity -> movie.requestFreshDecoderSurface());
            Surface replacement = ready.poll(10, TimeUnit.SECONDS);
            assertNotNull("Replacement decoder target: " + error.get(), replacement);
            assertNotSame(first, replacement);
            assertFalse(first.isValid());
            scene.onActivity(activity -> {
                movie.expectNewDecoderFrame();
                movie.setFieldOfView(70);
            });
            // There is no new decoder frame yet. A pose redraw must not surface the previous input.
            awaitColor(movie, Color.BLACK, error);
            assertEquals(samples, movie.presentedSamples());
            assertEquals(1, firstFrames.get());

            postColor(replacement, Color.GREEN);
            awaitColor(movie, Color.GREEN, error);
            assertEquals(samples + 1, movie.presentedSamples());
            assertEquals(2, firstFrames.get());
            assertNull(error.get());
        }
    }

    private static void postColor(Surface surface, int color) {
        Canvas canvas = surface.lockCanvas(null);
        try { canvas.drawColor(color); }
        finally { surface.unlockCanvasAndPost(canvas); }
    }

    private static void awaitColor(MovieSurface movie, int expected, AtomicReference<String> error)
            throws InterruptedException {
        Handler main = new Handler(Looper.getMainLooper());
        Bitmap image = Bitmap.createBitmap(16, 16, Bitmap.Config.ARGB_8888);
        try {
            long timeout = SystemClock.elapsedRealtime() + 6000;
            int actual = Color.TRANSPARENT;
            while (SystemClock.elapsedRealtime() < timeout) {
                assertNull(error.get());
                CountDownLatch done = new CountDownLatch(1);
                AtomicInteger status = new AtomicInteger(-1);
                PixelCopy.request(movie, image, result -> { status.set(result); done.countDown(); }, main);
                assertTrue("PixelCopy timed out", done.await(3, TimeUnit.SECONDS));
                if (status.get() == PixelCopy.SUCCESS) {
                    actual = image.getPixel(8, 8);
                    if (Math.abs(Color.red(actual) - Color.red(expected)) < 40
                            && Math.abs(Color.green(actual) - Color.green(expected)) < 40
                            && Math.abs(Color.blue(actual) - Color.blue(expected)) < 40) return;
                }
                SystemClock.sleep(60);
            }
            fail("Expected " + Integer.toHexString(expected) + ", saw " + Integer.toHexString(actual));
        } finally { image.recycle(); }
    }
}
