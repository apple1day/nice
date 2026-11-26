package com.anxiong.nicevideos;

import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.media.MediaScannerConnection;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.os.ParcelFileDescriptor;
import android.provider.MediaStore;
import android.system.ErrnoException;
import android.system.Os;
import android.system.StructStat;
import android.webkit.MimeTypeMap;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InterruptedIOException;
import java.nio.channels.FileChannel;
import java.nio.file.FileAlreadyExistsException;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Locale;
import org.json.JSONException;
import org.json.JSONObject;

/** Move verified legacy downloads into shared Downloads, one movie at a time. */
final class LegacyDownloadMigration {
    private static final Object WORKER = new Object();
    private static final int BUFFER = 1024 * 1024;
    private final VideoLibrary library;
    private final ContentResolver resolver;
    private final SharedPreferences journal;

    LegacyDownloadMigration(VideoLibrary library) {
        this.library = library;
        resolver = library.context.getContentResolver();
        journal = library.context.getSharedPreferences("legacy_download_migration", 0);
    }

    java.util.Set<String> pendingIds() { return journal.getAll().keySet(); }

    static boolean needsMigration(VideoLibrary.Entry e) {
        return e != null && e.downloaded() && !e.publicDownload && VideoLibrary.READY.equals(e.state);
    }

    // Keep large-file I/O off the catalog lock. Multiple activity instances may share a process.
    boolean migrate(String id) throws IOException {
        synchronized (WORKER) {
            VideoLibrary.Entry old = library.find(id);
            if (!needsMigration(old)) return false;
            File source = library.file(old);
            long length = source.length();
            if (!source.isFile() || length <= 0 || (old.bytes >= 0 && length != old.bytes))
                throw new IOException("旧版影片不完整，已保留原文件。");
            Transaction tx = read(id);
            if (tx == null) tx = begin(old);
            if (!tx.matchesOriginal(old))
                throw new IOException("影片记录已更改，请重新打开片库。");

            boolean published = false;
            if (tx.media()) {
                String state = mediaColumn(tx.target, MediaStore.MediaColumns.IS_PENDING);
                if (state == null) tx = begin(old); // Unfinished pending items can expire.
                else published = "0".equals(state);
            } else {
                published = tx.verified && !stage(id).exists() && new File(tx.target.getPath()).isFile();
            }

            if (published && !matches(source, tx.target)) {
                // A user may edit a file between publication and recovery; never overwrite it.
                tx = begin(old);
                published = false;
            }
            if (!published) {
                Uri staging = tx.media() ? tx.target : Uri.fromFile(stage(id));
                copyAndVerify(source, staging, tx.media());
                tx.verified = true;
                write(id, tx);
            }

            synchronized (VideoLibrary.class) {
                VideoLibrary.Entry latest = library.find(id);
                if (!needsMigration(latest) || !tx.matchesOriginal(latest)) {
                    discardUnpublished(id, tx);
                    return false;
                }
                if (!published) publish(id, tx, latest.name);
                String actualName = tx.media() ? mediaColumn(tx.target, MediaStore.MediaColumns.DISPLAY_NAME)
                        : new File(tx.target.getPath()).getName();
                try (ParcelFileDescriptor fd = open(tx.target, "r")) {
                    if (actualName == null || fd.getStatSize() != length)
                        throw new IOException("公共影片尚未就绪，已保留原文件。");
                }
                latest.publicDownload = true;
                latest.restoredPrivate = false;
                latest.publicUri = tx.target.toString();
                latest.disk = actualName;
                latest.bytes = length;
                latest.job = -1;
                if (!library.saveCommitted(latest)) throw new IOException("无法保存迁移记录。");
                cleanup(id, tx);
            }
            return true;
        }
    }

    /** Finish cleanup if the process stopped after switching the catalog but before removing the old file. */
    void recover() throws IOException {
        synchronized (WORKER) {
            IOException failure = null;
            for (String id : journal.getAll().keySet()) {
                interrupted();
                try {
                    recover(id);
                } catch (InterruptedIOException stop) {
                    throw stop;
                } catch (IOException | RuntimeException ex) {
                    if (failure == null) failure = new IOException("无法恢复迁移：" + ex.getLocalizedMessage(), ex);
                }
            }
            if (failure != null) throw failure;
        }
    }

