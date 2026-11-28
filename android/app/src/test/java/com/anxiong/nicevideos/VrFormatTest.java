package com.anxiong.nicevideos;

import org.junit.Test;
import static org.junit.Assert.assertEquals;

public final class VrFormatTest {
    @Test public void fullSphereRequiresAnExplicitTag() {
        for (String title : new String[]{"vr360-8k-sbs-8s-hevc.mp4", "Tour_360_SBS.mp4", "旅行360度.mp4", "VR-360°.mkv"})
            assertEquals(title, VrFormat.Projection.EQUIRECT_360, VrFormat.initialProjection(title));
        for (String title : new String[]{"movie.360p.mp4", "ticket1360.mp4", "movie3600.mp4", "8K_SBS.mp4", null})
            assertEquals(title, VrFormat.Projection.EQUIRECT_180, VrFormat.initialProjection(title));
    }
}
