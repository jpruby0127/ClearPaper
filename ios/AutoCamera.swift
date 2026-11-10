import SwiftUI
import UIKit
import AVFoundation
import CoreImage
import Vision

// MARK: - 翻页自动拍
//
// 系统文档相机（VNDocumentCameraViewController）的自动快门无法干预：只要画面稳定
// 就会再拍一张，来不及翻页时同一页会被连拍好几次。
//
// 这一层自己管相机与快门，状态机与扫描全能王「翻页自动拍」同构：
//
//   seeking ──(文档入框 + 连续稳定帧)──> 拍摄
//      ▲                                  │
//      │                                  ▼
//      │                              locked  ← 关键：拍完立即锁死自动快门，
//      │                                  │        页面静止时绝不重复拍
//      │                                  │
//      └──(稳定帧)── settling <──(翻页信号)─┘
//                     帧差 / 页面消失 / 感知哈希变化
//
// 拍完再等「页面稳定、手指离开、纹理清晰」才真正落一张，并用 dHash 再做一次兜底去重。
// 手动快门在任何状态都可用，不受锁定影响。全程本机，不联网、不含模型。

struct Quad {
    let tl: CGPoint, tr: CGPoint, br: CGPoint, bl: CGPoint
}

struct FrameSample {
    let gray: [UInt8]
    let hash: UInt64
    let area: CGFloat
    let quad: Quad?
    let sharp: Int
}

// MARK: - 单帧分析

enum FrameAnalyzer {
    static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// 直接从 BGRA 像素缓冲抽样出 32×32 灰度，不需要任何图像上下文，开销极低。
    static func bgraGray(_ pb: CVPixelBuffer) -> [UInt8]? {
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let row = base.assumingMemoryBound(to: UInt8.self)
        let n = PageFingerprint.n
        var out = [UInt8](repeating: 0, count: n * n)
        for y in 0..<n {
            let sy = min(h - 1, Int((CGFloat(y) + 0.5) * CGFloat(h) / CGFloat(n)))
            for x in 0..<n {
                let sx = min(w - 1, Int((CGFloat(x) + 0.5) * CGFloat(w) / CGFloat(n)))
                let p = row + sy * stride + sx * 4
                let b = Int(p[0]), g = Int(p[1]), r = Int(p[2])
                out[y * n + x] = UInt8(clamping: (r * 77 + g * 150 + b * 29) >> 8)
            }
        }
        return out
    }

    /// 把相机横屏缓冲转成竖屏 CIImage；矩形检测与透视矫正都在这套坐标里做。
    static func upright(_ pb: CVPixelBuffer) -> CIImage? {
        CIImage(cvImageBuffer: pb).oriented(forExifOrientation: 6)
    }

    static func detect(_ ci: CIImage) -> (rect: CGRect, quad: Quad)? {
        let req = VNDetectRectanglesRequest()
        req.minimumConfidence = 0.5
        req.minimumSize = 0.20
        req.minimumAspectRatio = 0.25
        req.maximumObservations = 3
        let handler = VNImageRequestHandler(ciImage: ci, orientation: .up, options: [:])
        do { try handler.perform([req]) } catch { return nil }
        guard let list = req.results, !list.isEmpty else { return nil }
        var best: (CGRect, Quad)?
        for o in list {
            let pts = [o.topLeft, o.topRight, o.bottomRight, o.bottomLeft]
            let xs = pts.map(\.x), ys = pts.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max() else { continue }
            let r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            let q = Quad(tl: o.topLeft, tr: o.topRight, br: o.bottomRight, bl: o.bottomLeft)
            if best == nil || r.width * r.height > best!.0.width * best!.0.height {
                best = (r, q)
            }
        }
        return best
    }

