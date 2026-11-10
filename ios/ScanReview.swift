import SwiftUI
import UIKit

// MARK: - 检查拍摄页
//
// 系统文档相机（VNDocumentCameraViewController）是系统黑盒：自动快门、找边、
// 透视矫正都不对 App 开放。苹果也不给外部关掉自动快门，所以「来不及翻页」
// 时同一页会被连拍。我们把可控的部分放在拍摄之后：
//
//  · 逐页缩略图检查，可删除、旋转 90°、调整顺序、点开看大图；
//  · 按页面指纹自动剔除重复页，并允许一键恢复，绝不静默丢页；
//  · 标出系统相机裁边失败、仍带桌面的页，确认后只对这些页补一次矫正；
//  · 原图逐页落在 Application Support，检查页只持有缩略图，20 页也不爆内存。
//
// 确认之后才交给 Store.addCaptured 走完整 ScanCore 清理流程。

struct ScanPage: Identifiable {
    let id = UUID()
    let url: URL
    var thumb: UIImage
    var rotation = 0
    /// 系统相机这一页仍带桌面背景，确认后需要补一次找边 + 透视矫正。
    var needsFix = false
}

final class ScanBatch: ObservableObject, Identifiable {
    let id = UUID()
    let fromCamera: Bool
    let dir: URL
    @Published var pages: [ScanPage] = []
    @Published var dropped: [ScanPage] = []

    var fixCount: Int { pages.filter { $0.needsFix }.count }

    init(images: [UIImage], fromCamera: Bool) {
        self.fromCamera = fromCamera
        let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClearPaper/Review", isDirectory: true)
        let d = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        self.dir = d

        var sigs: [Capture.PageSignature] = []
        for (i, raw) in images.enumerated() {
            // 统一方向 + 限长边，既稳住 OCR / 引擎内存，也不损失 A4 打印精度。
            let img = Capture.normalized(raw)
            guard let data = img.jpegData(compressionQuality: 0.90),
                  let t = Capture.thumbnail(img) else { continue }
            let u = d.appendingPathComponent(String(format: "page-%03d.jpg", i))
            try? data.write(to: u, options: .atomic)
            var page = ScanPage(url: u, thumb: t)
            if fromCamera { page.needsFix = Capture.needsRectify(img) }

            let sig = Capture.signature(img)
            if let s = sig, Capture.isDuplicate(s, kept: sigs) {
                dropped.append(page)
            } else {
                if let s = sig { sigs.append(s) }
                pages.append(page)
            }
        }
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }

    func restoreDropped() {
        guard !dropped.isEmpty else { return }
        pages.append(contentsOf: dropped)
        dropped.removeAll()
    }

    func rotate(_ id: UUID, by deg: Int) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        var p = pages[i]
        p.rotation = (p.rotation + deg + 360) % 360
        if let img = UIImage(contentsOfFile: p.url.path),
           let t = Capture.thumbnail(Capture.rotated(img, degrees: p.rotation)) {
            p.thumb = t
        }
        pages[i] = p
    }

    func move(_ id: UUID, by delta: Int) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard j >= 0, j < pages.count else { return }
        pages.swapAt(i, j)
    }

    func remove(_ id: UUID) { pages.removeAll { $0.id == id } }

    /// 读回原图并应用用户选的旋转，交给完整清理流程。
    func confirmPages() -> [UIImage] {
        pages.compactMap { p in
            guard let img = UIImage(contentsOfFile: p.url.path) else { return nil }
            return Capture.rotated(img, degrees: p.rotation)
        }
    }
}

