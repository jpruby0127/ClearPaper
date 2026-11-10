package com.jpruby.clearpaper;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.io.File;
import java.nio.charset.StandardCharsets;

/** OCR 文字稿查看：复制 / 分享 / 返回，对应 iOS 的 TextViewSheet。 */
public final class TextActivity extends Activity {
    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        App.ctx = getApplicationContext();
        Ui.setAppearance(this, getSharedPreferences("clearpaper", Context.MODE_PRIVATE)
                .getInt("cp.appearance", 0));
        final File file = new File(getIntent().getStringExtra("path"));
        String content = "无法读取文字稿";
        try {
            byte[] b = java.nio.file.Files.readAllBytes(file.toPath());
            content = new String(b, StandardCharsets.UTF_8);
        } catch (Exception ignored) {}
        final String text = content;

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
        TextView copy = Ui.text(this, "复制", 13, Ui.blue(), true);
        copy.setPadding(Ui.dp(this, 12), 0, Ui.dp(this, 12), 0);
        copy.setOnClickListener(v -> {
            ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
            if (cm != null) cm.setPrimaryClip(ClipData.newPlainText("文字稿", text));
            Toast.makeText(this, "已复制", Toast.LENGTH_SHORT).show();
        });
        bar.addView(copy);
        TextView share = Ui.text(this, "分享", 13, Ui.blue(), true);
        share.setPadding(Ui.dp(this, 8), 0, Ui.dp(this, 8), 0);
        share.setOnClickListener(v -> {
            Uri u = ShareProvider.uriFor(file);
            Intent i = new Intent(Intent.ACTION_SEND);
            i.setType("text/plain");
            i.putExtra(Intent.EXTRA_STREAM, u);
            i.setClipData(ClipData.newUri(getContentResolver(), "file", u));
            i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            startActivity(Intent.createChooser(i, "分享"));
        });
        bar.addView(share);
        TextView done = Ui.text(this, "完成", 14, Ui.amber(), true);
        done.setPadding(Ui.dp(this, 8), 0, 0, 0);
        done.setOnClickListener(v -> finish());
        bar.addView(done);
        root.addView(bar, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));
        View line = new View(this);
        line.setBackgroundColor(Ui.line());
        root.addView(line, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 1));

        TextView body = Ui.text(this, text, 13, Ui.ink(), false);
        body.setTextIsSelectable(true);
        body.setPadding(Ui.dp(this, 16), Ui.dp(this, 16), Ui.dp(this, 16), Ui.dp(this, 32));
        ScrollView sv = new ScrollView(this);
        sv.setBackgroundColor(Ui.canvas());
        sv.addView(body, new ScrollView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));
        root.addView(sv, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        setContentView(root);
    }
}
