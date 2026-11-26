package com.anxiong.nicevideos;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.database.Cursor;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.DocumentsContract;
import android.provider.OpenableColumns;
import android.text.InputType;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.*;
import java.io.IOException;
import java.util.*;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class MainActivity extends Activity {
    private static final int PICK = 30, EXPORT_FOLDER = 31;
    private static final int INK = 0xfff4f7f8, MUTED = 0xff9ca9b0, ACCENT = 0xff9ee5d6,
            BG = 0xff10171b, CARD = 0xff1b262d, ACTIVE = 0xff28423f;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService network = Executors.newSingleThreadExecutor();
    private final ExecutorService documents = Executors.newSingleThreadExecutor();
    private final ExecutorService jobs = Executors.newSingleThreadExecutor();
    private final List<Object> rows = new ArrayList<>();
    private final Map<String, VideoLibrary.Entry> sources = new HashMap<>();
    private final Map<String, VideoLibrary.Transfer> progress = new HashMap<>();
    private List<ServerVideos.Movie> remote = new ArrayList<>();
    private VideoLibrary library;
    private MovieExportTask exports;
    private String pendingExportId; // Empty string selects all completed downloads.
    private TextView exportAll;
    private Rows adapter;
    private LinearLayout panel;
    private TextView feedback;
    private String serverError = "";
    private boolean server, loading, checking, resumed;
    private int filter, fetchGeneration, pickGeneration;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        library = new VideoLibrary(this);
        exports = (MovieExportTask) getLastNonConfigurationInstance();
        if (exports == null) exports = new MovieExportTask(library);
        if (state != null) pendingExportId = state.getString("exportId");
        if (state != null) { server = state.getBoolean("server"); filter = state.getInt("filter"); }
        getWindow().setStatusBarColor(BG);
        getWindow().setNavigationBarColor(BG);
        build();
        exports.listen(this::refreshRows);
        if (server && !address().isEmpty()) fetch();
    }

    @Override protected void onSaveInstanceState(Bundle state) {
        super.onSaveInstanceState(state);
        state.putString("exportId", pendingExportId);
        state.putBoolean("server", server); state.putInt("filter", filter);
    }

    private String address() { return library.prefs.getString("server", ""); }
    private int dp(float n) { return (int)(getResources().getDisplayMetrics().density * n + .5f); }
    private GradientDrawable bg(int color, int radius) {
        GradientDrawable d = new GradientDrawable(); d.setColor(color); d.setCornerRadius(dp(radius)); return d;
    }
    private TextView text(String value, int sp, int color, boolean bold) {
        TextView v = new TextView(this);
        v.setText(value); v.setTextSize(sp); v.setTextColor(color); v.setGravity(Gravity.CENTER_VERTICAL);
        if (bold) v.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        return v;
    }
    private TextView pill(String title, boolean selected, Runnable click) {
        TextView v = text(title, 15, selected ? BG : INK, true);
        v.setGravity(Gravity.CENTER); v.setPadding(dp(12), 0, dp(12), 0); v.setMinHeight(dp(44));
        v.setBackground(bg(selected ? ACCENT : CARD, 12)); v.setFocusable(true);
        v.setOnClickListener(w -> click.run()); return v;
    }
    private LinearLayout column() {
        LinearLayout l = new LinearLayout(this); l.setOrientation(LinearLayout.VERTICAL); return l;
    }
    private LinearLayout row() {
        LinearLayout l = new LinearLayout(this); l.setGravity(Gravity.CENTER_VERTICAL); return l;
    }
    private LinearLayout.LayoutParams fillWidth(int height) { return new LinearLayout.LayoutParams(0, height, 1f); }
    private void gap(LinearLayout row) { row.addView(new View(this), dp(6), 1); }

    private void build() {
        FrameLayout viewport = new FrameLayout(this);
        viewport.setBackgroundColor(BG);
        LinearLayout root = column();
        int screen = getResources().getDisplayMetrics().widthPixels;
        viewport.addView(root, new FrameLayout.LayoutParams(Math.min(screen, dp(900)), -1, Gravity.CENTER_HORIZONTAL));
        int margin = dp(getResources().getConfiguration().screenWidthDp > 600 ? 30 : 16);
        root.setPadding(margin, dp(8), margin, 0);
        setContentView(viewport);
        LinearLayout header = row();
        root.addView(header, -1, dp(56));
        header.addView(text("Nice 视频", 25, INK, true), fillWidth(-1));
        header.addView(pill("本地", !server, () -> tab(false))); gap(header);
        header.addView(pill("服务器", server, () -> tab(true)));
        panel = column(); panel.setPadding(0, dp(8), 0, dp(8)); root.addView(panel);
        feedback = text("", 14, MUTED, false);
        feedback.setPadding(dp(2), dp(9), dp(2), dp(9)); root.addView(feedback);
        ListView list = new ListView(this);
        list.setDivider(new ColorDrawable(BG)); list.setDividerHeight(dp(5)); list.setCacheColorHint(BG);
        adapter = new Rows(); list.setAdapter(adapter);
        root.addView(list, new LinearLayout.LayoutParams(-1, 0, 1f));
        updatePanel(); refreshRows();
    }

    private void tab(boolean next) {
        if (next == server) return;
        server = next; build();
        if (server && remote.isEmpty() && !loading && !address().isEmpty()) fetch();
    }

    private void updatePanel() {
        exportAll = null;
        panel.removeAllViews();
        LinearLayout heading = row(); panel.addView(heading, -1, dp(50));
        heading.addView(text(server ? "服务器影片" : "本地影片", 21, INK, true), fillWidth(-1));
        if (server) {
            if (!address().isEmpty()) { heading.addView(pill("刷新", false, this::fetch)); gap(heading); }
            heading.addView(pill("设置地址", true, this::editServer));
            if (!address().isEmpty()) {
                TextView url = text(address(), 14, MUTED, false); url.setSingleLine();
                url.setEllipsize(TextUtils.TruncateAt.END); panel.addView(url);
            }
        } else {
            exportAll = pill("导出全部", false, () -> pickExportFolder(""));
            heading.addView(exportAll); gap(heading);
            heading.addView(pill("打开文件", true, this::pick));
            LinearLayout chips = row(); chips.setPadding(0, dp(7), 0, 0); panel.addView(chips);
            String[] names = {"全部", "收藏", "已下载"};
            for (int i = 0; i < names.length; i++) {
                final int position = i;
                TextView chip = pill(names[i], false, () -> { filter = position; updatePanel(); refreshRows(); });
                if (filter == i) { chip.setBackground(bg(ACTIVE, 12)); chip.setTextColor(ACCENT); }
                chips.addView(chip); gap(chips);
            }
        }
    }

    private void refreshRows() {
        boolean hasExport = false;
        rows.clear(); sources.clear();
        for (VideoLibrary.Entry e : library.all()) {
            if (e.downloaded()) sources.put(e.source, e);
            if (MovieExporter.eligible(e)) hasExport = true;
            if (!server && (filter == 0 || (filter == 1 && e.favorite) || (filter == 2 && e.downloaded()))) rows.add(e);
        }
        if (server) rows.addAll(remote);
        String message = "";
        if (server) {
            if (address().isEmpty()) message = "输入运行 Nice 视频服务的地址，即可下载影片到本机。";
            else if (loading) message = "正在获取影片…";
            else if (!serverError.isEmpty()) message = serverError;
            else if (rows.isEmpty()) message = "这个服务器还没有影片。";
        } else if (rows.isEmpty()) {
            message = filter == 1 ? "还没有收藏。可在影片右侧菜单中加入收藏。" : filter == 2 ?
                    "还没有离线副本。可从服务器选择影片下载。" : "点「打开文件」选择视频。手机或外接盘上的影片可直接从原位置播放。";
        }
        if (exportAll != null) {
            boolean enabled = hasExport && !exports.running();
            exportAll.setEnabled(enabled);
            exportAll.setAlpha(enabled ? 1f : .5f);
        }
        if (!server && !exports.status().isEmpty()) message = exports.status();
        feedback.setText(message); feedback.setVisibility(message.isEmpty() ? View.GONE : View.VISIBLE);
        adapter.notifyDataSetChanged();
    }

    private void pick() {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                .setType("*/*").putExtra(Intent.EXTRA_MIME_TYPES, new String[]{"video/*", "application/octet-stream", "application/x-matroska"})
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);
        try { startActivityForResult(intent, PICK); }
        catch (ActivityNotFoundException ex) { toast("系统文件选择器不可用。"); }
    }

    private void pickExportFolder(String id) {
        if (exports.running() || pendingExportId != null) return;
        Intent choose = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                .putExtra(Intent.EXTRA_LOCAL_ONLY, true)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
        pendingExportId = id;
        try { startActivityForResult(choose, EXPORT_FOLDER); }
        catch (ActivityNotFoundException ex) { pendingExportId = null; toast("系统文件夹选择器不可用。"); }
    }

    private void acceptExportFolder(int result, Intent data) {
        String id = pendingExportId;
        pendingExportId = null;
        if (id == null || result != RESULT_OK || data == null || data.getData() == null) return;
        Uri tree = data.getData();
        if (!"content".equals(tree.getScheme()) || !DocumentsContract.isTreeUri(tree)) {
            toast("请选择可写入的文件夹。");
            return;
        }
        List<VideoLibrary.Entry> selection = new ArrayList<>();
        for (VideoLibrary.Entry e : library.all()) {
            if ((id.isEmpty() || id.equals(e.id)) && MovieExporter.eligible(e))
                selection.add(e);
        }
        if (selection.isEmpty()) { toast("没有可以导出的已完成下载。"); return; }
        exports.start(selection, tree);
    }

    @Override protected void onActivityResult(int code, int result, Intent data) {
        super.onActivityResult(code, result, data);
        if (code == EXPORT_FOLDER) { acceptExportFolder(result, data); return; }
        if (code != PICK || result != RESULT_OK || data == null || data.getData() == null) return;
        Uri uri = data.getData();
        if (!"content".equals(uri.getScheme())) { toast("请选择系统文件提供方中的视频。"); return; }
        boolean durable;
        try {
            getContentResolver().takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION);
            durable = true;
        } catch (SecurityException ex) { durable = false; }
        final boolean remember = durable;
        int generation = ++pickGeneration;
        documents.execute(() -> {
            String name = "所选影片"; long bytes = -1;
            try (Cursor c = getContentResolver().query(uri, new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE},
                    null, null, null)) {
                if (c != null && c.moveToFirst()) {
                    int n = c.getColumnIndex(OpenableColumns.DISPLAY_NAME), s = c.getColumnIndex(OpenableColumns.SIZE);
                    if (n >= 0 && !c.isNull(n)) name = c.getString(n);
                    if (s >= 0 && !c.isNull(s)) bytes = c.getLong(s);
                }
            } catch (RuntimeException ignored) { /* Some providers omit optional metadata. */ }
            final String title = name;
            final long size = bytes;
            main.post(() -> {
                if (!live() || generation != pickGeneration) return;
                if (ServerVideos.playlist(title)) {
                    if (remember) {
                        try { getContentResolver().releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION); }
                        catch (SecurityException ignored) {}
                    }
                    toast("请选择影片文件，播放列表需要单独的媒体分片。"); return;
                }
                if (remember) library.remember(uri, title, size);
                refreshRows(); play(uri, title);
            });
        });
    }

    private void play(Uri uri, String title) {
        startActivity(new Intent(this, PlayerActivity.class).setData(uri).putExtra("title", title)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION));
    }

    private void activate(Object item) {
        if (item instanceof ServerVideos.Movie) {
            ServerVideos.Movie m = (ServerVideos.Movie) item;
            VideoLibrary.Entry existing = sources.get(m.url);
            if (existing != null && !VideoLibrary.FAILED.equals(existing.state)) activate(existing);
            else download(m, existing);
            return;
        }
        VideoLibrary.Entry e = (VideoLibrary.Entry) item;
        if (VideoLibrary.READY.equals(e.state)) {
            e.time = System.currentTimeMillis(); library.save(e); play(library.uri(e), e.name);
        } else if (VideoLibrary.FAILED.equals(e.state)) download(new ServerVideos.Movie(e.name, e.bytes, e.source), e);
        else confirmRemove(e);
    }

    private void download(ServerVideos.Movie m, VideoLibrary.Entry prior) {
        if (ServerVideos.playlist(m.name)) { toast("播放列表包含外部分片，无法作为单个离线影片下载。"); return; }
        try {
            library.enqueue(m, prior); refreshRows(); toast("已加入系统下载，可在「本地」查看进度。"); poll();
        } catch (IOException | RuntimeException ex) { toast(error(ex)); }
    }

    private void actions(View anchor, VideoLibrary.Entry e) {
        PopupMenu menu = new PopupMenu(this, anchor);
        menu.getMenu().add(e.favorite ? "取消收藏" : "加入收藏").setOnMenuItemClickListener(item -> {
            VideoLibrary.Entry current = library.find(e.id);
            if (current != null) { current.favorite = !current.favorite; library.save(current); refreshRows(); }
            return true;
        });
        if (MovieExporter.eligible(e)) {
            menu.getMenu().add("导出到文件夹").setEnabled(!exports.running()).setOnMenuItemClickListener(item -> {
                pickExportFolder(e.id); return true;
            });
        }
        menu.getMenu().add(!e.downloaded() ? "从最近播放移除" : VideoLibrary.TRANSFER.equals(e.state) ?
                "取消下载" : "删除本机副本").setOnMenuItemClickListener(item -> { confirmRemove(e); return true; });
        menu.show();
    }

    private void confirmRemove(VideoLibrary.Entry e) {
        boolean transfer = VideoLibrary.TRANSFER.equals(e.state);
        String title = !e.downloaded() ? "移除播放记录" : transfer ? "取消下载" : "删除本机副本";
        String hint = !e.downloaded() ? "只移除这条记录，文件管理器中的原片会保留。" :
                transfer ? "已传输的部分将被清理。" : "删除后可从服务器重新下载，服务器原片会保留。";
        new AlertDialog.Builder(this).setTitle(title).setMessage(e.name + "\n\n" + hint)
                .setNegativeButton("返回", null).setPositiveButton("确认", (d, w) -> {
                    try { library.remove(e); progress.remove(e.id); refreshRows(); }
                    catch (IOException | RuntimeException ex) { toast(error(ex)); }
                }).show();
    }

    private void editServer() {
        EditText edit = new EditText(this);
        edit.setSingleLine(); edit.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        edit.setHint("http://192.168.1.10:8106"); edit.setText(address()); edit.selectAll();
        FrameLayout wrapper = new FrameLayout(this);
        wrapper.setPadding(dp(22), dp(12), dp(22), 0); wrapper.addView(edit);
        AlertDialog d = new AlertDialog.Builder(this).setTitle("服务器地址").setView(wrapper)
                .setNegativeButton("取消", null).setPositiveButton("连接", null).create();
        d.setOnShowListener(i -> d.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
            try {
                String base = ServerVideos.address(edit.getText().toString());
                if (!base.equals(address())) remote = new ArrayList<>();
                library.prefs.edit().putString("server", base).apply();
                d.dismiss(); updatePanel(); fetch();
            } catch (IOException ex) { edit.setError(ex.getMessage()); }
        }));
        d.show();
    }

    private void fetch() {
        String base = address();
        if (base.isEmpty()) { editServer(); return; }
        int generation = ++fetchGeneration; loading = true; serverError = ""; refreshRows();
        network.execute(() -> {
            List<ServerVideos.Movie> movies = new ArrayList<>(); String problem = "";
            try { movies = ServerVideos.list(base); } catch (Exception ex) { problem = "连接失败 · " + error(ex); }
            final List<ServerVideos.Movie> result = movies; final String report = problem;
            main.post(() -> {
                if (!live() || generation != fetchGeneration) return;
                if (report.isEmpty()) remote = result;
                serverError = report; loading = false; refreshRows();
            });
        });
    }

    @Override protected void onResume() {
        super.onResume(); resumed = true;
        if (library != null) { refreshRows(); poll(); }
    }
    @Override protected void onPause() { resumed = false; main.removeCallbacks(pollLater); super.onPause(); }
    @Override public Object onRetainNonConfigurationInstance() { return exports; }

    @Override protected void onDestroy() {
        exports.listen(null);
        if (!isChangingConfigurations()) exports.close();
        main.removeCallbacksAndMessages(null); network.shutdownNow(); documents.shutdownNow(); jobs.shutdownNow();
        super.onDestroy();
    }
    private final Runnable pollLater = this::poll;

    private void poll() {
        main.removeCallbacks(pollLater);
        if (!resumed || checking) return;
        List<VideoLibrary.Entry> active = new ArrayList<>();
        for (VideoLibrary.Entry e : library.all()) if (VideoLibrary.TRANSFER.equals(e.state)) active.add(e);
        if (active.isEmpty()) return;
        checking = true;
        jobs.execute(() -> {
            Map<String, VideoLibrary.Transfer> updates = new HashMap<>();
            for (VideoLibrary.Entry e : active) {
                try { updates.put(e.id, library.check(e)); }
                catch (IOException | RuntimeException ignored) { /* Storage or service may be temporarily unavailable. */ }
            }
            main.post(() -> {
                if (!live()) return;
                checking = false;
                for (VideoLibrary.Entry old : active) {
                    VideoLibrary.Transfer t = updates.get(old.id);
                    VideoLibrary.Entry e = library.find(old.id);
                    if (t == null || e == null || old.job != e.job || !VideoLibrary.TRANSFER.equals(e.state)) continue;
                    progress.put(e.id, t);
                    if (!VideoLibrary.TRANSFER.equals(t.state)) {
                        e.state = t.state; e.error = VideoLibrary.FAILED.equals(t.state) ? t.label : "";
                        if (VideoLibrary.READY.equals(t.state)) e.bytes = t.bytes;
                        library.save(e);
                    }
                }
                if (resumed) { refreshRows(); main.postDelayed(pollLater, 1500); }
            });
        });
    }

    private boolean live() { return !isFinishing() && !isDestroyed(); }
    private void toast(String value) { Toast.makeText(this, value, Toast.LENGTH_LONG).show(); }
    private static String error(Exception ex) {
        return ex.getLocalizedMessage() == null ? "操作未完成，请稍后重试。" : ex.getLocalizedMessage();
    }
    private String size(long bytes) { return bytes >= 0 ? android.text.format.Formatter.formatFileSize(this, bytes) : ""; }

    private String description(VideoLibrary.Entry e) {
        if (VideoLibrary.FAILED.equals(e.state)) return e.error + " · 轻点重试";
        if (VideoLibrary.TRANSFER.equals(e.state)) {
            VideoLibrary.Transfer t = progress.get(e.id);
            return t == null ? "等待下载" : t.label + (t.bytes > 0 ? " · " + size(t.bytes) + (t.total > 0 ? " / " + size(t.total) : "") : "");
        }
        return (e.downloaded() ? "离线副本" : "文件") + (e.bytes >= 0 ? " · " + size(e.bytes) : "") + (e.favorite ? " · 已收藏" : "");
    }

    private final class Rows extends BaseAdapter {
        @Override public int getCount() { return rows.size(); }
        @Override public Object getItem(int position) { return rows.get(position); }
        @Override public long getItemId(int position) { return position; }

        @Override public View getView(int position, View recycled, ViewGroup parent) {
            LinearLayout cell;
            if (recycled == null) {
                cell = row(); cell.setBackground(bg(CARD, 13)); cell.setPadding(dp(13), dp(9), dp(5), dp(9));
                LinearLayout labels = column();
                TextView name = text("", 16, INK, true); name.setMaxLines(2); name.setEllipsize(TextUtils.TruncateAt.END);
                TextView detail = text("", 13, MUTED, false); detail.setPadding(0, dp(3), 0, 0);
                labels.addView(name); labels.addView(detail); cell.addView(labels, fillWidth(-2));
                TextView action = text("", 16, ACCENT, true); action.setGravity(Gravity.CENTER); action.setMinWidth(dp(48));
                cell.addView(action, new LinearLayout.LayoutParams(-2, dp(48)));
                cell.setTag(new TextView[]{name, detail, action});
            } else cell = (LinearLayout) recycled;
            TextView[] fields = (TextView[])cell.getTag();
            Object item = rows.get(position);
            if (item instanceof VideoLibrary.Entry) {
                VideoLibrary.Entry e = (VideoLibrary.Entry)item;
                fields[0].setText(e.name); fields[1].setText(description(e));
                fields[2].setText("⋮"); fields[2].setTextSize(23); fields[2].setContentDescription(e.name + "，更多操作");
                fields[2].setOnClickListener(v -> actions(v, e));
            } else {
                ServerVideos.Movie m = (ServerVideos.Movie)item;
                VideoLibrary.Entry e = sources.get(m.url);
                fields[0].setText(m.name); fields[1].setText(e == null ? size(m.bytes) : description(e));
                String label = e == null ? "下载" : VideoLibrary.READY.equals(e.state) ? "播放" :
                        VideoLibrary.FAILED.equals(e.state) ? "重试" : "取消";
                fields[2].setText(label); fields[2].setTextSize(14); fields[2].setContentDescription(label + " " + m.name);
                fields[2].setOnClickListener(v -> activate(m));
            }
            cell.setOnClickListener(v -> activate(item));
            cell.setOnLongClickListener(v -> {
                if (!(item instanceof VideoLibrary.Entry)) return false;
                actions(v, (VideoLibrary.Entry)item); return true;
            });
            return cell;
        }
    }
}
