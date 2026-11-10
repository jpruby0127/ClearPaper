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

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let done: ([UIImage]) -> Void
        init(done: @escaping ([UIImage]) -> Void) { self.done = done }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            var imgs: [UIImage] = []
            for i in 0..<scan.pageCount { imgs.append(scan.imageOfPage(at: i)) }
            controller.dismiss(animated: true) { self.done(imgs) }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            controller.dismiss(animated: true)
        }
    }
}
