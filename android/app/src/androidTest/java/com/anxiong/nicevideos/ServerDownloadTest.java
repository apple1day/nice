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
import java.util.concurrent.atomic.AtomicBoolean;
import static org.junit.Assert.*;

@RunWith(AndroidJUnit4.class)
public final class ServerDownloadTest {
    private static final String NAME = "样片 #+ 1%.mp4";

    /** The Go list and download routes, on the emulator's own loopback interface. */
    private static final class LocalServer implements Closeable {
        final ServerSocket socket;
        final Thread worker;
        final byte[] media = new byte[144_599];
        final byte[] index;
        volatile Exception failure;
        volatile boolean downloaded;
        LocalServer() throws Exception {
            for (int i = 0; i < media.length; i++) media[i] = (byte)(i * 17);
            index = new JSONObject().put("videos", new JSONArray().put(new JSONObject()
                    .put("name", NAME).put("size", media.length).put("contentType", "video/mp4")
                    .put("downloadUrl", "/api/download/" + android.net.Uri.encode(NAME))))
                    .toString().getBytes(StandardCharsets.UTF_8);
            socket = new ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"));
            worker = new Thread(this::serve, "NiceTestHttp");
            worker.setDaemon(true);
            worker.start();
        }
        String address() { return "http://127.0.0.1:" + socket.getLocalPort(); }
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
                        boolean list = "/api/videos".equals(path);
                        boolean movie = ("/api/download/" + NAME).equals(path);
                        byte[] response = list ? index : movie ? media : new byte[0];
                        String headers = "HTTP/1.1 " + (list || movie ? "200 OK" : "404 Not Found")
                                + "\r\nContent-Type: " + (list ? "application/json" : "video/mp4")
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
        if (v instanceof TextView && text.contentEquals(((TextView)v).getText())) return (TextView)v;
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
                if (v != null && v.isShown()) clicked.set(v.performClick());
            });
            if (clicked.get()) return;
            SystemClock.sleep(100);
        } while (SystemClock.elapsedRealtime() < deadline);
        fail("No clickable control: " + label);
    }

    @Test public void serverListAndDownloadPublishOnlyTheByteIdenticalLocalCopy() throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
        VideoLibrary library = new VideoLibrary(context);
        String previous = library.prefs.getString("server", null);
        try (LocalServer server = new LocalServer()) {
            String base = ServerVideos.address(server.address() + "/");
            library.prefs.edit().putString("server", base).commit();
            try (ActivityScenario<MainActivity> app = ActivityScenario.launch(MainActivity.class)) {
                click(app, "服务器");
                click(app, "下载");
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
