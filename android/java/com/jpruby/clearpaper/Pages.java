package com.jpruby.clearpaper;

import android.app.AlertDialog;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.PorterDuff;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.Switch;
import android.widget.TextView;

import java.io.File;
import java.util.ArrayList;
import java.util.List;

/** 四个 Tab 的页面构建，逐项对齐 iOS 的 ProcessView / MergeView / FilesView / AboutView。 */
public final class Pages {
    private Pages() {}

    private static LinearLayout page(Context c) { return Ui.page(c); }
    private static void gap(Context c, LinearLayout l, int dp) { Ui.add(l, Ui.spacer(c, dp), 0); }
    private static void row(Context c, LinearLayout parent, View v) { Ui.add(parent, v, 0); }

    private static TextView footerNote(Context c, String s) {
        TextView t = Ui.text(c, s, 10, Ui.mute(), false);
        t.setGravity(Gravity.CENTER);
        return t;
    }

    private static LinearLayout actions(Context c, Host h, File f, boolean includePrint) {
        List<String[]> items = new ArrayList<>();
        List<Integer> tints = new ArrayList<>();
        List<Runnable> acts = new ArrayList<>();
        items.add(new String[]{"◉", "预览"}); tints.add(Ui.blue()); acts.add(() -> h.preview(f));
        if (includePrint) { items.add(new String[]{"⎙", "打印"}); tints.add(Ui.green()); acts.add(() -> h.printPdf(f)); }
        items.add(new String[]{"↗", "分享"}); tints.add(Ui.blue()); acts.add(() -> h.share(f));
        items.add(new String[]{"▤", "存文件"}); tints.add(Ui.amber()); acts.add(() -> h.saveAs(f));
        int[] colors = new int[tints.size()];
        for (int i = 0; i < colors.length; i++) colors[i] = tints.get(i);
        return Ui.tileRow(c, items.toArray(new String[][]{}), colors, acts.toArray(new Runnable[]{}));
    }

    // MARK: 处理

