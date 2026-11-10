import com.jpruby.clearpaper.GrayMath;
import com.jpruby.clearpaper.PdfWrite;

import java.io.File;
import java.util.Arrays;

/**
 * 纯 JVM 回归测试：扫描引擎与 PDF 写出不依赖 android.*，可在 Mac 上直接跑。
 * 造一张「带黑框 + 背面透印 + 光照不均 + 真实横线」的脏扫描页，
 * 走完整流程后输出 PDF，再用 PDFKit 校验页数 / 横竖 A4 / 渲染结果。
 *
 *   ./test/run_test.sh
 */
public final class EngineTest {
    private static GrayMath.Gray dirtyPage(int w, int h) {
        byte[] px = new byte[w * h];
        Arrays.fill(px, (byte) 255);
        // 不均匀光照：左侧整体偏暗 18
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
            int v = 255 - (x < w / 2 ? 18 : 0);
            px[y * w + x] = (byte) v;
        }
        // 四周黑框
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
            if (x < 40 || x >= w - 40 || y < 60 || y >= h - 60) px[y * w + x] = (byte) 55;
        }
        // 真实笔画（16 条横线）
        for (int line = 0; line < 16; line++) {
            int y = 180 + line * 82;
            for (int t = 0; t < 4; t++)
                for (int x = 120; x < w - 120; x++) px[(y + t) * w + x] = (byte) 35;
        }
        // 背面透印：孤立的浅灰细笔画
        for (int line = 0; line < 14; line++) {
            int y = 230 + line * 82;
            for (int t = 0; t < 2; t++)
                for (int x = 260; x < w - 300; x++) px[(y + t) * w + x] = (byte) 220;
        }
        return new GrayMath.Gray(w, h, px);
    }

    private static void check(boolean ok, String what) {
        System.out.println((ok ? "PASS  " : "FAIL  ") + what);
        if (!ok) throw new AssertionError(what);
    }

    private static int darkCount(GrayMath.Gray g) {
        int n = 0;
        for (byte v : g.px) if ((v & 255) < 120) n++;
        return n;
    }

    public static void main(String[] args) throws Exception {
        File out = new File(args.length > 0 ? args[0] : "/tmp/clearpaper-engine-test.pdf");
        GrayMath.Gray src = dirtyPage(1200, 1700);
        System.out.println("source " + src.w + "x" + src.h + " dark=" + darkCount(src));

        float[] f = GrayMath.features(src);
        System.out.printf("features border=%.3f ring=%.1f inner=%.1f%n", f[0], f[1], f[2]);
        check(f[0] > 0.25f, "检测到四周黑框");

        GrayMath.Gray flat = GrayMath.flatten(src);
        GrayMath.Gray photo = GrayMath.photoMask(flat);
        float gamma = GrayMath.autoGamma(flat, photo);
        System.out.printf("autoGamma=%.2f%n", gamma);
        check(gamma >= 1.30f && gamma <= 1.90f, "自适应 gamma 落在合理区间");

        GrayMath.Enhanced e = GrayMath.enhance(src, gamma, Math.max(1f, gamma - 0.45f));
        System.out.printf("deghost removed=%.4f%%%n", e.ghost * 100);
        check(e.ghost > 0, "去透印命中浅灰虚影");

        GrayMath.Gray stripped = GrayMath.stripFrame(e.image);
        int[] box = GrayMath.cropBounds(stripped, false);
        GrayMath.Gray cropped = GrayMath.crop(stripped, box);
        System.out.printf("crop box=%s -> %dx%d%n", Arrays.toString(box), cropped.w, cropped.h);
        // 引擎按「有笔画的内容」裁掉空白纸边，因此裁后是内容框而非整张纸
        check(cropped.w > 900 && cropped.h > 1200, "裁边后保留全部笔画内容");
        check(box[0] > 30 && box[1] < 1170, "黑框被裁掉");

        float ret = GrayMath.strokeRetention(src, cropped, box);
        System.out.printf("stroke retention=%.4f%n", ret);
        check(ret > 0.97f, "笔画保留率 > 97%%（质量闸门放行）");

        // 关掉去透印后浅灰应保留：验证开关真的生效
        GrayMath.deghostEnabled = false;
        GrayMath.Enhanced off = GrayMath.enhance(src, gamma, 1f);
        check(off.ghost == 0, "关闭开关后去透印不生效");
        GrayMath.deghostEnabled = true;

        // 写一竖一横 + 一张空白页，验证逐页 MediaBox
        PdfWrite w = new PdfWrite(out);
        double scale = Math.min((PdfWrite.A4_W - 2 * PdfWrite.INSET) / cropped.w,
                (PdfWrite.A4_H - 2 * PdfWrite.INSET) / cropped.h);
        w.addGrayPage(cropped, scale);
        GrayMath.Gray wide = GrayMath.Gray.white(1700, 1100);
        for (int line = 0; line < 9; line++) {
            int y = 150 + line * 100;
            for (int t = 0; t < 4; t++)
                for (int x = 120; x < 1580; x++) wide.px[(y + t) * wide.w + x] = (byte) 40;
        }
        w.addGrayPage(wide, scale);
        w.addBlankPage(PdfWrite.A4_W, PdfWrite.A4_H);
        w.close();
        System.out.println("PDF " + out.getAbsolutePath() + " " + out.length() + " bytes");
        check(out.length() > 1000 && out.exists(), "PDF 已写出");
        System.out.println("ALL PASS");
    }
}
