package com.jpruby.clearpaper;

import android.app.Activity;
import android.content.ClipData;
import android.content.Intent;
import android.database.Cursor;
import android.graphics.PorterDuff;
import android.net.Uri;
import android.os.Bundle;
import android.os.Looper;
import android.provider.OpenableColumns;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

/** 根容器：四个 Tab（处理 / 合并 / 文件 / 关于）+ 所有系统交互路由。 */
public final class MainActivity extends Activity implements Host {
    private static final int REQ_PICK_PDF = 1, REQ_PICK_IMAGES = 2, REQ_REVIEW = 3, REQ_SAVE_AS = 4;
    private static final int[] ICONS = {R.drawable.tab_process, R.drawable.tab_merge,
            R.drawable.tab_files, R.drawable.tab_about};
    private static final String[] LABELS = {"处理", "合并", "文件", "关于"};

    private Store store;
    private FrameLayout content;
    private View rootView, tabBarView, tabDivider;
    private final ImageView[] iconViews = new ImageView[4];
    private final TextView[] labelViews = new TextView[4];
    private int tab;
    private File pendingSave;
    private boolean didImport;

    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        App.ctx = getApplicationContext();
        store = new Store(this, this);
        Ui.setAppearance(this, store.appearance);
        buildChrome();
        handleExternalIntent(getIntent());
        if (!didImport) { didImport = true; store.importInbox(); }
        store.refreshFiles();
        refresh();
    }

    private void buildChrome() {
        LinearLayout root = new LinearLayout(this);
        rootView = root;
        root.setOrientation(LinearLayout.VERTICAL);
        root.setFitsSystemWindows(true);
        root.setBackgroundColor(Ui.canvas());
        content = new FrameLayout(this);
        content.setBackgroundColor(Ui.canvas());
        root.addView(content, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));

        View line = new View(this);
        tabDivider = line;
        line.setBackgroundColor(Ui.line());
        root.addView(line, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 1));

        LinearLayout bar = new LinearLayout(this);
        tabBarView = bar;
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setBackgroundColor(Ui.panel());
        bar.setPadding(0, Ui.dp(this, 6), 0, Ui.dp(this, 8));
        for (int i = 0; i < 4; i++) {
            final int idx = i;
            LinearLayout item = new LinearLayout(this);
            item.setOrientation(LinearLayout.VERTICAL);
            item.setGravity(Gravity.CENTER_HORIZONTAL);
            ImageView iv = new ImageView(this);
            iv.setImageResource(ICONS[i]);
            iv.setLayoutParams(new LinearLayout.LayoutParams(Ui.dp(this, 23), Ui.dp(this, 23)));
            iconViews[i] = iv;
            item.addView(iv);
            TextView tv = Ui.text(this, LABELS[i], 10, Ui.sub(), true);
            tv.setGravity(Gravity.CENTER);
            tv.setPadding(0, Ui.dp(this, 3), 0, 0);
            labelViews[i] = tv;
            item.addView(tv);
            item.setOnClickListener(v -> { tab = idx; refresh(); });
            item.setPadding(0, Ui.dp(this, 4), 0, 0);
            bar.addView(item, new LinearLayout.LayoutParams(0,
                    ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        }
        root.addView(bar, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        setContentView(root);
    }

    private void rebuild() {
        if (content == null) return;
        content.removeAllViews();
        View v;
        switch (tab) {
            case 1: v = Pages.Merge.build(this, this); break;
            case 2: v = Pages.Files.build(this, this); break;
            case 3: v = Pages.About.build(this, this); break;
            default: v = Pages.Process.build(this, this); break;
        }
        content.addView(v, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        // 外观切换时重建界面，底部栏 / 状态栏也要跟着换色，不能只有内容区变
        rootView.setBackgroundColor(Ui.canvas());
        content.setBackgroundColor(Ui.canvas());
        tabBarView.setBackgroundColor(Ui.panel());
        tabDivider.setBackgroundColor(Ui.line());
        getWindow().setStatusBarColor(Ui.canvas());
        getWindow().setNavigationBarColor(Ui.panel());
        if (android.os.Build.VERSION.SDK_INT >= 23) {
            View decor = getWindow().getDecorView();
            int flags = decor.getSystemUiVisibility();
            if (Ui.isDark()) flags &= ~View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR;
            else flags |= View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR;
            decor.setSystemUiVisibility(flags);
        }
        for (int i = 0; i < 4; i++) {
            int color = i == tab ? Ui.amber() : Ui.sub();
            iconViews[i].setColorFilter(color, PorterDuff.Mode.SRC_IN);
            labelViews[i].setTextColor(color);
        }
    }

    @Override public void refresh() {
        if (Looper.myLooper() == Looper.getMainLooper()) rebuild();
        else runOnUiThread(this::rebuild);
    }

    @Override public Store store() { return store; }
    @Override public void gotoTab(int t) { tab = t; refresh(); }
    @Override public void toast(String message) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show();
    }

    @Override public void pickPdf() {
        Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        i.addCategory(Intent.CATEGORY_OPENABLE);
        i.setType("application/pdf");
        i.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        try { startActivityForResult(i, REQ_PICK_PDF); }
        catch (Exception e) { toast("找不到文件选择器"); }
    }

    @Override public void pickImages() {
        Intent i = new Intent(Intent.ACTION_GET_CONTENT);
        i.addCategory(Intent.CATEGORY_OPENABLE);
        i.setType("image/*");
        i.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        try { startActivityForResult(i, REQ_PICK_IMAGES); }
        catch (Exception e) { toast("找不到相册"); }
    }

    @Override public boolean hasCamera() { return CameraActivity.hasCamera(this); }

    @Override public void startCamera() {
        // 没有相机硬件的设备别让用户白进一个空检查页，直接给完整可用的相册路径
        if (!hasCamera()) {
            toast("这台设备没有可用相机，已为你打开相册");
            pickImages();
            return;
        }
        File dir = new File(new File(getFilesDir(), "ClearPaper/Review"),
                UUID.randomUUID().toString());
        dir.mkdirs();
        Intent i = new Intent(this, ReviewActivity.class);
        i.putExtra("dir", dir.getAbsolutePath());
        i.putExtra("fromCamera", true);
        i.putExtra("capture", true);
        startActivityForResult(i, REQ_REVIEW);
    }

    @Override public void preview(File f) {
        Intent i = new Intent(this, PreviewActivity.class);
        i.putExtra("path", f.getAbsolutePath());
        startActivity(i);
    }

    @Override public void showText(File f) {
        Intent i = new Intent(this, TextActivity.class);
        i.putExtra("path", f.getAbsolutePath());
        startActivity(i);
    }

    @Override public void share(File f) {
        Uri u = ShareProvider.uriFor(f);
        Intent i = new Intent(Intent.ACTION_SEND);
        i.setType(f.getName().toLowerCase().endsWith(".pdf") ? "application/pdf" : "text/plain");
        i.putExtra(Intent.EXTRA_STREAM, u);
        i.setClipData(ClipData.newUri(getContentResolver(), "file", u));
        i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        try { startActivity(Intent.createChooser(i, "分享")); }
        catch (Exception e) { toast("没有可用的分享应用"); }
    }

    @Override public void saveAs(File f) {
        pendingSave = f;
        Intent i = new Intent(Intent.ACTION_CREATE_DOCUMENT);
        i.addCategory(Intent.CATEGORY_OPENABLE);
        i.setType(f.getName().toLowerCase().endsWith(".pdf") ? "application/pdf" : "text/plain");
        i.putExtra(Intent.EXTRA_TITLE, f.getName());
        try { startActivityForResult(i, REQ_SAVE_AS); }
        catch (Exception e) { toast("找不到文件保存器"); }
    }

    @Override public void printPdf(File f) { PrintHelper.print(this, f); }
    @Override public void addToMerge(File f) { store.addToMerge(f); }

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        handleExternalIntent(intent);
    }

    private void handleExternalIntent(Intent intent) {
        if (intent == null) return;
        String action = intent.getAction();
        if (!Intent.ACTION_VIEW.equals(action) && !Intent.ACTION_SEND.equals(action)) return;
        Uri u = Intent.ACTION_SEND.equals(action)
                ? intent.getParcelableExtra(Intent.EXTRA_STREAM) : intent.getData();
        if (u == null) return;
        File f = Store.stage(this, u, displayName(u));
        if (f != null) {
            store.add(Collections.singletonList(f));
            tab = 0;
            toast("已导入 " + f.getName());
        }
    }

    private String displayName(Uri u) {
        try (Cursor c = getContentResolver().query(u, null, null, null, null)) {
            if (c != null && c.moveToFirst()) {
                int i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                if (i >= 0) return c.getString(i);
            }
        } catch (Exception ignored) {}
        return null;
    }

    private static List<Uri> uris(Intent data) {
        List<Uri> out = new ArrayList<>();
        ClipData clip = data.getClipData();
        if (clip != null) {
            for (int i = 0; i < clip.getItemCount(); i++) {
                Uri u = clip.getItemAt(i).getUri();
                if (u != null) out.add(u);
            }
        } else if (data.getData() != null) out.add(data.getData());
        return out;
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

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (result != RESULT_OK || data == null) return;
        if (request == REQ_PICK_PDF) {
            List<File> staged = new ArrayList<>();
            for (Uri u : uris(data)) {
                File f = Store.stage(this, u, displayName(u));
                if (f != null) staged.add(f);
            }
            if (!staged.isEmpty()) { store.add(staged); tab = 0; refresh(); }
        } else if (request == REQ_PICK_IMAGES) {
            List<Uri> picked = uris(data);
            if (picked.isEmpty()) return;
            File dir = new File(new File(getFilesDir(), "ClearPaper/Review"),
                    UUID.randomUUID().toString());
            dir.mkdirs();
            int n = 0;
            for (Uri u : picked) {
                File raw = new File(dir, "raw-" + n + ".jpg");
                if (!copyUri(u, raw)) { raw.delete(); continue; }
                File page = new File(dir, String.format(java.util.Locale.US, "page-%03d.jpg", n));
                if (!Capture.normalize(raw, page)) {
                    if (!copyUri(u, page)) { raw.delete(); continue; }
                }
                raw.delete();
                n++;
            }
            if (n == 0) { toast("图片读取失败"); return; }
            Intent i = new Intent(this, ReviewActivity.class);
            i.putExtra("dir", dir.getAbsolutePath());
            i.putExtra("fromCamera", false);
            startActivityForResult(i, REQ_REVIEW);
        } else if (request == REQ_REVIEW) {
            String path = data.getStringExtra("dir");
            if (path == null) return;
            boolean fromCamera = data.getBooleanExtra("fromCamera", true);
            int dropped = data.getIntExtra("dropped", 0);
            store.addCaptured(new File(path), fromCamera, dropped);
            tab = 0;
            refresh();
        } else if (request == REQ_SAVE_AS && pendingSave != null && data.getData() != null) {
            final File src = pendingSave;
            final Uri dst = data.getData();
            new Thread(() -> {
                boolean ok = false;
                try (InputStream in = new java.io.FileInputStream(src);
                     OutputStream out = getContentResolver().openOutputStream(dst)) {
                    if (out != null) {
                        byte[] buf = new byte[64 * 1024];
                        int r;
                        while ((r = in.read(buf)) > 0) out.write(buf, 0, r);
                        out.flush();
                        ok = true;
                    }
                } catch (Exception ignored) {}
                final boolean done = ok;
                runOnUiThread(() -> toast(done ? "已保存到文件" : "保存失败"));
            }).start();
        }
    }

    @Override protected void onResume() {
        super.onResume();
        if (store != null) store.refreshFiles();
    }

    @Override public void onConfigurationChanged(android.content.res.Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        if (store != null) { Ui.setAppearance(this, store.appearance); refresh(); }
    }
}