    /// 四角透视矫正；失败就退回矩形裁剪，再失败退回整帧，保证一定能出图。
    static func page(_ ci: CIImage, quad: Quad?) -> UIImage? {
        let e = ci.extent
        func px(_ p: CGPoint) -> CIVector {
            CIVector(cgPoint: CGPoint(x: e.minX + p.x * e.width, y: e.minY + p.y * e.height))
        }
        if let q = quad, let f = CIFilter(name: "CIPerspectiveCorrection") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(px(q.tl), forKey: "inputTopLeft")
            f.setValue(px(q.tr), forKey: "inputTopRight")
            f.setValue(px(q.br), forKey: "inputBottomRight")
            f.setValue(px(q.bl), forKey: "inputBottomLeft")
            if let out = f.outputImage, let cg = context.createCGImage(out, from: out.extent) {
                return UIImage(cgImage: cg)
            }
        }
        var box = e
        if let q = quad {
            let pts = [q.tl, q.tr, q.br, q.bl]
            let xs = pts.map(\.x), ys = pts.map(\.y)
            if let minX = xs.min(), let maxX = xs.max(),
               let minY = ys.min(), let maxY = ys.max() {
                box = CGRect(x: e.minX + minX * e.width, y: e.minY + minY * e.height,
                             width: (maxX - minX) * e.width, height: (maxY - minY) * e.height)
                    .integral.insetBy(dx: 2, dy: 2)
            }
        }
        if let cg = context.createCGImage(ci, from: box) { return UIImage(cgImage: cg) }
        return nil
    }
}

// MARK: - 相机 + 快门状态机

enum ShutterPhase { case seeking, locked, settling }

