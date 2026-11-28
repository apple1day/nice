package com.anxiong.nicevideos;

import android.app.Instrumentation;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.Environment;
import android.os.ParcelFileDescriptor;
import android.os.SystemClock;
import android.provider.DocumentsContract;
import android.provider.MediaStore;
import android.view.accessibility.AccessibilityNodeInfo;
import androidx.test.core.app.ActivityScenario;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.filters.SdkSuppress;
import androidx.test.platform.app.InstrumentationRegistry;
import java.io.File;
import java.io.IOException;
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
public final class LegacyDownloadMigrationTest {
    private final Context app = InstrumentationRegistry.getInstrumentation().getTargetContext();
    private final VideoLibrary library = new VideoLibrary(app);
    private final LegacyDownloadMigration migration = new LegacyDownloadMigration(library);
    private static final String RELATIVE_PATH = Environment.DIRECTORY_DOWNLOADS + "/NiceVideos/";
    private final Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();

    /** A record serialized with the 1.2.0 schema, before public location fields existed. */
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

    @Test public void migratesOriginalBytesAndKeepsBookmarkUriWhenNameAlreadyExists() throws Exception {
        String name = "测试 #+ % " + UUID.randomUUID() + ".mp4";
        byte[] original = {3, 2, 1};
        byte[] existing = {9, 8, 7, 6};
        VideoLibrary.Entry old = legacy(name, original, original.length);
        Uri playback = library.uri(old);
        File oldFile = library.file(old);
        ContentValues values = new ContentValues();
        values.put(MediaStore.MediaColumns.DISPLAY_NAME, name);
        values.put(MediaStore.MediaColumns.MIME_TYPE, "video/mp4");
        values.put(MediaStore.MediaColumns.RELATIVE_PATH, RELATIVE_PATH);
        Uri occupied = app.getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
        assertNotNull(occupied);
        try {
            try (OutputStream out = app.getContentResolver().openOutputStream(occupied)) {
                assertNotNull(out);
                out.write(existing);
            }
            migration.migrate(old.id);
            VideoLibrary.Entry saved = new VideoLibrary(app).find(old.id);
            assertTrue(saved.publicDownload);
            assertEquals(old.name, saved.name);
            assertEquals(old.source, saved.source);
            assertEquals(old.time, saved.time);
            assertTrue(saved.favorite);
            assertEquals(playback, library.uri(saved));
            assertBytes(playback, original);
            assertBytes(occupied, existing);
            assertFalse(oldFile.exists());
            Uri published = Uri.parse(saved.publicUri);
            assertNotEquals(occupied, published);
            String[] columns = {MediaStore.MediaColumns.RELATIVE_PATH, MediaStore.MediaColumns.DISPLAY_NAME,
                    MediaStore.MediaColumns.IS_PENDING};
            try (Cursor c = app.getContentResolver().query(published, columns, null, null, null)) {
                assertNotNull(c);
                assertTrue(c.moveToFirst());
                assertEquals(RELATIVE_PATH, c.getString(0));
                assertNotEquals(name, c.getString(1));
                assertEquals(saved.disk, c.getString(1));
                assertEquals(0, c.getInt(2));
            }
            new LegacyDownloadMigration(new VideoLibrary(app)).recover();
            migration.migrate(saved.id);
            assertEquals(saved.publicUri, library.find(old.id).publicUri);
        } finally {
            library.remove(library.find(old.id));
            app.getContentResolver().delete(occupied, null, null);
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

    @Test public void bulkExportToSystemSelectedFolderKeepsBothSourcesAndReusesVerifiedCopy() throws Exception {
        String folder = "NiceExport-" + UUID.randomUUID();
        String folderId = "primary:Download/" + folder;
        String authority = "com.android.externalstorage.documents";
        Uri initial = DocumentsContract.buildDocumentUri(authority, folderId);
        Uri tree = DocumentsContract.buildTreeDocumentUri(authority, folderId);
        String privateName = "Private #.mp4";
        String publicName = "Public-" + UUID.randomUUID() + ".mp4";
        byte[] original = "old".getBytes(StandardCharsets.UTF_8);
        byte[] modern = {6, 7, 8, 9};
        VideoLibrary.Entry old = legacy(privateName, original, original.length);
        VideoLibrary.Entry publicEntry = legacy(publicName, modern, modern.length);
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
            assertTrue(migration.migrate(publicEntry.id));
            String oldRecord = library.prefs.getString("movie." + old.id, null);
            String publicRecord = library.prefs.getString("movie." + publicEntry.id, null);
            ContentValues occupiedValues = new ContentValues();
            occupiedValues.put(MediaStore.MediaColumns.DISPLAY_NAME, privateName);
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
                Uri copiedPublic = DocumentsContract.buildDocumentUriUsingTree(tree, folderId + "/" + publicName);
                long timeout = SystemClock.elapsedRealtime() + 15000;
                Set<String> files = exportNames(tree);
                while (!(files.contains(copy) && files.contains(publicName)) && SystemClock.elapsedRealtime() < timeout) {
                    SystemClock.sleep(100);
                    files = exportNames(tree);
                }
                assertTrue("Expected both exports in " + files, files.contains(copy) && files.contains(publicName));
                assertBytes(occupied, "new".getBytes(StandardCharsets.UTF_8));
                assertBytes(copied, original);
                assertBytes(copiedPublic, modern);
                MovieExporter.Result repeated = new MovieExporter(library).export(old.id, tree);
                assertTrue(repeated.existing);
                assertEquals(copy, repeated.name);
                assertEquals(3, exportNames(tree).size());
                assertBytes(library.uri(publicEntry), modern);
                assertArrayEquals(original, Files.readAllBytes(library.file(old).toPath()));
                assertEquals(oldRecord, library.prefs.getString("movie." + old.id, null));
                assertEquals(publicRecord, library.prefs.getString("movie." + publicEntry.id, null));
            }
        } finally {
            library.remove(library.find(old.id));
            library.remove(library.find(publicEntry.id));
            if (occupied != null) app.getContentResolver().delete(occupied, null, null);
            try (InputStream done = new ParcelFileDescriptor.AutoCloseInputStream(
                    instrumentation.getUiAutomation().executeShellCommand("rm -r /sdcard/Download/" + folder))) {
                while (done.read() != -1) { /* wait for the disposable test directory to be removed */ }
            }
        }
    }

