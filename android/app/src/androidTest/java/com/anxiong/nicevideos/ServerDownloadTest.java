package com.anxiong.nicevideos;

import android.app.DownloadManager;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.os.Environment;
import android.os.SystemClock;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;
import androidx.test.core.app.ActivityScenario;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.filters.SdkSuppress;
import androidx.test.platform.app.InstrumentationRegistry;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Test;
import org.junit.runner.RunWith;
import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.BooleanSupplier;
import static org.junit.Assert.*;

@RunWith(AndroidJUnit4.class)
public final class ServerDownloadTest {
    private static final String NAME = "样片 #+ 1%.mp4";
    private static final String REMOTE_ONLY = "尚未下载.mp4";

    /** The Go list, delete and download routes, on the emulator's own loopback interface. */
    private static final class LocalServer implements Closeable {
        final ServerSocket socket;
        final Thread worker;
        final byte[] media;
        final List<String> deletes = new CopyOnWriteArrayList<>();
        volatile int listedSize;
        volatile Exception failure;
        volatile boolean downloaded, rejectDeletion, removed;
        LocalServer() throws Exception {
            try (InputStream input = InstrumentationRegistry.getInstrumentation().getContext()
                    .getAssets().open("moving-sbs.mp4"); ByteArrayOutputStream buffer = new ByteArrayOutputStream()) {
                byte[] chunk = new byte[8192];
                for (int n; (n = input.read(chunk)) != -1; ) buffer.write(chunk, 0, n);
                // Both file versions are playable: the newer one appends an empty MP4 free-space box.
                buffer.write(new byte[]{0, 0, 0, 8, 'f', 'r', 'e', 'e'});
                media = buffer.toByteArray();
            }
            listedSize = media.length;
            socket = new ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"));
            worker = new Thread(this::serve, "NiceTestHttp");
            worker.setDaemon(true);
            worker.start();
        }
        String address() { return "http://127.0.0.1:" + socket.getLocalPort(); }
        private JSONObject row(String name, int size) throws Exception {
            return new JSONObject().put("name", name).put("size", size)
                    .put("contentType", "video/mp4").put("downloadUrl", "/api/download/" + Uri.encode(name));
        }
        private byte[] index() throws Exception {
            JSONArray videos = new JSONArray();
            if (!removed) videos.put(row(NAME, listedSize));
            videos.put(row(REMOTE_ONLY, media.length));
            return new JSONObject().put("videos", videos).toString().getBytes(StandardCharsets.UTF_8);
        }
        private void serve() {
            try {
                while (!socket.isClosed()) {
                    try (Socket connection = socket.accept()) {
                        connection.setSoTimeout(5000);
                        BufferedReader in = new BufferedReader(new InputStreamReader(
                                connection.getInputStream(), StandardCharsets.US_ASCII));
                        String line = in.readLine();
                        if (line == null) continue;
                        String[] request = line.split(" ", 3);
                        String path = new URI(request[1]).getPath();
                        while ((line = in.readLine()) != null && !line.isEmpty()) { /* headers */ }
                        boolean list = "GET".equals(request[0]) && "/api/videos".equals(path);
                        boolean movie = ("/api/download/" + NAME).equals(path)
                                || ("/api/download/" + REMOTE_ONLY).equals(path);
                        boolean delete = "DELETE".equals(request[0]) && path.startsWith("/api/videos/");
                        if (delete) {
                            String target = path.substring("/api/videos/".length());
                            deletes.add(target);
                            if (!rejectDeletion && NAME.equals(target)) removed = true;
                        }
                        byte[] response = list ? index() : movie ? (path.endsWith(NAME)
                                ? Arrays.copyOf(media, listedSize) : media) : new byte[0];
                        String status = list || movie || delete ? "200 OK" : "404 Not Found";
                        if (delete && rejectDeletion) status = "500 Internal Server Error";
                        String headers = "HTTP/1.1 " + status
                                + "\r\nContent-Type: " + (movie ? "video/mp4" : "application/json")
                                + "\r\nContent-Length: " + response.length + "\r\nConnection: close\r\n\r\n";
                        OutputStream out = connection.getOutputStream();
                        out.write(headers.getBytes(StandardCharsets.US_ASCII));
                        if (!"HEAD".equals(request[0])) out.write(response);
                        out.flush();
                        if (movie && "GET".equals(request[0])) downloaded = true;
                    }
                }
            } catch (Exception ex) { if (!socket.isClosed()) failure = ex; }
        }
        @Override public void close() throws IOException { socket.close(); }
    }

