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
}
