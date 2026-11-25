package com.anxiong.nicevideos;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.BroadcastReceiver;
import android.content.Context;
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
import android.view.Surface;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.SeekBar;
import android.widget.TextView;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.UUID;

public final class PlayerActivity extends Activity implements MovieSurface.Listener, MovieSession.Listener {
    private static final int STEPS = 10000;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Runnable hide = () -> showControls(false);
    private final Runnable firstFrameCheck = this::checkFirstFrame;
    private final BroadcastReceiver noisy = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) {
            if (AudioManager.ACTION_AUDIO_BECOMING_NOISY.equals(i.getAction())) pause();
        }
    };
    private MovieSurface movie;
    private Surface surface;
    private MovieSession session;
    private MovieSurface.Mode mode = MovieSurface.Mode.STANDARD;
    private LinearLayout header, footer;
    private TextView statusLabel, elapsed, total;
    private Button play, formats, fullscreen, retry;
    private SeekBar bar;
    private Uri uri;
    private SharedPreferences bookmarks;
    private String bookmarkKey, videoMime;
    private int width, height;
    private long duration, position, lastSave;
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
        if (state != null) {
            position = state.getLong("position", position);
            wantsPlay = state.getBoolean("wantsPlay", false);
            mode = MovieSurface.Mode.valueOf(state.getString("mode", MovieSurface.Mode.STANDARD.name()));
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
        movie.setMode(mode);
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
        String name = getIntent().getStringExtra("title");
        if (name == null) name = "file".equals(uri.getScheme()) ? new File(uri.getPath()).getName() : "本地视频";
        title.setText(name);
        header.addView(title, new LinearLayout.LayoutParams(0, -2, 1));
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
        bar.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onStartTrackingTouch(SeekBar b) { dragging = true; main.removeCallbacks(hide); }
            @Override public void onProgressChanged(SeekBar b, int value, boolean user) {
                if (!user) return;
                long target = duration * value / STEPS;
                elapsed.setText(time(target));
                if (!dragging) jump(target);
            }
            @Override public void onStopTrackingTouch(SeekBar b) {
                dragging = false;
                jump(duration * b.getProgress() / STEPS);
            }
        });
        LinearLayout actions = new LinearLayout(this);
        play = button("暂停", "播放或暂停", v -> { if (wantsPlay && !ended) pause(); else requestPlay(); });
        formats = button("格式", "视频格式", v -> chooseFormat());
        fullscreen = button("全屏", "全屏", v -> {
            userFullscreen = !wide();
            if (!userFullscreen) mode = MovieSurface.Mode.STANDARD;
            movie.setMode(mode);
            applyMode();
            showControls(true);
        });
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

    private void checkFirstFrame() {
        if (active && prepared && playing && !firstFrame && !ended && !failed) {
            status("尚未显示视频画面。可在「格式 → 片源信息」查看分辨率和视频轨道。", false);
        }
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
    private boolean wide() { return userFullscreen || mode != MovieSurface.Mode.STANDARD; }

    private void applyMode() {
        int orientation = wide() ? ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE : ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED;
        if (getRequestedOrientation() != orientation) setRequestedOrientation(orientation);
        int flags = View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION;
        if (wide()) flags |= View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY | View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION;
        getWindow().getDecorView().setSystemUiVisibility(flags);
        fullscreen.setText(wide() ? "退出" : "全屏");
        formats.setText(mode == MovieSurface.Mode.STANDARD ? "格式" : "VR");
    }

    private void chooseFormat() {
        main.removeCallbacks(hide);
        dialogOpen = true;
        AlertDialog dialog = new AlertDialog.Builder(this).setTitle("视频格式")
                .setSingleChoiceItems(new String[]{"普通播放", "半宽 SBS", "全宽 SBS"}, mode.ordinal(), (d, which) -> {
                    mode = MovieSurface.Mode.values()[which]; movie.setMode(mode); applyMode(); d.dismiss();
                }).setNegativeButton("关闭", null)
                .setNeutralButton("片源信息", (d, which) -> main.post(this::showDetails)).create();
        dialog.setOnDismissListener(d -> { dialogOpen = false; armControls(); }); dialog.show();
    }

    private void showDetails() {
        if (!active || isFinishing()) return;
        dialogOpen = true; main.removeCallbacks(hide);
        String dims = width > 0 && height > 0 ? width + " × " + height : "暂未识别";
        String info = "分辨率  " + dims + "\n视频轨道  " + (videoMime == null ? "暂未识别" : videoMime)
                + "\n播放器  Android 系统 MediaPlayer\n\n每只眼的画面被横向压缩时选半宽，保持原比例时选全宽。";
        AlertDialog dialog = new AlertDialog.Builder(this).setTitle("片源信息").setMessage(info).setPositiveButton("关闭", null).create();
        dialog.setOnDismissListener(d -> { dialogOpen = false; armControls(); }); dialog.show();
    }

    private void showControls(boolean visible) {
        controlsVisible = visible;
        header.setVisibility(visible ? View.VISIBLE : View.GONE); footer.setVisibility(visible ? View.VISIBLE : View.GONE);
        armControls();
    }
    private void armControls() {
        main.removeCallbacks(hide);
        if (active && controlsVisible && playing && !dragging && !dialogOpen && !failed) main.postDelayed(hide, 4500);
    }
    private void status(String message, boolean canRetry) {
        statusLabel.setText(message); statusLabel.setVisibility(message == null ? View.GONE : View.VISIBLE);
        retry.setVisibility(canRetry ? View.VISIBLE : View.GONE);
    }
    private void restart() {
        retireSession(); failed = false; ended = false; wantsPlay = true; startIfReady();
    }
    private void startIfReady() {
        if (!active || session != null || surface == null || !surface.isValid() || failed) return;
        if (wantsPlay && !acquireFocus()) wantsPlay = false;
        prepared = false; playing = false; status("正在打开视频…", false);
        session = new MovieSession(this); session.open(this, uri, surface, position, wantsPlay);
        refresh();
    }
    @Override public void onSurfaceReady(Surface newSurface) {
        if (!active) return;
        if (session != null && surface != newSurface) retireSession();
        surface = newSurface; firstFrame = false; startIfReady();
    }
    @Override public void onRenderError(String detail) { onError("无法初始化视频画面。\n" + detail); }
    @Override public void onFirstFrameDrawn() {
        firstFrame = true; main.removeCallbacks(firstFrameCheck);
        if (!failed) status(null, false);
    }
    @Override public void onPrepared(long length, String mime) {
        duration = length; videoMime = mime; prepared = true; bar.setEnabled(duration > 0);
        total.setText(time(duration));
        if (firstFrame || !wantsPlay) status(null, false);
        refresh();
    }
    @Override public void onVideoSize(int w, int h) { width = w; height = h; movie.setVideoSize(w,h); }
    @Override public void onBuffering(boolean buffering) { if (!failed) status(buffering ? "正在缓冲…" : null, false); }
    @Override public void onProgress(long current, boolean motion) {
        boolean changed = playing != motion; playing = motion; position = current;
        if (!dragging) {
            elapsed.setText(time(position));
            if (duration > 0) bar.setProgress((int) Math.min(STEPS, position * STEPS / duration));
        }
        if (playing && SystemClock.elapsedRealtime() - lastSave >= 5000) saveBookmark();
        if (changed) {
            refresh(); main.removeCallbacks(firstFrameCheck);
            if (playing && !firstFrame) main.postDelayed(firstFrameCheck, 8000);
        }
    }
    @Override public void onEnded() {
        ended = true; playing = false; wantsPlay = false; position = 0;
        bookmarks.edit().remove(bookmarkKey).apply(); elapsed.setText(time(duration)); bar.setProgress(STEPS);
        abandonFocus(); showControls(true); refresh();
    }
    @Override public void onError(String message) {
        failed = true; wantsPlay = false; playing = false; retireSession(); abandonFocus();
        status(message, true); showControls(true); refresh();
    }
    private void jump(long target) {
        if (!prepared || session == null || duration <= 0) return;
        ended = false; position = Math.min(duration, Math.max(0, target)); session.seek(position); armControls();
    }
    private void requestPlay() {
        if (failed) { restart(); return; }
        if (!acquireFocus()) { status("其他应用正在使用音频，请稍后再点播放。", false); return; }
        if (ended) position = 0;
        ended = false; wantsPlay = true; resumeOnGain = false;
        if (firstFrame) status(null, false);
        if (session != null) session.setPlaying(true);
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
    private void retireSession() {
        if (session != null) session.close(); session = null; prepared = false; playing = false;
        bar.setEnabled(false); main.removeCallbacks(firstFrameCheck); main.removeCallbacks(hide);
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
        movie.onResume(); startIfReady();
    }
    @Override protected void onPause() {
        if (movie != null) {
            active = false; saveBookmark(); wantsPlay = false; abandonFocus(); retireSession(); surface = null;
            movie.onPause(); unregisterReceiver(noisy); refresh();
        }
        super.onPause();
    }
    @Override protected void onSaveInstanceState(Bundle out) {
        super.onSaveInstanceState(out); out.putLong("position", position); out.putBoolean("wantsPlay", wantsPlay);
        out.putString("mode", mode.name()); out.putBoolean("fullscreen", userFullscreen);
    }
    static String time(long ms) {
        long s = Math.max(0, ms) / 1000;
        return s >= 3600 ? String.format(Locale.ROOT, "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                : String.format(Locale.ROOT, "%02d:%02d", s / 60, s % 60);
    }
}
