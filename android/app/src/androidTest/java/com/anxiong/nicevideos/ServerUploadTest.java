package com.anxiong.nicevideos;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.CancellationSignal;
import android.os.SystemClock;
import android.provider.MediaStore;
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
import java.io.BufferedInputStream;
import java.io.Closeable;
import java.io.DataInputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.TreeMap;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import static org.junit.Assert.*;

@RunWith(AndroidJUnit4.class)
@SdkSuppress(minSdkVersion = 29)
public final class ServerUploadTest {
    private static final String NAME = "旅行 #+ 50%.mp4";

    private static final class Service implements Closeable {
        final ServerSocket server;
        final byte[] video = new byte[144_599];
        volatile Throwable failure;
        volatile boolean published;
        int preflights, posts;
        Service() throws IOException {
            for (int i = 0; i < video.length; i++) video[i] = (byte)(i * 57);
            server = new ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"));
            Thread thread = new Thread(() -> {
                while (!server.isClosed()) {
                    try (Socket connection = server.accept()) { serve(connection); }
                    catch (Throwable e) { if (!server.isClosed()) failure = e; }
                }
            }, "UploadFixture");
            thread.setDaemon(true);
            thread.start();
        }
        String base() { return "http://127.0.0.1:" + server.getLocalPort(); }

        @SuppressWarnings("deprecation") // HTTP/1.1 headers are ASCII. DataInputStream preserves raw body bytes.
        private void serve(Socket connection) throws Exception {
            connection.setSoTimeout(10000);
            DataInputStream in = new DataInputStream(new BufferedInputStream(connection.getInputStream()));
            String line = in.readLine();
            if (line == null) return;
            String[] request = line.split(" ", 3);
            Uri path = Uri.parse(request[1]);
            Map<String, String> headers = new TreeMap<>(String.CASE_INSENSITIVE_ORDER);
            while ((line = in.readLine()) != null && !line.isEmpty()) {
                int separator = line.indexOf(':');
                headers.put(line.substring(0, separator), line.substring(separator + 1).trim());
            }
            String status, body = "";
            if ("/api/videos".equals(path.getPath())) {
                assertEquals("GET", request[0]);
                JSONArray list = new JSONArray();
                if (published) list.put(new JSONObject().put("name", NAME).put("size", video.length));
                body = new JSONObject().put("videos", list).toString();
                status = "200 OK";
            } else {
                assertEquals("/api/upload-file", path.getPath());
                assertEquals(NAME, path.getQueryParameter("name"));
                if ("HEAD".equals(request[0])) {
                    preflights++;
                    status = published ? "409 Conflict" : "204 No Content";
                } else {
                    assertEquals("POST", request[0]);
                    assertTrue(preflights > 0);
                    posts++;
                    String id = headers.get("X-Nice-Upload-ID");
                    assertEquals(UUID.fromString(id).toString(), id);
                    assertEquals("application/octet-stream", headers.get("Content-Type"));
                    assertEquals(Integer.toString(video.length), headers.get("X-Nice-Upload-Bytes"));
                    assertEquals(Integer.toString(video.length), headers.get("Content-Length"));
                    byte[] received = new byte[video.length];
                    in.readFully(received);
                    assertArrayEquals(video, received);
                    published = true;
                    body = new JSONObject().put("version", 1).put("uploadID", id)
                            .put("name", NAME).put("size", video.length).toString();
                    status = "201 Created";
                }
            }
            byte[] encoded = body.getBytes(StandardCharsets.UTF_8);
            String response = "HTTP/1.1 " + status + "\r\nContent-Type: application/json; charset=utf-8\r\n"
                    + "X-Nice-Upload-Version: 1\r\nX-Nice-Upload-Max-Bytes: 21474836480\r\n"
                    + "Content-Length: " + encoded.length + "\r\nConnection: close\r\n\r\n";
            OutputStream out = connection.getOutputStream();
            out.write(response.getBytes(StandardCharsets.US_ASCII));
            out.write(encoded);
            out.flush();
        }
        @Override public void close() throws IOException { server.close(); }
    }

