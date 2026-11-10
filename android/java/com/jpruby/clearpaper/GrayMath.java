package com.jpruby.clearpaper;

import java.util.ArrayList;
import java.util.List;

/**
 * ClearPaper 清理引擎：engine/Core.swift 的等价 Java 移植。
 * 纯 Java、无 android.* 依赖，因此可以脱离模拟器在 JVM 上跑回归测试。
 * 全链路：白场归一 -> 去背面透印 -> 自适应 gamma -> 单向锐化 -> 裁边 -> A4 -> 笔画闸门。
 */
public final class GrayMath {
    private GrayMath() {}

    /** 8-bit 灰度图。byte 是有符号的，读取一律用 (px[i] & 0xFF)。 */
    public static class Gray {
        public final int w, h;
        public final byte[] px;
        public Gray(int w, int h, byte[] px) { this.w = w; this.h = h; this.px = px; }
        public Gray(int w, int h) { this(w, h, new byte[w * h]); }
        public static Gray white(int w, int h) {
            byte[] p = new byte[w * h];
            java.util.Arrays.fill(p, (byte) 255);
            return new Gray(w, h, p);
        }
    }

    public static final class Decisions {
        public float gammaText = 1.45f, gammaPhoto = 1.00f;
        public boolean hasFrame, notesCanvas, showThrough;
        public float upscale = 1f, sheetWidthMM;
        public final List<Float> retention = new ArrayList<>();
    }

    public static final class Report {
        public int pages;
        public final Decisions decisions = new Decisions();
        public double seconds;
        public boolean passed = true;
        public final List<String> problems = new ArrayList<>();
    }

    public static final class Enhanced {
        public final Gray image;
        public final float ghost;
        Enhanced(Gray image, float ghost) { this.image = image; this.ghost = ghost; }
    }

    /** 去背面透印开关，由「处理选项」控制。 */
    public static volatile boolean deghostEnabled = true;

    private static int u(byte v) { return v & 0xFF; }
    private static byte b(int v) { return (byte) (v < 0 ? 0 : (v > 255 ? 255 : v)); }
    private static int clamp255(int v) { return v < 0 ? 0 : (v > 255 ? 255 : v); }

    // MARK: primitives

    public static Gray downsampleMean(Gray a, int factor) {
        int sw = Math.max(2, a.w / factor), sh = Math.max(2, a.h / factor);
        Gray o = new Gray(sw, sh);
        for (int y = 0; y < sh; y++) {
            int y0 = y * factor, y1 = Math.min(a.h, y0 + factor);
            for (int x = 0; x < sw; x++) {
                int x0 = x * factor, x1 = Math.min(a.w, x0 + factor);
                int sum = 0, n = 0;
                for (int yy = y0; yy < y1; yy++) {
                    int row = yy * a.w;
                    for (int xx = x0; xx < x1; xx++) { sum += u(a.px[row + xx]); n++; }
                }
                o.px[y * sw + x] = b(sum / Math.max(1, n));
            }
        }
        return o;
    }

    public static Gray median3x3(Gray a, int passes) {
        byte[] cur = a.px.clone(), nxt = a.px.clone();
        int[] win = new int[9];
        for (int p = 0; p < passes; p++) {
            for (int y = 0; y < a.h; y++) {
                int ym = Math.max(y - 1, 0) * a.w, yr = y * a.w, yp = Math.min(y + 1, a.h - 1) * a.w;
                for (int x = 0; x < a.w; x++) {
                    int xm = Math.max(x - 1, 0), xp = Math.min(x + 1, a.w - 1);
                    win[0] = u(cur[ym + xm]); win[1] = u(cur[ym + x]); win[2] = u(cur[ym + xp]);
                    win[3] = u(cur[yr + xm]); win[4] = u(cur[yr + x]); win[5] = u(cur[yr + xp]);
                    win[6] = u(cur[yp + xm]); win[7] = u(cur[yp + x]); win[8] = u(cur[yp + xp]);
                    java.util.Arrays.sort(win);
                    nxt[yr + x] = b(win[4]);
                }
            }
            byte[] t = cur; cur = nxt; nxt = t;
        }
        return new Gray(a.w, a.h, cur);
    }

