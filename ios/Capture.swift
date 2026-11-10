import Foundation
import SwiftUI
import UIKit
import Vision
import VisionKit
import PDFKit
import CoreImage

// MARK: - 拍照扫描 + 本机 OCR
//
// 这一层完全不联网：
//  · VisionKit 的文档相机负责多页拍摄、自动找边与透视矫正；
//  · Vision 的 VNRecognizeTextRequest 负责中英文文字识别（系统自带模型，零体积）；
//  · 拍到的图片先合成 PDF，再交给 ScanCore 走同一套清晰化 / A4 / 质量闸门流程。
//
// 更重的结构化解析（整页 Markdown、表格、字段 JSON）由 Python 参考引擎里
// 可选的 Xiaomi-OCR-0 后端提供，见 python/ocr_xiaomi.py。

// MARK: - 页面指纹：自动连拍去重

/// 32×32 灰度 + 64 位 dHash。纯本地运算，不依赖任何模型。
enum PageFingerprint {
    static let n = 32

    static func gray(_ image: UIImage) -> [UInt8]? {
        guard let cg = image.cgImage,
              let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8,
                                  bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let p = ctx.data else { return nil }
        let buf = p.bindMemory(to: UInt8.self, capacity: n * n)
        return (0..<(n * n)).map { buf[$0] }
    }

    /// 把灰度图降成 9×8 均值网格，比较水平梯度得到 64 位哈希。
    static func dHash(_ g: [UInt8]) -> UInt64 {
        var small = [UInt8](repeating: 0, count: 9 * 8)
        for y in 0..<8 {
            for x in 0..<9 {
                let x0 = Int(CGFloat(x) * 32 / 9)
                let x1 = max(x0 + 1, Int(CGFloat(x + 1) * 32 / 9))
                var sum = 0, count = 0
                for yy in (y * 4)..<((y + 1) * 4) {
                    for xx in x0..<min(32, x1) {
                        sum += Int(g[yy * 32 + xx]); count += 1
                    }
                }
                small[y * 9 + x] = UInt8(clamping: sum / max(1, count))
            }
        }
        var h: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 where small[y * 9 + x] > small[y * 9 + x + 1] {
                h |= (UInt64(1) << UInt64(y * 8 + x))
            }
        }
        return h
    }

    static func distance(_ a: UInt64, _ b: UInt64) -> Int {
        var v = a ^ b, c = 0
        while v != 0 { v &= v - 1; c += 1 }
        return c
    }

    static func meanDiff(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count, !a.isEmpty else { return 255 }
        var s = 0
        for i in a.indices { s += abs(Int(a[i]) - Int(b[i])) }
        return s / a.count
    }

    /// 纹理能量：太低说明画面糊成一片或完全虚焦，不值得拍。
    static func sharpness(_ g: [UInt8]) -> Int {
        var s = 0
        for y in 1..<n {
            for x in 1..<n {
                s += abs(Int(g[y * n + x]) - Int(g[y * n + x - 1]))
            }
        }
        return s / ((n - 1) * (n - 1))
    }
}

struct OCRLine {
    let text: String
    /// 归一化坐标，原点在左下（Vision 的原始输出）
    let rect: CGRect
}

struct OCRPage {
    let lines: [OCRLine]
}

enum Capture {
    static var scannerSupported: Bool {
        VNDocumentCameraViewController.isSupported
    }

    /// 找边预处理的三档策略。
    enum RectifyMode {
        /// 系统文档相机：只有检测到仍带桌面背景的页才补裁，其余原样保留。
        case auto
        /// 相册原帧：逐页尝试找边 + 透视矫正，找不到才用原图。
        case always
    }

    struct PageSignature {
        let gray: [UInt8]
        let hash: UInt64
    }

    static func signature(_ image: UIImage) -> PageSignature? {
        guard let g = PageFingerprint.gray(image) else { return nil }
        return PageSignature(gray: g, hash: PageFingerprint.dHash(g))
    }

    /// 剔除自动连拍带进来的重复页。系统文档相机的自动快门无法从外部关掉，
    /// 来不及翻页时同一页会被连拍好几次，只能在收结果时去重。
    ///
    /// 两档阈值：相邻页用宽松阈值（拍同一页时手抖/曝光差异较大），
    /// 非相邻页用严格阈值（几乎逐像素相同才判重复），
    /// 这样 A-B-A 式连拍能去掉，版式相近但内容不同的两页不会被误删。
    static func isDuplicate(_ s: PageSignature, kept: [PageSignature]) -> Bool {
        if let last = kept.last,
           PageFingerprint.distance(last.hash, s.hash) <= 10,
           PageFingerprint.meanDiff(last.gray, s.gray) <= 9 { return true }
        return kept.contains { k in
            PageFingerprint.distance(k.hash, s.hash) <= 5
                && PageFingerprint.meanDiff(k.gray, s.gray) <= 5
        }
    }

