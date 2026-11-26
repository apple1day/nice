package com.anxiong.nicevideos;

/** Monitors new decoder samples presented by GL while both media time and real time advance. */
final class VideoFrameWatch {
    enum Action { NONE, RECONNECT, REPORT }

    private long previousFrames = -1, previousPosition, previousTime, quietMs;
    private boolean reconnected, reported;

    void newPlayback() {
        reconnected = false;
        interrupt();
    }

    void interrupt() {
        previousFrames = -1;
        quietMs = 0;
        reported = false;
    }

    boolean reported() { return reported; }

    Action sample(long position, long now, long frames, boolean hasPicture, float fps) {
        if (previousFrames != frames || position < previousPosition || now < previousTime) {
            quietMs = 0;
            reported = false;
        } else {
            // Do not count a delayed UI message, resume or timeline jump as sustained playback.
            quietMs += Math.min(1000, Math.min(position - previousPosition, now - previousTime));
        }
        previousFrames = frames;
        previousPosition = position;
        previousTime = now;
        long grace = hasPicture ? 4000 : 3000;
        if (Float.isFinite(fps) && fps > 0) grace = Math.max(grace, (long) Math.ceil(3000.0 / fps));
        else grace = hasPicture ? 10000 : 6000;
        if (quietMs < grace || reported) return Action.NONE;
        if (!reconnected) {
            reconnected = true;
            interrupt();
            return Action.RECONNECT;
        }
        reported = true;
        return Action.REPORT;
    }
}
