package com.anxiong.nicevideos;

import android.app.DownloadManager;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.net.Uri;
import android.os.Environment;
import org.json.JSONObject;
import org.json.JSONException;
import java.io.File;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;

/** Stores small catalog records; the system manages transfers outside the activity's lifecycle. */
final class VideoLibrary {
    static final String READY = "ready", TRANSFER = "transfer", FAILED = "failed";
    final Context context;
    final SharedPreferences prefs;

    static final class Entry {
        final String id;
        String name = "", document = "", source = "", disk = "", state = READY, error = "";
        long bytes = -1, time, job = -1;
        boolean favorite;
        Entry(String id) { this.id = id; }
        boolean downloaded() { return !disk.isEmpty(); }
    }

    VideoLibrary(Context c) {
        context = c.getApplicationContext();
        prefs = c.getSharedPreferences("video_library", Context.MODE_PRIVATE);
    }

    private Entry parse(String value) {
        if (value == null) return null;
        try {
            JSONObject o = new JSONObject(value);
            Entry e = new Entry(o.getString("id"));
            e.name = o.getString("name"); e.document = o.optString("document");
            e.source = o.optString("source"); e.disk = o.optString("disk");
            e.state = o.optString("state", READY); e.error = o.optString("error");
            e.bytes = o.optLong("bytes", -1); e.time = o.optLong("time"); e.job = o.optLong("job", -1);
            e.favorite = o.optBoolean("favorite");
            return e;
        } catch (JSONException ex) { return null; }
    }

    List<Entry> all() {
        ArrayList<Entry> result = new ArrayList<>();
        for (Map.Entry<String, ?> record : prefs.getAll().entrySet()) {
            if (!record.getKey().startsWith("movie.") || !(record.getValue() instanceof String)) continue;
            Entry e = parse((String) record.getValue());
            if (e != null) result.add(e);
        }
        result.sort(Comparator.comparingLong((Entry e) -> e.time).reversed());
        return result;
    }

    Entry find(String id) { return parse(prefs.getString("movie." + id, null)); }

    void save(Entry e) {
        JSONObject o = new JSONObject();
        try {
            o.put("id", e.id).put("name", e.name).put("document", e.document).put("source", e.source)
                .put("disk", e.disk).put("state", e.state).put("error", e.error).put("bytes", e.bytes)
                .put("time", e.time).put("job", e.job).put("favorite", e.favorite);
        } catch (JSONException ex) { throw new IllegalStateException(ex); }
        prefs.edit().putString("movie." + e.id, o.toString()).apply();
    }

    void remember(Uri uri, String name, long bytes) {
        String document = uri.toString();
        Entry e = null;
        for (Entry candidate : all()) if (document.equals(candidate.document)) { e = candidate; break; }
        if (e == null) e = new Entry(UUID.randomUUID().toString());
        e.document = document; e.name = name; e.bytes = bytes; e.time = System.currentTimeMillis();
        save(e);
    }

    DownloadManager manager() { return (DownloadManager) context.getSystemService(Context.DOWNLOAD_SERVICE); }

    File file(Entry e) throws IOException {
        File root = context.getExternalFilesDir(Environment.DIRECTORY_MOVIES);
        if (root == null || !e.disk.matches("[a-f0-9-]{36}\\.[a-z0-9]{1,10}"))
            throw new IOException("本机视频目录不可用。");
        return new File(root, e.disk);
    }

    Uri uri(Entry e) {
        return e.downloaded() ? new Uri.Builder().scheme("content").authority(context.getPackageName() + ".offline")
                .appendPath(e.id).build() : Uri.parse(e.document);
    }

    void remove(Entry e) throws IOException {
        if (e.downloaded()) {
            removeTransfer(e);
        } else {
            try { context.getContentResolver().releasePersistableUriPermission(Uri.parse(e.document), Intent.FLAG_GRANT_READ_URI_PERMISSION); }
            catch (SecurityException ignored) { /* File or grant was removed by the user. */ }
        }
        prefs.edit().remove("movie." + e.id).apply();
    }

    private void removeTransfer(Entry e) throws IOException {
        if (e.job >= 0) manager().remove(e.job);
        File f = file(e);
        if (f.exists() && !f.delete()) throw new IOException("无法清理本机副本。");
    }

    void enqueue(ServerVideos.Movie movie, Entry prior) throws IOException {
        if (prior != null && !FAILED.equals(prior.state)) return;
        if (prior != null) removeTransfer(prior);
        int dot = movie.name.lastIndexOf('.');
        String extension = dot < 0 ? "video" : movie.name.substring(dot + 1).toLowerCase(Locale.ROOT);
        if (!extension.matches("[a-z0-9]{1,10}")) extension = "video";
        Entry e = prior == null ? new Entry(UUID.randomUUID().toString()) : prior;
        e.disk = UUID.randomUUID().toString() + "." + extension;
        e.name = movie.name; e.source = movie.url; e.bytes = movie.bytes;
        long space = file(e).getParentFile().getUsableSpace();
        if (e.bytes > 0 && space > 0 && space < e.bytes) throw new IOException("本机剩余空间不足。");
        DownloadManager.Request req = new DownloadManager.Request(Uri.parse(e.source)).setTitle(e.name)
            .setDescription("Nice 视频 · 离线下载")
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE)
            .setDestinationInExternalFilesDir(context, Environment.DIRECTORY_MOVIES, e.disk);
        e.job = manager().enqueue(req);
        e.state = TRANSFER; e.error = ""; e.time = System.currentTimeMillis();
        save(e);
    }

    static final class Transfer {
        String state = TRANSFER, label = "等待下载";
        long bytes, total;
    }

    Transfer check(Entry e) throws IOException {
        Transfer t = new Transfer();
        File f = file(e);
        try (Cursor c = manager().query(new DownloadManager.Query().setFilterById(e.job))) {
            if (c == null) throw new IOException("系统下载服务不可用。");
            if (!c.moveToFirst()) { t.state = FAILED; t.label = "下载任务已移除"; return t; }
            int status = c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS));
            t.bytes = c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR));
            t.total = c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES));
            if (status == DownloadManager.STATUS_RUNNING) t.label = "下载中";
            if (status == DownloadManager.STATUS_PAUSED) t.label = "等待网络或稍后重试";
            if (status == DownloadManager.STATUS_FAILED) {
                int why = c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON));
                t.state = FAILED;
                t.label = why == DownloadManager.ERROR_INSUFFICIENT_SPACE ? "本机空间不足" : "下载失败（" + why + "）";
            }
            if (status == DownloadManager.STATUS_SUCCESSFUL) {
                long expected = e.bytes >= 0 ? e.bytes : t.total;
                if (f.isFile() && f.length() > 0 && (expected < 0 || f.length() == expected)) {
                    t.state = READY;
                    t.bytes = f.length();
                } else { t.state = FAILED; t.label = "文件不完整或已移除"; }
            }
        }
        return t;
    }
}