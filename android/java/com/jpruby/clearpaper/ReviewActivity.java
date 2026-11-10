package com.jpruby.clearpaper;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Color;
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
    private static final int REQ_CAMERA = 11;

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

    private void startCamera() {
        pendingCamera = new File(dir, "camera-" + System.currentTimeMillis() + ".jpg");
        Intent i = new Intent(MediaStore.ACTION_IMAGE_CAPTURE);
        android.net.Uri u = ShareProvider.uriFor(pendingCamera);
        i.putExtra(MediaStore.EXTRA_OUTPUT, u);
        i.setClipData(ClipData.newUri(getContentResolver(), "capture", u));
        i.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION | Intent.FLAG_GRANT_READ_URI_PERMISSION);
        try { startActivityForResult(i, REQ_CAMERA); }
        catch (Exception e) {
            pendingCamera = null;
            new AlertDialog.Builder(this).setTitle("当前设备没有可用的相机")
                    .setMessage("可以返回「处理」页用「从相册选」导入已有照片，一样会走完整清理流程。")
                    .setPositiveButton("好", null).show();
        }
    }

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request != REQ_CAMERA) return;
        if (result != RESULT_OK || pendingCamera == null || !pendingCamera.exists()
                || pendingCamera.length() < 1024) {
            if (pendingCamera != null) pendingCamera.delete();
            return;
        }
        File raw = pendingCamera;
        pendingCamera = null;
        int n = 0;
        File dst;
        do { dst = new File(dir, String.format(Locale.US, "page-%03d.jpg", n++)); }
        while (dst.exists());
        if (!Capture.normalize(raw, dst)) {
            Toast.makeText(ReviewActivity.this, "照片读取失败", Toast.LENGTH_SHORT).show();
            raw.delete();
            return;
        }
        raw.delete();
        recomputeSignatures();
        addPage(dst, true);
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
