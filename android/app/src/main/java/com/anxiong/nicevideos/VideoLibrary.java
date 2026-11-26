package com.anxiong.nicevideos;

import android.app.DownloadManager;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.net.Uri;
import android.os.Environment;
import android.os.ParcelFileDescriptor;
import org.json.JSONObject;
import org.json.JSONException;
import java.io.File;
import java.io.IOException;
import java.io.FileNotFoundException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.Set;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;

/** Stores small catalog records; the system manages transfers outside the activity's lifecycle. */
final class VideoLibrary {
    static final String READY = "ready", TRANSFER = "transfer", FAILED = "failed";
    static final String PUBLIC_FOLDER = "NiceVideos";
    final Context context;
    final SharedPreferences prefs;

    static final class Entry {
        final String id;
        String name = "", document = "", source = "", disk = "", state = READY, error = "";
        long bytes = -1, time, job = -1;
        boolean favorite, publicDownload;
        String publicUri = "";
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
            e.publicDownload = o.optBoolean("publicDownload");
            e.publicUri = o.optString("publicUri");
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

    private SharedPreferences.Editor edit(Entry e) {
        JSONObject o = new JSONObject();
        try {
            o.put("id", e.id).put("name", e.name).put("document", e.document).put("source", e.source)
                .put("disk", e.disk).put("state", e.state).put("error", e.error).put("bytes", e.bytes)
                .put("time", e.time).put("job", e.job).put("favorite", e.favorite)
                .put("publicDownload", e.publicDownload).put("publicUri", e.publicUri);
        } catch (JSONException ex) { throw new IllegalStateException(ex); }
        return prefs.edit().putString("movie." + e.id, o.toString());
    }

    void save(Entry e) { edit(e).apply(); }
    boolean saveCommitted(Entry e) { return edit(e).commit(); }

    Entry touch(String id) {
        synchronized (VideoLibrary.class) {
            Entry e = find(id);
            if (e != null) {
                e.time = System.currentTimeMillis();
                save(e);
            }
            return e;
        }
    }

    void toggleFavorite(String id) {
        synchronized (VideoLibrary.class) {
            Entry e = find(id);
            if (e != null) { e.favorite = !e.favorite; save(e); }
        }
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
        if (e.publicDownload || root == null || !e.disk.matches("[a-f0-9-]{36}\\.[a-z0-9]{1,10}"))
            throw new IOException("本机视频目录不可用。");
        return new File(root, e.disk);
    }

    Uri uri(Entry e) {
        return e.downloaded() ? new Uri.Builder().scheme("content").authority(context.getPackageName() + ".offline")
                .appendPath(e.id).build() : Uri.parse(e.document);
    }

