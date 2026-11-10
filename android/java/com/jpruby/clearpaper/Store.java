package com.jpruby.clearpaper;

import android.content.Context;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.Date;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** 数据仓库与后台调度：对应 iOS 的 Store（任务 / 合并 / 输出文件 / 设置）。 */
public final class Store {
    private final Context c;
    private final Host host;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService engine = Executors.newSingleThreadExecutor();
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final SharedPreferences prefs;

    public final List<Job> jobs = new ArrayList<>();
    public final List<OutFile> files = new ArrayList<>();
    public final List<File> mergeURLs = new ArrayList<>();
    public volatile int mergeMode = 1;
    public volatile File mergeResult;
    public volatile String mergeMessage = "";
    public volatile boolean merging;
    public volatile boolean deghost = true, autoProcess = true;
    public volatile int appearance = 0;

    public Store(Context c, Host host) {
        this.c = c;
        this.host = host;
        prefs = c.getSharedPreferences("clearpaper", Context.MODE_PRIVATE);
        deghost = prefs.getBoolean("cp.deghost", true);
        autoProcess = prefs.getBoolean("cp.auto", true);
        appearance = prefs.getInt("cp.appearance", 0);
        mergeMode = prefs.getInt("cp.mergeMode", 1);
        GrayMath.deghostEnabled = deghost;
        Ui.setAppearance(c, appearance);
    }

    public File docsDir() {
        File d = new File(c.getFilesDir(), "清晰版");
        d.mkdirs();
        return d;
    }
    public File importDir() {
        File d = new File(c.getFilesDir(), "imports");
        d.mkdirs();
        return d;
    }
    public File captureRoot() {
        File d = new File(c.getFilesDir(), "ClearPaper/Captures");
        d.mkdirs();
        return d;
    }
    public File reviewRoot() {
        File d = new File(c.getFilesDir(), "ClearPaper/Review");
        d.mkdirs();
        return d;
    }

    private static String stamp() {
        return new SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(new Date());
    }

    public static String sizeText(long n) {
        return n >= 1048576 ? String.format(Locale.US, "%.1f MB", n / 1048576.0)
                : String.format(Locale.US, "%.0f KB", n / 1024.0);
    }
    public static String dateText(long d) {
        return new SimpleDateFormat("MM-dd HH:mm", Locale.CHINA).format(new Date(d));
    }

    private void ui(Runnable r) { main.post(r); }

    // MARK: 导入

    /** 外部来源（SAF / 微信「用其他应用打开」）先复制进自己的目录，保留原文件名。 */
    public static File stage(Context c, Uri uri, String suggestedName) {
        File dir = new File(c.getFilesDir(), "imports");
        dir.mkdirs();
        String name = suggestedName;
        if (name == null || name.isEmpty()) name = "导入-" + System.currentTimeMillis() + ".pdf";
        if (!name.toLowerCase(Locale.US).endsWith(".pdf")) name += ".pdf";
        name = name.replaceAll("[/\\\\:*?\"<>|]", "_");
        File dst = new File(dir, name);
        int n = 2;
        while (dst.exists()) {
            String base = name.substring(0, name.length() - 4);
            dst = new File(dir, base + "(" + n++ + ").pdf");
        }
        try (InputStream in = c.getContentResolver().openInputStream(uri);
             OutputStream out = new FileOutputStream(dst)) {
            if (in == null) return null;
            byte[] buf = new byte[64 * 1024];
            int r;
            while ((r = in.read(buf)) > 0) out.write(buf, 0, r);
            return dst;
        } catch (Exception e) { return null; }
    }

    /** 用户把 PDF 放进 App 的外部 Documents/Inbox 时，启动时自动加入任务。 */
    public void importInbox() {
        File inbox = new File(c.getExternalFilesDir(android.os.Environment.DIRECTORY_DOCUMENTS), "Inbox");
        if (inbox == null || !inbox.isDirectory()) return;
        File[] list = inbox.listFiles();
        if (list == null) return;
        Set<String> seen = new HashSet<>(prefs.getStringSet("cp.imported", new HashSet<>()));
        List<File> fresh = new ArrayList<>();
        for (File f : list) {
            if (!f.getName().toLowerCase(Locale.US).endsWith(".pdf")) continue;
            String key = f.getName() + "-" + f.length();
            if (!seen.contains(key)) { fresh.add(f); seen.add(key); }
        }
        prefs.edit().putStringSet("cp.imported", seen).apply();
        if (!fresh.isEmpty()) add(fresh);
    }

