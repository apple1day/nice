package com.anxiong.nicevideos;

import java.util.Locale;

/** Monitors distinct decoder timestamps submitted by GL while media and real time advance. */
final class VideoFrameWatch {
    enum Action { NONE, RECONNECT, REPORT }
    private enum Problem { NO_FRAMES, LOW_RATE }

    private long previousFrames = -1, previousPosition, previousTime, quietMs;
    private long windowStart = -1, windowPosition, windowFrames;
    private float windowNominal;
    private double previousSlowRate = -1;
    private boolean reconnected;
    private Problem reported;
    private String finding = "";

    void newPlayback() {
        reconnected = false;
        finding = "";
        interrupt();
    }

    void interrupt() {
        previousFrames = -1;
        quietMs = 0;
        windowStart = -1;
        previousSlowRate = -1;
        reported = null;
    }

    boolean reported() { return reported != null; }
    String finding() { return finding; }

    Action sample(long position, long now, long frames, boolean hasPicture, float fps) {
        long wallDelta = now - previousTime;
        long mediaDelta = position - previousPosition;
        if (frames < previousFrames || wallDelta < 0 || wallDelta > 3500
                || mediaDelta < 0 || mediaDelta > wallDelta + 1250) interrupt();
        if (previousFrames >= 0 && previousFrames == frames) {
            quietMs += Math.min(1000, Math.min(mediaDelta, wallDelta));
        } else {
            quietMs = 0;
            if (reported == Problem.NO_FRAMES) reported = null;
        }
        previousFrames = frames;
        previousPosition = position;
        previousTime = now;

        long grace = hasPicture ? 4000 : 3000;
        if (Float.isFinite(fps) && fps > 0) grace = Math.max(grace, (long) Math.ceil(3000.0 / fps));
        else grace = hasPicture ? 10000 : 6000;
        double slowRate = sustainedSlowRate(position, now, frames, hasPicture, fps);
        Problem problem = quietMs >= grace ? Problem.NO_FRAMES : slowRate >= 0 ? Problem.LOW_RATE : null;
        if (problem == null || reported == problem) return Action.NONE;
        finding = problem == Problem.NO_FRAMES ? "播放时钟前进但没有新画面"
                : String.format(Locale.ROOT, "画面持续低帧：GL 约 %.1f 帧/秒，片源 %.1f 帧/秒", slowRate, fps);
        if (!reconnected) {
            reconnected = true;
            interrupt();
            return Action.RECONNECT;
        }
        reported = problem;
        return Action.REPORT;
    }

    // Compare two independent five-second windows. A short burst after a seek, a slow
    // source, or a clock held by buffering must not trigger a decoder restart.
    private double sustainedSlowRate(long position, long now, long frames, boolean hasPicture, float fps) {
        if (!hasPicture || !Float.isFinite(fps) || fps < 23) {
            windowStart = -1;
            previousSlowRate = -1;
            if (reported == Problem.LOW_RATE) reported = null;
            return -1;
        }
        double average = -1;
        if (windowStart >= 0 && windowNominal == fps) {
            long elapsed = now - windowStart;
            if (elapsed < 5000) return -1;
            long played = position - windowPosition;
            double rate = 1000.0 * (frames - windowFrames) / elapsed;
            if (played >= elapsed * .8 && played <= elapsed + 1250 && rate > 0 && rate < Math.min(8, fps / 6.0)) {
                if (previousSlowRate >= 0) average = (previousSlowRate + rate) / 2;
                previousSlowRate = rate;
            } else {
                previousSlowRate = -1;
                if (reported == Problem.LOW_RATE) reported = null;
            }
        } else {
            previousSlowRate = -1;
            if (reported == Problem.LOW_RATE) reported = null;
        }
        windowStart = now;
        windowPosition = position;
        windowFrames = frames;
        windowNominal = fps;
        return average;
    }
}
