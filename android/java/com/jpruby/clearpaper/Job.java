package com.jpruby.clearpaper;

import android.graphics.Bitmap;

import java.io.File;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/** 一个处理任务：对应 iOS 的 Job（含拍摄原稿持久化，系统清缓存后仍可重试）。 */
public final class Job {
    public static final int QUEUED = 0, WORKING = 1, DONE = 2, FAILED = 3;

    public final String id = UUID.randomUUID().toString();
    public final File source;
    public volatile String name;
    public volatile int state = QUEUED;
    public volatile float progress;
    public volatile String phase = "准备中…";
    public volatile int pages;
    public volatile float retention = 1;
    public volatile float sheetMM;
    public volatile double seconds;
    public volatile boolean showThrough, captured;
    public volatile int rectified, dropped, ocrLines;
    public volatile File result, textFile, captureDir;
    public volatile String outputStem;
    public volatile Bitmap thumb;
    public final List<File> imageFiles = new ArrayList<>();

    public Job(File source) {
        this.source = source;
        this.name = source.getName();
    }
}