    @Test public void openingLibraryPreservesPrivateMovieUntilUserConfirmsMigration() throws Exception {
        byte[] bytes = {1, 1, 2, 3, 5};
        VideoLibrary.Entry old = legacy("自动迁移-" + UUID.randomUUID() + ".mp4", bytes, bytes.length);
        File source = library.file(old);
        Uri playback = library.uri(old);
        Uri importedUri = Uri.parse("content://example.document/" + UUID.randomUUID());
        library.remember(importedUri, "外部文件.mp4", 5L);
        try (ActivityScenario<MainActivity> ignored = ActivityScenario.launch(MainActivity.class)) {
            clickControl("迁移历史下载");
            clickControl("取消");
            assertArrayEquals(bytes, Files.readAllBytes(source.toPath()));
            assertFalse(library.find(old.id).publicDownload);
            clickControl("迁移历史下载");
            clickControl("开始迁移");
            long timeout = SystemClock.elapsedRealtime() + 20000;
            while (source.exists() && SystemClock.elapsedRealtime() < timeout) SystemClock.sleep(50);
            assertFalse("Home did not migrate the legacy file", source.exists());
            VideoLibrary.Entry saved = library.find(old.id);
            assertTrue(saved.publicDownload);
            assertBytes(playback, bytes);
            assertTrue(library.all().stream().anyMatch(e -> importedUri.equals(library.uri(e)) && !e.downloaded()));
        } finally {
            library.remove(library.find(old.id));
            for (VideoLibrary.Entry row : library.all()) {
                if (importedUri.toString().equals(row.document)) library.forget(row);
            }
        }
    }