    private static TextView label(View v, String text) {
        if (v instanceof TextView && (text.contentEquals(((TextView)v).getText())
                || text.equals(v.getContentDescription()))) return (TextView)v;
        if (v instanceof ViewGroup) {
            ViewGroup group = (ViewGroup)v;
            for (int i = 0; i < group.getChildCount(); i++) {
                TextView found = label(group.getChildAt(i), text);
                if (found != null) return found;
            }
        }
        return null;
    }

    private static void click(ActivityScenario<MainActivity> app, String label) throws Exception {
        long deadline = SystemClock.elapsedRealtime() + 10_000;
        AtomicBoolean clicked = new AtomicBoolean();
        do {
            app.onActivity(a -> {
                TextView v = label(a.getWindow().getDecorView(), label);
                if (v != null && v.isShown() && v.isEnabled()) clicked.set(v.performClick());
            });
            if (clicked.get()) return;
            SystemClock.sleep(100);
        } while (SystemClock.elapsedRealtime() < deadline);
        fail("No clickable control: " + label);
    }

    private static void await(String reason, int seconds, BooleanSupplier condition) {
        long deadline = SystemClock.elapsedRealtime() + seconds * 1000L;
        while (!condition.getAsBoolean()) {
            if (SystemClock.elapsedRealtime() >= deadline) fail(reason);
            SystemClock.sleep(100);
        }
    }

    @Test public void defaultAddressAndPreviouslySavedAddressSurviveReopening() {
        Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
        VideoLibrary library = new VideoLibrary(context);
        String previous = library.prefs.getString("server", null);
        try {
            assertTrue(library.prefs.edit().remove("server").commit());
            assertEquals("http://192.168.168.2:8106", new VideoLibrary(context).serverAddress());
            String custom = "http://127.0.0.1:38106";
            assertTrue(library.prefs.edit().putString("server", custom).commit());
            assertEquals(custom, new VideoLibrary(context).serverAddress());
        } finally {
            library.prefs.edit().putString("server", previous).commit();
        }
    }

