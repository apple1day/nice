package com.anxiong.nicevideos;

import java.util.Objects;

/** Source projection and packing are independent of how many viewports are displayed. */
public final class VrFormat {
    public enum Projection {
        FLAT(0), EQUIRECT_180(1), EQUIRECT_360(2), FISHEYE_180(3);
        final int shaderId;
        Projection(int shaderId) { this.shaderId = shaderId; }
    }

    public enum Layout { MONO, SBS_HALF, SBS_FULL, TOP_BOTTOM }

    public static final VrFormat ORDINARY = new VrFormat(Projection.FLAT, Layout.MONO, false);
    public final Projection projection;
    public final Layout layout;
    public final boolean headset;

    public VrFormat(Projection projection, Layout layout, boolean headset) {
        this.projection = Objects.requireNonNull(projection);
        this.layout = Objects.requireNonNull(layout);
        this.headset = headset;
    }
}
