import SwiftUI
import UIKit
import PDFKit
import PhotosUI
import UniformTypeIdentifiers

// ClearPaper · iOS 原生版
// 清理引擎（engine/Core.swift）与合并引擎（engine/Merge.swift）直接编译进包：
// 无服务端、不联网、不需要 Python。UI 与 macOS 端共用同一套暖灰设计语言。

// MARK: - 设计令牌（与 macOS 的 T 一一对应）

enum Pal {
    static func rgb(_ v: UInt32) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    static func dyn(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { t in t.userInterfaceStyle == .dark ? rgb(dark) : rgb(light) }
    }
    static func c(_ light: UInt32, _ dark: UInt32) -> Color { Color(uiColor: dyn(light, dark)) }

    static let canvas     = c(0xF6F6F7, 0x1C1C1E)
    static let sidebar    = c(0xEBEBEE, 0x262628)
    static let panel      = c(0xFFFFFF, 0x2A2A2D)
    static let panel2     = c(0xFAFAFB, 0x232326)
    static let ink        = c(0x1B1B1E, 0xF2F2F4)
    static let ink2       = c(0x3A3A3F, 0xC9C9CE)
    static let sub        = c(0x6C6C72, 0x9A9AA0)
    static let mute       = c(0x9A9AA0, 0x6E6E74)
    static let line       = c(0xE4E4E8, 0x3A3A3D)
    static let graySoft   = c(0xEDEDF0, 0x343437)
    static let amber      = c(0xE08A00, 0xF0A83C)
    static let amberSoft  = c(0xFFF3DC, 0x3A2B12)
    static let green      = c(0x12A374, 0x35C79B)
    static let greenSoft  = c(0xE6F6F0, 0x163024)
    static let blue       = c(0x2F6BFF, 0x6B9BFF)
    static let blueSoft   = c(0xEAF0FF, 0x1E2A44)
    static let red        = c(0xE5484D, 0xFF6B6F)
    static let redSoft    = c(0xFDECEC, 0x3A2023)
}

// MARK: - 版本 / 品牌

enum About {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.5.0"
    }
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "7"
    }
    static var versionLine: String { "版本 \(version) (\(build))" }
    static let author = "jpruby"
    static let repo = "https://github.com/jpruby0127/ClearPaper"
    static var logo: UIImage? {
        guard let p = Bundle.main.url(forResource: "Logo", withExtension: "png") else { return nil }
        return UIImage(contentsOfFile: p.path)
    }
}

enum Tab: Int { case process = 0, merge = 1, files = 2, about = 3 }

struct URLItem: Identifiable { let id = UUID(); let url: URL }

enum Sheet: Identifiable {
    case preview(URL), share(URL), export(URL), text(URL), scanner
    var id: String {
        switch self {
        case .preview(let u): return "p-\(u.absoluteString)"
        case .share(let u): return "s-\(u.absoluteString)"
        case .export(let u): return "e-\(u.absoluteString)"
        case .text(let u): return "t-\(u.absoluteString)"
        case .scanner: return "scanner"
        }
    }
}

// MARK: - 路由：预览 / 分享 / 存文件 / 导入 / 拍照 / 切换页

final class Router: ObservableObject {
    @Published var sheet: Sheet?
    @Published var picking = false
    @Published var requestedTab: Tab?

    func show(_ u: URL) { sheet = .preview(u) }
    func share(_ u: URL) { sheet = .share(u) }
    func save(_ u: URL) { sheet = .export(u) }
    func showText(_ u: URL) { sheet = .text(u) }
    func pick() { picking = true }
    func scan() { sheet = .scanner }
    func close() { sheet = nil }
    func goto(_ t: Tab) { requestedTab = t }
}

// MARK: - 模型

enum JobState: Equatable {
    case queued, working, done, failed(String)
}

final class Job: Identifiable, ObservableObject {
    let id = UUID()
    var url: URL                 // 拍照任务先占位，合成 PDF 后在后台替换
    @Published var name: String
    var outputStem: String?      // OCR 识别出的标题，用于给输出文件命名
    @Published var textURL: URL?
    @Published var ocrLines = 0
    @Published var captured = false
    @Published var state: JobState = .queued
    @Published var progress: Double = 0
    @Published var phase = "准备中…"
    @Published var pages = 0
    @Published var retention: Float = 1
    @Published var sheetMM: Float = 0
    @Published var seconds: Double = 0
    @Published var showThrough = false
    @Published var result: URL?
    @Published var thumb: UIImage?
    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent
    }
}

struct OutFile: Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
    let date: Date
    let pages: Int
    let isText: Bool
    var name: String { url.lastPathComponent }
}

// MARK: - 数据仓库

final class Store: ObservableObject {
    @Published var jobs: [Job] = []
    @Published var files: [OutFile] = []
    @Published var mergeURLs: [URL] = []
    @Published var mergeMode: MergeMode = .full
    @Published var mergeResult: URL?
    @Published var mergePages = 0
    @Published var mergeMessage = ""
    @Published var merging = false
    @Published var busy = false

    @Published var deghost: Bool {
        didSet {
            UserDefaults.standard.set(deghost, forKey: "cp.deghost")
            ScanCore.deghostEnabled = deghost
        }
    }
    @Published var autoProcess: Bool {
        didSet { UserDefaults.standard.set(autoProcess, forKey: "cp.auto") }
    }
    @Published var appearance: Int {
        didSet { UserDefaults.standard.set(appearance, forKey: "cp.appearance") }
    }

    var scheme: ColorScheme? {
        appearance == 1 ? .light : (appearance == 2 ? .dark : nil)
    }

    private let queue = DispatchQueue(label: "clearpaper.engine", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "clearpaper.files", qos: .utility)
    private let importedKey = "clearpaper.importedPDFs"