    @Test @SdkSuppress(minSdkVersion = 29)
    public void allDownloadsIncludesNewVersionAndPreservesTheCompletedOlderCopy() throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
        VideoLibrary library = new VideoLibrary(context);
        String previous = library.prefs.getString("server", null);
        try (LocalServer server = new LocalServer()) {
            String base = server.address();
            library.prefs.edit().putString("server", base).commit();
            server.listedSize = server.media.length - 8;
            try (ActivityScenario<MainActivity> scene = ActivityScenario.launch(MainActivity.class)) {
                TestAppWindows controls = new TestAppWindows(scene);
                controls.click("服务器");
                click(scene, "下载 " + NAME);
                await("Older version did not finish", 60, () -> library.all().stream()
                        .anyMatch(e -> e.source.startsWith(base + "/") && e.name.equals(NAME)
                                && VideoLibrary.READY.equals(e.state)));

                server.listedSize = server.media.length;
                controls.click("刷新");
                AtomicBoolean newVersionAvailable = new AtomicBoolean();
                await("Changed-size movie should offer a new download", 15, () -> {
                    scene.onActivity(a -> newVersionAvailable.set(label(a.getWindow().getDecorView(), "下载 " + NAME) != null));
                    return newVersionAvailable.get();
                });
                controls.click("全部下载");
                controls.click("取消");
                assertEquals(1, library.all().stream().filter(e -> e.source.startsWith(base + "/")).count());
                controls.click("全部下载");
                controls.click("加入下载队列");
                await("Both missing downloads should finish", 60, () -> library.all().stream()
                        .filter(e -> e.source.startsWith(base + "/") && VideoLibrary.READY.equals(e.state)).count() == 3);
                int oldVersions = 0, newVersions = 0, otherMovies = 0;
                for (VideoLibrary.Entry e : library.all()) {
                    if (!e.source.startsWith(base + "/")) continue;
                    try (android.os.ParcelFileDescriptor fd = library.openMovie(e)) {
                        assertEquals(e.bytes, fd.getStatSize());
                    }
                    if (e.name.equals(REMOTE_ONLY)) otherMovies++;
                    else if (e.name.equals(NAME) && e.bytes == server.media.length - 8) oldVersions++;
                    else if (e.name.equals(NAME) && e.bytes == server.media.length) newVersions++;
                }
                assertEquals(1, oldVersions);
                assertEquals(1, newVersions);
                assertEquals(1, otherMovies);
                assertTrue(server.deletes.isEmpty());
            } finally {
                for (VideoLibrary.Entry e : library.all()) if (e.source.startsWith(base + "/")) library.remove(e);
                library.prefs.edit().putString("server", previous).commit();
            }
        }
    }

    @Test public void unsafeLocalCopiesNeverSendDeleteAndServerFailureKeepsTheCopy() throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
        VideoLibrary library = new VideoLibrary(context);
        try (LocalServer server = new LocalServer()) {
            String base = server.address();
            List<ServerVideos.Movie> catalog = ServerVideos.list(base);
            VideoLibrary.Entry entry = new VideoLibrary.Entry(UUID.randomUUID().toString());
            entry.name = NAME;
            entry.source = ServerVideos.downloadEndpoint(base, NAME);
            entry.bytes = server.media.length;
            entry.disk = entry.id + ".mp4";
            File copy = library.file(entry);
            try {
                assertTrue(library.saveCommitted(entry));
                DownloadedServerDeletion.Plan snapshot = DownloadedServerDeletion.plan(base, catalog, library.all());
                assertEquals(1, snapshot.size());
                assertFalse(copy.exists());
                assertEquals(1, DownloadedServerDeletion.run(snapshot, library, () -> true).skipped);
                Files.write(copy.toPath(), Arrays.copyOf(server.media, server.media.length - 8));
                assertEquals(1, DownloadedServerDeletion.run(snapshot, library, () -> true).skipped);
                Files.write(copy.toPath(), server.media);

                entry.state = VideoLibrary.TRANSFER;
                assertTrue(library.saveCommitted(entry));
                assertEquals(0, DownloadedServerDeletion.plan(base, catalog, library.all()).size());
                assertEquals(1, DownloadedServerDeletion.run(snapshot, library, () -> true).skipped);
                entry.state = VideoLibrary.READY;
                entry.direct = true;
                assertTrue(library.saveCommitted(entry));
                assertEquals(0, DownloadedServerDeletion.plan(base, catalog, library.all()).size());
                assertEquals(1, DownloadedServerDeletion.run(snapshot, library, () -> true).skipped);
                assertTrue(server.deletes.isEmpty());

                entry.direct = false;
                assertTrue(library.saveCommitted(entry));
                server.rejectDeletion = true;
                DownloadedServerDeletion.Result failure = DownloadedServerDeletion.run(snapshot, library, () -> true);
                assertEquals(1, failure.failed);
                assertEquals(0, failure.deleted);
                assertEquals(Collections.singletonList(NAME), server.deletes);
                assertEquals(VideoLibrary.READY, library.find(entry.id).state);
                assertArrayEquals(server.media, Files.readAllBytes(copy.toPath()));
                assertFalse(server.removed);
            } finally {
                library.remove(entry);
            }
        }
    }

    @Test public void serverDeleteRequiresTheSameCompletedCopyAndPreservesItsBytes() throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
        VideoLibrary library = new VideoLibrary(context);
        String previous = library.prefs.getString("server", null);
        try (LocalServer server = new LocalServer()) {
            String base = ServerVideos.address(server.address() + "/");
            library.prefs.edit().putString("server", base).commit();
            try (ActivityScenario<MainActivity> app = ActivityScenario.launch(MainActivity.class)) {
                click(app, "服务器");
                click(app, "下载 " + NAME);
                VideoLibrary.Entry e = null;
                long deadline = SystemClock.elapsedRealtime() + 60_000;
                while (SystemClock.elapsedRealtime() < deadline) {
                    for (VideoLibrary.Entry row : library.all()) if (row.source.startsWith(base + "/")) e = row;
                    if (e != null && !VideoLibrary.TRANSFER.equals(e.state)) break;
                    SystemClock.sleep(200);
                }
                assertNull(server.failure);
                assertNotNull("No DownloadManager record", e);
                assertEquals("System download: " + e.state + " / " + e.error, VideoLibrary.READY, e.state);
                assertTrue("Download route didn't receive GET for the decoded filename", server.downloaded);
                assertEquals(server.media.length, e.bytes);
                assertTrue(e.publicDownload);
                File expected = new File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                        "NiceVideos/" + e.disk);
                assertTrue(e.disk.startsWith("样片 #+ 1%"));
                try (Cursor row = library.manager().query(new DownloadManager.Query().setFilterById(e.job))) {
                    assertNotNull(row);
                    assertTrue(row.moveToFirst());
                    String localUri = row.getString(row.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI));
                    assertEquals(expected.getAbsolutePath(), Uri.parse(localUri).getPath());
                }
                List<ServerVideos.Movie> catalog = ServerVideos.list(base);
                DownloadedServerDeletion.Plan selected = DownloadedServerDeletion.plan(base, catalog, library.all());
                assertEquals(1, selected.size());
                // Neither a different server nor a same-name replacement can reuse this download.
                assertEquals(0, DownloadedServerDeletion.plan("http://127.0.0.1:1", catalog, library.all()).size());
                server.listedSize++;
                DownloadedServerDeletion.Result stale = DownloadedServerDeletion.run(selected, library, () -> true);
                assertEquals(0, stale.deleted);
                assertEquals(1, stale.skipped);
                assertTrue(server.deletes.isEmpty());
                server.listedSize--;
                assertEquals(1, DownloadedServerDeletion.run(selected, library, () -> false).skipped);
                assertTrue(server.deletes.isEmpty());

                click(app, "一键删除已下载视频（1）");
                await("Expected DELETE for the one completed movie", 15, () -> !server.deletes.isEmpty());
                assertEquals(Collections.singletonList(NAME), server.deletes);
                assertNotNull("Offline record disappeared", library.find(e.id));
                try (InputStream in = context.getContentResolver().openInputStream(library.uri(e))) {
                    assertNotNull(in);
                    ByteArrayOutputStream read = new ByteArrayOutputStream();
                    byte[] buffer = new byte[4096];
                    for (int n; (n = in.read(buffer)) != -1; ) read.write(buffer, 0, n);
                    assertArrayEquals(server.media, read.toByteArray());
                }
                library.remove(e);
                assertNull(library.find(e.id));
                // DownloadProvider schedules its file cleanup after removing the job.
                long cleanupDeadline = SystemClock.elapsedRealtime() + 5000;
                while (expected.exists() && SystemClock.elapsedRealtime() < cleanupDeadline) SystemClock.sleep(50);
                assertFalse(expected.exists());
            } finally {
                for (VideoLibrary.Entry e : library.all()) if (e.source.startsWith(base + "/")) library.remove(e);
                library.prefs.edit().putString("server", previous).commit();
            }
        }
    }
}
