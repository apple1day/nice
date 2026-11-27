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
import java.util.List;
import java.util.Locale;

final class ServerVideos {
    static final class Movie {
        final String name, url;
        final long bytes;
        final boolean direct;
        Movie(String name, long bytes, String url) { this(name, bytes, url, false); }
        Movie(String name, long bytes, String url, boolean direct) {
            this.name = name; this.bytes = bytes; this.url = url; this.direct = direct;
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
        } catch (Exception ex) { throw new IOException("请输入服务器根地址，例如 http://192.168.1.10:8106"); }
    }

    /** Uses the same API root and per-name /api/download endpoint as the Go service. */
    static List<Movie> list(String base) throws IOException {
        HttpURLConnection c = (HttpURLConnection) new URL(base + "/api/videos").openConnection();
        c.setConnectTimeout(8000);
        c.setReadTimeout(15000);
        c.setInstanceFollowRedirects(false);
        try {
            int status = c.getResponseCode();
            if (status != 200) throw new IOException("服务器返回 HTTP " + status);
            try (JsonReader reader = new JsonReader(new InputStreamReader(c.getInputStream(), StandardCharsets.UTF_8))) {
                List<Movie> movies = new ArrayList<>();
                boolean found = false;
                reader.beginObject();
                while (reader.hasNext()) {
                    if (!"videos".equals(reader.nextName())) { reader.skipValue(); continue; }
                    found = true;
                    reader.beginArray();
                    while (reader.hasNext()) {
                        String name = "";
                        long size = -1;
                        reader.beginObject();
                        while (reader.hasNext()) {
                            switch (reader.nextName()) {
                                case "name": name = reader.nextString(); break;
                                case "size": size = reader.nextLong(); break;
                                default: reader.skipValue();
                            }
                        }
                        reader.endObject();
                        if (name.isEmpty() || name.contains("/") || name.contains("\\") || ".".equals(name) || "..".equals(name)) continue;
                        String endpoint = Uri.parse(base).buildUpon().appendPath("api").appendPath("download").appendPath(name).build().toString();
                        movies.add(new Movie(name, size, endpoint));
                    }
                    reader.endArray();
                }
                reader.endObject();
                if (!found) throw new IOException("这个地址没有返回视频列表。");
                return movies;
            }
        } finally { c.disconnect(); }
    }

    static boolean playlist(String name) {
        String ext = name.toLowerCase(Locale.ROOT);
        return ext.endsWith(".m3u8") || ext.endsWith(".m3u") || ext.endsWith(".mpd") || ext.endsWith(".pls") || ext.endsWith(".xspf");
    }
}
