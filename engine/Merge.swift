import Foundation
import CoreGraphics
import PDFKit

// 多份 PDF 合并：macOS 与 iOS 共用同一份实现。
// 两种合并语义在双端保持一致，避免「电脑上双面不跨卷、手机上却跨卷」。

public enum MergeMode: Int, CaseIterable {
    case separate = 0   // 分别保存，不合并
    case full = 1       // 完全合并：按添加顺序首尾相接
    case duplex = 2     // 间隔合并：每份后补空白页，双面打印不跨卷
}

/// 生成一张与给定页面同尺寸的空白 PDF 页。
public func blankPDFPage(size: CGSize) -> PDFPage? {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
    var box = CGRect(origin: .zero, size: size)
    guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
    ctx.beginPage(mediaBox: &box)
    ctx.endPage()
    ctx.closePDF()
    guard let doc = PDFDocument(data: data as Data) else { return nil }
    return doc.page(at: 0)
}

/// 按顺序合并；duplex 模式下为每份非末尾文档补齐到偶数页（补空白页）。
/// 返回合并后的总页数，失败返回 0。
public func mergePDFs(_ urls: [URL], mode: MergeMode, to out: URL,
                      progress: ((String) -> Void)? = nil) -> Int {
    let merged = PDFDocument()
    for (idx, url) in urls.enumerated() {
        guard let doc = PDFDocument(url: url) else { continue }
        let n = doc.pageCount
        guard n > 0 else { continue }
        progress?("合并 \(idx + 1)/\(urls.count)")
        let lastSize = doc.page(at: n - 1)?.bounds(for: .mediaBox).size
            ?? CGSize(width: 595.28, height: 841.89)
        for i in 0..<n {
            if let page = doc.page(at: i) {
                merged.insert(page, at: merged.pageCount)
            }
        }
        if mode == .duplex, idx < urls.count - 1, n % 2 == 1 {
            if let blank = blankPDFPage(size: lastSize) {
                merged.insert(blank, at: merged.pageCount)
            } else {
                return 0
            }
        }
    }
    guard merged.pageCount > 0 else { return 0 }
    return merged.write(to: out) ? merged.pageCount : 0
}
