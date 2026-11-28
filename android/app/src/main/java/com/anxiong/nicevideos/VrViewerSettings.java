package com.anxiong.nicevideos;

import android.content.Context;
import android.content.SharedPreferences;

/** Gesture and display preferences apply across movies. */
final class VrViewerSettings {
    enum DoubleTap {
        RECENTER("视角回正"), PLAY_PAUSE("播放／暂停"), CONTROLS("显示／隐藏控件");
        final String label;
        DoubleTap(String label) { this.label = label; }
        @Override public String toString() { return label; }
    }

    enum Pinch {
        FINE("精细", 0.55), NORMAL("标准", 1), FAST("快速", 1.7);
        final String label;
        final double strength;
        Pinch(String label, double strength) { this.label = label; this.strength = strength; }
        @Override public String toString() { return label; }
    }

    enum Quality {
        BALANCED("流畅（最长边 1920）"), NATIVE("屏幕原生");
        final String label;
        Quality(String label) { this.label = label; }
        @Override public String toString() { return label; }
    }

    final DoubleTap doubleTap;
    final Pinch pinch;
    final Quality quality;

    VrViewerSettings(DoubleTap doubleTap, Pinch pinch, Quality quality) {
        this.doubleTap = doubleTap;
        this.pinch = pinch;
        this.quality = quality;
    }

    static VrViewerSettings read(Context context) {
        SharedPreferences prefs = context.getSharedPreferences("vr_gestures", Context.MODE_PRIVATE);
        return new VrViewerSettings(saved(prefs, "doubleTap", DoubleTap.RECENTER),
                saved(prefs, "pinch", Pinch.NORMAL), saved(prefs, "quality", Quality.BALANCED));
    }

    void save(Context context) {
        context.getSharedPreferences("vr_gestures", Context.MODE_PRIVATE).edit()
                .putString("doubleTap", doubleTap.name()).putString("pinch", pinch.name())
                .putString("quality", quality.name()).apply();
    }

    private static <E extends Enum<E>> E saved(SharedPreferences prefs, String key, E fallback) {
        try { return Enum.valueOf(fallback.getDeclaringClass(), prefs.getString(key, fallback.name())); }
        catch (IllegalArgumentException ignored) { return fallback; }
    }
}
