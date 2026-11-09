#!/usr/bin/env python3
"""Turn low-quality scanned PDFs into crisp A4 print files.

Fixes the two things that actually make scans unreadable in print:
  1. bogus page geometry (huge MediaBox -> printer shrinks the sheet to ~25%)
  2. scanner artifacts (dark border bands, paper-curl shadows, washed-out grey text)
"""
import argparse
import glob
import os
import sys

import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage as ndi

A4_PT = (595.2755905511812, 841.8897637795277)  # 210 x 297 mm


def bg_estimate(a, factor=24, med=9):
    im = Image.fromarray(a.astype(np.uint8))
    sm = im.resize((max(2, im.width // factor), max(2, im.height // factor)), Image.BILINEAR)
    sm = sm.filter(ImageFilter.MedianFilter(med))
    return np.array(sm.resize((im.width, im.height), Image.BILINEAR), dtype=np.float32)


def flatten(a, floor=150):
    """Multiplicative white-point normalisation.

    The old additive form (a + 255 - bg) is unsafe: where the background
    estimate is contaminated by dense text or a diagram it adds a large
    constant and pushes faint strokes straight to pure white. Dividing by the
    background keeps ink where it is and only lifts the paper, and it turns a
    dark scanner frame white as a side effect.
    """
    bg = np.maximum(bg_estimate(a), floor)
    return np.clip(a / bg * 255.0, 0, 255)


def sharpen_darken_only(a, radius=1.5, percent=130, threshold=4):
    """Unsharp mask that never lightens.

    A symmetric mask brightens the flanks of a thin stroke, and at scan
    resolution the whole faint stroke is a flank, so it erases exactly the
    strokes people then report as missing. Clipping the correction to the
    darkening side keeps the crisp edge without the loss.
    """
    blur = np.array(Image.fromarray(a.astype(np.uint8)).filter(
        ImageFilter.GaussianBlur(radius)), dtype=np.float32)
    d = np.minimum(a - blur, 0.0)
    d = np.where((a - blur) < -threshold, d, 0.0)
    return np.clip(a + d * percent / 100.0, 0, 255)
def darken(a, gamma=1.60, white=244, black=34):
    a = np.clip((a - black) * (255.0 / (white - black)), 0, 255)
    return np.clip(255.0 * np.power(a / 255.0, gamma), 0, 255)


def unsharp(a, radius=1.5, percent=95, threshold=3):
    b = np.array(Image.fromarray(a.astype(np.uint8)).filter(ImageFilter.GaussianBlur(radius)),
                 dtype=np.float32)
    diff = a - b
    mask = (np.abs(diff) > threshold).astype(np.float32)
    return np.clip(a + diff * percent / 100.0 * mask, 0, 255)


def remove_frame(a, thresh=205, span_ratio=0.55, min_area_ratio=0.004):
    """Paint large dark components that hug the page edge (scanner frame) white."""
    H, W = a.shape
    lab, n = ndi.label(a < thresh)
    if n == 0:
        return a, 0
    objs = ndi.find_objects(lab)
    ids = np.unique(np.concatenate([lab[0, :], lab[-1, :], lab[:, 0], lab[:, -1]]))
    hits = []
    for i in np.unique(ids[ids > 0]):
        sl = objs[i - 1]
        h = sl[0].stop - sl[0].start
        w = sl[1].stop - sl[1].start
        area = int((lab[sl] == i).sum())
        if (w / W > span_ratio or h / H > span_ratio) and area > min_area_ratio * H * W:
            hits.append(int(i))
    out = a.copy()
    if hits:
        out[np.isin(lab, hits)] = 255.0
    return out, len(hits)


def paint_edge_bands(a, thresh=205, frac=0.30, step=6, max_ratio=0.09):
    """Sweep inward from each edge while the strip is mostly dark."""
    H, W = a.shape
    out = a.copy()
    mx = int(max_ratio * min(H, W))

    def dfr(sub):
        return (sub < thresh).mean()

    r = 0
    while r < mx and dfr(out[r:r + step, :]) > frac:
        out[r:r + step, :] = 255.0
        r += step
    r = 0
    while r < mx and dfr(out[H - step - r:H - r, :]) > frac:
        out[H - step - r:H - r, :] = 255.0
        r += step
    r = 0
    while r < mx and dfr(out[:, r:r + step]) > frac:
        out[:, r:r + step] = 255.0
        r += step
    r = 0
    while r < mx and dfr(out[:, W - step - r:W - r]) > frac:
        out[:, W - step - r:W - r] = 255.0
        r += step
    return out, r


def remove_border_slivers(a, thresh=215, band=34, max_thick=90):
    """Delete thin strokes lying entirely inside the outer page-edge band.

    The whole bbox must sit in that band, so interior rules such as
    fill-in-the-blank underlines can never match.
    """
    H, W = a.shape
    dark = a < thresh
    lab, k = ndi.label(dark)
    if k == 0:
        return a, []
    objs = ndi.find_objects(lab)
    sizes = ndi.sum(dark, lab, range(1, k + 1))
    rm = np.zeros((H, W), dtype=bool)
    hits = []
    for i in range(1, k + 1):
        sl = objs[i - 1]
        if sl is None:
            continue
        y0, y1, x0, x1 = sl[0].start, sl[0].stop, sl[1].start, sl[1].stop
        h, w = y1 - y0, x1 - x0
        if int(sizes[i - 1]) < 120:
            continue
        inside = (y1 <= band) or (y0 >= H - band) or (x1 <= band) or (x0 >= W - band)
        thin = (h <= max_thick) or (w <= max_thick)
        if inside and thin:
            full = np.zeros((H, W), dtype=bool)
            full[sl] = (lab[sl] == i)
            rm |= full
            hits.append((w, h, int(sizes[i - 1])))
    out = a.copy()
    if rm.any():
        out[rm] = 255.0
    return out, hits


def despeckle(a, thresh=200, min_area=16, keep_near_ink=5):
    """Remove isolated noise specks only.

    A small component that sits next to other ink is a broken stroke fragment,
    not dirt, and deleting it is exactly the missing-stroke artefact people
    report, so anything with ink within keep_near_ink pixels is left alone.
    """
    dark = a < thresh
    lab, k = ndi.label(dark)
    if k == 0:
        return a, 0
    sizes = ndi.sum(dark, lab, range(1, k + 1))
    cand = np.where(sizes < min_area)[0] + 1
    if not len(cand):
        return a, 0
    others = np.isin(lab, cand, invert=True) & dark
    near = ndi.binary_dilation(others, iterations=keep_near_ink)
    drop = [i for i in cand if not near[lab == i].any()]
    out = a.copy()
    if drop:
        out[np.isin(lab, drop)] = 255.0
    return out, len(drop)


def paper_span_x(a, thr=250.5, close=41):
    """Left/right edges of the sheet, found from the tone step against the white
    surround. Reliable; the vertical edges are not, because blank text rows read
    as white, so vertical cropping uses ink instead."""
    prof = ndi.median_filter(a.mean(axis=0), size=25)
    m = ndi.binary_closing(prof < thr, structure=np.ones(close, dtype=bool))
    c = len(m) // 2
    if not m[c]:
        idx = np.where(m)[0]
        if not len(idx):
            return None
        c = int(idx[np.argmin(np.abs(idx - c))])
    lo = c
    while lo > 0 and m[lo - 1]:
        lo -= 1
    hi = c
    while hi < len(m) - 1 and m[hi + 1]:
        hi += 1
    return lo, hi


def ink_span_y(a, thr=200, min_frac=0.0015):
    m = a < thr
    rows = m.mean(axis=1)
    ri = np.where(rows > min_frac)[0]
    if not len(ri):
        return None
    return int(ri[0]), int(ri[-1])


def ink_span_x(a, thr=200, min_frac=0.0015):
    cols = (a < thr).mean(axis=0)
    ci = np.where(cols > min_frac)[0]
    if not len(ci):
        return None
    return int(ci[0]), int(ci[-1])


def upscale(a, factor=2.0):
    im = Image.fromarray(a.astype(np.uint8))
    im = im.resize((int(round(im.width * factor)), int(round(im.height * factor))), Image.LANCZOS)
    return np.array(im, dtype=np.float32)


def _ghost_mask(f, m, lo=196, hi=252, guard=19, solid=0.82):
    """Pixels that look like bleed-through rather than real content.

    Ghost ink sits only a few percent below paper white and always comes in
    thin strokes. Grey banners, table shading and colour blocks are solid
    areas, so a local-density guard keeps them; photos are left alone.
    """
    # 真实笔画（含抗锯齿边缘）附近一律不动，只清孤立在空白处的浅灰
    near_ink = ndi.uniform_filter((f < 120).astype(np.float32), size=7)
    mask = (f > lo) & (f < hi) & (m < 0.38) & (near_ink < 0.03)
    if not mask.any():
        return mask
    dens = ndi.uniform_filter(mask.astype(np.float32), size=guard)
    return mask & (dens <= solid)


def show_through_ratio(f, m):
    """Fraction of the page that would be cleaned as bleed-through."""
    return float(_ghost_mask(f, m).mean())


def suppress_show_through(f, m):
    """Lift bleed-through (ink showing through from the back of the sheet) to paper white."""
    mask = _ghost_mask(f, m)
    if mask.mean() < 0.002:
        return f
    soft = ndi.uniform_filter(mask.astype(np.float32), size=3)
    out = f.copy()
    out[mask] = f[mask] * (1.0 - soft[mask]) + 255.0 * soft[mask]
    return np.clip(out, 0, 255)


def enhance_scan(a, gamma_text=1.55, gamma_photo=1.02, denoise_photo=1.3,
                 sharp_text=130, sharp_photo=45):
    """Region-aware cleanup of a photographed document page.

    Flat-field correction is right for paper but erases the tonal range of
    photographs, so the mask chooses between the two paths instead of applying
    one curve to the whole page. Sharpening is darken-only throughout; a
    symmetric mask removes faint strokes.
    """
    f = flatten(a)
    m = photo_mask(f)
    f = suppress_show_through(f, m)
    inv = 1.0 - m
    base = f * inv + a * m
    smooth = np.array(Image.fromarray(np.clip(base, 0, 255).astype(np.uint8))
                      .filter(ImageFilter.GaussianBlur(denoise_photo)), dtype=np.float32)
    base = base * inv + smooth * m
    out = darken(base, gamma=gamma_text) * inv + darken(base, gamma=gamma_photo) * m
    sharp = sharpen_darken_only(out, radius=1.5, percent=sharp_text, threshold=4)
    soft = sharpen_darken_only(out, radius=1.2, percent=sharp_photo, threshold=4)
    return np.clip(sharp * inv + soft * m, 0, 255)


def photo_mask(f, block=48, lo=0.30, hi=0.60):
    """Soft 0..1 mask of photographic regions, from the local mid-tone fraction.

    Text and line art sit on white paper, so a block is mostly near-white or
    near-black; a photo is mostly mid-tone. Blending a gentler curve inside the
    mask keeps photos from posterising while text still gets the strong curve.
    """
    H, W = f.shape
    mid = ((f > 90) & (f < 225)).astype(np.float32)
    by, bx = max(1, H // block), max(1, W // block)
    small = mid[:by * block, :bx * block].reshape(by, block, bx, block).mean(axis=(1, 3))
    frac = np.clip((small - lo) / (hi - lo), 0, 1)
    m = np.array(Image.fromarray((frac * 255).astype(np.uint8)).resize(
        (W, H), Image.BILINEAR), dtype=np.float32) / 255.0
    return ndi.gaussian_filter(m, sigma=block * 0.9)


def split_curve(a, gamma_text=1.55, gamma_photo=1.05, **kw):
    """Apply a strong curve to text areas and a gentle one to photos."""
    m = photo_mask(a, **kw)
    return darken(a, gamma=gamma_photo) * m + darken(a, gamma=gamma_text) * (1.0 - m)


def clean_page(rgb, gamma=1.60):
    a = np.array(Image.fromarray(rgb).convert("L"), dtype=np.float32)
    a, _ = remove_frame(a)
    a, _ = paint_edge_bands(a)
    a = darken(flatten(a), gamma=gamma)
    a = sharpen_darken_only(a)
    a, _ = remove_border_slivers(a)
    a, _ = despeckle(a)
    return np.clip(a, 0, 255).astype(np.uint8)


def extract(src, workdir):
    import pymupdf
    doc = pymupdf.open(src)
    if doc.needs_pass:
        sys.exit("PDF is encrypted")
    paths = []
    for i, pg in enumerate(doc):
        imgs = pg.get_images(full=True)
        if not imgs:
            sys.exit(f"page {i + 1} has no raster image - this PDF is not a scan")
        raw = doc.extract_image(imgs[0][0])["image"]
        im = Image.open(__import__("io").BytesIO(raw))
        path = os.path.join(workdir, f"page{i + 1:02d}.png")
        im.save(path)
        paths.append(path)
    return doc, paths


def build(pages, out_pdf, title, margin_mm=0.0):
    import pymupdf
    doc = pymupdf.open()
    inset = margin_mm / 25.4 * 72.0
    box = (A4_PT[0] - 2 * inset, A4_PT[1] - 2 * inset)
    report = []
    for f in pages:
        w, h = Image.open(f).size
        s = min(box[0] / w, box[1] / h)
        rw, rh = w * s, h * s
        pg = doc.new_page(width=A4_PT[0], height=A4_PT[1])
        pg.insert_image(pymupdf.Rect((A4_PT[0] - rw) / 2, (A4_PT[1] - rh) / 2,
                                    (A4_PT[0] + rw) / 2, (A4_PT[1] + rh) / 2),
                        filename=f, keep_proportion=False)
        report.append((os.path.basename(f), rw / 72 * 25.4, rh / 72 * 25.4, w / (rw / 72)))
    doc.set_metadata({"title": title, "creator": "scan-cleanup", "producer": "scan-cleanup"})
    doc.save(out_pdf, deflate=True, garbage=4)
    return report


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("out")
    ap.add_argument("--title", default=None)
    ap.add_argument("--gamma", type=float, default=1.60)
    ap.add_argument("--workdir", default=None)
    ap.add_argument("--report-only", action="store_true")
    args = ap.parse_args()

    workdir = args.workdir or (os.path.splitext(args.out)[0] + ".work")
    os.makedirs(workdir, exist_ok=True)
    doc, pages = extract(args.src, workdir)
    print(f"source pages: {doc.page_count}")
    for i, pg in enumerate(doc):
        print(f"  p{i + 1} MediaBox {pg.rect.width:.0f}x{pg.rect.height:.0f} pt "
              f"= {pg.rect.width / 72:.1f}x{pg.rect.height / 72:.1f} in")
    if args.report_only:
        return

    outs = []
    for f in pages:
        arr = clean_page(np.array(Image.open(f).convert("RGB")), gamma=args.gamma)
        dst = os.path.join(workdir, "clean_" + os.path.basename(f))
        Image.fromarray(arr).save(dst, optimize=True)
        outs.append(dst)
        print(f"  cleaned {os.path.basename(f)} {arr.shape[1]}x{arr.shape[0]} "
              f"ink={float((arr < 128).mean()) * 100:.2f}%")

    title = args.title or os.path.splitext(os.path.basename(args.out))[0]
    for name, wmm, hmm, dpi in build(outs, args.out, title):
        print(f"  placed {name}: {wmm:.1f}x{hmm:.1f} mm @ {dpi:.0f} DPI")
    print(f"wrote {args.out} ({os.path.getsize(args.out) / 1e6:.2f} MB)")


if __name__ == "__main__":
    main()
