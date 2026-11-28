package com.anxiong.nicevideos;

import android.app.Instrumentation;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.os.SystemClock;
import android.provider.MediaStore;

import androidx.test.core.app.ActivityScenario;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.filters.SdkSuppress;

import org.junit.Test;
import org.junit.runner.RunWith;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.BooleanSupplier;

import static org.junit.Assert.*;

@RunWith(AndroidJUnit4.class)
@SdkSuppress(minSdkVersion = 29)
public final class BatchDeleteDownloadsTest {
    private static final String BUTTON = "批量删除本机副本";
    private final Instrumentation ins = InstrumentationRegistry.getInstrumentation();
    private final Context app = ins.getTargetContext();
    private final VideoLibrary library = new VideoLibrary(app);
    private final ContentResolver resolver = app.getContentResolver();
    private final String prefix = "batch-" + UUID.randomUUID() + "-";
    private final List<Uri> publicRows = new ArrayList<>();

    /** Serve an ordinary movie and keep a second real transfer in progress until the test releases it. */
    private static final class VideoSource implements AutoCloseable {
        private final ServerSocket server;
        private final byte[] video;
        final AtomicInteger unexpectedMethods = new AtomicInteger();
        final CountDownLatch pendingStarted = new CountDownLatch(1);
        final CountDownLatch finishPending = new CountDownLatch(1);

        VideoSource(byte[] video) throws IOException {
            this.video = video;
            server = new ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"));
            Thread listener = new Thread(() -> {
                while (!server.isClosed()) {
                    try {
                        Socket accepted = server.accept();
                        Thread sender = new Thread(() -> respond(accepted), "bulk-delete-fixture-response");
                        sender.setDaemon(true);
                        sender.start();
                    } catch (IOException closed) { return; }
                }
            }, "bulk-delete-fixture-listener");
            listener.setDaemon(true);
            listener.start();
        }

        String address(String file) { return "http://127.0.0.1:" + server.getLocalPort() + "/" + file; }

        private void respond(Socket accepted) {
            try (Socket socket = accepted) {
                socket.setSoTimeout(10000);
                BufferedReader in = new BufferedReader(new InputStreamReader(socket.getInputStream(), StandardCharsets.US_ASCII));
                String line = in.readLine();
                if (line == null) return;
                String[] request = line.split(" ", 3);
                while ((line = in.readLine()) != null && !line.isEmpty()) { /* request headers */ }
                if (!"GET".equals(request[0]) && !"HEAD".equals(request[0])) {
                    unexpectedMethods.incrementAndGet();
                    return;
                }
                OutputStream out = socket.getOutputStream();
                String headers = "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: "
                        + video.length + "\r\nConnection: close\r\n\r\n";
                out.write(headers.getBytes(StandardCharsets.US_ASCII));
                if ("HEAD".equals(request[0])) return;
                if ("/pending.mp4".equals(request[1])) {
                    int sent = 0;
                    do {
                        out.write(video[sent++]);
                        out.flush();
                        pendingStarted.countDown();
                    } while (sent < video.length && !finishPending.await(1, TimeUnit.SECONDS));
                    out.write(video, sent, video.length - sent);
                } else {
                    out.write(video);
                }
                out.flush();
            } catch (IOException ignored) { /* DownloadManager may close its connection during test cleanup. */ }
              catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
        }

        @Override public void close() throws IOException {
            finishPending.countDown();
            server.close();
        }
    }

