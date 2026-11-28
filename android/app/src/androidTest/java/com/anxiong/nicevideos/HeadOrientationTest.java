package com.anxiong.nicevideos;

import android.hardware.SensorManager;
import android.opengl.Matrix;
import android.view.Surface;
import org.junit.Test;
import static org.junit.Assert.*;

public class HeadOrientationTest {
    @Test public void cameraIsRelativeToTheCenteredDeviceInEveryDisplayRotation() {
        // A right-handed quarter turn about the device's Y axis.
        float[] baseline = new float[16], rotated = new float[16];
        SensorManager.getRotationMatrixFromVector(baseline, new float[]{0, 0, 0, 1});
        float s = (float)Math.sqrt(0.5);
        SensorManager.getRotationMatrixFromVector(rotated, new float[]{0, s, 0, s});
        float[][] expected = {{-1,0}, {0,-1}, {1,0}, {0,1}};
        for (int r = Surface.ROTATION_0; r <= Surface.ROTATION_270; r++) {
            float[] tmp = new float[16], center = new float[16], current = new float[16];
            VrHeadTracker.toScreenMatrix(baseline, r, tmp, center);
            VrHeadTracker.toScreenMatrix(rotated, r, tmp, current);
            float[] inv = new float[16], relative = new float[16], ray = new float[4];
            Matrix.transposeM(inv, 0, center, 0);
            Matrix.multiplyMM(relative, 0, inv, 0, current, 0);
            Matrix.multiplyMV(ray, 0, relative, 0, new float[]{0, 0, -1, 0}, 0);
            assertEquals(expected[r][0], ray[0], 0.001f);
            assertEquals(expected[r][1], ray[1], 0.001f);
            assertEquals(0, ray[2], 0.001f);
        }
    }
}
