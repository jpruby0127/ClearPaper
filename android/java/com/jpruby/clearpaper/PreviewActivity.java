package com.jpruby.clearpaper;

import android.app.Activity;
import android.graphics.Bitmap;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.File;
import java.util.List;

/** PDF 预览：用系统 PdfRenderer 逐页渲染，保留与 iOS PDFView 一致的浏览体验。 */
public final class PreviewActivity extends Activity {
    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        App.ctx = getApplicationContext();
        Ui.setAppearance(this, new StorePrefs(this).appearance());
        final File file = new File(getIntent().getStringExtra("path"));

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setFitsSystemWindows(true);
        root.setBackgroundColor(Ui.canvas());

        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setBackgroundColor(Ui.panel());
        bar.setPadding(Ui.dp(this, 16), Ui.dp(this, 12), Ui.dp(this, 16), Ui.dp(this, 12));
        TextView name = Ui.text(this, file.getName(), 14, Ui.ink(), true);
        name.setSingleLine(true);
        bar.addView(name, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        TextView done = Ui.text(this, "完成", 14, Ui.amber(), true);
        done.setOnClickListener(v -> finish());
        bar.addView(done);
        root.addView(bar, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));
        View line = new View(this);
        line.setBackgroundColor(Ui.line());
        root.addView(line, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 1));

        final LinearLayout pages = new LinearLayout(this);
        pages.setOrientation(LinearLayout.VERTICAL);
        pages.setPadding(Ui.dp(this, 16), Ui.dp(this, 16), Ui.dp(this, 16), Ui.dp(this, 32));
        ScrollView sv = new ScrollView(this);
        sv.setBackgroundColor(Ui.canvas());
        sv.addView(pages, new ScrollView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));
        root.addView(sv, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        setContentView(root);

        int width = Math.min(720, getResources().getDisplayMetrics().widthPixels - Ui.dp(this, 32));
        final int w = Math.max(320, width);
        new Thread(() -> {
            List<Bitmap> bms = ScanEngine.previewPages(file, w, 6);
            int count = ScanEngine.pageCount(file);
            final boolean more = count > bms.size();
            runOnUiThread(() -> {
                if (isFinishing()) return;
                if (bms.isEmpty()) {
                    TextView t = Ui.text(this, "无法预览这个 PDF", 14, Ui.sub(), false);
                    t.setGravity(Gravity.CENTER);
                    pages.addView(t);
                    return;
                }
                for (int i = 0; i < bms.size(); i++) {
                    ImageView iv = new ImageView(this);
                    iv.setImageBitmap(bms.get(i));
                    iv.setBackgroundColor(0xFFFFFFFF);
                    iv.setAdjustViewBounds(true);
                    LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
                    p.bottomMargin = Ui.dp(this, 14);
                    pages.addView(iv, p);
                }
                if (more) {
                    TextView t = Ui.text(this, "仅预览前 " + bms.size() + " 页 · 共 " + count
                            + " 页（分享或存文件可查看完整 PDF）", 11, Ui.mute(), false);
                    t.setGravity(Gravity.CENTER);
                    pages.addView(t);
                }
            });
        }).start();
    }

    /** 只读取外观偏好，不创建数据仓库。 */
    private static final class StorePrefs {
        private final android.content.SharedPreferences p;
        StorePrefs(Activity a) { p = a.getSharedPreferences("clearpaper", android.content.Context.MODE_PRIVATE); }
        int appearance() { return p.getInt("cp.appearance", 0); }
    }
}
