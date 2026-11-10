package com.jpruby.clearpaper;

import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.zip.Deflater;

/**
 * 零依赖 PDF 写出：每页一张 /DeviceGray + /FlateDecode 图像 XObject。
 * 边写边落盘，不把整份 PDF 堆在内存里；横竖 A4 逐页独立 MediaBox
 * （与 Core.swift 的 kCGPDFContextMediaBox 行为一致）。
 * 纯 Java，可在 JVM 上直接验证输出文件。
 */
public final class PdfWrite implements Closeable {
    public static final double A4_W = 595.2756;
    public static final double A4_H = 841.8898;
    public static final double INSET = 4.0 / 25.4 * 72.0;

    private final OutputStream raw;
    private long pos;
    private int nextObj = 3;                   // 1 = Catalog, 2 = Pages
    private final Map<Integer, Long> offsets = new HashMap<>();
    private final List<Integer> kids = new ArrayList<>();
    private boolean closed;

    public PdfWrite(File out) throws IOException {
        raw = new BufferedOutputStream(new FileOutputStream(out), 64 * 1024);
        w("%PDF-1.4\n");
        byte[] bin = new byte[]{(byte) 0x25, (byte) 0xE2, (byte) 0xE3, (byte) 0xCF, (byte) 0xD3, (byte) 0x0A};
        write(bin);
        w("% ClearPaper Android · by jpruby\n");
    }

    private void w(String s) throws IOException { write(s.getBytes("ISO-8859-1")); }

    private void write(byte[] data) throws IOException { raw.write(data); pos += data.length; }

    private int newObj() { int n = nextObj++; offsets.put(n, -1L); return n; }

    private void obj(int n) throws IOException {
        offsets.put(n, pos);
        w(n + " 0 obj\n");
    }

    private static String f(double v) { return String.format(Locale.US, "%.4f", v); }

    /** 按内容方向自动选竖/横 A4，页面内容按统一 scale 居中、顶部留 4mm。 */
    public void addGrayPage(GrayMath.Gray g, double scale) throws IOException {
        boolean landscape = g.w >= g.h;
        double pw = landscape ? A4_H : A4_W, ph = landscape ? A4_W : A4_H;
        double rw = g.w * scale, rh = g.h * scale;
        addPage(g, pw, ph, (pw - rw) / 2, ph - INSET - rh, rw, rh);
    }

    /** 合并用：保留源页的物理尺寸与方向，渲染结果铺满整页。 */
    public void addFullPage(GrayMath.Gray g, double mediaW, double mediaH) throws IOException {
        addPage(g, mediaW, mediaH, 0, 0, mediaW, mediaH);
    }

    public void addBlankPage(double mediaW, double mediaH) throws IOException {
        addPage(GrayMath.Gray.white(1, 1), mediaW, mediaH, 0, 0, mediaW, mediaH);
    }

    private void addPage(GrayMath.Gray g, double pw, double ph,
                         double x, double y, double rw, double rh) throws IOException {
        if (closed) throw new IOException("writer closed");
        int pageObj = newObj(), contentObj = newObj(), imageObj = newObj();

        obj(pageObj);
        w("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 " + f(pw) + " " + f(ph) + "]"
                + " /Resources << /XObject << /Im0 " + imageObj + " 0 R >> >>"
                + " /Contents " + contentObj + " 0 R >>\nendobj\n");

        String content = "q\n" + f(rw) + " 0 0 " + f(rh) + " " + f(x) + " " + f(y) + " cm\n/Im0 Do\nQ\n";
        byte[] cb = content.getBytes("ISO-8859-1");
        obj(contentObj);
        w("<< /Length " + cb.length + " >>\nstream\n");
        write(cb);
        w("endstream\nendobj\n");

        byte[] packed = flate(g.px);
        obj(imageObj);
        w("<< /Type /XObject /Subtype /Image /Width " + g.w + " /Height " + g.h
                + " /ColorSpace /DeviceGray /BitsPerComponent 8"
                + " /Filter /FlateDecode /Length " + packed.length + " >>\nstream\n");
        write(packed);
        w("\nendstream\nendobj\n");
        kids.add(pageObj);
    }

    private static byte[] flate(byte[] src) throws IOException {
        Deflater def = new Deflater(Deflater.DEFAULT_COMPRESSION);
        def.setInput(src);
        def.finish();
        ByteArrayOutputStream bos = new ByteArrayOutputStream(Math.max(1024, src.length / 8));
        byte[] buf = new byte[64 * 1024];
        while (!def.finished()) {
            int n = def.deflate(buf);
            bos.write(buf, 0, n);
        }
        def.end();
        return bos.toByteArray();
    }

    @Override
    public void close() throws IOException {
        if (closed) return;
        closed = true;
        int infoObj = newObj();
        obj(infoObj);
        w("<< /Producer (ClearPaper Android by jpruby) /Author (jpruby) /Creator (ClearPaper) >>\nendobj\n");

        obj(1);
        w("<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
        obj(2);
        StringBuilder sb = new StringBuilder("<< /Type /Pages /Count ").append(kids.size()).append(" /Kids [");
        for (int k : kids) sb.append(k).append(" 0 R ");
        sb.append("] >>\nendobj\n");
        w(sb.toString());

        long xref = pos;
        int size = nextObj;
        w("xref\n0 " + size + "\n0000000000 65535 f \n");
        for (int n = 1; n < size; n++) {
            long off = offsets.containsKey(n) ? offsets.get(n) : 0;
            w(String.format(Locale.US, "%010d 00000 n \n", off));
        }
        w("trailer\n<< /Size " + size + " /Root 1 0 R /Info " + infoObj + " 0 R >>\n"
                + "startxref\n" + xref + "\n%%EOF\n");
        raw.flush();
        raw.close();
    }
}