    @Test public void resumesPartialPendingMediaStoreCopyAfterRestart() throws Exception {
        byte[] original = {3, 1, 4, 1, 5, 9, 2, 6};
        VideoLibrary.Entry old = legacy("中断-" + UUID.randomUUID() + ".mp4", original, original.length);
        ContentValues values = new ContentValues();
        values.put(MediaStore.MediaColumns.DISPLAY_NAME, old.name);
        values.put(MediaStore.MediaColumns.MIME_TYPE, "video/mp4");
        values.put(MediaStore.MediaColumns.RELATIVE_PATH, RELATIVE_PATH);
        values.put(MediaStore.MediaColumns.IS_PENDING, 1);
        Uri pending = app.getContentResolver().insert(MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY),
                values);
        assertNotNull(pending);
        try {
            try (OutputStream out = app.getContentResolver().openOutputStream(pending)) {
                assertNotNull(out);
                out.write(original, 0, 3);
            }
            JSONObject journal = new JSONObject().put("original", old.disk).put("job", old.job)
                    .put("target", pending.toString()).put("verified", false);
            assertTrue(app.getSharedPreferences("legacy_download_migration", Context.MODE_PRIVATE)
                    .edit().putString(old.id, journal.toString()).commit());

            LegacyDownloadMigration restarted = new LegacyDownloadMigration(new VideoLibrary(app));
            restarted.recover();
            assertTrue(restarted.migrate(old.id));
            VideoLibrary.Entry saved = library.find(old.id);
            assertEquals(pending.toString(), saved.publicUri);
            assertBytes(pending, original);
            assertFalse(library.file(old).exists());
            assertEquals(1, app.getContentResolver().delete(pending, null, null));
            assertTrue(library.missingPublicFile(saved));
        } finally {
            library.remove(library.find(old.id));
            app.getContentResolver().delete(pending, null, null);
            app.getSharedPreferences("legacy_download_migration", Context.MODE_PRIVATE).edit().remove(old.id).commit();
        }
    }

    @Test public void resumesFromUsbRestoreDirectoryAndOnlyCleansRecordedSource() throws Exception {
        byte[] externalBytes = {1, 2, 3}, restoredBytes = {4, 5, 6};
        VideoLibrary.Entry old = legacy("USB-" + UUID.randomUUID() + ".mp4", externalBytes, externalBytes.length);
        File unrelated = library.file(old);
        File restored = new File(new File(app.getFilesDir(), "legacy_download_restore"), old.disk);
        Files.createDirectories(restored.toPath().getParent());
        Files.write(restored.toPath(), restoredBytes);
        old.restoredPrivate = true;
        assertTrue(library.saveCommitted(old));
        Uri playback = library.uri(old);
        try {
            assertBytes(playback, restoredBytes);
            assertTrue(migration.migrate(old.id));
            VideoLibrary.Entry published = library.find(old.id);
            assertFalse(published.restoredPrivate);
            assertBytes(Uri.parse(published.publicUri), restoredBytes);
            assertArrayEquals(externalBytes, Files.readAllBytes(unrelated.toPath()));
            assertFalse(restored.exists());

            // Recreate a stop after the catalog switched, then remove the public copy before cleanup.
            Files.write(restored.toPath(), restoredBytes);
            JSONObject tx = new JSONObject().put("original", old.disk).put("job", old.job)
                    .put("restoredPrivate", true).put("target", published.publicUri).put("verified", true);
            assertTrue(app.getSharedPreferences("legacy_download_migration", Context.MODE_PRIVATE)
                    .edit().putString(old.id, tx.toString()).commit());
            assertEquals(1, app.getContentResolver().delete(Uri.parse(published.publicUri), null, null));
            LegacyDownloadMigration restarted = new LegacyDownloadMigration(new VideoLibrary(app));
            restarted.recover();
            VideoLibrary.Entry recovered = library.find(old.id);
            assertTrue(recovered.restoredPrivate);
            assertFalse(recovered.publicDownload);
            assertBytes(playback, restoredBytes);
            assertTrue(restarted.migrate(old.id));
            assertBytes(playback, restoredBytes);
            assertFalse(restored.exists());
            assertArrayEquals(externalBytes, Files.readAllBytes(unrelated.toPath()));
        } finally {
            library.remove(library.find(old.id));
            Files.deleteIfExists(unrelated.toPath());
            Files.deleteIfExists(restored.toPath());
            app.getSharedPreferences("legacy_download_migration", Context.MODE_PRIVATE).edit().remove(old.id).commit();
        }
    }

    @Test public void rejectsTruncatedFileWithoutLosingRecordAndCanRetryAfterRepair() throws Exception {
        byte[] original = {2, 7, 1, 8};
        // The low 32 bits match the length on disk: an int comparison would silently publish an incomplete file.
        VideoLibrary.Entry old = legacy("恢复-" + UUID.randomUUID() + ".mp4", original, (1L << 32) + original.length);
        File oldFile = library.file(old);
        try {
            try {
                migration.migrate(old.id);
                fail("A truncated legacy file was published");
            } catch (IOException expected) {
                assertArrayEquals(original, Files.readAllBytes(oldFile.toPath()));
                assertFalse(library.find(old.id).publicDownload);
            }
            old.bytes = original.length;
            library.save(old);
            migration.migrate(old.id);
            VideoLibrary.Entry saved = library.find(old.id);
            assertTrue(saved.publicDownload);
            assertBytes(Uri.parse(saved.publicUri), original);
            assertFalse(oldFile.exists());
        } finally {
            library.remove(library.find(old.id));
        }
    }
}
