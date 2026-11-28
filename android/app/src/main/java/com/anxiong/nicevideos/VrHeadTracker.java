package com.anxiong.nicevideos;

import android.content.Context;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.opengl.Matrix;
import android.view.Display;
import android.view.Surface;
import android.view.WindowManager;

/** Relative 3DoF camera orientation in the current screen axes. Used only during VR. */
final class VrHeadTracker implements SensorEventListener {
    interface Listener { void onOrientation(float[] cameraToWorld); }

    private final SensorManager sensors;
    private final Sensor sensor;
    private final Display display;
    private final Listener listener;
    private final float[] device = new float[16];
    private final float[] screen = new float[16];
    private final float[] current = new float[16];
    private final float[] inverseCenter = new float[16];
    private final float[] relative = new float[16];
    private boolean registered;
    private boolean centered;
    private int rotation = -1;

    VrHeadTracker(Context context, Listener listener) {
        this.listener = listener;
        sensors = (SensorManager) context.getSystemService(Context.SENSOR_SERVICE);
        Sensor candidate = sensors.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR);
        sensor = candidate != null ? candidate : sensors.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR);
        display = ((WindowManager) context.getSystemService(Context.WINDOW_SERVICE)).getDefaultDisplay();
    }

    boolean isAvailable() { return sensor != null; }

    void setEnabled(boolean enabled) {
        if (registered == enabled) return;
        if (enabled && sensor != null) {
            registered = sensors.registerListener(this, sensor, SensorManager.SENSOR_DELAY_GAME);
        } else {
            sensors.unregisterListener(this);
            registered = false;
        }
        recenter();
    }

    void recenter() {
        centered = false;
        Matrix.setIdentityM(relative, 0);
        listener.onOrientation(relative);
    }

    @Override public void onSensorChanged(SensorEvent event) {
        if (!registered || event.sensor != sensor) return;
        SensorManager.getRotationMatrixFromVector(device, event.values);
        int nextRotation = display.getRotation();
        toScreenMatrix(device, nextRotation, screen, current);
        if (!centered || nextRotation != rotation) {
            // Inverse of an orthonormal rotation is its transpose.
            Matrix.transposeM(inverseCenter, 0, current, 0);
            centered = true;
            rotation = nextRotation;
        }
        Matrix.multiplyMM(relative, 0, inverseCenter, 0, current, 0);
        listener.onOrientation(relative);
    }

    // Android reports a row-major device-to-world matrix. Map portrait/landscape
    // screen axes before passing a column-major camera-to-world matrix to OpenGL.
    static void toScreenMatrix(float[] device, int rotation, float[] screen, float[] camera) {
        int x = SensorManager.AXIS_X, y = SensorManager.AXIS_Y;
        switch (rotation) {
            case Surface.ROTATION_90: x = SensorManager.AXIS_Y; y = SensorManager.AXIS_MINUS_X; break;
            case Surface.ROTATION_180: x = SensorManager.AXIS_MINUS_X; y = SensorManager.AXIS_MINUS_Y; break;
            case Surface.ROTATION_270: x = SensorManager.AXIS_MINUS_Y; y = SensorManager.AXIS_X; break;
            default: break;
        }
        SensorManager.remapCoordinateSystem(device, x, y, screen);
        Matrix.transposeM(camera, 0, screen, 0);
    }

    @Override public void onAccuracyChanged(Sensor sensor, int accuracy) {}
}
