import Foundation
import CoreGraphics
import ImageIO
import PDFKit

// On-device port of the Python scan-cleanup engine. Same maths, same gates,
// no server: every step is plain pixel work an A-series chip does quickly.

public struct Gray {
    public var w: Int
    public var h: Int
    public var px: [UInt8]
    public init(w: Int, h: Int, px: [UInt8]) { self.w = w; self.h = h; self.px = px }
}

public struct Decisions {
    public var gammaText: Float = 1.45
    public var gammaPhoto: Float = 1.00
    public var hasFrame = false
    public var notesCanvas = false
    public var upscale: Float = 1.0
    public var sheetWidthMM: Float = 0
    public var showThrough = false
    public var retention: [Float] = []
}

public struct Report {
    public var pages = 0
    public var decisions = Decisions()
    public var seconds: Double = 0
    public var passed = true
    public var problems: [String] = []
}

public enum ScanCore {

    /// 去背面透印开关。iOS / macOS 的设置页可直接改这个开关；
    /// 环境变量 SCANPDF_NO_DEGHOST=1 仍作为命令行逃生通道。
    public static var deghostEnabled = true

    // MARK: render

    /// Rendering through the page box is what neutralises bogus MediaBoxes:
    /// a 28-inch page and a Letter page both come out the same physical size.
    public static func renderPages(_ url: URL, targetWidthPx: Int = 2480) -> [Gray] {
        guard let doc = PDFDocument(url: url) else { return [] }
        var out: [Gray] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            guard box.width > 1, box.height > 1 else { continue }
            let scale = CGFloat(targetWidthPx) / box.width
            let w = Int((box.width * scale).rounded())
            let h = Int((box.height * scale).rounded())
            // grayscale-only context: .none alpha is invalid for RGB bitmaps
            let cs = CGColorSpace(name: "kCGColorSpaceGenericGray" as CFString)!
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { continue }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: .mediaBox, to: ctx)
            guard let cg = ctx.makeImage() else { continue }
            out.append(gray(from: cg))
        }
        return out
    }

    public static func gray(from cg: CGImage) -> Gray {
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 255, count: w * h)
        let cs = CGColorSpace(name: "kCGColorSpaceGenericGray" as CFString)!
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w, space: cs,
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)
            ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Gray(w: w, h: h, px: buf)
    }

    public static func cgImage(_ g: Gray) -> CGImage? {
        let cs = CGColorSpace(name: "kCGColorSpaceGenericGray" as CFString)!
        guard let provider = CGDataProvider(data: Data(g.px) as CFData) else { return nil }
        return CGImage(width: g.w, height: g.h, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: g.w, space: cs, bitmapInfo: CGBitmapInfo(),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    public static func resize(_ g: Gray, factor: Float) -> Gray {
        guard factor != 1, let cg = cgImage(g) else { return g }
        let w = Int((Float(g.w) * factor).rounded()), h = Int((Float(g.h) * factor).rounded())
        let cs = CGColorSpace(name: "kCGColorSpaceGenericGray" as CFString)!
        var buf = [UInt8](repeating: 255, count: w * h)
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w, space: cs,
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)
            ctx?.interpolationQuality = .high
            ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Gray(w: w, h: h, px: buf)
    }

    // MARK: primitives

    static func downsampleMean(_ a: Gray, factor: Int) -> Gray {
        let sw = max(2, a.w / factor), sh = max(2, a.h / factor)
        var out = [UInt8](repeating: 0, count: sw * sh)
        for y in 0..<sh {
            let y0 = y * factor, y1 = min(a.h, y0 + factor)
            for x in 0..<sw {
                var sum = 0, n = 0
                let x0 = x * factor, x1 = min(a.w, x0 + factor)
                for yy in y0..<y1 {
                    let row = yy * a.w
                    for xx in x0..<x1 { sum += Int(a.px[row + xx]); n += 1 }
                }
                out[y * sw + x] = UInt8(sum / max(1, n))
            }
        }
        return Gray(w: sw, h: sh, px: out)
    }

    static func median3x3(_ a: Gray, passes: Int = 2) -> Gray {
        var cur = a.px
        var nxt = cur
        var win = [UInt8](repeating: 0, count: 9)
        for _ in 0..<passes {
            for y in 0..<a.h {
                let ym = max(y - 1, 0) * a.w, yr = y * a.w, yp = min(y + 1, a.h - 1) * a.w
                for x in 0..<a.w {
                    let xm = max(x - 1, 0), xp = min(x + 1, a.w - 1)
                    win[0] = cur[ym + xm]; win[1] = cur[ym + x]; win[2] = cur[ym + xp]
                    win[3] = cur[yr + xm]; win[4] = cur[yr + x]; win[5] = cur[yr + xp]
                    win[6] = cur[yp + xm]; win[7] = cur[yp + x]; win[8] = cur[yp + xp]
                    win.sort()
                    nxt[yr + x] = win[4]
                }
            }
            swap(&cur, &nxt)
        }
        return Gray(w: a.w, h: a.h, px: cur)
    }

    static func upsampleBilinear(_ a: Gray, toW: Int, toH: Int) -> Gray {
        var out = [UInt8](repeating: 0, count: toW * toH)
        let fx = Float(max(1, a.w - 1)) / Float(max(1, toW - 1))
        let fy = Float(max(1, a.h - 1)) / Float(max(1, toH - 1))
        for y in 0..<toH {
            let sy = Float(y) * fy
            let y0 = Int(sy), y1 = min(a.h - 1, y0 + 1)
            let ty = sy - Float(y0)
            let r0 = y0 * a.w, r1 = y1 * a.w, ro = y * toW
            for x in 0..<toW {
                let sx = Float(x) * fx
                let x0 = Int(sx), x1 = min(a.w - 1, x0 + 1)
                let tx = sx - Float(x0)
                let top = Float(a.px[r0 + x0]) + (Float(a.px[r0 + x1]) - Float(a.px[r0 + x0])) * tx
                let bot = Float(a.px[r1 + x0]) + (Float(a.px[r1 + x1]) - Float(a.px[r1 + x0])) * tx
                out[ro + x] = UInt8((top + (bot - top) * ty).rounded())
            }
        }
        return Gray(w: toW, h: toH, px: out)
    }

    /// Separable box blur with running sums (O(n)); repeated passes ~ gaussian.
    public static func boxBlur(_ a: Gray, radius: Int, passes: Int = 1) -> Gray {
        var cur = a.px
        var tmp = cur
        let r = max(1, radius)
        let span = 2 * r + 1
        for _ in 0..<passes {
            for y in 0..<a.h {
                let row = y * a.w
                var acc = 0
                for x in -r...r { acc += Int(cur[row + min(max(x, 0), a.w - 1)]) }
                for x in 0..<a.w {
                    tmp[row + x] = UInt8(acc / span)
                    acc += Int(cur[row + min(x + r + 1, a.w - 1)]) - Int(cur[row + max(x - r, 0)])
                }
            }
            for x in 0..<a.w {
                var acc = 0
                for y in -r...r { acc += Int(tmp[min(max(y, 0), a.h - 1) * a.w + x]) }
                for y in 0..<a.h {
                    cur[y * a.w + x] = UInt8(acc / span)
                    acc += Int(tmp[min(y + r + 1, a.h - 1) * a.w + x]) - Int(tmp[max(y - r, 0) * a.w + x])
                }
            }
        }
        return Gray(w: a.w, h: a.h, px: cur)
    }

    static func gammaLUT(_ gamma: Float, black: Float = 34, white: Float = 244) -> [UInt8] {
        var lut = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 {
            let v = min(max((Float(i) - black) * (255.0 / (white - black)), 0), 255)
            lut[i] = UInt8(min(255, (255.0 * pow(v / 255.0, gamma)).rounded()))
        }
        return lut
    }

    // MARK: analysis

    public static func features(_ a: Gray) -> (borderMax: Float, ringMean: Float, innerMean: Float) {
        let b = max(6, Int(0.012 * Float(min(a.w, a.h))))
        func dark(_ range: Range<Int>, strideBy: Int = 1) -> Float {
            var d = 0, n = 0
            for i in Swift.stride(from: range.lowerBound, to: range.upperBound, by: strideBy) { if a.px[i] < 200 { d += 1 }; n += 1 }
            return Float(d) / Float(max(1, n))
        }
        let top = dark(0..<b * a.w)
        let bot = dark((a.h - b) * a.w..<a.h * a.w)
        var ld = 0, rd = 0, ln = 0
        var ringSum = 0, ringN = 0
        for y in stride(from: 0, to: a.h, by: 3) {
            let row = y * a.w
            for x in 0..<b { if a.px[row + x] < 200 { ld += 1 }; ringSum += Int(a.px[row + x]); ringN += 1 }
            for x in (a.w - b)..<a.w { if a.px[row + x] < 200 { rd += 1 }; ringSum += Int(a.px[row + x]); ringN += 1 }
            ln += 2 * b
        }
        for x in 0..<a.w { for y in 0..<b { ringSum += Int(a.px[y * a.w + x]); ringN += 1 } }
        for x in 0..<a.w { for y in (a.h - b)..<a.h { ringSum += Int(a.px[y * a.w + x]); ringN += 1 } }
        var innerSum = 0.0, innerN = 0
        for y in stride(from: Int(0.2 * Float(a.h)), to: Int(0.8 * Float(a.h)), by: 6) {
            for x in stride(from: Int(0.2 * Float(a.w)), to: Int(0.8 * Float(a.w)), by: 6) {
                innerSum += Double(a.px[y * a.w + x]); innerN += 1
            }
        }
        return (max(top, bot, Float(ld) / Float(max(1, ln / 2)), Float(rd) / Float(max(1, ln / 2))),
                Float(ringSum) / Float(max(1, ringN)),
                Float(innerSum / Double(max(1, innerN))))
    }

    /// 4-connected labeling with union-find.
    public static func label(_ a: Gray, thresh: UInt8) -> [Int] {
        var lab = [Int](repeating: 0, count: a.px.count)
        var parent = [Int](repeating: 0, count: 1)   // labels are 1-based
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            var c = x
            while parent[c] != r { let n = parent[c]; parent[c] = r; c = n }
            return r
        }
        var next = 0
        for y in 0..<a.h {
            let row = y * a.w
            for x in 0..<a.w {
                guard a.px[row + x] < thresh else { continue }
                let left = x > 0 && a.px[row + x - 1] < thresh ? lab[row + x - 1] : 0
                let up = y > 0 && a.px[row - a.w + x] < thresh ? lab[row - a.w + x] : 0
                if left == 0 && up == 0 {
                    next += 1; parent.append(next); lab[row + x] = next
                } else if left != 0 && up != 0 {
                    lab[row + x] = min(left, up)
                    if left != up { let rl = find(left), ru = find(up); parent[max(rl, ru)] = min(rl, ru) }
                } else {
                    lab[row + x] = left != 0 ? left : up
                }
            }
        }
        for i in 0..<lab.count where lab[i] > 0 { lab[i] = find(lab[i]) }
        return lab
    }

    static func strokeMask(_ f: Gray, photo: Gray, thresh: UInt8 = 190, minArea: Int = 15) -> [Bool] {
        let lab = label(f, thresh: thresh)
        var counts = [Int](repeating: 0, count: (lab.max() ?? 0) + 1)
        for v in lab where v > 0 && v < counts.count { counts[v] += 1 }
        var mask = [Bool](repeating: false, count: f.px.count)
        let ex = Int(0.02 * Float(f.w)), ey = Int(0.02 * Float(f.h))
        for i in 0..<f.px.count {
            let l = lab[i]
            guard l > 0, l < counts.count, counts[l] >= minArea else { continue }
            let x = i % f.w, y = i / f.w
            if x < ex || y < ey || x >= f.w - ex || y >= f.h - ey { continue }
            if photo.px[i] > 127 { continue }
            mask[i] = true
        }
        return mask
    }

    static func photoMask(_ f: Gray, block: Int = 48) -> Gray {
        let bw = max(1, f.w / block), bh = max(1, f.h / block)
        var frac = Gray(w: bw, h: bh, px: [UInt8](repeating: 0, count: bw * bh))
        for by in 0..<bh {
            let y0 = by * block, y1 = min(f.h, y0 + block)
            for bx in 0..<bw {
                var mid = 0, n = 0
                let x0 = bx * block, x1 = min(f.w, x0 + block)
                for y in y0..<y1 {
                    let row = y * f.w
                    for x in x0..<x1 {
                        let v = f.px[row + x]
                        if v > 90 && v < 225 { mid += 1 }
                        n += 1
                    }
                }
                let r = Float(mid) / Float(max(1, n))
                frac.px[by * bw + bx] = UInt8((min(max((r - 0.30) / 0.30, 0), 1) * 255).rounded())
            }
        }
        let up = upsampleBilinear(frac, toW: f.w, toH: f.h)
        return boxBlur(up, radius: block * 2 / 3, passes: 2)
    }

    public static func flatten(_ a: Gray) -> Gray {
        let small = downsampleMean(a, factor: 24)
        let med = median3x3(small, passes: 2)
        let bg = upsampleBilinear(med, toW: a.w, toH: a.h)
        var out = a.px
        for i in 0..<out.count {
            let b = max(Int(bg.px[i]), 150)
            out[i] = UInt8(min(255, Int(a.px[i]) * 255 / b))
        }
        return Gray(w: a.w, h: a.h, px: out)
    }

    /// Smallest gamma that makes real strokes print black (median <= 105).
    public static func autoGamma(_ f: Gray, photo: Gray) -> Float {
        let mask = strokeMask(f, photo: photo)
        var vals: [UInt8] = []
        for i in 0..<f.px.count where mask[i] { vals.append(f.px[i]) }
        guard vals.count > 500 else { return 1.30 }
        vals.sort()
        let lv = min(max((Float(vals[vals.count / 2]) - 34) * (255.0 / 210.0), 0), 255) / 255.0
        var g: Float = 1.30
        while g <= 1.9001 {
            if pow(lv, g) * 255.0 <= 95.0 { return g }
            g += 0.04
        }
        return 1.90
    }

    public static func enhance(_ a: Gray, gammaText: Float, gammaPhoto: Float) -> (Gray, Float) {
        var f = flatten(a)
        let m = photoMask(f)
        let (cleaned, ghost) = deghost(f, photo: m)
        f = cleaned
        let lutT = gammaLUT(gammaText)
        let lutP = gammaLUT(gammaPhoto)
        let smooth = boxBlur(f, radius: 1, passes: 1)
        var out = [UInt8](repeating: 0, count: f.px.count)
        for i in 0..<out.count {
            let mv = Float(m.px[i]) / 255.0
            let base = Float(f.px[i]) * (1 - mv) + Float(smooth.px[i]) * mv
            let bi = Int(min(255, max(0, base.rounded())))
            out[i] = UInt8((Float(lutT[bi]) * (1 - mv) + Float(lutP[bi]) * mv).rounded())
        }
        // darken-only unsharp: never lightens, so faint strokes survive
        let blur = boxBlur(Gray(w: f.w, h: f.h, px: out), radius: 2, passes: 1)
        for i in 0..<out.count {
            let d = Int(out[i]) - Int(blur.px[i])
            if d < -4 { out[i] = UInt8(max(0, Int(out[i]) + d * 130 / 100)) }
        }
        return (Gray(w: f.w, h: f.h, px: out), ghost)
    }

    /// 背面透印（show-through）抑制。
    ///
    /// 透印墨比纸白只暗一点点（约 1%~30%），而且总是细笔画；
    /// 一旦加了对比度就会被一起加深，看着像"脏"。做法是把这一灰段抹回纸白，
    /// 但用局部密度守住成片的浅灰（表格底纹、灰色横幅、色块），
    /// 并跳过照片区域，避免把浅色照片洗掉。
    static func deghost(_ a: Gray, photo: Gray) -> (Gray, Float) {
        // 调试/逃生开关：不希望动浅灰的文档可以关掉这一步
        if !ScanCore.deghostEnabled
            || ProcessInfo.processInfo.environment["SCANPDF_NO_DEGHOST"] == "1" { return (a, 0) }
        // 真实笔画（含抗锯齿边缘）附近一律不动，只清孤立在空白处的浅灰
        var ink = [UInt8](repeating: 0, count: a.px.count)
        for i in 0..<a.px.count where a.px[i] < 120 { ink[i] = 255 }
        let nearInk = boxBlur(Gray(w: a.w, h: a.h, px: ink), radius: 3, passes: 1)

        var mask = [UInt8](repeating: 0, count: a.px.count)
        var hits = 0
        for i in 0..<a.px.count {
            let v = a.px[i]
            if v > 196 && v < 252 && photo.px[i] < 96 && nearInk.px[i] < 8 {
                mask[i] = 255; hits += 1
            }
        }
        guard hits > max(1200, a.px.count / 500) else { return (a, 0) }

        let m = Gray(w: a.w, h: a.h, px: mask)
        let dens = boxBlur(m, radius: 9, passes: 1)
        let soft = boxBlur(m, radius: 1, passes: 1)
        var out = a.px
        var removed = 0
        for i in 0..<out.count where mask[i] != 0 {
            if dens.px[i] > 209 { continue }          // >0.82：成片浅灰，保留
            let alpha = Float(soft.px[i]) / 255.0
            let v = Float(out[i]) * (1 - alpha) + 255 * alpha
            out[i] = UInt8(min(255, max(0, v.rounded())))
            removed += 1
        }
        return (Gray(w: a.w, h: a.h, px: out), Float(removed) / Float(max(1, out.count)))
    }

    static func paperSpanX(_ a: Gray, thr: Float = 250.5) -> (Int, Int)? {
        var colMean = [Float](repeating: 255, count: a.w)
        for x in 0..<a.w {
            var s = 0, n = 0
            for y in stride(from: 0, to: a.h, by: 4) { s += Int(a.px[y * a.w + x]); n += 1 }
            colMean[x] = Float(s) / Float(max(1, n))
        }
        let sm = boxBlur(Gray(w: a.w, h: 1, px: colMean.map { UInt8(min(255, max(0, $0.rounded()))) }),
                         radius: 12, passes: 1)
        var m = sm.px.map { Float($0) < thr }
        // close gaps up to 41 columns
        var i = 0
        while i < m.count {
            if m[i] {
                var j = i
                while j + 1 < m.count {
                    if m[j + 1] { j += 1; continue }
                    var g = 0
                    while j + 1 + g < m.count && !m[j + 1 + g] { g += 1 }
                    if g > 0 && g <= 41 && j + 1 + g < m.count && m[j + 1 + g] {
                        for k in (j + 1)..<(j + 1 + g) { m[k] = true }
                        j += 1 + g
                    } else { break }
                }
                i = j + 1
            } else { i += 1 }
        }
        var c = m.count / 2
        if c >= m.count || !m[c] {
            var best = -1, bestD = Int.max
            for k in 0..<m.count where m[k] && abs(k - c) < bestD { best = k; bestD = abs(k - c) }
            if best < 0 { return nil }
            c = best
        }
        var lo = c
        while lo > 0 && m[lo - 1] { lo -= 1 }
        var hi = c
        while hi < m.count - 1 && m[hi + 1] { hi += 1 }
        return (lo, hi + 1)
    }

    public static func cropBounds(_ a: Gray, notesCanvas: Bool) -> (Int, Int, Int, Int) {
        var rows = [Float](repeating: 0, count: a.h)
        var cols = [Float](repeating: 0, count: a.w)
        for y in 0..<a.h {
            var c = 0
            let row = y * a.w
            for x in 0..<a.w where a.px[row + x] < 200 { c += 1 }
            rows[y] = Float(c) / Float(a.w)
        }
        for x in 0..<a.w {
            var c = 0
            for y in stride(from: 0, to: a.h, by: 2) where a.px[y * a.w + x] < 200 { c += 1 }
            cols[x] = Float(c) / Float(a.h / 2)
        }
        func span(_ p: [Float], _ minF: Float) -> (Int, Int)? {
            var lo = -1, hi = -1
            for i in 0..<p.count where p[i] > minF { if lo < 0 { lo = i }; hi = i }
            return lo >= 0 ? (lo, hi) : nil
        }
        guard let ry = span(rows, 0.0015), let rx = span(cols, 0.0015) else { return (0, a.w, 0, a.h) }
        var x0 = rx.0, x1 = rx.1 + 1
        if notesCanvas, let p = paperSpanX(a) { x0 = min(x0, p.0); x1 = max(x1, p.1) }
        let padx = Int(0.018 * Float(a.w)), pady = Int(0.014 * Float(a.h))
        x0 = max(0, x0 - padx); x1 = min(a.w, x1 + padx)
        let y0 = max(0, ry.0 - pady), y1 = min(a.h, ry.1 + 1 + pady)
        if x1 - x0 >= Int(0.985 * Float(a.w)) && y1 - y0 >= Int(0.985 * Float(a.h)) {
            return (0, a.w, 0, a.h)
        }
        return (x0, x1, y0, y1)
    }

    static func crop(_ a: Gray, _ b: (Int, Int, Int, Int)) -> Gray {
        let w = b.1 - b.0, h = b.3 - b.2
        var px = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let src = (b.2 + y) * a.w + b.0
            px.replaceSubrange(y * w..<(y + 1) * w, with: a.px[src..<src + w])
        }
        return Gray(w: w, h: h, px: px)
    }

    // MARK: gate

    /// Fraction of the source's real strokes that still exist in the output.
    /// out is the cropped (and possibly resampled) page, so the mask has to be
    /// shifted by the crop origin before comparing.
    public static func strokeRetention(_ src: Gray, _ out: Gray,
                                       box: (Int, Int, Int, Int)) -> Float {
        let f = flatten(src)
        let photo = photoMask(f)
        let mask = strokeMask(f, photo: photo)
        let cw = max(1, box.1 - box.0), ch = max(1, box.3 - box.2)
        let sx = Float(out.w) / Float(cw)
        let sy = Float(out.h) / Float(ch)
        var total = 0, kept = 0
        for i in 0..<mask.count where mask[i] {
            let x = i % src.w, y = i / src.w
            guard x >= box.0, x < box.1, y >= box.2, y < box.3 else { continue }
            total += 1
            let ox = min(out.w - 1, Int(Float(x - box.0) * sx))
            let oy = min(out.h - 1, Int(Float(y - box.2) * sy))
            if out.px[oy * out.w + ox] < 215 { kept += 1 }
        }
        guard total > 500 else { return 1.0 }
        return Float(kept) / Float(total)
    }

    // MARK: document pipeline

    public static func process(_ src: URL, to dst: URL,
                               progress: ((String) -> Void)? = nil) -> Report {
        let t0 = Date()
        var rep = Report()
        let pages = renderPages(src)
        guard !pages.isEmpty else {
            rep.passed = false; rep.problems.append("PDF 无法渲染"); return rep
        }
        var dec = Decisions()
        var frames = false, canvasVotes = 0
        var gammas: [Float] = []
        for (i, a) in pages.enumerated() {
            let f = features(a)
            if f.borderMax > 0.25 || (f.ringMean - f.innerMean) < -15 { frames = true }
            if f.ringMean > 248 && (f.ringMean - f.innerMean) > 8 { canvasVotes += 1 }
            let fl = flatten(a)
            gammas.append(autoGamma(fl, photo: photoMask(fl)))
            progress?("分析 \(i + 1)/\(pages.count)")
        }
        dec.hasFrame = frames
        dec.notesCanvas = canvasVotes >= max(1, pages.count / 2)
        gammas.sort()
        dec.gammaText = gammas[gammas.count / 2]
        dec.gammaPhoto = min(max(dec.gammaText - 0.45, 1.0), 1.15)

        var crops: [Gray] = []
        var srcs: [Gray] = []
        var cropBoundsUsed: [(Int, Int, Int, Int)] = []
        for (i, a) in pages.enumerated() {
            let enhanced = enhance(a, gammaText: dec.gammaText, gammaPhoto: dec.gammaPhoto)
            var e = enhanced.0
            if enhanced.1 > 0.004 { dec.showThrough = true }
            if dec.hasFrame { e = stripFrame(e) }
            let b = cropBounds(e, notesCanvas: dec.notesCanvas)
            cropBoundsUsed.append(b)
            crops.append(crop(e, b))
            srcs.append(a)
            progress?("增强 \(i + 1)/\(pages.count)")
        }

        let a4w: CGFloat = 595.2756, a4h: CGFloat = 841.8898   // A4 竖向
        let inset: CGFloat = 4.0 / 25.4 * 72.0
        // 按内容方向选 A4 竖向 / 横向；整批用统一缩放，物理比例保持一致。
        func sheetSize(for g: Gray) -> CGSize {
            g.w >= g.h ? CGSize(width: a4h, height: a4w)   // 横向页
                       : CGSize(width: a4w, height: a4h)   // 竖向页
        }
        let baseScale = crops.map { c -> CGFloat in
            let s = sheetSize(for: c)
            let availW = s.width - 2 * inset, availH = s.height - 2 * inset
            return min(availW / CGFloat(max(1, c.w)), availH / CGFloat(max(1, c.h)))
        }.min() ?? 1
        let placedDPI = Float(72.0 / baseScale)
        if placedDPI < 230 { dec.upscale = min(3.0, max(1.0, 300.0 / placedDPI)) }
        let finalScale = baseScale / CGFloat(dec.upscale)
        let widthsMM = crops.map { Float($0.w) * Float(baseScale) / 72.0 * 25.4 }.sorted()
        dec.sheetWidthMM = widthsMM.isEmpty ? 0 : widthsMM[widthsMM.count / 2]

        var finalPages: [Gray] = []
        for (i, c) in crops.enumerated() {
            var g = c
            if dec.upscale != 1 {
                g = resize(g, factor: dec.upscale)
                g = darkenOnlySharpen(g)
            }
            finalPages.append(g)
            let ret = strokeRetention(srcs[i], g, box: cropBoundsUsed[i])
            dec.retention.append(ret)
            if ret < 0.97 {
                rep.passed = false
                rep.problems.append("第 \(i + 1) 页笔画保留 \(String(format: "%.1f", ret * 100))% < 97%")
            }
            progress?("校验 \(i + 1)/\(pages.count)")
        }
        writePDF(finalPages, to: dst, scale: finalScale, inset: inset)
        rep.pages = pages.count
        rep.decisions = dec
        rep.seconds = Date().timeIntervalSince(t0)
        return rep
    }

    static func stripFrame(_ a: Gray) -> Gray {
        // paint dark bands hugging the edges white, sweeping inward
        var out = a.px
        let step = 6
        let mx = Int(0.09 * Float(min(a.w, a.h)))
        func darkFrac(_ xs: Range<Int>, _ ys: Range<Int>) -> Float {
            var d = 0, n = 0
            for y in ys { for x in xs { if out[y * a.w + x] < 205 { d += 1 }; n += 1 } }
            return Float(d) / Float(max(1, n))
        }
        var r = 0
        while r < mx && darkFrac(0..<a.w, r..<r + step) > 0.30 {
            for y in r..<r + step { for x in 0..<a.w { out[y * a.w + x] = 255 } }
            r += step
        }
        r = 0
        while r < mx && darkFrac(0..<a.w, (a.h - step - r)..<(a.h - r)) > 0.30 {
            for y in (a.h - step - r)..<(a.h - r) { for x in 0..<a.w { out[y * a.w + x] = 255 } }
            r += step
        }
        r = 0
        while r < mx && darkFrac(r..<r + step, 0..<a.h) > 0.30 {
            for y in 0..<a.h { for x in r..<r + step { out[y * a.w + x] = 255 } }
            r += step
        }
        r = 0
        while r < mx && darkFrac((a.w - step - r)..<(a.w - r), 0..<a.h) > 0.30 {
            for y in 0..<a.h { for x in (a.w - step - r)..<(a.w - r) { out[y * a.w + x] = 255 } }
            r += step
        }
        return Gray(w: a.w, h: a.h, px: out)
    }

    static func darkenOnlySharpen(_ g: Gray) -> Gray {
        let blur = boxBlur(g, radius: 2, passes: 1)
        var out = g.px
        for i in 0..<out.count {
            let d = Int(out[i]) - Int(blur.px[i])
            if d < -4 { out[i] = UInt8(max(0, Int(out[i]) + d * 60 / 100)) }
        }
        return Gray(w: g.w, h: g.h, px: out)
    }

    // MARK: pdf output

    public static func writePDF(_ pages: [Gray], to url: URL,
                                scale: CGFloat, inset: CGFloat) {
        let a4w: CGFloat = 595.2756, a4h: CGFloat = 841.8898
        var box = CGRect(x: 0, y: 0, width: a4w, height: a4h)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        for g in pages {
            // 每页独立设置 MediaBox：横向内容用横向 A4，避免被竖向页面裁掉。
            let size = g.w >= g.h ? CGSize(width: a4h, height: a4w)
                                  : CGSize(width: a4w, height: a4h)
            // 注意：kCGPDFContextMediaBox 的值必须是「装着 CGRect 字节的 CFData」，
            // 直接传 CGRect 会被忽略，页面仍旧沿用 context 的默认竖向尺寸。
            let mediaBox = CGRect(origin: .zero, size: size)
            let boxData = withUnsafeBytes(of: mediaBox) { Data($0) } as CFData
            let info: [CFString: Any] = [kCGPDFContextMediaBox: boxData]
            ctx.beginPDFPage(info as CFDictionary)
            if let cg = cgImage(g) {
                let rw = CGFloat(g.w) * scale, rh = CGFloat(g.h) * scale
                let rect = CGRect(x: (size.width - rw) / 2,
                                  y: size.height - inset - rh,
                                  width: rw, height: rh)
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: rect)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}
