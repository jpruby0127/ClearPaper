import Foundation
import SwiftUI
import UIKit
import Vision
import VisionKit
import PDFKit

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

    /// 剔除自动连拍带进来的重复页。dHash 与灰度均差同时命中才丢，
    /// 版式相近但内容不同的两页（比如同一份卷子的第 1、2 页）不会被误删。
    static func uniquePages(_ images: [UIImage]) -> [UIImage] {
        var out: [UIImage] = []
        var lastGray: [UInt8]?
        var lastHash: UInt64?
        for img in images {
            guard let g = PageFingerprint.gray(img) else { out.append(img); continue }
            let h = PageFingerprint.dHash(g)
            if let lh = lastHash, PageFingerprint.distance(lh, h) <= 10,
               let lg = lastGray, PageFingerprint.meanDiff(lg, g) <= 9 {
                continue
            }
            out.append(img)
            lastGray = g
            lastHash = h
        }
        return out
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