    public static Gray upsampleBilinear(Gray a, int toW, int toH) {
        Gray o = new Gray(toW, toH);
        float fx = (float) Math.max(1, a.w - 1) / Math.max(1, toW - 1);
        float fy = (float) Math.max(1, a.h - 1) / Math.max(1, toH - 1);
        for (int y = 0; y < toH; y++) {
            float sy = y * fy;
            int y0 = (int) sy, y1 = Math.min(a.h - 1, y0 + 1);
            float ty = sy - y0;
            int r0 = y0 * a.w, r1 = y1 * a.w, ro = y * toW;
            for (int x = 0; x < toW; x++) {
                float sx = x * fx;
                int x0 = (int) sx, x1 = Math.min(a.w - 1, x0 + 1);
                float tx = sx - x0;
                float v0 = u(a.px[r0 + x0]), v1 = u(a.px[r0 + x1]);
                float v2 = u(a.px[r1 + x0]), v3 = u(a.px[r1 + x1]);
                float top = v0 + (v1 - v0) * tx, bot = v2 + (v3 - v2) * tx;
                o.px[ro + x] = b(Math.round(top + (bot - top) * ty));
            }
        }
        return o;
    }

    /** 可分离盒式模糊，滑窗求和 O(n)；多遍近似高斯。 */
    public static Gray boxBlur(Gray a, int radius, int passes) {
        byte[] cur = a.px.clone(), tmp = a.px.clone();
        int r = Math.max(1, radius), span = 2 * r + 1;
        for (int p = 0; p < passes; p++) {
            for (int y = 0; y < a.h; y++) {
                int row = y * a.w, acc = 0;
                for (int x = -r; x <= r; x++) acc += u(cur[row + Math.min(Math.max(x, 0), a.w - 1)]);
                for (int x = 0; x < a.w; x++) {
                    tmp[row + x] = b(acc / span);
                    acc += u(cur[row + Math.min(x + r + 1, a.w - 1)]) - u(cur[row + Math.max(x - r, 0)]);
                }
            }
            for (int x = 0; x < a.w; x++) {
                int acc = 0;
                for (int y = -r; y <= r; y++) acc += u(tmp[Math.min(Math.max(y, 0), a.h - 1) * a.w + x]);
                for (int y = 0; y < a.h; y++) {
                    cur[y * a.w + x] = b(acc / span);
                    acc += u(tmp[Math.min(y + r + 1, a.h - 1) * a.w + x])
                         - u(tmp[Math.max(y - r, 0) * a.w + x]);
                }
            }
        }
        return new Gray(a.w, a.h, cur);
    }

    public static byte[] gammaLUT(float gamma) {
        byte[] lut = new byte[256];
        for (int i = 0; i < 256; i++) {
            float v = Math.min(Math.max((i - 34f) * (255f / (244f - 34f)), 0), 255);
            lut[i] = b(Math.round(255f * (float) Math.pow(v / 255f, gamma)));
        }
        return lut;
    }

    // MARK: analysis

    /** {borderMax, ringMean, innerMean} */
    public static float[] features(Gray a) {
        int bd = Math.max(6, (int) (0.012f * Math.min(a.w, a.h)));
        int d = 0, n = 0;
        for (int i = 0; i < bd * a.w; i++) { if (u(a.px[i]) < 200) d++; n++; }
        float top = (float) d / Math.max(1, n);
        d = 0; n = 0;
        for (int i = (a.h - bd) * a.w; i < a.h * a.w; i++) { if (u(a.px[i]) < 200) d++; n++; }
        float bot = (float) d / Math.max(1, n);
        int ld = 0, rd = 0, ln = 0, ringN = 0;
        long ringSum = 0;
        for (int y = 0; y < a.h; y += 3) {
            int row = y * a.w;
            for (int x = 0; x < bd; x++) {
                int v = u(a.px[row + x]); if (v < 200) ld++; ringSum += v; ringN++;
            }
            for (int x = a.w - bd; x < a.w; x++) {
                int v = u(a.px[row + x]); if (v < 200) rd++; ringSum += v; ringN++;
            }
            ln += 2 * bd;
        }
        for (int x = 0; x < a.w; x++) {
            for (int y = 0; y < bd; y++) { ringSum += u(a.px[y * a.w + x]); ringN++; }
            for (int y = a.h - bd; y < a.h; y++) { ringSum += u(a.px[y * a.w + x]); ringN++; }
        }
        double innerSum = 0; int innerN = 0;
        for (int y = (int) (0.2f * a.h); y < (int) (0.8f * a.h); y += 6) {
            for (int x = (int) (0.2f * a.w); x < (int) (0.8f * a.w); x += 6) {
                innerSum += u(a.px[y * a.w + x]); innerN++;
            }
        }
        float borderMax = Math.max(Math.max(top, bot),
                Math.max((float) ld / Math.max(1, ln / 2), (float) rd / Math.max(1, ln / 2)));
        return new float[]{borderMax, (float) ringSum / Math.max(1, ringN),
                (float) (innerSum / Math.max(1, innerN))};
    }

