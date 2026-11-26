package com.anxiong.nicevideos;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.pm.ActivityInfo;
import android.graphics.Color;
import android.graphics.Typeface;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.Surface;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.SeekBar;
import android.widget.TextView;
import android.widget.Toast;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.UUID;

public final class PlayerActivity extends Activity implements MovieSurface.Listener, MovieSession.Listener {
    static final String EXTRA_START_IN_VR = "startInVr";
    private static final int STEPS = 10000;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Runnable hide = () -> showControls(false);
    private final VideoFrameWatch frameWatch = new VideoFrameWatch();
    private final BroadcastReceiver noisy = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) {
            if (AudioManager.ACTION_AUDIO_BECOMING_NOISY.equals(i.getAction())) pause();
        }
    };
    private MovieSurface movie;
    private Surface surface, replaceAfterRelease;
    private boolean needFreshOutput;
    private MovieSession session;
    private VrLookControls look;
    private VrFormat vrFormat;
    private float fieldOfView = 80;
    private boolean inVr, followHead, softwareDecoder, releasingSession;
    private LinearLayout vrActions;
    private Button recenter, headsetButton, headButton;
    private TextView vrSummary;
    private LinearLayout header, footer;
    private TextView statusLabel, elapsed, total;
    private Button play, formats, fullscreen, retry;
    private SeekBar bar;
    private Uri uri;
    private SharedPreferences bookmarks;
    private String bookmarkKey;
    private String lastTrackReport = "视频轨道  等待识别";
    private String outputEvent = "首次打开";
    private long framesAtOpen;
    private int inputNumber;
    private int width, height;
    private long duration, position, lastSave;
    private long scrubTarget = -1, discreteTarget = -1, displayedSecond = -1;
    private final Runnable commitDiscreteSeek = () -> jump(discreteTarget);
    private boolean stalledPicture, playBeforeFailure;
    private boolean active, prepared, failed, ended, firstFrame, playing, wantsPlay = true;
    private boolean hasFocus, resumeOnGain, dragging, controlsVisible = true, dialogOpen, userFullscreen;
    private AudioManager audio;
    private AudioFocusRequest focus;

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        uri = getIntent().getData();
        if (uri == null || !("content".equals(uri.getScheme()) || "file".equals(uri.getScheme()))) {
            finish();
            return;
        }
        bookmarks = getSharedPreferences("video_positions", MODE_PRIVATE);
        bookmarkKey = UUID.nameUUIDFromBytes(uri.toString().getBytes(StandardCharsets.UTF_8)).toString();
        position = Math.max(0, bookmarks.getLong(bookmarkKey, 0));
        readVrSettings();
        if (state == null && getIntent().getBooleanExtra(EXTRA_START_IN_VR, false)) inVr = true;
        if (state != null) {
            position = state.getLong("position", position);
            wantsPlay = state.getBoolean("wantsPlay", false);
            inVr = state.getBoolean("inVr", inVr);
            softwareDecoder = state.getBoolean("softwareDecoder", false);
            userFullscreen = state.getBoolean("fullscreen", false);
        }
        audio = (AudioManager) getSystemService(AUDIO_SERVICE);
        setVolumeControlStream(AudioManager.STREAM_MUSIC);
        focus = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
                .setWillPauseWhenDucked(true).setOnAudioFocusChangeListener(this::focusChanged, main).build();
        buildScreen();
        applyMode();
    }

    private void buildScreen() {
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        movie = new MovieSurface(this, this);
        look = new VrLookControls(this, movie, () -> { fieldOfView = look.fieldOfView(); saveVrSettings(); }, this::togglePlayback);
        movie.setContentDescription("视频画面");
        movie.setOnClickListener(v -> showControls(!controlsVisible));
        root.addView(movie, new FrameLayout.LayoutParams(-1, -1));

        header = new LinearLayout(this);
        header.setGravity(Gravity.CENTER_VERTICAL);
        header.setBackgroundColor(0xCF151519);
        TextView title = label(17);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        title.setSingleLine(true);
        title.setEllipsize(TextUtils.TruncateAt.END);
        title.setText(displayTitle());
        LinearLayout heading = new LinearLayout(this);
        heading.setOrientation(LinearLayout.VERTICAL);
        heading.addView(title);
        vrSummary = label(13);
        vrSummary.setSingleLine(true);
        vrSummary.setEllipsize(TextUtils.TruncateAt.END);
        heading.addView(vrSummary);
        header.addView(heading, new LinearLayout.LayoutParams(0, -2, 1));
        recenter = button("回正", "视角回正", v -> { look.recenter(); armControls(); });
        header.addView(recenter);
        header.addView(button("片源信息", "片源信息", v -> showDetails()));
        header.addView(button("关闭", "关闭播放器", v -> finish()));
        root.addView(header, new FrameLayout.LayoutParams(-1, -2, Gravity.TOP));

        LinearLayout feedback = new LinearLayout(this);
        feedback.setOrientation(LinearLayout.VERTICAL);
        feedback.setGravity(Gravity.CENTER);
        feedback.setPadding(dp(18), 0, dp(18), 0);
        statusLabel = label(15);
        statusLabel.setGravity(Gravity.CENTER);
        statusLabel.setBackgroundColor(0xD0111114);
        statusLabel.setPadding(dp(12), dp(8), dp(12), dp(8));
        feedback.addView(statusLabel);
        retry = button("重新打开", "重新打开视频", v -> restart());
        feedback.addView(retry);
        root.addView(feedback, new FrameLayout.LayoutParams(-1, -2, Gravity.CENTER));

        footer = new LinearLayout(this);
        footer.setOrientation(LinearLayout.VERTICAL);
        footer.setBackgroundColor(0xD016161A);
        LinearLayout timeline = new LinearLayout(this);
        timeline.setGravity(Gravity.CENTER_VERTICAL);
        elapsed = label(13); total = label(13);
        elapsed.setText("00:00"); total.setText("00:00");
        timeline.addView(elapsed);
        bar = new SeekBar(this);
        bar.setMax(STEPS);
        bar.setContentDescription("播放进度");
        bar.setEnabled(false);
        timeline.addView(bar, new LinearLayout.LayoutParams(0, dp(44), 1));
        timeline.addView(total);
        footer.addView(timeline);
        bar.setOnTouchListener((v, event) -> {
            // SeekBar also fires onStopTrackingTouch for ACTION_CANCEL.
            if (event.getActionMasked() == MotionEvent.ACTION_CANCEL) endScrub(false);
            return false;
        });
        bar.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onStartTrackingTouch(SeekBar b) { beginScrub(); }
            @Override public void onProgressChanged(SeekBar b, int value, boolean user) {
                if (!user || !prepared || duration <= 0) return;
                long target = duration * value / STEPS;
                if (dragging) previewScrub(target);
                else {
                    // Keyboard and accessibility progress events have no touch-end callback.
                    discreteTarget = target;
                    showElapsed(target);
                    main.removeCallbacks(commitDiscreteSeek);
                    main.postDelayed(commitDiscreteSeek, 180);
                }
            }
            @Override public void onStopTrackingTouch(SeekBar b) { endScrub(true); }
        });
        LinearLayout actions = new LinearLayout(this);
        play = button("暂停", "播放或暂停", v -> togglePlayback());
        formats = button("VR", "进入 VR", v -> {
            if (inVr) chooseFormat();
            else {
                inVr = true;
                applyMode(); saveVrSettings(); showControls(true);
                if (panorama()) Toast.makeText(this, "拖动环顾，双指缩放。双击动作可在 VR 设置中更改。", Toast.LENGTH_SHORT).show();
            }
        });
        fullscreen = button("全屏", "全屏", v -> {
            boolean next = !wide();
            if (!next && inVr && vrFormat.headset) {
                vrFormat = new VrFormat(vrFormat.projection, vrFormat.layout, false);
                saveVrSettings();
            }
            userFullscreen = next;
            applyMode(); showControls(true);
        });
        vrActions = new LinearLayout(this);
        headsetButton = button("双眼眼镜", "切换眼镜显示", v -> {
            vrFormat = new VrFormat(vrFormat.projection, vrFormat.layout, !vrFormat.headset);
            applyMode(); saveVrSettings(); showControls(true);
        });
        headButton = button("陀螺仪：关", "陀螺仪跟随", v -> {
            if (!look.sensorAvailable()) {
                Toast.makeText(this, "这台设备没有可用的方向传感器，可以拖动画面环顾。", Toast.LENGTH_SHORT).show();
                return;
            }
            followHead = !followHead;
            applyMode(); saveVrSettings(); armControls();
        });
        for (Button b : new Button[]{headsetButton, headButton, button("退出 VR", "退出 VR", v -> {
            inVr = false;
            applyMode(); saveVrSettings(); showControls(true);
        })}) vrActions.addView(b, new LinearLayout.LayoutParams(0, dp(44), 1));
        footer.addView(vrActions);
        for (Button b : new Button[]{button("−15秒", "后退15秒", v -> jump(position - 15000)), play,
                button("+15秒", "快进15秒", v -> jump(position + 15000)), formats, fullscreen})
            actions.addView(b, new LinearLayout.LayoutParams(0, dp(48), 1));
        footer.addView(actions);
        root.addView(footer, new FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM));
        root.setOnApplyWindowInsetsListener((v, insets) -> {
            int left = insets.getSystemWindowInsetLeft(), right = insets.getSystemWindowInsetRight();
            header.setPadding(dp(12) + left, dp(4) + insets.getSystemWindowInsetTop(), dp(6) + right, dp(4));
            footer.setPadding(dp(8) + left, dp(2), dp(8) + right, dp(4) + insets.getSystemWindowInsetBottom());
            return insets;
        });
        setContentView(root);
        status("正在打开视频…", false);
    }

    private void togglePlayback() {
        if (wantsPlay && !ended) pause();
        else requestPlay();
    }

    // Gamepad button codes are separate from Android's Back and volume keys.
    // Dispatch before the focused view so immersive mode and the toolbar agree.
    @Override public boolean dispatchKeyEvent(KeyEvent event) {
        if (!active || !inVr || dialogOpen) return super.dispatchKeyEvent(event);
        boolean trigger = event.getAction() == KeyEvent.ACTION_DOWN && event.getRepeatCount() == 0;
        switch (event.getKeyCode()) {
            case KeyEvent.KEYCODE_BUTTON_A:
                if (trigger) togglePlayback();
                return true;
            case KeyEvent.KEYCODE_BUTTON_X:
                if (trigger && panorama()) look.recenter();
                return true;
            case KeyEvent.KEYCODE_BUTTON_Y:
                if (trigger) showControls(!controlsVisible);
                return true;
            case KeyEvent.KEYCODE_BUTTON_L1:
            case KeyEvent.KEYCODE_BUTTON_R1:
                if (trigger) jump(position + (event.getKeyCode() == KeyEvent.KEYCODE_BUTTON_L1 ? -15000 : 15000));
                return true;
            default:
                return super.dispatchKeyEvent(event);
        }
    }

    private String displayTitle() {
        String title = getIntent().getStringExtra("title");
        if (title != null) return title;
        return "file".equals(uri.getScheme()) ? new File(uri.getPath()).getName() : "本地视频";
    }
    private int dp(int v) { return Math.round(getResources().getDisplayMetrics().density * v); }
    private TextView label(int size) {
        TextView v = new TextView(this); v.setTextColor(Color.WHITE); v.setTextSize(size); return v;
    }
    private Button button(String title, String description, View.OnClickListener click) {
        Button b = new Button(this, null, android.R.attr.borderlessButtonStyle);
        b.setAllCaps(false); b.setSingleLine(true); b.setText(title); b.setTextSize(14); b.setTextColor(Color.WHITE);
        b.setPadding(dp(2),0,dp(2),0); b.setMinWidth(0); b.setMinimumWidth(0);
        b.setContentDescription(description); b.setOnClickListener(click); return b;
    }
    private boolean wide() { return userFullscreen || (inVr && vrFormat.headset); }
    private boolean panorama() { return inVr && vrFormat.projection != VrFormat.Projection.FLAT; }

    private void readVrSettings() {
        String key = "vr." + bookmarkKey + ".";
        VrFormat.Projection projection = getIntent().getBooleanExtra(EXTRA_START_IN_VR, false)
                ? VrFormat.initialProjection(displayTitle()) : VrFormat.Projection.EQUIRECT_180;
        VrFormat.Layout layout = VrFormat.Layout.SBS_FULL;
        try {
            projection = VrFormat.Projection.valueOf(bookmarks.getString(key + "projection", projection.name()));
            layout = VrFormat.Layout.valueOf(bookmarks.getString(key + "layout", layout.name()));
        } catch (IllegalArgumentException ignored) { /* Unknown saved choice from an earlier build. */ }
        vrFormat = new VrFormat(projection, layout, bookmarks.getBoolean(key + "headset", false));
        inVr = bookmarks.getBoolean(key + "active", false);
        followHead = bookmarks.getBoolean(key + "follow", false);
        fieldOfView = bookmarks.getFloat(key + "fov", 80);
    }

    private void saveVrSettings() {
        String key = "vr." + bookmarkKey + ".";
        bookmarks.edit().putString(key + "projection", vrFormat.projection.name())
                .putString(key + "layout", vrFormat.layout.name()).putBoolean(key + "headset", vrFormat.headset)
                .putBoolean(key + "active", inVr).putBoolean(key + "follow", followHead)
                .putFloat(key + "fov", fieldOfView).apply();
    }

    private void applyMode() {
        VrViewerSettings preferences = VrViewerSettings.read(this);
        movie.setVrRenderQuality(inVr, preferences.quality);
        movie.setFormat(inVr ? vrFormat : VrFormat.ORDINARY);
        look.configure(panorama(), inVr && vrFormat.headset, followHead, fieldOfView, preferences);
        int orientation = wide() ? ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE : ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED;
        if (getRequestedOrientation() != orientation) setRequestedOrientation(orientation);
        int flags = View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION;
        if (wide()) flags |= View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY | View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION;
        getWindow().getDecorView().setSystemUiVisibility(flags);
        fullscreen.setText(wide() ? "退出全屏" : "全屏");
        formats.setText(inVr ? "VR 设置" : "VR");
        formats.setContentDescription(inVr ? "VR 设置" : "进入 VR");
        vrActions.setVisibility(inVr ? View.VISIBLE : View.GONE);
        vrSummary.setVisibility(inVr ? View.VISIBLE : View.GONE);
        vrSummary.setText(VrOptionsDialog.projectionName(vrFormat.projection) + " · " +
                VrOptionsDialog.layoutName(vrFormat) + " · " + (vrFormat.headset ? "双眼" : "单屏"));
        recenter.setVisibility(panorama() ? View.VISIBLE : View.GONE);
        headButton.setVisibility(panorama() ? View.VISIBLE : View.GONE);
        headButton.setText(!look.sensorAvailable() ? "仅触摸" : (followHead ? "陀螺仪：开" : "陀螺仪：关"));
        headsetButton.setText(vrFormat.headset ? "切到单屏" : "双眼眼镜");
    }

    private void chooseFormat() {
        AlertDialog dialog = VrOptionsDialog.create(this, vrFormat, fieldOfView, (choice, fov) -> {
            vrFormat = choice;
            fieldOfView = fov;
            applyMode();
            saveVrSettings();
        }, () -> main.post(this::showDetails));
        showPlayerDialog(dialog);
    }

    private void showPlayerDialog(AlertDialog dialog) {
        main.removeCallbacks(hide);
        dialogOpen = true;
        dialog.setOnDismissListener(d -> { dialogOpen = false; armControls(); });
        dialog.show();
    }

    String playbackReport() {
        String phase = failed ? "失败" : ended ? "已结束" : stalledPicture ? "等待新画面"
                : !prepared ? "正在打开" : playing ? "播放中" : "已暂停";
        String mode = inVr ? VrOptionsDialog.projectionName(vrFormat.projection) + " · "
                + VrOptionsDialog.layoutName(vrFormat) + " · " + (vrFormat.headset ? "双眼" : "单屏") : "原始画面";
        int glLimit = movie.maxTextureSize();
        return "播放器  Media3 ExoPlayer · Android " + Build.VERSION.RELEASE + " · " + Build.MODEL
                + "\n" + (session == null ? lastTrackReport : session.diagnostics())
                + "\n解码偏好  " + (softwareDecoder ? "软件解码" : "自动选择")
                + "\n输出  " + mode + (glLimit > 0 ? " · GL 纹理上限 " + glLimit : "")
                + "\n显示尺寸  " + (width > 0 && height > 0 ? width + " × " + height : "尚无画面尺寸")
                + "\n播放状态  " + phase + " · " + time(ended ? duration : position) + " / " + time(duration)
                + "\n本次输入  " + inputNumber + " · GL 已提交新帧 " + Math.max(0, movie.presentedSamples() - framesAtOpen)
                + "\n输出事件  " + outputEvent;
    }

    private void showDetails() {
        if (!active || isFinishing()) return;
        AlertDialog dialog = new AlertDialog.Builder(this).setTitle("片源信息").setMessage(playbackReport())
                .setPositiveButton("关闭", null)
                .setNegativeButton("复制诊断", (d, w) -> {
                    ClipboardManager clipboard = getSystemService(ClipboardManager.class);
                    if (clipboard != null) clipboard.setPrimaryClip(ClipData.newPlainText("Nice 视频播放诊断", playbackReport()));
                })
                .setNeutralButton(softwareDecoder ? "恢复自动解码" : "尝试软件解码", (d, w) -> {
                    boolean resume = failed ? playBeforeFailure : wantsPlay;
                    softwareDecoder = !softwareDecoder;
                    frameWatch.newPlayback();
                    outputEvent = softwareDecoder ? "手动切换到软件解码" : "手动恢复自动解码";
                    retireSession(true);
                    failed = false;
                    ended = false;
                    wantsPlay = resume;
                    startIfReady();
                }).create();
        showPlayerDialog(dialog);
    }

    private void showControls(boolean visible) {
        controlsVisible = visible;
        header.setVisibility(visible ? View.VISIBLE : View.GONE); footer.setVisibility(visible ? View.VISIBLE : View.GONE);
        armControls();
    }
    private void armControls() {
        main.removeCallbacks(hide);
        if (active && controlsVisible && playing && !dragging && !dialogOpen && !failed && !stalledPicture) main.postDelayed(hide, 4500);
    }
    private void status(String message, boolean canRetry) {
        statusLabel.setText(message); statusLabel.setVisibility(message == null ? View.GONE : View.VISIBLE);
        retry.setVisibility(canRetry ? View.VISIBLE : View.GONE);
    }
    private void restart() {
        frameWatch.newPlayback();
        outputEvent = "手动重新打开";
        retireSession(true); failed = false; ended = false; wantsPlay = true; startIfReady();
    }
    private void startIfReady() {
        if (!active || releasingSession || session != null || failed || isFinishing() || isDestroyed()) return;
        if (needFreshOutput) {
            needFreshOutput = false;
            boolean replace = surface == null || surface == replaceAfterRelease;
            replaceAfterRelease = null;
            if (replace) {
                surface = null;
                movie.requestFreshDecoderSurface();
                return;
            }
        }
        if (surface == null || !surface.isValid()) return;
        if (wantsPlay && !acquireFocus()) wantsPlay = false;
        prepared = false; playing = false; firstFrame = false;
        width = 0; height = 0; movie.setVideoSize(0, 0);
        framesAtOpen = movie.presentedSamples(); inputNumber++;
        lastTrackReport = "视频轨道  等待识别";
        resetPictureWatch();
        status("正在打开视频…", false);
        movie.expectNewDecoderFrame();
        session = new MovieSession(this); session.open(this, uri, surface, position, wantsPlay, softwareDecoder);
        refresh();
    }
    @Override public void onSurfaceReady(Surface newSurface) {
        if (!active) return;
        if (session != null && surface != newSurface) retireSession();
        surface = newSurface; firstFrame = false; startIfReady();
    }
    @Override public void onRenderError(String detail) { onError("无法初始化视频画面。\n" + detail); }
    @Override public void onFirstFrameDrawn() {
        if (session == null) return;
        firstFrame = true;
        if (!failed) status(null, false);
    }
    @Override public void onPrepared(long length, String mime) {
        duration = length; prepared = true; bar.setEnabled(duration > 0);
        total.setText(time(duration));
        if (firstFrame || !wantsPlay) status(null, false);
        refresh();
    }
    @Override public void onVideoSize(int w, int h) { width = w; height = h; movie.setVideoSize(w,h); }
    @Override public void onBuffering(boolean buffering) {
        if (buffering) resetPictureWatch();
        if (!failed) status(buffering ? "正在缓冲…" : null, false);
    }

    private void resetPictureWatch() {
        frameWatch.interrupt();
        if (stalledPicture) {
            stalledPicture = false;
            if (!failed) status(null, false);
            armControls();
        }
    }

    private boolean checkPictureMotion(long current, boolean moving) {
        if (!moving || !prepared || failed || dragging || session == null || !active
                || (duration > 0 && duration - current < 900)) {
            resetPictureWatch();
            return false;
        }
        VideoFrameWatch.Action action = frameWatch.sample(current, SystemClock.elapsedRealtime(),
                movie.presentedSamples(), firstFrame, session.frameRate());
        if (action == VideoFrameWatch.Action.RECONNECT) {
            outputEvent = "播放时钟前进但没有新画面，在 " + time(current) + " 自动重连一次";
            retireSession(true);
            status("正在从 " + time(current) + " 重连视频输出…", false);
            startIfReady();
            return true;
        }
        if (action == VideoFrameWatch.Action.REPORT) {
            stalledPicture = true;
            status("已重连一次，播放时钟仍前进但画面没有更新。请在「片源信息」查看解码能力或切换解码方式。", false);
            showControls(true);
        } else if (stalledPicture && !frameWatch.reported()) {
            stalledPicture = false;
            status(null, false);
            armControls();
        }
        return false;
    }

    @Override public void onProgress(long current, boolean motion) {
        boolean changed = playing != motion; playing = motion; position = current;
        if (checkPictureMotion(current, motion)) return;
        if (!dragging && discreteTarget < 0) showTimeline(current);
        if (playing && SystemClock.elapsedRealtime() - lastSave >= 5000) saveBookmark();
        if (changed) refresh();
    }
    @Override public void onEnded() {
        ended = true; playing = false; wantsPlay = false; position = 0;
        resetPictureWatch();
        bookmarks.edit().remove(bookmarkKey).apply();
        if (!dragging && discreteTarget < 0) showTimeline(duration);
        abandonFocus(); showControls(true); refresh();
    }
    @Override public void onError(String message) {
        if (!failed) playBeforeFailure = wantsPlay;
        failed = true; wantsPlay = false; playing = false; retireSession(); abandonFocus();
        status(message, true); showControls(true); refresh();
    }
    private void showElapsed(long target) {
        long second = target / 1000;
        if (second != displayedSecond) {
            elapsed.setText(time(target));
            displayedSecond = second;
        }
    }

    private void showTimeline(long target) {
        showElapsed(target);
        if (duration > 0) bar.setProgress((int) Math.round(
                STEPS * Math.min(1.0, Math.max(0.0, (double) target / duration))));
    }

    private boolean beginScrub() {
        if (!prepared || session == null || duration <= 0) return false;
        cancelDiscreteSeek();
        dragging = true;
        scrubTarget = -1;
        main.removeCallbacks(hide);
        return true;
    }

    private void previewScrub(long target) {
        if (!dragging) return;
        scrubTarget = Math.min(duration, Math.max(0, target));
        showTimeline(scrubTarget);
    }

    private void endScrub(boolean commit) {
        if (!dragging) return;
        dragging = false;
        if (commit && scrubTarget >= 0) jump(scrubTarget);
        else showTimeline(ended ? duration : position);
        scrubTarget = -1;
        armControls();
    }

    private void cancelDiscreteSeek() {
        main.removeCallbacks(commitDiscreteSeek);
        discreteTarget = -1;
    }

    private void jump(long target) {
        cancelDiscreteSeek();
        if (!prepared || session == null || duration <= 0) return;
        resetPictureWatch();
        position = Math.min(duration, Math.max(0, target));
        showTimeline(position);
        if (ended) {
            ended = false;
            frameWatch.newPlayback();
            outputEvent = "片尾定位后重建视频输出";
            retireSession(true);
            startIfReady();
        } else session.seek(position);
        armControls();
    }
    private void requestPlay() {
        if (failed) { restart(); return; }
        if (!acquireFocus()) { status("其他应用正在使用音频，请稍后再点播放。", false); return; }
        if (ended) {
            position = 0;
            frameWatch.newPlayback();
            outputEvent = "重播时重建视频输出";
            retireSession(true);
            showTimeline(0);
        }
        ended = false; wantsPlay = true; resumeOnGain = false;
        if (firstFrame) status(null, false);
        if (session != null) session.setPlaying(true);
        else startIfReady();
        refresh();
    }
    private void pause() {
        wantsPlay = false; resumeOnGain = false;
        if (session != null) session.setPlaying(false);
        abandonFocus(); showControls(true); refresh();
    }
    private void refresh() {
        play.setText(ended ? "重播" : wantsPlay ? "暂停" : "播放");
        if (active && wantsPlay && !failed) getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        else getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        armControls();
    }
    private boolean acquireFocus() {
        if (!hasFocus) hasFocus = audio.requestAudioFocus(focus) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED;
        return hasFocus;
    }
    private void abandonFocus() { if (hasFocus) audio.abandonAudioFocusRequest(focus); hasFocus = false; resumeOnGain = false; }
    private void focusChanged(int event) {
        if (!active || !hasFocus) return;
        if (event == AudioManager.AUDIOFOCUS_GAIN) { if (resumeOnGain) requestPlay(); }
        else if (event == AudioManager.AUDIOFOCUS_LOSS) pause();
        else {
            resumeOnGain = resumeOnGain || wantsPlay; wantsPlay = false;
            if (session != null) session.setPlaying(false); showControls(true); refresh();
        }
    }
    private void retireSession() { retireSession(false); }

    private void retireSession(boolean freshOutput) {
        if (freshOutput) { needFreshOutput = true; replaceAfterRelease = surface; }
        cancelDiscreteSeek();
        endScrub(false);
        if (session != null) {
            MovieSession old = session;
            lastTrackReport = old.diagnostics();
            session = null;
            releasingSession = true;
            old.close(() -> {
                releasingSession = false;
                startIfReady();
            });
        }
        prepared = false; playing = false;
        resetPictureWatch();
        bar.setEnabled(false); main.removeCallbacks(hide);
    }
    private void saveBookmark() {
        lastSave = SystemClock.elapsedRealtime();
        if (ended || (duration > 0 && duration - position < 1500)) bookmarks.edit().remove(bookmarkKey).apply();
        else bookmarks.edit().putLong(bookmarkKey, Math.max(0, position)).apply();
    }
    @Override protected void onResume() {
        super.onResume();
        if (movie == null) return;
        active = true;
        IntentFilter filter = new IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY);
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(noisy, filter, Context.RECEIVER_NOT_EXPORTED);
        else registerReceiver(noisy, filter);
        movie.onResume(); look.setResumed(true); startIfReady();
    }
    @Override protected void onPause() {
        if (movie != null) {
            active = false; look.setResumed(false); saveBookmark(); wantsPlay = false; playBeforeFailure = false; abandonFocus(); retireSession(); surface = null;
            movie.onPause(); unregisterReceiver(noisy); refresh();
        }
        super.onPause();
    }
    @Override protected void onSaveInstanceState(Bundle out) {
        super.onSaveInstanceState(out); out.putLong("position", position); out.putBoolean("wantsPlay", wantsPlay);
        out.putBoolean("inVr", inVr); out.putBoolean("softwareDecoder", softwareDecoder); out.putBoolean("fullscreen", userFullscreen);
    }
    static String time(long ms) {
        long s = Math.max(0, ms) / 1000;
        return s >= 3600 ? String.format(Locale.ROOT, "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                : String.format(Locale.ROOT, "%02d:%02d", s / 60, s % 60);
    }
}