    public static final class Process {
        public static View build(Context c, Host h) {
            Store s = h.store();
            LinearLayout l = page(c);
            Ui.add(l, Ui.brandHeader(c), 0);
            Ui.add(l, importCard(c, h), 14);
            Ui.add(l, captureRow(c, h), 14);
            Ui.add(l, optionsCard(c, h, s), 14);

            if (!s.jobs.isEmpty()) {
                LinearLayout head = Ui.hbox(c);
                head.addView(Ui.sectionTitle(c, "任务", s.jobs.size() + " 项"),
                        new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
                boolean anyDone = false;
                for (Job j : s.jobs) if (j.state == Job.DONE) anyDone = true;
                if (anyDone) {
                    TextView clear = Ui.text(c, "清空已完成", 11, Ui.amber(), false);
                    clear.setOnClickListener(v -> s.clearFinished());
                    head.addView(clear);
                }
                Ui.add(l, head, 10);
                for (Job j : s.jobs) Ui.add(l, jobCard(c, h, j), 12);
            } else {
                Ui.add(l, emptyState(c), 14);
            }
            Ui.add(l, footerNote(c, "全离线 · 不上传任何文件 · 数据只在本机"), 12);
            return Ui.scroll(c, l);
        }

        private static View importCard(Context c, Host h) {
            LinearLayout r = Ui.hbox(c);
            r.setPadding(Ui.dp(c, 14), Ui.dp(c, 14), Ui.dp(c, 14), Ui.dp(c, 14));
            GradientDrawable g = new GradientDrawable();
            g.setColor(Ui.panel());
            g.setCornerRadius(Ui.dp(c, 16));
            int a = Ui.amber();
            g.setStroke(Math.max(1, Ui.dp(c, 1.2f)), Color.argb(128, Color.red(a), Color.green(a), Color.blue(a)),
                    Ui.dp(c, 6), Ui.dp(c, 5));
            r.setBackground(g);
            r.addView(Ui.iconBox(c, "↓", Ui.amber(), Ui.amberSoft(), 48));
            LinearLayout t = Ui.vbox(c);
            t.setPadding(Ui.dp(c, 13), 0, 0, 0);
            t.addView(Ui.text(c, "导入试卷 PDF", 14, Ui.ink(), true));
            t.addView(Ui.text(c, "可一次选多份 · 微信里「用其他应用打开」也能进来", 12, Ui.sub(), false));
            r.addView(t, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
            TextView arrow = Ui.text(c, "›", 18, Ui.mute(), false);
            r.addView(arrow);
            r.setOnClickListener(v -> h.pickPdf());
            return r;
        }

        private static View captureRow(Context c, Host h) {
            LinearLayout l = Ui.vbox(c);
            LinearLayout tiles = Ui.hbox(c);
            FrameLayout cam = tileBig(c, "▣", "拍照扫描", Ui.amber(), h::startCamera);
            tiles.addView(cam, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
            tiles.addView(Ui.spacer(c, 10));
            FrameLayout album = tileBig(c, "▤", "从相册选", Ui.blue(), h::pickImages);
            tiles.addView(album, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
            l.addView(tiles);
            Ui.add(l, Ui.text(c, "手动快门逐页拍，不会因来不及翻页重复拍同一张；拍完进入检查页可删页、旋转、调序，重复页自动剔除。相册照片会自动找边并做透视矫正。",
                    11, Ui.sub(), false), 8);
            return l;
        }

        private static FrameLayout tileBig(Context c, String glyph, String label, int tint, Runnable action) {
            LinearLayout l = Ui.vbox(c);
            l.setGravity(Gravity.CENTER_HORIZONTAL);
            TextView icon = Ui.text(c, glyph, 19, tint, true);
            icon.setGravity(Gravity.CENTER);
            l.addView(icon);
            TextView cap = Ui.text(c, label, 12, tint, true);
            cap.setGravity(Gravity.CENTER);
            Ui.add(l, cap, 6);
            l.setPadding(Ui.dp(c, 8), Ui.dp(c, 13), Ui.dp(c, 8), Ui.dp(c, 13));
            FrameLayout f = new FrameLayout(c);
            f.setBackground(Ui.rounded(Color.argb(26, Color.red(tint), Color.green(tint), Color.blue(tint)), 14, 0, 0));
            f.addView(l, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT));
            f.setOnClickListener(v -> action.run());
            return f;
        }

        private static View optionsCard(Context c, Host h, Store s) {
            LinearLayout card = Ui.card(c, 14);
            LinearLayout head = Ui.hbox(c);
            head.addView(Ui.iconBox(c, "✦", Ui.amber(), Ui.amberSoft(), 30));
            TextView t = Ui.text(c, "处理选项", 14, Ui.ink(), true);
            t.setPadding(Ui.dp(c, 10), 0, 0, 0);
            head.addView(t);
            card.addView(head);
            Ui.add(card, Ui.text(c, "拍照与相册导入的页面都会先经过检查页；确认后才进入和导入 PDF 完全相同的清理流程：白场归一 → 去透印 → 自适应 gamma → 单向锐化 → 裁边 → A4 → 笔画闸门。",
                    10, Ui.sub(), false), 6);
            Ui.add(card, Ui.divider(c), 8);
            Ui.add(card, toggle(c, "去除背面透印", "清掉纸背透过来的浅灰虚影，保留真实笔画与照片",
                    s.deghost, on -> s.setDeghost(on)), 8);
            Ui.add(card, Ui.divider(c), 8);
            Ui.add(card, toggle(c, "导入后自动开始", "关闭后先攒齐多份，再点「开始处理」",
                    s.autoProcess, on -> s.setAutoProcess(on)), 8);
            int queued = 0;
            for (Job j : s.jobs) if (j.state == Job.QUEUED) queued++;
            if (queued > 0) {
                Ui.add(card, Ui.primaryButton(c, "开始处理 " + queued + " 份", false, s::startQueued), 10);
            }
            return card;
        }

        private static View toggle(Context c, String title, String body, boolean on,
                                   java.util.function.Consumer<Boolean> changed) {
            LinearLayout r = Ui.hbox(c);
            LinearLayout t = Ui.vbox(c);
            t.addView(Ui.text(c, title, 13, Ui.ink(), true));
            Ui.add(t, Ui.text(c, body, 10, Ui.sub(), false), 2);
            r.addView(t, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
            Switch sw = new Switch(c);
            sw.setChecked(on);
            sw.setOnCheckedChangeListener((v, checked) -> changed.accept(checked));
            r.addView(sw);
            return r;
        }

        private static View emptyState(Context c) {
            LinearLayout l = Ui.vbox(c);
            l.setGravity(Gravity.CENTER_HORIZONTAL);
            l.setPadding(Ui.dp(c, 16), Ui.dp(c, 22), Ui.dp(c, 16), Ui.dp(c, 22));
            GradientDrawable g = new GradientDrawable();
            g.setColor(Color.TRANSPARENT);
            g.setCornerRadius(Ui.dp(c, 16));
            g.setStroke(Ui.dp(c, 1), Ui.line(), Ui.dp(c, 6), Ui.dp(c, 5));
            l.setBackground(g);
            l.addView(Ui.iconBox(c, "✦", Ui.amber(), Ui.amberSoft(), 46));
            Ui.add(l, Ui.text(c, "把试卷变干净，只要三步", 14, Ui.ink(), true), 12);
            Ui.add(l, Ui.stepRow(c, 1, "导入 PDF", "一份或多份，顺序就是合并顺序"), 12);
            Ui.add(l, Ui.stepRow(c, 2, "本机清晰化", "自动裁边、去透印、铺成 A4"), 8);
            Ui.add(l, Ui.stepRow(c, 3, "打印 / 分享", "可直接打印，或存到文件"), 8);
            return l;
        }

        private static View jobCard(Context c, Host h, Job j) {
            LinearLayout card = Ui.card(c, 14);
            LinearLayout top = Ui.hbox(c);
            FrameLayout thumbBox = new FrameLayout(c);
            thumbBox.setBackground(Ui.rounded(Ui.graySoft(), 8, 0, 0));
            int tw = Ui.dp(c, 42), th = Ui.dp(c, 54);
            thumbBox.setLayoutParams(new LinearLayout.LayoutParams(tw, th));
            ImageView iv = new ImageView(c);
            iv.setScaleType(ImageView.ScaleType.CENTER_CROP);
            if (j.thumb != null) iv.setImageBitmap(j.thumb);
            else iv.setImageDrawable(null);
            FrameLayout.LayoutParams ip = new FrameLayout.LayoutParams(
                    Ui.dp(c, 38), Ui.dp(c, 50), Gravity.CENTER);
            thumbBox.addView(iv, ip);
            top.addView(thumbBox);
            LinearLayout info = Ui.vbox(c);
            info.setPadding(Ui.dp(c, 11), 0, 0, 0);
            TextView name = Ui.text(c, j.name, 14, Ui.ink(), true);
            name.setMaxLines(2);
            info.addView(name);
            Ui.add(info, Ui.text(c, subtitle(j), 12, Ui.sub(), false), 4);
            top.addView(info, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
            LinearLayout right = Ui.vbox(c);
            right.setGravity(Gravity.CENTER_HORIZONTAL);
            TextView badge = Ui.text(c, badge(j), 16,
                    j.state == Job.DONE ? Ui.green() : (j.state == Job.FAILED ? Ui.red() : Ui.amber()), true);
            badge.setGravity(Gravity.CENTER);
            right.addView(badge);
            TextView close = Ui.text(c, "✕", 10, Ui.mute(), true);
            close.setGravity(Gravity.CENTER);
            close.setBackground(Ui.rounded(Ui.graySoft(), 20, 0, 0));
            LinearLayout.LayoutParams cp = new LinearLayout.LayoutParams(Ui.dp(c, 20), Ui.dp(c, 20));
            cp.topMargin = Ui.dp(c, 6);
            close.setOnClickListener(v -> h.store().remove(j));
            right.addView(close, cp);
            top.addView(right);
            card.addView(top);

            if (j.state == Job.WORKING) {
                ProgressBar pb = new ProgressBar(c, null, android.R.attr.progressBarStyleHorizontal);
                pb.setMax(100);
                pb.setProgress((int) (j.progress * 100));
                pb.getProgressDrawable().setColorFilter(Ui.amber(), PorterDuff.Mode.SRC_IN);
                Ui.add(card, pb, 10);
            }
            if (j.state == Job.DONE) {
                LinearLayout chips = Ui.hbox(c);
                chips.addView(Ui.chip(c, j.pages + " 页 A4", Ui.blue(), Ui.blueSoft()));
                chips.addView(Ui.spacer(c, 6));
                chips.addView(Ui.chip(c, String.format(java.util.Locale.US, "笔画保留 %.0f%%", j.retention * 100),
                        Ui.green(), Ui.greenSoft()));
                if (j.showThrough) {
                    chips.addView(Ui.spacer(c, 6));
                    chips.addView(Ui.chip(c, "已去透印", Ui.amber(), Ui.amberSoft()));
                }
                Ui.add(card, chips, 11);
                if (j.captured) {
                    StringBuilder note = new StringBuilder();
                    if (j.rectified > 0) note.append("找边矫正 ").append(j.rectified).append(" 页 · ");
                    if (j.dropped > 0) note.append("跳过重复 ").append(j.dropped).append(" 页 · ");
                    note.append("完整流程：白场归一 / 去透印 / 单向锐化 / A4 / 笔画闸门");
                    Ui.add(card, Ui.text(c, note.toString(), 10, Ui.sub(), false), 8);
                }
            }
            if (j.result != null) Ui.add(card, actions(c, h, j.result, true), 11);
            if (j.textFile != null) {
                TextView txt = Ui.text(c, "≡  OCR 文字稿 · " + j.ocrLines + " 行   ›", 12, Ui.ink2(), true);
                txt.setBackground(Ui.rounded(Ui.panel2(), 10, 0, 0));
                txt.setPadding(Ui.dp(c, 11), Ui.dp(c, 9), Ui.dp(c, 11), Ui.dp(c, 9));
                txt.setOnClickListener(v -> h.showText(j.textFile));
                Ui.add(card, txt, 10);
            }
            if (j.state == Job.FAILED) {
                Ui.add(card, Ui.tileRow(c, new String[][]{{"⟳", "重试"}},
                        new int[]{Ui.red()}, new Runnable[]{() -> h.store().retry(j)}), 10);
            } else if (j.state == Job.QUEUED) {
                Ui.add(card, Ui.tileRow(c, new String[][]{{"▶", "开始处理"}},
                        new int[]{Ui.amber()}, new Runnable[]{() -> h.store().start(j)}), 10);
            }
            return card;
        }

        private static String subtitle(Job j) {
            switch (j.state) {
                case Job.QUEUED: return "排队中 · 等待开始";
                case Job.WORKING: return j.phase;
                case Job.DONE: return String.format(java.util.Locale.US, "纸面 %.0f mm · 用时 %.1fs", j.sheetMM, j.seconds);
                default: return j.phase;
            }
        }
        private static String badge(Job j) {
            switch (j.state) {
                case Job.WORKING: return "◌";
                case Job.DONE: return "✓";
                case Job.FAILED: return "!";
                default: return "◷";
            }
        }
    }

    // MARK: 合并

    public static final class Merge {
        public static View build(Context c, Host h) {
            Store s = h.store();
            LinearLayout l = page(c);
            Ui.add(l, Ui.pageHeader(c, "▧", "合并清晰版", "按下面的顺序拼成一份 PDF"), 0);

            LinearLayout mode = Ui.card(c, 14);
            mode.addView(Ui.sectionTitle(c, "合并方式", null));
            Ui.add(mode, Ui.segmented(c, new String[]{"分别保存", "完全合并", "间隔·双面"},
                    s.mergeMode, i -> s.setMergeMode(i)), 10);
            Ui.add(mode, Ui.text(c, modeHint(s.mergeMode), 12, Ui.sub(), false), 10);
            Ui.add(l, mode, 14);

            LinearLayout order = Ui.card(c, 0);
            LinearLayout head = Ui.hbox(c);
            head.setPadding(Ui.dp(c, 14), Ui.dp(c, 14), Ui.dp(c, 14), Ui.dp(c, 8));
            head.addView(Ui.sectionTitle(c, "合并顺序", s.mergeURLs.size() + " 份"),
                    new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
            TextView add = Ui.text(c, "+ 添加", 12, Ui.amber(), true);
            add.setOnClickListener(v -> h.pickPdf());
            head.addView(add);
            order.addView(head);
            if (s.mergeURLs.isEmpty()) {
                TextView empty = Ui.text(c, "还没有可合并的清晰版。\n先到「处理」导入 PDF，或到「文件」把已有结果加进来。",
                        12, Ui.mute(), false);
                empty.setGravity(Gravity.CENTER);
                empty.setPadding(Ui.dp(c, 16), Ui.dp(c, 26), Ui.dp(c, 16), Ui.dp(c, 30));
                order.addView(empty);
            } else {
                for (int i = 0; i < s.mergeURLs.size(); i++) {
                    final File f = s.mergeURLs.get(i);
                    LinearLayout line = Ui.hbox(c);
                    line.setPadding(Ui.dp(c, 14), Ui.dp(c, 9), Ui.dp(c, 14), Ui.dp(c, 9));
                    TextView num = Ui.text(c, String.valueOf(i + 1), 10, Ui.amber(), true);
                    num.setGravity(Gravity.CENTER);
                    num.setBackground(Ui.rounded(Ui.amberSoft(), 20, 0, 0));
                    num.setLayoutParams(new LinearLayout.LayoutParams(Ui.dp(c, 22), Ui.dp(c, 22)));
                    line.addView(num);
                    LinearLayout info = Ui.vbox(c);
                    info.setPadding(Ui.dp(c, 10), 0, 0, 0);
                    TextView nm = Ui.text(c, f.getName(), 12, Ui.ink(), true);
                    nm.setSingleLine(true);
                    info.addView(nm);
                    Ui.add(info, Ui.text(c, ScanEngine.pageCount(f) + " 页", 10, Ui.sub(), false), 2);
                    line.addView(info, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
                    line.addView(tool(c, "↑", Ui.sub(), () -> s.moveMerge(f, -1)));
                    line.addView(tool(c, "↓", Ui.sub(), () -> s.moveMerge(f, 1)));
                    line.addView(tool(c, "−", Ui.red(), () -> s.removeFromMerge(f)));
                    order.addView(line);
                    if (i < s.mergeURLs.size() - 1) {
                        View d = Ui.divider(c);
                        LinearLayout.LayoutParams dp = new LinearLayout.LayoutParams(
                                ViewGroup.LayoutParams.MATCH_PARENT, Math.max(1, Ui.dp(c, 0.6f)));
                        dp.leftMargin = Ui.dp(c, 46);
                        order.addView(d, dp);
                    }
                }
                order.setPadding(0, 0, 0, Ui.dp(c, 10));
            }
            Ui.add(l, order, 14);

            if (s.mergeMode == 0) {
                Ui.add(l, Ui.primaryButton(c, "结果已分别保存 · 去查看", false, () -> h.gotoTab(2)), 14);
            } else {
                boolean disabled = s.mergeURLs.size() < 2 || s.merging;
                Ui.add(l, Ui.primaryButton(c, s.merging ? "正在合并…" : "合并并保存", disabled,
                        disabled ? null : s::performMerge), 14);
            }

            if (!s.mergeMessage.isEmpty()) {
                LinearLayout result = Ui.card(c, 12);
                LinearLayout r = Ui.hbox(c);
                r.addView(Ui.iconBox(c, s.mergeResult == null ? "i" : "✓",
                        s.mergeResult == null ? Ui.sub() : Ui.green(),
                        s.mergeResult == null ? Ui.graySoft() : Ui.greenSoft(), 30));
                TextView m = Ui.text(c, s.mergeMessage, 12, Ui.ink(), false);
                m.setPadding(Ui.dp(c, 10), 0, 0, 0);
                r.addView(m, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
                result.addView(r);
                if (s.mergeResult != null && s.mergeResult.exists())
                    Ui.add(result, actions(c, h, s.mergeResult, true), 8);
                Ui.add(l, result, 14);
            }

            LinearLayout why = Ui.card(c, 14);
            why.addView(Ui.text(c, "为什么要「间隔·双面」？", 12, Ui.ink(), true));
            Ui.add(why, Ui.text(c, "双面打印时，如果上一份试卷是奇数页，下一份的第一页会印在同一张纸背面，两卷就串了。间隔模式会在每份末尾补一张空白页，保证每卷都从新纸正面开始。",
                    10, Ui.sub(), false), 7);
            Ui.add(l, why, 14);
            return Ui.scroll(c, l);
        }

        private static TextView tool(Context c, String glyph, int tint, Runnable action) {
            TextView t = Ui.text(c, glyph, 15, tint, true);
            t.setGravity(Gravity.CENTER);
            t.setPadding(Ui.dp(c, 6), Ui.dp(c, 4), Ui.dp(c, 6), Ui.dp(c, 4));
            t.setOnClickListener(v -> action.run());
            return t;
        }

        private static String modeHint(int mode) {
            switch (mode) {
                case 0: return "每份各存一个清晰版 PDF，不生成合并文件。结果在「文件」里。";
                case 2: return "每份末尾（最后一份除外）补空白页到偶数页，双面打印不跨卷。";
                default: return "按上面的顺序首尾相接，页数不变。";
            }
        }
    }

    // MARK: 文件

    public static final class Files {
        public static View build(Context c, Host h) {
            Store s = h.store();
            LinearLayout l = page(c);
            LinearLayout header = Ui.pageHeader(c, "▣", "输出文件", "保存在本 App 的「清晰版」文件夹");
            TextView refresh = Ui.text(c, "↻", 18, Ui.amber(), true);
            refresh.setOnClickListener(v -> s.refreshFiles());
            header.addView(refresh);
            Ui.add(l, header, 0);

            if (s.files.isEmpty()) {
                LinearLayout empty = Ui.vbox(c);
                empty.setGravity(Gravity.CENTER_HORIZONTAL);
                empty.setPadding(0, Ui.dp(c, 42), 0, Ui.dp(c, 42));
                empty.addView(Ui.text(c, "▤", 34, Ui.mute(), false));
                Ui.add(empty, Ui.text(c, "还没有输出文件", 14, Ui.sub(), false), 10);
                TextView tip = Ui.text(c, "处理后的 PDF 会自动出现在这里，也可以分享或存到系统文件", 10, Ui.mute(), false);
                tip.setGravity(Gravity.CENTER);
                Ui.add(empty, tip, 6);
                Ui.add(l, empty, 14);
            } else {
                for (OutFile f : s.files) Ui.add(l, fileCard(c, h, f), 12);
            }
            Ui.add(l, footerNote(c, "这些文件只存在你的手机上 · 删除后可在「处理」重试"), 12);
            return Ui.scroll(c, l);
        }

        private static View fileCard(Context c, Host h, OutFile f) {
            Store s = h.store();
            LinearLayout card = Ui.card(c, 14);
            LinearLayout top = Ui.hbox(c);
            top.addView(Ui.iconBox(c, f.isText ? "≡" : "▤", f.isText ? Ui.amber() : Ui.blue(),
                    f.isText ? Ui.amberSoft() : Ui.blueSoft(), 38));
            LinearLayout info = Ui.vbox(c);
            info.setPadding(Ui.dp(c, 11), 0, 0, 0);
            TextView name = Ui.text(c, f.name(), 12, Ui.ink(), true);
            name.setMaxLines(2);
            info.addView(name);
            String sub = f.isText ? "文字稿 · " + Store.sizeText(f.size) + " · " + Store.dateText(f.date)
                    : f.pages + " 页 · " + Store.sizeText(f.size) + " · " + Store.dateText(f.date);
            Ui.add(info, Ui.text(c, sub, 10, Ui.sub(), false), 3);
            top.addView(info, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
            TextView del = Ui.text(c, "✕", 13, Ui.red(), true);
            del.setOnClickListener(v -> confirmDelete(c, h, f.file));
            top.addView(del);
            card.addView(top);

            List<String[]> items = new ArrayList<>();
            List<Integer> tints = new ArrayList<>();
            List<Runnable> acts = new ArrayList<>();
            items.add(new String[]{f.isText ? "◉" : "◉", f.isText ? "查看" : "预览"});
            tints.add(Ui.blue());
            acts.add(() -> { if (f.isText) h.showText(f.file); else h.preview(f.file); });
            if (!f.isText) {
                items.add(new String[]{"⎙", "打印"}); tints.add(Ui.green()); acts.add(() -> h.printPdf(f.file));
            }
            items.add(new String[]{"↗", "分享"}); tints.add(Ui.blue()); acts.add(() -> h.share(f.file));
            if (!f.isText) {
                items.add(new String[]{"+", "加合并"}); tints.add(Ui.amber());
                acts.add(() -> { s.addToMerge(f.file); h.gotoTab(1); });
            } else {
                items.add(new String[]{"⧉", "复制"}); tints.add(Ui.green());
                acts.add(() -> h.showText(f.file));
            }
            int[] colors = new int[tints.size()];
            for (int i = 0; i < colors.length; i++) colors[i] = tints.get(i);
            Ui.add(card, Ui.tileRow(c, items.toArray(new String[][]{}), colors, acts.toArray(new Runnable[]{})), 10);
            return card;
        }

        private static void confirmDelete(Context c, Host h, File f) {
            new AlertDialog.Builder(c)
                    .setTitle("删除这个文件？")
                    .setMessage(f.getName())
                    .setNegativeButton("取消", null)
                    .setPositiveButton("删除", (d, w) -> h.store().deleteFile(f))
                    .show();
        }
    }

    // MARK: 关于

    public static final class About {
        public static View build(Context c, Host h) {
            Store s = h.store();
            LinearLayout l = page(c);
            LinearLayout brand = Ui.card(c, 18);
            brand.setGravity(Gravity.CENTER_HORIZONTAL);
            ImageView logo = new ImageView(c);
            logo.setImageResource(R.drawable.logo);
            logo.setScaleType(ImageView.ScaleType.FIT_CENTER);
            logo.setBackground(Ui.rounded(Ui.graySoft(), 20, 0, 0));
            brand.addView(logo, new LinearLayout.LayoutParams(Ui.dp(c, 86), Ui.dp(c, 86)));
            Ui.add(brand, Ui.text(c, "ClearPaper", 20, Ui.ink(), true), 10);
            Ui.add(brand, Ui.text(c, "by " + Ui.AUTHOR, 14, Ui.amber(), true), 4);
            Ui.add(brand, Ui.chip(c, "版本 " + Ui.VERSION + " (" + Ui.BUILD + ")", Ui.sub(), Ui.graySoft()), 8);
            Ui.add(brand, Ui.text(c, "全离线 · 不上传任何文件 · 无服务端", 12, Ui.sub(), false), 8);
            TextView link = Ui.text(c, "⌁  github.com/jpruby0127/ClearPaper", 12, Ui.blue(), false);
            link.setOnClickListener(v -> c.startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(Ui.REPO))));
            Ui.add(brand, link, 8);
            Ui.add(l, brand, 0);

            LinearLayout feat = Ui.card(c, 14);
            feat.addView(Ui.sectionTitle(c, "它能做什么", null));
            addFeature(c, feat, "✦", "扫描件清晰化", "自动裁掉白边与黑框、拉回对比度，保持笔画不丢", Ui.amber(), Ui.amberSoft());
            addFeature(c, feat, "◌", "背面透印抑制", "只清纸背透过来的浅灰虚影，照片与浅色底纹不动", Ui.blue(), Ui.blueSoft());
            addFeature(c, feat, "▭", "横竖页自适应", "横向排版自动输出横向 A4，不会被裁掉", Ui.green(), Ui.greenSoft());
            addFeature(c, feat, "▧", "多份合并", "完全合并 / 间隔·双面，双面打印不跨卷", Ui.blue(), Ui.blueSoft());
            addFeature(c, feat, "✓", "质量闸门", "笔画保留率低于 97% 会提示，不静默出坏结果", Ui.green(), Ui.greenSoft());
            addFeature(c, feat, "▣", "拍照扫描 + OCR", "自动找边透视矫正、重复页自动剔除；文字稿与自动命名", Ui.amber(), Ui.amberSoft());
            Ui.add(l, feat, 14);

            LinearLayout steps = Ui.card(c, 14);
            steps.addView(Ui.sectionTitle(c, "三步上手", null));
            Ui.add(steps, Ui.stepRow(c, 1, "导入 PDF", "在「处理」页选一份或多份试卷，顺序就是合并顺序。"), 11);
            Ui.add(steps, Ui.stepRow(c, 2, "本机处理", "自动完成并给出页数、纸面宽度、笔画保留率。"), 11);
            Ui.add(steps, Ui.stepRow(c, 3, "打印 / 分享 / 合并", "可直接打印，也可在「合并」页拼成一份。"), 11);
            Ui.add(steps, Ui.divider(c), 10);
            Ui.add(steps, Ui.text(c, "打印小贴士：选 A4、缩放「实际大小 / 100%」，不要选「适合页面」。",
                    10, Ui.sub(), false), 8);
            Ui.add(l, steps, 14);

            LinearLayout capture = Ui.card(c, 14);
            capture.addView(Ui.sectionTitle(c, "关于拍照与清理", null));
            Ui.add(capture, Ui.text(c, "Android 没有系统文档相机，这里用手动快门逐页拍：不会因来不及翻页重复拍同一张；拍完进入「检查拍摄页」，可逐页删除、旋转 90°、调整顺序，重复页按页面指纹自动剔除，也能一键恢复。没有实验性质的自研自动相机。",
                    10, Ui.sub(), false), 8);
            Ui.add(capture, Ui.text(c, "相册原帧带桌面、阴影、歪斜时，App 会逐页做几何找边 + 透视矫正；已经裁好的扫描件不会被二次裁剪。之后所有拍照件都走完和导入 PDF 完全相同的清理流程：白场归一 → 去透印 → 自适应 gamma → 单向锐化 → 裁边 → A4 → 笔画闸门。",
                    10, Ui.sub(), false), 8);
            Ui.add(capture, Ui.divider(c), 10);
            Ui.add(capture, Ui.sectionTitle(c, "关于 OCR", null), 8);
            Ui.add(capture, Ui.text(c, "iOS 用系统 Vision 引擎离线识别；Android 系统不提供通用 OCR 模型，因此这里改成可选桥接小米开源的 Xiaomi-OCR-0（0.8B / Apache 2.0，与仓库 python/ocr_xiaomi.py 同一协议）。默认关闭、零联网：只有你在下面填入自己部署的本机 / 内网服务地址并打开开关，才会把页面送过去生成 Markdown 文字稿、用首页标题自动命名。",
                    10, Ui.sub(), false), 8);
            Ui.add(capture, Ui.text(c, "无论是否配置 OCR，图像清晰化、A4 排版与质量闸门都照常工作。PDF 本身保持图像，保证打印质量。",
                    10, Ui.sub(), false), 8);
            Ui.add(capture, Ui.text(c, "合并说明：iOS 用 PDFKit 原样插入页面；Android 用系统 PdfRenderer 按 200dpi 逐页重绘后拼接，顺序、横竖方向与双面补空白页完全一致，扫描件看不出差别；纯矢量文字稿合并会变成图像页。",
                    10, Ui.sub(), false), 8);
            TextView ocr = Ui.text(c, "⌁  OCR 服务设置" + (OcrClient.enabled(c) ? "（已启用）" : "（未启用 · 完全离线）"),
                    12, Ui.blue(), true);
            ocr.setPadding(0, Ui.dp(c, 10), 0, 0);
            ocr.setOnClickListener(v -> ocrSettings(c, h));
            capture.addView(ocr);
            Ui.add(l, capture, 14);

            LinearLayout look = Ui.card(c, 14);
            look.addView(Ui.sectionTitle(c, "外观", null));
            Ui.add(look, Ui.segmented(c, new String[]{"跟随系统", "浅色", "深色"}, s.appearance,
                    i -> { s.setAppearance(i); h.refresh(); }), 10);
            Ui.add(look, Ui.text(c, "深色不是纯黑，浅色也保留足够的层次对比。", 10, Ui.sub(), false), 8);
            Ui.add(l, look, 14);

            Ui.add(l, footerNote(c, "© 2026 " + Ui.AUTHOR + " · MIT License"), 4);
            Ui.add(l, footerNote(c, "macOS / iOS / Android / Windows · 同一套算法"), 2);
            return Ui.scroll(c, l);
        }

        private static void addFeature(Context c, LinearLayout parent, String glyph, String t,
                                       String body, int fg, int bg) {
            Ui.add(parent, Ui.feature(c, glyph, t, body, fg, bg), 11);
        }

        private static void ocrSettings(Context c, Host h) {
            LinearLayout box = Ui.vbox(c);
            box.setPadding(Ui.dp(c, 20), Ui.dp(c, 12), Ui.dp(c, 20), Ui.dp(c, 4));
            box.addView(Ui.text(c, "服务地址（OpenAI 兼容）", 11, Ui.sub(), false));
            EditText url = new EditText(c);
            url.setHint("http://192.168.1.10:8000/v1");
            url.setInputType(InputType.TYPE_TEXT_VARIATION_URI);
            url.setText(OcrClient.endpoint(c));
            box.addView(url);
            box.addView(Ui.text(c, "模型名", 11, Ui.sub(), false));
            EditText model = new EditText(c);
            model.setHint("SeerRay-Lab/Xiaomi-OCR-0");
            model.setText(OcrClient.model(c));
            box.addView(model);
            Switch on = new Switch(c);
            on.setText("启用 OCR（关闭时完全离线）");
            on.setTextColor(Ui.ink());
            on.setChecked(OcrClient.enabled(c));
            Ui.add(box, on, 10);
            Ui.add(box, Ui.text(c, "只填你自己部署的服务地址；启用后拍摄页会发往该地址，其余功能始终离线。",
                    10, Ui.mute(), false), 8);
            new AlertDialog.Builder(c).setTitle("OCR 服务 · Xiaomi-OCR-0").setView(box)
                    .setNegativeButton("取消", null)
                    .setPositiveButton("保存", (d, w) -> {
                        OcrClient.configure(c, url.getText().toString(), model.getText().toString(), on.isChecked());
                        h.toast(on.isChecked() ? "OCR 服务已启用" : "OCR 已关闭，保持完全离线");
                        h.refresh();
                    }).show();
        }
    }
}