    /** 4-连通标记 + 并查集。 */
    public static int[] label(Gray a, int thresh) {
        int total = a.px.length;
        int[] lab = new int[total];
        int[] parent = new int[Math.min(total / 8 + 16, 1 << 20)];
        int next = 0;
        for (int y = 0; y < a.h; y++) {
            int row = y * a.w;
            for (int x = 0; x < a.w; x++) {
                int i = row + x;
                if (u(a.px[i]) >= thresh) continue;
                int left = x > 0 && u(a.px[i - 1]) < thresh ? lab[i - 1] : 0;
                int up = y > 0 && u(a.px[i - a.w]) < thresh ? lab[i - a.w] : 0;
                if (left == 0 && up == 0) {
                    next++;
                    if (next >= parent.length) {
                        int[] bigger = new int[Math.min(parent.length * 2, 1 << 23)];
                        System.arraycopy(parent, 0, bigger, 0, parent.length);
                        parent = bigger;
                    }
                    parent[next] = next; lab[i] = next;
                } else if (left != 0 && up != 0) {
                    lab[i] = Math.min(left, up);
                    if (left != up) {
                        int rl = find(parent, left), ru = find(parent, up);
                        parent[Math.max(rl, ru)] = Math.min(rl, ru);
                    }
                } else {
                    lab[i] = left != 0 ? left : up;
                }
            }
        }
        for (int i = 0; i < total; i++) if (lab[i] > 0) lab[i] = find(parent, lab[i]);
        return lab;
    }

    private static int find(int[] parent, int x) {
        int r = x;
        while (parent[r] != r) r = parent[r];
        int c = x;
        while (parent[c] != r) { int n = parent[c]; parent[c] = r; c = n; }
        return r;
    }

    static boolean[] strokeMask(Gray f, Gray photo, int thresh, int minArea) {
        int[] lab = label(f, thresh);
        int max = 0;
        for (int v : lab) if (v > max) max = v;
        int[] counts = new int[max + 1];
        for (int v : lab) if (v > 0) counts[v]++;
        boolean[] mask = new boolean[f.px.length];
        int ex = (int) (0.02f * f.w), ey = (int) (0.02f * f.h);
        for (int i = 0; i < f.px.length; i++) {
            int l = lab[i];
            if (l == 0 || counts[l] < minArea) continue;
            int x = i % f.w, y = i / f.w;
            if (x < ex || y < ey || x >= f.w - ex || y >= f.h - ey) continue;
            if (u(photo.px[i]) > 127) continue;
            mask[i] = true;
        }
        return mask;
    }

    public static boolean[] strokeMask(Gray f, Gray photo) { return strokeMask(f, photo, 190, 15); }

    public static Gray photoMask(Gray f, int block) {
        int bw = Math.max(1, f.w / block), bh = Math.max(1, f.h / block);
        Gray frac = new Gray(bw, bh);
        for (int by = 0; by < bh; by++) {
            int y0 = by * block, y1 = Math.min(f.h, y0 + block);
            for (int bx = 0; bx < bw; bx++) {
                int x0 = bx * block, x1 = Math.min(f.w, x0 + block), mid = 0, n = 0;
                for (int y = y0; y < y1; y++) {
                    int row = y * f.w;
                    for (int x = x0; x < x1; x++) {
                        int v = u(f.px[row + x]);
                        if (v > 90 && v < 225) mid++;
                        n++;
                    }
                }
                float r = (float) mid / Math.max(1, n);
                frac.px[by * bw + bx] = b(Math.round(Math.min(Math.max((r - 0.30f) / 0.30f, 0), 1) * 255));
            }
        }
        Gray up = upsampleBilinear(frac, f.w, f.h);
        return boxBlur(up, block * 2 / 3, 2);
    }

