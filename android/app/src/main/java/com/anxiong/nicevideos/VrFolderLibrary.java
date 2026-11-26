package com.anxiong.nicevideos;

import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.net.Uri;
import android.os.CancellationSignal;
import android.provider.DocumentsContract;
import android.provider.DocumentsContract.Document;
import java.io.IOException;
import java.text.Collator;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/** Directory listings use only SAF metadata. Movie bytes stay at the provider until playback. */
final class VrFolderLibrary {
    private static final Set<String> EXTENSIONS = new HashSet<>(Arrays.asList(
            "mp4", "m4v", "mov", "mkv", "webm", "avi", "ts", "m2ts", "mts", "mpg", "mpeg",
            "m2v", "3gp", "3g2", "ogv", "vob", "asf", "wmv", "flv", "f4v"));
    private final ContentResolver resolver;
    private final SharedPreferences roots;

    static final class Item {
        final Uri uri;
        final String name;
        final boolean folder;
        final long bytes;
        Item(Uri uri, String name, boolean folder, long bytes) {
            this.uri = uri; this.name = name; this.folder = folder; this.bytes = bytes;
        }
    }

    VrFolderLibrary(Context context) {
        resolver = context.getContentResolver();
        roots = context.getSharedPreferences("vr_folder_roots", Context.MODE_PRIVATE);
    }

    List<Item> roots() {
        List<Item> result = new ArrayList<>();
        for (Map.Entry<String, ?> e : roots.getAll().entrySet()) {
            if (e.getValue() instanceof String)
                result.add(new Item(Uri.parse(e.getKey()), (String)e.getValue(), true, -1));
        }
        sort(result);
        return result;
    }

    Item add(Uri tree) throws IOException {
        if (!ContentResolver.SCHEME_CONTENT.equals(tree.getScheme()) || !DocumentsContract.isTreeUri(tree))
            throw new IOException("请选择系统文件夹。");
        resolver.takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION);
        Uri directory = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree));
        String name = roots.getString(tree.toString(), "已授权文件夹");
        try (Cursor c = resolver.query(directory, new String[]{Document.COLUMN_DISPLAY_NAME}, null, null, null)) {
            if (c != null && c.moveToFirst() && !c.isNull(0)) name = c.getString(0);
        } catch (RuntimeException ignored) {
            // Keep a granted root if its provider goes offline; children() reports its access state.
        }
        roots.edit().putString(tree.toString(), name).apply();
        return new Item(tree, name, true, -1);
    }

    void forget(Uri tree) {
        roots.edit().remove(tree.toString()).apply();
        try { resolver.releasePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION); }
        catch (SecurityException ignored) { /* The user may already have revoked access. */ }
    }

    List<Item> children(Uri tree, String parentId, CancellationSignal cancel) throws IOException {
        Uri parent = DocumentsContract.buildDocumentUriUsingTree(tree, parentId);
        try (Cursor c = resolver.query(parent, new String[]{Document.COLUMN_MIME_TYPE}, null, null, null, cancel)) {
            if (c == null || !c.moveToFirst() || !Document.MIME_TYPE_DIR.equals(c.getString(0)))
                throw new IOException("文件夹已移动或不可用，请返回重选。");
        }
        Uri children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId);
        String[] projection = {Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME,
                Document.COLUMN_MIME_TYPE, Document.COLUMN_SIZE};
        List<Item> found = new ArrayList<>();
        try (Cursor c = resolver.query(children, projection, null, null, null, cancel)) {
            if (c == null || c.getExtras().getBoolean(DocumentsContract.EXTRA_LOADING))
                throw new IOException("文件提供方尚未就绪，请稍后刷新。");
            while (c.moveToNext()) {
                cancel.throwIfCanceled();
                String id = c.getString(0), name = c.getString(1), mime = c.getString(2);
                if (id == null || id.equals(parentId) || name == null || name.isEmpty() || name.startsWith(".")) continue;
                boolean folder = Document.MIME_TYPE_DIR.equals(mime);
                if (!folder && !isMovie(name, mime)) continue;
                found.add(new Item(DocumentsContract.buildDocumentUriUsingTree(tree, id), name,
                        folder, c.isNull(3) ? -1 : c.getLong(3)));
            }
        }
        sort(found);
        return found;
    }

    private static boolean isMovie(String name, String mime) {
        if (ServerVideos.playlist(name)) return false;
        int dot = name.lastIndexOf('.');
        return (mime != null && mime.startsWith("video/")) ||
                (dot >= 0 && EXTENSIONS.contains(name.substring(dot + 1).toLowerCase(Locale.ROOT)));
    }

    private static void sort(List<Item> items) {
        Collator collator = Collator.getInstance();
        items.sort((a,b) -> a.folder != b.folder ? Boolean.compare(b.folder, a.folder) : collator.compare(a.name, b.name));
    }
}
