package com.anxiong.nicevideos;

import android.content.Context;
import android.graphics.SurfaceTexture;
import android.opengl.EGL14;
import android.opengl.GLES11Ext;
import android.opengl.GLES20;
import android.opengl.GLSurfaceView;
import android.opengl.Matrix;
import android.os.Handler;
import android.os.Looper;
import android.util.Size;
import android.view.Choreographer;
import android.view.Surface;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.util.concurrent.atomic.AtomicLong;

import javax.microedition.khronos.egl.EGLConfig;
import javax.microedition.khronos.opengles.GL10;

/** One external decoder texture serves both ordinary and stereo projections. */
public final class MovieSurface extends GLSurfaceView {
    public enum Mode { STANDARD, HALF, FULL }

    public interface Listener {
        void onSurfaceReady(Surface surface);
        void onRenderError(String detail);
        default void onFirstFrameDrawn() { }
    }

    private final Listener listener;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final VideoRenderer renderer;
    private volatile VrFormat format = VrFormat.ORDINARY;
    // This lock covers only 16 floats. Sensor/UI and GL threads never wait on a GPU operation.
    private final float[] orientation = new float[16];
    private volatile float shortFov = 80f;
    private volatile Size frameSize = new Size(0, 0);
    private volatile boolean active = true;
    private volatile long decoderGeneration;
    private volatile long presentedSamples;
    private volatile int maxTextureSize;
    private static final int VR_LONG_EDGE = 1920;
    private boolean limitedVrResolution;
    private int fixedWidth, fixedHeight;

    private final Choreographer display = Choreographer.getInstance();
    private final Choreographer.FrameCallback drawAtVsync = this::drawAtVsync;
    private boolean redrawScheduled, newContent;
    private long lastDrawTime;
    // 16 ms allows normal 60 Hz vsync jitter. Decoder and layout changes bypass this limit.
    private static final long POSE_INTERVAL_NS = 16_000_000L;

    // Successful GL submissions of distinct decoder timestamps, not screen refreshes.
    long presentedSamples() { return presentedSamples; }
    int maxTextureSize() { return maxTextureSize; }

    /**
     * The old decoder must have been released. A new buffer queue separates replay or
     * stalled-output recovery from callbacks and images belonging to the retired producer.
     * The listener receives the replacement Surface through the usual onSurfaceReady path.
     */
    void requestFreshDecoderSurface() {
        Surface old = renderer.decoderSurface;
        if (!active) return;
        queueEvent(() -> {
            // A failed producer allocation can leave a live context but no Surface. Permit retry in
            // that case; before initialization or after EGL loss, onSurfaceCreated does the work.
            if (active && old == renderer.decoderSurface && renderer.program != 0
                    && !EGL14.EGL_NO_CONTEXT.equals(EGL14.eglGetCurrentContext())) renderer.replaceProducer();
        });
    }

    public MovieSurface(Context context, Listener listener) {
        super(context);
        this.listener = listener;
        Matrix.setIdentityM(orientation, 0);
        setEGLContextClientVersion(2);
        setEGLConfigChooser(8, 8, 8, 8, 0, 0);
        setPreserveEGLContextOnPause(false);
        renderer = new VideoRenderer();
        setRenderer(renderer);
        setRenderMode(RENDERMODE_WHEN_DIRTY);
    }

    // Only the composited display buffer changes. The incoming decoder SurfaceTexture,
    // movie's sample dimensions and touch coordinates retain their original sizes.
    void setVrRenderQuality(boolean inVr, VrViewerSettings.Quality quality) {
        limitedVrResolution = inVr && quality == VrViewerSettings.Quality.BALANCED;
        resizeDisplayBuffer(getWidth(), getHeight());
    }

    @Override protected void onSizeChanged(int width, int height, int oldWidth, int oldHeight) {
        super.onSizeChanged(width, height, oldWidth, oldHeight);
        resizeDisplayBuffer(width, height);
    }

    private void resizeDisplayBuffer(int width, int height) {
        if (width < 1 || height < 1) return;
        int longest = Math.max(width, height);
        if (!limitedVrResolution || longest <= VR_LONG_EDGE) {
            if (fixedWidth != 0) {
                fixedWidth = fixedHeight = 0;
                getHolder().setSizeFromLayout();
            }
            return;
        }
        double scale = (double) VR_LONG_EDGE / longest;
        int pixelsWide = Math.max(1, (int) Math.round(width * scale));
        int pixelsHigh = Math.max(1, (int) Math.round(height * scale));
        if (pixelsWide == fixedWidth && pixelsHigh == fixedHeight) return;
        fixedWidth = pixelsWide;
        fixedHeight = pixelsHigh;
        getHolder().setFixedSize(pixelsWide, pixelsHigh);
    }