    public static Gray photoMask(Gray f) { return photoMask(f, 48); }

    /** 白场归一：用 24px 网格的背景亮度把不均匀光照拉平。 */
    public static Gray flatten(Gray a) {
        Gray small = downsampleMean(a, 24);
        Gray med = median3x3(small, 2);
        Gray bg = upsampleBilinear(med, a.w, a.h);
        Gray o = new Gray(a.w, a.h, a.px.clone());
        for (int i = 0; i < o.px.length; i++) {
            int back = Math.max(u(bg.px[i]), 150);
            o.px[i] = b(Math.min(255, u(a.px[i]) * 255 / back));
        }
        return o;
    }

    /** 刚好能把真实笔画压到黑的最小 gamma（中位数 <= 105）。 */
    public static float autoGamma(Gray f, Gray photo) {
        boolean[] mask = strokeMask(f, photo);
        int count = 0;
        for (boolean m : mask) if (m) count++;
        if (count <= 500) return 1.30f;
        byte[] vals = new byte[count];
        int k = 0;
        for (int i = 0; i < mask.length; i++) if (mask[i]) vals[k++] = f.px[i];
        java.util.Arrays.sort(vals);
        double lv = Math.min(Math.max((u(vals[count / 2]) - 34) * (255.0 / 210.0), 0), 255) / 255.0;
        for (float g = 1.30f; g <= 1.9001f; g += 0.04f) {
            if (Math.pow(lv, g) * 255.0 <= 95.0) return g;
        }
        return 1.90f;
    }

    public static Enhanced enhance(Gray a, float gammaText, float gammaPhoto) {
        Gray f0 = flatten(a);
        Gray m = photoMask(f0);
        Enhanced d = deghost(f0, m);
        Gray f = d.image;
        byte[] lutT = gammaLUT(gammaText), lutP = gammaLUT(gammaPhoto);
        Gray smooth = boxBlur(f, 1, 1);
        byte[] out = new byte[f.px.length];
        for (int i = 0; i < out.length; i++) {
            float mv = u(m.px[i]) / 255f;
            float base = u(f.px[i]) * (1 - mv) + u(smooth.px[i]) * mv;
            int bi = clamp255(Math.round(base));
            out[i] = b(Math.round(u(lutT[bi]) * (1 - mv) + u(lutP[bi]) * mv));
        }
        // 只加深、绝不提亮的单向锐化：浅笔画不会被洗掉
        Gray blur = boxBlur(new Gray(f.w, f.h, out), 2, 1);
        for (int i = 0; i < out.length; i++) {
            int dd = u(out[i]) - u(blur.px[i]);
            if (dd < -4) out[i] = b(Math.max(0, u(out[i]) + dd * 130 / 100));
        }
        return new Enhanced(new Gray(f.w, f.h, out), d.ghost);
    }

    /**
     * 背面透印抑制：透印墨只比纸白暗一点点且是细笔画，加对比度会一起变深。
     * 把 196~252 这一段孤立的浅灰抹回纸白，但用局部密度守住成片浅灰底纹，
     * 跳过照片区域，且真实墨迹 3px 内一律不动。
     */
    public static Enhanced deghost(Gray a, Gray photo) {
        if (!deghostEnabled) return new Enhanced(a, 0);
        byte[] ink = new byte[a.px.length];
        for (int i = 0; i < a.px.length; i++) if (u(a.px[i]) < 120) ink[i] = (byte) 255;
        Gray nearInk = boxBlur(new Gray(a.w, a.h, ink), 3, 1);

        byte[] mask = new byte[a.px.length];
        int hits = 0;
        for (int i = 0; i < a.px.length; i++) {
            int v = u(a.px[i]);
            if (v > 196 && v < 252 && u(photo.px[i]) < 96 && u(nearInk.px[i]) < 8) {
                mask[i] = (byte) 255; hits++;
            }
        }
        if (hits <= Math.max(1200, a.px.length / 500)) return new Enhanced(a, 0);

        Gray dens = boxBlur(new Gray(a.w, a.h, mask), 9, 1);
        Gray soft = boxBlur(new Gray(a.w, a.h, mask), 1, 1);
        byte[] out = a.px.clone();
        int removed = 0;
        for (int i = 0; i < out.length; i++) {
            if (mask[i] == 0) continue;
            if (u(dens.px[i]) > 209) continue;      // 成片浅灰，保留
            float alpha = u(soft.px[i]) / 255f;
            out[i] = b(Math.round(u(out[i]) * (1 - alpha) + 255 * alpha));
            removed++;
        }
        return new Enhanced(new Gray(a.w, a.h, out), (float) removed / Math.max(1, out.length));
    }

