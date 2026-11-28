package com.anxiong.nicevideos;

import android.net.Uri;
import android.util.JsonReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

final class ServerVideos {
    static final String DEFAULT_ADDRESS = "http://192.168.168.2:8106";
    private static final String DOWNLOAD_PREFIX = "/api/download/";
    private static final Set<String> OFFLINE_EXTENSIONS = new HashSet<>(Arrays.asList(
            "mp4", "m4v", "mov", "mkv", "avi", "webm", "ogg", "flv", "wmv", "ts"));

    static final class Movie {
        final String name, url, contentType;
        final long bytes;
        final boolean direct;
        Movie(String name, long bytes, String url) { this(name, bytes, url, false); }
        Movie(String name, long bytes, String url, boolean direct) {
            this(name, bytes, url, direct, "");
        }
        Movie(String name, long bytes, String url, boolean direct, String contentType) {
            this.name = name; this.bytes = bytes; this.url = url; this.direct = direct;
            this.contentType = contentType;
        }
        boolean supportsOffline() {
            if (direct) return true; // Direct links are probed after download, including extensionless URLs.
            int dot = name.lastIndexOf('.');
            String mime = contentType.toLowerCase(Locale.ROOT);
            return bytes > 0 && dot >= 0 && OFFLINE_EXTENSIONS.contains(name.substring(dot + 1).toLowerCase(Locale.ROOT))
                    && !mime.startsWith("text/") && !mime.contains("json") && !mime.contains("mpegurl")
                    && !mime.contains("dash+xml") && !mime.contains("xhtml");
        }
    }

    static Movie direct(String raw, String suggestedName) throws IOException {
        URI link;
        try { link = new URI(raw == null ? "" : raw.trim()); }
        catch (java.net.URISyntaxException ex) { throw new IOException("视频地址格式有误。"); }
        String scheme = link.getScheme();
        if (!("https".equalsIgnoreCase(scheme) || "http".equalsIgnoreCase(scheme))
                || link.getHost() == null || link.getRawUserInfo() != null
                || link.getPort() == 0 || link.getPort() > 65535)
            throw new IOException("请输入以 https:// 或 http:// 开头的完整视频直链。");
        // Preserve the signed path and query byte for byte. Fragments never reach the server.
        String url = link.toASCIIString();
        int fragment = url.indexOf('#');
        if (fragment >= 0) url = url.substring(0, fragment);
        url = scheme.toLowerCase(Locale.ROOT) + url.substring(scheme.length());
        Uri uri = Uri.parse(url);
        String original = uri.getLastPathSegment();
        String name = suggestedName == null ? "" : suggestedName.trim();
        if (name.isEmpty()) {
            String filename = uri.getQueryParameter("filename");
            name = filename == null || filename.trim().isEmpty() ? original : filename;
        }
        if (name == null || name.trim().isEmpty()) name = "video";
        if (playlist(original == null ? "" : original) || playlist(name))
            throw new IOException("这是播放列表，请使用单个视频文件的下载地址。");
        return new Movie(VideoLibrary.safePublicName(name), -1, url, true);
    }

    static String address(String raw) throws IOException {
        String input = raw.trim();
        if (!input.contains("://")) input = "http://" + input;
        try {
            URI u = new URI(input);
            String scheme = u.getScheme().toLowerCase(Locale.ROOT);
            if (!("http".equals(scheme) || "https".equals(scheme)) || u.getHost() == null ||
                    u.getUserInfo() != null || u.getQuery() != null || u.getFragment() != null ||
                    !(u.getPath().isEmpty() || "/".equals(u.getPath())) || u.getPort() > 65535 || u.getPort() == 0)
                throw new IllegalArgumentException();
            String host = u.getHost().toLowerCase(Locale.ROOT);
            int port = u.getPort();
            if (port == ("https".equals(scheme) ? 443 : 80)) port = -1;
            return new URI(scheme, null, host, port, null, null, null).toASCIIString();
        } catch (Exception ex) { throw new IOException("请输入服务器根地址，例如 " + DEFAULT_ADDRESS); }
    }

