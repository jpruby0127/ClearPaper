import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Fully on-device: the Swift port of the cleanup engine runs here, no server.

enum JobState: Equatable {
    case queued, working, done, failed(String)
}

final class Job: Identifiable, ObservableObject {
    let id = UUID()
    let url: URL
    let name: String
    @Published var state: JobState = .queued
    @Published var progress: Double = 0
    @Published var pages = 0
    @Published var retention: Float = 1
    @Published var sheetMM: Float = 0
    @Published var seconds: Double = 0
    @Published var result: URL?
    @Published var thumb: UIImage?
    @Published var phase = "准备中…"
    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent
    }
}

final class Store: ObservableObject {
    @Published var jobs: [Job] = []
    @Published var busy = false
    private let queue = DispatchQueue(label: "scanpdf.engine", qos: .userInitiated)
    private let importedKey = "scanpdf.importedPDFs"

    var docsDir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("清晰版", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Files handed over by the Files app / WeChat live outside our sandbox and
    /// may be security-scoped. Copy them into a unique temp path first — a fixed
    /// name silently fails on the second import of the same document.
    static func stage(_ u: URL) -> URL? {
        let fm = FileManager.default
        let scoped = u.startAccessingSecurityScopedResource()
        defer { if scoped { u.stopAccessingSecurityScopedResource() } }
        let dst = fm.temporaryDirectory
            .appendingPathComponent("ScanClean-\(UUID().uuidString)-\(u.lastPathComponent)")
        do {
            try fm.copyItem(at: u, to: dst)
            return dst
        } catch {
            return nil
        }
    }

    /// PDFs dropped into the app's Documents folder via the Files app / iTunes
    /// sharing are picked up on launch. Remembered by name+size so relaunching
    /// never reprocesses the same document.
    func importInbox() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let files = try? fm.contentsOfDirectory(
            at: docs, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)
        else { return }
        let seen = Set(UserDefaults.standard.stringArray(forKey: importedKey) ?? [])
        var seenNow = seen
        var fresh: [URL] = []
        for u in files where u.pathExtension.lowercased() == "pdf"
            && !u.lastPathComponent.contains("清晰版") {
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let key = "\(u.lastPathComponent)-\(size)"
            if !seen.contains(key) { fresh.append(u); seenNow.insert(key) }
        }
        UserDefaults.standard.set(Array(seenNow), forKey: importedKey)
        if !fresh.isEmpty { add(fresh) }
    }

    func add(_ urls: [URL]) {
        for u in urls {
            let j = Job(url: u)
            jobs.insert(j, at: 0)
            queue.async { [weak self] in
                guard let self else { return }
                if let g = ScanCore.renderPages(u, targetWidthPx: 420).first,
                   let cg = ScanCore.cgImage(g) {
                    let img = UIImage(cgImage: cg)
                    DispatchQueue.main.async { j.thumb = img }
                }
                self.run(j)
            }
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

    private func run(_ j: Job, announce: Bool = true) {
        if announce {
            DispatchQueue.main.async {
                j.state = .working
                j.phase = "准备中…"
                self.busy = true
            }
        }
        let stem = (j.name as NSString).deletingPathExtension
        let dst = uniqueOutput(for: stem)
        var step = 0.0
        let rep = ScanCore.process(j.url, to: dst) { msg in
            step += 1
            let p = 1.0 - exp(-step / 10.0)  // smooth, never claims 100% early
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
            if rep.passed && rep.pages > 0 {
                j.result = dst
                j.state = .done
                j.phase = "完成"
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                j.state = .failed(rep.problems.first ?? "处理失败")
                j.phase = "未通过"
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            self.busy = self.jobs.contains { $0.state == .working }
        }
    }

    /// Never overwrite a previous result: re-importing the same exam produces
    /// "…-清晰版(2).pdf" instead of silently replacing the first one.
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
}

// MARK: - shapes & bits

struct CheckMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.width * 0.22, y: r.height * 0.55))
        p.addLine(to: CGPoint(x: r.width * 0.42, y: r.height * 0.75))
        p.addLine(to: CGPoint(x: r.width * 0.80, y: r.height * 0.30))
        return p
    }
}