    private static int[] paperSpanX(Gray a, float thr) {
        float[] colMean = new float[a.w];
        for (int x = 0; x < a.w; x++) {
            int s = 0, n = 0;
            for (int y = 0; y < a.h; y += 4) { s += u(a.px[y * a.w + x]); n++; }
            colMean[x] = (float) s / Math.max(1, n);
        }
        byte[] row = new byte[a.w];
        for (int x = 0; x < a.w; x++) row[x] = b(Math.round(colMean[x]));
        Gray sm = boxBlur(new Gray(a.w, 1, row), 12, 1);
        boolean[] m = new boolean[a.w];
        for (int x = 0; x < a.w; x++) m[x] = u(sm.px[x]) < thr;
        int i = 0;
        while (i < m.length) {
            if (m[i]) {
                int j = i;
                while (j + 1 < m.length) {
                    if (m[j + 1]) { j++; continue; }
                    int g = 0;
                    while (j + 1 + g < m.length && !m[j + 1 + g]) g++;
                    if (g > 0 && g <= 41 && j + 1 + g < m.length && m[j + 1 + g]) {
                        for (int k = j + 1; k < j + 1 + g; k++) m[k] = true;
                        j += 1 + g;
                    } else break;
                }
                i = j + 1;
            } else i++;
        }
        int c = m.length / 2;
        if (c >= m.length || !m[c]) {
            int best = -1, bestD = Integer.MAX_VALUE;
            for (int k = 0; k < m.length; k++) if (m[k] && Math.abs(k - c) < bestD) { best = k; bestD = Math.abs(k - c); }
            if (best < 0) return null;
            c = best;
        }
        int lo = c, hi = c;
        while (lo > 0 && m[lo - 1]) lo--;
        while (hi < m.length - 1 && m[hi + 1]) hi++;
        return new int[]{lo, hi + 1};
    }

    /** {x0, x1, y0, y1} */
    public static int[] cropBounds(Gray a, boolean notesCanvas) {
        float[] rows = new float[a.h], cols = new float[a.w];
        for (int y = 0; y < a.h; y++) {
            int c = 0, row = y * a.w;
            for (int x = 0; x < a.w; x++) if (u(a.px[row + x]) < 200) c++;
            rows[y] = (float) c / a.w;
        }
        for (int x = 0; x < a.w; x++) {
            int c = 0;
            for (int y = 0; y < a.h; y += 2) if (u(a.px[y * a.w + x]) < 200) c++;
            cols[x] = (float) c / (a.h / 2f);
        }
        int ry0 = -1, ry1 = -1, rx0 = -1, rx1 = -1;
        for (int i = 0; i < a.h; i++) if (rows[i] > 0.0015f) { if (ry0 < 0) ry0 = i; ry1 = i; }
        for (int i = 0; i < a.w; i++) if (cols[i] > 0.0015f) { if (rx0 < 0) rx0 = i; rx1 = i; }
        if (ry0 < 0 || rx0 < 0) return new int[]{0, a.w, 0, a.h};
        int x0 = rx0, x1 = rx1 + 1;
        if (notesCanvas) {
            int[] p = paperSpanX(a, 250.5f);
            if (p != null) { x0 = Math.min(x0, p[0]); x1 = Math.max(x1, p[1]); }
        }
        int padx = (int) (0.018f * a.w), pady = (int) (0.014f * a.h);
        x0 = Math.max(0, x0 - padx); x1 = Math.min(a.w, x1 + padx);
        int y0 = Math.max(0, ry0 - pady), y1 = Math.min(a.h, ry1 + 1 + pady);
        if (x1 - x0 >= (int) (0.985f * a.w) && y1 - y0 >= (int) (0.985f * a.h))
            return new int[]{0, a.w, 0, a.h};
        return new int[]{x0, x1, y0, y1};
    }