    public void setMode(Mode value) {
        setFormat(value == Mode.STANDARD ? VrFormat.ORDINARY :
                new VrFormat(VrFormat.Projection.FLAT,
                        value == Mode.HALF ? VrFormat.Layout.SBS_HALF : VrFormat.Layout.SBS_FULL, true));
    }

    public void setFormat(VrFormat value) {
        if (value == null) throw new IllegalArgumentException("Missing video format");
        format = value;
        queueDraw(true);
    }

    /** OpenGL column-major rotation: world rays = this matrix * camera rays. */
    public void setViewOrientation(float[] cameraToWorld) {
        if (cameraToWorld == null || cameraToWorld.length < 16) return;
        for (int i = 0; i < 16; i++) if (!Float.isFinite(cameraToWorld[i])) return;
        synchronized (orientation) { System.arraycopy(cameraToWorld, 0, orientation, 0, 16); }
        if (format.projection != VrFormat.Projection.FLAT) queueDraw(false);
    }

    public void setFieldOfView(float degrees) {
        if (!Float.isFinite(degrees)) return;
        float value = Math.min(110f, Math.max(45f, degrees));
        if (value == shortFov) return;
        shortFov = value;
        queueDraw(false);
    }

    // Called on the main thread after any previous decoder has released its
    // Surface. Redrawing its cached texture cannot announce a new first frame.
    public void expectNewDecoderFrame() {
        decoderGeneration++;
        queueDraw(true);
    }

    public void setVideoSize(int width, int height) {
        frameSize = new Size(Math.max(0, width), Math.max(0, height));
        queueDraw(true);
    }

    // Share one draw between all camera samples and video frames received in a display tick.
    // A final queued camera change is still displayed when the movie is paused.
    private synchronized void queueDraw(boolean videoOrLayout) {
        if (!active) return;
        newContent |= videoOrLayout;
        if (!redrawScheduled) {
            redrawScheduled = true;
            display.postFrameCallback(drawAtVsync);
        }
    }

    private synchronized void drawAtVsync(long frameTime) {
        if (!active) return;
        if (!newContent && frameTime - lastDrawTime < POSE_INTERVAL_NS) {
            display.postFrameCallback(drawAtVsync);
            return;
        }
        redrawScheduled = newContent = false;
        lastDrawTime = frameTime;
        requestRender();
    }

    private synchronized void cancelDraw() {
        display.removeFrameCallback(drawAtVsync);
        redrawScheduled = newContent = false;
        lastDrawTime = 0;
    }

    @Override public void onPause() {
        active = false;
        cancelDraw();
        super.onPause();
        renderer.releaseProducer(); // GL thread is paused and its context discarded.
    }

    @Override public void onResume() {
        active = true;
        super.onResume();
    }

    @Override protected void onDetachedFromWindow() {
        cancelDraw();
        super.onDetachedFromWindow();
        renderer.releaseProducer(); // GL thread has exited.
    }

    private static final String VERTEX =
            "attribute vec2 pos; varying vec2 screenPos; void main(){"
            + "screenPos=pos; gl_Position=vec4(pos,0.,1.); }";

    private String readFragmentShader() {
        try (BufferedReader source = new BufferedReader(new InputStreamReader(
                getResources().openRawResource(R.raw.vr_projection), StandardCharsets.UTF_8))) {
            StringBuilder code = new StringBuilder();
            String line;
            while ((line = source.readLine()) != null) code.append(line).append('\n');
            return code.toString();
        } catch (IOException e) {
            throw new IllegalStateException("无法读取视频显示程序", e);
        }
    }

    private final class VideoRenderer implements Renderer {
        private AtomicLong pendingGeneration = new AtomicLong(-1);
        private final FloatBuffer quad = ByteBuffer.allocateDirect(8 * Float.BYTES)
                .order(ByteOrder.nativeOrder()).asFloatBuffer();
        private final float[] transform = new float[16];
        private final float[] pose = new float[16];
        private volatile SurfaceTexture decoderTexture;
        private volatile Surface decoderSurface;
        private int viewWidth, viewHeight, textureName, program;
        private int position, texMatrix, poseMatrix, projectionId, fit, lens, rayExtent, fisheyeDisc, eyeRect, inset;
        private long imageGeneration = -1, announcedGeneration = -1;
        private long imageTimestamp, presentedTimestamp;
        private volatile long producerEpoch;
        private long reportedErrorGeneration = -1;

        VideoRenderer() {
            quad.put(new float[] {-1, -1, 1, -1, -1, 1, 1, 1}).position(0);
        }

