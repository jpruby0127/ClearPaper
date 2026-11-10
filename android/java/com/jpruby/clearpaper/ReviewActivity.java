package com.jpruby.clearpaper;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.provider.MediaStore;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.AbsListView;
import android.widget.BaseAdapter;
import android.widget.FrameLayout;
import android.widget.GridView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;

/**
 * 检查拍摄页：逐页缩略图、大图、删除、旋转、调序、重复页自动剔除与恢复。
 * 对应 iOS 的 ScanReviewView。原图逐页落盘，网格只持有缩略图。
 */
public final class ReviewActivity extends Activity {
    private static final int REQ_CAMERA = 11;        // App 内置相机
    private static final int REQ_SYSTEM_CAMERA = 12; // 兜底：系统相机 App
    private static final int REQ_IMAGES = 13;       // 无相机设备 / 用户主动选相册

    private final class Page {
        final File file;
        int rotation;
        boolean needsFix;
        Bitmap thumb;
        Page(File file) { this.file = file; }
    }

    private File dir;
    private boolean fromCamera;
    private final List<Page> pages = new ArrayList<>();
    private final List<Page> dropped = new ArrayList<>();
    private final List<Capture.Signature> signatures = new ArrayList<>();
    private GridAdapter adapter;
    private LinearLayout footer;
    private TextView summary;
    private boolean keepDir;
    private File pendingCamera;

    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        App.ctx = getApplicationContext();
        Ui.setAppearance(ReviewActivity.this, getSharedPreferences("clearpaper", Context.MODE_PRIVATE)
                .getInt("cp.appearance", 0));
        String path = getIntent().getStringExtra("dir");
        dir = new File(path != null ? path
                : new File(getFilesDir(), "ClearPaper/Review/" + java.util.UUID.randomUUID()).getPath());
        dir.mkdirs();
        fromCamera = getIntent().getBooleanExtra("fromCamera", true);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setFitsSystemWindows(true);
        root.setBackgroundColor(Ui.canvas());

        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setBackgroundColor(Ui.panel());
        bar.setPadding(Ui.dp(ReviewActivity.this, 16), Ui.dp(ReviewActivity.this, 12), Ui.dp(ReviewActivity.this, 16), Ui.dp(ReviewActivity.this, 12));
        TextView cancel = Ui.text(ReviewActivity.this, "取消", 14, Ui.blue(), false);
        cancel.setOnClickListener(v -> cancel());
        bar.addView(cancel);
        TextView title = Ui.text(ReviewActivity.this, "检查拍摄页", 15, Ui.ink(), true);
        title.setGravity(Gravity.CENTER);
        bar.addView(title, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        TextView add = Ui.text(ReviewActivity.this, "继续拍", 14, Ui.amber(), true);
        add.setOnClickListener(v -> startCamera());
        bar.addView(add);
        root.addView(bar, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));
        View line = new View(this);
        line.setBackgroundColor(Ui.line());
        root.addView(line, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 1));

        LinearLayout head = new LinearLayout(this);
        head.setOrientation(LinearLayout.VERTICAL);
        head.setBackgroundColor(Ui.panel());
        head.setPadding(Ui.dp(ReviewActivity.this, 16), Ui.dp(ReviewActivity.this, 11), Ui.dp(ReviewActivity.this, 16), Ui.dp(ReviewActivity.this, 11));
        summary = Ui.text(ReviewActivity.this, "", 14, Ui.ink(), true);
        head.addView(summary);
        head.addView(Ui.text(ReviewActivity.this, "重复页按页面指纹自动剔除，也能一键恢复。点缩略图看大图，可逐页删除、旋转或调整顺序。",
                10, Ui.sub(), false));
        root.addView(head, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));

        GridView grid = new GridView(this);
        grid.setNumColumns(2);
        grid.setVerticalSpacing(Ui.dp(ReviewActivity.this, 12));
        grid.setHorizontalSpacing(Ui.dp(ReviewActivity.this, 12));
        grid.setPadding(Ui.dp(ReviewActivity.this, 16), Ui.dp(ReviewActivity.this, 12), Ui.dp(ReviewActivity.this, 16), Ui.dp(ReviewActivity.this, 12));
        grid.setClipToPadding(false);
        grid.setBackgroundColor(Ui.canvas());
        grid.setVerticalScrollBarEnabled(false);
        adapter = new GridAdapter();
        grid.setAdapter(adapter);
        root.addView(grid, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));

        footer = new LinearLayout(this);
        footer.setOrientation(LinearLayout.VERTICAL);
        footer.setBackgroundColor(Ui.panel());
        footer.setPadding(Ui.dp(ReviewActivity.this, 16), Ui.dp(ReviewActivity.this, 12), Ui.dp(ReviewActivity.this, 16), Ui.dp(ReviewActivity.this, 22));
        root.addView(footer, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));
        setContentView(root);

        if (!fromCamera) loadExisting();
        updateFooter();
        if (getIntent().getBooleanExtra("capture", false)) startCamera();
    }

    private void loadExisting() {
        File[] fs = dir.listFiles((d, n) -> n.startsWith("page-") && n.endsWith(".jpg"));
        if (fs == null) return;
        Arrays.sort(fs, Comparator.comparing(File::getName));
        for (File f : fs) addPage(f, true);
    }

    private void recomputeSignatures() {
        signatures.clear();
        for (Page p : pages) {
            Bitmap bm = Capture.decode(p.file);
            if (bm == null) continue;
            signatures.add(Capture.signature(bm));
            bm.recycle();
        }
    }

    private void addPage(File file, boolean dedup) {
        Bitmap bm = Capture.decode(file);
        if (bm == null) return;
        Capture.Signature sig = Capture.signature(bm);
        Page p = new Page(file);
        p.needsFix = fromCamera && Capture.needsRectify(bm);
        p.thumb = makeThumb(bm, 0);
        bm.recycle();
        if (dedup && Capture.isDuplicate(sig, signatures)) dropped.add(p);
        else { pages.add(p); signatures.add(sig); }
        updateFooter();
        if (adapter != null) adapter.notifyDataSetChanged();
    }

    private Bitmap makeThumb(Bitmap src, int rotation) {
        Bitmap rotated = Capture.rotated(src, rotation);
        int w = 300, h = Math.max(1, rotated.getHeight() * w / rotated.getWidth());
        Bitmap out = Bitmap.createScaledBitmap(rotated, w, h, true);
        if (out != rotated) rotated.recycle();
        return out;
    }

    private void updateFooter() {
        if (footer == null) return;
        footer.removeAllViews();
        summary.setText("共 " + pages.size() + " 页 · " + (dropped.isEmpty()
                ? "未发现重复页" : "已自动跳过 " + dropped.size() + " 张重复页"));
        if (!dropped.isEmpty()) {
            TextView restore = Ui.text(ReviewActivity.this, "恢复 " + dropped.size() + " 张被跳过的页", 13, Ui.blue(), true);
            restore.setGravity(Gravity.CENTER);
            restore.setPadding(0, Ui.dp(ReviewActivity.this, 4), 0, Ui.dp(ReviewActivity.this, 8));
            restore.setOnClickListener(v -> {
                pages.addAll(dropped);
                dropped.clear();
                recomputeSignatures();
                adapter.notifyDataSetChanged();
                updateFooter();
            });
            footer.addView(restore);
        }
        int fix = 0;
        for (Page p : pages) if (p.needsFix) fix++;
        if (fix > 0) {
            TextView note = Ui.text(ReviewActivity.this, fix + " 页检测到桌面背景，确认后会补一次找边矫正", 10, Ui.sub(), false);
            note.setGravity(Gravity.CENTER);
            footer.addView(note);
        }
        TextView confirm = Ui.primaryButton(ReviewActivity.this, "确认处理 " + pages.size() + " 页",
                pages.isEmpty(), () -> confirm());
        LinearLayout.LayoutParams cp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        cp.topMargin = Ui.dp(ReviewActivity.this, 10);
        footer.addView(confirm, cp);
        TextView again = Ui.text(ReviewActivity.this, "继续拍一页", 12, Ui.amber(), true);
        again.setGravity(Gravity.CENTER);
        again.setPadding(0, Ui.dp(ReviewActivity.this, 10), 0, 0);
        again.setOnClickListener(v -> startCamera());
        footer.addView(again);
    }

    private final class GridAdapter extends BaseAdapter {
        @Override public int getCount() { return pages.size(); }
        @Override public Object getItem(int position) { return pages.get(position); }
        @Override public long getItemId(int position) { return position; }

        @Override public View getView(int position, View convert, ViewGroup parent) {
            final Page p = pages.get(position);
            LinearLayout card = Ui.card(ReviewActivity.this, 9);
            FrameLayout holder = new FrameLayout(ReviewActivity.this);
            ImageView iv = new ImageView(ReviewActivity.this);
            iv.setScaleType(ImageView.ScaleType.CENTER_CROP);
            if (p.thumb != null) iv.setImageBitmap(p.thumb);
            holder.addView(iv, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                    Ui.dp(ReviewActivity.this, 158)));
            LinearLayout badges = new LinearLayout(ReviewActivity.this);
            badges.setOrientation(LinearLayout.HORIZONTAL);
            badges.setPadding(Ui.dp(ReviewActivity.this, 7), Ui.dp(ReviewActivity.this, 7), 0, 0);
            badges.addView(Ui.chip(ReviewActivity.this, String.valueOf(position + 1), 0xFFFFFFFF,
                    Color.argb(190, 27, 27, 30)));
            if (p.needsFix) {
                TextView fix = Ui.chip(ReviewActivity.this, "补裁边", Ui.ink(), Ui.amberSoft());
                LinearLayout.LayoutParams fp = new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
                fp.leftMargin = Ui.dp(ReviewActivity.this, 5);
                badges.addView(fix, fp);
            }
            holder.addView(badges);
            holder.setOnClickListener(v -> showBig(p));
            card.addView(holder, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                    Ui.dp(ReviewActivity.this, 158)));

            LinearLayout tools = Ui.hbox(ReviewActivity.this);
            tools.addView(tool("←", Ui.sub(), () -> { move(p, -1); }),
                    new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
            tools.addView(tool("⟳", Ui.sub(), () -> {
                p.rotation = (p.rotation + 90) % 360;
                Bitmap bm = Capture.decode(p.file);
                if (bm != null) {
                    if (p.thumb != null) p.thumb.recycle();
                    p.thumb = makeThumb(bm, p.rotation);
                    bm.recycle();
                }
                adapter.notifyDataSetChanged();
            }), new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
            tools.addView(tool("✕", Ui.red(), () -> {
                pages.remove(p);
                recomputeSignatures();
                adapter.notifyDataSetChanged();
                updateFooter();
            }), new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
            tools.addView(tool("→", Ui.sub(), () -> { move(p, 1); }),
                    new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
            LinearLayout.LayoutParams tp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            tp.topMargin = Ui.dp(ReviewActivity.this, 7);
            card.addView(tools, tp);
            return card;
        }

        private TextView tool(String glyph, int tint, Runnable action) {
            TextView t = Ui.text(ReviewActivity.this, glyph, 13, tint, true);
            t.setGravity(Gravity.CENTER);
            t.setBackground(Ui.rounded(Ui.canvas(), 8, 0, 0));
            t.setPadding(0, Ui.dp(ReviewActivity.this, 7), 0, Ui.dp(ReviewActivity.this, 7));
            t.setOnClickListener(v -> action.run());
            return t;
        }
    }

    private void move(Page p, int delta) {
        int i = pages.indexOf(p), j = i + delta;
        if (i < 0 || j < 0 || j >= pages.size()) return;
        java.util.Collections.swap(pages, i, j);
        adapter.notifyDataSetChanged();
    }

    private void showBig(Page p) {
        Bitmap bm = Capture.decode(p.file);
        if (bm == null) return;
        Bitmap shown = Capture.rotated(bm, p.rotation);
        if (shown != bm) bm.recycle();
        ImageView iv = new ImageView(this);
        iv.setImageBitmap(shown);
        iv.setBackgroundColor(0xFF000000);
        iv.setScaleType(ImageView.ScaleType.FIT_CENTER);
        final android.app.Dialog d = new android.app.Dialog(this,
                android.R.style.Theme_Black_NoTitleBar_Fullscreen);
        iv.setLayoutParams(new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT));
        d.setContentView(iv);
        iv.setOnClickListener(v -> d.dismiss());
        d.setOnDismissListener(x -> shown.recycle());
        d.show();
    }

    /** 优先用 App 内置相机：不需要外部相机 App，也就不会踩 Android 11+ 包可见性的坑。 */
    private void startCamera() {
        if (!CameraActivity.hasCamera(ReviewActivity.this)) { showNoCamera(); return; }
        Intent i = new Intent(ReviewActivity.this, CameraActivity.class);
        i.putExtra(CameraActivity.EXTRA_DIR, dir.getAbsolutePath());
        startActivityForResult(i, REQ_CAMERA);
    }

    private void showNoCamera() {
        new AlertDialog.Builder(ReviewActivity.this)
                .setTitle("这台设备没有可用的相机")
                .setMessage("可以直接从相册选已有的试卷照片，一样会做找边矫正并走完整清理流程，功能不打折。")
                .setPositiveButton("从相册选", (d, w) -> pickImages())
                .setNegativeButton("取消", null).show();
    }

    /** 内置相机失败时给出准确原因，而不是笼统一句「没有可用的相机」。 */
    private void showCameraProblem(String reason) {
        boolean noCamera = CameraActivity.REASON_NO_CAMERA.equals(reason);
        boolean denied = CameraActivity.REASON_DENIED.equals(reason);
        String title = noCamera ? "这台设备没有可用的相机"
                : denied ? "相机权限被拒绝" : "相机暂时打不开";
        String body = noCamera
                ? "没有检测到相机硬件。可以直接从相册选已有的试卷照片，一样会做找边矫正并走完整清理流程。"
                : denied
                ? "在系统「设置 → 应用 → ClearPaper → 权限」里允许相机后即可拍摄；也可以先用相册里的照片，功能完全一样。"
                : "相机可能被其他应用占用，或这台设备的相机驱动不兼容。可以稍后重试、改用系统相机拍，或直接从相册选已有照片。";
        AlertDialog.Builder b = new AlertDialog.Builder(ReviewActivity.this)
                .setTitle(title).setMessage(body)
                .setPositiveButton("从相册选", (d, w) -> pickImages())
                .setNegativeButton("稍后再说", null);
        if (!noCamera && !denied) b.setNeutralButton("用系统相机", (d, w) -> startSystemCamera());
        b.show();
    }

    /** 最后一道兜底：Manifest 里已补 queries，且显式把 URI 权限授予解析到的相机 App。 */
    private void startSystemCamera() {
        pendingCamera = new File(dir, "camera-" + System.currentTimeMillis() + ".jpg");
        Intent i = new Intent(MediaStore.ACTION_IMAGE_CAPTURE);
        Uri u = ShareProvider.uriFor(pendingCamera);
        i.putExtra(MediaStore.EXTRA_OUTPUT, u);
        i.setClipData(ClipData.newUri(getContentResolver(), "capture", u));
        i.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION | Intent.FLAG_GRANT_READ_URI_PERMISSION);
        try {
            java.util.List<ResolveInfo> targets = getPackageManager()
                    .queryIntentActivities(i, PackageManager.MATCH_DEFAULT_ONLY);
            for (ResolveInfo r : targets) {
                grantUriPermission(r.activityInfo.packageName, u,
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION | Intent.FLAG_GRANT_READ_URI_PERMISSION);
            }
            if (targets.isEmpty()) throw new IllegalStateException("no camera app");
            startActivityForResult(i, REQ_SYSTEM_CAMERA);
        } catch (Exception e) {
            pendingCamera.delete();
            pendingCamera = null;
            showNoCamera();
        }
    }

    private void pickImages() {
        Intent i = new Intent(Intent.ACTION_GET_CONTENT);
        i.addCategory(Intent.CATEGORY_OPENABLE);
        i.setType("image/*");
        i.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        try { startActivityForResult(i, REQ_IMAGES); }
        catch (Exception e) { Toast.makeText(this, "找不到相册", Toast.LENGTH_SHORT).show(); }
    }

    private File nextPageFile() {
        int n = 0;
        File dst;
        do { dst = new File(dir, String.format(Locale.US, "page-%03d.jpg", n++)); }
        while (dst.exists());
        return dst;
    }

    /** 原始拍摄帧 → 方向归一 + 限长边 → 检查页的一页；原帧用完即删。 */
    private void importShot(File raw) {
        if (raw == null || !raw.exists() || raw.length() < 1024) { if (raw != null) raw.delete(); return; }
        File dst = nextPageFile();
        if (!Capture.normalize(raw, dst)) {
            Toast.makeText(this, "照片读取失败", Toast.LENGTH_SHORT).show();
            raw.delete();
            return;
        }
        if (!raw.equals(dst)) raw.delete();
        addPage(dst, true);
    }

    private boolean copyUri(Uri u, File dst) {
        try (InputStream in = getContentResolver().openInputStream(u);
             OutputStream out = new FileOutputStream(dst)) {
            if (in == null) return false;
            byte[] buf = new byte[64 * 1024];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            return true;
        } catch (Exception e) { return false; }
    }

    private List<Uri> uris(Intent data) {
        List<Uri> out = new ArrayList<>();
        if (data == null) return out;
        ClipData clip = data.getClipData();
        if (clip != null) {
            for (int i = 0; i < clip.getItemCount(); i++) {
                Uri u = clip.getItemAt(i).getUri();
                if (u != null) out.add(u);
            }
        } else if (data.getData() != null) out.add(data.getData());
        return out;
    }

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request == REQ_CAMERA) {
            if (result == RESULT_OK && data != null) {
                ArrayList<String> paths = data.getStringArrayListExtra(CameraActivity.EXTRA_PATHS);
                if (paths != null && !paths.isEmpty()) {
                    recomputeSignatures();
                    for (String p : paths) importShot(new File(p));
                    return;
                }
            } else if (data != null) {
                String reason = data.getStringExtra(CameraActivity.EXTRA_REASON);
                if (reason != null) { showCameraProblem(reason); return; }
            }
        } else if (request == REQ_SYSTEM_CAMERA) {
            if (result == RESULT_OK && pendingCamera != null && pendingCamera.exists()
                    && pendingCamera.length() >= 1024) {
                File raw = pendingCamera;
                pendingCamera = null;
                recomputeSignatures();
                importShot(raw);
            } else if (pendingCamera != null) {
                pendingCamera.delete();
                pendingCamera = null;
            }
        } else if (request == REQ_IMAGES) {
            if (result != RESULT_OK) return;
            List<Uri> picked = uris(data);
            if (picked.isEmpty()) return;
            recomputeSignatures();
            int n = 0;
            for (Uri u : picked) {
                File raw = new File(dir, "pick-" + System.currentTimeMillis() + "-" + n++ + ".jpg");
                if (!copyUri(u, raw)) { raw.delete(); continue; }
                importShot(raw);
            }
            if (pages.isEmpty()) Toast.makeText(this, "图片读取失败", Toast.LENGTH_SHORT).show();
        }
    }

    private void confirm() {
        if (pages.isEmpty()) return;
        try (Writer w = new OutputStreamWriter(new FileOutputStream(new File(dir, "manifest.txt")),
                StandardCharsets.UTF_8)) {
            for (Page p : pages) {
                w.write(p.file.getName() + "|" + p.rotation + "|" + (p.needsFix ? 1 : 0) + "\n");
            }
        } catch (Exception e) {
            Toast.makeText(ReviewActivity.this, "无法保存拍摄页", Toast.LENGTH_SHORT).show();
            return;
        }
        Intent i = new Intent();
        i.putExtra("dir", dir.getAbsolutePath());
        i.putExtra("fromCamera", fromCamera);
        i.putExtra("dropped", dropped.size());
        keepDir = true;
        setResult(RESULT_OK, i);
        finish();
    }

    private void cancel() {
        setResult(RESULT_CANCELED);
        finish();
    }

    @Override public void onBackPressed() { cancel(); }

    @Override protected void onDestroy() {
        super.onDestroy();
        if (!keepDir) {
            File[] fs = dir.listFiles();
            if (fs != null) for (File f : fs) f.delete();
            dir.delete();
        }
    }
}