    private static byte[] bytes(InputStream stream) throws IOException {
        assertNotNull(stream);
        try (InputStream in = stream; ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192];
            for (int n; (n = in.read(buffer)) >= 0; ) out.write(buffer, 0, n);
            return out.toByteArray();
        }
    }

    private static void await(String condition, int seconds, BooleanSupplier check) {
        long until = SystemClock.elapsedRealtime() + seconds * 1000L;
        do {
            if (check.getAsBoolean()) return;
            SystemClock.sleep(80);
        } while (SystemClock.elapsedRealtime() < until);
        fail(condition);
    }

    private VideoLibrary.Entry enqueue(VideoSource service, String file, int length) throws IOException {
        String url = service.address(file);
        assertTrue(library.enqueue(new ServerVideos.Movie(prefix + file, length, url), null));
        for (VideoLibrary.Entry e : library.all()) if (url.equals(e.source)) return e;
        throw new AssertionError("No queued system download for " + file);
    }

    private Uri insertPublic(String name, byte[] content) throws IOException {
        ContentValues values = new ContentValues();
        values.put(MediaStore.MediaColumns.RELATIVE_PATH, "Download/NiceVideos/");
        values.put(MediaStore.MediaColumns.MIME_TYPE, "video/mp4");
        values.put(MediaStore.MediaColumns.DISPLAY_NAME, name);
        Uri uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
        assertNotNull(uri);
        publicRows.add(uri);
        try (OutputStream out = resolver.openOutputStream(uri)) {
            assertNotNull(out);
            out.write(content);
        }
        return uri;
    }

    private VideoLibrary.Entry migratedCopy(String suffix, byte[] video, String source) throws IOException {
        VideoLibrary.Entry e = new VideoLibrary.Entry(UUID.randomUUID().toString());
        e.name = e.disk = prefix + suffix;
        e.publicDownload = true;
        e.publicUri = insertPublic(e.name, video).toString();
        e.bytes = video.length;
        e.source = source;
        assertTrue(library.saveCommitted(e));
        return e;
    }

    private boolean exists(Uri row) {
        try (Cursor c = resolver.query(row, new String[]{"_id"}, null, null, null)) {
            return c != null && c.moveToFirst();
        }
    }

    @Test public void localListAutomaticallyRemovesDeletedRecordsButPreservesExistingAndPending() throws Exception {
        byte[] data = {1, 2, 3, 4};
        VideoLibrary.Entry gone = migratedCopy("gone.mp4", data, "https://example.org/gone.mp4");
        VideoLibrary.Entry kept = migratedCopy("kept.mp4", data, "https://example.org/kept.mp4");
        VideoLibrary.Entry pending = migratedCopy("pending.mp4", data, "https://example.org/pending.mp4");
        pending.state = VideoLibrary.TRANSFER;
        library.saveCommitted(pending);
        try {
            assertEquals(1, resolver.delete(Uri.parse(gone.publicUri), null, null));
            assertEquals(1, resolver.delete(Uri.parse(pending.publicUri), null, null));
            assertFalse(library.forgetIfMissing(pending.id));
            // Keep the deliberately incomplete record out of the activity's DownloadManager poll.
            pending.state = VideoLibrary.FAILED;
            library.saveCommitted(pending);
            try (ActivityScenario<MainActivity> scenario = ActivityScenario.launch(MainActivity.class)) {
                await("Missing record should be pruned automatically", 15, () -> library.find(gone.id) == null);
                assertNotNull(library.find(kept.id));
                assertNotNull(library.find(pending.id));
                assertArrayEquals(data, bytes(resolver.openInputStream(Uri.parse(kept.publicUri))));
                assertEquals(1, resolver.delete(Uri.parse(kept.publicUri), null, null));
                await("Foreground rescan should prune externally deleted file", 15, () -> library.find(kept.id) == null);
            }
        } finally {
            library.forget(gone);
            library.forget(kept);
            library.forget(pending);
            for (Uri row : publicRows) if (exists(row)) resolver.delete(row, null, null);
        }
    }

    @Test public void movingAConfirmedFilePreservesItAndItsReplacementAtTheOldPath() throws Exception {
        assertFalse("Use a clean test installation", library.all().stream().anyMatch(VideoLibrary.Entry::downloaded));
        byte[] original = {3, 1, 4}, other = {1, 5, 9};
        VideoLibrary.Entry moved = migratedCopy("moved.mp4", original, "https://example.org/moved.mp4");
        DownloadedVideoDeletion deletion = new DownloadedVideoDeletion(library);
        try {
            DownloadedVideoDeletion.Plan confirmed = deletion.prepare();
            assertEquals(1, confirmed.copies.size());
            Uri movedUri = Uri.parse(moved.publicUri);
            ContentValues changes = new ContentValues();
            changes.put(MediaStore.MediaColumns.RELATIVE_PATH, "Download/");
            assertEquals(1, resolver.update(movedUri, changes, null, null));
            Uri replacement = insertPublic(moved.name, other);

            CountDownLatch finished = new CountDownLatch(1);
            ins.runOnMainSync(() -> {
                deletion.listen(() -> { if (!deletion.running()) finished.countDown(); });
                deletion.start(confirmed);
            });
            assertTrue("Deletion should finish", finished.await(15, TimeUnit.SECONDS));
            assertNotNull(library.find(moved.id));
            assertArrayEquals(original, bytes(resolver.openInputStream(movedUri)));
            assertArrayEquals(other, bytes(resolver.openInputStream(replacement)));
        } finally {
            ins.runOnMainSync(deletion::close);
            library.forget(moved);
            for (Uri row : publicRows) if (exists(row)) resolver.delete(row, null, null);
        }
    }

    @Test public void cancelPreservesCopiesAndConfirmDeletesOnlyCompletedDownloadsInTheSnapshot() throws Exception {
        assertFalse("Use a clean test installation", library.all().stream().anyMatch(VideoLibrary.Entry::downloaded));
        byte[] video = bytes(ins.getContext().getAssets().open("moving-sbs.mp4"));
        try (VideoSource service = new VideoSource(video)) {
            VideoLibrary.Entry first = enqueue(service, "ready.mp4", video.length);
            VideoLibrary.Entry pending = enqueue(service, "pending.mp4", video.length);
            VideoLibrary.Entry migrated = migratedCopy("migrated.mp4", video, service.address("migrated.mp4"));
            Uri manual = insertPublic(prefix + "manual.mp4", video);
            library.remember(manual, prefix + "manual.mp4", video.length);
            try (ActivityScenario<MainActivity> scene = ActivityScenario.launch(MainActivity.class)) {
                await("First system download should complete", 60,
                        () -> VideoLibrary.READY.equals(library.find(first.id).state));
                assertTrue("Second system download must be active", service.pendingStarted.await(20, TimeUnit.SECONDS));
                File publicFile = new File(VideoLibrary.publicDirectory(), library.find(first.id).disk);
                assertArrayEquals(video, bytes(resolver.openInputStream(library.uri(first))));

                // The operation covers completed downloads even when the current view only shows favorites.
                TestAppWindows controls = new TestAppWindows(scene);
                controls.click("收藏");
                controls.click(BUTTON);
                controls.expectText("2 部");
                controls.click("取消");
                assertArrayEquals(video, bytes(resolver.openInputStream(library.uri(first))));
                assertArrayEquals(video, bytes(resolver.openInputStream(library.uri(migrated))));

                controls.click(BUTTON);
                controls.expectText("2 部");
                VideoLibrary.Entry later = migratedCopy("finished-after-dialog.mp4", video, service.address("later.mp4"));
                controls.click("确认删除");
                await("Both confirmed records should disappear", 15,
                        () -> library.find(first.id) == null && library.find(migrated.id) == null);
                await("DownloadProvider should remove the first public file", 10,
                        () -> !publicFile.exists() && library.manager().getUriForDownloadedFile(first.job) == null);
                assertFalse("Migrated public copy survived", exists(Uri.parse(migrated.publicUri)));

                assertEquals(VideoLibrary.TRANSFER, library.find(pending.id).state);
                assertArrayEquals(video, bytes(resolver.openInputStream(library.uri(later))));
                assertTrue("Manual document should remain in the library",
                        library.all().stream().anyMatch(e -> manual.toString().equals(e.document)));
                assertArrayEquals(video, bytes(resolver.openInputStream(manual)));
                assertArrayEquals("Server original should still be accessible", video,
                        bytes(new URL(service.address("ready.mp4")).openStream()));
                assertEquals(0, service.unexpectedMethods.get());

                service.finishPending.countDown();
                await("In-progress download should finish normally", 45,
                        () -> VideoLibrary.READY.equals(library.find(pending.id).state));
                assertArrayEquals(video, bytes(resolver.openInputStream(library.uri(pending))));
            }
        } finally {
            for (VideoLibrary.Entry e : library.all()) if (e.name.startsWith(prefix)) library.remove(e);
            for (Uri row : publicRows) if (exists(row)) resolver.delete(row, null, null);
        }
    }
}
