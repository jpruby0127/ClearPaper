package com.jpruby.clearpaper;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.ImageFormat;
import android.graphics.Matrix;
import android.graphics.SurfaceTexture;
import android.graphics.drawable.GradientDrawable;
import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.media.Image;
import android.media.ImageReader;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Size;
import android.view.Gravity;
import android.view.Surface;
import android.view.TextureView;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.Arrays;

/**
 * App 内置文档相机（Camera2），不依赖任何外部相机 App。
 *
 * 之前的版本用 MediaStore.ACTION_IMAGE_CAPTURE 拉起系统相机，在 targetSdk 30+ 上会同时踩到
 * 两个坑：Manifest 里没有 queries 声明导致包可见性过滤后解析不到相机 App；
 * 声明了 CAMERA 权限却没有动态申请，相机 App 会直接拒绝。两者都会表现成「没有可用的相机」，
 * 即使手机明明有摄像头。这里改成自己开 Camera2，顺带把无相机设备、权限拒绝、相机被占用
 * 三种情况分开返回，让调用方能给出准确的下一步。
 *
 * 手动快门逐页拍：不会因来不及翻页重复拍同一张；拍完统一进检查拍摄页。
 */
public final class CameraActivity extends Activity {
    public static final String EXTRA_DIR = "dir";
    public static final String EXTRA_PATHS = "paths";
    public static final String EXTRA_REASON = "reason";

    public static final String REASON_NO_CAMERA = "no_camera";
    public static final String REASON_DENIED = "denied";
    public static final String REASON_BUSY = "busy";
    public static final String REASON_SYSTEM_CAMERA = "system_camera";

    private static final int REQ_PERMISSION = 7;
    private static final int PREVIEW_MAX = 1920;
    private static final String PREF_CAM_ROT = "cp.camera.rotation";

    private File dir;
    private final ArrayList<String> shots = new ArrayList<>();
    private TextureView preview;
    private TextView counter, done, flashBtn, tip, rotateBtn;
    private View shutter;

    private String cameraId;
    private CameraDevice camera;
    private CameraCaptureSession session;
    private ImageReader reader;
    private CaptureRequest.Builder previewBuilder;
    private Size previewSize, jpegSize;
    private boolean flashAvailable = false, autoFlashAvailable = false;
    private int sensorOrientation = 90;
    private int userRotation = 0;   // 用户手动校正的预览方向，持久保存

    private HandlerThread camThread, imageThread;
    private Handler camHandler, imageHandler;
    private boolean resumed, surfaceReady, taking, flashOn, failed;

