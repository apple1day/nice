package com.anxiong.nicevideos;

import android.app.Activity;
import android.opengl.Matrix;
import android.view.GestureDetector;
import android.view.MotionEvent;
import android.view.ScaleGestureDetector;

/** Maps screen-space gestures and the display-corrected head pose to the camera. */
final class VrLookControls {
    private final MovieSurface movie;
    private final VrHeadTracker tracker;
    private final Runnable zoomFinished;
    private final float[] head = new float[16], touch = new float[16], camera = new float[16];
    private float yaw, pitch, fieldOfView = 80;
    private boolean panorama, headset, resumed, followHead, multiplePointers;

    VrLookControls(Activity owner, MovieSurface movie, Runnable zoomFinished) {
        this.movie = movie;
        this.zoomFinished = zoomFinished;
        Matrix.setIdentityM(head, 0);
        tracker = new VrHeadTracker(owner, orientation -> {
            System.arraycopy(orientation, 0, head, 0, 16);
            orient();
        });

        ScaleGestureDetector scale = new ScaleGestureDetector(owner,
                new ScaleGestureDetector.SimpleOnScaleGestureListener() {
            @Override public boolean onScaleBegin(ScaleGestureDetector detector) { return panorama; }
            @Override public boolean onScale(ScaleGestureDetector detector) {
                double scale = detector.getScaleFactor();
                if (!(scale > 0) || !Double.isFinite(scale)) return false;
                double halfAngle = Math.toRadians(fieldOfView / 2.0);
                setFieldOfView((float) Math.toDegrees(2 * Math.atan(Math.tan(halfAngle) / scale)));
                return true;
            }
            @Override public void onScaleEnd(ScaleGestureDetector detector) { zoomFinished.run(); }
        });
        scale.setQuickScaleEnabled(false);
        GestureDetector gesture = new GestureDetector(owner, new GestureDetector.SimpleOnGestureListener() {
            @Override public boolean onDown(MotionEvent down) { return true; }
            @Override public boolean onSingleTapConfirmed(MotionEvent tap) { return movie.performClick(); }
            @Override public boolean onDoubleTap(MotionEvent tap) {
                if (panorama) recenter();
                else movie.performClick();
                return true;
            }
            @Override public boolean onScroll(MotionEvent down, MotionEvent move, float dx, float dy) {
                if (!panorama || multiplePointers) return false;
                float viewWidth = headset ? movie.getWidth() * 0.5f : movie.getWidth();
                float shortSide = Math.max(1, Math.min(viewWidth, movie.getHeight()));
                double projection = 2 * Math.tan(Math.toRadians(fieldOfView * 0.5)) / shortSide;
                // Grabbing the image and moving it left reveals the scene to the right.
                yaw = (yaw + (float) Math.toDegrees(Math.atan(dx * projection))) % 360;
                pitch = Math.max(-89, Math.min(89, pitch - (float) Math.toDegrees(Math.atan(dy * projection))));
                orient();
                return true;
            }
        });
        movie.setOnTouchListener((v, event) -> {
            if (event.getActionMasked() == MotionEvent.ACTION_DOWN) multiplePointers = false;
            if (event.getPointerCount() > 1) multiplePointers = true;
            scale.onTouchEvent(event);
            gesture.onTouchEvent(event);
            return true;
        });
    }

    void configure(boolean panorama, boolean headset, boolean followHead, float fov) {
        boolean changedProjection = panorama != this.panorama;
        this.panorama = panorama;
        this.headset = headset;
        this.followHead = followHead;
        setFieldOfView(fov);
        if (changedProjection) recenter();
        updateSensor();
    }

    boolean sensorAvailable() { return tracker.isAvailable(); }
    float fieldOfView() { return fieldOfView; }

    void setResumed(boolean resumed) {
        this.resumed = resumed;
        updateSensor();
    }

    private void updateSensor() {
        boolean enabled = resumed && panorama && followHead && sensorAvailable();
        tracker.setEnabled(enabled);
        if (!enabled) {
            Matrix.setIdentityM(head, 0);
            orient();
        }
    }

    void recenter() {
        yaw = pitch = 0;
        Matrix.setIdentityM(head, 0);
        tracker.recenter();
        orient();
    }

    private void setFieldOfView(float value) {
        fieldOfView = Math.max(45f, Math.min(110f, value));
        movie.setFieldOfView(fieldOfView);
    }

    private void orient() {
        Matrix.setRotateM(touch, 0, -yaw, 0, 1, 0);
        Matrix.multiplyMM(camera, 0, touch, 0, head, 0);
        Matrix.rotateM(camera, 0, pitch, 1, 0, 0);
        movie.setViewOrientation(camera);
    }
}
