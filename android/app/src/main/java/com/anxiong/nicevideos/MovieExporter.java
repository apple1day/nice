package com.anxiong.nicevideos;

import android.content.ContentResolver;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract;
import android.provider.DocumentsContract.Document;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.system.StructStat;
import android.webkit.MimeTypeMap;
import java.io.FileDescriptor;
import java.io.IOException;
import java.io.InputStream;
import java.io.InterruptedIOException;
import java.io.OutputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;

/** Copies finished offline movies into the folder granted by ACTION_OPEN_DOCUMENT_TREE. */
final class MovieExporter {
    static final class Result {
        final String name;
        final boolean existing;

        Result(String name, boolean existing) {
            this.name = name;
            this.existing = existing;
        }
    }

    private static final Object EXPORT_LOCK = new Object();
    private static final String[] COLUMNS = {
            Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE,
            Document.COLUMN_SIZE, Document.COLUMN_FLAGS
    };
    private final VideoLibrary library;
    private final ContentResolver resolver;
    private final SharedPreferences partials;

    MovieExporter(VideoLibrary library) {
        this.library = library;
        resolver = library.context.getContentResolver();
        partials = library.context.getSharedPreferences("movie_export_partials", 0);
    }

    static boolean eligible(VideoLibrary.Entry entry) {
        return entry != null && entry.downloaded() && VideoLibrary.READY.equals(entry.state);
    }

    Result export(String entryId, Uri tree) throws IOException {
        if (tree == null || !DocumentsContract.isTreeUri(tree))
            throw new IOException("请选择用于导出的文件夹。");
        synchronized (EXPORT_LOCK) {
            VideoLibrary.Entry entry;
            ParcelFileDescriptor descriptor;
            // Migration may publish a new URI and unlink the old path. Open the current file
            // under its catalog lock; the open descriptor then stays valid throughout the copy.
            synchronized (VideoLibrary.class) {
                entry = library.find(entryId);
                if (!eligible(entry)) throw new IOException("只能导出已完成下载的影片。");
                descriptor = library.openMovie(entry);
            }
            try (ParcelFileDescriptor.AutoCloseInputStream source =
                         new ParcelFileDescriptor.AutoCloseInputStream(descriptor)) {
                return copy(tree, VideoLibrary.safePublicName(entry.name), source, descriptor.getStatSize());
            }
        }
    }

