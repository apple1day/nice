package com.anxiong.nicevideos;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.SystemClock;
import android.provider.DocumentsContract;
import android.provider.MediaStore;
import android.view.View;
import android.view.ViewGroup;
import android.view.accessibility.AccessibilityNodeInfo;
import android.widget.TextView;
import androidx.test.core.app.ActivityScenario;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.filters.SdkSuppress;
import androidx.test.platform.app.InstrumentationRegistry;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.Test;
import org.junit.runner.RunWith;
import static org.junit.Assert.*;

@RunWith(AndroidJUnit4.class)
@SdkSuppress(minSdkVersion = 29)
public final class VrFolderLibraryTest {
    private final Instrumentation ins = InstrumentationRegistry.getInstrumentation();
    private final Context context = ins.getTargetContext();

    private void click(String label) {
        long deadline = SystemClock.elapsedRealtime() + 15000;
        do {
            AccessibilityNodeInfo root = ins.getUiAutomation().getRootInActiveWindow();
            if (root != null) {
                for (AccessibilityNodeInfo item : root.findAccessibilityNodeInfosByText(label)) {
                    if (item.getText() == null || !label.equalsIgnoreCase(item.getText().toString())) continue;
                    for (AccessibilityNodeInfo target = item; target != null; target = target.getParent()) {
                        if (target.isClickable() && target.isEnabled() && target.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return;
                    }
                }
            }
            SystemClock.sleep(100);
        } while (SystemClock.elapsedRealtime() < deadline);
        fail("Missing control: " + label);
    }

    private View label(View view, String name) {
        if (view instanceof TextView && name.contentEquals(((TextView)view).getText())) return view;
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup)view;
            for (int i = 0; i < group.getChildCount(); i++) {
                View match = label(group.getChildAt(i), name);
                if (match != null) return match;
            }
        }
        return null;
    }

    private void clickRow(ActivityScenario<MainActivity> scenario, String name) {
        long deadline = SystemClock.elapsedRealtime() + 15000;
        AtomicBoolean clicked = new AtomicBoolean();
        do {
            scenario.onActivity(activity -> {
                View cell = label(activity.getWindow().getDecorView(), name);
                while (cell != null && !cell.isClickable())
                    cell = cell.getParent() instanceof View ? (View)cell.getParent() : null;
                if (cell != null) clicked.set(cell.performClick());
            });
            if (clicked.get()) return;
            SystemClock.sleep(100);
        } while (SystemClock.elapsedRealtime() < deadline);
        fail("Missing folder entry: " + name);
    }

    private Uri file(String path, String name, String mime) throws Exception {
        ContentValues values = new ContentValues();
        values.put(MediaStore.MediaColumns.DISPLAY_NAME, name);
        values.put(MediaStore.MediaColumns.RELATIVE_PATH, path);
        values.put(MediaStore.MediaColumns.MIME_TYPE, mime);
        Uri uri = context.getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
        assertNotNull(uri);
        try (OutputStream out = context.getContentResolver().openOutputStream(uri)) {
            assertNotNull(out); out.write(new byte[]{8, 6, 4, 2});
        }
        return uri;
    }

    @Test public void grantedFolderOpensNestedMovieInVrAndSurvivesActivityRecreation() throws Exception {
        String folder = "Nice-VR-" + UUID.randomUUID();
        String relative = "Download/" + folder + "/";
        String rootId = "primary:Download/" + folder;
        String sub = "SBS", name = "Space #1.mp4";
        String authority = "com.android.externalstorage.documents";
        Uri root = DocumentsContract.buildTreeDocumentUri(authority, rootId);
        Uri initial = DocumentsContract.buildDocumentUri(authority, rootId);
        Uri movie = file(relative + sub + "/", name, "video/mp4");
        Uri note = file(relative, "notes.txt", "text/plain");
        AtomicReference<Intent> opened = new AtomicReference<>();
        CountDownLatch played = new CountDownLatch(1);
        Instrumentation.ActivityMonitor monitor = new Instrumentation.ActivityMonitor() {
            @Override public Instrumentation.ActivityResult onStartActivity(Intent intent) {
                if (Intent.ACTION_OPEN_DOCUMENT_TREE.equals(intent.getAction()))
                    intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI, initial);
                if (intent.getComponent() != null && PlayerActivity.class.getName().equals(intent.getComponent().getClassName())) {
                    opened.set(new Intent(intent)); played.countDown();
                    return new Instrumentation.ActivityResult(Activity.RESULT_CANCELED, null);
                }
                return null;
            }
        };
        VrFolderLibrary folders = new VrFolderLibrary(context);
        try (ActivityScenario<MainActivity> activity = ActivityScenario.launch(MainActivity.class)) {
            ins.addMonitor(monitor);
            click("VR"); click("添加文件夹"); click("Use this folder"); click("Allow");
            clickRow(activity, sub);
            activity.recreate();
            clickRow(activity, name);
            assertTrue(played.await(8, TimeUnit.SECONDS));
            Intent sent = opened.get();
            Uri expected = DocumentsContract.buildDocumentUriUsingTree(root, rootId + "/" + sub + "/" + name);
            assertEquals(expected, sent.getData());
            assertTrue(sent.getBooleanExtra(PlayerActivity.EXTRA_START_IN_VR, false));
            assertEquals(name, sent.getStringExtra("title"));
            try (InputStream in = context.getContentResolver().openInputStream(sent.getData())) {
                assertNotNull(in); assertEquals(8, in.read());
            }
            assertTrue(folders.roots().stream().anyMatch(item -> root.equals(item.uri)));
            List<VrFolderLibrary.Item> items = folders.children(root, rootId, new android.os.CancellationSignal());
            assertEquals(1, items.size()); assertEquals(sub, items.get(0).name); assertTrue(items.get(0).folder);
        } finally {
            ins.removeMonitor(monitor);
            folders.forget(root);
            context.getContentResolver().delete(note, null, null);
            context.getContentResolver().delete(movie, null, null);
        }
    }
}