final class AutoCameraController: NSObject, ObservableObject,
                                  AVCaptureVideoDataOutputSampleBufferDelegate {

    @Published var status = "正在检查相机…"
    @Published var hint = ""
    @Published var pages: [UIImage] = []
    @Published var autoShutter = true
    @Published var hasCamera = false
    @Published var authorized = false
    @Published var denied = false
    @Published var torchOn = false

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "clearpaper.camera.session")
    private let videoQueue = DispatchQueue(label: "clearpaper.camera.frames")
    private var device: AVCaptureDevice?
    private var running = false

    // 以下状态只在 videoQueue 上读写
    private var phase: ShutterPhase = .seeking
    private var lastSample: FrameSample?
    private var lastShotGray: [UInt8]?
    private var lastShotHash: UInt64?
    private var lastShotArea: CGFloat = 0
    private var lastShotTime: Date = .distantPast
    private var lastUpright: CIImage?
    private var lastQuad: Quad?
    private var stableFrames = 0
    private var changeFrames = 0
    private var frameIndex = 0
    private var capturedCount = 0

    private let minInterval: TimeInterval = 1.3
    private let stableNeeded = 6        // 约 0.7 秒连续稳定
    private let turnNeeded = 2          // 连续两帧确认翻页，滤掉手抖

    // MARK: 生命周期

    func start() {
        guard !running else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                DispatchQueue.main.async {
                    self?.authorized = ok
                    self?.denied = !ok
                    if !ok { self?.status = "需要相机权限才能拍摄" }
                }
                if ok { self?.configure() }
            }
        default:
            DispatchQueue.main.async {
                self.denied = true
                self.status = "相机权限被关闭"
                self.hint = "可到「设置 → ClearPaper」打开，或改用系统文档相机"
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.running else { return }
            self.session.stopRunning()
            self.running = false
        }
    }

    private func configure() {
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: dev) else {
            DispatchQueue.main.async {
                self.hasCamera = false
                self.status = "当前设备没有可用相机"
                self.hint = "模拟器请使用「从相册选」，或改用系统文档相机"
            }
            return
        }
        device = dev
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080
        if session.canAddInput(input) { session.addInput(input) }
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(out) { session.addOutput(out) }
        session.commitConfiguration()
        DispatchQueue.main.async {
            self.hasCamera = true
            self.authorized = true
            self.status = "把试卷完整放进框内"
            self.hint = "第一页放稳后会自动拍，之后翻页才拍下一张"
        }
        sessionQueue.async { [weak self] in
            self?.session.startRunning()
            self?.running = true
        }
    }

    func toggleTorch() {
        guard let dev = device, dev.hasTorch else { return }
        try? dev.lockForConfiguration()
        let on = dev.torchMode == .off
        dev.torchMode = on ? .on : .off
        dev.unlockForConfiguration()
        DispatchQueue.main.async { self.torchOn = on }
    }

    func setAuto(_ on: Bool) {
        DispatchQueue.main.async {
            self.autoShutter = on
            if !on {
                self.status = "手动模式 · 点快门拍照"
                self.hint = "打开自动后可翻页连拍，不会重复拍同一页"
            } else {
                self.status = "已拍 \(self.capturedCount) 页 · 等待翻页"
                self.hint = "页面静止时不会重复拍"
            }
        }
    }

    func manualShutter() {
        videoQueue.async { [weak self] in
            guard let self, let s = self.lastSample else { return }
            self.shoot(s, manual: true)
        }
    }

    func undoLast() {
        DispatchQueue.main.async {
            guard !self.pages.isEmpty else { return }
            self.pages.removeLast()
        }
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.capturedCount = max(0, self.capturedCount - 1)
            self.lastShotHash = nil
            self.lastShotGray = nil
            self.lastShotArea = 0
            self.phase = .seeking
            self.stableFrames = 0
        }
        ui("已撤销上一页 · 可重新拍", "重新放稳后会自动拍摄")
    }

    // MARK: 帧回调

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        frameIndex += 1
        guard frameIndex % 4 == 0 else { return }     // 30fps → 约 7.5fps 决策
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer),
              let g = FrameAnalyzer.bgraGray(pb) else { return }

        var quad: Quad?
        var area: CGFloat = 0
        if let ci = FrameAnalyzer.upright(pb) {
            lastUpright = ci
            if let found = FrameAnalyzer.detect(ci) {
                quad = found.quad
                area = found.rect.width * found.rect.height
                lastQuad = found.quad
            }
        }
        let s = FrameSample(gray: g, hash: PageFingerprint.dHash(g), area: area,
                            quad: quad, sharp: PageFingerprint.sharpness(g))
        decide(s)
    }

    private func decide(_ s: FrameSample) {
        let prev = lastSample
        let diff = prev.map { PageFingerprint.meanDiff($0.gray, s.gray) } ?? 0
        lastSample = s
        let now = Date()
        let cooled = now.timeIntervalSince(lastShotTime) > minInterval
        let hashDist = lastShotHash.map { PageFingerprint.distance($0, s.hash) } ?? 64
        let auto = autoShutter

        switch phase {
        case .locked:
            // 拍完之后必须真的「翻页」才解锁；静止不动永远不触发第二次自动拍摄。
            guard cooled else { return }
            let pageGone = lastShotArea > 0 && s.area < lastShotArea * 0.6
            let turned = diff >= 16 || pageGone || hashDist >= 14
            changeFrames = turned ? changeFrames + 1 : 0
            if !auto {
                ui("手动模式 · 点快门拍照", "已拍 \(capturedCount) 页")
            } else if changeFrames >= turnNeeded {
                phase = .settling
                stableFrames = 0
                changeFrames = 0
                ui("检测到翻页 · 等待页面放稳", "手离开画面、页面不晃时才会拍")
            } else {
                ui("已拍 \(capturedCount) 页 · 等待翻页", "页面不动就不会重复拍")
            }
            return

        case .seeking, .settling:
            guard auto, cooled else {
                ui(auto ? "准备中…" : "手动模式 · 点快门拍照",
                   auto ? "" : "打开自动后翻页即拍，不会重复拍同一页")
                return
            }
            let hasDoc = s.area >= 0.24 && s.quad != nil
            let steady = diff <= 7
            let sharpOK = s.sharp >= 2
            stableFrames = (hasDoc && steady && sharpOK) ? stableFrames + 1 : 0

            if phase == .seeking {
                ui(hasDoc ? (steady ? "画面稳定中… \(min(stableFrames, stableNeeded))/\(stableNeeded)"
                                     : "请保持试卷不动")
                          : "把试卷完整放进框内",
                   "自动找边 · 稳定后自动拍摄")
            } else {
                ui(hasDoc ? (steady ? "新页面稳定中… \(min(stableFrames, stableNeeded))/\(stableNeeded)"
                                     : "等待新页面放稳")
                          : "翻页中…",
                   "手指遮挡、页面晃动或虚焦时不会拍")
            }
            guard stableFrames >= stableNeeded else { return }

            // 兜底去重：即使翻页信号误触发，画面与上一张几乎一样就丢弃。
            if let lg = lastShotGray, let lh = lastShotHash,
               PageFingerprint.distance(lh, s.hash) <= 10,
               PageFingerprint.meanDiff(lg, s.gray) <= 9 {
                phase = .locked
                lastShotTime = now
                stableFrames = 0
                ui("画面没变化 · 已跳过重复页", "翻到下一页才会再拍")
                return
            }
            shoot(s, manual: false)
        }
    }

    private func shoot(_ s: FrameSample, manual: Bool) {
        guard let ci = lastUpright,
              let image = FrameAnalyzer.page(ci, quad: lastQuad) else { return }
        lastShotGray = s.gray
        lastShotHash = s.hash
        lastShotArea = s.area
        lastShotTime = Date()
        phase = .locked
        stableFrames = 0
        changeFrames = 0
        capturedCount += 1
        let n = capturedCount
        DispatchQueue.main.async {
            self.pages.append(image)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            self.status = manual ? "已手动拍摄第 \(n) 页" : "已拍 \(n) 页 · 等待翻页"
            self.hint = "翻到下一页并放稳后才会再拍；也可随时点快门"
        }
    }

    private func ui(_ status: String, _ hint: String) {
        DispatchQueue.main.async {
            self.status = status
            self.hint = hint
        }
    }
}