    /// 分成「保留页 / 判为重复的页」两堆，检查页据此提供「恢复」按钮。
    static func splitPages(_ images: [UIImage]) -> (kept: [UIImage], dropped: [UIImage]) {
        var kept: [UIImage] = [], dropped: [UIImage] = [], sigs: [PageSignature] = []
        for img in images {
            guard let s = signature(img) else { kept.append(img); continue }
            if isDuplicate(s, kept: sigs) { dropped.append(img) }
            else { kept.append(img); sigs.append(s) }
        }
        return (kept, dropped)
    }

    static func uniquePages(_ images: [UIImage]) -> [UIImage] { splitPages(images).kept }

    // MARK: - 图像整理（检查页与引擎共用的入口预处理）

    /// 统一为 .up 方向，并把长边压到 2600px：手机 4000px 原图直接进 OCR /
    /// ScanCore 很容易吃满内存；2600px 对 A4 300dpi 仍然绰绰有余。
    static func normalized(_ image: UIImage, maxSide: CGFloat = 2600) -> UIImage {
        guard let cg = uprightCG(image) else { return image }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let k = min(1, maxSide / max(w, h))
        if k >= 1, image.imageOrientation == .up { return image }
        let size = CGSize(width: max(1, round(w * k)), height: max(1, round(h * k)))
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            UIImage(cgImage: cg, scale: 1, orientation: .up)
                .draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 顺时针旋转并真正重绘成 .up，下游 OCR / PDF 不需要再猜 EXIF 方向。
    static func rotated(_ image: UIImage, degrees: Int) -> UIImage {
        let r = ((degrees % 360) + 360) % 360
        guard r != 0, let cg = uprightCG(image) else { return image }
        let s = CGSize(width: CGFloat(cg.width), height: CGFloat(cg.height))
        let swap = r == 90 || r == 270
        let out = swap ? CGSize(width: s.height, height: s.width) : s
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: out, format: fmt).image { ctx in
            let c = ctx.cgContext
            c.translateBy(x: out.width / 2, y: out.height / 2)
            c.rotate(by: CGFloat(r) * .pi / 180)
            UIImage(cgImage: cg, scale: 1, orientation: .up)
                .draw(in: CGRect(x: -s.width / 2, y: -s.height / 2,
                                 width: s.width, height: s.height))
        }
    }

    static func thumbnail(_ image: UIImage, width: CGFloat = 360) -> UIImage? {
        let s = image.size
        guard s.width > 1, s.height > 1 else { return nil }
        let size = CGSize(width: width, height: max(1, s.height * width / s.width))
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 判断系统相机这一页是否「还带着桌面 / 阴影」：四周边框明显暗于纸面中心。
    /// 已裁好的白底扫描件哪怕有横线、页眉，边缘均值依旧接近纸白，不会误判。
    static func needsRectify(_ image: UIImage) -> Bool {
        guard let cg = uprightCG(image), let g = graySmall(cg, w: 64, h: 64) else { return false }
        let b = 4
        var edge = 0, edgeN = 0, center = 0, centerN = 0
        for y in 0..<64 {
            for x in 0..<64 {
                let v = Int(g[y * 64 + x])
                if x < b || x >= 64 - b || y < b || y >= 64 - b { edge += v; edgeN += 1 }
                if x >= 21 && x < 43 && y >= 21 && y < 43 { center += v; centerN += 1 }
            }
        }
        return center / max(1, centerN) - edge / max(1, edgeN) > 32
    }

    // MARK: - 纸张找边 + 透视矫正（拍照链路的入口预处理）
    //
    // 系统文档相机（VNDocumentCameraViewController）吐出来的已经是裁好边、
    // 矫正过透视、做过画质增强的纸面图，不需要也不能再动一次。
// 但从相册导入的照片给的是原始画面：带桌面、阴影、歪斜。
// 系统文档相机偶尔也会裁边失败、返回仍带背景的整帧。
// 直接喂给 ScanCore 的话，平场归一化会把深色桌面
    // 当成纸白、裁边会把整帧当内容，出来的就是「瑕疵品」。
    //
    // 这里先用 Vision 的文档分割（比通用矩形检测更适合试卷）找到纸张四角，
    // 做透视矫正，把画面变成干净的纸面图，再交给同一套扫描清理引擎。

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// 统一成 .up 方向，避免 EXIF 旋转让四角坐标对不上。
    private static func uprightCG(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up { return image.cgImage }
        let s = image.size
        guard s.width > 1, s.height > 1 else { return nil }
        UIGraphicsBeginImageContextWithOptions(s, false, 1)
        defer { UIGraphicsEndImageContext() }
        image.draw(in: CGRect(origin: .zero, size: s))
        return UIGraphicsGetImageFromCurrentImageContext()?.cgImage
    }

    /// 归一化四角，原点在左下（与 Vision 的输出一致）。
    struct PaperCorners {
        let tl: CGPoint, tr: CGPoint, br: CGPoint, bl: CGPoint
    }

    private static func graySmall(_ cg: CGImage, w: Int, h: Int) -> [UInt8]? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let p = ctx.data else { return nil }
        let buf = p.bindMemory(to: UInt8.self, capacity: w * h)
        return (0..<(w * h)).map { buf[$0] }
    }

