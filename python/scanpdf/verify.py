#!/usr/bin/env python3
"""Quality gate for scanpdf: prove nothing was clipped and the geometry is sane.

Re-runs the engine's own crop decision and checks, at several ink thresholds,
that every real ink pixel still lies inside the kept region. Also verifies the
output page size, page count and that each placed image stays on the sheet.

Usage: verify.py <in.pdf> <out.pdf>
Exit code 0 = pass, 1 = fail.
"""
import io
import json
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.expanduser("~/.qoder-tools/scan-cleanup"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pymupdf as fitz
from scipy import ndimage as ndi
from clean_scan import flatten, ink_span_x, ink_span_y, paper_span_x
from clean_scan import photo_mask
from engine import (analyse, clean_one, crop_bounds, page_image, strip_frame)

A4_MM = (210.0, 297.0)
THRESHOLDS = [(200, 0.0015), (150, 0.0008), (110, 0.0003), (80, 0.0002)]


def main():
    src, dst = sys.argv[1], sys.argv[2]
    s = fitz.open(src)
    d = fitz.open(dst)
    problems = []

    if d.page_count != s.page_count:
        problems.append(f"page count {d.page_count} != source {s.page_count}")

    s, _arrays, _feats, dec = analyse(src)
    for i, pg in enumerate(s):
        a, how, ext = page_image(s, pg)
        b = clean_one(a, dec)
        x0, x1, y0, y1 = crop_bounds(b, dec)
        H, W = a.shape
        for thr, mf in THRESHOLDS:
            m = b < thr
            ri = np.where(m.mean(axis=1) > mf)[0]
            ci = np.where(m.mean(axis=0) > mf)[0]
            if not len(ri) or not len(ci):
                continue
            slack = (ci[0] - x0, x1 - 1 - ci[-1], ri[0] - y0, y1 - 1 - ri[-1])
            if min(slack) < 0:
                problems.append(f"page {i + 1} thr {thr}: clipped "
                                f"L{slack[0]} R{slack[1]} T{slack[2]} B{slack[3]}")

    for i, pg in enumerate(d):
        wmm, hmm = pg.rect.width / 72 * 25.4, pg.rect.height / 72 * 25.4
        if abs(wmm - A4_MM[0]) > 0.5 or abs(hmm - A4_MM[1]) > 0.5:
            problems.append(f"page {i + 1} is {wmm:.1f}x{hmm:.1f} mm, not A4")
        for im in pg.get_images(full=True):
            for r in pg.get_image_rects(im[0]):
                if r.x0 < -0.5 or r.y0 < -0.5 or r.x1 > pg.rect.width + 0.5 \
                        or r.y1 > pg.rect.height + 0.5:
                    problems.append(f"page {i + 1} image overflows the sheet")

    # Every real stroke in the source must still be there in the delivered
    # page. This is the gate that catches missing strokes, which is what a
    # plain ink-percentage check misses.
    ret = []
    for i in range(s.page_count):
        a = _arrays[i]
        probe = strip_frame(a) if dec["has_frame"] else a
        f = flatten(probe)
        # same definition the engine calibrates on: connected dark components,
        # interior only, photo interiors excluded
        stroke = np.zeros(f.shape, dtype=bool)
        lab, k = ndi.label((f < 190) & (photo_mask(f) < 0.5))
        if k:
            sizes = ndi.sum(lab > 0, lab, range(1, k + 1))
            stroke = np.isin(lab, np.where(sizes >= 15)[0] + 1)
        e = 0.02
        H, W = f.shape
        stroke[:int(e * H), :] = False
        stroke[int((1 - e) * H):, :] = False
        stroke[:, :int(e * W)] = False
        stroke[:, int((1 - e) * W):] = False
        x0, x1, y0, y1 = crop_bounds(clean_one(a, dec), dec)
        emb = d[i].get_images(full=True)
        out = np.array(Image.open(io.BytesIO(d.extract_image(emb[0][0])["image"])).convert("L"),
                       dtype=np.float32)
        sel = stroke[y0:y1, x0:x1]
        if sel.sum() < 500:
            continue
        if sel.shape != out.shape:            # engine resampled the page
            sel = np.array(Image.fromarray(sel.astype(np.uint8) * 255)
                           .resize((out.shape[1], out.shape[0]), Image.NEAREST)) > 127
            if sel.sum() < 500:
                continue
        kept = float((out[sel] < 215).mean())
        ret.append(round(kept * 100, 1))
        if kept < 0.97:
            problems.append(f"page {i + 1} stroke retention {kept * 100:.1f}% < 97%")
    report_ink = ret

    report = {"src": os.path.basename(src), "out": os.path.basename(dst),
              "decisions": dec, "problems": problems,
              "stroke_retention_pct": report_ink,
              "min_retention_pct": min(report_ink) if report_ink else None,
              "output_mb": round(os.path.getsize(dst) / 1e6, 2)}
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if problems:
        print(f"\nFAIL: {len(problems)} problem(s)")
        return 1
    print("\nPASS: 无裁切、尺寸标准 A4、页数一致、笔画保留达标")
    return 0


if __name__ == "__main__":
    sys.exit(main())