// MARK: - 预览层

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView { PreviewView(session: session) }
    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        private var preview: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
        init(session: AVCaptureSession) {
            super.init(frame: .zero)
            backgroundColor = .black
            preview.session = session
            preview.videoGravity = .resizeAspectFill
            preview.connection?.videoOrientation = .portrait
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    }
}

// MARK: - 界面

struct AutoCameraSheet: View {
    let done: ([UIImage]) -> Void
    let cancel: () -> Void
    @State private var useSystem = false

    var body: some View {
        Group {
            if useSystem, Capture.scannerSupported {
                DocumentScanner(done: done, cancel: cancel).ignoresSafeArea()
            } else if useSystem {
                VStack(spacing: 14) {
                    Image(systemName: "camera.viewfinder").font(.largeTitle)
                    Text("当前环境不支持系统文档相机").font(.headline)
                    Text("模拟器请回到「处理」页，用「从相册选」导入照片。")
                        .font(.caption).multilineTextAlignment(.center)
                    Button("返回") { cancel() }
                        .padding(.horizontal, 20).padding(.vertical, 9)
                        .background(Capsule().stroke(.white.opacity(0.6), lineWidth: 1))
                }
                .foregroundStyle(.white)
                .padding(30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.ignoresSafeArea())
            } else {
                AutoCameraView(done: done, cancel: cancel) { useSystem = true }
            }
        }
    }
}

struct AutoCameraView: View {
    let done: ([UIImage]) -> Void
    let cancel: () -> Void
    let fallback: () -> Void
    @StateObject private var cam = AutoCameraController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if cam.hasCamera && cam.authorized {
                CameraPreview(session: cam.session).ignoresSafeArea()
                Color.black.opacity(0.18).ignoresSafeArea().allowsHitTesting(false)
                frameGuide
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                statusPill
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 22)

