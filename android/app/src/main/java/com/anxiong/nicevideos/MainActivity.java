package com.anxiong.nicevideos;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.CancellationSignal;
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
    private static final int PICK = 30, WRITE_DOWNLOADS = 31, EXPORT_FOLDER = 32, PICK_VR_FOLDER = 33, PICK_VR_FILE = 34;
    private enum Tab { LOCAL, VR, SERVER }
    private Tab tab = Tab.LOCAL;
    private VrFolderLibrary vrFolders;
    private Uri vrRoot;
    private final ArrayList<String> vrIds = new ArrayList<>(), vrNames = new ArrayList<>();
    private List<VrFolderLibrary.Item> vrItems = new ArrayList<>();
    private CancellationSignal vrRead;
    private String vrStatus = "";
    private static final String MIGRATION_REQUESTED = "migrateLegacyDownloads";
    private static final int PICK_FOR_UPLOAD = 47;
    private MovieExportTask exports;
    private MovieUploadTask uploads;
    private DownloadedVideoDeletion deletions;
    private ServerBatchTask serverBatch;
    private TextView downloadAll, deleteServerDownloads, moveAll;
    private String pendingMoveServer;
    private DownloadedServerDeletion.Plan serverPlan;
    private String pendingDownloadAllServer;
    private boolean preparingDeletion;
    private String pendingUploadServer;

    private static final class Transfers {
        final MovieExportTask exports;
        final MovieUploadTask uploads;
        final DownloadedVideoDeletion deletions;
        final ServerBatchTask serverBatch;
        Transfers(MovieExportTask exports, MovieUploadTask uploads, DownloadedVideoDeletion deletions, ServerBatchTask serverBatch) {
            this.serverBatch = serverBatch;
            this.exports = exports;
            this.uploads = uploads;
            this.deletions = deletions;
        }
    }

    private String pendingExportId; // Empty string selects all completed downloads.
    private TextView exportAll, clearMissing, deleteDownloads;
    private final ExecutorService migrations = Executors.newSingleThreadExecutor();
    private final Set<String> missing = new HashSet<>();
    private boolean migrating, rescanAfterMigration;
    private String migrationStatus = "";
    private ServerVideos.Movie requestedDownload;
    private String requestedRetryId;
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
    private Rows adapter;
    private LinearLayout panel;
    private TextView feedback;
    private String serverError = "";
    private boolean loading, checking, resumed;
    private int filter, fetchGeneration, pickGeneration;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        if ("com.anxiong.nicevideos.PREPARE_RESTORE".equals(getIntent().getAction())) {
            // Android 11+ provisions this app-specific folder through the framework.
            getExternalFilesDir(android.os.Environment.DIRECTORY_MOVIES);
            if (new VideoLibrary(this).all().isEmpty()) {
                // The USB restore helper force-stops this process as soon as this activity finishes.
                getSharedPreferences("download_options", MODE_PRIVATE).edit().putBoolean(MIGRATION_REQUESTED, true).commit();
            }
            finish();
            return;
        }
        library = new VideoLibrary(this);
        Transfers retained = (Transfers)getLastNonConfigurationInstance();
        exports = retained == null ? new MovieExportTask(library) : retained.exports;
        uploads = retained == null ? new MovieUploadTask(getApplicationContext().getContentResolver()) : retained.uploads;
        deletions = retained == null ? new DownloadedVideoDeletion(library) : retained.deletions;
        serverBatch = retained == null ? new ServerBatchTask(library) : retained.serverBatch;
        if (state != null) pendingDownloadAllServer = state.getString("downloadAllServer");
        if (state != null) pendingMoveServer = state.getString("moveServer");
        if (state != null) pendingUploadServer = state.getString("uploadServer");
        if (state != null) pendingExportId = state.getString("exportId");
        vrFolders = new VrFolderLibrary(this);
        if (getResources().getBoolean(R.bool.start_in_vr_library)) tab = Tab.VR;
        if (state != null) {
            tab = Tab.valueOf(state.getString("tab", state.getBoolean("server") ? "SERVER" : "LOCAL"));
            filter = state.getInt("filter");
            String root = state.getString("vrRoot");
            if (root != null) {
                vrRoot = Uri.parse(root);
                vrIds.addAll(state.getStringArrayList("vrIds")); vrNames.addAll(state.getStringArrayList("vrNames"));
            }
        }
        if (state != null && state.containsKey("downloadUrl")) {
            requestedDownload = new ServerVideos.Movie(state.getString("downloadName"),
                    state.getLong("downloadBytes"), state.getString("downloadUrl"), state.getBoolean("downloadDirect"));
            requestedRetryId = state.getString("downloadRetry");
        }
        getWindow().setStatusBarColor(BG);
        getWindow().setNavigationBarColor(BG);
        build();
        deletions.listen(() -> {
            updatePanel(); refreshRows();
            if (!deletions.running()) { checkPublicFiles(); startMigration(); }
        });
        serverBatch.listen(refreshCatalog -> {
            refreshRows();
            if (refreshCatalog) fetch();
            if (!serverBatch.running()) { poll(); startMigration(); }
        });
        exports.listen(() -> { updatePanel(); refreshRows(); });
        uploads.listen(finished -> {
            if (finished) {
                updatePanel();
                if (!uploads.status(address()).isEmpty()) fetch();
            }
            refreshRows();
        });
        if (tab == Tab.SERVER && !address().isEmpty()) fetch();
    }

    @Override protected void onSaveInstanceState(Bundle state) {
        super.onSaveInstanceState(state);
        state.putString("downloadAllServer", pendingDownloadAllServer);
        state.putString("moveServer", pendingMoveServer);
        state.putString("exportId", pendingExportId);
        state.putString("uploadServer", pendingUploadServer);
        state.putString("tab", tab.name()); state.putInt("filter", filter);
        if (vrRoot != null) {
            state.putString("vrRoot", vrRoot.toString()); state.putStringArrayList("vrIds", new ArrayList<>(vrIds));
            state.putStringArrayList("vrNames", new ArrayList<>(vrNames));
        }
        if (requestedDownload != null) {
            state.putString("downloadName", requestedDownload.name);
            state.putString("downloadUrl", requestedDownload.url);
            state.putLong("downloadBytes", requestedDownload.bytes);
            state.putBoolean("downloadDirect", requestedDownload.direct);
            state.putString("downloadRetry", requestedRetryId);
        }
    }

    private String address() { return library.serverAddress(); }
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
        header.addView(pill("本地", tab == Tab.LOCAL, () -> select(Tab.LOCAL))); gap(header);
        header.addView(pill("VR", tab == Tab.VR, () -> select(Tab.VR))); gap(header);
        header.addView(pill("服务器", tab == Tab.SERVER, () -> select(Tab.SERVER)));
        panel = column(); panel.setPadding(0, dp(8), 0, dp(8)); root.addView(panel);
        feedback = text("", 14, MUTED, false);
        feedback.setPadding(dp(2), dp(9), dp(2), dp(9)); root.addView(feedback);
        ListView list = new ListView(this);
        list.setDivider(new ColorDrawable(BG)); list.setDividerHeight(dp(5)); list.setCacheColorHint(BG);
        adapter = new Rows(); list.setAdapter(adapter);
        root.addView(list, new LinearLayout.LayoutParams(-1, 0, 1f));
        updatePanel(); refreshRows();
    }

    private void select(Tab next) {
        if (next == tab) return;
        if (vrRead != null) { vrRead.cancel(); vrRead = null; }
        tab = next; build();
        if (tab == Tab.VR) loadVrFolder();
        if (tab == Tab.SERVER && remote.isEmpty() && !loading && !address().isEmpty()) fetch();
    }

    private void updatePanel() {
        exportAll = null;
        clearMissing = null;
        deleteDownloads = null;
        downloadAll = null;
        deleteServerDownloads = null;
        moveAll = null;
        panel.removeAllViews();
        LinearLayout heading = row(); panel.addView(heading, -1, dp(50));
        if (tab == Tab.VR) {
            heading.addView(text("VR 片库", 21, INK, true), fillWidth(-1));
            heading.addView(pill("添加文件夹", false, this::pickVrFolder)); gap(heading);
            heading.addView(pill("打开影片", true, () -> pick(PICK_VR_FILE)));
            if (vrRoot != null) {
                LinearLayout navigation = row();
                panel.addView(navigation, -1, dp(48));
                navigation.addView(pill("上一级", false, this::upVrFolder)); gap(navigation);
                TextView path = text(TextUtils.join(" / ", vrNames), 14, MUTED, false);
                path.setSingleLine(); path.setEllipsize(TextUtils.TruncateAt.START);
                navigation.addView(path, fillWidth(-1)); gap(navigation);
                navigation.addView(pill("刷新", false, this::loadVrFolder));
            }
            return;
        }
        heading.addView(text(tab == Tab.SERVER ? "服务器影片" : "本地影片", 21, INK, true), fillWidth(-1));
        if (tab == Tab.SERVER) {
            if (!address().isEmpty()) { heading.addView(pill("刷新", false, this::fetch)); gap(heading); }
            heading.addView(pill("设置地址", true, this::editServer));
            if (!address().isEmpty()) {
                TextView url = text(address(), 14, MUTED, false); url.setSingleLine();
                url.setEllipsize(TextUtils.TruncateAt.END);
                LinearLayout actions = row();
                panel.addView(actions, -1, dp(48));
                actions.addView(url, fillWidth(-1)); gap(actions);
                TextView upload = pill(uploads.running() ? "上传中…" : "上传本机视频", false, () -> pick(PICK_FOR_UPLOAD));
                upload.setEnabled(!uploads.running());
                actions.addView(upload);
                LinearLayout transfers = row();
                panel.addView(transfers);
                downloadAll = pill("全部下载", false, this::confirmDownloadAll);
                transfers.addView(downloadAll);
                gap(transfers);
                deleteServerDownloads = pill("一键删除已下载视频", false, this::deleteFromServer);
                deleteServerDownloads.setTextColor(0xffffb4ab);
                transfers.addView(deleteServerDownloads);
                moveAll = pill("一键下载然后删除远程视频", true, this::moveAllVideos);
                panel.addView(moveAll, -1, dp(48));
                panel.addView(text("下载并删除：逐部下载，校验本机副本后立即删除服务器原片。停止或失败时保留未确认的原片。", 13, MUTED, false));
            }
        } else {
            exportAll = pill("导出全部", false, () -> pickExportFolder(""));
            heading.addView(exportAll); gap(heading);
            heading.addView(pill("打开文件", true, () -> pick(PICK)));
            LinearLayout downloads = row(); downloads.setPadding(0, dp(7), 0, 0); panel.addView(downloads);
            downloads.addView(pill("视频直链", false, this::directDownload)); gap(downloads);
            deleteDownloads = pill("批量删除本机副本", false, this::confirmDeleteDownloads);
            deleteDownloads.setTextColor(0xffffb4ab);
            downloads.addView(deleteDownloads);
            clearMissing = pill("清理已删除记录", false, this::confirmClearMissing);
            panel.addView(clearMissing, -2, -2);
            clearMissing.setVisibility(missing.isEmpty() ? View.GONE : View.VISIBLE);
            LinearLayout chips = row(); chips.setPadding(0, dp(7), 0, 0); panel.addView(chips);
            String[] names = {"全部", "收藏", "已下载"};
            for (int i = 0; i < names.length; i++) {
                final int position = i;
                TextView chip = pill(names[i], false, () -> { filter = position; updatePanel(); refreshRows(); });
                if (filter == i) { chip.setBackground(bg(ACTIVE, 12)); chip.setTextColor(ACCENT); }
                chips.addView(chip); gap(chips);
            }
            if (library.all().stream().anyMatch(LegacyDownloadMigration::needsMigration)) {
                TextView migrate = pill(migrating ? "正在迁移…" : "迁移历史下载", false, this::confirmMigration);
                migrate.setEnabled(!migrating && !exports.running() && !deletions.running());
                panel.addView(migrate, -1, dp(44));
            }
        }
    }

    private void refreshRows() {
        rows.clear(); sources.clear();
        boolean hasExport = false, hasDownloads = false;
        List<VideoLibrary.Entry> records = library.all();
        for (VideoLibrary.Entry e : records) {
            if (e.downloaded()) sources.putIfAbsent(VideoLibrary.downloadKey(e.source, e.direct, e.bytes), e);
            hasDownloads |= DownloadedVideoDeletion.eligible(e) && !missing.contains(e.id);
            hasExport |= MovieExporter.eligible(e) && !missing.contains(e.id);
            if (tab == Tab.LOCAL && (filter == 0 || (filter == 1 && e.favorite) || (filter == 2 && e.downloaded()))) rows.add(e);
        }
        if (tab == Tab.SERVER) rows.addAll(remote);
        String message = "";
        if (tab == Tab.VR) {
            rows.addAll(vrRoot == null ? vrFolders.roots() : vrItems);
            message = vrStatus;
            if (rows.isEmpty() && message.isEmpty())
                message = vrRoot == null ? "添加保存 VR 影片的文件夹，或直接打开一部影片。" : "此目录没有视频或子文件夹。";
        } else if (tab == Tab.SERVER) {
            if (address().isEmpty()) message = "输入运行 Nice 视频服务的地址，即可下载影片到本机。";
            else if (loading) message = "正在获取影片…";
            else if (!serverError.isEmpty()) message = serverError;
            else if (rows.isEmpty()) message = "这个服务器还没有影片。";
            String upload = uploads.status(address());
            if (!upload.isEmpty()) message = serverError.isEmpty() ? upload : upload + "\n" + serverError;
            String result = serverBatch.status(address());
            if (!result.isEmpty()) message = message.isEmpty() ? result : result + "\n" + message;
            serverPlan = DownloadedServerDeletion.plan(address(), remote, records);
            deleteServerDownloads.setText("一键删除已下载视频（" + serverPlan.size() + "）");
            boolean idle = !loading && serverError.isEmpty() && !serverBatch.running() && !deletions.running() && !migrating;
            enable(deleteServerDownloads, idle && serverPlan.size() > 0);
            enable(downloadAll, idle && remote.stream().anyMatch(ServerVideos.Movie::supportsOffline));
            moveAll.setText(serverBatch.moving() ? (serverBatch.stopping() ? "正在停止…" : "停止下载并删除") : "一键下载然后删除远程视频");
            enable(moveAll, serverBatch.moving() ? !serverBatch.stopping() : idle && !preparingDeletion && !uploads.running() && pendingUploadServer == null && remote.stream().anyMatch(ServerVideos.Movie::supportsOffline));
        } else if (rows.isEmpty()) {
            message = filter == 1 ? "还没有收藏。可在影片右侧菜单中加入收藏。" : filter == 2 ?
                    "还没有离线副本。可粘贴视频直链，或从服务器下载。" : "点「视频直链」下载影片，或点「打开文件」播放本机视频。";
        }
        if (clearMissing != null) clearMissing.setVisibility(missing.isEmpty() ? View.GONE : View.VISIBLE);
        if (deleteDownloads != null) {
            boolean enabled = hasDownloads && !serverBatch.running() && !preparingDeletion && !deletions.running() && !exports.running() && !migrating;
            deleteDownloads.setEnabled(enabled);
            deleteDownloads.setAlpha(enabled ? 1f : .5f);
        }
        if (exportAll != null) {
            boolean enabled = hasExport && !exports.running() && !migrating && !deletions.running();
            exportAll.setEnabled(enabled);
            exportAll.setAlpha(enabled ? 1f : .5f);
        }
        if (tab == Tab.LOCAL && !migrationStatus.isEmpty()) message = migrationStatus;
        if (tab == Tab.LOCAL && !exports.status().isEmpty() && !migrating) message = exports.status();
        if (tab == Tab.LOCAL && !deletions.status().isEmpty()) message = deletions.status();
        feedback.setText(message); feedback.setVisibility(message.isEmpty() ? View.GONE : View.VISIBLE);
        adapter.notifyDataSetChanged();
    }

    private void enable(TextView button, boolean enabled) {
        button.setEnabled(enabled);
        button.setAlpha(enabled ? 1f : .5f);
    }

    private VideoLibrary.Entry source(ServerVideos.Movie movie) {
        return sources.get(VideoLibrary.downloadKey(movie.url, movie.direct, movie.bytes));
    }

    private void moveAllVideos() {
        if (serverBatch.moving()) { serverBatch.stopMove(); return; }
        if (moveAll == null || !moveAll.isEnabled()) return;
        if (!canWriteDownloads()) {
            pendingMoveServer = address();
            requestDownloadPermission();
            return;
        }
        serverBatch.move(address(), new ArrayList<>(remote));
    }

    private void resumeMove() {
        if (pendingMoveServer == null || loading || !canWriteDownloads()) return;
        boolean start = pendingMoveServer.equals(address()) && moveAll != null && moveAll.isEnabled();
        pendingMoveServer = null;
        if (start) moveAllVideos();
    }

    private void confirmDownloadAll() {
        if (!downloadAll.isEnabled()) return;
        if (!canWriteDownloads()) {
            pendingDownloadAllServer = address();
            requestDownloadPermission();
            return;
        }
        String base = address();
        List<ServerVideos.Movie> selection = new ArrayList<>(remote);
        new AlertDialog.Builder(this).setTitle("下载全部支持的视频？")
                .setMessage("影片将保存到 Download/NiceVideos。已下载和下载中的影片会自动跳过。")
                .setNegativeButton("取消", null).setPositiveButton("加入下载队列", (dialog, which) -> {
                    if (base.equals(address())) serverBatch.download(base, selection);
                }).show();
    }

    private void deleteFromServer() {
        if (deleteServerDownloads.isEnabled() && serverPlan != null && serverPlan.size() > 0)
            serverBatch.delete(address(), serverPlan);
    }

    private void pickVrFolder() {
        Intent choose = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).putExtra(Intent.EXTRA_LOCAL_ONLY, true)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);
        try { startActivityForResult(choose, PICK_VR_FOLDER); }
        catch (ActivityNotFoundException ex) { toast("系统文件夹选择器不可用。"); }
    }

    private void enterVrFolder(VrFolderLibrary.Item folder) {
        if (vrRoot == null) {
            vrRoot = folder.uri;
            vrIds.add(DocumentsContract.getTreeDocumentId(vrRoot));
        } else {
            String child = DocumentsContract.getDocumentId(folder.uri);
            if (vrIds.contains(child)) return;
            vrIds.add(child);
        }
        vrNames.add(folder.name);
        updatePanel(); loadVrFolder();
    }

    private void resetVrPath() {
        vrRoot = null; vrIds.clear(); vrNames.clear();
    }

    private void upVrFolder() {
        if (vrIds.size() <= 1) resetVrPath();
        else { vrIds.remove(vrIds.size() - 1); vrNames.remove(vrNames.size() - 1); }
        updatePanel(); loadVrFolder();
    }

    @Override public void onBackPressed() {
        if (tab == Tab.VR && vrRoot != null) upVrFolder();
        else super.onBackPressed();
    }

    private void loadVrFolder() {
        if (vrRead != null) vrRead.cancel();
        vrRead = null;
        vrItems = new ArrayList<>(); vrStatus = vrRoot == null ? "" : "正在读取文件夹…";
        refreshRows();
        if (vrRoot == null) return;
        final Uri tree = vrRoot;
        final String parent = vrIds.get(vrIds.size() - 1);
        final CancellationSignal read = new CancellationSignal();
        vrRead = read;
        documents.execute(() -> {
            List<VrFolderLibrary.Item> items = Collections.emptyList();
            String problem = "";
            try { items = vrFolders.children(tree, parent, read); }
            catch (SecurityException ex) { problem = "文件夹授权已失效，请点「添加文件夹」重新选择。"; }
            catch (IllegalArgumentException ex) { problem = "文件夹已移动或不可用，请返回上一级或重新选择。"; }
            catch (IOException | RuntimeException ex) { problem = error(ex); }
            List<VrFolderLibrary.Item> result = items;
            String message = problem;
            main.post(() -> {
                if (!live() || read != vrRead || tab != Tab.VR) return;
                vrRead = null; vrItems = result; vrStatus = message;
                refreshRows();
            });
        });
    }

    private void pick(int request) {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                .setType("*/*").putExtra(Intent.EXTRA_MIME_TYPES, new String[]{"video/*", "application/octet-stream", "application/x-matroska"})
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);
        if (request == PICK_FOR_UPLOAD) {
            if (serverBatch.moving() || uploads.running() || pendingUploadServer != null || address().isEmpty()) return;
            pendingUploadServer = address();
            intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true).putExtra(Intent.EXTRA_LOCAL_ONLY, true);
        }
        try { startActivityForResult(intent, request); }
        catch (ActivityNotFoundException ex) {
            if (request == PICK_FOR_UPLOAD) pendingUploadServer = null;
            toast("系统文件选择器不可用。");
        }
    }

    private void pickExportFolder(String id) {
        if (migrating || exports.running() || deletions.running() || pendingExportId != null) return;
        deletions.clearStatus();
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
            if ((id.isEmpty() || id.equals(e.id)) && MovieExporter.eligible(e) && !missing.contains(e.id))
                selection.add(e);
        }
        if (selection.isEmpty()) { toast("没有可以导出的已完成下载。"); return; }
        exports.start(selection, tree);
    }

    @Override protected void onActivityResult(int code, int result, Intent data) {
        super.onActivityResult(code, result, data);
        if (code == PICK_FOR_UPLOAD) {
            String target = pendingUploadServer;
            pendingUploadServer = null;
            if (serverBatch.moving() || target == null || result != RESULT_OK || data == null) return;
            Set<Uri> selected = new LinkedHashSet<>();
            if (data.getData() != null) selected.add(data.getData());
            android.content.ClipData selection = data.getClipData();
            if (selection != null) {
                for (int i = 0; i < selection.getItemCount(); i++) {
                    Uri uri = selection.getItemAt(i).getUri();
                    if (uri != null) selected.add(uri);
                }
            }
            uploads.start(target, new ArrayList<>(selected));
            updatePanel();
            return;
        }
        if (code == EXPORT_FOLDER) { acceptExportFolder(result, data); return; }
        if (code == PICK_VR_FOLDER) {
            if (result != RESULT_OK || data == null || data.getData() == null) return;
            Uri tree = data.getData();
            documents.execute(() -> {
                try {
                    VrFolderLibrary.Item root = vrFolders.add(tree);
                    main.post(() -> {
                        if (live() && tab == Tab.VR) { resetVrPath(); enterVrFolder(root); }
                    });
                } catch (IOException | RuntimeException ex) {
                    main.post(() -> { if (live()) { toast("无法保存文件夹授权：" + error(ex)); refreshRows(); } });
                }
            });
            return;
        }
        if ((code != PICK && code != PICK_VR_FILE) || result != RESULT_OK || data == null || data.getData() == null) return;
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
                refreshRows(); play(uri, title, code == PICK_VR_FILE);
            });
        });
    }

    private void play(Uri uri, String title, boolean startInVr) {
        startActivity(new Intent(this, PlayerActivity.class).setData(uri).putExtra("title", title)
                .putExtra(PlayerActivity.EXTRA_START_IN_VR, startInVr)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION));
    }

    private void activate(Object item) {
        if (item instanceof VrFolderLibrary.Item) {
            VrFolderLibrary.Item entry = (VrFolderLibrary.Item)item;
            if (entry.folder) enterVrFolder(entry);
            else play(entry.uri, entry.name, true);
            return;
        }
        if (item instanceof ServerVideos.Movie) {
            ServerVideos.Movie m = (ServerVideos.Movie) item;
            if (!m.supportsOffline() || serverBatch.running()) return;
            VideoLibrary.Entry existing = source(m);
            if (existing != null && !VideoLibrary.FAILED.equals(existing.state)) activate(existing);
            else download(m, existing);
            return;
        }
        VideoLibrary.Entry e = (VideoLibrary.Entry) item;
        if (VideoLibrary.READY.equals(e.state)) {
            if (missing.contains(e.id)) {
                new AlertDialog.Builder(this).setTitle("公共目录中的影片已移走或删除")
                        .setMessage(e.name).setNegativeButton("返回", null)
                        .setPositiveButton("重新下载", (d, w) ->
                                download(new ServerVideos.Movie(e.name, e.bytes, e.source, e.direct), e)).show();
                return;
            }
            VideoLibrary.Entry current = library.touch(e.id);
            if (current != null) play(library.uri(current), current.name, false);
        } else if (VideoLibrary.FAILED.equals(e.state)) download(new ServerVideos.Movie(e.name, e.bytes, e.source, e.direct), e);
        else confirmRemove(e);
    }

    private void download(ServerVideos.Movie m, VideoLibrary.Entry prior) {
        if (serverBatch.moving()) { toast("请先停止下载并删除。"); return; }
        if (ServerVideos.playlist(m.name)) { toast("播放列表包含外部分片，无法作为单个离线影片下载。"); return; }
        if (!canWriteDownloads()) {
            requestedDownload = m;
            requestedRetryId = prior == null ? null : prior.id;
            requestDownloadPermission();
            return;
        }
        try {
            if (!library.enqueue(m, prior)) { toast("本地列表中已有这部影片或下载任务。"); return; }
            if (prior != null) missing.remove(prior.id);
            if (m.direct && tab == Tab.LOCAL && filter == 1) { filter = 0; updatePanel(); }
            refreshRows(); toast("已开始下载到 Download/NiceVideos"); poll();
        } catch (IOException | RuntimeException ex) { toast(error(ex)); }
    }

    private void actions(View anchor, VideoLibrary.Entry e) {
        PopupMenu menu = new PopupMenu(this, anchor);
        if (VideoLibrary.READY.equals(e.state) && !missing.contains(e.id)) {
            menu.getMenu().add("以 VR 模式播放").setOnMenuItemClickListener(item -> {
                VideoLibrary.Entry current = library.touch(e.id);
                if (current != null) play(library.uri(current), current.name, true);
                return true;
            });
        }
        menu.getMenu().add(e.favorite ? "取消收藏" : "加入收藏").setOnMenuItemClickListener(item -> {
            library.toggleFavorite(e.id);
            refreshRows();
            return true;
        });
        if (MovieExporter.eligible(e) && !missing.contains(e.id)) {
            menu.getMenu().add("导出到文件夹").setEnabled(!migrating && !exports.running() && !deletions.running()).setOnMenuItemClickListener(item -> {
                pickExportFolder(e.id);
                return true;
            });
        }
        if (e.publicDownload && !VideoLibrary.TRANSFER.equals(e.state)) {
            menu.getMenu().add("从列表移除").setEnabled(!serverBatch.running()).setOnMenuItemClickListener(item -> {
                if (serverBatch.running()) return true;
                library.forget(e); missing.remove(e.id); refreshRows();
                return true;
            });
            if (missing.contains(e.id)) { menu.show(); return; }
        }
        menu.getMenu().add(!e.downloaded() ? "从最近播放移除" : VideoLibrary.TRANSFER.equals(e.state) ?
                "取消下载" : "删除本机副本").setEnabled(!serverBatch.running()).setOnMenuItemClickListener(item -> { confirmRemove(e); return true; });
        menu.show();
    }

    private void confirmRemove(VideoLibrary.Entry e) {
        if (serverBatch.running()) return;
        boolean transfer = VideoLibrary.TRANSFER.equals(e.state);
        String title = !e.downloaded() ? "移除播放记录" : transfer ? "取消下载" : "删除本机副本";
        String hint = !e.downloaded() ? "只移除这条记录，文件管理器中的原片会保留。" :
                transfer ? "已传输的部分将被清理。" : e.publicDownload ?
                        "这会删除公共下载目录中的视频文件，其他播放器也将无法打开它。" :
                        "这会删除此设备上的离线文件和下载记录。";
        new AlertDialog.Builder(this).setTitle(title).setMessage(e.name + "\n\n" + hint)
                .setNegativeButton("返回", null).setPositiveButton("确认", (d, w) -> {
                    if (serverBatch.running()) return;
                    try { library.remove(e); progress.remove(e.id); refreshRows(); }
                    catch (IOException | RuntimeException ex) { toast(error(ex)); }
                }).show();
    }

    private void directDownload() {
        LinearLayout form = column();
        form.setPadding(dp(22), dp(10), dp(22), 0);
        EditText url = new EditText(this);
        url.setSingleLine(); url.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        url.setHint("https://example.com/video.mp4"); form.addView(url);
        EditText name = new EditText(this);
        name.setSingleLine(); name.setHint("文件名（选填，可含扩展名）"); form.addView(name);
        AlertDialog dialog = new AlertDialog.Builder(this).setTitle("视频直链")
                .setMessage("粘贴视频文件的下载地址。影片将保存到 Download/NiceVideos。")
                .setView(form).setNegativeButton("取消", null).setPositiveButton("开始下载", null).create();
        dialog.setOnShowListener(shown -> dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
            try {
                ServerVideos.Movie movie = ServerVideos.direct(url.getText().toString(), name.getText().toString());
                dialog.dismiss(); download(movie, source(movie));
            } catch (IOException ex) { url.setError(ex.getMessage()); }
        }));
        dialog.show();
    }

    private void confirmDeleteDownloads() {
        if (serverBatch.running() || preparingDeletion || deletions.running() || migrating || exports.running() || pendingExportId != null) return;
        preparingDeletion = true;
        refreshRows();
        jobs.execute(() -> {
            DownloadedVideoDeletion.Plan plan = deletions.prepare();
            main.post(() -> {
                if (!live()) return;
                preparingDeletion = false;
                refreshRows();
                if (!resumed || tab != Tab.LOCAL || serverBatch.running() || migrating || exports.running()) return;
                if (plan.copies.isEmpty()) {
                    toast(plan.unavailable == 0 ? "没有可删除的已下载视频。" : "暂时无法访问已下载的视频，请稍后重试。");
                    return;
                }
                String hint = "将删除 " + plan.copies.size() + " 部已下载视频，包括收藏中的下载。"
                        + "本机文件和对应的下载记录都会删除，其他播放器也无法再打开这些副本。"
                        + "服务器原片、另存的副本和手动打开的影片会保留。"
                        + (plan.unavailable == 0 ? "" : "\n另有 " + plan.unavailable + " 部暂时无法核对，将跳过。");
                new AlertDialog.Builder(this).setTitle("批量删除本机副本").setMessage(hint)
                        .setNegativeButton("取消", null).setPositiveButton("确认删除", (dialog, which) -> {
                            if (serverBatch.running() || migrating || exports.running() || pendingExportId != null) {
                                toast("请等当前文件操作完成后重试。"); return;
                            }
                            exports.clearStatus();
                            migrationStatus = "";
                            deletions.start(plan);
                        }).show();
            });
        });
    }

    private void confirmClearMissing() {
        Set<String> candidates = new HashSet<>(missing);
        new AlertDialog.Builder(this).setTitle("清理已删除记录")
                .setMessage("将从本地列表移除 " + candidates.size() + " 条找不到公共文件的记录。")
                .setNegativeButton("取消", null).setPositiveButton("清理", (d, w) -> jobs.execute(() -> {
                    int removed = 0;
                    for (String id : candidates) if (library.forgetIfMissing(id)) removed++;
                    final int count = removed;
                    main.post(() -> {
                        if (!live()) return;
                        missing.removeAll(candidates); refreshRows(); checkPublicFiles();
                        toast("已清理 " + count + " 条记录。");
                    });
                })).show();
    }

    private void editServer() {
        if (serverBatch.moving()) { toast("请先停止下载并删除。"); return; }
        EditText edit = new EditText(this);
        edit.setSingleLine(); edit.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        edit.setHint(ServerVideos.DEFAULT_ADDRESS); edit.setText(address()); edit.selectAll();
        FrameLayout wrapper = new FrameLayout(this);
        wrapper.setPadding(dp(22), dp(12), dp(22), 0); wrapper.addView(edit);
        AlertDialog d = new AlertDialog.Builder(this).setTitle("服务器地址").setView(wrapper)
                .setNegativeButton("取消", null).setPositiveButton("连接", null).create();
        d.setOnShowListener(i -> d.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
            try {
                if (serverBatch.moving()) { d.dismiss(); return; }
                String base = ServerVideos.address(edit.getText().toString());
                if (!base.equals(address())) {
                    serverBatch.serverChanged();
                    remote = new ArrayList<>();
                    pendingDownloadAllServer = null;
                    pendingMoveServer = null;
                }
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
                serverError = report; loading = false; refreshRows(); resumeDownloadAll(); resumeMove();
            });
        });
    }

    private void resumeDownloadAll() {
        if (pendingDownloadAllServer == null || loading || !canWriteDownloads()) return;
        boolean show = pendingDownloadAllServer.equals(address()) && downloadAll != null && downloadAll.isEnabled();
        pendingDownloadAllServer = null;
        if (show) confirmDownloadAll();
    }

    private boolean canWriteDownloads() {
        return Build.VERSION.SDK_INT >= 29 || checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE)
                == PackageManager.PERMISSION_GRANTED;
    }

    private void requestDownloadPermission() {
        requestPermissions(new String[]{Manifest.permission.WRITE_EXTERNAL_STORAGE}, WRITE_DOWNLOADS);
    }

    @Override public void onRequestPermissionsResult(int code, String[] permissions, int[] grants) {
        super.onRequestPermissionsResult(code, permissions, grants);
        if (code != WRITE_DOWNLOADS) return;
        ServerVideos.Movie movie = requestedDownload;
        String retryId = requestedRetryId;
        requestedDownload = null;
        requestedRetryId = null;
        if (!canWriteDownloads()) {
            pendingDownloadAllServer = null;
            pendingMoveServer = null;
            toast("保存到公共下载目录需要存储权限。已有离线影片仍可播放。");
            return;
        }
        resumeDownloadAll(); resumeMove();
        if (movie != null) download(movie, retryId == null ? source(movie) : library.find(retryId));
        startMigration();
    }

    private void checkPublicFiles() {
        jobs.execute(() -> {
            Set<String> absent = new HashSet<>();
            for (VideoLibrary.Entry e : library.all()) {
                if (library.missingPublicFile(e)) absent.add(e.id);
            }
            main.post(() -> {
                if (!live()) return;
                missing.clear(); missing.addAll(absent); refreshRows();
            });
        });
    }

    private void confirmMigration() {
        new AlertDialog.Builder(this).setTitle("迁移历史下载？")
                .setMessage("影片会移到 Download/NiceVideos，校验成功后会清理旧文件。要同时保留原件，请使用「导出全部」。")
                .setNegativeButton("取消", null).setPositiveButton("开始迁移", (d, w) -> {
                    exports.clearStatus();
                    deletions.clearStatus();
                    getSharedPreferences("download_options", MODE_PRIVATE).edit().putBoolean(MIGRATION_REQUESTED, true).apply();
                    if (canWriteDownloads()) startMigration();
                    else requestDownloadPermission();
                }).show();
    }

    private void startMigration() {
        if (serverBatch.running() || !canWriteDownloads() || exports.running() || deletions.running() || pendingExportId != null) return;
        boolean batch = getSharedPreferences("download_options", MODE_PRIVATE).getBoolean(MIGRATION_REQUESTED, false);
        LegacyDownloadMigration migration = new LegacyDownloadMigration(library);
        Set<String> pending = migration.pendingIds();
        if (!batch && pending.isEmpty()) return;
        if (migrating) { rescanAfterMigration = true; return; }
        migrating = true;
        updatePanel();
        migrations.execute(() -> {
            String problem = "";
            int moved = 0;
            try {
                migration.recover();
            } catch (IOException | RuntimeException ex) { problem = error(ex); }
            for (VideoLibrary.Entry entry : library.all()) {
                if (Thread.currentThread().isInterrupted()) return;
                if ((!batch && !pending.contains(entry.id)) || !LegacyDownloadMigration.needsMigration(entry)) continue;
                main.post(() -> {
                    if (live()) { migrationStatus = "正在迁移：" + entry.name; refreshRows(); }
                });
                try {
                    if (migration.migrate(entry.id)) moved++;
                } catch (IOException | RuntimeException ex) {
                    if (problem.isEmpty()) problem = entry.name + " · " + error(ex);
                }
            }
            String summary = !problem.isEmpty() ? "迁移待重试：" + problem :
                    moved > 0 ? moved + " 个视频已迁移到 Download/NiceVideos" : "";
            main.post(() -> {
                if (!live()) return;
                migrating = false; migrationStatus = summary;
                if (library.all().stream().noneMatch(e -> LegacyDownloadMigration.needsMigration(e)
                        || (e.downloaded() && !e.publicDownload && VideoLibrary.TRANSFER.equals(e.state))))
                    getSharedPreferences("download_options", MODE_PRIVATE).edit().remove(MIGRATION_REQUESTED).apply();
                updatePanel(); refreshRows();
                if (rescanAfterMigration) { rescanAfterMigration = false; startMigration(); }
            });
        });
    }

    @Override protected void onResume() {
        super.onResume(); resumed = true;
        if (library != null) {
            updatePanel(); refreshRows(); poll(); checkPublicFiles(); startMigration();
            if (tab == Tab.VR) loadVrFolder();
        }
    }
    @Override protected void onPause() { resumed = false; main.removeCallbacks(pollLater); super.onPause(); }
    @Override public Object onRetainNonConfigurationInstance() { return new Transfers(exports, uploads, deletions, serverBatch); }

    @Override protected void onDestroy() {
        if (vrRead != null) vrRead.cancel();
        if (exports != null) {
            exports.listen(null);
            if (!isChangingConfigurations()) exports.close();
        }
        if (deletions != null) {
            deletions.listen(null);
            if (!isChangingConfigurations()) deletions.close();
        }
        if (serverBatch != null) {
            serverBatch.listen(null);
            if (!isChangingConfigurations()) serverBatch.close();
        }
        if (uploads != null) {
            uploads.listen(null);
            if (!isChangingConfigurations()) uploads.close();
        }
        main.removeCallbacksAndMessages(null); network.shutdownNow(); documents.shutdownNow(); jobs.shutdownNow(); migrations.shutdownNow();
        super.onDestroy();
    }
    private final Runnable pollLater = this::poll;

    private void poll() {
        main.removeCallbacks(pollLater);
        if (!resumed || checking || serverBatch.moving()) return;
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
                if (serverBatch.moving()) return;
                boolean legacyFinished = false;
                for (VideoLibrary.Entry old : active) {
                    VideoLibrary.Transfer t = updates.get(old.id);
                    VideoLibrary.Entry e = library.find(old.id);
                    if (t == null || e == null || old.job != e.job || !VideoLibrary.TRANSFER.equals(e.state)) continue;
                    progress.put(e.id, t);
                    if (!VideoLibrary.TRANSFER.equals(t.state)) {
                        e.state = t.state; e.error = VideoLibrary.FAILED.equals(t.state) ? t.label : "";
                        if (VideoLibrary.READY.equals(t.state)) {
                            e.bytes = t.bytes;
                            if (!t.publicUri.isEmpty()) e.publicUri = t.publicUri;
                            if (!t.disk.isEmpty()) e.disk = t.disk;
                            legacyFinished |= LegacyDownloadMigration.needsMigration(e);
                        }
                        library.save(e);
                    }
                }
                if (legacyFinished) { updatePanel(); startMigration(); }
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
        if (missing.contains(e.id)) return "公共文件已移走或删除 · 轻点重新下载";
        String location = e.publicDownload ? "Download/NiceVideos/" + e.disk : e.downloaded() ? "旧版离线副本" : "文件";
        return location + (e.bytes >= 0 ? " · " + size(e.bytes) : "") + (e.favorite ? " · 已收藏" : "");
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
            enable(fields[2], true);
            Object item = rows.get(position);
            if (item instanceof VrFolderLibrary.Item) {
                VrFolderLibrary.Item e = (VrFolderLibrary.Item)item;
                boolean root = vrRoot == null;
                fields[0].setText(e.name);
                fields[1].setText(e.folder ? "文件夹" : size(e.bytes));
                fields[2].setText(root ? "⋮" : e.folder ? "打开" : "VR 播放");
                fields[2].setTextSize(root ? 23 : 14);
                fields[2].setContentDescription(e.name + (root ? "，文件夹操作" : e.folder ? "，打开" : "，VR 播放"));
                fields[2].setOnClickListener(v -> {
                    if (!root) { activate(e); return; }
                    PopupMenu menu = new PopupMenu(MainActivity.this, v);
                    menu.getMenu().add("打开文件夹").setOnMenuItemClickListener(m -> { enterVrFolder(e); return true; });
                    menu.getMenu().add("从 VR 片库移除").setOnMenuItemClickListener(m -> {
                        vrFolders.forget(e.uri); refreshRows(); return true;
                    });
                    menu.show();
                });
            } else if (item instanceof VideoLibrary.Entry) {
                VideoLibrary.Entry e = (VideoLibrary.Entry)item;
                fields[0].setText(e.name); fields[1].setText(description(e));
                fields[2].setText("⋮"); fields[2].setTextSize(23); fields[2].setContentDescription(e.name + "，更多操作");
                fields[2].setOnClickListener(v -> actions(v, e));
            } else {
                ServerVideos.Movie m = (ServerVideos.Movie)item;
                VideoLibrary.Entry e = source(m);
                fields[0].setText(m.name); fields[1].setText(e == null ? size(m.bytes) : description(e));
                String label = !m.supportsOffline() ? "不支持下载" : e == null ? "下载" : missing.contains(e.id) ? "重新下载" : VideoLibrary.READY.equals(e.state) ? "播放" :
                        VideoLibrary.FAILED.equals(e.state) ? "重试" : "取消";
                fields[2].setText(label); fields[2].setTextSize(14); fields[2].setContentDescription(label + " " + m.name);
                fields[2].setOnClickListener(v -> activate(m));
                enable(fields[2], m.supportsOffline() && !serverBatch.running());
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