    init() {
        let d = UserDefaults.standard
        deghost = d.object(forKey: "cp.deghost") as? Bool ?? true
        autoProcess = d.object(forKey: "cp.auto") as? Bool ?? true
        appearance = d.object(forKey: "cp.appearance") as? Int ?? 0
        if let n = d.object(forKey: "cp.mergeMode") as? Int,
           let m = MergeMode(rawValue: n) { mergeMode = m }
        ScanCore.deghostEnabled = deghost
    }

    var docsDir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("清晰版", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// 外部来源（文件 App / 微信）是安全作用域 URL，先复制到唯一的临时目录。
    /// 目录唯一但保留原文件名，避免任务列表与输出文件出现 UUID 前缀。
    static func stage(_ u: URL) -> URL? {
        let fm = FileManager.default
        let scoped = u.startAccessingSecurityScopedResource()
        defer { if scoped { u.stopAccessingSecurityScopedResource() } }
        let dir = fm.temporaryDirectory
            .appendingPathComponent("ClearPaper-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dst = dir.appendingPathComponent(u.lastPathComponent)
            try fm.copyItem(at: u, to: dst)
            return dst
        } catch { return nil }
    }

    /// 「文件」App / iTunes 共享放进 Documents 的 PDF 会在启动时自动加入。
    func importInbox() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let items = try? fm.contentsOfDirectory(
            at: docs, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)
        else { return }
        let seen = Set(UserDefaults.standard.stringArray(forKey: importedKey) ?? [])
        var seenNow = seen
        var fresh: [URL] = []
        for u in items where u.pathExtension.lowercased() == "pdf"
            && !u.lastPathComponent.contains("清晰版") {
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let key = "\(u.lastPathComponent)-\(size)"
            if !seen.contains(key) { fresh.append(u); seenNow.insert(key) }
        }
        UserDefaults.standard.set(Array(seenNow), forKey: importedKey)
        if !fresh.isEmpty { add(fresh) }
        refreshFiles()
    }

    // MARK: 任务

    /// 拍照 / 相册图片 → PDF → 本机 OCR → 文字稿 → 走同一套清晰化流程。
    /// 识别出的首页标题会同时用作任务名与输出文件名，拍完即可归档。
    func addCaptured(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        let fm = FileManager.default
        let placeholder = fm.temporaryDirectory
            .appendingPathComponent("拍摄-\(UUID().uuidString).pdf")
        let j = Job(url: placeholder)
        j.state = .working
        j.captured = true
        j.phase = "整理拍摄件…"
        jobs.insert(j, at: 0)
        busy = true

        queue.async { [weak self] in
            guard let self else { return }
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyyMMdd-HHmmss"
            let stamp = df.string(from: Date())
            let pdf = fm.temporaryDirectory.appendingPathComponent("拍摄-\(stamp).pdf")
            guard Capture.pdf(from: images, to: pdf) else {
                DispatchQueue.main.async {
                    j.state = .failed("拍摄件合成 PDF 失败")
                    j.phase = "未通过"
                    self.busy = self.jobs.contains { $0.state == .working }
                }
                return
            }
            let ocr = Capture.recognize(images)
            let title = Capture.suggestedName(ocr) ?? "拍摄-\(stamp)"
            let stem = String(title.prefix(40))
                .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r"))
                .joined()
            let txt = self.docsDir.appendingPathComponent(stem + "-文字.txt")
            try? Capture.text(ocr).write(to: txt, atomically: true, encoding: .utf8)

            j.url = pdf
            j.outputStem = stem
            let lineCount = ocr.reduce(0) { $0 + $1.lines.count }
            DispatchQueue.main.async {
                j.name = title
                j.textURL = txt
                j.ocrLines = lineCount
                j.phase = "识别完成，开始清晰化…"
            }
            self.makeThumb(j)
            self.run(j, announce: false)
            self.refreshFiles()
        }
    }

    func add(_ urls: [URL]) {
        for u in urls {
            let j = Job(url: u)
            jobs.insert(j, at: 0)
            if autoProcess {
                queue.async { [weak self] in
                    guard let self else { return }
                    self.makeThumb(j)
                    self.run(j)
                }
            } else {
                queue.async { [weak self] in self?.makeThumb(j) }
            }
        }
    }

    private func makeThumb(_ j: Job) {
        if let g = ScanCore.renderPages(j.url, targetWidthPx: 420).first,
           let cg = ScanCore.cgImage(g) {
            let img = UIImage(cgImage: cg)
            DispatchQueue.main.async { j.thumb = img }
        }
    }

    func startQueued() {
        let pending = jobs.filter { $0.state == .queued }
        for j in pending {
            queue.async { [weak self] in self?.run(j) }
        }
    }

    func retry(_ j: Job) {
        j.state = .working
        j.progress = 0
        j.result = nil
        j.phase = "重新开始…"
        busy = true
        queue.async { [weak self] in self?.run(j, announce: false) }
    }

    func remove(_ j: Job) {
        if let r = j.result { mergeURLs.removeAll { $0 == r } }
        jobs.removeAll { $0.id == j.id }
    }

    func clearFinished() {
        for j in jobs where j.state == .done { remove(j) }
    }