    private static boolean safeName(String name) {
        return !name.isEmpty() && !name.contains("/") && !name.contains("\\") && !".".equals(name) && !"..".equals(name);
    }

    static String downloadEndpoint(String base, String name) {
        // Keep older DownloadManager records addressable even where Go and Android escape "+" differently.
        return Uri.parse(base).buildUpon().appendPath("api").appendPath("download").appendPath(name).build().toString();
    }

    private static boolean validDownloadPath(String path, String name) {
        try {
            URI uri = new URI(path);
            return uri.getScheme() == null && uri.getRawAuthority() == null && uri.getRawQuery() == null
                    && uri.getRawFragment() == null && path.startsWith(DOWNLOAD_PREFIX)
                    && (DOWNLOAD_PREFIX + name).equals(uri.getPath());
        } catch (java.net.URISyntaxException ex) { return false; }
    }

    /** Uses the same API root and per-name /api/download endpoint as the Go service. */
    static List<Movie> list(String base) throws IOException {
        HttpURLConnection c = (HttpURLConnection) new URL(base + "/api/videos").openConnection();
        c.setConnectTimeout(8000);
        c.setReadTimeout(15000);
        c.setInstanceFollowRedirects(false);
        c.setUseCaches(false);
        try {
            int status = c.getResponseCode();
            if (status != 200) throw new IOException("服务器返回 HTTP " + status);
            try (JsonReader reader = new JsonReader(new InputStreamReader(c.getInputStream(), StandardCharsets.UTF_8))) {
                List<Movie> movies = new ArrayList<>();
                Set<String> names = new HashSet<>();
                boolean found = false;
                reader.beginObject();
                while (reader.hasNext()) {
                    if (!"videos".equals(reader.nextName())) { reader.skipValue(); continue; }
                    found = true;
                    reader.beginArray();
                    while (reader.hasNext()) {
                        String name = "", contentType = "", downloadPath = null;
                        long size = -1;
                        reader.beginObject();
                        while (reader.hasNext()) {
                            switch (reader.nextName()) {
                                case "name": name = reader.nextString(); break;
                                case "size": size = reader.nextLong(); break;
                                case "contentType": contentType = reader.nextString(); break;
                                case "downloadUrl": downloadPath = reader.nextString(); break;
                                default: reader.skipValue();
                            }
                        }
                        reader.endObject();
                        if (!safeName(name)) continue;
                        if (!names.add(name)) throw new IOException("服务器返回重复文件名，请检查影片列表。");
                        if (downloadPath != null && !validDownloadPath(downloadPath, name))
                            throw new IOException("服务器返回的下载地址与影片名称不符：" + name);
                        movies.add(new Movie(name, size, downloadEndpoint(base, name), false, contentType));
                    }
                    reader.endArray();
                }
                reader.endObject();
                if (!found) throw new IOException("这个地址没有返回视频列表。");
                return movies;
            }
        } finally { c.disconnect(); }
    }

    static void delete(String base, Movie movie) throws IOException {
        if (movie.direct || !safeName(movie.name) || !downloadEndpoint(base, movie.name).equals(movie.url))
            throw new IOException("影片不属于当前服务器。");
        URL url = new URL(Uri.parse(base).buildUpon().appendPath("api").appendPath("videos")
                .appendPath(movie.name).build().toString());
        HttpURLConnection c = (HttpURLConnection) url.openConnection();
        c.setInstanceFollowRedirects(false);
        c.setUseCaches(false);
        c.setConnectTimeout(8000);
        c.setReadTimeout(15000);
        try {
            c.setRequestMethod("DELETE");
            int status = c.getResponseCode();
            if (status < 200 || status >= 300) throw new IOException("服务器返回 HTTP " + status);
        } finally { c.disconnect(); }
    }

    static boolean playlist(String name) {
        String ext = name.toLowerCase(Locale.ROOT);
        return ext.endsWith(".m3u8") || ext.endsWith(".m3u") || ext.endsWith(".mpd") || ext.endsWith(".pls") || ext.endsWith(".xspf");
    }
}
