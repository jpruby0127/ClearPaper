package com.jpruby.clearpaper;

import java.io.File;

public final class OutFile {
    public final File file;
    public final long size, date;
    public final int pages;
    public final boolean isText;
    public OutFile(File file, long size, long date, int pages, boolean isText) {
        this.file = file; this.size = size; this.date = date; this.pages = pages; this.isText = isText;
    }
    public String name() { return file.getName(); }
}