    private func run(_ j: Job, announce: Bool = true) {
        if announce {
            DispatchQueue.main.async {
                j.state = .working
                j.phase = "准备中…"
                self.busy = true
            }
        }
        let stem = (j.outputStem ?? (j.name as NSString).deletingPathExtension)
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r"))
            .joined()
        let dst = uniqueOutput(for: stem)
        var step = 0.0
        let rep = ScanCore.process(j.url, to: dst) { msg in
            step += 1
            let p = 1.0 - exp(-step / 10.0)
            DispatchQueue.main.async {
                j.progress = min(0.95, p)
                j.phase = msg
            }
        }
        DispatchQueue.main.async {
            j.progress = 1
            j.pages = rep.pages
            j.retention = rep.decisions.retention.min() ?? 1
            j.sheetMM = rep.decisions.sheetWidthMM
            j.seconds = rep.seconds
            j.showThrough = rep.decisions.showThrough
            if rep.passed && rep.pages > 0 {
                j.result = dst
                j.state = .done
                j.phase = "完成"
                self.addToMerge(dst)
                self.refreshFiles()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                j.state = .failed(rep.problems.first ?? "处理失败")
                j.phase = "未通过质量闸门"
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            self.busy = self.jobs.contains { $0.state == .working }
        }
    }

    /// 同名文件不覆盖，重新导入同一份卷子会得到 "…-清晰版(2).pdf"。
    private func uniqueOutput(for stem: String) -> URL {
        let fm = FileManager.default
        let base = docsDir.appendingPathComponent(stem + "-清晰版.pdf")
        if !fm.fileExists(atPath: base.path) { return base }
        for n in 2...99 {
            let u = docsDir.appendingPathComponent("\(stem)-清晰版(\(n)).pdf")
            if !fm.fileExists(atPath: u.path) { return u }
        }
        return docsDir.appendingPathComponent("\(stem)-清晰版-\(UUID().uuidString.prefix(6)).pdf")
    }

    // MARK: 合并

    func setMergeMode(_ m: MergeMode) {
        mergeMode = m
        UserDefaults.standard.set(m.rawValue, forKey: "cp.mergeMode")
        mergeMessage = ""
    }

    func addToMerge(_ u: URL) {
        if !mergeURLs.contains(u) { mergeURLs.append(u) }
    }

    func moveMerge(_ u: URL, by delta: Int) {
        guard let i = mergeURLs.firstIndex(of: u) else { return }
        let j = i + delta
        guard j >= 0, j < mergeURLs.count else { return }
        mergeURLs.swapAt(i, j)
    }

    func removeFromMerge(_ u: URL) { mergeURLs.removeAll { $0 == u } }

    func performMerge() {
        let urls = mergeURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard urls.count >= 2 else {
            mergeMessage = "至少要有 2 份清晰版才能合并"
            return
        }
        merging = true
        mergeMessage = "正在合并 \(urls.count) 份…"
        let mode = mergeMode
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd-HHmmss"
        let out = docsDir.appendingPathComponent("合并清晰版-\(df.string(from: Date())).pdf")
        ioQueue.async { [weak self] in
            let pages = mergePDFs(urls, mode: mode, to: out)
            DispatchQueue.main.async {
                guard let self else { return }
                self.merging = false
                if pages > 0 {
                    self.mergeResult = out
                    self.mergePages = pages
                    self.mergeMessage = "已合并 \(urls.count) 份 · 共 \(pages) 页"
                    self.refreshFiles()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } else {
                    self.mergeMessage = "合并失败，请检查文件是否有效"
                }
            }
        }
    }

    // MARK: 输出文件

    func refreshFiles() {
        let dir = docsDir
        ioQueue.async { [weak self] in
            let fm = FileManager.default
            let items = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: .skipsHiddenFiles)) ?? []
            var list: [OutFile] = []
            for u in items where ["pdf", "txt", "md"].contains(u.pathExtension.lowercased()) {
                let a = try? fm.attributesOfItem(atPath: u.path)
                let size = (a?[.size] as? NSNumber)?.int64Value ?? 0
                let date = (a?[.modificationDate] as? Date) ?? .distantPast
                let isText = u.pathExtension.lowercased() != "pdf"
                let pages = isText ? 0 : (PDFDocument(url: u)?.pageCount ?? 0)
                list.append(OutFile(url: u, size: size, date: date, pages: pages, isText: isText))
            }
            list.sort { $0.date > $1.date }
            DispatchQueue.main.async {
                self?.files = list
                // 已被删除的结果不要再留在任务/合并队列里
                for j in self?.jobs ?? [] {
                    if let r = j.result, !list.contains(where: { $0.url == r }) {
                        j.result = nil
                        j.state = .failed("结果文件已被删除，可重试")
                    }
                }
                self?.mergeURLs.removeAll { u in !list.contains(where: { $0.url == u }) }
            }
        }
    }

    func deleteFile(_ u: URL) {
        try? FileManager.default.removeItem(at: u)
        removeFromMerge(u)
        refreshFiles()
    }
}

// MARK: - 基础组件

struct Card<Content: View>: View {
    let padding: CGFloat
    let content: Content
    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }
    var body: some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Pal.panel))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Pal.line.opacity(0.8), lineWidth: 0.5))
    }
}

struct SectionTitle: View {
    let title: String
    var hint: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Pal.ink)
            Spacer()
            if let hint { Text(hint).font(.caption).foregroundStyle(Pal.mute) }
        }
    }
}

struct Chip: View {
    let text: String
    var fg: Color = Pal.sub
    var bg: Color = Pal.graySoft
    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(bg))
            .foregroundStyle(fg)
    }
}

struct IconBox: View {
    let system: String
    var tint: Color = Pal.ink2
    var bg: Color = Pal.graySoft
    var size: CGFloat = 36
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(bg)
            Image(systemName: system)
                .font(.system(size: size * 0.44, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

struct PrimaryButton: View {
    let title: String
    let icon: String
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(title).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(disabled ? Pal.mute : Pal.canvas)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(disabled ? Pal.graySoft : Pal.ink))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

struct ActionTile: View {
    let icon: String
    let title: String
    var tint: Color = Pal.blue
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium))
                Text(title).font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.11)))
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}