    public static Gray crop(Gray a, int[] box) {
        int w = box[1] - box[0], h = box[3] - box[2];
        Gray o = new Gray(w, h);
        for (int y = 0; y < h; y++)
            System.arraycopy(a.px, (box[2] + y) * a.w + box[0], o.px, y * w, w);
        return o;
    }

    /** 输出中还剩多少源图的真实笔画；低于 97% 判失败，不静默出坏结果。 */
    public static float strokeRetention(Gray src, Gray out, int[] box) {
        Gray f = flatten(src);
        boolean[] mask = strokeMask(f, photoMask(f));
        int cw = Math.max(1, box[1] - box[0]), ch = Math.max(1, box[3] - box[2]);
        float sx = (float) out.w / cw, sy = (float) out.h / ch;
        int total = 0, kept = 0;
        for (int i = 0; i < mask.length; i++) {
            if (!mask[i]) continue;
            int x = i % src.w, y = i / src.w;
            if (x < box[0] || x >= box[1] || y < box[2] || y >= box[3]) continue;
            total++;
            int ox = Math.min(out.w - 1, (int) ((x - box[0]) * sx));
            int oy = Math.min(out.h - 1, (int) ((y - box[2]) * sy));
            if (u(out.px[oy * out.w + ox]) < 215) kept++;
        }
        if (total <= 500) return 1f;
        return (float) kept / total;
    }

    /** 贴着纸边的黑框：从外往内逐条涂白。 */
    public static Gray stripFrame(Gray a) {
        byte[] out = a.px.clone();
        int step = 6, mx = (int) (0.09f * Math.min(a.w, a.h));
        int r = 0;
        while (r < mx && r + step <= a.h && darkFrac(out, a, 0, a.w, r, r + step) > 0.30f) {
            for (int y = r; y < r + step; y++) for (int x = 0; x < a.w; x++) out[y * a.w + x] = (byte) 255;
            r += step;
        }
        r = 0;
        while (r < mx && a.h - step - r >= 0 && r + step <= a.h
                && darkFrac(out, a, 0, a.w, a.h - step - r, a.h - r) > 0.30f) {
            for (int y = a.h - step - r; y < a.h - r; y++) for (int x = 0; x < a.w; x++) out[y * a.w + x] = (byte) 255;
            r += step;
        }
        r = 0;
        while (r < mx && r + step <= a.w && darkFrac(out, a, r, r + step, 0, a.h) > 0.30f) {
            for (int y = 0; y < a.h; y++) for (int x = r; x < r + step; x++) out[y * a.w + x] = (byte) 255;
            r += step;
        }
        r = 0;
        while (r < mx && a.w - step - r >= 0 && r + step <= a.w
                && darkFrac(out, a, a.w - step - r, a.w - r, 0, a.h) > 0.30f) {
            for (int y = 0; y < a.h; y++) for (int x = a.w - step - r; x < a.w - r; x++) out[y * a.w + x] = (byte) 255;
            r += step;
        }
        return new Gray(a.w, a.h, out);
    }

    private static float darkFrac(byte[] px, Gray a, int x0, int x1, int y0, int y1) {
        int d = 0, n = 0;
        for (int y = y0; y < y1; y++) for (int x = x0; x < x1; x++) { if (u(px[y * a.w + x]) < 205) d++; n++; }
        return (float) d / Math.max(1, n);
    }

    public static Gray darkenOnlySharpen(Gray g, int weight) {
        Gray blur = boxBlur(g, 2, 1);
        byte[] out = g.px.clone();
        for (int i = 0; i < out.length; i++) {
            int d = u(out[i]) - u(blur.px[i]);
            if (d < -4) out[i] = b(Math.max(0, u(out[i]) + d * weight / 100));
        }
        return new Gray(g.w, g.h, out);
    }
}
