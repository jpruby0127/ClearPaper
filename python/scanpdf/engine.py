#!/usr/bin/env python3
"""Automatic print-cleanup for photographed/scanned exam PDFs.

Drop a PDF in, get an A4 PDF out that prints dark and at true size. The engine
sniffs what kind of scan it is and picks the branch itself:

  geometry_bad   MediaBox is absurd (some scanners emit 28x41 inch pages, so the
                 printer shrinks the sheet to ~25% -> tiny grey text)
  has_frame      dark scanner border bands hugging the page edge
  notes_canvas   iOS Notes put the sheet on a pure-white canvas, wasting ~25% of
                 the page; crop back to the sheet
  photo_frac     photographs need a gentler curve than text, or they posterise
  placed_dpi     below ~230 DPI the printer staircases glyphs, so resample up

Usage: scanpdf in.pdf [-o out.pdf] [--json] [--dry-run]
"""
import argparse
import io
import json
import os
import sys
import time

import numpy as np
from PIL import Image

from scipy import ndimage as ndi
from clean_scan import (despeckle, enhance_scan, flatten, ink_span_x, ink_span_y,
                        paper_span_x, paint_edge_bands, photo_mask,
                        remove_border_slivers, remove_frame, show_through_ratio,
                        upscale)

import pymupdf as fitz

A4_PT = (595.2755905511812, 841.8897637795277)
MARGIN_MM = 4.0
TARGET_DPI = 300.0
DPI_FLOOR = 230.0
MAX_UPSCALE = 3.0


def _clamp(v, lo, hi):
    return max(lo, min(hi, v))


def _safe_text(s):
    """Under a non-UTF-8 locale Python decodes argv with surrogateescape, and
    PDF metadata then fails to encode. Recover the real UTF-8 text."""
    try:
        s.encode("utf-8")
    except UnicodeEncodeError:
        s = os.fsencode(s).decode("utf-8", "replace")
    return s


def page_image(doc, pg):
    """Biggest embedded raster, or a 300 DPI render when the page is not one image."""
    ims = pg.get_images(full=True)
    if len(ims) == 1:
        info = doc.extract_image(ims[0][0])
        a = np.array(Image.open(io.BytesIO(info["image"])).convert("L"), dtype=np.float32)
        return a, "embedded", info.get("ext", "?")
    if len(ims) > 1:
        pm = pg.get_pixmap(dpi=300, colorspace=fitz.csGRAY)
        return np.array(Image.open(io.BytesIO(pm.tobytes("png"))).convert("L"),
                        dtype=np.float32), "rendered-multi", "png"
    pm = pg.get_pixmap(dpi=300, colorspace=fitz.csGRAY)
    return np.array(Image.open(io.BytesIO(pm.tobytes("png"))).convert("L"),
                    dtype=np.float32), "rendered-vector", "png"


def features(a, pg):
    H, W = a.shape
    b = int(max(6, 0.012 * min(H, W)))
    sides = [(a[:b] < 200).mean(), (a[-b:] < 200).mean(),
             (a[:, :b] < 200).mean(), (a[:, -b:] < 200).mean()]
    ring = np.concatenate([a[:b].ravel(), a[-b:].ravel(), a[:, :b].ravel(), a[:, -b:].ravel()])
    inner = a[int(.2 * H):int(.8 * H), int(.2 * W):int(.8 * W)]
    f_flat = flatten(a)
    dark = f_flat < 200
    return {
        "w": W, "h": H,
        "page_in": (pg.rect.width / 72.0, pg.rect.height / 72.0),
        "rotation": pg.rotation,
        "border_max": float(max(sides)),
        "ring_mean": float(ring.mean()),
        "inner_mean": float(inner.mean()),
        "delta": float(ring.mean() - inner.mean()),
        "ink_tone": float(np.median(f_flat[dark])) if dark.any() else 255.0,
        "ink_frac": float(dark.mean()),
    }


