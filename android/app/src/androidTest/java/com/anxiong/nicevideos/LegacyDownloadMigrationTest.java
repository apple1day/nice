package com.anxiong.nicevideos;

import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.os.Environment;
import android.os.SystemClock;
import android.provider.MediaStore;
import androidx.test.core.app.ActivityScenario;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.filters.SdkSuppress;
import androidx.test.platform.app.InstrumentationRegistry;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
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

    @Test public void openingLibraryAutomaticallyMigratesCompletedDownloadsAndLeavesImportedUriInPlace() throws Exception {
        byte[] bytes = {1, 1, 2, 3, 5};
        VideoLibrary.Entry old = legacy("自动迁移-" + UUID.randomUUID() + ".mp4", bytes, bytes.length);
        File source = library.file(old);
        Uri playback = library.uri(old);
        Uri importedUri = Uri.parse("content://example.document/" + UUID.randomUUID());
        library.remember(importedUri, "外部文件.mp4", 5L);
        try (ActivityScenario<MainActivity> ignored = ActivityScenario.launch(MainActivity.class)) {
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