    private void recover(String id) throws IOException {
        Transaction tx = read(id);
        VideoLibrary.Entry e = library.find(id);
        if (e == null || !e.publicDownload || !tx.target.toString().equals(e.publicUri)) {
            if (!needsMigration(e) || !tx.matchesOriginal(e)) discardUnpublished(id, tx);
            // Uncommitted copies resume in migrate(id).
            return;
        }

        File source = oldFile(id, tx);
        boolean restore = false;
        if (source.exists()) {
            boolean targetExists = tx.media() ? mediaColumn(tx.target, MediaStore.MediaColumns.DISPLAY_NAME) != null
                    : new File(tx.target.getPath()).isFile();
            restore = !targetExists || !matches(source, tx.target);
        }
        synchronized (VideoLibrary.class) {
            VideoLibrary.Entry current = library.find(id);
            if (current == null || !current.publicDownload || !e.publicUri.equals(current.publicUri)) return;
            if (restore) {
                // If the published copy changed before cleanup, preserve it and resume from the intact original.
                if (!source.isFile() || source.length() != current.bytes) throw new IOException("旧版副本大小异常。");
                current.publicDownload = false;
                current.restoredPrivate = tx.restoredPrivate;
                current.publicUri = "";
                current.disk = tx.original;
                current.job = tx.job;
                current.state = VideoLibrary.READY;
                current.error = "";
            }
            if (!library.saveCommitted(current)) throw new IOException("无法保存迁移记录。");
            if (restore) journal.edit().remove(id).commit();
            else cleanup(id, tx);
        }
    }

    private static final class Transaction {
        final String original;
        final long job;
        final boolean restoredPrivate;
        Uri target;
        boolean verified;
        Transaction(String original, long job, boolean restoredPrivate, Uri target, boolean verified) {
            this.original = original; this.job = job; this.target = target; this.verified = verified;
            this.restoredPrivate = restoredPrivate;
        }
        boolean matchesOriginal(VideoLibrary.Entry e) {
            return original.equals(e.disk) && job == e.job && restoredPrivate == e.restoredPrivate;
        }
        boolean media() { return ContentResolver.SCHEME_CONTENT.equals(target.getScheme()); }
    }

    private Transaction read(String id) throws IOException {
        String value = journal.getString(id, null);
        if (value == null) return null;
        try {
            JSONObject o = new JSONObject(value);
            return new Transaction(o.getString("original"), o.getLong("job"), o.optBoolean("restoredPrivate"),
                    Uri.parse(o.getString("target")), o.getBoolean("verified"));
        } catch (JSONException ex) { throw new IOException("迁移记录无效。", ex); }
    }

    private void write(String id, Transaction tx) throws IOException {
        try {
            String value = new JSONObject().put("original", tx.original).put("job", tx.job)
                    .put("restoredPrivate", tx.restoredPrivate)
                    .put("target", tx.target.toString()).put("verified", tx.verified).toString();
            if (!journal.edit().putString(id, value).commit()) throw new IOException("无法保存迁移进度。");
        } catch (JSONException ex) { throw new IOException(ex); }
    }