    static File publicDirectory() {
        return new File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), PUBLIC_FOLDER);
    }

    static String safePublicName(String original) {
        String name = original.replaceAll("[\\p{Cntrl}\\\\/:*?\"<>|]", "_").trim()
                .replaceAll("^[. ]+|[. ]+$", "");
        if (name.isEmpty()) name = "video";
        if (name.getBytes(StandardCharsets.UTF_8).length <= 240) return name;
        int dot = name.lastIndexOf('.');
        String suffix = dot > 0 && name.length() - dot <= 16 ? name.substring(dot) : "";
        String stem = name.substring(0, name.length() - suffix.length());
        int remaining = 240 - suffix.getBytes(StandardCharsets.UTF_8).length;
        int end = 0;
        while (end < stem.length()) {
            int cp = stem.codePointAt(end);
            int width = cp < 128 ? 1 : cp < 2048 ? 2 : cp < 65536 ? 3 : 4;
            if (remaining < width) break;
            remaining -= width;
            end += Character.charCount(cp);
        }
        return stem.substring(0, end) + suffix;
    }

    String nextDownloadName(String original) {
        String name = safePublicName(original);
        Set<String> reserved = new HashSet<>();
        for (Entry row : all()) {
            if (row.publicDownload) reserved.add(row.disk.toLowerCase(Locale.ROOT));
        }
        File directory = publicDirectory();
        int dot = name.lastIndexOf('.');
        String stem = dot > 0 ? name.substring(0, dot) : name;
        String suffix = dot > 0 ? name.substring(dot) : "";
        String candidate = name;
        for (int i = 1; reserved.contains(candidate.toLowerCase(Locale.ROOT)) || new File(directory, candidate).exists(); i++) {
            candidate = stem + " (" + i + ")" + suffix;
        }
        return candidate;
    }

    private File publicFile(Uri uri) throws IOException {
        if (uri.getPath() == null) throw new IOException("下载文件位置无效。");
        File file = new File(uri.getPath()).getCanonicalFile();
        if (!publicDirectory().getCanonicalFile().equals(file.getParentFile())) throw new IOException("下载文件位置无效。");
        return file;
    }

    private ParcelFileDescriptor openDownload(Entry e) throws IOException {
        if (!e.publicDownload) return ParcelFileDescriptor.open(file(e), ParcelFileDescriptor.MODE_READ_ONLY);
        if (!e.publicUri.isEmpty()) {
            Uri location = Uri.parse(e.publicUri);
            if ("file".equals(location.getScheme()))
                return ParcelFileDescriptor.open(publicFile(location), ParcelFileDescriptor.MODE_READ_ONLY);
            try {
                ParcelFileDescriptor descriptor = context.getContentResolver().openFileDescriptor(location, "r");
                if (descriptor == null) throw new IOException("系统存储暂时不可用。");
                return descriptor;
            } catch (SecurityException ex) {
                // Some releases grant the caller access only via its DownloadManager job.
                if (e.job < 0) throw ex;
            }
        }
        if (e.job < 0) throw new FileNotFoundException("下载文件已移除。");
        return manager().openDownloadedFile(e.job);
    }

    ParcelFileDescriptor openMovie(Entry e) throws IOException {
        ParcelFileDescriptor fd = openDownload(e);
        long size = fd.getStatSize();
        if (size > 0 && (e.bytes < 0 || size == e.bytes)) return fd;
        fd.close();
        throw new IOException("本机副本大小不符或文件已移除。");
    }

    boolean missingPublicFile(Entry e) {
        String storage = Environment.getExternalStorageState();
        if (!e.publicDownload || !READY.equals(e.state)
                || !(Environment.MEDIA_MOUNTED.equals(storage) || Environment.MEDIA_MOUNTED_READ_ONLY.equals(storage))) return false;
        try (ParcelFileDescriptor ignored = openDownload(e)) {
            return false;
        } catch (FileNotFoundException ex) {
            return true;
        } catch (IOException | RuntimeException ex) {
            return false;
        }
    }

    void forget(Entry e) {
        synchronized (VideoLibrary.class) {
            prefs.edit().remove("movie." + e.id).apply();
        }
    }

    void remove(Entry entry) throws IOException {
        synchronized (VideoLibrary.class) {
            Entry e = find(entry.id);
            if (e == null) return;
            if (e.downloaded()) {
                removeTransfer(e);
            } else {
                try { context.getContentResolver().releasePersistableUriPermission(Uri.parse(e.document), Intent.FLAG_GRANT_READ_URI_PERMISSION); }
                catch (SecurityException ignored) { /* File or grant was removed by the user. */ }
            }
            forget(e);
        }
    }

    private void removeTransfer(Entry e) throws IOException {
        if (e.job >= 0) manager().remove(e.job);
        if (e.publicDownload) {
            // The system removes a DownloadManager-owned file together with its job.
            // A migrated copy has no job; delete only its recorded destination.
            if (e.job < 0 && !e.publicUri.isEmpty()) {
                Uri location = Uri.parse(e.publicUri);
                if ("file".equals(location.getScheme())) {
                    File f = publicFile(location);
                    if (f.exists() && !f.delete()) throw new IOException("无法删除公共目录中的影片。");
                } else {
                    context.getContentResolver().delete(location, null, null);
                }
            }
            return;
        }
        File f = file(e);
        if (!f.delete() && f.exists()) throw new IOException("无法清理本机副本。");
    }

    void enqueue(ServerVideos.Movie movie, Entry prior) throws IOException {
        synchronized (VideoLibrary.class) {
            // Activity recreation can leave a list row referring to an old record.
            for (Entry current : all()) {
                if (current.source.equals(movie.url)) { prior = current; break; }
            }
            if (prior != null && !FAILED.equals(prior.state) && !missingPublicFile(prior)) return;
            if (prior != null && !prior.publicDownload) removeTransfer(prior);
            Entry e = prior == null ? new Entry(UUID.randomUUID().toString()) : prior;
            e.disk = nextDownloadName(movie.name);
            e.name = movie.name; e.source = movie.url; e.bytes = movie.bytes;
            e.publicDownload = true; e.publicUri = "";
            long space = Environment.getExternalStorageDirectory().getUsableSpace();
            if (e.bytes > 0 && space > 0 && space < e.bytes) throw new IOException("本机剩余空间不足。");
            // DownloadManager appends the subpath as an encoded URI path. Encode the filename
            // so that a literal #, +, or % on the server also reaches the filesystem unchanged.
            String subPath = PUBLIC_FOLDER + "/" + Uri.encode(e.disk);
            DownloadManager.Request req = new DownloadManager.Request(Uri.parse(e.source)).setTitle(e.name)
                    .setDescription("Nice 视频 · Download/" + PUBLIC_FOLDER)
                    .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                    .setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, subPath);
            req.allowScanningByMediaScanner();
            e.job = manager().enqueue(req);
            e.state = TRANSFER; e.error = ""; e.time = System.currentTimeMillis();
            if (!saveCommitted(e)) {
                manager().remove(e.job);
                throw new IOException("无法保存下载记录。");
            }
        }
    }

    static final class Transfer {
        String state = TRANSFER, label = "等待下载", publicUri = "", disk = "";
        long bytes, total;
    }

    Transfer check(Entry e) throws IOException {
        Transfer t = new Transfer();
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
                if (e.publicDownload) {
                    String local = c.getString(c.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI));
                    Uri location = local == null ? null : Uri.parse(local);
                    if (location != null && "file".equals(location.getScheme()) && location.getLastPathSegment() != null)
                        t.disk = location.getLastPathSegment(); // DownloadManager may have resolved a name collision.
                }
                int media = c.getColumnIndex(DownloadManager.COLUMN_MEDIAPROVIDER_URI);
                if (e.publicDownload && media >= 0 && !c.isNull(media)) {
                    // Prefer a MediaStore row that follows renames, but keep the job as the
                    // locator on devices where only DownloadManager can open this download.
                    String location = c.getString(media);
                    try (ParcelFileDescriptor fd = context.getContentResolver().openFileDescriptor(Uri.parse(location), "r")) {
                        if (fd != null && fd.getStatSize() > 0) t.publicUri = location;
                    } catch (IOException | SecurityException ignored) {}
                }
                try (ParcelFileDescriptor fd = openDownload(e)) {
                    long size = fd.getStatSize();
                    if (size > 0 && (expected < 0 || size == expected)) {
                        t.state = READY;
                        t.bytes = size;
                    } else { t.state = FAILED; t.label = "文件不完整或已移除"; }
                } catch (FileNotFoundException ex) { t.state = FAILED; t.label = "下载文件已移除"; }
            }
        }
        return t;
    }
}