struct Ring: View {
    var value: Double
    var tint: Color
    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: 4)
            Circle().trim(from: 0, to: value)
                .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.35), value: value)
        }
    }
}

struct CheckMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.width * 0.22, y: r.height * 0.55))
        p.addLine(to: CGPoint(x: r.width * 0.42, y: r.height * 0.75))
        p.addLine(to: CGPoint(x: r.width * 0.80, y: r.height * 0.30))
        return p
    }
}

struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let logo = About.logo {
                    Image(uiImage: logo).resizable().scaledToFit()
                } else {
                    Image(systemName: "doc.text.magnifyingglass").resizable().scaledToFit()
                        .padding(10).foregroundStyle(Pal.amber)
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text("ClearPaper").font(.headline.weight(.bold)).foregroundStyle(Pal.ink)
                    Chip(text: "v\(About.version)", fg: Pal.amber, bg: Pal.amberSoft)
                }
                Text("by \(About.author) · \(About.versionLine)")
                    .font(.caption).foregroundStyle(Pal.sub)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 系统能力封装

struct PDFKitView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = UIColor(Pal.panel2)
        v.document = PDFDocument(url: url)
        return v
    }
    func updateUIView(_ v: PDFView, context: Context) {
        if v.document?.documentURL != url { v.document = PDFDocument(url: url) }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let w = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            vc.popoverPresentationController?.sourceView = w
            vc.popoverPresentationController?.sourceRect =
                CGRect(x: w.bounds.midX, y: w.bounds.midY, width: 1, height: 1)
        }
        return vc
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct DocumentExporter: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
}

struct PreviewSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var router: Router
    var body: some View {
        NavigationStack {
            PDFKitView(url: url)
                .ignoresSafeArea(edges: .bottom)
                .background(Pal.canvas)
                .navigationTitle(url.lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("完成") { dismiss() }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { router.share(url) } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
        }
    }
}

struct TextViewSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var router: Router
    @State private var content = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(content)
                    .font(.footnote)
                    .foregroundStyle(Pal.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(16)
            }
            .background(Pal.canvas.ignoresSafeArea())
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 14) {
                        Button { UIPasteboard.general.string = content } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        Button { router.share(url) } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            .onAppear {
                content = (try? String(contentsOf: url, encoding: .utf8)) ?? "无法读取文字稿"
            }
        }
    }
}

func printPDF(_ url: URL) {
    let c = UIPrintInteractionController.shared
    c.printingItem = url
    let info = UIPrintInfo(dictionary: nil)
    info.jobName = url.lastPathComponent
    info.outputType = .general
    c.printInfo = info
    if UIDevice.current.userInterfaceIdiom == .pad,
       let w = UIApplication.shared.connectedScenes
        .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
        c.present(from: CGRect(x: w.bounds.midX, y: w.bounds.midY, width: 1, height: 1),
                  in: w, animated: true, completionHandler: nil)
    } else {
        c.present(animated: true, completionHandler: nil)
    }
}

func sizeText(_ n: Int64) -> String {
    n >= 1_048_576 ? String(format: "%.1f MB", Double(n) / 1_048_576)
                   : String(format: "%.0f KB", Double(n) / 1024)
}

func dateText(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = "MM-dd HH:mm"
    return f.string(from: d)
}

// MARK: - 处理页