    public void add(List<File> urls) {
        for (File f : urls) {
            if (f == null || !f.exists()) continue;
            final Job j = new Job(f);
            jobs.add(0, j);
            if (autoProcess) start(j);
            else engine.execute(() -> makeThumb(j));
        }
        ui(host::refresh);
    }

    public void startQueued() {
        for (Job j : new ArrayList<>(jobs)) if (j.state == Job.QUEUED) start(j);
    }

    public void start(Job j) { j.state = Job.WORKING; engine.execute(() -> run(j)); }

    public void retry(final Job j) {
        j.state = Job.WORKING;
        j.progress = 0;
        j.result = null;
        j.phase = "重新开始…";
        engine.execute(() -> {
            boolean ok = j.captured ? (!j.imageFiles.isEmpty() && allExist(j.imageFiles)) : j.source.exists();
            if (!ok) {
                ui(() -> { j.state = Job.FAILED; j.phase = "原稿已丢失，请重新拍摄或导入"; host.refresh(); });
                return;
            }
            run(j);
        });
        ui(host::refresh);
    }

    private static boolean allExist(List<File> fs) {
        for (File f : fs) if (!f.exists()) return false;
        return true;
    }

    public void remove(Job j) {
        if (j.result != null) mergeURLs.remove(j.result);
        jobs.remove(j);
        ui(host::refresh);
    }
    public void clearFinished() {
        List<Job> copy = new ArrayList<>(jobs);
        for (Job j : copy) if (j.state == Job.DONE) remove(j);
    }

    private void makeThumb(Job j) {
        final android.graphics.Bitmap bm = j.captured
                ? (j.imageFiles.isEmpty() ? null : Capture.thumbnail(j.imageFiles.get(0), 84))
                : ScanEngine.thumb(j.source, 84);
        ui(() -> { j.thumb = bm; host.refresh(); });
    }

    // MARK: 拍照 / 相册链路

    /** 检查页确认后：逐页补裁边 / 旋转 -> 持久化原稿 -> OCR 文字稿 -> 完整清理流程。 */
    public void addCaptured(final File reviewDir, final boolean fromCamera, final int dropped) {
        File[] entries = reviewDir.listFiles((d, n) -> n.equals("manifest.txt"));
        if (entries == null || entries.length == 0) return;
        List<String> lines = new ArrayList<>();
        try (java.io.BufferedReader br = new java.io.BufferedReader(
                new java.io.InputStreamReader(new java.io.FileInputStream(entries[0]),
                        java.nio.charset.StandardCharsets.UTF_8))) {
            String line;
            while ((line = br.readLine()) != null) if (!line.trim().isEmpty()) lines.add(line);
        } catch (Exception e) { return; }
        if (lines.isEmpty()) return;

        final File dir = new File(captureRoot(), UUID.randomUUID().toString());
        dir.mkdirs();
        final Job j = new Job(new File(dir, "拍摄原件"));
        j.captured = true;
        j.captureDir = dir;
        j.dropped = dropped;
        j.state = Job.WORKING;
        j.name = "拍摄-" + stamp();
        j.phase = "自动找边矫正…";
        jobs.add(0, j);
        ui(host::refresh);

        engine.execute(() -> {
            int fixed = 0, idx = 0;
            for (String line : lines) {
                String[] p = line.split("\\|");
                File src = new File(reviewDir, p[0]);
                int rot = p.length > 1 ? parseInt(p[1]) : 0;
                boolean needsFix = p.length > 2 && "1".equals(p[2]);
                File work = new File(dir, "tmp-" + idx + ".jpg");
                boolean rectified = false;
                if ((!fromCamera) || needsFix) rectified = Capture.rectify(src, work);
                if (rectified) fixed++;
                File src2 = rectified ? work : src;
                File dst = new File(dir, String.format(Locale.US, "page-%03d.jpg", idx));
                boolean ok = rot != 0 ? Capture.rotatedFile(src2, rot, dst) : copy(src2, dst);
                if (rectified) work.delete();
                if (ok) j.imageFiles.add(dst);
                idx++;
            }
            if (j.imageFiles.isEmpty()) {
                ui(() -> { j.state = Job.FAILED; j.phase = "拍摄件读取失败"; host.refresh(); });
                return;
            }
            j.rectified = fixed;
            makeThumb(j);

            OcrClient.Result ocr = OcrClient.recognize(c, new ArrayList<>(j.imageFiles));
            String title = ocr.title;
            if (title == null || title.isEmpty()) title = "拍摄-" + stamp();
            String stem = sanitize(title).substring(0, Math.min(40, sanitize(title).length()));
            if (stem.isEmpty()) stem = "拍摄-" + stamp();
            File txt = new File(docsDir(), stem + "-文字.txt");
            try (java.io.Writer w = new java.io.OutputStreamWriter(
                    new FileOutputStream(txt), java.nio.charset.StandardCharsets.UTF_8)) {
                w.write(ocr.text);
            } catch (Exception ignored) {}
            j.name = title;
            j.outputStem = stem;
            j.textFile = txt;
            j.ocrLines = ocr.lines;
            j.phase = dropped > 0 ? "已跳过 " + dropped + " 张重复页 · 进入完整文档清理…"
                    : "找边矫正完成，进入完整文档清理…";
            ui(host::refresh);
            run(j);
            cleanupDir(reviewDir);
        });
    }