struct ScanReviewView: View {
    @ObservedObject var batch: ScanBatch
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @State private var big: UIImage?
    @State private var showBig = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                summary
                if batch.pages.isEmpty {
                    Spacer(minLength: 0)
                    VStack(spacing: 10) {
                        Image(systemName: "doc.on.doc").font(.system(size: 34))
                            .foregroundStyle(Pal.mute)
                        Text("没有可处理的页").font(.subheadline).foregroundStyle(Pal.sub)
                        if !batch.dropped.isEmpty {
                            Button("恢复 \(batch.dropped.count) 张被跳过的页") {
                                batch.restoreDropped()
                            }.font(.footnote)
                        }
                    }
                    Spacer(minLength: 0)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                            GridItem(.flexible(), spacing: 12)],
                                  spacing: 12) {
                            ForEach(batch.pages) { p in pageCard(p) }
                        }
                        .padding(16)
                    }
                }
                footer
            }
            .background(Pal.canvas.ignoresSafeArea())
            .navigationTitle("检查拍摄页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { batch.cleanup(); router.close() }
                }
            }
        }
        .fullScreenCover(isPresented: $showBig) {
            BigImageView(image: big) { showBig = false }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("共 \(batch.pages.count) 页" +
                 (batch.dropped.isEmpty ? " · 未发现重复页"
                                        : " · 已自动跳过 \(batch.dropped.count) 张重复页"))
                .font(.subheadline.weight(.semibold)).foregroundStyle(Pal.ink)
            Text("系统相机来不及翻页时拍重的页会自动剔除，也能一键恢复。点缩略图看大图，可逐页删除、旋转或调整顺序。")
                .font(.caption2).foregroundStyle(Pal.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(Pal.panel)
    }

    private var footer: some View {
        VStack(spacing: 9) {
            if !batch.dropped.isEmpty {
                Button {
                    batch.restoreDropped()
                } label: {
                    Text("恢复 \(batch.dropped.count) 张被跳过的页")
                        .font(.footnote.weight(.medium)).foregroundStyle(Pal.blue)
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.plain)
            }
            if batch.fixCount > 0 {
                Text("\(batch.fixCount) 页检测到桌面背景，确认后会补一次找边矫正")
                    .font(.caption2).foregroundStyle(Pal.sub)
            }
            Button { confirm() } label: {
                Text("确认处理 \(batch.pages.count) 页")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Pal.canvas)
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Capsule().fill(Pal.ink))
            }
            .buttonStyle(.plain)
            .disabled(batch.pages.isEmpty)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 22)
        .background(Pal.panel)
    }

    private func pageCard(_ p: ScanPage) -> some View {
        let idx = batch.pages.firstIndex { $0.id == p.id } ?? 0
        return VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topLeading) {
                Image(uiImage: p.thumb)
                    .resizable().scaledToFill()
                    .frame(maxWidth: .infinity).frame(height: 158)
                    .clipped()
                    .background(Pal.panel)
                    .cornerRadius(10)
                    .onTapGesture { openBig(p) }
                HStack(spacing: 5) {
                    Text("\(idx + 1)").font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Pal.ink.opacity(0.75)))
                    if p.needsFix {
                        Text("补裁边").font(.caption2.bold())
                            .foregroundStyle(Pal.ink)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Pal.amberSoft))
                    }
                }.padding(7)
            }
            HStack(spacing: 5) {
                toolButton("arrow.left", enabled: idx > 0) { batch.move(p.id, by: -1) }
                toolButton("rotate.right") { batch.rotate(p.id, by: 90) }
                toolButton("trash", tint: Pal.red) { batch.remove(p.id) }
                toolButton("arrow.right", enabled: idx < batch.pages.count - 1) {
                    batch.move(p.id, by: 1)
                }
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Pal.panel))
    }

    private func toolButton(_ icon: String, tint: Color = Pal.sub,
                            enabled: Bool = true,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.caption.weight(.semibold))
                .foregroundStyle(enabled ? tint : Pal.mute)
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Pal.canvas))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func openBig(_ p: ScanPage) {
        guard let img = UIImage(contentsOfFile: p.url.path) else { return }
        big = Capture.rotated(img, degrees: p.rotation)
        showBig = true
    }

    private func confirm() {
        let imgs = batch.confirmPages()
        let dropped = batch.dropped.count
        let mode: Capture.RectifyMode = batch.fromCamera ? .auto : .always
        batch.cleanup()
        router.close()
        store.addCaptured(imgs, rectify: mode, dedup: false, dropped: dropped)
        router.goto(.process)
    }
}

private struct BigImageView: View {
    let image: UIImage?
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image).resizable().scaledToFit().ignoresSafeArea()
            }
            Button(action: close) {
                Image(systemName: "xmark.circle.fill").font(.title)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .padding(18)
        }
    }
}
