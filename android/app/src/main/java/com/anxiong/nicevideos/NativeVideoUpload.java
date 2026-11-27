package com.anxiong.nicevideos;

import android.content.ContentResolver;
import android.database.Cursor;
import android.net.Uri;
import android.os.CancellationSignal;
import android.os.SystemClock;
import android.provider.OpenableColumns;

import org.json.JSONException;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.UUID;

/** The same create-only file upload and receipt used by the iOS app and Go service. */
final class NativeVideoUpload {
    private static final long LIMIT = 20L * 1024 * 1024 * 1024;
    private static final List<String> EXT = Arrays.asList("mp4","m4v","mov","mkv","avi","webm","ogg","flv","wmv","ts");
    interface Progress { void update(String name, long done, long size); }

    static String send(ContentResolver resolver, Uri uri, String server, CancellationSignal stop, Progress progress)
            throws IOException {
        if (!ContentResolver.SCHEME_CONTENT.equals(uri.getScheme())) throw new IOException("请选择系统文件中的视频。");
        String name = null;
        long size = -1;
        try (Cursor row = resolver.query(uri, new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE},
                null, null, null, stop)) {
            if (row != null && row.moveToFirst()) {
                int n = row.getColumnIndex(OpenableColumns.DISPLAY_NAME), s = row.getColumnIndex(OpenableColumns.SIZE);
                if (n >= 0) name = row.getString(n);
                if (s >= 0 && !row.isNull(s)) size = row.getLong(s);
            }
        }
        if (name == null || name.isEmpty() || name.startsWith(".") || name.contains("/") || name.contains("\\")
                || name.codePoints().anyMatch(Character::isISOControl) || name.getBytes(StandardCharsets.UTF_8).length > 240
                || !name.contains(".") || !EXT.contains(name.substring(name.lastIndexOf('.') + 1).toLowerCase(Locale.ROOT)))
            throw new IOException("请选择服务器支持的本地视频文件，例如 MP4、MOV 或 MKV。");
        Uri endpoint = Uri.parse(ServerVideos.address(server)).buildUpon().appendPath("api").appendPath("upload-file")
                .appendQueryParameter("name", name).build();
        URL url = new URL(endpoint.toString());
        try (android.content.res.AssetFileDescriptor file = resolver.openAssetFileDescriptor(uri, "r", stop)) {
            if (file == null) throw new IOException("无法打开所选视频。");
            long actual = file.getLength();
            if (actual >= 0 && size >= 0 && actual != size) throw new IOException("视频大小已改变，请重新选择。");
            if (actual >= 0) size = actual;
            if (size <= 0 || size > LIMIT) throw new IOException("本地文件需有可读取的大小，且在 0 字节到 20 GiB 之间。");
            progress.update(name, 0, size);
            HttpURLConnection check = open(url);
            try {
                check.setRequestMethod("HEAD");
                stop.setOnCancelListener(check::disconnect);
                stop.throwIfCanceled();
                int status = check.getResponseCode();
                if (status != 204 || !"1".equals(check.getHeaderField("X-Nice-Upload-Version"))) {
                    if (status == 409) throw new IOException("服务器已存在同名影片：" + name);
                    throw new IOException("服务器未接受上传检查（HTTP " + status + "），请确认 Nice 视频服务支持文件上传。");
                }
                if (size > check.getHeaderFieldLong("X-Nice-Upload-Max-Bytes", LIMIT))
                    throw new IOException("影片超过这台服务器的上传大小上限。");
            } finally { stop.setOnCancelListener(null); check.disconnect(); }

            String id = UUID.randomUUID().toString();
            HttpURLConnection post = open(url);
            try {
                stop.setOnCancelListener(post::disconnect);
                stop.throwIfCanceled();
                post.setRequestMethod("POST");
                post.setDoOutput(true);
                post.setFixedLengthStreamingMode(size);
                post.setRequestProperty("Content-Type", "application/octet-stream");
                post.setRequestProperty("X-Nice-Upload-ID", id);
                post.setRequestProperty("X-Nice-Upload-Bytes", Long.toString(size));
                try (InputStream in = file.createInputStream(); OutputStream out = post.getOutputStream()) {
                    byte[] block = new byte[65536];
                    long count = 0, last = SystemClock.elapsedRealtime();
                    for (int read; (read = in.read(block)) != -1; ) {
                        stop.throwIfCanceled();
                        count += read;
                        if (count > size) throw new IOException("视频大小已改变，请重新选择。");
                        out.write(block, 0, read);
                        long now = SystemClock.elapsedRealtime();
                        if (now - last >= 500) { progress.update(name, count, size); last = now; }
                    }
                    if (count != size) throw new IOException("未能完整读取影片，请检查本地文件。");
                }
                int status = post.getResponseCode();
                if (status == 409) throw new IOException("服务器已存在同名影片：" + name);
                if (status != 201) throw new IOException("服务器上传失败（HTTP " + status + "）。");
                String badReceipt = "上传回执不匹配，请刷新服务器列表确认影片。";
                String type = post.getContentType();
                if (type == null || !type.split(";", 2)[0].trim().equalsIgnoreCase("application/json"))
                    throw new IOException(badReceipt);
                try (InputStream body = post.getInputStream()) {
                    ByteArrayOutputStream json = new ByteArrayOutputStream();
                    byte[] chunk = new byte[2048];
                    for (int n; (n = body.read(chunk)) != -1; ) {
                        if (json.size() + n > 16384) throw new IOException(badReceipt);
                        json.write(chunk, 0, n);
                    }
                    JSONObject ack = new JSONObject(json.toString("UTF-8"));
                    if (ack.getInt("version") != 1 || !id.equals(ack.getString("uploadID"))
                            || !name.equals(ack.getString("name")) || ack.getLong("size") != size)
                        throw new IOException(badReceipt);
                } catch (JSONException ex) { throw new IOException(badReceipt, ex); }
                return name;
            } finally { stop.setOnCancelListener(null); post.disconnect(); }
        }
    }

    private static HttpURLConnection open(URL url) throws IOException {
        HttpURLConnection c = (HttpURLConnection)url.openConnection();
        c.setConnectTimeout(10000);
        c.setReadTimeout(60000);
        c.setInstanceFollowRedirects(false);
        c.setUseCaches(false);
        return c;
    }
}
