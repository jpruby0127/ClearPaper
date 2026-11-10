package com.jpruby.clearpaper;

import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.util.Base64;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * 可选 OCR：Android 没有系统级文字识别 API，这里桥接小米开源的 Xiaomi-OCR-0
 * （0.8B / Apache 2.0，官方 OpenAI 兼容服务，与 python/ocr_xiaomi.py 同一协议）。
 * 默认完全关闭、零联网；只有用户在「关于 → OCR 服务」里填了自己的本机 / 内网地址
 * 并打开开关，才会把页面送到该地址。不配置时仍生成文字稿占位文件，UI 流程不缺口。
 */
public final class OcrClient {
    private OcrClient() {}
    public static final String PREF_ENDPOINT = "cp.ocr_endpoint";
    public static final String PREF_MODEL = "cp.ocr_model";
    public static final String PREF_ENABLED = "cp.ocr_enabled";

    private static final String DOC_PROMPT =
            "Extract all information from the main body of the document image and represent it in markdown format, "
            + "ignoring headers and footers. Tables should be expressed in OTSL format, formulas in the document should "
            + "be represented using LATEX format, and the parsing should be organized according to the reading order.";

    public static final class Result {
        public String text = "";
        public int lines;
        public String title;
        public boolean remote;
        public String error;
    }

    private static SharedPreferences prefs(Context c) {
        return c.getSharedPreferences("clearpaper", Context.MODE_PRIVATE);
    }

    public static String endpoint(Context c) {
        return prefs(c).getString(PREF_ENDPOINT, "");
    }
    public static String model(Context c) {
        String m = prefs(c).getString(PREF_MODEL, "");
        return m.isEmpty() ? "SeerRay-Lab/Xiaomi-OCR-0" : m;
    }
    public static boolean enabled(Context c) {
        return prefs(c).getBoolean(PREF_ENABLED, false) && !endpoint(c).isEmpty();
    }
    public static void configure(Context c, String url, String model, boolean on) {
        prefs(c).edit().putString(PREF_ENDPOINT, url.trim())
                .putString(PREF_MODEL, model.trim())
                .putBoolean(PREF_ENABLED, on).apply();
    }

