package com.jpruby.clearpaper;

import android.app.Application;
import android.content.Context;

/** 全局上下文，仅用于 UI 组件把 dp 换算成 px。 */
public final class App extends Application {
    public static Context ctx;
    @Override public void onCreate() {
        super.onCreate();
        ctx = getApplicationContext();
    }
}