        @Override public void onSurfaceCreated(GL10 gl, EGLConfig config) {
            releaseProducer();
            // This is a new context. Names in the discarded context were already reclaimed.
            textureName = program = 0;
            reportedErrorGeneration = -1;
            try {
                int[] limit = new int[1];
                GLES20.glGetIntegerv(GLES20.GL_MAX_TEXTURE_SIZE, limit, 0);
                maxTextureSize = limit[0];
                program = createProgram(readFragmentShader());
                position = GLES20.glGetAttribLocation(program, "pos");
                texMatrix = GLES20.glGetUniformLocation(program, "textureTransform");
                fit = GLES20.glGetUniformLocation(program, "fit");
                lens = GLES20.glGetUniformLocation(program, "lens");
                poseMatrix = GLES20.glGetUniformLocation(program, "cameraToWorld");
                projectionId = GLES20.glGetUniformLocation(program, "projection");
                rayExtent = GLES20.glGetUniformLocation(program, "rayExtent");
                fisheyeDisc = GLES20.glGetUniformLocation(program, "fisheyeDisc");
                eyeRect = GLES20.glGetUniformLocation(program, "eyeRect");
                inset = GLES20.glGetUniformLocation(program, "texelInset");

                createProducer();
            } catch (RuntimeException e) {
                releaseProducer();
                reportError(e);
            }
        }

        private void createProducer() {
            imageGeneration = announcedGeneration = reportedErrorGeneration = -1;
            int[] textures = new int[1];
            GLES20.glGenTextures(1, textures, 0);
            textureName = textures[0];
            int target = GLES11Ext.GL_TEXTURE_EXTERNAL_OES;
            GLES20.glBindTexture(target, textureName);
            GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
            GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
            GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
            GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);
            checkGl();
            SurfaceTexture image = new SurfaceTexture(textureName);
            decoderTexture = image;
            AtomicLong pending = new AtomicLong(-1);
            pendingGeneration = pending;
            image.setOnFrameAvailableListener(frame -> {
                if (active && decoderTexture == frame) {
                    // A callback racing with release can write only to its own producer's slot.
                    pending.set(decoderGeneration);
                    queueDraw(true);
                }
            }, main);
            Surface surface = new Surface(image);
            decoderSurface = surface;
            main.post(() -> {
                if (active && decoderSurface == surface) listener.onSurfaceReady(surface);
            });
        }

        /** Runs on the GL thread while the existing EGL context is current. */
        void replaceProducer() {
            releaseProducer();
            if (textureName != 0) GLES20.glDeleteTextures(1, new int[]{textureName}, 0);
            textureName = 0;
            try {
                createProducer();
                queueDraw(true);
            } catch (RuntimeException e) {
                releaseProducer();
                reportError(e);
            }
        }

        void releaseProducer() {
            producerEpoch++;
            Surface surface = decoderSurface;
            SurfaceTexture image = decoderTexture;
            decoderSurface = null;
            decoderTexture = null;
            pendingGeneration.set(-1);
            if (surface != null) surface.release();
            if (image != null) {
                image.setOnFrameAvailableListener(null);
                image.release();
            }
        }

        @Override public void onSurfaceChanged(GL10 gl, int width, int height) {
            viewWidth = width;
            viewHeight = height;
        }

