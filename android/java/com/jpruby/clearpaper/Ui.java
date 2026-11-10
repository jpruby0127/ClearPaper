package com.jpruby.clearpaper;

import android.content.Context;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

/** 与 macOS / iOS 端 Pal 一一对应的暖灰设计令牌 + 组件工厂。 */
public final class Ui {
    private Ui() {}
    public static final String VERSION = "1.5.0";
    public static final String BUILD = "10";
    public static final String AUTHOR = "jpruby";
    public static final String REPO = "https://github.com/jpruby0127/ClearPaper";

    private static boolean dark;

    /** 外观：0 跟随系统 / 1 浅色 / 2 深色。切换后由 Activity 重建界面。 */
    public static void setAppearance(Context c, int mode) {
        if (mode == 1) dark = false;
        else if (mode == 2) dark = true;
        else dark = (c.getResources().getConfiguration().uiMode
                & android.content.res.Configuration.UI_MODE_NIGHT_MASK)
                == android.content.res.Configuration.UI_MODE_NIGHT_YES;
    }

    public static boolean isDark() { return dark; }

    public static int dp(Context c, float v) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v,
                c.getResources().getDisplayMetrics()));
    }

    public static int canvas() { return dark ? 0xFF1C1C1E : 0xFFF6F6F7; }
    public static int panel() { return dark ? 0xFF2A2A2D : 0xFFFFFFFF; }
    public static int panel2() { return dark ? 0xFF232326 : 0xFFFAFAFB; }
    public static int ink() { return dark ? 0xFFF2F2F4 : 0xFF1B1B1E; }
    public static int ink2() { return dark ? 0xFFC9C9CE : 0xFF3A3A3F; }
    public static int sub() { return dark ? 0xFF9A9AA0 : 0xFF6C6C72; }
    public static int mute() { return dark ? 0xFF6E6E74 : 0xFF9A9AA0; }
    public static int line() { return dark ? 0xFF3A3A3D : 0xFFE4E4E8; }
    public static int graySoft() { return dark ? 0xFF343437 : 0xFFEDEDF0; }
    public static int amber() { return dark ? 0xFFF0A83C : 0xFFE08A00; }
    public static int amberSoft() { return dark ? 0xFF3A2B12 : 0xFFFFF3DC; }
    public static int green() { return dark ? 0xFF35C79B : 0xFF12A374; }
    public static int greenSoft() { return dark ? 0xFF163024 : 0xFFE6F6F0; }
    public static int blue() { return dark ? 0xFF6B9BFF : 0xFF2F6BFF; }
    public static int blueSoft() { return dark ? 0xFF1E2A44 : 0xFFEAF0FF; }
    public static int red() { return dark ? 0xFFFF6B6F : 0xFFE5484D; }
    public static int redSoft() { return dark ? 0xFF3A2023 : 0xFFFDECEC; }

    private static int alpha(int color, int a) {
        return Color.argb(a, Color.red(color), Color.green(color), Color.blue(color));
    }

    public static GradientDrawable rounded(int fill, float radiusDp, int stroke, float strokePx) {
        Context c = App.ctx;
        GradientDrawable g = new GradientDrawable();
        g.setColor(fill);
        g.setCornerRadius(dp(c, radiusDp));
        if (stroke != 0) g.setStroke(Math.max(1, Math.round(strokePx)), stroke);
        return g;
    }

    public static TextView text(Context c, String s, float sp, int color, boolean bold) {
        TextView t = new TextView(c);
        t.setText(s);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        t.setTextColor(color);
        if (bold) t.setTypeface(android.graphics.Typeface.create("sans-serif-medium", 0));
        t.setLineSpacing(dp(c, 2), 1f);
        return t;
    }

    public static TextView body(Context c, String s) { return text(c, s, 11, sub(), false); }
    public static TextView title(Context c, String s) { return text(c, s, 14, ink(), true); }

    public static LinearLayout vbox(Context c) {
        LinearLayout l = new LinearLayout(c);
        l.setOrientation(LinearLayout.VERTICAL);
        return l;
    }

    public static LinearLayout hbox(Context c) {
        LinearLayout l = new LinearLayout(c);
        l.setOrientation(LinearLayout.HORIZONTAL);
        l.setGravity(Gravity.CENTER_VERTICAL);
        return l;
    }

    public static LinearLayout card(Context c, int padDp) {
        LinearLayout l = vbox(c);
        int p = dp(c, padDp);
        l.setPadding(p, p, p, p);
        l.setBackground(rounded(panel(), 16, line(), dp(c, 0.5f)));
        return l;
    }

    public static View divider(Context c) {
        View v = new View(c);
        v.setBackgroundColor(line());
        return v;
    }

    public static void add(LinearLayout parent, View v, int topDp) {
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        p.topMargin = dp(parent.getContext(), topDp);
        parent.addView(v, p);
    }

    public static void addFill(LinearLayout parent, View v, int weight) {
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, weight);
        parent.addView(v, p);
    }

    public static View spacer(Context c, int dp) {
        View v = new View(c);
        v.setLayoutParams(new LinearLayout.LayoutParams(dp(c, dp), dp(c, dp)));
        return v;
    }

    public static LinearLayout row(Context c, int gapDp) {
        LinearLayout r = hbox(c);
        r.setPadding(0, 0, 0, 0);
        return r;
    }

    public static TextView chip(Context c, String s, int fg, int bg) {
        TextView t = text(c, s, 10, fg, true);
        t.setBackground(rounded(bg, 20, 0, 0));
        t.setPadding(dp(c, 9), dp(c, 4), dp(c, 9), dp(c, 4));
        t.setGravity(Gravity.CENTER);
        return t;
    }

    public static TextView iconBox(Context c, String glyph, int tint, int bg, int sizeDp) {
        TextView t = text(c, glyph, sizeDp * 0.44f, tint, true);
        t.setGravity(Gravity.CENTER);
        t.setBackground(rounded(bg, sizeDp * 0.28f, 0, 0));
        int s = dp(c, sizeDp);
        t.setLayoutParams(new LinearLayout.LayoutParams(s, s));
        return t;
    }

    public static LinearLayout sectionTitle(Context c, String s, String hint) {
        LinearLayout r = hbox(c);
        r.addView(title(c, s), new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        if (hint != null) r.addView(text(c, hint, 11, mute(), false));
        return r;
    }

    public static TextView primaryButton(Context c, String s, boolean disabled, Runnable action) {
        TextView t = text(c, s, 14, disabled ? mute() : canvas(), true);
        t.setGravity(Gravity.CENTER);
        t.setBackground(rounded(disabled ? graySoft() : ink(), 12, 0, 0));
        t.setPadding(dp(c, 12), dp(c, 13), dp(c, 12), dp(c, 13));
        if (!disabled && action != null) t.setOnClickListener(v -> action.run());
        return t;
    }

    /** 动作小方块：淡色底 + 图标 + 文字，对应 SwiftUI 的 ActionTile。 */
    public static FrameLayout tile(Context c, String glyph, String label, int tint, Runnable action) {
        LinearLayout l = vbox(c);
        l.setGravity(Gravity.CENTER_HORIZONTAL);
        TextView icon = text(c, glyph, 15, tint, true);
        icon.setGravity(Gravity.CENTER);
        l.addView(icon);
        TextView cap = text(c, label, 10, tint, true);
        cap.setGravity(Gravity.CENTER);
        cap.setPadding(0, dp(c, 3), 0, 0);
        l.addView(cap);
        l.setPadding(dp(c, 6), dp(c, 9), dp(c, 6), dp(c, 9));
        FrameLayout wrap = new FrameLayout(c);
        wrap.setBackground(rounded(alpha(tint, 28), 10, 0, 0));
        wrap.addView(l, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));
        if (action != null) wrap.setOnClickListener(v -> action.run());
        wrap.setClickable(action != null);
        return wrap;
    }

    public static LinearLayout tileRow(Context c, String[][] items, int[] tints, Runnable[] actions) {
        LinearLayout r = hbox(c);
        for (int i = 0; i < items.length; i++) {
            if (i > 0) r.addView(spacer(c, 8));
            FrameLayout t = tile(c, items[i][0], items[i][1], tints[i], actions[i]);
            r.addView(t, new LinearLayout.LayoutParams(0,
                    ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        }
        return r;
    }

    public static ScrollView scroll(Context c, LinearLayout content) {
        ScrollView s = new ScrollView(c);
        s.setBackgroundColor(canvas());
        s.setFillViewport(true);
        s.setVerticalScrollBarEnabled(false);
        s.addView(content, new ScrollView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));
        return s;
    }

    public static LinearLayout page(Context c) {
        LinearLayout l = vbox(c);
        l.setPadding(dp(c, 16), dp(c, 8), dp(c, 16), dp(c, 96));
        return l;
    }

    public static LinearLayout pageHeader(Context c, String glyph, String title, String subtitle) {
        LinearLayout r = hbox(c);
        r.addView(iconBox(c, glyph, amber(), amberSoft(), 44));
        LinearLayout t = vbox(c);
        t.setPadding(dp(c, 12), 0, 0, 0);
        t.addView(text(c, title, 19, ink(), true));
        t.addView(text(c, subtitle, 12, sub(), false));
        r.addView(t, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        return r;
    }

    public static LinearLayout brandHeader(Context c) {
        LinearLayout r = hbox(c);
        android.widget.ImageView logo = new android.widget.ImageView(c);
        logo.setImageResource(R.drawable.logo);
        logo.setScaleType(android.widget.ImageView.ScaleType.FIT_CENTER);
        GradientDrawable clip = rounded(graySoft(), 11, 0, 0);
        logo.setBackground(clip);
        int s = dp(c, 46);
        r.addView(logo, new LinearLayout.LayoutParams(s, s));
        LinearLayout t = vbox(c);
        t.setPadding(dp(c, 12), 0, 0, 0);
        LinearLayout first = hbox(c);
        first.addView(text(c, "ClearPaper", 16, ink(), true));
        TextView v = chip(c, "v" + VERSION, amber(), amberSoft());
        LinearLayout.LayoutParams vp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        vp.leftMargin = dp(c, 7);
        first.addView(v, vp);
        t.addView(first);
        t.addView(text(c, "by " + AUTHOR + " · 版本 " + VERSION + " (" + BUILD + ")", 11, sub(), false));
        r.addView(t, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        return r;
    }

    public static LinearLayout stepRow(Context c, int n, String t, String body) {
        LinearLayout r = hbox(c);
        r.setGravity(Gravity.TOP);
        TextView num = text(c, String.valueOf(n), 10, amber(), true);
        num.setGravity(Gravity.CENTER);
        num.setBackground(rounded(amberSoft(), 20, 0, 0));
        num.setLayoutParams(new LinearLayout.LayoutParams(dp(c, 22), dp(c, 22)));
        r.addView(num);
        LinearLayout col = vbox(c);
        col.setPadding(dp(c, 10), 0, 0, 0);
        col.addView(text(c, t, 12, ink(), true));
        col.addView(text(c, body, 11, sub(), false));
        r.addView(col, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        return r;
    }

    public static LinearLayout feature(Context c, String glyph, String t, String body, int tint, int bg) {
        LinearLayout r = hbox(c);
        r.setGravity(Gravity.TOP);
        r.addView(iconBox(c, glyph, tint, bg, 30));
        LinearLayout col = vbox(c);
        col.setPadding(dp(c, 10), 0, 0, 0);
        col.addView(text(c, t, 12, ink(), true));
        col.addView(text(c, body, 11, sub(), false));
        r.addView(col, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        return r;
    }

    /** 三段选择器，与 SwiftUI 的 Picker(.segmented) 对齐。 */
    public static LinearLayout segmented(Context c, String[] labels, int selected,
                                         java.util.function.IntConsumer onPick) {
        LinearLayout box = hbox(c);
        box.setBackground(rounded(graySoft(), 9, 0, 0));
        box.setPadding(dp(c, 3), dp(c, 3), dp(c, 3), dp(c, 3));
        for (int i = 0; i < labels.length; i++) {
            final int idx = i;
            TextView t = text(c, labels[i], 12, i == selected ? ink() : sub(), i == selected);
            t.setGravity(Gravity.CENTER);
            t.setPadding(dp(c, 6), dp(c, 8), dp(c, 6), dp(c, 8));
            if (i == selected) t.setBackground(rounded(panel(), 7, 0, 0));
            t.setOnClickListener(v -> onPick.accept(idx));
            box.addView(t, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        }
        return box;
    }
}
