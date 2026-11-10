package com.jpruby.clearpaper;

import android.app.Activity;
import android.content.Context;
import android.os.Bundle;
import android.os.CancellationSignal;
import android.os.ParcelFileDescriptor;
import android.print.PageRange;
import android.print.PrintAttributes;
import android.print.PrintDocumentAdapter;
import android.print.PrintDocumentInfo;
import android.print.PrintManager;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;

/** 系统打印框架，直接把生成的 PDF 字节交给打印服务（对应 iOS 的 AirPrint）。 */
public final class PrintHelper {
    private PrintHelper() {}

    public static void print(Activity a, File pdf) {
        PrintManager pm = (PrintManager) a.getSystemService(Context.PRINT_SERVICE);
        if (pm == null) return;
        PrintAttributes attrs = new PrintAttributes.Builder()
                .setMediaSize(PrintAttributes.MediaSize.ISO_A4)
                .setMinMargins(PrintAttributes.Margins.NO_MARGINS)
                .build();
        pm.print(pdf.getName(), new PrintDocumentAdapter() {
            @Override public void onLayout(PrintAttributes oldAttributes, PrintAttributes newAttributes,
                                           CancellationSignal cancellationSignal,
                                           LayoutResultCallback callback, Bundle extras) {
                if (cancellationSignal.isCanceled()) { callback.onLayoutCancelled(); return; }
                callback.onLayoutFinished(new PrintDocumentInfo.Builder(pdf.getName())
                        .setContentType(PrintDocumentInfo.CONTENT_TYPE_DOCUMENT)
                        .setPageCount(PrintDocumentInfo.PAGE_COUNT_UNKNOWN).build(), true);
            }
            @Override public void onWrite(PageRange[] pages, ParcelFileDescriptor destination,
                                          CancellationSignal cancellationSignal,
                                          WriteResultCallback callback) {
                try (InputStream in = new FileInputStream(pdf);
                     OutputStream out = new FileOutputStream(destination.getFileDescriptor())) {
                    byte[] buf = new byte[64 * 1024];
                    int n;
                    while ((n = in.read(buf)) > 0) {
                        if (cancellationSignal.isCanceled()) { callback.onWriteCancelled(); return; }
                        out.write(buf, 0, n);
                    }
                    out.flush();
                    callback.onWriteFinished(new PageRange[]{PageRange.ALL_PAGES});
                } catch (Exception e) {
                    callback.onWriteFailed(e.getMessage() == null ? "打印失败" : e.getMessage());
                }
            }
        }, attrs);
    }
}