    private static func otsu(_ g: [UInt8]) -> Int {
        var hist = [Int](repeating: 0, count: 256)
        for v in g { hist[Int(v)] += 1 }
        let total = g.count
        var sumAll = 0
        for i in 0..<256 { sumAll += i * hist[i] }
        var wB = 0, sumB = 0, best = -1.0, thr = 190
        for t in 0..<256 {
            wB += hist[t]
            if wB == 0 { continue }
            let wF = total - wB
            if wF == 0 { break }
            sumB += t * hist[t]
            let mB = Double(sumB) / Double(wB)
            let mF = Double(sumAll - sumB) / Double(wF)
            let between = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
            if between > best { best = between; thr = t }
        }
        return thr
    }

    /// 不依赖任何模型的几何找边：亮纸 + 暗背景时，逐行找最长的亮段，
    /// 用最小二乘拟合左右两条纸边，再取上下边界，得到透视四角。
    /// Vision 的文档分割在合成图、低纹理或极端光照下会返回空，这一步兜住它。
    private static func geometricQuad(_ cg: CGImage) -> PaperCorners? {
        let W = 160
        let H = max(120, Int(CGFloat(W) * CGFloat(cg.height) / CGFloat(cg.width)))
        guard let g = graySmall(cg, w: W, h: H) else { return nil }
        func mean(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
            var s = 0, n = 0
            for y in y0..<y1 { for x in x0..<x1 { s += Int(g[y * W + x]); n += 1 } }
            return n > 0 ? s / n : 0
        }
        // 只有「四周明显比中心暗」才动手：已经裁好的扫描件不会被误裁。
        let bw = max(2, W / 25), bh = max(2, H / 25)
        let border = (mean(0, 0, W, bh) + mean(0, H - bh, W, H)
                      + mean(0, 0, bw, H) + mean(W - bw, 0, W, H)) / 4
        let center = mean(W / 3, H / 3, 2 * W / 3, 2 * H / 3)
        guard center - border > 35 else { return nil }

        let thr = otsu(g)
        func longest(_ y: Int) -> (Int, Int)? {
            var best = 0, bestStart = 0, start = -1
            for x in 0..<W {
                if Int(g[y * W + x]) > thr {
                    if start < 0 { start = x }
                } else if start >= 0 {
                    let len = x - start
                    if len > best { best = len; bestStart = start }
                    start = -1
                }
            }
            if start >= 0 && W - start > best { best = W - start; bestStart = start }
            return best >= W / 4 ? (bestStart, bestStart + best) : nil
        }
        var raw: [(Int, Int, Int)] = []
        var y = Int(0.05 * Double(H))
        while y < Int(0.95 * Double(H)) {
            if let r = longest(y) { raw.append((y, r.0, r.1)) }
            y += 2
        }
        guard raw.count >= 12 else { return nil }
        let widths = raw.map { $0.2 - $0.1 }.sorted()
        let medW = widths[widths.count / 2]
        guard medW > W / 5, medW < W * 95 / 100 else { return nil }
        let good = raw.filter { abs(($0.2 - $0.1) - medW) <= max(8, medW / 4) }
        guard good.count >= 10 else { return nil }

        func fit(_ pick: (Int, Int, Int) -> Int) -> (Double, Double) {
            var sy = 0.0, sx = 0.0, sxy = 0.0, syy = 0.0
            let n = Double(good.count)
            for s in good {
                let yy = Double(s.0), xx = Double(pick(s.0, s.1, s.2))
                sy += yy; sx += xx; sxy += xx * yy; syy += yy * yy
            }
            let den = n * syy - sy * sy
            if abs(den) < 0.0001 { return (0, sx / n) }
            let a = (n * sxy - sy * sx) / den
            return (a, (sx - a * sy) / n)
        }
        let L = fit { _, l, _ in l }
        let R = fit { _, _, r in r }
        let yT = Double(good.first!.0), yB = Double(good.last!.0)
        let lT = L.0 * yT + L.1, rT = R.0 * yT + R.1
        let lB = L.0 * yB + L.1, rB = R.0 * yB + R.1
        guard rT - lT > Double(W) / 5, rB - lB > Double(W) / 5 else { return nil }
        let area = ((rT - lT + rB - lB) / 2) * (yB - yT) / Double(W * H)
        guard area > 0.15, area < 0.97 else { return nil }
        func nx(_ v: Double) -> CGFloat { CGFloat(min(1, max(0, v / Double(W)))) }
        func ny(_ v: Double) -> CGFloat { CGFloat(min(1, max(0, 1 - v / Double(H)))) }
        // CGContext 的行是自上而下，CIPerspectiveCorrection 用左下原点，y 要翻过来。
        return PaperCorners(tl: CGPoint(x: nx(lT), y: ny(yT)),
                            tr: CGPoint(x: nx(rT), y: ny(yT)),
                            br: CGPoint(x: nx(rB), y: ny(yB)),
                            bl: CGPoint(x: nx(lB), y: ny(yB)))
    }

