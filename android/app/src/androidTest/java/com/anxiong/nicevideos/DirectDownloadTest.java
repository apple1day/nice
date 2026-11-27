package com.anxiong.nicevideos;

import android.app.Instrumentation;
import android.content.Context;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.accessibility.AccessibilityNodeInfo;
import androidx.test.core.app.ActivityScenario;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import org.junit.Test;
import org.junit.runner.RunWith;
import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import static org.junit.Assert.*;

@RunWith(AndroidJUnit4.class)
public final class DirectDownloadTest {
    private final Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();

    private static byte[] read(InputStream in) throws IOException {
        try (InputStream stream = in; ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[16_384];
            for (int n; (n = stream.read(buffer)) != -1; ) out.write(buffer, 0, n);
            return out.toByteArray();
        }
    }

    private static final String TARGET = "/asset/opaque?filename=sample%20clip.mp4&token=a%2Fb%2Bc%3D";
    private static class Endpoint implements AutoCloseable {
        final ServerSocket socket;
        final String url;
        final byte[] bytes;
        final String type;
        volatile boolean served;
        volatile IOException failure;
        Endpoint(byte[] bytes, String type) throws IOException {
            this.bytes = bytes; this.type = type;
            socket = new ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"));
            url = "http://127.0.0.1:" + socket.getLocalPort() + TARGET;
            Thread worker = new Thread(this::serve);
            worker.setDaemon(true); worker.start();
        }
        private void serve() {
            try {
                while (!socket.isClosed()) {
                    try (Socket connection = socket.accept()) {
                        connection.setSoTimeout(5000);
                        BufferedReader in = new BufferedReader(new InputStreamReader(connection.getInputStream(), StandardCharsets.US_ASCII));
                        String line = in.readLine();
                        if (line == null) continue;
                        boolean valid = line.startsWith("GET " + TARGET + " HTTP/");
                        while ((line = in.readLine()) != null && !line.isEmpty()) { /* request headers */ }
                        byte[] body = valid ? bytes : new byte[0];
                        OutputStream out = connection.getOutputStream();
                        String headers = "HTTP/1.1 " + (valid ? "200 OK" : "404 Not Found") + "\r\nContent-Type: " + type
                                + "\r\nContent-Length: " + body.length + "\r\nConnection: close\r\n\r\n";
                        out.write(headers.getBytes(StandardCharsets.US_ASCII)); out.write(body); out.flush();
                        if (valid) served = true;
                    }
                }
            } catch (IOException ex) { if (!socket.isClosed()) failure = ex; }
        }
        @Override public void close() throws IOException { socket.close(); }
    }

    private static AccessibilityNodeInfo find(AccessibilityNodeInfo node, String text, boolean editable) {
        if (node == null) return null;
        if (editable ? node.isEditable() : text.contentEquals(node.getText() == null ? "" : node.getText())) return node;
        for (int i = 0; i < node.getChildCount(); i++) {
            AccessibilityNodeInfo match = find(node.getChild(i), text, editable);
            if (match != null) return match;
        }
        return null;
    }

    private AccessibilityNodeInfo control(String text, boolean editable) {
        long end = SystemClock.elapsedRealtime() + 10_000;
        do {
            AccessibilityNodeInfo found = find(instrumentation.getUiAutomation().getRootInActiveWindow(), text, editable);
            if (found != null) return found;
            SystemClock.sleep(100);
        } while (SystemClock.elapsedRealtime() < end);
        throw new AssertionError("Missing control: " + text);
    }

    private VideoLibrary.Entry download(Endpoint endpoint, VideoLibrary library) {
        assertTrue(control("视频直链", false).performAction(AccessibilityNodeInfo.ACTION_CLICK));
        Bundle args = new Bundle();
        args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, endpoint.url + "#fragment");
        assertTrue(control("URL", true).performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args));
        assertTrue(control("开始下载", false).performAction(AccessibilityNodeInfo.ACTION_CLICK));
        long end = SystemClock.elapsedRealtime() + 60_000;
        VideoLibrary.Entry last = null;
        do {
            for (VideoLibrary.Entry entry : library.all()) {
                if (endpoint.url.equals(entry.source)) {
                    last = entry;
                    if (!VideoLibrary.TRANSFER.equals(entry.state)) return entry;
                }
            }
            SystemClock.sleep(150);
        } while (SystemClock.elapsedRealtime() < end);
        throw new AssertionError("Direct download stuck: " + (last == null ? "not enqueued" : last.state));
    }

    @Test public void uiDownloadsSignedLinkAndRejectsDisguisedHtmlWithoutServer() throws Exception {
        Context app = instrumentation.getTargetContext();
        VideoLibrary library = new VideoLibrary(app);
        String server = library.prefs.getString("server", null);
        library.prefs.edit().remove("server").commit();
        byte[] sample = read(instrumentation.getContext().getAssets().open("moving-sbs.mp4"));
        try (Endpoint movie = new Endpoint(sample, "application/octet-stream");
             Endpoint fake = new Endpoint("<html>Login required</html>".getBytes(StandardCharsets.UTF_8), "video/mp4");
             ActivityScenario<MainActivity> scene = ActivityScenario.launch(MainActivity.class)) {
            try {
                VideoLibrary.Entry ready = download(movie, library);
                assertNull(movie.failure); assertTrue(movie.served);
                assertEquals(ready.error, VideoLibrary.READY, ready.state);
                assertTrue(ready.publicDownload && ready.direct);
                assertEquals("sample clip.mp4", ready.name);
                assertTrue(ready.disk.startsWith("sample clip"));
                assertArrayEquals(sample, read(app.getContentResolver().openInputStream(library.uri(ready))));
                assertFalse("An accessible public copy was removed", library.forgetIfMissing(ready.id));
                VideoLibrary.Entry failed = download(fake, library);
                assertNull(fake.failure); assertTrue(fake.served);
                assertEquals(VideoLibrary.FAILED, failed.state);
                assertTrue(failed.error, failed.error.contains("视频"));
                assertNull(library.manager().getUriForDownloadedFile(failed.job));
            } finally {
                for (VideoLibrary.Entry e : library.all()) {
                    if (movie.url.equals(e.source) || fake.url.equals(e.source)) library.remove(e);
                }
            }
        } finally { library.prefs.edit().putString("server", server).commit(); }
    }

    @Test public void invalidAndPlaylistLinksAreRejectedBeforeEnqueue() throws Exception {
        for (String url : new String[]{"", "content://provider/file", "https://", "https://user@host/video",
                "https://host/list.m3u8?token=abc", "https://host/a?filename=index.mpd"}) {
            try { ServerVideos.direct(url, ""); fail(url); }
            catch (IOException expected) { assertNotNull(expected.getMessage()); }
        }
        String raw = "HTTPS://example.com/test%2Fx?value=a%2Bb%2Fc%3D+xyz#skip";
        ServerVideos.Movie valid = ServerVideos.direct(raw, "片段.mp4");
        assertEquals("https://example.com/test%2Fx?value=a%2Bb%2Fc%3D+xyz", valid.url);
        assertEquals("片段.mp4", valid.name); assertTrue(valid.direct);
    }
}
