package com.jpruby.clearpaper;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.pdf.PdfRenderer;
import android.os.ParcelFileDescriptor;

import java.io.Closeable;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

/**
 * 扫描流水线调度：把 PDF / 图片变成 Gray，走 GrayMath 的完整流程，
 * 再用 PdfWrite 流式输出 A4 PDF。逐页处理 + 临时落盘，20 页也不会吃爆内存。
 */
public final class ScanEngine {
    private ScanEngine() {}

    public interface Progress { void on(String message); }

    /** 手机上的工作分辨率：A4 约 218dpi，足够打印，内存与耗时都可控。 */
    public static final int TARGET_WIDTH = 1800;
    private static final int MAX_HEIGHT = 2600;

    public interface Source extends Closeable {
        int count();
        GrayMath.Gray load(int index) throws IOException;
    }

    /** PDF 输入：按页盒渲染，绕开伪造的 MediaBox；横向页自然保持横向。 */
    public static final class PdfSource implements Source {
        private final ParcelFileDescriptor pfd;
        private final PdfRenderer renderer;
        public PdfSource(File file) throws IOException {
            pfd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY);
            renderer = new PdfRenderer(pfd);
        }
        @Override public int count() { return renderer.getPageCount(); }
        @Override public GrayMath.Gray load(int index) throws IOException {
            PdfRenderer.Page page = renderer.openPage(index);
            try {
                double scale = Math.min(Math.min((double) TARGET_WIDTH / Math.max(1, page.getWidth()),
                        (double) MAX_HEIGHT / Math.max(1, page.getHeight())), 3.4);
                int w = Math.max(1, (int) Math.round(page.getWidth() * scale));
                int h = Math.max(1, (int) Math.round(page.getHeight() * scale));
                Bitmap bm = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
                bm.eraseColor(Color.WHITE);
                page.render(bm, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY);
                GrayMath.Gray g = fromBitmap(bm);
                bm.recycle();
                return g;
            } finally { page.close(); }
        }
        /** 合并用：灰度页 + 源页物理尺寸（pt），横向页保持横向。 */
        public MergedPage loadPageForMerge(int index) {
            PdfRenderer.Page page = renderer.openPage(index);
            try {
                double pw = Math.max(1, page.getWidth()), ph = Math.max(1, page.getHeight());
                double scale = Math.min(Math.min(200.0 / 72.0, (double) TARGET_WIDTH / pw),
                        (double) MAX_HEIGHT / ph);
                int w = Math.max(1, (int) Math.round(pw * scale));
                int h = Math.max(1, (int) Math.round(ph * scale));
                Bitmap bm = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
                bm.eraseColor(Color.WHITE);
                page.render(bm, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY);
                GrayMath.Gray g = fromBitmap(bm);
                bm.recycle();
                return new MergedPage(g, pw, ph);
            } finally { page.close(); }
        }
        @Override public void close() throws IOException { renderer.close(); pfd.close(); }
    }

    /** 拍照 / 相册输入：每页一张已归一方向的 JPEG。 */
    public static final class ImageSource implements Source {
        private final List<File> files;
        public ImageSource(List<File> files) { this.files = files; }
        @Override public int count() { return files.size(); }
        @Override public GrayMath.Gray load(int index) {
            BitmapFactory.Options probe = new BitmapFactory.Options();
            probe.inJustDecodeBounds = true;
            BitmapFactory.decodeFile(files.get(index).getPath(), probe);
            int w = Math.max(1, probe.outWidth), h = Math.max(1, probe.outHeight);
            int sample = 1;
            while (w / sample > TARGET_WIDTH * 2 || h / sample > MAX_HEIGHT * 2) sample *= 2;
            BitmapFactory.Options opt = new BitmapFactory.Options();
            opt.inSampleSize = sample;
            opt.inPreferredConfig = Bitmap.Config.ARGB_8888;
            Bitmap bm = BitmapFactory.decodeFile(files.get(index).getPath(), opt);
            if (bm == null) throw new IllegalStateException("无法解码图片: " + files.get(index));
            if (bm.getWidth() > TARGET_WIDTH || bm.getHeight() > MAX_HEIGHT) {
                float k = Math.min((float) TARGET_WIDTH / bm.getWidth(), (float) MAX_HEIGHT / bm.getHeight());
                Bitmap small = Bitmap.createScaledBitmap(bm,
                        Math.max(1, Math.round(bm.getWidth() * k)),
                        Math.max(1, Math.round(bm.getHeight() * k)), true);
                bm.recycle();
                bm = small;
            }
            GrayMath.Gray g = fromBitmap(bm);
            bm.recycle();
            return g;
        }
        @Override public void close() {}
    }

    public static GrayMath.Gray fromBitmap(Bitmap bm) {
        int w = bm.getWidth(), h = bm.getHeight();
        int[] argb = new int[w * h];
        bm.getPixels(argb, 0, w, 0, 0, w, h);
        byte[] px = new byte[w * h];
        for (int i = 0; i < argb.length; i++) {
            int c = argb[i];
            int r = (c >> 16) & 255, g = (c >> 8) & 255, bl = c & 255;
            px[i] = (byte) ((r * 77 + g * 150 + bl * 29) >> 8);
        }
        return new GrayMath.Gray(w, h, px);
    }

    public static Bitmap toBitmap(GrayMath.Gray g) {
        int[] argb = new int[g.w * g.h];
        for (int i = 0; i < argb.length; i++) {
            int v = g.px[i] & 255;
            argb[i] = 0xFF000000 | (v << 16) | (v << 8) | v;
        }
        return Bitmap.createBitmap(argb, g.w, g.h, Bitmap.Config.ARGB_8888);
    }

    public static int pageCount(File pdf) {
        try (PdfSource s = new PdfSource(pdf)) { return s.count(); }
        catch (Exception e) { return 0; }
    }

    /** 任务卡 / 文件卡的小缩略图。 */
    public static Bitmap thumb(File pdf, int width) {
        try (PdfSource s = new PdfSource(pdf)) {
            if (s.count() == 0) return null;
            GrayMath.Gray g = s.load(0);
            int h = Math.max(1, g.h * width / g.w);
            Bitmap full = toBitmap(g);
            Bitmap out = Bitmap.createScaledBitmap(full, width, h, true);
            full.recycle();
            return out;
        } catch (Exception e) { return null; }
    }

    public static GrayMath.Report processPdf(File in, File out, Progress cb) throws IOException {
        try (PdfSource src = new PdfSource(in)) { return process(src, out, cb); }
    }

    public static GrayMath.Report processImages(List<File> images, File out, Progress cb) throws IOException {
        try (ImageSource src = new ImageSource(images)) { return process(src, out, cb); }
    }

    private static GrayMath.Report process(Source src, File out, Progress cb) throws IOException {
        long t0 = System.currentTimeMillis();
        GrayMath.Report rep = new GrayMath.Report();
        int n = src.count();
        if (n == 0) { rep.passed = false; rep.problems.add("PDF / 图片无法渲染"); return rep; }

        File cache = new File(out.getParentFile(), ".engine-" + UUID.randomUUID().toString().substring(0, 8));
        if (!cache.mkdirs()) throw new IOException("无法创建临时目录");
        List<File> crops = new ArrayList<>();
        try {
            // ① 逐页分析：黑框 / 笔记画布 / 自适应 gamma（全批取中位）
            boolean frames = false;
            int canvasVotes = 0;
            List<Float> gammas = new ArrayList<>();
            for (int i = 0; i < n; i++) {
                GrayMath.Gray a = src.load(i);
                float[] f = GrayMath.features(a);
                if (f[0] > 0.25f || (f[1] - f[2]) < -15) frames = true;
                if (f[1] > 248 && (f[1] - f[2]) > 8) canvasVotes++;
                GrayMath.Gray fl = GrayMath.flatten(a);
                gammas.add(GrayMath.autoGamma(fl, GrayMath.photoMask(fl)));
                if (cb != null) cb.on("分析 " + (i + 1) + "/" + n);
            }
            GrayMath.Decisions dec = rep.decisions;
            dec.hasFrame = frames;
            dec.notesCanvas = canvasVotes >= Math.max(1, n / 2);
            Collections.sort(gammas);
            dec.gammaText = gammas.get(gammas.size() / 2);
            dec.gammaPhoto = Math.min(Math.max(dec.gammaText - 0.45f, 1.0f), 1.15f);

            // ② 逐页增强 + 裁边，裁后结果落盘；同时做笔画保留闸门
            double baseScale = Double.MAX_VALUE;
            List<Integer> widths = new ArrayList<>();
            for (int i = 0; i < n; i++) {
                GrayMath.Gray a = src.load(i);
                GrayMath.Enhanced e = GrayMath.enhance(a, dec.gammaText, dec.gammaPhoto);
                if (e.ghost > 0.004f) dec.showThrough = true;
                GrayMath.Gray img = dec.hasFrame ? GrayMath.stripFrame(e.image) : e.image;
                int[] box = GrayMath.cropBounds(img, dec.notesCanvas);
                GrayMath.Gray c = GrayMath.crop(img, box);
                float ret = GrayMath.strokeRetention(a, c, box);
                dec.retention.add(ret);
                if (ret < 0.97f) {
                    rep.passed = false;
                    rep.problems.add(String.format(java.util.Locale.US,
                            "第 %d 页笔画保留 %.1f%% < 97%%", i + 1, ret * 100));
                }
                File f = new File(cache, String.format(java.util.Locale.US, "page-%04d.bin", i));
                try (DataOutputStream dos = new DataOutputStream(new FileOutputStream(f))) {
                    dos.writeInt(c.w); dos.writeInt(c.h); dos.write(c.px);
                }
                crops.add(f);
                widths.add(c.w);
                boolean landscape = c.w >= c.h;
                double sw = landscape ? PdfWrite.A4_H : PdfWrite.A4_W;
                double sh = landscape ? PdfWrite.A4_W : PdfWrite.A4_H;
                baseScale = Math.min(baseScale, Math.min((sw - 2 * PdfWrite.INSET) / Math.max(1, c.w),
                        (sh - 2 * PdfWrite.INSET) / Math.max(1, c.h)));
                if (cb != null) cb.on("增强 " + (i + 1) + "/" + n);
            }
            double placedDPI = 72.0 / baseScale;
            if (placedDPI < 230) dec.upscale = Math.min(3f, Math.max(1f, (float) (300.0 / placedDPI)));
            double finalScale = baseScale / dec.upscale;
            List<Integer> mm = new ArrayList<>();
            for (int w : widths) mm.add(Math.round(w * (float) baseScale / 72f * 25.4f));
            Collections.sort(mm);
            dec.sheetWidthMM = mm.get(mm.size() / 2);

            // ③ 逐页读回、按需放大 + 单向锐化，流式写 PDF
            PdfWrite writer = new PdfWrite(out);
            try {
                for (int i = 0; i < n; i++) {
                    GrayMath.Gray g = readGray(crops.get(i));
                    if (dec.upscale != 1f) {
                        g = GrayMath.upsampleBilinear(g,
                                Math.max(1, Math.round(g.w * dec.upscale)),
                                Math.max(1, Math.round(g.h * dec.upscale)));
                        g = GrayMath.darkenOnlySharpen(g, 60);
                    }
                    writer.addGrayPage(g, finalScale);
                    if (cb != null) cb.on("校验 " + (i + 1) + "/" + n);
                }
            } finally { writer.close(); }

            rep.pages = n;
            rep.seconds = (System.currentTimeMillis() - t0) / 1000.0;
            return rep;
        } finally {
            for (File f : crops) if (f.exists()) f.delete();
            File[] left = cache.listFiles();
            if (left != null) for (File f : left) f.delete();
            cache.delete();
        }
    }

    private static GrayMath.Gray readGray(File f) throws IOException {
        try (DataInputStream dis = new DataInputStream(new FileInputStream(f))) {
            int w = dis.readInt(), h = dis.readInt();
            byte[] px = new byte[w * h];
            dis.readFully(px);
            return new GrayMath.Gray(w, h, px);
        }
    }

    /** 合并模式与 engine/Merge.swift 一致：0 分别保存 / 1 完全合并 / 2 间隔·双面补空白。 */
    public static int merge(List<File> inputs, int mode, File out, Progress cb) throws IOException {
        int total = 0;
        PdfWrite writer = new PdfWrite(out);
        try {
            for (int idx = 0; idx < inputs.size(); idx++) {
                File file = inputs.get(idx);
                if (!file.exists()) continue;
                try (PdfSource s = new PdfSource(file)) {
                    int n = s.count();
                    if (n == 0) continue;
                    if (cb != null) cb.on("合并 " + (idx + 1) + "/" + inputs.size());
                    double lastW = PdfWrite.A4_W, lastH = PdfWrite.A4_H;
                    for (int i = 0; i < n; i++) {
                        MergedPage g = s.loadPageForMerge(i);
                        lastW = g.mediaW; lastH = g.mediaH;
                        writer.addFullPage(g, g.mediaW, g.mediaH);
                        total++;
                    }
                    if (mode == 2 && idx < inputs.size() - 1 && n % 2 == 1) {
                        writer.addBlankPage(lastW, lastH);
                        total++;
                    }
                }
            }
        } finally { writer.close(); }
        return total;
    }

    /** 渲染 PDF 单页用于预览；页面超出 10 页时由调用方限制。 */
    public static List<Bitmap> previewPages(File pdf, int maxWidth, int maxPages) {
        List<Bitmap> out = new ArrayList<>();
        try (PdfSource s = new PdfSource(pdf)) {
            int n = Math.min(s.count(), maxPages);
            for (int i = 0; i < n; i++) {
                GrayMath.Gray g = s.load(i);
                int w = Math.min(maxWidth, g.w);
                int h = Math.max(1, g.h * w / g.w);
                Bitmap full = toBitmap(g);
                Bitmap scaled = Bitmap.createScaledBitmap(full, w, h, true);
                full.recycle();
                out.add(scaled);
            }
        } catch (Exception ignored) {}
        return out;
    }

    /** PdfRenderer 一页的灰度结果 + 原始 MediaBox（pt），供无损尺寸的合并使用。 */
    public static final class MergedPage extends GrayMath.Gray {
        public final double mediaW, mediaH;
        MergedPage(GrayMath.Gray g, double mediaW, double mediaH) {
            super(g.w, g.h, g.px);
            this.mediaW = mediaW; this.mediaH = mediaH;
        }
    }
}
