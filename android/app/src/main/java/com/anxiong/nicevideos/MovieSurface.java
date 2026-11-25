package com.anxiong.nicevideos;

import android.content.Context;
import android.graphics.SurfaceTexture;
import android.opengl.GLES11Ext;
import android.opengl.GLES20;
import android.opengl.GLSurfaceView;
import android.os.Handler;
import android.os.Looper;
import android.util.Size;
import android.view.Surface;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.util.concurrent.atomic.AtomicBoolean;

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
    private volatile Mode mode = Mode.STANDARD;
    private volatile Size frameSize = new Size(0, 0);
    private volatile boolean active = true;

    public MovieSurface(Context context, Listener listener) {
        super(context);
        this.listener = listener;
        setEGLContextClientVersion(2);
        setEGLConfigChooser(8, 8, 8, 8, 0, 0);
        setPreserveEGLContextOnPause(false);
        renderer = new VideoRenderer();
        setRenderer(renderer);
        setRenderMode(RENDERMODE_WHEN_DIRTY);
    }

    public void setMode(Mode value) {
        mode = value;
        requestRender(); // Switch projections even while paused on a frame.
    }

    public void setVideoSize(int width, int height) {
        frameSize = new Size(Math.max(0, width), Math.max(0, height));
        requestRender();
    }

    @Override public void onPause() {
        active = false;
        super.onPause();
        renderer.releaseProducer(); // GL thread is paused and its context discarded.
    }

    @Override public void onResume() {
        active = true;
        super.onResume();
    }

    @Override protected void onDetachedFromWindow() {
        super.onDetachedFromWindow();
        renderer.releaseProducer(); // GL thread has exited.
    }

    private static final String VERTEX =
            "attribute vec2 pos; varying vec2 screenPos; void main(){"
            + "screenPos=pos; gl_Position=vec4(pos,0.,1.); }";

    // Inverse-map display pixels to movie UV. The v1 Cardboard polynomial and
    // 40-degree half-FOV match the optics in the iOS player.
    private static final String FRAGMENT =
            "#extension GL_OES_EGL_image_external : require\n"
            + "#ifdef GL_FRAGMENT_PRECISION_HIGH\nprecision highp float;\n#else\nprecision mediump float;\n#endif\n"
            + "varying vec2 screenPos; uniform samplerExternalOES movie; uniform mat4 transform;"
            + "uniform vec2 fit, lens, slice; uniform float inset;"
            + "void main(){ vec2 ray=screenPos*lens; float r2=dot(ray,ray);"
            + "vec2 p=screenPos*(1.+r2*(.441+.156*r2))/fit;"
            + "if(max(abs(p.x),abs(p.y))>1.){gl_FragColor=vec4(0.,0.,0.,1.);return;}"
            + "vec2 uv=p*.5+.5; uv.x=clamp(mix(slice.x,slice.y,uv.x),slice.x+inset,slice.y-inset);"
            + "gl_FragColor=vec4(texture2D(movie,(transform*vec4(uv,0.,1.)).xy).rgb,1.); }";

    private final class VideoRenderer implements Renderer {
        private final AtomicBoolean frameAvailable = new AtomicBoolean();
        private final FloatBuffer quad = ByteBuffer.allocateDirect(8 * Float.BYTES)
                .order(ByteOrder.nativeOrder()).asFloatBuffer();
        private final float[] transform = new float[16];
        private volatile SurfaceTexture decoderTexture;
        private volatile Surface decoderSurface;
        private int viewWidth, viewHeight, textureName, program;
        private int position, texMatrix, fit, lens, slice, inset;
        private boolean hasImage, announcedFrame;

        VideoRenderer() {
            quad.put(new float[] {-1, -1, 1, -1, -1, 1, 1, 1}).position(0);
        }

        @Override public void onSurfaceCreated(GL10 gl, EGLConfig config) {
            releaseProducer();
            hasImage = announcedFrame = false;
            try {
                program = createProgram();
                position = GLES20.glGetAttribLocation(program, "pos");
                texMatrix = GLES20.glGetUniformLocation(program, "transform");
                fit = GLES20.glGetUniformLocation(program, "fit");
                lens = GLES20.glGetUniformLocation(program, "lens");
                slice = GLES20.glGetUniformLocation(program, "slice");
                inset = GLES20.glGetUniformLocation(program, "inset");

                int[] textures = new int[1];
                GLES20.glGenTextures(1, textures, 0);
                textureName = textures[0];
                int target = GLES11Ext.GL_TEXTURE_EXTERNAL_OES;
                GLES20.glBindTexture(target, textureName);
                GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
                GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
                GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
                GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);
                SurfaceTexture image = new SurfaceTexture(textureName);
                decoderTexture = image;
                image.setOnFrameAvailableListener(frame -> {
                    if (active && decoderTexture == frame) {
                        frameAvailable.set(true);
                        requestRender();
                    }
                }, main);
                Surface surface = new Surface(image);
                decoderSurface = surface;
                main.post(() -> {
                    if (active && decoderSurface == surface) listener.onSurfaceReady(surface);
                });
            } catch (RuntimeException e) {
                releaseProducer();
                reportError(e);
            }
        }

        void releaseProducer() {
            Surface surface = decoderSurface;
            SurfaceTexture image = decoderTexture;
            decoderSurface = null;
            decoderTexture = null;
            frameAvailable.set(false);
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
            if (frameAvailable.getAndSet(false)) {
                try {
                    image.updateTexImage();
                    image.getTransformMatrix(transform);
                    hasImage = true;
                } catch (RuntimeException e) {
                    reportError(e);
                    return;
                }
            }
            if (!hasImage) return;
            Size video = frameSize;
            int width = video.getWidth(), height = video.getHeight();
            if (width == 0 || height == 0) return;
            GLES20.glUseProgram(program);
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureName);
            GLES20.glUniformMatrix4fv(texMatrix, 1, false, transform, 0);
            GLES20.glVertexAttribPointer(position, 2, GLES20.GL_FLOAT, false, 0, quad);
            GLES20.glEnableVertexAttribArray(position);
            GLES20.glUniform1f(inset, .5f / width);
            float aspect = width / (float) height;
            Mode projection = mode;
            if (projection == Mode.STANDARD || width < 2 || viewWidth < 2) {
                drawView(0, viewWidth, aspect, false, 0, 1);
            } else {
                // Exclude the middle column of an odd-width frame from both eyes.
                int split = viewWidth / 2;
                float half = (width / 2) / (float) width;
                float eyeAspect = projection == Mode.HALF ? aspect : aspect * .5f;
                drawView(0, split, eyeAspect, true, 0, half);
                drawView(split, viewWidth - split, eyeAspect, true, 1 - half, 1);
            }
            if (!announcedFrame) {
                announcedFrame = true;
                main.post(() -> {
                    if (active && decoderTexture == image) listener.onFirstFrameDrawn();
                });
            }
        }

        private void drawView(int left, int width, float aspect, boolean stereo, float from, float to) {
            float screenAspect = width / (float) viewHeight;
            GLES20.glViewport(left, 0, width, viewHeight);
            GLES20.glUniform2f(fit, Math.min(1f, aspect / screenAspect), Math.min(1f, screenAspect / aspect));
            float radial = stereo ? 0.83909965f / Math.min(width, viewHeight) : 0f; // tan(40°)
            GLES20.glUniform2f(lens, radial * width, radial * viewHeight);
            GLES20.glUniform2f(slice, from, to);
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
        }

        private void reportError(RuntimeException error) {
            main.post(() -> {
                if (active) listener.onRenderError("无法绘制视频画面：" + error.getMessage());
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

    private static int createProgram() {
        int id = GLES20.glCreateProgram();
        int vertex = shader(GLES20.GL_VERTEX_SHADER, VERTEX);
        int fragment = shader(GLES20.GL_FRAGMENT_SHADER, FRAGMENT);
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