    private Transaction begin(VideoLibrary.Entry old) throws IOException {
        String name = library.nextDownloadName(old.name);
        Uri target;
        if (Build.VERSION.SDK_INT >= 29) {
            ContentValues v = new ContentValues();
            v.put(MediaStore.MediaColumns.DISPLAY_NAME, name);
            String extension = name.substring(name.lastIndexOf('.') + 1).toLowerCase(Locale.ROOT);
            String mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension);
            v.put(MediaStore.MediaColumns.MIME_TYPE, mime == null ? "application/octet-stream" : mime);
            v.put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/" + VideoLibrary.PUBLIC_FOLDER + "/");
            v.put(MediaStore.MediaColumns.IS_PENDING, 1);
            target = resolver.insert(MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), v);
            if (target == null) throw new IOException("无法在公共下载目录创建影片。");
        } else {
            File dir = VideoLibrary.publicDirectory();
            if (!dir.isDirectory() && !dir.mkdirs()) throw new IOException("无法创建公共下载目录。");
            target = Uri.fromFile(new File(dir, name));
        }
        Transaction tx = new Transaction(old.disk, old.job, old.restoredPrivate, target, false);
        try {
            write(old.id, tx);
        } catch (IOException ex) {
            if (tx.media()) resolver.delete(target, null, null);
            throw ex;
        }
        return tx;
    }

    private String mediaColumn(Uri uri, String column) throws IOException {
        try (Cursor c = resolver.query(MediaStore.setIncludePending(uri), new String[]{column}, null, null, null)) {
            if (c == null) throw new IOException("公共媒体库暂时不可用。");
            return c.moveToFirst() ? c.getString(0) : null;
        }
    }

    private static File stage(String id) {
        return new File(VideoLibrary.publicDirectory(), ".nice-" + id + ".part");
    }

    private void publish(String id, Transaction tx, String name) throws IOException {
        if (tx.media()) {
            ContentValues publish = new ContentValues();
            publish.put(MediaStore.MediaColumns.IS_PENDING, 0);
            if (resolver.update(tx.target, publish, null, null) != 1) throw new IOException("无法发布公共影片。");
        } else {
            File part = stage(id);
            while (true) {
                interrupted();
                File chosen = new File(VideoLibrary.publicDirectory(), library.nextDownloadName(name));
                tx.target = Uri.fromFile(chosen);
                write(id, tx);
                try {
                    Files.move(part.toPath(), chosen.toPath());
                    break;
                } catch (FileAlreadyExistsException collision) { /* Another download just took this name. */ }
            }
            MediaScannerConnection.scanFile(library.context, new String[]{tx.target.getPath()}, null, null);
        }
    }

    private File oldFile(String id, Transaction tx) throws IOException {
        VideoLibrary.Entry old = new VideoLibrary.Entry(id);
        old.disk = tx.original;
        old.restoredPrivate = tx.restoredPrivate;
        return library.file(old);
    }

    private void cleanup(String id, Transaction tx) throws IOException {
        File source = oldFile(id, tx);
        if (tx.job >= 0) library.manager().remove(tx.job);
        Files.deleteIfExists(source.toPath());
        journal.edit().remove(id).commit();
    }

    private void discardUnpublished(String id, Transaction tx) throws IOException {
        if (tx.media()) {
            if ("1".equals(mediaColumn(tx.target, MediaStore.MediaColumns.IS_PENDING)))
                resolver.delete(tx.target, null, null);
        } else Files.deleteIfExists(stage(id).toPath());
        journal.edit().remove(id).commit();
    }

    private ParcelFileDescriptor open(Uri uri, String mode) throws IOException {
        ParcelFileDescriptor fd = resolver.openFileDescriptor(uri, mode);
        if (fd == null) throw new IOException("无法打开迁移目标文件。");
        return fd;
    }

    private void copyAndVerify(File source, Uri staging, boolean media) throws IOException {
        interrupted();
        tryLink(source, staging, media);
        try (FileInputStream input = new FileInputStream(source);
             ParcelFileDescriptor.AutoCloseOutputStream output = new ParcelFileDescriptor.AutoCloseOutputStream(open(staging, "rw"))) {
            long size = source.length();
            FileChannel dest = output.getChannel();
            long offset = dest.size();
            if (offset > size) throw new IOException("暂存文件大小异常。");
            long free = Environment.getExternalStorageDirectory().getUsableSpace();
            if (free > 0 && size - offset > free) throw new IOException("公共目录空间不足，请释放空间后重试。");
            input.getChannel().position(offset);
            dest.position(offset);
            byte[] buf = new byte[BUFFER];
            for (int count; (count = input.read(buf)) != -1; ) {
                interrupted();
                output.write(buf, 0, count);
            }
            dest.force(true);
        }
        if (!matches(source, staging)) {
            // Drop a damaged, unpublished copy. A retry always starts with the intact private original.
            if (media) resolver.delete(staging, null, null);
            else Files.deleteIfExists(new File(staging.getPath()).toPath());
            throw new IOException("公共副本校验失败，已保留旧版影片。");
        }
    }

    // An atomic hard link costs no additional video space and leaves the private copy usable until commit.
    // Emulated/FUSE volumes commonly disallow links; only try on an owned, empty staging destination.
    private void tryLink(File source, Uri staging, boolean media) throws IOException {
        File temp = new File(source.getParentFile(), "." + source.getName() + ".link");
        try {
            String path = media ? mediaColumn(staging, MediaStore.MediaColumns.DATA) : staging.getPath();
            if (path == null) return;
            File dest = new File(path);
            if (!VideoLibrary.publicDirectory().equals(dest.getParentFile()) || dest.length() != 0) return;
            Files.deleteIfExists(temp.toPath());
            Files.createLink(temp.toPath(), source.toPath());
            Files.move(temp.toPath(), dest.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } catch (IOException | RuntimeException unavailable) {
            // Copy through the content descriptor when the volume disallows direct access or hard links.
        } finally {
            Files.deleteIfExists(temp.toPath());
        }
    }

    private boolean matches(File source, Uri uri) throws IOException {
        try (FileInputStream original = new FileInputStream(source);
             ParcelFileDescriptor.AutoCloseInputStream copy = new ParcelFileDescriptor.AutoCloseInputStream(open(uri, "r"))) {
            if (source.length() != copy.getChannel().size()) return false;
            try {
                StructStat a = Os.fstat(original.getFD()), b = Os.fstat(copy.getFD());
                if (a.st_ino != 0 && a.st_ino == b.st_ino && a.st_dev == b.st_dev) return true;
            } catch (ErrnoException ignored) { /* Verify the bytes if a provider hides the file identity. */ }
            return MessageDigest.isEqual(digest(original), digest(copy));
        }
    }

    private static byte[] digest(FileInputStream input) throws IOException {
        MessageDigest digest;
        try { digest = MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException ex) { throw new AssertionError(ex); }
        byte[] buf = new byte[BUFFER];
        for (int n; (n = input.read(buf)) != -1; ) {
            interrupted();
            digest.update(buf, 0, n);
        }
        return digest.digest();
    }

    private static void interrupted() throws InterruptedIOException {
        if (Thread.currentThread().isInterrupted()) throw new InterruptedIOException("迁移已暂停。");
    }
}
