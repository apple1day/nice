package com.anxiong.nicevideos;

import static org.junit.Assert.*;
import org.junit.Test;

public final class VideoFrameWatchTest {
    @Test public void missingFirstFrameRecoversBeforeAnEightSecondMovieEndsAndRetriesOnlyOnce() {
        VideoFrameWatch watch = new VideoFrameWatch();
        for (int ms = 0; ms < 3000; ms += 250)
            assertEquals(VideoFrameWatch.Action.NONE, watch.sample(ms, ms, 0, false, 24));
        assertEquals(VideoFrameWatch.Action.RECONNECT, watch.sample(3000, 3000, 0, false, 24));
        for (int ms = 3200; ms < 6200; ms += 250)
            assertEquals(VideoFrameWatch.Action.NONE, watch.sample(ms, ms, 0, false, 24));
        assertEquals(VideoFrameWatch.Action.REPORT, watch.sample(6200, 6200, 0, false, 24));
        assertEquals(VideoFrameWatch.Action.NONE, watch.sample(6450, 6450, 0, false, 24));
        watch.newPlayback();
        for (int ms = 0; ms < 3000; ms += 250) watch.sample(ms, ms, 0, false, 24);
        assertEquals(VideoFrameWatch.Action.RECONNECT, watch.sample(3000, 3000, 0, false, 24));
    }

    @Test public void pauseSeekAndSlowOrChangingPicturesDoNotTriggerRecovery() {
        VideoFrameWatch watch = new VideoFrameWatch();
        for (int ms = 0; ms < 18000; ms += 250)
            assertEquals(VideoFrameWatch.Action.NONE, watch.sample(ms, ms, ms / 5000, true, .2f));
        watch.interrupt();
        assertEquals(VideoFrameWatch.Action.NONE, watch.sample(90000, 40000, 9, true, 24));
        assertEquals(VideoFrameWatch.Action.NONE, watch.sample(125000, 75000, 9, true, 24));
        for (int ms = 0; ms < 4000; ms += 250)
            assertEquals(VideoFrameWatch.Action.NONE, watch.sample(ms, 80000 + ms, 9, true, 24));
        assertEquals(VideoFrameWatch.Action.RECONNECT, watch.sample(4000, 84000, 9, true, 24));
    }

    @Test public void twoSlowWindowsReconnectOnceAndExposeMeasuredRateOnRepeatedStarvation() {
        VideoFrameWatch watch = new VideoFrameWatch();
        for (int ms = 0; ms < 10000; ms += 250)
            assertEquals(VideoFrameWatch.Action.NONE, watch.sample(ms, ms, ms / 250, true, 60));
        assertEquals(VideoFrameWatch.Action.RECONNECT, watch.sample(10000, 10000, 40, true, 60));
        assertTrue(watch.finding().contains("4.0 帧/秒"));
        assertTrue(watch.finding().contains("60.0 帧/秒"));
        for (int ms = 10250; ms < 20250; ms += 250)
            assertEquals(VideoFrameWatch.Action.NONE, watch.sample(ms, ms, ms / 250, true, 60));
        assertEquals(VideoFrameWatch.Action.REPORT, watch.sample(20250, 20250, 81, true, 60));
        assertTrue(watch.reported());
        for (int step = 1; step <= 20; step++) {
            long ms = 20250 + step * 250;
            assertEquals(VideoFrameWatch.Action.NONE, watch.sample(ms, ms, 81 + step * 15, true, 60));
        }
        assertFalse(watch.reported());
    }

    @Test public void naturalLowFpsHealthyWindowsAndInterruptedClocksDoNotAccumulateStarvation() {
        VideoFrameWatch watch = new VideoFrameWatch();
        long frames = 0;
        for (int ms = 0; ms <= 15000; ms += 250)
            assertEquals(VideoFrameWatch.Action.NONE, watch.sample(ms, ms, ++frames, true, 4));
        // Two non-consecutive slow windows with a normal five-second interval between them.
        watch.interrupt();
        for (int ms = 0; ms <= 15000; ms += 250) {
            frames += ms > 5000 && ms <= 10000 ? 15 : 1;
            assertEquals(VideoFrameWatch.Action.NONE, watch.sample(ms, ms, frames, true, 60));
        }
        // A forward seek, a background delay and a buffering pause each interrupt the interval.
        for (int ms = 15250; ms <= 20250; ms += 250)
            assertEquals(VideoFrameWatch.Action.NONE, watch.sample(ms + 90000, ms, ++frames, true, 60));
        for (int ms = 20500; ms <= 25500; ms += 250)
            assertEquals(VideoFrameWatch.Action.NONE, watch.sample(ms + 90000, ms + 8000, ++frames, true, 60));
        watch.interrupt();
        for (int ms = 25750; ms <= 34750; ms += 250)
            assertEquals(VideoFrameWatch.Action.NONE, watch.sample(ms + 90000, ms + 8000, ++frames, true, 60));
    }
}