        @Override public void onDrawFrame(GL10 gl) {
            GLES20.glClearColor(0, 0, 0, 1);
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
            SurfaceTexture image = decoderTexture;
            if (!active || image == null || viewWidth < 1 || viewHeight < 1) return;
            long pending = pendingGeneration.getAndSet(-1);
            long generation = decoderGeneration;
            if (pending == generation) {
                try {
                    image.updateTexImage();
                    image.getTransformMatrix(transform);
                    imageTimestamp = image.getTimestamp();
                    imageGeneration = generation;
                } catch (RuntimeException e) {
                    reportError(e);
                    return;
                }
            }
            if (imageGeneration != generation) return;
            Size video = frameSize;
            int width = video.getWidth(), height = video.getHeight();
            if (width == 0 || height == 0) return;
            GLES20.glUseProgram(program);
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureName);
            GLES20.glUniformMatrix4fv(texMatrix, 1, false, transform, 0);
            GLES20.glVertexAttribPointer(position, 2, GLES20.GL_FLOAT, false, 0, quad);
            GLES20.glEnableVertexAttribArray(position);
            GLES20.glUniform2f(inset, .5f / width, .5f / height);
            synchronized (orientation) { System.arraycopy(orientation, 0, pose, 0, 16); }
            GLES20.glUniformMatrix4fv(poseMatrix, 1, false, pose, 0);
            VrFormat selected = format;
            GLES20.glUniform1i(projectionId, selected.projection.shaderId);
            if (!selected.headset || viewWidth < 2) {
                drawEye(0, viewWidth, selected, false, width, height);
            } else {
                int split = viewWidth / 2;
                drawEye(0, split, selected, false, width, height);
                drawEye(split, viewWidth - split, selected, true, width, height);
            }
            if (!active || generation != decoderGeneration || decoderTexture != image) return;
            // A draw accepted by GL is not proof the panel presented it. Pose-only redraws
            // reuse the cached decoder image, so they cannot keep the picture watchdog alive.
            if (announcedGeneration != generation || imageTimestamp != presentedTimestamp) {
                try {
                    checkGl();
                } catch (RuntimeException e) {
                    reportError(e);
                    return;
                }
                presentedTimestamp = imageTimestamp;
                presentedSamples++;
            }
            if (announcedGeneration != generation) {
                announcedGeneration = generation;
                main.post(() -> {
                    if (active && decoderTexture == image && decoderGeneration == generation) listener.onFirstFrameDrawn();
                });
            }
        }

        private void drawEye(int left, int viewportWidth, VrFormat selected, boolean right,
                             int frameWidth, int frameHeight) {
            // Use integer eye boundaries to leave an ambiguous odd center row/column unused.
            int x = 0, y = 0, w = frameWidth, h = frameHeight;
            float pixelWidth = 1f;
            switch (selected.layout) {
                case SBS_HALF:
                case SBS_FULL:
                    w = Math.max(1, frameWidth / 2);
                    x = right ? frameWidth - w : 0;
                    pixelWidth = selected.layout == VrFormat.Layout.SBS_HALF ? 2f : 1f;
                    break;
                case TOP_BOTTOM:
                    h = Math.max(1, frameHeight / 2);
                    y = right ? 0 : frameHeight - h;
                    break;
                case MONO:
                    break;
            }
            GLES20.glUniform4f(eyeRect, (float)x / frameWidth, (float)y / frameHeight,
                    (float)(x + w) / frameWidth, (float)(y + h) / frameHeight);
            float eyeAspect = pixelWidth * w / h;
            float screenAspect = (float)viewportWidth / viewHeight;
            GLES20.glViewport(left, 0, viewportWidth, viewHeight);
            GLES20.glUniform2f(fit, Math.min(1f, eyeAspect / screenAspect), Math.min(1f, screenAspect / eyeAspect));

            float shortSide = Math.min(viewportWidth, viewHeight);
            float lensScale = selected.headset ? .83909965f / shortSide : 0f; // Cardboard v1 tan(40°)
            GLES20.glUniform2f(lens, lensScale * viewportWidth, lensScale * viewHeight);
            float perspective = (float)Math.tan(Math.toRadians(shortFov * .5f)) / shortSide;
            GLES20.glUniform2f(rayExtent, perspective * viewportWidth, perspective * viewHeight);
            GLES20.glUniform2f(fisheyeDisc, Math.min(1f, 1f / eyeAspect), Math.min(1f, eyeAspect));
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
        }

        private void checkGl() {
            int error = GLES20.glGetError();
            if (error != GLES20.GL_NO_ERROR)
                throw new IllegalStateException("OpenGL ES 0x" + Integer.toHexString(error));
        }

        private void reportError(RuntimeException error) {
            long generation = decoderGeneration;
            if (reportedErrorGeneration == generation) return;
            reportedErrorGeneration = generation;
            long epoch = producerEpoch;
            main.post(() -> {
                if (active && producerEpoch == epoch && decoderGeneration == generation)
                    listener.onRenderError("无法绘制视频画面：" + error.getMessage());
            });
        }
    }

    private static int shader(int type, String source) {
        int id = GLES20.glCreateShader(type);
        GLES20.glShaderSource(id, source);
        GLES20.glCompileShader(id);
        int[] status = new int[1];
        GLES20.glGetShaderiv(id, GLES20.GL_COMPILE_STATUS, status, 0);
        if (status[0] == 0) throw new IllegalStateException(GLES20.glGetShaderInfoLog(id));
        return id;
    }

    private static int createProgram(String fragmentSource) {
        int id = GLES20.glCreateProgram();
        int vertex = shader(GLES20.GL_VERTEX_SHADER, VERTEX);
        int fragment = shader(GLES20.GL_FRAGMENT_SHADER, fragmentSource);
        GLES20.glAttachShader(id, vertex);
        GLES20.glAttachShader(id, fragment);
        GLES20.glLinkProgram(id);
        int[] status = new int[1];
        GLES20.glGetProgramiv(id, GLES20.GL_LINK_STATUS, status, 0);
        GLES20.glDeleteShader(vertex);
        GLES20.glDeleteShader(fragment);
        if (status[0] == 0) throw new IllegalStateException(GLES20.glGetProgramInfoLog(id));
        return id;
    }
}
