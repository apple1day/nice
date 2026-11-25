package com.anxiong.nicevideos;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import android.webkit.MimeTypeMap;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;

/** Private provider: only complete, verified app-owned movies expose a seekable descriptor. */
public final class OfflineMovieProvider extends ContentProvider {
    @Override public boolean onCreate() { return true; }

    private VideoLibrary.Entry lookup(Uri uri) {
        if (uri.getPathSegments().size() != 1 || getContext() == null) return null;
        VideoLibrary.Entry e = new VideoLibrary(getContext()).find(uri.getLastPathSegment());
        return e != null && e.downloaded() && VideoLibrary.READY.equals(e.state) ? e : null;
    }

    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        VideoLibrary.Entry e = lookup(uri);
        if (e == null || !"r".equals(mode)) throw new FileNotFoundException("没有可读取的本机副本。");
        try {
            File f = new VideoLibrary(getContext()).file(e);
            if (!f.isFile() || f.length() == 0 || (e.bytes >= 0 && f.length() != e.bytes))
                throw new FileNotFoundException("本机副本不完整。");
            return ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY);
        } catch (IOException ex) { throw new FileNotFoundException(ex.getMessage()); }
    }

    @Override public Cursor query(Uri uri, String[] projection, String where, String[] args, String order) {
        VideoLibrary.Entry e = lookup(uri);
        String[] columns = projection == null ? new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE} : projection;
        MatrixCursor c = new MatrixCursor(columns);
        if (e == null) return c;
        MatrixCursor.RowBuilder row = c.newRow();
        for (String key : columns) row.add(OpenableColumns.DISPLAY_NAME.equals(key) ? e.name :
                OpenableColumns.SIZE.equals(key) ? Long.valueOf(e.bytes) : null);
        return c;
    }

    @Override public String getType(Uri uri) {
        VideoLibrary.Entry e = lookup(uri);
        if (e == null) return null;
        String type = MimeTypeMap.getSingleton().getMimeTypeFromExtension(e.disk.substring(e.disk.lastIndexOf('.') + 1));
        return type == null ? "video/*" : type;
    }
    @Override public Uri insert(Uri u, ContentValues v) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri u, ContentValues v, String s, String[] a) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri u, String s, String[] a) { throw new UnsupportedOperationException(); }
}