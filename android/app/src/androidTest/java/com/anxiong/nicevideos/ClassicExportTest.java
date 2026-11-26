package com.anxiong.nicevideos;

import android.app.Instrumentation;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.os.SystemClock;
import android.provider.DocumentsContract;
import android.provider.MediaStore;
import android.view.accessibility.AccessibilityNodeInfo;
import androidx.test.core.app.ActivityScenario;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.filters.SdkSuppress;
import androidx.test.platform.app.InstrumentationRegistry;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.charset.StandardCharsets;
import java.util.HashSet;
import java.util.Set;
import java.util.UUID;
import org.json.JSONObject;
import org.junit.Test;
import org.junit.runner.RunWith;
import static org.junit.Assert.*;

@RunWith(AndroidJUnit4.class)
@SdkSuppress(minSdkVersion = 29)
public final class ClassicExportTest {
    private final Context app = InstrumentationRegistry.getInstrumentation().getTargetContext();
    private final VideoLibrary library = new VideoLibrary(app);
    private final Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();

    /** The on-disk catalog format of both published 83,397-byte APKs. */
    private VideoLibrary.Entry legacy(String name, byte[] data, long expectedSize) throws Exception {
        String id = UUID.randomUUID().toString();
        JSONObject row = new JSONObject().put("id", id).put("name", name).put("disk", id + ".mp4")
                .put("bytes", expectedSize).put("source", "https://example.invalid/" + id)
                .put("favorite", true).put("time", 123456789L).put("state", VideoLibrary.READY);
        assertTrue(library.prefs.edit().putString("movie." + id, row.toString()).commit());
        VideoLibrary.Entry entry = library.find(id);
        Files.write(library.file(entry).toPath(), data);
        return entry;
    }

    private void assertBytes(Uri uri, byte[] expected) throws Exception {
        try (InputStream in = app.getContentResolver().openInputStream(uri)) {
            assertNotNull(in);
            for (byte b : expected) assertEquals(b & 0xff, in.read());
            assertEquals(-1, in.read());
        }
    }

