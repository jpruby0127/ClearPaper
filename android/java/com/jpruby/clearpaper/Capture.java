package com.jpruby.clearpaper;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Matrix;
import android.media.ExifInterface;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;

/**
 * 拍照链路的入口预处理：方向归一、页面指纹去重、几何找边 + 透视矫正。
 * 对应 ios/Capture.swift；Android 没有系统文档相机，因此找边全部由这段几何算法完成，
 * 找不到可靠纸边时直接用原图，绝不做猜测式裁剪（这正是 build 8 的教训）。
 */
public final class Capture {
    private Capture() {}
    private static final int MAX_SIDE = 2600;

    public static final class Signature {
        final byte[] gray;
        final long hash;
        Signature(byte[] gray, long hash) { this.gray = gray; this.hash = hash; }
    }

    private static int u(byte v) { return v & 0xFF; }

    /** 统一 EXIF 方向 + 限长边 2600px，写回 JPEG。下游不需要再猜方向。 */
    public static boolean normalize(File src, File dst) {
        // 相机直出的 JPEG 可能有 3000~4000px 长边，先按 inSampleSize 粗采样再解码，
        // 避免整张 48MB ARGB_8888 位图直接进内存（后面还会再缩到 2600）。
        BitmapFactory.Options bounds = new BitmapFactory.Options();
        bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeFile(src.getPath(), bounds);
        int side = Math.max(bounds.outWidth, bounds.outHeight);
        int sample = 1;
        while (side / sample > 3200) sample *= 2;
        BitmapFactory.Options o = new BitmapFactory.Options();
        o.inSampleSize = sample;
        o.inPreferredConfig = Bitmap.Config.ARGB_8888;
        Bitmap bm = BitmapFactory.decodeFile(src.getPath(), o);
        if (bm == null) return false;
        Bitmap cur = upright(bm, exifDegrees(src));
        if (cur != bm) bm.recycle();
        try {
            int curSide = Math.max(cur.getWidth(), cur.getHeight());
            if (curSide > MAX_SIDE) {
                float k = (float) MAX_SIDE / curSide;
                Bitmap small = Bitmap.createScaledBitmap(cur,
                        Math.max(1, Math.round(cur.getWidth() * k)),
                        Math.max(1, Math.round(cur.getHeight() * k)), true);
                cur.recycle();
                cur = small;
            }
            return save(cur, dst, 90);
        } finally { cur.recycle(); }
    }

    public static Bitmap decode(File src) {
        BitmapFactory.Options o = new BitmapFactory.Options();
        o.inPreferredConfig = Bitmap.Config.ARGB_8888;
        return BitmapFactory.decodeFile(src.getPath(), o);
    }