    private static TextView label(View view, String title) {
        if (view instanceof TextView && title.contentEquals(((TextView)view).getText())) return (TextView)view;
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup)view;
            for (int i = 0; i < group.getChildCount(); i++) {
                TextView match = label(group.getChildAt(i), title);
                if (match != null) return match;
            }
        }
        return null;
    }

    private static void awaitLabel(ActivityScenario<MainActivity> app, String title, boolean click, Service service) {
        long end = SystemClock.elapsedRealtime() + 15000;
        AtomicBoolean found = new AtomicBoolean();
        do {
            if (service.failure != null) throw new AssertionError("Upload fixture failed", service.failure);
            app.onActivity(a -> {
                TextView control = label(a.getWindow().getDecorView(), title);
                if (control != null && control.isShown()) found.set(!click || control.performClick());
            });
            if (found.get()) return;
            SystemClock.sleep(50);
        } while (SystemClock.elapsedRealtime() < end);
        fail("Missing visible label: " + title);
    }

    @Test public void pickedVideoIsUploadedByteForByteAndAppearsOnServerWithoutOverwriting() throws Exception {
        Instrumentation ins = InstrumentationRegistry.getInstrumentation();
        Context context = ins.getTargetContext();
        ContentResolver resolver = context.getContentResolver();
        VideoLibrary library = new VideoLibrary(context);
        String oldServer = library.prefs.getString("server", null);
        ContentValues values = new ContentValues();
        values.put(MediaStore.MediaColumns.RELATIVE_PATH, "Download/UploadTest-" + UUID.randomUUID() + "/");
        values.put(MediaStore.MediaColumns.DISPLAY_NAME, NAME);
        values.put(MediaStore.MediaColumns.MIME_TYPE, "video/mp4");
        Uri selected = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
        assertNotNull(selected);
        AtomicReference<Intent> picker = new AtomicReference<>();
        Instrumentation.ActivityMonitor monitor = new Instrumentation.ActivityMonitor() {
            @Override public Instrumentation.ActivityResult onStartActivity(Intent intent) {
                if (!Intent.ACTION_OPEN_DOCUMENT.equals(intent.getAction())) return null;
                picker.set(new Intent(intent));
                return new Instrumentation.ActivityResult(Activity.RESULT_OK, new Intent().setData(selected));
            }
        };
        try (Service service = new Service()) {
            try (OutputStream output = resolver.openOutputStream(selected)) {
                assertNotNull(output); output.write(service.video);
            }
            library.prefs.edit().putString("server", service.base()).commit();
            try (ActivityScenario<MainActivity> app = ActivityScenario.launch(MainActivity.class)) {
                ins.addMonitor(monitor);
                awaitLabel(app, "服务器", true, service);
                awaitLabel(app, "上传本机视频", true, service);
                awaitLabel(app, "上传完成：" + NAME, false, service);
                awaitLabel(app, NAME, false, service);
                assertTrue(picker.get().hasCategory(Intent.CATEGORY_OPENABLE));
                assertTrue(picker.get().getBooleanExtra(Intent.EXTRA_ALLOW_MULTIPLE, false));
                try {
                    NativeVideoUpload.send(resolver, selected, service.base(), new CancellationSignal(), (n,d,s) -> {});
                    fail("Existing video should produce a conflict");
                } catch (IOException expected) {
                    assertTrue(expected.getMessage(), expected.getMessage().contains("同名"));
                }
                assertTrue(service.published);
                assertEquals(2, service.preflights);
                assertEquals(1, service.posts);
                assertNull(service.failure);
            }
        } finally {
            ins.removeMonitor(monitor);
            resolver.delete(selected, null, null);
            library.prefs.edit().putString("server", oldServer).commit();
        }
    }
}