    private void clickControl(String label) {
        long timeout = SystemClock.elapsedRealtime() + 15000;
        do {
            AccessibilityNodeInfo root = instrumentation.getUiAutomation().getRootInActiveWindow();
            if (root != null) {
                for (AccessibilityNodeInfo item : root.findAccessibilityNodeInfosByText(label)) {
                    if (item.getText() != null && label.equalsIgnoreCase(item.getText().toString()) &&
                            item.isEnabled() && item.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return;
                }
            }
            SystemClock.sleep(100);
        } while (SystemClock.elapsedRealtime() < timeout);
        fail("Missing enabled UI control: " + label);
    }

    private Set<String> exportNames(Uri tree) {
        Uri children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree));
        Set<String> names = new HashSet<>();
        try (Cursor c = app.getContentResolver().query(children,
                new String[]{DocumentsContract.Document.COLUMN_DISPLAY_NAME}, null, null, null)) {
            assertNotNull(c);
            while (c.moveToNext()) names.add(c.getString(0));
        } catch (SecurityException waitingForGrant) {
            // The picker may still be returning its URI grant to MainActivity.
        }
        return names;
    }

    @Test public void systemFolderExportCopiesOriginalDownloadsAndPreservesHistory() throws Exception {
        String folder = "NiceExport-" + UUID.randomUUID();
        String folderId = "primary:Download/" + folder;
        String authority = "com.android.externalstorage.documents";
        Uri initial = DocumentsContract.buildDocumentUri(authority, folderId);
        Uri tree = DocumentsContract.buildTreeDocumentUri(authority, folderId);
        String firstName = "Private #.mp4";
        String secondName = "另一部影片-" + UUID.randomUUID() + ".mp4";
        byte[] original = "old".getBytes(StandardCharsets.UTF_8);
        byte[] other = {6, 7, 8, 9};
        VideoLibrary.Entry old = legacy(firstName, original, original.length);
        VideoLibrary.Entry second = legacy(secondName, other, other.length);
        String position = UUID.nameUUIDFromBytes(library.uri(old).toString().getBytes(StandardCharsets.UTF_8)).toString();
        SharedPreferences bookmarks = app.getSharedPreferences("video_positions", Context.MODE_PRIVATE);
        Uri occupied = null;
        Instrumentation.ActivityMonitor picker = new Instrumentation.ActivityMonitor() {
            @Override public Instrumentation.ActivityResult onStartActivity(Intent intent) {
                if (Intent.ACTION_OPEN_DOCUMENT_TREE.equals(intent.getAction())) {
                    // Start the real DocumentsUI in a unique folder; it grants the URI to the app.
                    intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI, initial);
                }
                return null;
            }
        };
        try {
            assertTrue(bookmarks.edit().putLong(position, 12500L).commit());
            String oldRecord = library.prefs.getString("movie." + old.id, null);
            String secondRecord = library.prefs.getString("movie." + second.id, null);
            ContentValues occupiedValues = new ContentValues();
            occupiedValues.put(MediaStore.MediaColumns.DISPLAY_NAME, firstName);
            occupiedValues.put(MediaStore.MediaColumns.MIME_TYPE, "video/mp4");
            occupiedValues.put(MediaStore.MediaColumns.RELATIVE_PATH, "Download/" + folder + "/");
            occupied = app.getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, occupiedValues);
            assertNotNull(occupied);
            try (OutputStream out = app.getContentResolver().openOutputStream(occupied)) {
                assertNotNull(out);
                out.write("new".getBytes(StandardCharsets.UTF_8));
            }
            try (ActivityScenario<MainActivity> ignored = ActivityScenario.launch(MainActivity.class)) {
                instrumentation.addMonitor(picker);
                try {
                    clickControl("导出全部");
                    clickControl("Use this folder");
                    clickControl("Allow");
                } finally {
                    instrumentation.removeMonitor(picker);
                }
                String copy = "Private # (1).mp4";
                Uri copied = DocumentsContract.buildDocumentUriUsingTree(tree, folderId + "/" + copy);
                Uri secondCopy = DocumentsContract.buildDocumentUriUsingTree(tree, folderId + "/" + secondName);
                long timeout = SystemClock.elapsedRealtime() + 15000;
                Set<String> files = exportNames(tree);
                while (!(files.contains(copy) && files.contains(secondName)) && SystemClock.elapsedRealtime() < timeout) {
                    SystemClock.sleep(100);
                    files = exportNames(tree);
                }
                assertTrue("Expected both exports in " + files, files.contains(copy) && files.contains(secondName));
                assertBytes(occupied, "new".getBytes(StandardCharsets.UTF_8));
                assertBytes(copied, original);
                assertBytes(secondCopy, other);
                MovieExporter.Result repeated = new MovieExporter(library).export(old.id, tree);
                assertTrue(repeated.existing);
                assertEquals(copy, repeated.name);
                assertEquals(3, exportNames(tree).size());
                assertBytes(library.uri(second), other);
                assertArrayEquals(original, Files.readAllBytes(library.file(old).toPath()));
                assertEquals(12500L, bookmarks.getLong(position, 0));
                assertEquals(oldRecord, library.prefs.getString("movie." + old.id, null));
                assertEquals(secondRecord, library.prefs.getString("movie." + second.id, null));
            }
        } finally {
            bookmarks.edit().remove(position).commit();
            library.remove(library.find(old.id));
            library.remove(library.find(second.id));
            if (occupied != null) app.getContentResolver().delete(occupied, null, null);
            try (InputStream done = new ParcelFileDescriptor.AutoCloseInputStream(
                    instrumentation.getUiAutomation().executeShellCommand("rm -r /sdcard/Download/" + folder))) {
                while (done.read() != -1) { /* wait for the disposable test directory to be removed */ }
            }
        }
    }

}
