package com.jpruby.clearpaper;

import java.io.File;

/** 页面与 Activity 之间的路由：对应 iOS 版的 Router + Store 的 UI 动作。 */
public interface Host {
    Store store();
    void refresh();
    void gotoTab(int tab);
    void pickPdf();
    boolean hasCamera();
    void startCamera();
    void pickImages();
    void preview(File f);
    void showText(File f);
    void share(File f);
    void saveAs(File f);
    void printPdf(File f);
    void addToMerge(File f);
    void toast(String message);
}