struct ProcessView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @State private var photos: [PhotosPickerItem] = []
    @State private var cameraUnsupported = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                BrandHeader()
                importCard
                captureRow
                optionsCard
                if !store.jobs.isEmpty { queueHeader }
                ForEach(store.jobs) { JobCard(job: $0) }
                if store.jobs.isEmpty { emptyState }
                Text("全离线 · 不上传任何文件 · 数据只在本机")
                    .font(.caption2).foregroundStyle(Pal.mute)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 96)
        }
        .background(Pal.canvas.ignoresSafeArea())
        .navigationTitle("处理")
        .onChange(of: photos) { items in
            guard !items.isEmpty else { return }
            Task {
                var imgs: [UIImage] = []
                for item in items {
                    if let d = try? await item.loadTransferable(type: Data.self),
                       let im = UIImage(data: d) { imgs.append(im) }
                }
                await MainActor.run {
                    photos = []
                    store.addCaptured(imgs)
                }
            }
        }
        .alert("当前设备不支持文档扫描", isPresented: $cameraUnsupported) {
            Button("好", role: .cancel) {}
        } message: {
            Text("模拟器没有相机；真机上可直接多页连拍。也可以点「从相册选」导入已有照片。")
        }
    }

    var captureRow: some View {
        HStack(spacing: 10) {
            Button {
                if Capture.scannerSupported { router.scan() }
                else { cameraUnsupported = true }
            } label: {
                captureTile("camera.viewfinder", "拍照扫描", Pal.amber)
            }.buttonStyle(.plain)

            PhotosPicker(selection: $photos, maxSelectionCount: 20, matching: .images) {
                captureTile("photo.on.rectangle", "从相册选", Pal.blue)
            }
        }
    }

    func captureTile(_ icon: String, _ title: String, _ tint: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 19, weight: .medium))
            Text(title).font(.caption.weight(.medium))
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(tint.opacity(0.10)))
    }

    var importCard: some View {
        Button { router.pick() } label: {
            HStack(spacing: 13) {
                IconBox(system: "arrow.down.doc.fill", tint: Pal.amber,
                        bg: Pal.amberSoft, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("导入试卷 PDF").font(.subheadline.weight(.semibold))
                        .foregroundStyle(Pal.ink)
                    Text("可一次选多份 · 微信里「用其他应用打开」也能进来")
                        .font(.caption).foregroundStyle(Pal.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Pal.mute)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Pal.panel))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
                .foregroundStyle(Pal.amber.opacity(0.5)))
        }
        .buttonStyle(.plain)
    }

    var optionsCard: some View {
        Card(padding: 14) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    IconBox(system: "wand.and.stars", tint: Pal.amber, bg: Pal.amberSoft, size: 30)
                    Text("处理选项").font(.subheadline.weight(.semibold)).foregroundStyle(Pal.ink)
                    Spacer()
                }
                .padding(.bottom, 6)
                Toggle(isOn: $store.deghost) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("去除背面透印").font(.footnote.weight(.medium)).foregroundStyle(Pal.ink)
                        Text("清掉纸背透过来的浅灰虚影，保留真实笔画与照片")
                            .font(.caption2).foregroundStyle(Pal.sub)
                    }
                }
                .tint(Pal.amber)
                Divider().background(Pal.line).padding(.vertical, 8)
                Toggle(isOn: $store.autoProcess) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("导入后自动开始").font(.footnote.weight(.medium)).foregroundStyle(Pal.ink)
                        Text("关闭后先攒齐多份，再点「开始处理」")
                            .font(.caption2).foregroundStyle(Pal.sub)
                    }
                }
                .tint(Pal.amber)
                let queued = store.jobs.filter { $0.state == .queued }.count
                if queued > 0 {
                    Button {
                        store.startQueued()
                    } label: {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("开始处理 \(queued) 份")
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Pal.canvas)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Pal.ink))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 10)
                }
            }
        }
    }

    var queueHeader: some View {
        HStack {
            SectionTitle(title: "任务", hint: "\(store.jobs.count) 项")
            if store.jobs.contains(where: { $0.state == .done }) {
                Button("清空已完成") { store.clearFinished() }
                    .font(.caption).foregroundStyle(Pal.amber)
            }
        }
    }

    var emptyState: some View {
        VStack(spacing: 12) {
            IconBox(system: "sparkles", tint: Pal.amber, bg: Pal.amberSoft, size: 46)
            Text("把试卷变干净，只要三步").font(.subheadline.weight(.semibold))
                .foregroundStyle(Pal.ink)
            VStack(alignment: .leading, spacing: 8) {
                stepRow(1, "导入 PDF", "一份或多份，顺序就是合并顺序")
                stepRow(2, "本机清晰化", "自动裁边、去透印、铺成 A4")
                stepRow(3, "打印 / 分享", "可直接AirPrint，或存到文件")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
            .foregroundStyle(Pal.line))
    }

    func stepRow(_ n: Int, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.caption2.weight(.bold)).foregroundStyle(Pal.amber)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Pal.amberSoft))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(Pal.ink)
                Text(body).font(.caption2).foregroundStyle(Pal.sub)
            }
            Spacer()
        }
    }
}

// MARK: - 任务卡片

struct JobCard: View {
    @ObservedObject var job: Job
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @State private var drew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Pal.graySoft).frame(width: 42, height: 54)
                    if let t = job.thumb {
                        Image(uiImage: t).resizable().scaledToFill()
                            .frame(width: 38, height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        Image(systemName: "doc.text").foregroundStyle(Pal.mute)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.name).font(.subheadline.weight(.semibold))
                        .foregroundStyle(Pal.ink).lineLimit(2)
                    Text(subtitle).font(.caption).foregroundStyle(Pal.sub).lineLimit(2)
                }
                Spacer(minLength: 2)
                VStack(spacing: 6) {
                    statusBadge
                    Button { store.remove(job) } label: {
                        Image(systemName: "xmark").font(.caption2.weight(.bold))
                            .foregroundStyle(Pal.mute)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Pal.graySoft))
                    }.buttonStyle(.plain)
                }
            }

            if job.state == .working {
                ProgressView(value: job.progress).tint(Pal.amber)
            }

            if job.state == .done {
                HStack(spacing: 6) {
                    Chip(text: "\(job.pages) 页 A4", fg: Pal.blue, bg: Pal.blueSoft)
                    Chip(text: String(format: "笔画保留 %.0f%%", job.retention * 100),
                         fg: Pal.green, bg: Pal.greenSoft)
                    if job.showThrough {
                        Chip(text: "已去透印", fg: Pal.amber, bg: Pal.amberSoft)
                    }
                    Spacer()
                }
            }

            if let r = job.result {
                HStack(spacing: 8) {
                    ActionTile(icon: "eye", title: "预览") { router.show(r) }
                    ActionTile(icon: "printer.fill", title: "打印", tint: Pal.green) { printPDF(r) }
                    ActionTile(icon: "square.and.arrow.up", title: "分享") { router.share(r) }
                    ActionTile(icon: "folder", title: "存文件", tint: Pal.amber) { router.save(r) }
                }
            }

            if let t = job.textURL {
                Button { router.showText(t) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "text.alignleft").font(.caption)
                        Text("OCR 文字稿 · \(job.ocrLines) 行").font(.caption.weight(.medium))
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .foregroundStyle(Pal.ink2)
                    .padding(.horizontal, 11).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Pal.panel2))
                }
                .buttonStyle(.plain)
            }

            switch job.state {
            case .failed:
                ActionTile(icon: "arrow.clockwise", title: "重试", tint: Pal.red) {
                    store.retry(job)
                }
            case .queued:
                ActionTile(icon: "play.fill", title: "开始处理", tint: Pal.amber) {
                    store.startQueued()
                }
            default:
                EmptyView()
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Pal.panel))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Pal.line.opacity(0.8), lineWidth: 0.5))
        .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity),
                                removal: .opacity))
    }

    var subtitle: String {
        switch job.state {
        case .queued: return "排队中 · 等待开始"
        case .working: return job.phase
        case .done:
            return String(format: "纸面 %.0f mm · 用时 %.1fs", job.sheetMM, job.seconds)
        case .failed(let m): return m
        }
    }

    @ViewBuilder var statusBadge: some View {
        switch job.state {
        case .working:
            Ring(value: job.progress, tint: Pal.amber).frame(width: 26, height: 26)
        case .done:
            ZStack {
                Circle().fill(Pal.green.opacity(0.16))
                CheckMark().trim(from: 0, to: drew ? 1 : 0)
                    .stroke(Pal.green, style: StrokeStyle(lineWidth: 2.4, lineCap: .round,
                                                          lineJoin: .round))
                    .frame(width: 15, height: 15)
            }
            .frame(width: 26, height: 26)
            .onAppear { withAnimation(.easeOut(duration: 0.45).delay(0.1)) { drew = true } }
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Pal.red).font(.title3)
        case .queued:
            Image(systemName: "clock").foregroundStyle(Pal.mute).font(.footnote)
        }
    }
}