    private static int exifDegrees(File f) {
        try {
            ExifInterface e = new ExifInterface(f.getPath());
            int o = e.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL);
            if (o == ExifInterface.ORIENTATION_ROTATE_90) return 90;
            if (o == ExifInterface.ORIENTATION_ROTATE_180) return 180;
            if (o == ExifInterface.ORIENTATION_ROTATE_270) return 270;
        } catch (Exception ignored) {}
        return 0;
    }

    private static Bitmap upright(Bitmap bm, int deg) {
        if (deg == 0) return bm;
        Matrix m = new Matrix();
        m.postRotate(deg);
        return Bitmap.createBitmap(bm, 0, 0, bm.getWidth(), bm.getHeight(), m, true);
    }

    public static Bitmap rotated(Bitmap bm, int degrees) {
        int d = ((degrees % 360) + 360) % 360;
        if (d == 0) return bm;
        Matrix m = new Matrix();
        m.postRotate(d);
        return Bitmap.createBitmap(bm, 0, 0, bm.getWidth(), bm.getHeight(), m, true);
    }

    /** 按用户选的角度真正重绘并落盘，供引擎读取。 */
    public static boolean rotatedFile(File src, int degrees, File dst) {
        Bitmap bm = decode(src);
        if (bm == null) return false;
        Bitmap out = rotated(bm, degrees);
        if (out != bm) bm.recycle();
        boolean ok = save(out, dst, 92);
        out.recycle();
        return ok;
    }

    public static boolean save(Bitmap bm, File dst, int quality) {
        File parent = dst.getParentFile();
        if (parent != null) parent.mkdirs();
        try (FileOutputStream fos = new FileOutputStream(dst)) {
            return bm.compress(Bitmap.CompressFormat.JPEG, quality, fos);
        } catch (IOException e) { return false; }
    }

    public static Bitmap thumbnail(File src, int width) {
        BitmapFactory.Options p = new BitmapFactory.Options();
        p.inJustDecodeBounds = true;
        BitmapFactory.decodeFile(src.getPath(), p);
        int w = Math.max(1, p.outWidth), h = Math.max(1, p.outHeight);
        int sample = 1;
        while (w / sample > width * 2) sample *= 2;
        BitmapFactory.Options o = new BitmapFactory.Options();
        o.inSampleSize = sample;
        o.inPreferredConfig = Bitmap.Config.ARGB_8888;
        Bitmap bm = BitmapFactory.decodeFile(src.getPath(), o);
        if (bm == null) return null;
        int tw = width, th = Math.max(1, h * width / w);
        Bitmap out = Bitmap.createScaledBitmap(bm, tw, th, true);
        if (out != bm) bm.recycle();
        return out;
    }

    private static byte[] gray(Bitmap bm, int w, int h) {
        Bitmap s = Bitmap.createScaledBitmap(bm, w, h, true);
        int[] argb = new int[w * h];
        s.getPixels(argb, 0, w, 0, 0, w, h);
        byte[] out = new byte[w * h];
        for (int i = 0; i < argb.length; i++) {
            int c = argb[i];
            out[i] = (byte) ((((c >> 16) & 255) * 77 + ((c >> 8) & 255) * 150 + (c & 255) * 29) >> 8);
        }
        if (s != bm) s.recycle();
        return out;
    }

    /** 32×32 灰度 + 64 位 dHash：系统相机来不及翻页拍重的页靠它剔除。 */
    public static Signature signature(Bitmap bm) {
        byte[] g = gray(bm, 32, 32);
        byte[] small = new byte[9 * 8];
        for (int y = 0; y < 8; y++) {
            for (int x = 0; x < 9; x++) {
                int x0 = x * 32 / 9, x1 = Math.max(x0 + 1, (x + 1) * 32 / 9);
                int sum = 0, n = 0;
                for (int yy = y * 4; yy < (y + 1) * 4; yy++) {
                    for (int xx = x0; xx < Math.min(32, x1); xx++) { sum += u(g[yy * 32 + xx]); n++; }
                }
                small[y * 9 + x] = (byte) (sum / Math.max(1, n));
            }
        }
        long hsh = 0;
        for (int y = 0; y < 8; y++) for (int x = 0; x < 8; x++) {
            if (u(small[y * 9 + x]) > u(small[y * 9 + x + 1])) hsh |= (1L << (y * 8 + x));
        }
        return new Signature(g, hsh);
    }

    private static int distance(long a, long b) { return Long.bitCount(a ^ b); }

    private static int meanDiff(byte[] a, byte[] b) {
        if (a.length != b.length || a.length == 0) return 255;
        int s = 0;
        for (int i = 0; i < a.length; i++) s += Math.abs(u(a[i]) - u(b[i]));
        return s / a.length;
    }

    /** 两档阈值：相邻页宽松（手抖/曝光差），非相邻页严格（版式相近不误删）。 */
    public static boolean isDuplicate(Signature s, java.util.List<Signature> kept) {
        if (!kept.isEmpty()) {
            Signature last = kept.get(kept.size() - 1);
            if (distance(last.hash, s.hash) <= 10 && meanDiff(last.gray, s.gray) <= 9) return true;
        }
        for (Signature k : kept)
            if (distance(k.hash, s.hash) <= 5 && meanDiff(k.gray, s.gray) <= 5) return true;
        return false;
    }

    /** 四周明显暗于纸面中心 = 仍带桌面背景，需要补一次找边矫正。 */
    public static boolean needsRectify(Bitmap bm) {
        byte[] g = gray(bm, 64, 64);
        int edge = 0, edgeN = 0, center = 0, centerN = 0, b = 4;
        for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) {
            int v = u(g[y * 64 + x]);
            if (x < b || x >= 64 - b || y < b || y >= 64 - b) { edge += v; edgeN++; }
            if (x >= 21 && x < 43 && y >= 21 && y < 43) { center += v; centerN++; }
        }
        return center / Math.max(1, centerN) - edge / Math.max(1, edgeN) > 32;
    }

    private static int otsu(byte[] g) {
        int[] hist = new int[256];
        for (byte v : g) hist[u(v)]++;
        int total = g.length, sumAll = 0;
        for (int i = 0; i < 256; i++) sumAll += i * hist[i];
        int wB = 0, sumB = 0, thr = 190;
        double best = -1;
        for (int t = 0; t < 256; t++) {
            wB += hist[t];
            if (wB == 0) continue;
            int wF = total - wB;
            if (wF == 0) break;
            sumB += t * hist[t];
            double mB = (double) sumB / wB, mF = (double) (sumAll - sumB) / wF;
            double between = wB * (double) wF * (mB - mF) * (mB - mF);
            if (between > best) { best = between; thr = t; }
        }
        return thr;
    }

    /**
     * 不依赖任何模型的几何找边：亮纸 + 暗背景时逐行找最长亮段，
     * 最小二乘拟合左右两条纸边，再取上下边界。返回归一化四角（左上原点）。
     */
    public static float[] geometricQuad(Bitmap bm) {
        int W = 160;
        int H = Math.max(120, (int) (W * (float) bm.getHeight() / bm.getWidth()));
        byte[] g = gray(bm, W, H);
        int bw = Math.max(2, W / 25), bh = Math.max(2, H / 25);
        int border = (mean(g, W, 0, 0, W, bh) + mean(g, W, 0, H - bh, W, H)
                + mean(g, W, 0, 0, bw, H) + mean(g, W, W - bw, 0, W, H)) / 4;
        int center = mean(g, W, W / 3, H / 3, 2 * W / 3, 2 * H / 3);
        if (center - border <= 35) return null;

        int thr = otsu(g);
        java.util.List<int[]> raw = new java.util.ArrayList<>();
        for (int y = (int) (0.05 * H); y < (int) (0.95 * H); y += 2) {
            int best = 0, bestStart = 0, start = -1;
            for (int x = 0; x < W; x++) {
                if (u(g[y * W + x]) > thr) { if (start < 0) start = x; }
                else if (start >= 0) {
                    if (x - start > best) { best = x - start; bestStart = start; }
                    start = -1;
                }
            }
            if (start >= 0 && W - start > best) { best = W - start; bestStart = start; }
            if (best >= W / 4) raw.add(new int[]{y, bestStart, bestStart + best});
        }
        if (raw.size() < 12) return null;
        int[] widths = new int[raw.size()];
        for (int i = 0; i < widths.length; i++) widths[i] = raw.get(i)[2] - raw.get(i)[1];
        int[] sorted = widths.clone();
        java.util.Arrays.sort(sorted);
        int medW = sorted[sorted.length / 2];
        if (medW <= W / 5 || medW >= W * 95 / 100) return null;
        java.util.List<int[]> good = new java.util.ArrayList<>();
        for (int[] r : raw) if (Math.abs((r[2] - r[1]) - medW) <= Math.max(8, medW / 4)) good.add(r);
        if (good.size() < 10) return null;

        double[] L = fit(good, true), R = fit(good, false);
        double yT = good.get(0)[0], yB = good.get(good.size() - 1)[0];
        double lT = L[0] * yT + L[1], rT = R[0] * yT + R[1];
        double lB = L[0] * yB + L[1], rB = R[0] * yB + R[1];
        if (rT - lT <= W / 5.0 || rB - lB <= W / 5.0) return null;
        double area = ((rT - lT + rB - lB) / 2) * (yB - yT) / (double) (W * H);
        if (area <= 0.15 || area >= 0.97) return null;
        double minX = Math.min(Math.min(lT, rT), Math.min(lB, rB));
        double maxX = Math.max(Math.max(lT, rT), Math.max(lB, rB));
        double minY = Math.min(yT, yB), maxY = Math.max(yT, yB);
        if (minX < 0 || minY < 0 || maxX > W || maxY > H) {
            // 拟合略微越界时夹回画面内，避免采样到空像素
            lT = clamp(lT, 0, W); rT = clamp(rT, 0, W);
            lB = clamp(lB, 0, W); rB = clamp(rB, 0, W);
        }
        return new float[]{(float) (lT / W), (float) (yT / H),   // tl
                (float) (rT / W), (float) (yT / H),               // tr
                (float) (rB / W), (float) (yB / H),               // br
                (float) (lB / W), (float) (yB / H)};              // bl
    }

    private static double clamp(double v, double lo, double hi) { return Math.max(lo, Math.min(hi, v)); }

    private static int mean(byte[] g, int W, int x0, int y0, int x1, int y1) {
        int s = 0, n = 0;
        for (int y = y0; y < y1; y++) for (int x = x0; x < x1; x++) { s += u(g[y * W + x]); n++; }
        return n > 0 ? s / n : 0;
    }

    /** 最小二乘拟合 x = a*y + b。 */
    private static double[] fit(java.util.List<int[]> rows, boolean left) {
        double sy = 0, sx = 0, sxy = 0, syy = 0, n = rows.size();
        for (int[] r : rows) {
            double yy = r[0], xx = left ? r[1] : r[2];
            sy += yy; sx += xx; sxy += xx * yy; syy += yy * yy;
        }
        double den = n * syy - sy * sy;
        if (Math.abs(den) < 0.0001) return new double[]{0, sx / n};
        double a = (n * sxy - sy * sx) / den;
        return new double[]{a, (sx - a * sy) / n};
    }

    private static double dist(float[] q, int a, int b, float w, float h) {
        return Math.hypot((q[a * 2] - q[b * 2]) * w, (q[a * 2 + 1] - q[b * 2 + 1]) * h);
    }

    /** 找边 + 透视矫正；写入 dst，返回是否真的裁过。找不到可靠纸边时返回 false。 */
    public static boolean rectify(File src, File dst) {
        Bitmap bm = decode(src);
        if (bm == null) return false;
        float[] q0 = geometricQuad(bm);
        if (q0 == null) { bm.recycle(); return false; }
        float w = bm.getWidth(), h = bm.getHeight();
        // 四角向纸心内收 2%，避免插值把纸外桌面拖成淡灰虚线
        float cx = 0, cy = 0;
        for (int i = 0; i < 4; i++) { cx += q0[i * 2]; cy += q0[i * 2 + 1]; }
        cx /= 4; cy /= 4;
        float[] q = q0.clone();
        for (int i = 0; i < 4; i++) {
            q[i * 2] += (cx - q[i * 2]) * 0.02f;
            q[i * 2 + 1] += (cy - q[i * 2 + 1]) * 0.02f;
        }
        double bw = (dist(q, 0, 1, w, h) + dist(q, 3, 2, w, h)) / 2;
        double bh = (dist(q, 0, 3, w, h) + dist(q, 1, 2, w, h)) / 2;
        double ratio = bw / Math.max(1, bh);
        double area = (bw * bh) / (w * h);
        if (bw < 200 || bh < 200 || ratio < 0.30 || ratio > 3.4 || area < 0.16 || area > 0.965) {
            bm.recycle();
            return false;
        }
        double k = Math.min(1, (double) MAX_SIDE / Math.max(bw, bh));
        int ow = Math.max(1, (int) Math.round(bw * k)), oh = Math.max(1, (int) Math.round(bh * k));
        double[] inv = homography(q, w, h, ow, oh);
        if (inv == null) { bm.recycle(); return false; }
        Bitmap out = warp(bm, inv, ow, oh);
        bm.recycle();
        if (out == null) return false;
        boolean ok = save(out, dst, 92);
        out.recycle();
        return ok;
    }

    /** 解 8×8：目标矩形像素 (x,y) -> 源图四边形内的像素 (u,v)。 */
    private static double[] homography(float[] q, double sw, double sh, int ow, int oh) {
        double[][] a = new double[8][9];
        double[] dx = {0, ow, ow, 0}, dy = {0, 0, oh, oh};
        for (int i = 0; i < 4; i++) {
            double x = dx[i], y = dy[i];
            double u = q[i * 2] * sw, v = q[i * 2 + 1] * sh;
            double[] r0 = a[i * 2], r1 = a[i * 2 + 1];
            r0[0] = x; r0[1] = y; r0[2] = 1; r0[6] = -x * u; r0[7] = -y * u; r0[8] = u;
            r1[3] = x; r1[4] = y; r1[5] = 1; r1[6] = -x * v; r1[7] = -y * v; r1[8] = v;
        }
        // 高斯消元（列主元）
        for (int c = 0; c < 8; c++) {
            int pivot = c;
            for (int r = c + 1; r < 8; r++) if (Math.abs(a[r][c]) > Math.abs(a[pivot][c])) pivot = r;
            if (Math.abs(a[pivot][c]) < 1e-9) return null;
            double[] t = a[c]; a[c] = a[pivot]; a[pivot] = t;
            double pv = a[c][c];
            for (int j = c; j < 9; j++) a[c][j] /= pv;
            for (int r = 0; r < 8; r++) {
                if (r == c) continue;
                double f = a[r][c];
                if (f == 0) continue;
                for (int j = c; j < 9; j++) a[r][j] -= f * a[c][j];
            }
        }
        double[] out = new double[8];
        for (int i = 0; i < 8; i++) out[i] = a[i][8];
        return out;
    }

    private static Bitmap warp(Bitmap src, double[] m, int ow, int oh) {
        int sw = src.getWidth(), sh = src.getHeight();
        int[] sp = new int[sw * sh];
        src.getPixels(sp, 0, sw, 0, 0, sw, sh);
        int[] dp = new int[ow * oh];
        for (int y = 0; y < oh; y++) {
            for (int x = 0; x < ow; x++) {
                double den = m[6] * x + m[7] * y + 1;
                double u = (m[0] * x + m[1] * y + m[2]) / den;
                double v = (m[3] * x + m[4] * y + m[5]) / den;
                int x0 = (int) Math.floor(u), y0 = (int) Math.floor(v);
                float tx = (float) (u - x0), ty = (float) (v - y0);
                if (x0 < 0 || y0 < 0 || x0 + 1 >= sw || y0 + 1 >= sh) {
                    dp[y * ow + x] = 0xFFFFFFFF;
                    continue;
                }
                int r0 = y0 * sw + x0, r1 = r0 + sw;
                int c00 = sp[r0], c10 = sp[r0 + 1], c01 = sp[r1], c11 = sp[r1 + 1];
                int a = 0;
                for (int shft = 0; shft < 4; shft++) {
                    int bits = shft * 8;
                    int p00 = (c00 >> bits) & 255, p10 = (c10 >> bits) & 255;
                    int p01 = (c01 >> bits) & 255, p11 = (c11 >> bits) & 255;
                    int top = Math.round(p00 + (p10 - p00) * tx);
                    int bot = Math.round(p01 + (p11 - p01) * tx);
                    a |= (Math.round(top + (bot - top) * ty) & 255) << bits;
                }
                dp[y * ow + x] = a | 0xFF000000;
            }
        }
        return Bitmap.createBitmap(dp, ow, oh, Bitmap.Config.ARGB_8888);
    }
}