            if cam.denied || (!cam.hasCamera && !cam.authorized) { unavailable }
        }
        .onAppear { cam.start() }
        .onDisappear { cam.stop() }
    }

    private var frameGuide: some View {
        GeometryReader { geo in
            let w = min(geo.size.width - 40, 400)
            let h = min(w * 1.414, geo.size.height * 0.58)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                .frame(width: w, height: h)
                .overlay(alignment: .top) {
                    Text("把整页放进虚线框")
                        .font(.caption2).foregroundStyle(.white.opacity(0.8))
                        .padding(5)
                        .background(Capsule().fill(.black.opacity(0.35)))
                        .offset(y: -16)
                }
                .position(x: geo.size.width / 2, y: geo.size.height * 0.44)
        }
        .allowsHitTesting(false)
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            Button {
                cancel()
            } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.black.opacity(0.42)))
            }
            Spacer()
            VStack(spacing: 3) {
                Text("翻页自动拍").font(.headline).foregroundStyle(.white)
                Text("已拍 \(cam.pages.count) 页").font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
            }
            Spacer()
            HStack(spacing: 8) {
                Button { cam.toggleTorch() } label: {
                    Image(systemName: cam.torchOn ? "bolt.fill" : "bolt.slash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(cam.torchOn ? .yellow : .white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(.black.opacity(0.42)))
                }
                Button { cam.setAuto(!cam.autoShutter) } label: {
                    Text(cam.autoShutter ? "自动 开" : "自动 关")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(cam.autoShutter ? .black : .white)
                        .padding(.horizontal, 10).padding(.vertical, 9)
                        .background(Capsule().fill(cam.autoShutter
                            ? Color(uiColor: UIColor(red: 0.88, green: 0.62, blue: 0.12, alpha: 1))
                            : .black.opacity(0.42)))
                }
            }
        }
    }

    private var statusPill: some View {
        VStack(spacing: 6) {
            Text(cam.status).font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            if !cam.hint.isEmpty {
                Text(cam.hint).font(.caption2)
                    .foregroundStyle(.white.opacity(0.78))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(Capsule().fill(.black.opacity(0.55)))
        .padding(.horizontal, 24)
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            if !cam.pages.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(cam.pages.suffix(5).enumerated()), id: \.offset) { _, img in
                        Image(uiImage: img).resizable().scaledToFill()
                            .frame(width: 40, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5)
                                .stroke(.white.opacity(0.7), lineWidth: 1))
                    }
                    Spacer()
                }
            }
            HStack(alignment: .center) {
                Button { cam.undoLast() } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 17))
                        Text("撤销").font(.caption2)
                    }
                    .foregroundStyle(cam.pages.isEmpty ? .white.opacity(0.35) : .white)
                    .frame(width: 62)
                }
                .disabled(cam.pages.isEmpty)

                Spacer()
                Button { cam.manualShutter() } label: {
                    ZStack {
                        Circle().fill(.white).frame(width: 72, height: 72)
                        Circle().stroke(.black.opacity(0.15), lineWidth: 2)
                            .frame(width: 60, height: 60)
                    }
                }
                Spacer()

                Button {
                    guard !cam.pages.isEmpty else { return }
                    done(cam.pages)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 17))
                        Text("完成 \(cam.pages.count)").font(.caption2)
                    }
                    .foregroundStyle(cam.pages.isEmpty ? .white.opacity(0.35) : .white)
                    .frame(width: 62)
                }
                .disabled(cam.pages.isEmpty)
            }
            Button { fallback() } label: {
                Text("改用系统文档相机").font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .underline()
            }
        }
    }

    private var unavailable: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill").font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.7))
            Text(cam.denied ? "相机权限被关闭" : "当前设备没有可用相机")
                .font(.headline).foregroundStyle(.white)
            Text("模拟器可从相册导入图片；真机请允许相机权限。也可以改用系统文档相机。")
                .font(.caption).foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            HStack(spacing: 10) {
                Button { fallback() } label: {
                    Text("使用系统文档相机").font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(.white))
                }
                Button { cancel() } label: {
                    Text("返回").font(.subheadline).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().stroke(.white.opacity(0.5), lineWidth: 1))
                }
            }
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 18).fill(.black.opacity(0.7)))
        .padding(.horizontal, 28)
    }
}