    private static func visionQuad(_ cg: CGImage) -> PaperCorners? {
        let req = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do { try handler.perform([req]) } catch { return nil }
        guard let o = req.results?.first else { return nil }
        return PaperCorners(tl: o.topLeft, tr: o.topRight,
                            br: o.bottomRight, bl: o.bottomLeft)
    }

    /// 返回 nil 表示「没有可靠的纸边」——调用方直接用原图，不做任何猜测式裁剪。
    static func rectify(_ image: UIImage) -> UIImage? {
        guard let cg = uprightCG(image) else { return nil }
        // 几乎占满整帧 = 系统相机已经裁好；太小 / 太扁 = 把试卷里的表格框当成纸了。
        func valid(_ c: PaperCorners) -> Bool {
            let xs = [c.tl.x, c.tr.x, c.br.x, c.bl.x]
            let ys = [c.tl.y, c.tr.y, c.br.y, c.bl.y]
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max() else { return false }
            let w = maxX - minX, h = maxY - minY
            let ratio = w / max(0.0001, h)
            return w * h >= 0.16 && w * h <= 0.965
                && w > 0.28 && h > 0.28 && ratio > 0.30 && ratio < 3.4
        }
        // Vision 没结果、或者给了一个明显不合理的框，都退到几何找边。
        var corners = visionQuad(cg).flatMap { valid($0) ? $0 : nil }
        if corners == nil { corners = geometricQuad(cg).flatMap { valid($0) ? $0 : nil } }
        guard let c0 = corners else { return nil }
        // 四角统一向纸心收 2%：拟合不可能精确到像素，留一点余量，
        // 免得透视插值把纸外的桌面像素拖成一条淡灰虚线。
        let x0 = [c0.tl.x, c0.tr.x, c0.br.x, c0.bl.x].min() ?? 0
        let x1 = [c0.tl.x, c0.tr.x, c0.br.x, c0.bl.x].max() ?? 1
        let y0 = [c0.tl.y, c0.tr.y, c0.br.y, c0.bl.y].min() ?? 0
        let y1 = [c0.tl.y, c0.tr.y, c0.br.y, c0.bl.y].max() ?? 1
        let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2
        func inset(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x + (cx - p.x) * 0.02, y: p.y + (cy - p.y) * 0.02)
        }
        let c = PaperCorners(tl: inset(c0.tl), tr: inset(c0.tr),
                             br: inset(c0.br), bl: inset(c0.bl))