INK_BLACK_TARGET = 105.0        # median luminance of real strokes in the output


def stroke_pixels(a, edge=0.02):
    """Connected dark components only, so JPEG paper noise is not mistaken for
    ink. Photo interiors and the outer edge band are excluded -- the latter
    because scanner frame remnants would drag the median dark."""
    H, W = a.shape
    inner = np.zeros(a.shape, dtype=bool)
    inner[int(edge * H):int((1 - edge) * H), int(edge * W):int((1 - edge) * W)] = True
    dark = (a < 190) & inner
    lab, k = ndi.label(dark)
    if k == 0:
        return np.zeros(0, dtype=np.float32)
    sizes = ndi.sum(dark, lab, range(1, k + 1))
    keep = np.where(sizes >= 15)[0] + 1
    return a[np.isin(lab, keep) & (photo_mask(a) < 0.5)]


def auto_gamma(a_flat, lo=1.30, hi=1.90, step=0.04):
    """Smallest gamma that makes real strokes print black.

    Calibrating on the result instead of guessing from the paper tone is what
    keeps thin strokes: a fixed high gamma over-darkens some documents and a
    fixed low one leaves others grey.
    """
    v = stroke_pixels(a_flat)
    if len(v) < 500:
        return round(lo, 3)
    lv = np.clip((v - 34.0) * (255.0 / 210.0), 0, 255) / 255.0
    for g in np.arange(lo, hi + 1e-9, step):
        if np.median(np.power(lv, g) * 255.0) <= INK_BLACK_TARGET:
            return round(float(g), 3)
    return round(float(hi), 3)