    /** 相机硬件检测：CameraManager 列不出设备时再用 FEATURE_CAMERA_ANY 兜底一次。 */
    public static boolean hasCamera(Context c) {
        try {
            CameraManager m = (CameraManager) c.getSystemService(Context.CAMERA_SERVICE);
            if (m != null && m.getCameraIdList().length > 0) return true;
        } catch (Exception ignored) {}
        PackageManager pm = c.getPackageManager();
        return pm.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)
                || pm.hasSystemFeature(PackageManager.FEATURE_CAMERA);
    }

    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        App.ctx = getApplicationContext();
        requestWindowFeature(Window.FEATURE_NO_TITLE);
        getWindow().setFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN,
                WindowManager.LayoutParams.FLAG_FULLSCREEN);

        String p = getIntent().getStringExtra(EXTRA_DIR);
        dir = new File(p != null ? p
                : new File(getFilesDir(), "ClearPaper/Review/" + java.util.UUID.randomUUID()).getPath());
        dir.mkdirs();
        userRotation = getSharedPreferences("clearpaper", MODE_PRIVATE)
                .getInt(PREF_CAM_ROT, 0) % 360;

        buildUi();
        if (!hasCamera(this)) { fail(REASON_NO_CAMERA); return; }
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.CAMERA}, REQ_PERMISSION);
        } else {
            openCameraIfReady();
        }
    }

    private void buildUi() {
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(0xFF000000);

        preview = new TextureView(this);
        root.addView(preview, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        preview.setSurfaceTextureListener(new TextureView.SurfaceTextureListener() {
            @Override public void onSurfaceTextureAvailable(SurfaceTexture st, int w, int h) {
                surfaceReady = true;
                configureTransform(w, h);
                openCameraIfReady();
            }
            @Override public void onSurfaceTextureSizeChanged(SurfaceTexture st, int w, int h) {
                configureTransform(w, h);
            }
            @Override public boolean onSurfaceTextureDestroyed(SurfaceTexture st) {
                surfaceReady = false;
                closeCamera();
                return true;
            }
            @Override public void onSurfaceTextureUpdated(SurfaceTexture st) {}
        });

        LinearLayout top = Ui.hbox(this);
        top.setBackgroundColor(0x99000000);
        top.setPadding(Ui.dp(this, 16), Ui.dp(this, 14), Ui.dp(this, 16), Ui.dp(this, 14));
        TextView cancel = Ui.text(this, "取消", 14, 0xFFFFFFFF, false);
        cancel.setOnClickListener(v -> cancel());
        top.addView(cancel);
        TextView title = Ui.text(this, "拍照扫描", 15, 0xFFFFFFFF, true);
        title.setGravity(Gravity.CENTER);
        top.addView(title, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        rotateBtn = Ui.text(this, "画面 " + userRotation + "°", 12, 0xFFFFFFFF, true);
        rotateBtn.setPadding(Ui.dp(this, 10), 0, Ui.dp(this, 10), 0);
        rotateBtn.setOnClickListener(v -> rotateView());
        top.addView(rotateBtn);
        flashBtn = Ui.text(this, "补光 关", 12, 0xFFFFFFFF, true);
        flashBtn.setVisibility(View.INVISIBLE);
        flashBtn.setOnClickListener(v -> toggleFlash());
        top.addView(flashBtn);
        root.addView(top, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP));

        tip = Ui.text(this, "把试卷放进取景框，逐页按快门\n拍完点「完成」再逐页检查",
                12, 0xFFE8E8EA, false);
        tip.setGravity(Gravity.CENTER);
        tip.setBackgroundColor(0x66000000);
        tip.setPadding(Ui.dp(this, 12), Ui.dp(this, 8), Ui.dp(this, 12), Ui.dp(this, 8));
        FrameLayout.LayoutParams tp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER_HORIZONTAL | Gravity.TOP);
        tp.topMargin = Ui.dp(this, 70);
        root.addView(tip, tp);

        LinearLayout bottom = new LinearLayout(this);
        bottom.setOrientation(LinearLayout.VERTICAL);
        bottom.setBackgroundColor(0xCC000000);
        bottom.setPadding(Ui.dp(this, 16), Ui.dp(this, 14), Ui.dp(this, 16), Ui.dp(this, 26));
        counter = Ui.text(this, "已拍 0 页", 12, 0xFFFFFFFF, true);
        counter.setGravity(Gravity.CENTER);
        bottom.addView(counter);

        LinearLayout row = Ui.hbox(this);
        row.setGravity(Gravity.CENTER);
        row.setPadding(0, Ui.dp(this, 14), 0, Ui.dp(this, 10));

        TextView gallery = Ui.text(this, "相册", 13, 0xFFDDDDDF, true);
        gallery.setGravity(Gravity.CENTER);
        gallery.setOnClickListener(v -> pickImages());
        row.addView(gallery, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));

        shutter = new View(this);
        GradientDrawable ring = new GradientDrawable();
        ring.setShape(GradientDrawable.OVAL);
        ring.setColor(0xFFFFFFFF);
        ring.setStroke(Ui.dp(this, 4), 0x66FFFFFF);
        shutter.setBackground(ring);
        shutter.setOnClickListener(v -> takePicture());
        row.addView(shutter, new LinearLayout.LayoutParams(Ui.dp(this, 72), Ui.dp(this, 72)));

        done = Ui.text(this, "完成", 13, 0xFFF0A83C, true);
        done.setGravity(Gravity.CENTER);
        done.setOnClickListener(v -> finishWithShots());
        row.addView(done, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        bottom.addView(row, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        TextView note = Ui.text(this, "手动快门 · 不会因来不及翻页重复拍同一张",
                10, 0xFFB8B8BC, false);
        note.setGravity(Gravity.CENTER);
        bottom.addView(note);
        TextView sys = Ui.text(this, "画面仍不对？改用系统相机拍", 11, 0xFF9AC0FF, true);
        sys.setGravity(Gravity.CENTER);
        sys.setPadding(0, Ui.dp(this, 10), 0, 0);
        sys.setOnClickListener(v -> useSystemCamera());
        bottom.addView(sys);
        root.addView(bottom, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM));

        setContentView(root);
    }

    // MARK: 生命周期与权限

    @Override protected void onResume() {
        super.onResume();
        resumed = true;
        if (!failed) {
            startThreads();
            openCameraIfReady();
        }
    }

    @Override protected void onPause() {
        resumed = false;
        closeCamera();
        stopThreads();
        super.onPause();
    }

    @Override public void onRequestPermissionsResult(int req, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(req, permissions, results);
        if (req != REQ_PERMISSION) return;
        if (results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED) openCameraIfReady();
        else fail(REASON_DENIED);
    }

    private void startThreads() {
        if (camThread == null) {
            camThread = new HandlerThread("cp-camera");
            camThread.start();
            camHandler = new Handler(camThread.getLooper());
        }
        if (imageThread == null) {
            imageThread = new HandlerThread("cp-image");
            imageThread.start();
            imageHandler = new Handler(imageThread.getLooper());
        }
    }

    private void stopThreads() {
        if (camThread != null) { camThread.quitSafely(); camThread = null; camHandler = null; }
        if (imageThread != null) { imageThread.quitSafely(); imageThread = null; imageHandler = null; }
    }

    // MARK: 开相机 / 预览

    private void openCameraIfReady() {
        if (failed || !resumed || !surfaceReady || camera != null) return;
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) return;
        if (camHandler == null) startThreads();
        try {
            CameraManager mgr = (CameraManager) getSystemService(Context.CAMERA_SERVICE);
            if (mgr == null) { fail(REASON_NO_CAMERA); return; }
            cameraId = chooseCamera(mgr);
            if (cameraId == null) { fail(REASON_NO_CAMERA); return; }
            CameraCharacteristics cc = mgr.getCameraCharacteristics(cameraId);
            Integer so = cc.get(CameraCharacteristics.SENSOR_ORIENTATION);
            sensorOrientation = so != null ? so : 90;
            Boolean hasFlash = cc.get(CameraCharacteristics.FLASH_INFO_AVAILABLE);
            flashAvailable = Boolean.TRUE.equals(hasFlash);
            int[] aeModes = cc.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_MODES);
            if (aeModes != null) {
                for (int m : aeModes) if (m == CameraCharacteristics.CONTROL_AE_MODE_ON_AUTO_FLASH)
                    autoFlashAvailable = true;
            }
            runOnUiThread(() -> {
                if (flashBtn != null) flashBtn.setVisibility(flashAvailable ? View.VISIBLE : View.INVISIBLE);
            });

            StreamConfigurationMap map = cc.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
            if (map == null) { fail(REASON_BUSY); return; }
            jpegSize = chooseJpegSize(map.getOutputSizes(ImageFormat.JPEG));
            android.util.DisplayMetrics dm = getResources().getDisplayMetrics();
            previewSize = choosePreviewSize(map.getOutputSizes(SurfaceTexture.class),
                    dm.widthPixels, dm.heightPixels);
            if (jpegSize == null || previewSize == null) { fail(REASON_BUSY); return; }

            reader = ImageReader.newInstance(jpegSize.getWidth(), jpegSize.getHeight(),
                    ImageFormat.JPEG, 2);
            reader.setOnImageAvailableListener(r -> onImage(r), imageHandler);

            SurfaceTexture st = preview.getSurfaceTexture();
            if (st == null) return;
            st.setDefaultBufferSize(previewSize.getWidth(), previewSize.getHeight());
            configureTransform(preview.getWidth(), preview.getHeight());
            mgr.openCamera(cameraId, stateCallback, camHandler);
        } catch (SecurityException e) {
            fail(REASON_DENIED);
        } catch (Exception e) {
            fail(REASON_BUSY);
        }
    }

    private String chooseCamera(CameraManager mgr) throws CameraAccessException {
        String first = null;
        for (String id : mgr.getCameraIdList()) {
            if (first == null) first = id;
            CameraCharacteristics c = mgr.getCameraCharacteristics(id);
            Integer facing = c.get(CameraCharacteristics.LENS_FACING);
            if (facing != null && facing == CameraCharacteristics.LENS_FACING_BACK) return id;
        }
        return first;
    }

    private static Size chooseJpegSize(Size[] sizes) {
        if (sizes == null || sizes.length == 0) return null;
        Size best = null; long bestArea = -1;
        for (Size s : sizes) {
            long side = Math.max(s.getWidth(), s.getHeight());
            if (side > 3200) continue;                  // 交给 Capture.normalize 时不会占太多内存
            long area = (long) s.getWidth() * s.getHeight();
            if (area > bestArea) { bestArea = area; best = s; }
        }
        if (best == null) {
            best = sizes[0];
            for (Size s : sizes) if ((long) s.getWidth() * s.getHeight()
                    < (long) best.getWidth() * best.getHeight()) best = s;
        }
        return best;
    }

    /** 选与竖屏取景框比例最接近的预览尺寸，避免画面被横向压扁或拉伸。 */
    private static Size choosePreviewSize(Size[] sizes, int vw, int vh) {
        if (sizes == null || sizes.length == 0) return null;
        float target = (float) Math.min(vw, vh) / Math.max(Math.max(vw, vh), 1);
        Size best = null; float bestScore = -1e9f;
        for (Size s : sizes) {
            long side = Math.max(s.getWidth(), s.getHeight());
            if (side > PREVIEW_MAX) continue;
            float ratio = (float) Math.min(s.getWidth(), s.getHeight()) / side;
            float score = -Math.abs(ratio - target) * 10f + (float) side / PREVIEW_MAX;
            if (score > bestScore) { bestScore = score; best = s; }
        }
        if (best == null) {
            best = sizes[0];
            for (Size s : sizes) if ((long) s.getWidth() * s.getHeight()
                    < (long) best.getWidth() * best.getHeight()) best = s;
        }
        return best;
    }

    /**
     * 默认 identity：Camera2 的预览方向由系统按 sensor / display 方向自行处理，
     * TextureView 会把它正确转正。build 11 在这里额外叠加了「旋转 90° + center-crop 放大」，
     * 等于把已经转正的画面再转一次、再放大裁一次，才出现「放大且反转」。
     *
     * 用户手动校正时只做纯旋转 + 等比缩小（完整容纳，绝不放大裁切）。
     */
    private void configureTransform(int vw, int vh) {
        if (preview == null || vw <= 0 || vh <= 0) return;
        try {
            Matrix m = new Matrix();
            if (userRotation != 0) {
                float r = (float) Math.toRadians(userRotation);
                float c = Math.abs((float) Math.cos(r)), s = Math.abs((float) Math.sin(r));
                float outerW = vw * c + vh * s;
                float outerH = vw * s + vh * c;
                float fit = Math.min(vw / outerW, vh / outerH);
                m.postRotate(userRotation, vw / 2f, vh / 2f);
                m.postScale(fit, fit, vw / 2f, vh / 2f);
            }
            preview.setTransform(m);
        } catch (Exception ignored) {}
    }

    private void rotateView() {
        userRotation = (userRotation + 90) % 360;
        getSharedPreferences("clearpaper", MODE_PRIVATE).edit()
                .putInt(PREF_CAM_ROT, userRotation).apply();
        rotateBtn.setText("画面 " + userRotation + "°");
        configureTransform(preview.getWidth(), preview.getHeight());
        toast("画面已转到 " + userRotation + "°，拍照方向会一起调整");
    }

    /** Camera2Basic 的标准公式：让设备把 JPEG 方向写进 EXIF / 物理转正。 */
    private int jpegOrientation() {
        int r = getWindowManager().getDefaultDisplay().getRotation();
        int idx = r == Surface.ROTATION_90 ? 1 : r == Surface.ROTATION_180 ? 2
                : r == Surface.ROTATION_270 ? 3 : 0;
        int[] ORIENT = {90, 0, 270, 180};
        return (ORIENT[idx] + sensorOrientation + 270 + userRotation) % 360;
    }

    private final CameraDevice.StateCallback stateCallback = new CameraDevice.StateCallback() {
        @Override public void onOpened(CameraDevice dev) {
            camera = dev;
            createSession();
        }
        @Override public void onDisconnected(CameraDevice dev) {
            dev.close();
            camera = null;
            fail(REASON_BUSY);
        }
        @Override public void onError(CameraDevice dev, int error) {
            dev.close();
            camera = null;
            fail(REASON_BUSY);
        }
    };

    private void createSession() {
        try {
            SurfaceTexture st = preview.getSurfaceTexture();
            if (st == null || reader == null) { fail(REASON_BUSY); return; }
            final Surface previewSurface = new Surface(st);
            camera.createCaptureSession(Arrays.asList(previewSurface, reader.getSurface()),
                    new CameraCaptureSession.StateCallback() {
                        @Override public void onConfigured(CameraCaptureSession s) {
                            session = s;
                            try {
                                previewBuilder = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);
                                previewBuilder.addTarget(previewSurface);
                                previewBuilder.set(CaptureRequest.CONTROL_AF_MODE,
                                        CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE);
                                applyFlash(previewBuilder);
                                s.setRepeatingRequest(previewBuilder.build(), null, camHandler);
                            } catch (Exception e) {
                                // 某些 LEGACY 设备不支持连续对焦，退回自动对焦再试一次
                                try {
                                    previewBuilder.set(CaptureRequest.CONTROL_AF_MODE,
                                            CaptureRequest.CONTROL_AF_MODE_AUTO);
                                    applyFlash(previewBuilder);
                                    s.setRepeatingRequest(previewBuilder.build(), null, camHandler);
                                } catch (Exception ignored) {}
                            }
                        }
                        @Override public void onConfigureFailed(CameraCaptureSession s) {
                            fail(REASON_BUSY);
                        }
                    }, camHandler);
        } catch (Exception e) {
            fail(REASON_BUSY);
        }
    }

    private void applyFlash(CaptureRequest.Builder b) {
        try {
            if (flashOn && flashAvailable) {
                b.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON);
                b.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_TORCH);
            } else if (autoFlashAvailable) {
                b.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON_AUTO_FLASH);
                b.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_OFF);
            } else {
                b.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON);
                b.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_OFF);
            }
        } catch (Exception ignored) {}
    }

    private void toggleFlash() {
        if (!flashAvailable) return;
        flashOn = !flashOn;
        flashBtn.setText(flashOn ? "补光 开" : "补光 关");
        try {
            if (session != null && previewBuilder != null) {
                applyFlash(previewBuilder);
                session.stopRepeating();
                session.setRepeatingRequest(previewBuilder.build(), null, camHandler);
            }
        } catch (Exception ignored) {}
    }

    // MARK: 拍照

    private void takePicture() {
        if (camera == null || session == null || reader == null || taking) {
            if (camera == null) toast("相机还没准备好，稍等一下再拍");
            return;
        }
        taking = true;
        shutter.setEnabled(false);
        tip.setVisibility(View.INVISIBLE);
        try {
            CaptureRequest.Builder b = camera.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE);
            b.addTarget(reader.getSurface());
            b.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE);
            applyFlash(b);
            // 方向交给设备：JPEG_ORIENTATION 会写成 EXIF 或由 HAL 物理转正，
            // 再由 Capture.normalize 统一归正，不再自己猜角度、也就不会二次旋转
            b.set(CaptureRequest.JPEG_ORIENTATION, jpegOrientation());
            session.stopRepeating();
            session.capture(b.build(), new CameraCaptureSession.CaptureCallback() {
                @Override public void onCaptureCompleted(CameraCaptureSession s, CaptureRequest r,
                                                        android.hardware.camera2.TotalCaptureResult result) {
                    restartPreview();
                }
                @Override public void onCaptureFailed(CameraCaptureSession s, CaptureRequest r,
                                                     android.hardware.camera2.CaptureFailure failure) {
                    restartPreview();
                    runOnUiThread(() -> {
                        taking = false;
                        shutter.setEnabled(true);
                        toast("这一张没拍成，请再按一次快门");
                    });
                }
            }, camHandler);
        } catch (Exception e) {
            taking = false;
            shutter.setEnabled(true);
            restartPreview();
            toast("拍照失败，请重试");
        }
    }

    private void restartPreview() {
        try {
            if (session != null && previewBuilder != null && !failed)
                session.setRepeatingRequest(previewBuilder.build(), null, camHandler);
        } catch (Exception ignored) {}
    }

    private void onImage(ImageReader r) {
        Image img = null;
        try {
            img = r.acquireLatestImage();
            if (img == null) return;
            ByteBuffer buf = img.getPlanes()[0].getBuffer();
            byte[] bytes = new byte[buf.remaining()];
            buf.get(bytes);
            img.close();
            img = null;

            File out = new File(dir, "shot-" + System.currentTimeMillis() + ".jpg");
            final boolean ok = writeJpeg(bytes, out);
            final String path = out.getAbsolutePath();
            if (!ok) out.delete();
            runOnUiThread(() -> {
                taking = false;
                shutter.setEnabled(true);
                if (ok) {
                    shots.add(path);
                    updateCount();
                } else {
                    toast("照片保存失败，请再拍一张");
                }
            });
        } catch (Exception e) {
            runOnUiThread(() -> {
                taking = false;
                shutter.setEnabled(true);
                toast("照片读取失败，请再拍一张");
            });
        } finally {
            if (img != null) img.close();
        }
    }

    /**
     * 原样落盘相机输出的 JPEG，保留设备写好的 EXIF 方向。
     * 方向归正、EXIF 读取、限长边都由下游 Capture.normalize 一次做完，
     * 这里不解码、不旋转、不重压缩，也就不会再出现方向被转两次的问题。
     */
    private static boolean writeJpeg(byte[] bytes, File out) {
        try (FileOutputStream fos = new FileOutputStream(out)) {
            fos.write(bytes);
            fos.flush();
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    private void updateCount() {
        counter.setText("已拍 " + shots.size() + " 页");
        done.setText(shots.isEmpty() ? "完成" : "完成 (" + shots.size() + ")");
    }

    // MARK: 结果 / 降级

    private void finishWithShots() {
        if (shots.isEmpty()) { toast("先拍一页，或从相册选照片"); return; }
        Intent i = new Intent();
        i.putStringArrayListExtra(EXTRA_PATHS, new ArrayList<>(shots));
        setResult(RESULT_OK, i);
        finish();
    }

    private void pickImages() {
        Intent i = new Intent(Intent.ACTION_GET_CONTENT);
        i.addCategory(Intent.CATEGORY_OPENABLE);
        i.setType("image/*");
        i.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        try { startActivityForResult(i, 21); }
        catch (Exception e) { toast("找不到相册"); }
    }

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request != 21 || result != RESULT_OK || data == null) return;
        // 相机页里直接选相册：把选中的图片也当拍摄页返回，统一进检查页
        ArrayList<android.net.Uri> uris = new ArrayList<>();
        android.content.ClipData clip = data.getClipData();
        if (clip != null) {
            for (int i = 0; i < clip.getItemCount(); i++) {
                android.net.Uri u = clip.getItemAt(i).getUri();
                if (u != null) uris.add(u);
            }
        } else if (data.getData() != null) uris.add(data.getData());
        int n = 0;
        for (android.net.Uri u : uris) {
            File dst = new File(dir, "gallery-" + System.currentTimeMillis() + "-" + n + ".jpg");
            n++;
            try (java.io.InputStream in = getContentResolver().openInputStream(u);
                 java.io.OutputStream out = new java.io.FileOutputStream(dst)) {
                if (in == null) continue;
                byte[] buf = new byte[64 * 1024];
                int len;
                while ((len = in.read(buf)) > 0) out.write(buf, 0, len);
                shots.add(dst.getAbsolutePath());
            } catch (Exception e) { dst.delete(); }
        }
        updateCount();
        if (!shots.isEmpty()) {
            toast("已从相册加入 " + shots.size() + " 页，可继续拍或直接完成");
        }
    }

    private void cancelShots() {
        for (String p : shots) new File(p).delete();
        shots.clear();
        updateCount();
    }

    private void cancel() {
        cancelShots();
        setResult(RESULT_CANCELED);
        finish();
    }

    private void fail(final String reason) {
        if (failed) return;
        failed = true;
        // 相机回调在 HandlerThread 上，结果回传与 finish 必须放回主线程
        runOnUiThread(() -> {
            Intent i = new Intent();
            i.putExtra(EXTRA_REASON, reason);
            i.putStringArrayListExtra(EXTRA_PATHS, new ArrayList<>(shots));
            setResult(RESULT_CANCELED, i);
            finish();
        });
    }

    /** 切到系统相机：已拍的页先回传，别让用户白拍。 */
    private void useSystemCamera() {
        if (failed) return;
        failed = true;
        Intent i = new Intent();
        i.putExtra(EXTRA_REASON, REASON_SYSTEM_CAMERA);
        i.putStringArrayListExtra(EXTRA_PATHS, new ArrayList<>(shots));
        setResult(RESULT_CANCELED, i);
        finish();
    }

    @Override public void onBackPressed() { cancel(); }

    private void closeCamera() {
        try {
            if (session != null) { session.close(); session = null; }
            if (camera != null) { camera.close(); camera = null; }
            if (reader != null) { reader.close(); reader = null; }
        } catch (Exception ignored) {}
        previewBuilder = null;
    }

    private void toast(String s) { Toast.makeText(this, s, Toast.LENGTH_SHORT).show(); }
}