// MARK: - 合并页

struct MergeView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    IconBox(system: "square.on.square", tint: Pal.amber,
                            bg: Pal.amberSoft, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("合并清晰版").font(.title3.weight(.bold)).foregroundStyle(Pal.ink)
                        Text("按下面的顺序拼成一份 PDF")
                            .font(.caption).foregroundStyle(Pal.sub)
                    }
                    Spacer()
                }

                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "合并方式")
                        Picker("合并方式", selection: Binding(
                            get: { store.mergeMode },
                            set: { store.setMergeMode($0) })) {
                            Text("分别保存").tag(MergeMode.separate)
                            Text("完全合并").tag(MergeMode.full)
                            Text("间隔·双面").tag(MergeMode.duplex)
                        }
                        .pickerStyle(.segmented)
                        Text(modeHint).font(.caption).foregroundStyle(Pal.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Card(padding: 0) {
                    VStack(spacing: 0) {
                        HStack {
                            SectionTitle(title: "合并顺序", hint: "\(store.mergeURLs.count) 份")
                            Button { router.pick() } label: {
                                Label("添加", systemImage: "plus")
                                    .font(.caption).foregroundStyle(Pal.amber)
                            }.buttonStyle(.plain)
                        }
                        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)

                        if store.mergeURLs.isEmpty {
                            Text("还没有可合并的清晰版。先到「处理」导入 PDF，\n或到「文件」把已有结果加进来。")
                                .font(.caption).foregroundStyle(Pal.mute)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 26)
                        } else {
                            ForEach(Array(store.mergeURLs.enumerated()), id: \.element) { i, u in
                                HStack(spacing: 10) {
                                    Text("\(i + 1)").font(.caption2.weight(.bold))
                                        .foregroundStyle(Pal.amber)
                                        .frame(width: 22, height: 22)
                                        .background(Circle().fill(Pal.amberSoft))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(u.lastPathComponent).font(.caption.weight(.medium))
                                            .foregroundStyle(Pal.ink).lineLimit(1)
                                        Text("\(PDFDocument(url: u)?.pageCount ?? 0) 页")
                                            .font(.caption2).foregroundStyle(Pal.sub)
                                    }
                                    Spacer(minLength: 2)
                                    Button { store.moveMerge(u, by: -1) } label: {
                                        Image(systemName: "chevron.up").font(.caption)
                                    }.buttonStyle(.plain).foregroundStyle(Pal.sub)
                                    Button { store.moveMerge(u, by: 1) } label: {
                                        Image(systemName: "chevron.down").font(.caption)
                                    }.buttonStyle(.plain).foregroundStyle(Pal.sub)
                                    Button { store.removeFromMerge(u) } label: {
                                        Image(systemName: "minus.circle").font(.caption)
                                    }.buttonStyle(.plain).foregroundStyle(Pal.red)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                if i < store.mergeURLs.count - 1 {
                                    Divider().background(Pal.line).padding(.leading, 46)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 10)
                }

                if store.mergeMode == .separate {
                    PrimaryButton(title: "结果已分别保存 · 去查看", icon: "folder") {
                        router.goto(.files)
                    }
                } else {
                    PrimaryButton(title: store.merging ? "正在合并…" : "合并并保存",
                                  icon: "square.on.square",
                                  disabled: store.mergeURLs.count < 2 || store.merging) {
                        store.performMerge()
                    }
                }

                if !store.mergeMessage.isEmpty {
                    Card(padding: 12) {
                        HStack(spacing: 10) {
                            IconBox(system: store.mergeResult == nil ? "info.circle" : "checkmark.circle",
                                    tint: store.mergeResult == nil ? Pal.sub : Pal.green,
                                    bg: store.mergeResult == nil ? Pal.graySoft : Pal.greenSoft,
                                    size: 30)
                            Text(store.mergeMessage).font(.caption).foregroundStyle(Pal.ink)
                            Spacer()
                        }
                        if let r = store.mergeResult, FileManager.default.fileExists(atPath: r.path) {
                            HStack(spacing: 8) {
                                ActionTile(icon: "eye", title: "预览") { router.show(r) }
                                ActionTile(icon: "printer.fill", title: "打印", tint: Pal.green) { printPDF(r) }
                                ActionTile(icon: "square.and.arrow.up", title: "分享") { router.share(r) }
                                ActionTile(icon: "folder", title: "存文件", tint: Pal.amber) { router.save(r) }
                            }
                            .padding(.top, 8)
                        }
                    }
                }

                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("为什么要「间隔·双面」？").font(.caption.weight(.semibold))
                            .foregroundStyle(Pal.ink)
                        Text("双面打印时，如果上一份试卷是奇数页，下一份的第一页会印在同一张纸背面，两卷就串了。间隔模式会在每份末尾补一张空白页，保证每卷都从新纸正面开始。")
                            .font(.caption2).foregroundStyle(Pal.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 96)
        }
        .background(Pal.canvas.ignoresSafeArea())
        .navigationTitle("合并")
    }

    var modeHint: String {
        switch store.mergeMode {
        case .separate: return "每份各存一个清晰版 PDF，不生成合并文件。结果在「文件」里。"
        case .full: return "按上面的顺序首尾相接，页数不变。"
        case .duplex: return "每份末尾（最后一份除外）补空白页到偶数页，双面打印不跨卷。"
        }
    }
}