    private Result copy(Uri tree, String name, ParcelFileDescriptor.AutoCloseInputStream source,
                        long expectedBytes) throws IOException {
        Map<String, Child> children = list(tree);
        removeInterruptedCopy(tree, children);
        byte[] buffer = new byte[1024 * 1024];
        byte[] sourceHash = null;
        int dot = name.lastIndexOf('.');
        String stem = dot > 0 ? name.substring(0, dot) : name;
        String extension = dot > 0 ? name.substring(dot) : "";
        String desired = name;
        for (int suffix = 1; ; suffix++) {
            Child child = children.get(desired.toLowerCase(Locale.ROOT));
            if (child == null) break;
            if (!child.directory && (child.size < 0 || child.size == expectedBytes)) {
                if (sameFile(source.getFD(), child.uri, expectedBytes)) return new Result(child.name, true);
                if (sourceHash == null) {
                    sourceHash = transfer(source, null, expectedBytes, buffer);
                    if (sourceHash == null) throw new IOException("原片大小已改变，导出已停止。");
                    source.getChannel().position(0);
                }
                if (matches(child.uri, sourceHash, expectedBytes, buffer))
                    return new Result(child.name, true);
            }
            desired = stem + " (" + suffix + ")" + extension;
        }

        String mime = extension.isEmpty() ? null : MimeTypeMap.getSingleton()
                .getMimeTypeFromExtension(extension.substring(1).toLowerCase(Locale.ROOT));
        String token = "NiceVideos-" + UUID.randomUUID() + ".part";
        Uri folder = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree));
        Uri staging = DocumentsContract.createDocument(resolver, folder,
                mime != null ? mime : "application/octet-stream", token + extension);
        if (staging == null) throw new IOException("无法在所选文件夹中新建文件。");
        Child part = read(tree, staging);
        if (!part.name.startsWith(token) || children.containsKey(part.name.toLowerCase(Locale.ROOT)))
            throw new IOException("文件提供方没有创建独立的临时文件。");
        String key = tree.toString();
        boolean published = false;
        try {
            if (!partials.edit().putString(key, part.name).putString(key + "#uri", part.uri.toString()).commit())
                throw new IOException("无法保存导出状态。");
            if ((part.flags & Document.FLAG_SUPPORTS_RENAME) == 0 ||
                    (part.flags & Document.FLAG_SUPPORTS_DELETE) == 0)
                throw new IOException("此文件夹不支持安全导出，请选择内部存储中的文件夹。");
            byte[] copied;
            try (OutputStream out = resolver.openOutputStream(part.uri, "w")) {
                if (out == null) throw new IOException("无法写入导出的影片。");
                copied = transfer(source, out, expectedBytes, buffer);
            }
            if (copied == null || (sourceHash != null && !MessageDigest.isEqual(copied, sourceHash))
                    || !matches(part.uri, copied, expectedBytes, buffer))
                throw new IOException("导出副本校验失败，请检查剩余空间后重试。");
            // Recheck after the lengthy copy. Never ask the provider to replace a file already
            // present; Android's local document provider also resolves simultaneous name clashes.
            children = list(tree);
            for (int suffix = 1; children.containsKey(desired.toLowerCase(Locale.ROOT)); suffix++) {
                Child occupied = children.get(desired.toLowerCase(Locale.ROOT));
                if (!occupied.directory && (occupied.size < 0 || occupied.size == expectedBytes) &&
                        matches(occupied.uri, copied, expectedBytes, buffer))
                    return new Result(occupied.name, true);
                desired = stem + " (" + suffix + ")" + extension;
            }
            Uri output = DocumentsContract.renameDocument(resolver, part.uri, desired);
            if (output == null) throw new IOException("无法将已校验的副本保存为影片文件。");
            published = true;
            return new Result(read(tree, output).name, false);
        } finally {
            // A crash after rename is also safe: recovery checks both the URI and temporary
            // display name, so providers retaining stable IDs cannot cause the final copy to be deleted.
            if (published || discardPartial(part)) {
                partials.edit().remove(key).remove(key + "#uri").apply();
            }
        }
    }

    private boolean discardPartial(Child part) {
        try (Cursor cursor = resolver.query(part.uri, new String[]{Document.COLUMN_DISPLAY_NAME}, null, null, null)) {
            if (cursor == null) return false;
            if (!cursor.moveToFirst() || !part.name.equals(cursor.getString(0))) return true;
            return DocumentsContract.deleteDocument(resolver, part.uri);
        } catch (IOException | RuntimeException failure) {
            // Keep the marker and the original exception if storage vanished during the copy.
            return false;
        }
    }

    private void removeInterruptedCopy(Uri tree, Map<String, Child> children) throws IOException {
        String key = tree.toString();
        String name = partials.getString(key, null);
        if (name == null) return;
        Child part = children.get(name.toLowerCase(Locale.ROOT));
        if (part != null && part.name.equals(name) && part.uri.toString().equals(partials.getString(key + "#uri", ""))) {
            if (!DocumentsContract.deleteDocument(resolver, part.uri))
                throw new IOException("上次导出尚未清理，请检查文件夹权限。");
            children.remove(name.toLowerCase(Locale.ROOT));
        }
        partials.edit().remove(key).remove(key + "#uri").apply();
    }

    private Map<String, Child> list(Uri tree) throws IOException {
        Uri children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree));
        Map<String, Child> result = new HashMap<>();
        try (Cursor cursor = resolver.query(children, COLUMNS, null, null, null)) {
            if (cursor == null || cursor.getExtras().getBoolean(DocumentsContract.EXTRA_LOADING))
                throw new IOException("无法完整读取所选文件夹，请稍后重试。");
            while (cursor.moveToNext()) {
                Child child = new Child(tree, cursor);
                result.put(child.name.toLowerCase(Locale.ROOT), child);
            }
        }
        return result;
    }

    private Child read(Uri tree, Uri document) throws IOException {
        try (Cursor cursor = resolver.query(document, COLUMNS, null, null, null)) {
            if (cursor == null || !cursor.moveToFirst()) throw new IOException("无法读取导出文件的信息。");
            return new Child(tree, cursor);
        }
    }

    private static final class Child {
        final Uri uri;
        final String name;
        final long size;
        final boolean directory;
        final int flags;

        Child(Uri tree, Cursor cursor) {
            uri = DocumentsContract.buildDocumentUriUsingTree(tree, cursor.getString(0));
            name = cursor.getString(1);
            directory = Document.MIME_TYPE_DIR.equals(cursor.getString(2));
            size = cursor.isNull(3) ? -1 : cursor.getLong(3);
            flags = cursor.getInt(4);
        }
    }

    private boolean sameFile(FileDescriptor source, Uri uri, long size) {
        try (ParcelFileDescriptor target = resolver.openFileDescriptor(uri, "r")) {
            if (target == null) return false;
            StructStat a = Os.fstat(source), b = Os.fstat(target.getFileDescriptor());
            return OsConstants.S_ISREG(a.st_mode) && OsConstants.S_ISREG(b.st_mode) && a.st_ino != 0
                    && a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == size && b.st_size == size;
        } catch (ErrnoException | IOException ignored) {
            return false; // A provider can expose readable bytes without a comparable inode.
        }
    }

    private boolean matches(Uri uri, byte[] hash, long size, byte[] buffer) throws IOException {
        try (InputStream in = resolver.openInputStream(uri)) {
            if (in == null) throw new IOException("无法读取目标文件进行校验。");
            byte[] read = transfer(in, null, size, buffer);
            return read != null && MessageDigest.isEqual(hash, read);
        }
    }

    /** Returns null on length mismatch, including providers which silently truncate writes. */
    private static byte[] transfer(InputStream in, OutputStream out, long expectedBytes, byte[] buffer)
            throws IOException {
        MessageDigest sha256;
        try { sha256 = MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException impossible) { throw new AssertionError(impossible); }
        long total = 0;
        while (true) {
            if (Thread.currentThread().isInterrupted()) throw new InterruptedIOException("导出已中断。");
            int count = in.read(buffer);
            if (count < 0) break;
            total += count;
            if (total > expectedBytes) return null;
            if (out != null) out.write(buffer, 0, count);
            sha256.update(buffer, 0, count);
        }
        return total == expectedBytes ? sha256.digest() : null;
    }
}