def decide(feats):
    """Document-level branch choice. Returns (decisions, per-page flags)."""
    geometry_bad = any(max(f["page_in"]) > 13.0 for f in feats)
    has_frame = any(f["border_max"] > 0.25 or f["delta"] < -15.0 for f in feats)
    notes_canvas = sum(1 for f in feats if f["ring_mean"] > 248 and f["delta"] > 8.0)
    notes_canvas = notes_canvas >= max(1, len(feats) // 2)
    return {
        "geometry_bad": geometry_bad,
        "has_frame": has_frame,
        "notes_canvas": notes_canvas,
        "gamma_text": 1.45,
        "gamma_photo": 1.00,
        "show_through": False,
    }


def strip_frame(a):
    return paint_edge_bands(remove_frame(a)[0])[0]


def probe_gamma(a, dec):
    """Calibrate gamma on the frame-stripped, flat-fielded page, i.e. on the
    exact signal the darkening curve will later receive. Also measures how much
    bleed-through the page carries, so the report can say it was cleaned."""
    b = strip_frame(a) if dec["has_frame"] else a
    f = flatten(b)
    m = photo_mask(f)
    return auto_gamma(f), len(stroke_pixels(f)), show_through_ratio(f, m)


def clean_one(a, dec):
    if dec["has_frame"]:
        a = strip_frame(a)
    a = enhance_scan(a, gamma_text=dec["gamma_text"], gamma_photo=dec["gamma_photo"])
    if dec["has_frame"]:
        a, _ = remove_border_slivers(a)
    a, _ = despeckle(a)
    return a


def crop_bounds(a, dec):
    """Trim the padding the scanner app added around the sheet.

    Only the Notes canvas is safe to cut: there the white surround is synthetic.
    For a full-bleed photo the ink bbox shrinks on short pages, and unifying on
    it would shrink every page, so the frame is kept as-is.
    """
    H, W = a.shape
    if not dec["notes_canvas"]:
        return 0, W, 0, H
    ys = ink_span_y(a)
    xw = ink_span_x(a)
    if not ys or not xw:
        return 0, W, 0, H
    xs = paper_span_x(a) if dec["notes_canvas"] else None
    padx = int(0.018 * W)
    pady = int(0.014 * H)
    if xs:
        x0 = max(0, min(xs[0], xw[0]) - padx)
        x1 = min(W, max(xs[1] + 1, xw[1] + 1) + padx)
    else:
        x0 = max(0, xw[0] - padx)
        x1 = min(W, xw[1] + 1 + padx)
    y0 = max(0, ys[0] - pady)
    y1 = min(H, ys[1] + 1 + pady)
    if (x1 - x0) >= 0.985 * W and (y1 - y0) >= 0.985 * H:
        return 0, W, 0, H
    return x0, x1, y0, y1


def analyse(src):
    """Everything a caller needs to reproduce the exact processing decisions.

    verify.py runs this too, so the gate is measured against the same gamma the
    output was actually built with.
    """
    doc = fitz.open(src)
    if doc.needs_pass:
        raise SystemExit("ENCRYPTED: PDF 有密码，先解密再处理")
    if doc.page_count == 0:
        raise SystemExit("EMPTY: PDF 没有页面")
    feats, arrays = [], []
    for pg in doc:
        a, how, ext = page_image(doc, pg)
        f = features(a, pg)
        f["source"] = how
        feats.append(f)
        arrays.append(a)
    dec = decide(feats)
    if any(f["source"] != "rendered-vector" for f in feats):
        probes, ghosts = [], []
        for a in arrays:
            g, npx, ghost = probe_gamma(a, dec)
            ghosts.append(ghost)
            if npx > 2000:
                probes.append(g)
        dec["show_through"] = any(x > 0.004 for x in ghosts)
        gamma = sorted(probes)[len(probes) // 2] if probes else 1.45
        dec["gamma_text"] = gamma
        dec["gamma_photo"] = round(_clamp(gamma - 0.45, 1.00, 1.15), 3)
        dec["gamma_pages_probed"] = len(probes)
    return doc, arrays, feats, dec


def process_pdf(src, dst=None, progress=None, overwrite=False):
    t0 = time.time()
    doc, arrays, feats, dec = analyse(src)
    n = doc.page_count
    if not any(f["source"] != "rendered-vector" for f in feats):
        return {"status": "skip", "reason": "vector", "src": src,
                "detail": "这份 PDF 本身是矢量文字（不是拍照/扫描），打印已经是最清晰的，无需处理。"}

    inset = MARGIN_MM / 25.4 * 72.0
    a4w, a4h = A4_PT

    crops = []
    for i, (a, f) in enumerate(zip(arrays, feats)):
        if progress:
            progress(f"page {i + 1}/{n} enhance")
        b = clean_one(a, dec)
        x0, x1, y0, y1 = crop_bounds(b, dec)
        crops.append(b[y0:y1, x0:x1])

    # 每页按内容方向选 A4 竖向 / 横向；整批统一缩放，避免字号跳变。
    def page_size(c):
        h, w = c.shape
        return (a4h, a4w) if w >= h else (a4w, a4h)   # (width, height)

    base_scale = min(
        min((page_size(c)[0] - 2 * inset) / max(1, c.shape[1]),
            (page_size(c)[1] - 2 * inset) / max(1, c.shape[0]))
        for c in crops
    )
    placed_dpi = 72.0 / base_scale
    factor = 1.0
    if placed_dpi < DPI_FLOOR:
        factor = _clamp(TARGET_DPI / placed_dpi, 1.0, MAX_UPSCALE)
        if progress:
            progress(f"resample x{factor:.2f} (placed {placed_dpi:.0f} DPI)")

    if dst is None:
        base, _ = os.path.splitext(src)
        dst = base + "-清晰版.pdf"
    if os.path.exists(dst) and not overwrite:
        raise SystemExit(f"EXISTS: 已存在 {dst}（默认会覆盖；--no-overwrite 时请换 -o 路径）")
    outdir = os.path.dirname(os.path.abspath(dst)) or "."
    if not os.access(outdir, os.W_OK):
        raise SystemExit(f"NOWRITE: 输出目录不可写 {outdir}")

    out = fitz.open()
    placed = []
    for i, c in enumerate(crops):
        if factor != 1.0:
            c = np.clip(upscale(c, factor), 0, 255).astype(np.uint8)
        else:
            c = np.clip(c, 0, 255).astype(np.uint8)
        if progress:
            progress(f"page {i + 1}/{n} place")
        h, w = c.shape
        pw, ph = page_size(c)
        s = base_scale / factor                   # 统一物理比例（factor 只增加像素）
        rw, rh = w * s, h * s
        if rh > ph - 2 * inset + 0.5:             # rounding guard
            s = (ph - 2 * inset) / h
            rw, rh = w * s, h * s
        pg = out.new_page(width=pw, height=ph)
        buf = io.BytesIO()
        Image.fromarray(c).save(buf, format="PNG", optimize=True)
        buf.seek(0)
        pg.insert_image(fitz.Rect((pw - rw) / 2, inset,
                                  (pw + rw) / 2, inset + rh),
                        stream=buf.read(), keep_proportion=False)
        placed.append({"page": i + 1, "src_px": [feats[i]["w"], feats[i]["h"]],
                       "crop_px": [int(w), int(h)],
                       "placed_mm": [round(rw / 72 * 25.4, 1), round(rh / 72 * 25.4, 1)],
                       "dpi": round(w / (rw / 72.0))})

    out.set_metadata({"title": _safe_text(os.path.splitext(os.path.basename(dst))[0]),
                      "creator": "scanpdf", "producer": "scanpdf"})
    out.save(dst, deflate=True, garbage=4)
    size = os.path.getsize(dst)

    return {
        "status": "ok", "src": src, "out": dst, "pages": n,
        "decisions": dec, "upscale_factor": round(factor, 2),
        "placed_dpi_before_upscale": round(placed_dpi),
        "sheet_width_mm": round(float(np.median([c.shape[1] * base_scale for c in crops])) / 72 * 25.4, 1),
        "output_bytes": size, "seconds": round(time.time() - t0, 1),
        "per_page": placed,
        "vector_pages": [i + 1 for i, f in enumerate(feats) if f["source"] == "rendered-vector"],
    }


def main():
    ap = argparse.ArgumentParser(description="扫描件 PDF 打印清晰化（自动判断）")
    ap.add_argument("src")
    ap.add_argument("-o", "--out", default=None)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-overwrite", dest="overwrite", action="store_false")
    args = ap.parse_args()

    if args.dry_run:
        doc = fitz.open(args.src)
        feats = []
        for pg in doc:
            a, how, ext = page_image(doc, pg)
            f = features(a, pg)
            f["source"] = how
            feats.append(f)
        print(json.dumps({"features": feats, "decisions": decide(feats)},
                         ensure_ascii=False, indent=2))
        return

    res = process_pdf(args.src, args.out,
                      progress=None if args.json else (lambda m: print("  ·", m)),
                      overwrite=args.overwrite)
    if args.json:
        print(json.dumps(res, ensure_ascii=False, indent=2))
    elif res["status"] == "skip":
        print(f"未处理：{res['detail']}")
    else:
        d = res["decisions"]
        print(f"\n判断：几何异常={d['geometry_bad']} 扫描黑框={d['has_frame']} "
              f"备忘录白画布={d['notes_canvas']} 自动 gamma={d['gamma_text']}"
              f"（照片 {d['gamma_photo']}）")
        print(f"重采样 x{res['upscale_factor']}（原放置 {res['placed_dpi_before_upscale']} DPI），"
              f"纸面宽 {res['sheet_width_mm']} mm")
        print(f"输出 {res['out']}  {res['pages']} 页  "
              f"{res['output_bytes'] / 1e6:.2f} MB  用时 {res['seconds']}s")


if __name__ == "__main__":
    main()