// MARK: - 文件页

struct FilesView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @State private var pendingDelete: URL?
    @State private var confirming = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    IconBox(system: "folder.fill", tint: Pal.amber, bg: Pal.amberSoft, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("输出文件").font(.title3.weight(.bold)).foregroundStyle(Pal.ink)
                        Text("保存在本 App 的「清晰版」文件夹")
                            .font(.caption).foregroundStyle(Pal.sub)
                    }
                    Spacer()
                    Button { store.refreshFiles() } label: {
                        Image(systemName: "arrow.clockwise").font(.footnote)
                            .foregroundStyle(Pal.amber)
                    }.buttonStyle(.plain)
                }

                if store.files.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tray").font(.system(size: 34)).foregroundStyle(Pal.mute)
                        Text("还没有输出文件").font(.subheadline).foregroundStyle(Pal.sub)
                        Text("处理后的 PDF 会自动出现在这里，也可以在「文件」App 里看到")
                            .font(.caption2).foregroundStyle(Pal.mute)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 42)
                } else {
                    ForEach(store.files) { f in fileCard(f) }
                }

                Text("这些文件只存在你的手机上 · 删除后可在「处理」重试")
                    .font(.caption2).foregroundStyle(Pal.mute)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 96)
        }
        .background(Pal.canvas.ignoresSafeArea())
        .navigationTitle("文件")
        .onAppear { store.refreshFiles() }
        .alert("删除这个文件？", isPresented: $confirming) {
            Button("删除", role: .destructive) {
                if let u = pendingDelete { store.deleteFile(u) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.lastPathComponent ?? "")
        }
    }

    func fileCard(_ f: OutFile) -> some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 11) {
                    IconBox(system: f.isText ? "text.alignleft" : "doc.richtext",
                            tint: f.isText ? Pal.amber : Pal.blue,
                            bg: f.isText ? Pal.amberSoft : Pal.blueSoft, size: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(f.name).font(.caption.weight(.semibold))
                            .foregroundStyle(Pal.ink).lineLimit(2)
                        Text(f.isText
                             ? "文字稿 · \(sizeText(f.size)) · \(dateText(f.date))"
                             : "\(f.pages) 页 · \(sizeText(f.size)) · \(dateText(f.date))")
                            .font(.caption2).foregroundStyle(Pal.sub)
                    }
                    Spacer(minLength: 2)
                    Button {
                        pendingDelete = f.url
                        confirming = true
                    } label: {
                        Image(systemName: "trash").font(.caption)
                            .foregroundStyle(Pal.red)
                    }.buttonStyle(.plain)
                }
                HStack(spacing: 8) {
                    ActionTile(icon: "eye", title: f.isText ? "查看" : "预览") {
                        if f.isText { router.showText(f.url) } else { router.show(f.url) }
                    }
                    if !f.isText {
                        ActionTile(icon: "printer.fill", title: "打印", tint: Pal.green) {
                            printPDF(f.url)
                        }
                    }
                    ActionTile(icon: "square.and.arrow.up", title: "分享") { router.share(f.url) }
                    if !f.isText {
                        ActionTile(icon: "plus.square", title: "加合并", tint: Pal.amber) {
                            store.addToMerge(f.url)
                            router.goto(.merge)
                        }
                    } else {
                        ActionTile(icon: "doc.on.doc", title: "复制", tint: Pal.green) {
                            UIPasteboard.general.string = try? String(contentsOf: f.url,
                                                                      encoding: .utf8)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 关于页

struct AboutView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Card(padding: 18) {
                    VStack(spacing: 10) {
                        Group {
                            if let logo = About.logo {
                                Image(uiImage: logo).resizable().scaledToFit()
                            } else {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .resizable().scaledToFit().padding(18)
                                    .foregroundStyle(Pal.amber)
                            }
                        }
                        .frame(width: 86, height: 86)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                        Text("ClearPaper").font(.title2.weight(.bold)).foregroundStyle(Pal.ink)
                        Text("by \(About.author)").font(.subheadline.weight(.medium))
                            .foregroundStyle(Pal.amber)
                        Chip(text: About.versionLine, fg: Pal.sub, bg: Pal.graySoft)
                        Text("全离线 · 不上传任何文件 · 无服务端")
                            .font(.caption).foregroundStyle(Pal.sub)
                        Button {
                            if let u = URL(string: About.repo) { UIApplication.shared.open(u) }
                        } label: {
                            Label("github.com/jpruby0127/ClearPaper", systemImage: "link")
                                .font(.caption).foregroundStyle(Pal.blue)
                        }.buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity)
                }

                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 11) {
                        SectionTitle(title: "它能做什么")
                        feature("wand.and.stars", "扫描件清晰化", "自动裁掉白边与黑框、拉回对比度，保持笔画不丢", Pal.amber, Pal.amberSoft)
                        feature("eye.slash", "背面透印抑制", "只清纸背透过来的浅灰虚影，照片与浅色底纹不动", Pal.blue, Pal.blueSoft)
                        feature("rectangle.portrait.rotate", "横竖页自适应", "横向排版自动输出横向 A4，不会被裁掉", Pal.green, Pal.greenSoft)
                        feature("square.on.square", "多份合并", "完全合并 / 间隔·双面，双面打印不跨卷", Pal.blue, Pal.blueSoft)
                        feature("checkmark.seal", "质量闸门", "笔画保留率低于 97% 会提示，不静默出坏结果", Pal.green, Pal.greenSoft)
                        feature("camera.viewfinder", "拍照 + OCR", "多页连拍自动找边，本机识别文字、自动命名并导出文字稿", Pal.amber, Pal.amberSoft)
                    }
                }

                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "三步上手")
                        step(1, "拖入 / 导入 PDF", "在「处理」页选一份或多份试卷，顺序就是合并顺序。")
                        step(2, "本机处理", "自动完成并给出页数、纸面宽度、笔画保留率。")
                        step(3, "打印 / 分享 / 合并", "可直接 AirPrint，也可在「合并」页拼成一份。")
                        Divider().background(Pal.line)
                        Text("打印小贴士：选 A4、缩放「实际大小 / 100%」，不要选「适合页面」。")
                            .font(.caption2).foregroundStyle(Pal.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(title: "关于 OCR")
                        Text("iPhone 上用系统 Vision 引擎识别中英文，全离线、零额外体积：输出 .txt 文字稿，并用首页标题自动给文件命名。PDF 本身保持图像，保证打印质量。")
                            .font(.caption2).foregroundStyle(Pal.sub)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("进阶的整页 Markdown / 表格 / 字段 JSON 解析，可接小米开源的 Xiaomi-OCR-0（0.8B，Apache 2.0），由 Python 参考引擎的可选后端调用。模型权重约 2GB，适合桌面或服务器，不塞进这个轻量 IPA。")
                            .font(.caption2).foregroundStyle(Pal.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "外观")
                        Picker("外观", selection: $store.appearance) {
                            Text("跟随系统").tag(0)
                            Text("浅色").tag(1)
                            Text("深色").tag(2)
                        }
                        .pickerStyle(.segmented)
                        Text("深色不是纯黑，浅色也保留足够的层次对比。")
                            .font(.caption2).foregroundStyle(Pal.sub)
                    }
                }

                VStack(spacing: 4) {
                    Text("© 2026 \(About.author) · MIT License")
                        .font(.caption2).foregroundStyle(Pal.mute)
                    Text("macOS / iOS Swift 引擎 · Windows 便携版 · 同一套算法")
                        .font(.caption2).foregroundStyle(Pal.mute)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 96)
        }
        .background(Pal.canvas.ignoresSafeArea())
        .navigationTitle("关于")
    }

    func feature(_ icon: String, _ title: String, _ body: String,
                 _ fg: Color, _ bg: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            IconBox(system: icon, tint: fg, bg: bg, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(Pal.ink)
                Text(body).font(.caption2).foregroundStyle(Pal.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    func step(_ n: Int, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.caption2.weight(.bold)).foregroundStyle(Pal.amber)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Pal.amberSoft))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(Pal.ink)
                Text(body).font(.caption2).foregroundStyle(Pal.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}

// MARK: - 根视图

struct ContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @State private var tab: Tab = ContentView.initialTab
    @State private var didImport = false

    /// 调试入口：simctl launch ... -ClearPaperTab 3 可直接打开「关于」页，
    /// 与 macOS 端的 SCANPDF_PAGE 调试开关保持一致。
    static var initialTab: Tab {
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-ClearPaperTab"), i + 1 < a.count,
           let n = Int(a[i + 1]), let t = Tab(rawValue: n) { return t }
        return .process
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { ProcessView() }
                .tabItem { Label("处理", systemImage: "wand.and.stars") }.tag(Tab.process)
            NavigationStack { MergeView() }
                .tabItem { Label("合并", systemImage: "square.on.square") }.tag(Tab.merge)
            NavigationStack { FilesView() }
                .tabItem { Label("文件", systemImage: "folder") }.tag(Tab.files)
            NavigationStack { AboutView() }
                .tabItem { Label("关于", systemImage: "info.circle") }.tag(Tab.about)
        }
        .tint(Pal.amber)
        .onAppear {
            guard !didImport else { return }
            didImport = true
            store.importInbox()
        }
        .onChange(of: router.requestedTab) { t in
            if let t { tab = t; router.requestedTab = nil }
        }
        .fileImporter(isPresented: $router.picking, allowedContentTypes: [.pdf],
                      allowsMultipleSelection: true) { res in
            if case .success(let urls) = res {
                let staged = urls.compactMap(Store.stage)
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    store.add(staged)
                }
                router.goto(.process)
            }
        }
        .onOpenURL { u in
            guard let staged = Store.stage(u) else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                store.add([staged])
            }
            router.goto(.process)
        }
        .sheet(item: $router.sheet) { item in
            SheetContent(item: item)
                .environmentObject(store)
                .environmentObject(router)
        }
    }
}

/// 所有弹层共用一个 sheet 绑定，避免多个 .sheet 修饰符互相抢占。
struct SheetContent: View {
    let item: Sheet
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router

    @ViewBuilder
    var body: some View {
        switch item {
        case .preview(let u):
            PreviewSheet(url: u)
        case .share(let u):
            ActivityView(url: u)
        case .export(let u):
            DocumentExporter(url: u)
        case .text(let u):
            TextViewSheet(url: u)
        case .scanner:
            DocumentScanner { imgs in
                router.close()
                store.addCaptured(imgs)
                router.goto(.process)
            }
        }
    }
}

@main
struct ClearPaperApp: App {
    @StateObject private var store = Store()
    @StateObject private var router = Router()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(router)
                .preferredColorScheme(store.scheme)
        }
    }
}