    private static int parseInt(String s) { try { return Integer.parseInt(s.trim()); } catch (Exception e) { return 0; } }

    private static String sanitize(String s) {
        return s.replaceAll("[/\\\\:*?\"<>|\n\r]", "").trim();
    }

    private static boolean copy(File src, File dst) {
        try (InputStream in = new java.io.FileInputStream(src);
             OutputStream out = new FileOutputStream(dst)) {
            byte[] b = new byte[64 * 1024];
            int n;
            while ((n = in.read(b)) > 0) out.write(b, 0, n);
            return true;
        } catch (Exception e) { return false; }
    }

    private static void cleanupDir(File d) {
        File[] fs = d.listFiles();
        if (fs != null) for (File f : fs) f.delete();
        d.delete();
    }

    // MARK: 清理引擎

    private void run(final Job j) {
        j.state = Job.WORKING;
        j.progress = 0;
        String stem = j.outputStem != null ? j.outputStem : stripExt(j.name);
        final File dst = uniqueOutput(sanitize(stem));
        final int[] step = {0};
        ScanEngine.Progress cb = msg -> {
            step[0]++;
            final float p = (float) Math.min(0.95, 1 - Math.exp(-step[0] / 10.0));
            ui(() -> { j.progress = p; j.phase = msg; host.refresh(); });
        };
        GrayMath.Report rep;
        try {
            rep = j.captured
                    ? ScanEngine.processImages(new ArrayList<>(j.imageFiles), dst, cb)
                    : ScanEngine.processPdf(j.source, dst, cb);
        } catch (Exception e) {
            rep = new GrayMath.Report();
            rep.passed = false;
            rep.problems.add("处理失败：" + (e.getMessage() == null ? "未知错误" : e.getMessage()));
        }
        final GrayMath.Report r = rep;
        ui(() -> {
            j.progress = 1;
            j.pages = r.pages;
            float min = 1;
            for (float f : r.decisions.retention) min = Math.min(min, f);
            j.retention = min;
            j.sheetMM = r.decisions.sheetWidthMM;
            j.seconds = r.seconds;
            j.showThrough = r.decisions.showThrough;
            // 只按磁盘上是否真的存在判定，避免把刚生成的结果误报成「已被删除」
            if (r.passed && r.pages > 0 && dst.exists()) {
                j.result = dst;
                j.state = Job.DONE;
                j.phase = "完成";
                addToMerge(dst);
                refreshFiles();
            } else {
                j.state = Job.FAILED;
                j.phase = r.problems.isEmpty()
                        ? (dst.exists() ? "未通过质量闸门" : "输出文件写入失败，可重试")
                        : r.problems.get(0);
            }
            host.refresh();
        });
    }

    private static String stripExt(String s) {
        int i = s.lastIndexOf('.');
        return i > 0 ? s.substring(0, i) : s;
    }

