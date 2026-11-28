package com.anxiong.nicevideos;

import static org.junit.Assert.*;

import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.PixelCopy;
import android.view.View;
import android.view.ViewGroup;

import androidx.test.core.app.ActivityScenario;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;

import org.junit.Test;
import org.junit.runner.RunWith;

import java.io.File;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/** Checks colors actually rendered by the player; elapsed time alone is insufficient. */
@RunWith(AndroidJUnit4.class)
public class MovieMotionTest {
    @Test public void movingPixelsKeepTheCorrectEyeAndAspectAcrossModeChanges() throws Exception {
        Context app = InstrumentationRegistry.getInstrumentation().getTargetContext();
        File clip = File.createTempFile("stereo-motion-", ".mp4", app.getCacheDir());
        try {
            try (InputStream source = InstrumentationRegistry.getInstrumentation().getContext()
                    .getAssets().open("moving-sbs.mp4")) {
                Files.copy(source, clip.toPath(), StandardCopyOption.REPLACE_EXISTING);
            }
            Intent intent = new Intent(app, PlayerActivity.class)
                    .setData(Uri.fromFile(clip)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            try (ActivityScenario<PlayerActivity> player = ActivityScenario.launch(intent)) {
                AtomicReference<MovieSurface> surface = new AtomicReference<>();
                player.onActivity(activity -> surface.set(findMovie(activity.getWindow().getDecorView())));
                MovieSurface movie = surface.get();
                assertNotNull("Player's GL surface is missing", movie);
                requireMotion(movie, "ordinary");
                player.onActivity(activity -> movie.setMode(MovieSurface.Mode.HALF));
                double halfAspect = requireMotion(movie, "half SBS");
                player.onActivity(activity -> movie.setMode(MovieSurface.Mode.FULL));
                double fullAspect = requireMotion(movie, "full SBS");
                assertTrue("Half SBS should expand each eye relative to full SBS: " + halfAspect + "/" + fullAspect,
                        halfAspect > 1.25 * fullAspect);
                player.onActivity(activity -> movie.setMode(MovieSurface.Mode.STANDARD));
                requireMotion(movie, "back to ordinary");
            }
        } finally {
            clip.delete();
        }
    }

    private static MovieSurface findMovie(View view) {
        if (view instanceof MovieSurface) return (MovieSurface) view;
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) view;
            for (int i = 0; i < group.getChildCount(); i++) {
                MovieSurface found = findMovie(group.getChildAt(i));
                if (found != null) return found;
            }
        }
        return null;
    }

    private static double requireMotion(MovieSurface surface, String description) throws Exception {
        int phases = 0, left = 0, right = 0, copyStatus = -1;
        long deadline = SystemClock.elapsedRealtime() + 18000;
        Handler main = new Handler(Looper.getMainLooper());
        Bitmap image = Bitmap.createBitmap(240, 240, Bitmap.Config.ARGB_8888);
        try {
            while (SystemClock.elapsedRealtime() < deadline) {
                if (surface.getHolder().getSurface().isValid()) {
                    AtomicInteger status = new AtomicInteger();
                    CountDownLatch copied = new CountDownLatch(1);
                    PixelCopy.request(surface, image, result -> { status.set(result); copied.countDown(); }, main);
                    assertTrue("Screen copy did not finish", copied.await(3, TimeUnit.SECONDS));
                    copyStatus = status.get();
                    if (copyStatus == PixelCopy.SUCCESS) {
                        left = image.getPixel(60, 120);
                        right = image.getPixel(180, 120);
                        if (Color.red(left) > 140 && Color.green(left) < 85 && Color.blue(left) < 85 &&
                                Color.blue(right) > 140 && Color.red(right) < 85 && Color.green(right) < 85) phases |= 1;
                        if (Color.green(left) > 140 && Color.red(left) < 85 && Color.blue(left) < 85 &&
                                Color.red(right) > 140 && Color.green(right) > 140 && Color.blue(right) < 85) phases |= 2;
                        if (phases == 3) {
                            int width = 0, height = 0;
                            for (int x = 0; x < 120; x++) if (colored(image.getPixel(x, 120))) width++;
                            for (int y = 0; y < 240; y++) if (colored(image.getPixel(60, y))) height++;
                            return (double) width / height;
                        }
                    }
                }
                SystemClock.sleep(90);
            }
            throw new AssertionError(description + ": missing moving eye colors, phases=" + phases
                    + ", RGB=" + Integer.toHexString(left) + "/" + Integer.toHexString(right)
                    + ", PixelCopy=" + copyStatus);
        } finally {
            image.recycle();
        }
    }

    private static boolean colored(int pixel) {
        return Math.max(Color.red(pixel), Math.max(Color.green(pixel), Color.blue(pixel))) > 100;
    }
}
