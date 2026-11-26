package com.anxiong.nicevideos;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Context;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;
import androidx.test.core.app.ActivityScenario;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import org.junit.Test;
import org.junit.runner.RunWith;
import java.io.File;
import java.io.FileOutputStream;
import java.io.FileNotFoundException;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import static org.junit.Assert.*;

@RunWith(AndroidJUnit4.class)
public final class HomeLibraryTest {
    private TextView find(View v, String text) {
        if (v instanceof TextView && text.contentEquals(((TextView) v).getText())) return (TextView) v;
        if (v instanceof ViewGroup) {
            ViewGroup group = (ViewGroup)v;
            for (int i = 0; i < group.getChildCount(); i++) {
                TextView found = find(group.getChildAt(i), text);
                if (found != null) return found;
            }
        }
        return null;
    }

    private void clickOpen(MainActivity activity) {
        TextView open = find(activity.getWindow().getDecorView(), "打开文件");
        assertNotNull(open);
        assertTrue(open.performClick());
    }

    @Test public void cancellingSystemPickerReturnsToLocalHome() {
        Instrumentation ins = InstrumentationRegistry.getInstrumentation();
        AtomicReference<Intent> launch = new AtomicReference<>();
        Instrumentation.ActivityMonitor monitor = new Instrumentation.ActivityMonitor() {
            @Override public Instrumentation.ActivityResult onStartActivity(Intent intent) {
                if (!Intent.ACTION_OPEN_DOCUMENT.equals(intent.getAction())) return null;
                launch.set(new Intent(intent));
                return new Instrumentation.ActivityResult(Activity.RESULT_CANCELED, null);
            }
        };
        try (ActivityScenario<MainActivity> scenario = ActivityScenario.launch(MainActivity.class)) {
            ins.addMonitor(monitor);
            try {
                scenario.onActivity(this::clickOpen);
                ins.waitForIdleSync();
                Intent request = launch.get();
                assertNotNull(request);
                assertTrue(request.hasCategory(Intent.CATEGORY_OPENABLE));
                assertTrue((request.getFlags() & Intent.FLAG_GRANT_READ_URI_PERMISSION) != 0);
                assertTrue((request.getFlags() & Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION) != 0);
                scenario.onActivity(a -> assertNotNull(find(a.getWindow().getDecorView(), "本地影片")));
            } finally { ins.removeMonitor(monitor); }
        }
    }

    @Test public void selectedDocumentReachesPlayerUnchangedAndOnlyCompleteCopiesCanOpen() throws Exception {
        Instrumentation ins = InstrumentationRegistry.getInstrumentation();
        Context app = ins.getTargetContext();
        VideoLibrary library = new VideoLibrary(app);
        VideoLibrary.Entry e = new VideoLibrary.Entry(UUID.randomUUID().toString());
        e.name = "test # 影片.mp4";
        e.disk = e.id + ".mp4";
        e.bytes = 3;
        e.state = VideoLibrary.TRANSFER;
        File file = library.file(e);
        try (FileOutputStream out = new FileOutputStream(file)) { out.write(new byte[]{1, 2, 3}); }
        library.save(e);
        Uri source = library.uri(e);
        try {
            try (ParcelFileDescriptor ignored = app.getContentResolver().openFileDescriptor(source, "r")) {
                fail("A partial download was exposed");
            } catch (FileNotFoundException expected) { }
            e.state = VideoLibrary.READY; library.save(e);
            try (ParcelFileDescriptor fd = app.getContentResolver().openFileDescriptor(source, "r")) {
                assertNotNull(fd); assertEquals(3L, fd.getStatSize());
            }
            try (Cursor metadata = app.getContentResolver().query(source, new String[]{OpenableColumns.DISPLAY_NAME},
                    null, null, null)) {
                assertNotNull(metadata); assertTrue(metadata.moveToFirst()); assertEquals(e.name, metadata.getString(0));
            }
            CountDownLatch handedOff = new CountDownLatch(1);
            AtomicReference<Intent> playback = new AtomicReference<>();
            Instrumentation.ActivityMonitor monitor = new Instrumentation.ActivityMonitor() {
                @Override public Instrumentation.ActivityResult onStartActivity(Intent intent) {
                    if (Intent.ACTION_OPEN_DOCUMENT.equals(intent.getAction())) {
                        return new Instrumentation.ActivityResult(Activity.RESULT_OK, new Intent().setData(source)
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION));
                    }
                    if (intent.getComponent() != null && PlayerActivity.class.getName().equals(intent.getComponent().getClassName())) {
                        playback.set(new Intent(intent)); handedOff.countDown();
                        return new Instrumentation.ActivityResult(Activity.RESULT_CANCELED, null);
                    }
                    return null;
                }
            };
            try (ActivityScenario<MainActivity> scenario = ActivityScenario.launch(MainActivity.class)) {
                ins.addMonitor(monitor);
                try {
                    scenario.onActivity(this::clickOpen);
                    assertTrue("System document was never forwarded", handedOff.await(8, TimeUnit.SECONDS));
                    assertEquals(source, playback.get().getData());
                    assertEquals(e.name, playback.get().getStringExtra("title"));
                    try (ParcelFileDescriptor fd = app.getContentResolver().openFileDescriptor(source, "r")) {
                        assertNotNull(fd);
                        assertEquals(3L, fd.getStatSize());
                    }
                } finally { ins.removeMonitor(monitor); }
            }
        } finally {
            library.remove(e);
            for (VideoLibrary.Entry recent : library.all()) if (recent.document.equals(source.toString())) library.remove(recent);
        }
    }
}