    private File uniqueOutput(String stem) {
        File base = new File(docsDir(), stem + "-清晰版.pdf");
        if (!base.exists()) return base;
        for (int n = 2; n < 100; n++) {
            File f = new File(docsDir(), stem + "-清晰版(" + n + ").pdf");
            if (!f.exists()) return f;
        }
        return new File(docsDir(), stem + "-清晰版-" + UUID.randomUUID().toString().substring(0, 6) + ".pdf");
    }

    // MARK: 合并

    public void setMergeMode(int m) {
        mergeMode = m;
        prefs.edit().putInt("cp.mergeMode", m).apply();
        mergeMessage = "";
        ui(host::refresh);
    }
    public void addToMerge(File f) {
        if (f == null || !f.exists()) return;
        for (File x : mergeURLs) if (x.getAbsolutePath().equals(f.getAbsolutePath())) return;
        mergeURLs.add(f);
        ui(host::refresh);
    }
    public void moveMerge(File f, int delta) {
        int i = mergeURLs.indexOf(f), j = i + delta;
        if (i < 0 || j < 0 || j >= mergeURLs.size()) return;
        Collections.swap(mergeURLs, i, j);
        ui(host::refresh);
    }
    public void removeFromMerge(File f) { mergeURLs.remove(f); ui(host::refresh); }

    public void performMerge() {
        List<File> urls = new ArrayList<>();
        for (File f : mergeURLs) if (f.exists()) urls.add(f);
        if (urls.size() < 2) {
            mergeMessage = "至少要有 2 份清晰版才能合并";
            ui(host::refresh);
            return;
        }
        merging = true;
        mergeMessage = "正在合并 " + urls.size() + " 份…";
        ui(host::refresh);
        final List<File> input = urls;
        final int mode = mergeMode;
        final File out = new File(docsDir(), "合并清晰版-" + stamp() + ".pdf");
        io.execute(() -> {
            int pages = 0;
            String err = null;
            try { pages = ScanEngine.merge(input, mode, out, null); }
            catch (Exception e) { err = e.getMessage(); }
            final int n = pages;
            final String failure = err;
            ui(() -> {
                merging = false;
                if (n > 0 && out.exists()) {
                    mergeResult = out;
                    mergeMessage = "已合并 " + input.size() + " 份 · 共 " + n + " 页";
                    refreshFiles();
                } else {
                    mergeResult = null;
                    mergeMessage = "合并失败：" + (failure == null ? "请检查文件是否有效" : failure);
                }
                host.refresh();
            });
        });
    }

    // MARK: 输出文件

    public void refreshFiles() {
        io.execute(() -> {
            File[] items = docsDir().listFiles();
            List<OutFile> list = new ArrayList<>();
            if (items != null) for (File f : items) {
                String n = f.getName().toLowerCase(Locale.US);
                if (!n.endsWith(".pdf") && !n.endsWith(".txt") && !n.endsWith(".md")) continue;
                boolean isText = !n.endsWith(".pdf");
                list.add(new OutFile(f, f.length(), f.lastModified(),
                        isText ? 0 : ScanEngine.pageCount(f), isText));
            }
            Collections.sort(list, (a, b) -> Long.compare(b.date, a.date));
            ui(() -> {
                files.clear();
                files.addAll(list);
                for (Job j : jobs) {
                    if (j.result != null && !j.result.exists()) {
                        j.result = null;
                        j.state = Job.FAILED;
                        j.phase = "结果文件已移走，可重试重新生成";
                    }
                    if (j.textFile != null && !j.textFile.exists()) j.textFile = null;
                }
                mergeURLs.removeIf(f -> !f.exists());
                host.refresh();
            });
        });
    }

    public void deleteFile(File f) {
        f.delete();
        mergeURLs.remove(f);
        if (mergeResult != null && mergeResult.equals(f)) { mergeResult = null; mergeMessage = ""; }
        refreshFiles();
    }

    // MARK: 设置

    public void setDeghost(boolean on) {
        deghost = on;
        GrayMath.deghostEnabled = on;
        prefs.edit().putBoolean("cp.deghost", on).apply();
    }
    public void setAutoProcess(boolean on) {
        autoProcess = on;
        prefs.edit().putBoolean("cp.auto", on).apply();
    }
    public void setAppearance(int mode) {
        appearance = mode;
        prefs.edit().putInt("cp.appearance", mode).apply();
        Ui.setAppearance(c, mode);
    }
}