    public static Result recognize(Context c, List<File> pages) {
        Result r = new Result();
        r.remote = enabled(c);
        List<String> bodies = new ArrayList<>();
        if (r.remote) {
            for (File p : pages) {
                try {
                    String md = call(c, p);
                    bodies.add(md.isEmpty() ? "（本页未识别到文字）" : md);
                } catch (Exception e) {
                    r.error = e.getMessage() == null ? "OCR 服务连接失败" : e.getMessage();
                    bodies.add("（OCR 服务不可用：" + r.error + "）");
                }
            }
        } else {
            for (int i = 0; i < pages.size(); i++) bodies.add("（本页未识别到文字）");
        }
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < bodies.size(); i++) {
            if (i > 0) sb.append("\n\n");
            sb.append("## 第 ").append(i + 1).append(" 页\n\n").append(bodies.get(i));
        }
        if (!r.remote) {
            sb.append("\n\n---\n\nAndroid 版默认完全离线：系统不提供本机 OCR 模型，"
                    + "文字稿需要你在「关于 → OCR 服务」里填入自己部署的 Xiaomi-OCR-0 地址后才会生成。\n"
                    + "未配置时 PDF 的图像清晰化、A4 排版与质量闸门全部照常工作。\n");
        }
        r.text = sb.toString();
        for (String body : bodies) for (String line : body.split("\n")) if (!line.trim().isEmpty()) r.lines++;
        if (r.remote) r.title = suggestedTitle(bodies.isEmpty() ? "" : bodies.get(0));
        return r;
    }

    public static String suggestedTitle(String firstPage) {
        String[] lines = firstPage.split("\n");
        for (int i = 0; i < Math.min(6, lines.length); i++) {
            String t = lines[i].replaceAll("^[#>\\s*|-]+", "").trim();
            if (t.length() < 4 || t.length() > 30) continue;
            String clean = t.replaceAll("[/\\\\:*?\"<>|\\n\\r\\t]", "").trim();
            if (clean.length() >= 4) return clean.substring(0, Math.min(30, clean.length()));
        }
        return null;
    }

    private static String endpointUrl(String base) {
        String b = base.trim().replaceAll("/+$", "");
        if (b.endsWith("/chat/completions")) return b;
        if (b.endsWith("/v1")) return b + "/chat/completions";
        return b + "/v1/chat/completions";
    }

    private static String call(Context c, File page) throws Exception {
        byte[] png = pngForUpload(page);
        String b64 = Base64.encodeToString(png, Base64.NO_WRAP);
        JSONObject payload = new JSONObject();
        payload.put("model", model(c));
        payload.put("temperature", 0.0);
        payload.put("max_tokens", 4096);
        payload.put("stream", false);
        JSONArray content = new JSONArray();
        JSONObject image = new JSONObject();
        image.put("type", "image_url");
        image.put("image_url", new JSONObject().put("url", "data:image/png;base64," + b64));
        content.put(image);
        content.put(new JSONObject().put("type", "text").put("text", DOC_PROMPT));
        payload.put("messages", new JSONArray().put(new JSONObject()
                .put("role", "user").put("content", content)));

        HttpURLConnection conn = (HttpURLConnection) new URL(endpointUrl(endpoint(c))).openConnection();
        conn.setRequestMethod("POST");
        conn.setRequestProperty("Content-Type", "application/json");
        conn.setConnectTimeout(15000);
        conn.setReadTimeout(90000);
        conn.setDoOutput(true);
        try (OutputStream os = conn.getOutputStream()) {
            os.write(payload.toString().getBytes(StandardCharsets.UTF_8));
        }
        int code = conn.getResponseCode();
        StringBuilder sb = new StringBuilder();
        java.io.InputStream in = code >= 400 ? conn.getErrorStream() : conn.getInputStream();
        if (in != null) {
            try (BufferedReader br = new BufferedReader(new InputStreamReader(in, StandardCharsets.UTF_8))) {
                String line;
                while ((line = br.readLine()) != null) sb.append(line);
            }
        }
        conn.disconnect();
        if (code < 200 || code >= 300) throw new IllegalStateException("HTTP " + code + " " + sb.substring(0, Math.min(80, sb.length())));
        JSONObject root = new JSONObject(sb.toString());
        JSONArray choices = root.optJSONArray("choices");
        if (choices == null || choices.length() == 0) return "";
        return choices.getJSONObject(0).optJSONObject("message") == null ? ""
                : choices.getJSONObject(0).getJSONObject("message").optString("content", "");
    }

    /** 官方 Demo 的归一化：RGB PNG，长边限 2048。 */
    private static byte[] pngForUpload(File page) {
        BitmapFactory.Options probe = new BitmapFactory.Options();
        probe.inJustDecodeBounds = true;
        BitmapFactory.decodeFile(page.getPath(), probe);
        int w = Math.max(1, probe.outWidth), h = Math.max(1, probe.outHeight), sample = 1;
        while (w / sample > 2048 * 2 || h / sample > 2048 * 2) sample *= 2;
        BitmapFactory.Options o = new BitmapFactory.Options();
        o.inSampleSize = sample;
        o.inPreferredConfig = Bitmap.Config.ARGB_8888;
        Bitmap bm = BitmapFactory.decodeFile(page.getPath(), o);
        if (bm == null) throw new IllegalStateException("无法读取页面图片");
        int side = Math.max(bm.getWidth(), bm.getHeight());
        if (side > 2048) {
            float k = 2048f / side;
            Bitmap small = Bitmap.createScaledBitmap(bm,
                    Math.max(1, Math.round(bm.getWidth() * k)),
                    Math.max(1, Math.round(bm.getHeight() * k)), true);
            bm.recycle();
            bm = small;
        }
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        bm.compress(Bitmap.CompressFormat.PNG, 100, bos);
        bm.recycle();
        return bos.toByteArray();
    }
}