        let ci = CIImage(cgImage: cg)
        let e = ci.extent
        func px(_ p: CGPoint) -> CIVector {
            CIVector(cgPoint: CGPoint(x: e.minX + p.x * e.width,
                                      y: e.minY + p.y * e.height))
        }
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(px(c.tl), forKey: "inputTopLeft")
        filter.setValue(px(c.tr), forKey: "inputTopRight")
        filter.setValue(px(c.br), forKey: "inputBottomRight")
        filter.setValue(px(c.bl), forKey: "inputBottomLeft")
        guard var out = filter.outputImage else { return nil }
        // 手机照片动辄 4000px，先压到合理长边，避免后面 OCR / 引擎爆内存。
        let maxSide: CGFloat = 2600
        let k = min(1, maxSide / max(out.extent.width, out.extent.height))
        if k < 1 { out = out.transformed(by: CGAffineTransform(scaleX: k, y: k)) }
        let box = out.extent.integral
        guard box.width > 200, box.height > 200,
              let cg2 = ciContext.createCGImage(out, from: box) else { return nil }
        return UIImage(cgImage: cg2, scale: 1, orientation: .up)
    }

    /// 逐页矫正；返回矫正后的页与真正被裁过边的页数。
    /// `.auto` 只处理仍带背景的页（系统文档相机），`.always` 逐页尝试（相册原帧）。
    static func prepare(_ images: [UIImage], mode: RectifyMode = .always)
        -> (pages: [UIImage], rectified: Int) {
        var out: [UIImage] = []
        var count = 0
        for img in images {
            let should = mode == .always || needsRectify(img)
            if should, let r = rectify(img) { out.append(r); count += 1 }
            else { out.append(img) }
        }
        return (out, count)
    }

    /// 多张图片 → 一份按图片比例分页的临时 PDF，可直接喂给 ScanCore.process。
    static func pdf(from images: [UIImage], to url: URL) -> Bool {
        guard !images.isEmpty else { return false }
        try? FileManager.default.removeItem(at: url)
        UIGraphicsBeginPDFContextToFile(url.path, .zero, nil)
        for img in images {
            let s = img.size
            guard s.width > 1, s.height > 1 else { continue }
            // 150 dpi 换算成 pt，同时限制上限，避免手机 4000px 照片撑出巨大的 MediaBox
            let k = min(900 / s.width, 1300 / s.height, 72.0 / 150.0)
            let page = CGSize(width: max(200, s.width * k), height: max(200, s.height * k))
            UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: page), nil)
            img.draw(in: CGRect(origin: .zero, size: page))
        }
        UIGraphicsEndPDFContext()
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// 同步识别，调用方负责放在后台队列。失败时返回空页，不影响主流程。
    static func recognize(_ images: [UIImage]) -> [OCRPage] {
        var out: [OCRPage] = []
        for img in images {
            guard let cg = img.cgImage else {
                out.append(OCRPage(lines: []))
                continue
            }
            out.append(recognizePage(cg, languages: ["zh-Hans", "en-US"]))
        }
        return out
    }

    private static func recognizePage(_ cg: CGImage, languages: [String]) -> OCRPage {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = languages
        req.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([req])
        } catch {
            // 某些系统版本不接受混合语言列表，退回英文再试一次
            if languages.count > 1 { return recognizePage(cg, languages: ["en-US"]) }
            return OCRPage(lines: [])
        }
        let lines = req.results?.compactMap { o -> OCRLine? in
            guard let t = o.topCandidates(1).first?.string, !t.isEmpty else { return nil }
            return OCRLine(text: t, rect: o.boundingBox)
        } ?? []
        if lines.isEmpty, languages.count > 1 { return recognizePage(cg, languages: ["en-US"]) }
        return OCRPage(lines: lines)
    }

    /// 文字稿：按页分隔，纯文本 / Markdown 编辑器都能直接用。
    static func text(_ pages: [OCRPage]) -> String {
        pages.enumerated().map { i, p in
            let body = p.lines.map(\.text).joined(separator: "\n")
            return "## 第 \(i + 1) 页\n\n" + (body.isEmpty ? "（本页未识别到文字）" : body)
        }.joined(separator: "\n\n")
    }

    /// 用首页最像标题的一行给文件自动命名，拍完就能直接归档。
    static func suggestedName(_ pages: [OCRPage]) -> String? {
        for line in pages.first?.lines.prefix(6) ?? [] {
            let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 4, t.count <= 30 else { continue }
            let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
            let clean = t.components(separatedBy: bad).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.count >= 4 { return String(clean.prefix(30)) }
        }
        return nil
    }
}

// MARK: - 系统文档相机

struct DocumentScanner: UIViewControllerRepresentable {
    let done: ([UIImage]) -> Void
    var cancel: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(done: done, cancel: cancel) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let done: ([UIImage]) -> Void
        let cancel: (() -> Void)?
        init(done: @escaping ([UIImage]) -> Void, cancel: (() -> Void)?) {
            self.done = done
            self.cancel = cancel
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            var imgs: [UIImage] = []
            for i in 0..<scan.pageCount { imgs.append(scan.imageOfPage(at: i)) }
            controller.dismiss(animated: true) { self.done(imgs) }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true) { self.cancel?() }
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            controller.dismiss(animated: true) { self.cancel?() }
        }
    }
}
