package com.anxiong.nicevideos;

import android.content.Context;
import android.content.SharedPreferences;

/** Gesture preferences follow the viewer across movies. */
final class VrGestureSettings {
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

    final DoubleTap doubleTap;
    final Pinch pinch;

    VrGestureSettings(DoubleTap doubleTap, Pinch pinch) {
        this.doubleTap = doubleTap;
        this.pinch = pinch;
    }

    static VrGestureSettings read(Context context) {
        SharedPreferences prefs = context.getSharedPreferences("vr_gestures", Context.MODE_PRIVATE);
        return new VrGestureSettings(saved(prefs, "doubleTap", DoubleTap.RECENTER),
                saved(prefs, "pinch", Pinch.NORMAL));
    }

    void save(Context context) {
        context.getSharedPreferences("vr_gestures", Context.MODE_PRIVATE).edit()
                .putString("doubleTap", doubleTap.name()).putString("pinch", pinch.name()).apply();
    }

    private static <E extends Enum<E>> E saved(SharedPreferences prefs, String key, E fallback) {
        try { return Enum.valueOf(fallback.getDeclaringClass(), prefs.getString(key, fallback.name())); }
        catch (IllegalArgumentException ignored) { return fallback; }
    }
}