struct Ring: View {
    var value: Double
    var tint: Color
    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: 4)
            Circle()
                .trim(from: 0, to: value)
                .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.35), value: value)
        }
    }
}

// MARK: - views

struct JobCard: View {
    @ObservedObject var job: Job
    @EnvironmentObject var store: Store
    @State private var drew = false
    @State private var exporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .frame(width: 46, height: 58)
                    if let t = job.thumb {
                        Image(uiImage: t)
                            .resizable().scaledToFill()
                            .frame(width: 42, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        Image(systemName: "doc.text")
                            .font(.title3).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                statusBadge
            }
            if job.state == .working {
                ProgressView(value: job.progress)
                    .tint(.blue)
            }
            if let r = job.result {
                HStack(spacing: 10) {
                    action("printer.fill", "打印") { print(r) }
                    action("square.and.arrow.up", "分享") { share(r) }
                    action("folder", "存到文件") { exporting = true }
                }
            }
            if case .failed = job.state {
                HStack(spacing: 10) {
                    action("arrow.clockwise", "重试") { store.retry(job) }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .transition(.asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity),
                                removal: .opacity))
        .sheet(isPresented: $exporting) {
            if let r = job.result { DocumentExporter(url: r) }
        }
    }

    var subtitle: String {
        switch job.state {
        case .queued: return "排队中"
        case .working: return job.phase
        case .done:
            return "\(job.pages) 页 A4 · 纸面 \(Int(job.sheetMM))mm · 保留 \(Int(job.retention * 100))%"
        case .failed(let m): return m
        }
    }

    @ViewBuilder var statusBadge: some View {
        switch job.state {
        case .working:
            Ring(value: job.progress, tint: .blue).frame(width: 26, height: 26)
        case .done:
            ZStack {
                Circle().fill(.green.opacity(0.16))
                CheckMark()
                    .trim(from: 0, to: drew ? 1 : 0)
                    .stroke(.green, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    .frame(width: 15, height: 15)
            }
            .frame(width: 26, height: 26)
            .onAppear { withAnimation(.easeOut(duration: 0.45).delay(0.1)) { drew = true } }
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red).font(.title3)
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        }
    }

    func action(_ icon: String, _ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: icon)
                .font(.footnote.weight(.medium))
                .padding(.vertical, 7).frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.blue.opacity(0.12)))
                .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
    }

    func print(_ url: URL) {
        let ci = UIPrintInteractionController.shared
        ci.printingItem = url
        ci.present(animated: true)
    }
    func share(_ url: URL) {
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController?.present(av, animated: true)
    }
}

/// System "Save to Files" picker. Unlike the share sheet it always offers a
/// real destination, so the third action isn't a duplicate of 分享.
struct DocumentExporter: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController,
                                context: Context) {}
}

struct ContentView: View {
    @StateObject private var store = Store()
    @State private var picking = false
    @State private var didImport = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 14) {
                        hero
                        ForEach(store.jobs) { JobCard(job: $0).environmentObject(store) }
                        if store.jobs.isEmpty { empty }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("试卷清晰化")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { picking = true } label: { Image(systemName: "plus") }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.pdf],
                          allowsMultipleSelection: true) { res in
                if case .success(let urls) = res {
                    let secured = urls.compactMap(Store.stage)
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        store.add(secured)
                    }
                }
            }
            .onOpenURL { u in
                guard let staged = Store.stage(u) else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    store.add([staged])
                }
            }
        }
        .tint(.blue)
        .onAppear {
            guard !didImport else { return }
            didImport = true
            store.importInbox()
        }
    }

    var hero: some View {
        Button { picking = true } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [.blue, .cyan],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 52, height: 52)
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.title2).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("导入试卷 PDF").font(.headline).foregroundStyle(.primary)
                    Text("全离线处理 · 微信里选「用其他应用打开」也能进来")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
    }

    var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("还没有任务").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            Text("处理在 iPhone 本机完成，不上传任何地方")
                .font(.caption).foregroundStyle(.tertiary)
            Text("在「文件」里放进本 App 的 PDF，打开时会自动出现")
                .font(.caption2).foregroundStyle(.quaternary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 46)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                .foregroundStyle(.quaternary)
        )
    }
}

@main
struct ScanCleanApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
