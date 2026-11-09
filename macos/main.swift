import AppKit
import PDFKit
import QuartzCore
import UniformTypeIdentifiers

// ClearPaper · macOS 原生版
// 清理引擎（engine/Core.swift 的 ScanCore）直接编译进本包，桌面端零依赖、全离线。
// UI 采用「侧边栏 + 内容卡片」布局：处理 / 设置 / 帮助。

// MARK: - 多份合并

enum MergeMode: Int {
    case separate = 0
    case full = 1
    case duplex = 2
}

func blankPDFPage(size: CGSize) -> PDFPage? {
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
func mergePDFs(_ urls: [URL], mode: MergeMode, to out: URL) -> Int {
    let merged = PDFDocument()
    for (idx, url) in urls.enumerated() {
        guard let doc = PDFDocument(url: url) else { continue }
        let n = doc.pageCount
        guard n > 0 else { continue }
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

// MARK: - 输出目录（沙盒安全）

final class OutputStore {
    static let shared = OutputStore()
    private(set) var url: URL
    private var scoped = false
    private let key = "scanpdf.outputBookmark"

    init() {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["SCANPDF_OUTDIR"], !env.isEmpty {
            let u = URL(fileURLWithPath: env, isDirectory: true)
            url = u
            try? fm.createDirectory(at: u, withIntermediateDirectories: true)
            return
        }
        let fallback = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("试卷清晰版", isDirectory: true)
        if let data = UserDefaults.standard.data(forKey: key) {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: data,
                                options: .withSecurityScope, relativeTo: nil,
                                bookmarkDataIsStale: &stale),
               u.startAccessingSecurityScopedResource() {
                url = u; scoped = true; return
            }
        }
        url = fallback
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "选为输出文件夹"
        panel.message = "处理后的 A4 清晰版 PDF 会保存到这个文件夹"
        panel.directoryURL = url
        guard panel.runModal() == .OK, let picked = panel.urls.first else { return }
        do {
            if scoped { url.stopAccessingSecurityScopedResource() }
            let data = try picked.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil)
            UserDefaults.standard.set(data, forKey: key)
            url = picked; scoped = true
            _ = url.startAccessingSecurityScopedResource()
        } catch { presentError("无法记住该文件夹：\(error.localizedDescription)") }
    }

    func stopAccessing() { if scoped { url.stopAccessingSecurityScopedResource() } }
}

// MARK: - 设计令牌（参考 Purrge 的浅色/深色体系）

enum T {
    static func dyn(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { app in
            app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
    static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    // 色值对齐 Purrge：浅色侧栏 #EBEBEE / 内容底 #F6F6F7 / 卡片白；
    // 深色不是纯黑，而是暖灰 #262628 / #1C1C1E / #2A2A2D。
    static let canvas    = dyn(hex(0xF6F6F7), hex(0x1C1C1E))
    static let sidebar   = dyn(hex(0xEBEBEE), hex(0x262628))
    static let panel     = dyn(hex(0xFFFFFF), hex(0x2A2A2D))
    static let panel2    = dyn(hex(0xFAFAFB), hex(0x232326))
    static let ink       = dyn(hex(0x1B1B1E), hex(0xF2F2F4))
    static let ink2      = dyn(hex(0x3A3A3F), hex(0xC9C9CE))
    static let sub       = dyn(hex(0x6C6C72), hex(0x9A9AA0))
    static let mute      = dyn(hex(0x9A9AA0), hex(0x6E6E74))
    static let line      = dyn(hex(0xE4E4E8), hex(0x3A3A3D))
    static let line2     = dyn(hex(0xEFEFF2), hex(0x303033))
    static let graySoft  = dyn(hex(0xEDEDF0), hex(0x343437))
    static let navSelected = dyn(hex(0xD8D8DB), hex(0x3D3D3E))
    static let navHover    = dyn(hex(0xE2E2E6), hex(0x323234))
    static let pillBg      = dyn(hex(0xE3E3E6), hex(0x38383A))
    static let amber     = dyn(hex(0xE08A00), hex(0xF0A83C))
    static let amberSoft = dyn(hex(0xFFF3DC), hex(0x3A2B12))
    static let green     = dyn(hex(0x12A374), hex(0x35C79B))
    static let greenSoft = dyn(hex(0xE6F6F0), hex(0x163024))
    static let blue      = dyn(hex(0x2F6BFF), hex(0x6B9BFF))
    static let blueSoft  = dyn(hex(0xEAF0FF), hex(0x1E2A44))
    static let red       = dyn(hex(0xE5484D), hex(0xFF6B6F))
    static let redSoft   = dyn(hex(0xFDECEC), hex(0x3A2023))

    static let cardR: CGFloat = 14
    static let sidebarW: CGFloat = 208
}

// MARK: - 基础小组件

class ColorView: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    init(color: NSColor = .clear) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = color.cgColor }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

func label(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular,
           _ color: NSColor = T.ink) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    return l
}

func hstack(_ views: [NSView], spacing: CGFloat = 8,
            alignment: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .horizontal
    s.alignment = alignment
    s.spacing = spacing
    s.translatesAutoresizingMaskIntoConstraints = false
    return s
}


func vstack(_ views: [NSView], spacing: CGFloat = 10,
            alignment: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .vertical
    s.alignment = alignment
    s.spacing = spacing
    s.translatesAutoresizingMaskIntoConstraints = false
    return s
}

func spacer() -> NSView {
    let v = NSView()
    v.translatesAutoresizingMaskIntoConstraints = false
    v.setContentHuggingPriority(.defaultLow, for: .horizontal)
    v.setContentHuggingPriority(.defaultLow, for: .vertical)
    return v
}

func iconBox(_ name: String, size: CGFloat = 34, radius: CGFloat = 9,
             tint: NSColor = T.ink2, bg: NSColor = T.graySoft,
             point: CGFloat = 15) -> NSView {
    let box = ColorView(color: bg)
    box.translatesAutoresizingMaskIntoConstraints = false
    box.layer?.cornerRadius = radius
    box.layer?.cornerCurve = .continuous
    let iv = NSImageView()
    iv.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    iv.symbolConfiguration = .init(pointSize: point, weight: .medium)
    iv.contentTintColor = tint
    iv.imageScaling = .scaleProportionallyDown
    iv.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(iv)
    NSLayoutConstraint.activate([
        box.widthAnchor.constraint(equalToConstant: size),
        box.heightAnchor.constraint(equalToConstant: size),
        iv.centerXAnchor.constraint(equalTo: box.centerXAnchor),
        iv.centerYAnchor.constraint(equalTo: box.centerYAnchor),
    ])
    return box
}

func chip(_ text: String, fg: NSColor, bg: NSColor) -> NSView {
    let v = ColorView(color: bg)
    v.translatesAutoresizingMaskIntoConstraints = false
    v.layer?.cornerRadius = 7
    v.layer?.cornerCurve = .continuous
    let l = label(text, 10.5, .semibold, fg)
    l.translatesAutoresizingMaskIntoConstraints = false
    v.addSubview(l)
    NSLayoutConstraint.activate([
        l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 7),
        l.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -7),
        l.topAnchor.constraint(equalTo: v.topAnchor, constant: 2),
        l.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -2),
    ])
    return v
}

/// 圆角卡片，带细边框与很浅的阴影。
final class Card: NSView {
    init(_ content: NSView,
         padding: NSEdgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20),
         radius: CGFloat = T.cardR) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.05
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: 2)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding.left),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding.right),
            content.topAnchor.constraint(equalTo: topAnchor, constant: padding.top),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding.bottom),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = T.panel.cgColor
        layer?.borderColor = T.line.cgColor
    }
}

/// 可滚动页面：内容从顶部开始。
final class PageScroll: NSScrollView {
    let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .noBorder

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        documentView = doc

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)

        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 54),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -28),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func addFull(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}

// MARK: - 侧边栏

enum StatusTone {
    case neutral, busy, ok, bad
    var color: NSColor {
        switch self {
        case .neutral: return T.mute
        case .busy: return T.amber
        case .ok: return T.green
        case .bad: return T.red
        }
    }
}

final class StatusPill: ColorView {
    private let dot = ColorView()
    private let textLabel = NSTextField(labelWithString: "就绪")
    var tone: StatusTone = .ok { didSet { needsDisplay = true } }
    var text: String {
        get { textLabel.stringValue }
        set { textLabel.stringValue = newValue }
    }

    init() {
        super.init(color: T.pillBg)
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.color = T.green
        dot.layer?.cornerRadius = 4
        dot.layer?.cornerCurve = .continuous
        textLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        textLabel.textColor = T.ink2
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot); addSubview(textLabel)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            textLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        super.updateLayer()
        dot.color = tone.color
        textLabel.textColor = T.ink2
    }
}

final class NavRow: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private var hover = false
    var onTap: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }
    var badgeText: String = "" {
        didSet {
            badge.stringValue = badgeText
            badge.isHidden = badgeText.isEmpty
        }
    }

    init(symbol: String, title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous

        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13.5, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        badge.font = .systemFont(ofSize: 10.5, weight: .semibold)
        badge.textColor = T.mute
        badge.alignment = .right
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView); addSubview(titleLabel); addSubview(badge)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -6),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (isSelected ? T.navSelected : (hover ? T.navHover : T.sidebar)).cgColor
        iconView.contentTintColor = isSelected ? T.amber : T.sub
        titleLabel.textColor = isSelected ? T.ink : T.ink2
        titleLabel.font = .systemFont(ofSize: 13.5, weight: isSelected ? .semibold : .medium)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onTap?() }
}

final class DiskBar: NSView {
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height, r = h / 2
        T.line2.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        let w = max(0, min(1, fraction)) * bounds.width
        if w > 0.5 {
            T.mute.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h),
                         xRadius: r, yRadius: r).fill()
        }
    }
}

// MARK: - 主按钮

final class PrimaryButton: NSControl {
    private let label = NSTextField(labelWithString: "")
    var titleText: String = "" {
        didSet {
            label.stringValue = titleText
            setAccessibilityLabel(titleText)
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.button)

        label.font = .systemFont(ofSize: 13.5, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (isEnabled ? T.ink : T.graySoft).cgColor
        label.textColor = isEnabled ? T.panel : T.sub
    }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return bounds.contains(p) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        layer?.backgroundColor = T.ink.withAlphaComponent(0.82).cgColor
    }
    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        needsDisplay = true
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) { sendAction(action, to: target) }
    }
}

// MARK: - 拖拽区

final class DropCard: ColorView {
    var onDrop: (([URL]) -> Void)?
    var onPick: (() -> Void)?
    private var hover = false { didSet { needsDisplay = true } }
    private let dash = CAShapeLayer()

    init() {
        super.init(color: T.panel)
        registerForDraggedTypes([.fileURL])
        layer?.cornerRadius = T.cardR
        layer?.cornerCurve = .continuous
        dash.fillColor = NSColor.clear.cgColor
        dash.lineWidth = 1.5
        dash.lineDashPattern = [6, 4]
        layer?.addSublayer(dash)

        let ic = iconBox("arrow.down.doc.fill", size: 44, radius: 12,
                         tint: T.amber, bg: T.amberSoft, point: 20)
        let title = label("把 PDF 拖到这里", 15, .semibold, T.ink)
        let hint = label("支持一次多个 · 横向 / 竖向都行", 11.5, .regular, T.sub)
        let pick = NSButton(title: "选择文件…", target: self, action: #selector(pickTapped))
        pick.bezelStyle = .rounded
        pick.controlSize = .small
        pick.font = .systemFont(ofSize: 11.5, weight: .medium)

        let stack = vstack([ic, title, hint, pick], spacing: 8, alignment: .centerX)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 156),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pickTapped() { onPick?() }

    override func layout() {
        super.layout()
        dash.frame = bounds
        dash.path = CGPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                           cornerWidth: T.cardR, cornerHeight: T.cardR, transform: nil)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (hover ? T.amberSoft.withAlphaComponent(0.35) : T.panel).cgColor
        dash.strokeColor = (hover ? T.amber : T.amber.withAlphaComponent(0.45)).cgColor
    }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        hover = true; return pdfs(s).isEmpty ? [] : .copy
    }
    override func draggingExited(_ s: NSDraggingInfo?) { hover = false }
    override func prepareForDragOperation(_ s: NSDraggingInfo) -> Bool { !pdfs(s).isEmpty }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        hover = false
        let list = pdfs(s)
        if !list.isEmpty { onDrop?(list) }
        return !list.isEmpty
    }
    private func pdfs(_ s: NSDraggingInfo) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] =
            [.urlReadingContentsConformToTypes: [UTType.pdf.identifier]]
        guard let items = s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL]
        else { return [] }
        return items.filter { $0.pathExtension.lowercased() == "pdf" &&
                              !$0.lastPathComponent.contains("清晰") }
    }
}

// MARK: - 队列模型与行

final class Job: NSObject {
    @objc var name = ""
    @objc var state = "排队中"
    @objc var detail = ""
    var source: URL?
    var output: URL?
}

final class TagPill: ColorView {
    private let label = NSTextField(labelWithString: "")
    var text = "" { didSet { label.stringValue = text } }
    var tone: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }

    init() {
        super.init(color: T.graySoft)
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 62),
            heightAnchor.constraint(equalToConstant: 20),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = tone.withAlphaComponent(0.15).cgColor
        label.textColor = tone
    }
}

final class RowCell: NSTableCellView {
    let name = NSTextField(labelWithString: "")
    let meta = NSTextField(labelWithString: "")
    let pill = TagPill()
    let bar = NSProgressIndicator()
    private let iconBox = ColorView(color: T.graySoft)
    private let iconView = NSImageView()
    private let sep = ColorView(color: T.line2)

    override init(frame: NSRect) {
        super.init(frame: frame)

        iconBox.translatesAutoresizingMaskIntoConstraints = false
        iconBox.layer?.cornerRadius = 9
        iconBox.layer?.cornerCurve = .continuous
        iconView.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        iconView.contentTintColor = T.ink2
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconBox.addSubview(iconView)

        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = T.ink
        name.lineBreakMode = .byTruncatingTail
        meta.font = .systemFont(ofSize: 11)
        meta.textColor = T.sub
        meta.lineBreakMode = .byTruncatingTail
        let texts = vstack([name, meta], spacing: 1)
        texts.translatesAutoresizingMaskIntoConstraints = false

        pill.translatesAutoresizingMaskIntoConstraints = false

        bar.style = .bar
        bar.isIndeterminate = true
        bar.controlSize = .small
        bar.isHidden = true
        bar.translatesAutoresizingMaskIntoConstraints = false

        sep.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconBox); addSubview(texts); addSubview(pill); addSubview(bar); addSubview(sep)
        NSLayoutConstraint.activate([
            iconBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconBox.widthAnchor.constraint(equalToConstant: 34),
            iconBox.heightAnchor.constraint(equalToConstant: 34),
            iconView.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),

            texts.leadingAnchor.constraint(equalTo: iconBox.trailingAnchor, constant: 10),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -3),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: pill.leadingAnchor, constant: -10),

            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),

            bar.leadingAnchor.constraint(equalTo: texts.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: pill.leadingAnchor, constant: -10),
            bar.topAnchor.constraint(equalTo: texts.bottomAnchor, constant: 3),

            sep.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            sep.bottomAnchor.constraint(equalTo: bottomAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        iconBox.color = T.graySoft
        iconView.contentTintColor = T.ink2
        name.textColor = T.ink
        meta.textColor = T.sub
        sep.color = T.line2
    }
}

// MARK: - 关于 / 错误

func presentAbout() {
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                       styleMask: [.titled, .closable],
                       backing: .buffered, defer: false)
    win.title = "关于 ClearPaper"
    win.isReleasedWhenClosed = false
    let box = NSBox()
    box.boxType = .custom
    box.fillColor = .windowBackgroundColor
    box.cornerRadius = 0
    win.contentView = box

    let icon = NSImageView()
    icon.translatesAutoresizingMaskIntoConstraints = false
    if let u = Bundle.main.url(forResource: "Icon", withExtension: "icns"),
       let art = NSImage(contentsOf: u) { icon.image = art }
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.wantsLayer = true
    icon.layer?.cornerRadius = 18
    icon.layer?.cornerCurve = .continuous

    let name = NSTextField(labelWithString: "ClearPaper")
    name.font = .systemFont(ofSize: 20, weight: .bold)
    let ver = NSTextField(labelWithString:
        "版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")"
        + "（\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")）")
    ver.font = .systemFont(ofSize: 11)
    ver.textColor = .secondaryLabelColor
    let desc = NSTextField(labelWithString:
        "把扫描 / 拍照的试卷，转成可直接打印的 A4 清晰版。\n支持多份按顺序合并，横向页面自动用横向 A4。")
    desc.font = .systemFont(ofSize: 12)
    desc.textColor = .secondaryLabelColor
    desc.alignment = .center
    desc.lineBreakMode = .byWordWrapping
    desc.maximumNumberOfLines = 0
    let copy = NSTextField(labelWithString: "© 2026 jpruby · 全离线运行 · 不上传任何文件")
    copy.font = .systemFont(ofSize: 11)
    copy.textColor = .tertiaryLabelColor

    for v in [icon, name, ver, desc, copy] {
        v.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(v)
    }
    NSLayoutConstraint.activate([
        icon.topAnchor.constraint(equalTo: box.topAnchor, constant: 26),
        icon.centerXAnchor.constraint(equalTo: box.centerXAnchor),
        icon.widthAnchor.constraint(equalToConstant: 76),
        icon.heightAnchor.constraint(equalToConstant: 76),
        name.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 14),
        name.centerXAnchor.constraint(equalTo: box.centerXAnchor),
        ver.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 4),
        ver.centerXAnchor.constraint(equalTo: box.centerXAnchor),
        desc.topAnchor.constraint(equalTo: ver.bottomAnchor, constant: 12),
        desc.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 34),
        desc.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -34),
        copy.topAnchor.constraint(equalTo: desc.bottomAnchor, constant: 10),
        copy.centerXAnchor.constraint(equalTo: box.centerXAnchor),
    ])
    win.center()
    win.makeKeyAndOrderFront(nil)
}

func presentError(_ msg: String) {
    let a = NSAlert()
    a.messageText = "出错了"
    a.informativeText = msg
    a.alertStyle = .warning
    a.runModal()
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
    let table = NSTableView()
    let empty = NSView()
    let status = NSTextField(labelWithString: "就绪")
    let start = PrimaryButton()
    let mergePopup = NSPopUpButton()
    let settingsMergePopup = NSPopUpButton()
    let sidebarPill = StatusPill()
    let outputPathLabel = NSTextField(labelWithString: "")
    let countLabel = NSTextField(labelWithString: "")
    let diskName = NSTextField(labelWithString: "Macintosh HD")
    let diskFree = NSTextField(labelWithString: "")
    let diskBar = DiskBar()

    var jobs: [Job] = []
    var busy = false
    var drop: DropCard!
    var pages: [PageScroll] = []
    var navRows: [NavRow] = []
    var processingRow: NavRow?
    var currentPage = 0

    var mergeMode: MergeMode {
        MergeMode(rawValue: mergePopup.indexOfSelectedItem) ?? .separate
    }

    // MARK: 菜单

    func buildMenu() {
        let main = NSMenu()
        let appName = "ClearPaper"

        let appMenu = NSMenu(title: appName)
        appMenu.addItem(NSMenuItem(title: "关于 \(appName)", action: #selector(about), keyEquivalent: ""))
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        services.submenu = NSApp.servicesMenu ?? NSMenu()
        NSApp.servicesMenu = services.submenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "隐藏 \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "退出 \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appItem = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let file = NSMenu(title: "文件")
        file.addItem(NSMenuItem(title: "打开 PDF…", action: #selector(pick), keyEquivalent: "o"))
        file.addItem(.separator())
        file.addItem(NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ","))
        file.addItem(NSMenuItem(title: "选择输出文件夹…", action: #selector(chooseOutput), keyEquivalent: ""))
        file.addItem(NSMenuItem(title: "打开输出文件夹", action: #selector(reveal), keyEquivalent: ""))
        let fileItem = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
        fileItem.submenu = file
        main.addItem(fileItem)

        let edit = NSMenu(title: "编辑")
        edit.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "全选", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a"))
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "全部置于最前", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        NSApp.windowsMenu = windowMenu
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        let help = NSMenu(title: "帮助")
        help.addItem(NSMenuItem(title: "使用帮助", action: #selector(showHelpPage), keyEquivalent: ""))
        help.addItem(NSMenuItem(title: "关于", action: #selector(about), keyEquivalent: ""))
        let helpItem = NSMenuItem(title: "帮助", action: nil, keyEquivalent: "")
        helpItem.submenu = help
        main.addItem(helpItem)

        NSApp.mainMenu = main
    }

    @objc func about() { presentAbout() }
    @objc func showSettings() { showPage(1) }
    @objc func showHelpPage() { showPage(2) }

    // MARK: 启动

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()

        window.title = "ClearPaper"
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.backgroundColor = T.canvas
        window.minSize = NSSize(width: 760, height: 540)
        if let spec = ProcessInfo.processInfo.environment["SCANPDF_SIZE"] {
            let parts = spec.lowercased().split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { window.setContentSize(NSSize(width: parts[0], height: parts[1])) }
        }
        window.center()

        let root = ColorView(color: T.canvas)
        window.contentView = root

        // 侧边栏
        let sidebar = ColorView(color: T.sidebar)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)

        let divider = ColorView(color: T.line)
        divider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(divider)

        // 内容区
        let content = ColorView(color: T.canvas)
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: T.sidebarW),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            content.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        if ProcessInfo.processInfo.environment["SCANPDF_APPEARANCE"] == "light" {
            NSApp.appearance = NSAppearance(named: .aqua)
        }

        buildSidebar(sidebar)
        buildPages(content)
        showPage(0)
        if let p = ProcessInfo.processInfo.environment["SCANPDF_PAGE"] {
            showPage(p == "settings" ? 1 : (p == "help" ? 2 : 0))
        }

        // 恢复合并方式
        let saved = UserDefaults.standard.integer(forKey: "scanpdf.mergeMode")
        applyMergeMode(saved, persist: false)
        if let m = ProcessInfo.processInfo.environment["SCANPDF_MERGE"] {
            applyMergeMode(m == "full" ? 1 : (m == "duplex" ? 2 : 0), persist: false)
        }
        refreshOutputPath()
        refreshDisk()
        setStatus("就绪")

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 自动化：命令行传入 PDF 路径即可排队
        let args = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
        let pdfs = args.filter { $0.pathExtension.lowercased() == "pdf" &&
                                 FileManager.default.fileExists(atPath: $0.path) }
        if !pdfs.isEmpty {
            enqueue(pdfs)
            if ProcessInfo.processInfo.environment["SCANPDF_AUTORUN"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.begin()
                }
            }
        }
    }

    // MARK: 侧边栏

    func buildSidebar(_ sidebar: NSView) {
        // 顶部品牌
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        if let u = Bundle.main.url(forResource: "Icon", withExtension: "icns"),
           let art = NSImage(contentsOf: u) { icon.image = art }
        else { icon.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: nil) }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 12
        icon.layer?.cornerCurve = .continuous
        icon.layer?.masksToBounds = true

        let name = label("ClearPaper", 16, .bold, T.ink)
        let by = label("by jpruby", 11.5, .medium, T.mute)
        let titles = vstack([name, by], spacing: 1)
        let head = hstack([icon, titles], spacing: 11, alignment: .centerY)
        head.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(head)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 46),
            icon.heightAnchor.constraint(equalToConstant: 46),
            head.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            head.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.trailingAnchor, constant: -16),
            head.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 52),
        ])

        // 导航
        let nav = NSStackView()
        nav.orientation = .vertical
        nav.alignment = .leading
        nav.spacing = 4
        nav.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(nav)

        let items: [(String, String)] = [
            ("wand.and.stars", "处理"),
            ("gearshape", "设置"),
            ("questionmark.circle", "帮助"),
        ]
        for (i, item) in items.enumerated() {
            let row = NavRow(symbol: item.0, title: item.1)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.onTap = { [weak self] in self?.showPage(i) }
            nav.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: nav.widthAnchor).isActive = true
            navRows.append(row)
            if i == 0 { processingRow = row }
        }
        NSLayoutConstraint.activate([
            nav.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            nav.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            nav.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 22),
        ])

        // 底部：状态 + 磁盘
        sidebarPill.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarPill)

        diskName.font = .systemFont(ofSize: 11, weight: .medium)
        diskName.textColor = T.sub
        diskName.lineBreakMode = .byTruncatingTail
        diskFree.font = .systemFont(ofSize: 11, weight: .semibold)
        diskFree.textColor = T.ink2
        diskFree.alignment = .right
        let diskRow = hstack([diskName, spinnerSpacer(), diskFree], spacing: 6)
        diskRow.translatesAutoresizingMaskIntoConstraints = false
        diskBar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(diskRow); sidebar.addSubview(diskBar)

        NSLayoutConstraint.activate([
            sidebarPill.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            sidebarPill.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),

            diskRow.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            diskRow.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16),
            diskRow.bottomAnchor.constraint(equalTo: diskBar.topAnchor, constant: -8),

            diskBar.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            diskBar.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16),
            diskBar.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -16),
            diskBar.heightAnchor.constraint(equalToConstant: 4),

            sidebarPill.bottomAnchor.constraint(equalTo: diskRow.topAnchor, constant: -14),
        ])
    }

    func spinnerSpacer() -> NSView { spacer() }

    // MARK: 页面

    func buildPages(_ host: NSView) {
        let process = PageScroll()
        let settings = PageScroll()
        let help = PageScroll()
        pages = [process, settings, help]
        for p in pages {
            p.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(p)
            NSLayoutConstraint.activate([
                p.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                p.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                p.topAnchor.constraint(equalTo: host.topAnchor),
                p.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        }

        buildProcessPage(process)
        buildSettingsPage(settings)
        buildHelpPage(help)
    }

    func pageHeader(_ title: String, _ subtitle: String, badge: String? = nil) -> NSView {
        let t = label(title, 28, .bold, T.ink)
        let s = label(subtitle, 13, .regular, T.sub)
        var rowViews: [NSView] = [t]
        if let badge = badge {
            rowViews.append(spacer())
            rowViews.append(chip(badge, fg: T.amber, bg: T.amberSoft))
        }
        let row = hstack(rowViews, spacing: 10)
        let stack = vstack([row, s], spacing: 6)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        s.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    func buildProcessPage(_ page: PageScroll) {
        page.addFull(pageHeader("ClearPaper",
                                "扫描 / 拍照的试卷 → 可直接打印的 A4 清晰版 · 全离线",
                                badge: "全离线"))

        // 拖拽区
        drop = DropCard()
        drop.onDrop = { [weak self] in self?.enqueue($0) }
        drop.onPick = { [weak self] in self?.pick() }
        page.addFull(drop)

        // 队列
        let queueTitle = label("待处理", 13.5, .semibold, T.ink)
        countLabel.font = .systemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = T.mute
        let clear = NSButton(title: "清空", target: self, action: #selector(clearQueue))
        clear.isBordered = false
        clear.font = .systemFont(ofSize: 11.5, weight: .medium)
        clear.contentTintColor = T.sub
        let queueHead = hstack([queueTitle, countLabel, spacer(), clear], spacing: 8)

        table.style = .plain
        table.rowHeight = 66
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero
        table.registerForDraggedTypes([.string])
        table.draggingDestinationFeedbackStyle = .gap
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openResult)
        let col = NSTableColumn(identifier: .init("row"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.autoresizingMask = [.width]
        table.frame = NSRect(x: 0, y: 0, width: 640, height: 224)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let queueHost = NSView()
        queueHost.translatesAutoresizingMaskIntoConstraints = false
        queueHost.heightAnchor.constraint(equalToConstant: 224).isActive = true
        queueHost.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: queueHost.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: queueHost.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: queueHost.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: queueHost.bottomAnchor),
        ])

        let emptyIcon = NSImageView()
        emptyIcon.image = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)
        emptyIcon.symbolConfiguration = .init(pointSize: 24, weight: .regular)
        emptyIcon.contentTintColor = T.mute
        let emptyTitle = label("还没有文件", 12.5, .medium, T.sub)
        let emptyHint = label("拖入 PDF，或点「选择文件…」", 11.5, .regular, T.mute)
        let emptyStack = vstack([emptyIcon, emptyTitle, emptyHint], spacing: 6, alignment: .centerX)
        empty.translatesAutoresizingMaskIntoConstraints = false
        empty.addSubview(emptyStack)
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyStack.centerXAnchor.constraint(equalTo: empty.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: empty.centerYAnchor),
        ])
        queueHost.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.leadingAnchor.constraint(equalTo: queueHost.leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: queueHost.trailingAnchor),
            empty.topAnchor.constraint(equalTo: queueHost.topAnchor),
            empty.bottomAnchor.constraint(equalTo: queueHost.bottomAnchor),
        ])

        let queueStack = vstack([queueHead, queueHost], spacing: 10)
        queueHead.widthAnchor.constraint(equalTo: queueStack.widthAnchor).isActive = true
        queueHost.widthAnchor.constraint(equalTo: queueStack.widthAnchor).isActive = true
        let queueCard = Card(queueStack)
        page.addFull(queueCard)

        // 输出方式 + 开始
        let outLabel = label("输出方式", 13, .medium, T.ink2)
        configureMergePopup(mergePopup)
        mergePopup.target = self
        mergePopup.action = #selector(mergeModeChanged)
        mergePopup.controlSize = .small
        mergePopup.font = .systemFont(ofSize: 12)

        start.titleText = "开始处理"
        start.target = self
        start.action = #selector(begin)
        start.isEnabled = false
        start.widthAnchor.constraint(greaterThanOrEqualToConstant: 128).isActive = true
        start.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let actionTop = hstack([outLabel, mergePopup, spacer(), start], spacing: 10)
        status.font = .systemFont(ofSize: 11.5)
        status.textColor = T.sub
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let actionStack = vstack([actionTop, status], spacing: 8)
        actionTop.widthAnchor.constraint(equalTo: actionStack.widthAnchor).isActive = true
        status.widthAnchor.constraint(equalTo: actionStack.widthAnchor).isActive = true
        let actionCard = Card(actionStack, padding: NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18))
        page.addFull(actionCard)

        syncQueue()
    }

    func buildSettingsPage(_ page: PageScroll) {
        page.addFull(pageHeader("设置", "输出位置、默认方式与数据边界"))

        // 输出设置
        let pathRow = settingRow(icon: "folder",
                                 title: "输出文件夹",
                                 subtitle: outputPathLabel,
                                 accessory: smallButton("选择…", #selector(chooseOutput)))
        let openRow = settingRow(icon: "arrow.up.forward.app",
                                 title: "打开输出文件夹",
                                 subtitle: label("在访达中查看处理结果", 11.5, .regular, T.sub),
                                 accessory: smallButton("打开", #selector(reveal)))
        configureMergePopup(settingsMergePopup)
        settingsMergePopup.target = self
        settingsMergePopup.action = #selector(settingsMergeChanged)
        settingsMergePopup.controlSize = .small
        settingsMergePopup.font = .systemFont(ofSize: 12)
        let mergeRow = settingRow(icon: "doc.on.doc",
                                  title: "默认输出方式",
                                  subtitle: label("合并按队列顺序 · 间隔模式双面不跨卷", 11.5, .regular, T.sub),
                                  accessory: settingsMergePopup)
        let list = vstack([pathRow, separator(), openRow, separator(), mergeRow], spacing: 0)
        for v in list.arrangedSubviews {
            v.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        page.addFull(Card(list, padding: NSEdgeInsets(top: 4, left: 16, bottom: 4, right: 16)))

        // 数据边界
        page.addFull(sectionHeader("数据边界", hint: "无论处理什么文件都一样"))
        let c1 = infoCard(icon: "wifi.slash", title: "全离线",
                          body: "只在你自己的电脑上处理，不上传任何文件，也不需要联网。",
                          tint: T.amber, soft: T.amberSoft)
        let c2 = infoCard(icon: "lock.shield", title: "不改原件",
                          body: "只读取你拖入的 PDF，原文件不会被修改或移动。",
                          tint: T.blue, soft: T.blueSoft)
        let c3 = infoCard(icon: "checkmark.seal", title: "质量闸门",
                          body: "输出前检查笔画保留、A4 尺寸与页数，不达标会提示。",
                          tint: T.green, soft: T.greenSoft)
        let cards = hstack([c1, c2, c3], spacing: 12, alignment: .top)
        cards.distribution = .fillEqually
        page.addFull(cards)

        // 关于
        page.addFull(sectionHeader("关于"))
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let aboutRow = settingRow(icon: "info.circle",
                                  title: "ClearPaper \(ver)",
                                  subtitle: label("github.com/jpruby0127/ClearPaper", 11.5, .regular, T.sub),
                                  accessory: smallButton("打开", #selector(openRepo)))
        page.addFull(Card(aboutRow, padding: NSEdgeInsets(top: 4, left: 16, bottom: 4, right: 16)))
    }

    func buildHelpPage(_ page: PageScroll) {
        page.addFull(pageHeader("帮助", "三步把试卷变成可打印的清晰版"))

        let steps = vstack([
            helpStep(1, "拖入 PDF", "把一份或多份试卷拖进「处理」页，或点「选择文件…」。加入顺序就是合并顺序，列表可拖动调整。"),
            helpStep(2, "选输出方式", "分别保存：每份各存一个清晰版；合并（完全）：首尾相接；合并（间隔·双面）：每份后补空白页，双面打印不跨卷。"),
            helpStep(3, "开始处理", "点「开始处理 / 开始并合并」。全部在本机完成，完成后可在输出文件夹查看。"),
        ], spacing: 14)
        for v in steps.arrangedSubviews {
            v.widthAnchor.constraint(equalTo: steps.widthAnchor).isActive = true
        }
        page.addFull(Card(steps))

        page.addFull(paragraphCard("打印小贴士",
            "打印时选 A4、缩放「实际大小 / 100%」，不要选「适合页面」。横向页面会自动输出横向 A4。"))
        page.addFull(paragraphCard("合并方式",
            "完全合并：按队列顺序首尾相接。\n间隔合并：每份非末尾文档为奇数页时补一张空白页，保证下一份从新纸正面开始。"))
        let offline = label("全离线 · 不上传任何文件 · 数据只在本机", 11.5, .regular, T.mute)
        offline.alignment = .center
        page.addFull(offline)
    }

    func paragraphCard(_ title: String, _ body: String) -> Card {
        let t = label(title, 13.5, .semibold, T.ink)
        let b = label(body, 12, .regular, T.sub)
        b.maximumNumberOfLines = 0
        b.lineBreakMode = .byWordWrapping
        let s = vstack([t, b], spacing: 6)
        t.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
        b.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
        return Card(s)
    }

    func settingRow(icon: String, title: String, subtitle: NSTextField, accessory: NSView) -> NSView {
        let box = iconBox(icon)
        let t = label(title, 13.5, .semibold, T.ink)
        subtitle.font = .systemFont(ofSize: 11.5)
        subtitle.textColor = T.sub
        subtitle.lineBreakMode = .byTruncatingMiddle
        let texts = vstack([t, subtitle], spacing: 2)
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = hstack([box, texts, spacer(), accessory], spacing: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 64).isActive = true
        return row
    }

    func sectionHeader(_ title: String, hint: String? = nil) -> NSView {
        let t = label(title, 13.5, .semibold, T.ink)
        var views: [NSView] = [t]
        if let hint = hint {
            views.append(spacer())
            views.append(label(hint, 11.5, .regular, T.mute))
        }
        return hstack(views, spacing: 8)
    }

    func infoCard(icon: String, title: String, body: String,
                  tint: NSColor, soft: NSColor) -> Card {
        let box = iconBox(icon, size: 30, radius: 8, tint: tint, bg: soft, point: 14)
        let t = label(title, 13.5, .semibold, T.ink)
        let b = label(body, 11.5, .regular, T.sub)
        b.maximumNumberOfLines = 0
        b.lineBreakMode = .byWordWrapping
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        b.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = vstack([box, t, b], spacing: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        t.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        b.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let card = Card(stack, padding: NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))
        card.heightAnchor.constraint(greaterThanOrEqualToConstant: 122).isActive = true
        return card
    }

    func helpStep(_ n: Int, _ title: String, _ body: String) -> NSView {
        let num = ColorView(color: T.amberSoft)
        num.translatesAutoresizingMaskIntoConstraints = false
        num.layer?.cornerRadius = 11
        num.layer?.cornerCurve = .continuous
        let nl = label("\(n)", 12, .bold, T.amber)
        nl.alignment = .center
        nl.translatesAutoresizingMaskIntoConstraints = false
        num.addSubview(nl)
        NSLayoutConstraint.activate([
            num.widthAnchor.constraint(equalToConstant: 24),
            num.heightAnchor.constraint(equalToConstant: 24),
            nl.centerXAnchor.constraint(equalTo: num.centerXAnchor),
            nl.centerYAnchor.constraint(equalTo: num.centerYAnchor),
        ])
        let t = label(title, 13, .semibold, T.ink)
        let b = label(body, 11.5, .regular, T.sub)
        b.maximumNumberOfLines = 0
        b.lineBreakMode = .byWordWrapping
        let texts = vstack([t, b], spacing: 3)
        texts.translatesAutoresizingMaskIntoConstraints = false
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        b.widthAnchor.constraint(equalTo: texts.widthAnchor).isActive = true
        let row = hstack([num, texts], spacing: 12, alignment: .top)
        return row
    }

    func separator() -> NSView {
        let s = ColorView(color: T.line2)
        s.translatesAutoresizingMaskIntoConstraints = false
        s.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return s
    }

    func smallButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11.5, weight: .medium)
        return b
    }

    func configureMergePopup(_ p: NSPopUpButton) {
        p.removeAllItems()
        p.addItems(withTitles: ["分别保存", "合并（完全）", "合并（间隔·双面）"])
    }

    // MARK: 页面切换

    func showPage(_ index: Int) {
        guard index >= 0, index < pages.count else { return }
        currentPage = index
        for (i, p) in pages.enumerated() { p.isHidden = (i != index) }
        for (i, r) in navRows.enumerated() { r.isSelected = (i == index) }
        let p = pages[index]
        p.contentView.scroll(to: .zero)
        p.reflectScrolledClipView(p.contentView)
    }

    // MARK: 状态

    func setStatus(_ text: String) {
        status.stringValue = text
        sidebarPill.text = text
        if text.contains("失败") || text.contains("未通过") {
            status.textColor = T.red
            sidebarPill.tone = .bad
        } else if text.contains("处理中") || text.contains("正在合并") {
            status.textColor = T.amber
            sidebarPill.tone = .busy
        } else if text.contains("完成") || text.contains("已合并") || text.contains("已加入") || text.contains("就绪") {
            status.textColor = T.sub
            sidebarPill.tone = .ok
        } else {
            status.textColor = T.sub
            sidebarPill.tone = .neutral
        }
    }

    func refreshOutputPath() {
        let path = OutputStore.shared.url.path
        let home = NSHomeDirectory()
        outputPathLabel.stringValue = path.hasPrefix(home)
            ? "~" + String(path.dropFirst(home.count))
            : path
    }

    func refreshDisk() {
        let fm = FileManager.default
        var name = "Macintosh HD"
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]),
           let n = v.volumeName { name = n }
        let attrs = try? fm.attributesOfFileSystem(forPath: NSHomeDirectory())
        let total = (attrs?[.systemSize] as? NSNumber)?.doubleValue ?? 0
        let free = (attrs?[.systemFreeSize] as? NSNumber)?.doubleValue ?? 0
        diskName.stringValue = name
        diskFree.stringValue = String(format: "%.1f GB 可用", free / 1_073_741_824)
        diskBar.fraction = total > 0 ? CGFloat((total - free) / total) : 0
    }

    // MARK: 合并方式

    func applyMergeMode(_ index: Int, persist: Bool = true) {
        let i = min(max(index, 0), 2)
        mergePopup.selectItem(at: i)
        settingsMergePopup.selectItem(at: i)
        if persist { UserDefaults.standard.set(i, forKey: "scanpdf.mergeMode") }
        start.titleText = mergeMode == .separate ? "开始处理" : "开始并合并"
    }

    @objc func mergeModeChanged() {
        applyMergeMode(mergePopup.indexOfSelectedItem)
        mergeHint()
    }
    @objc func settingsMergeChanged() {
        applyMergeMode(settingsMergePopup.indexOfSelectedItem)
        mergeHint()
    }
    func mergeHint() {
        guard !busy else { return }
        switch mergeMode {
        case .separate: setStatus(jobs.isEmpty ? "就绪" : "已加入 \(jobs.count) 个文件")
        case .full: setStatus("完全合并：按队列顺序首尾相接")
        case .duplex: setStatus("间隔合并：每份后补空白页，双面不跨卷")
        }
    }

    // MARK: 窗口生命周期

    func applicationWillTerminate(_ notification: Notification) {
        OutputStore.shared.stopAccessing()
    }

    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil); return true
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" &&
                                 !$0.lastPathComponent.contains("清晰") }
        if !pdfs.isEmpty { enqueue(pdfs) }
    }

    // MARK: 队列

    func secureCopy(_ src: URL) -> URL {
        let fm = FileManager.default
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        let inbox = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClearPaper/Inbox", isDirectory: true)
        try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let dst = inbox.appendingPathComponent("\(UUID().uuidString)-\(src.lastPathComponent)")
        return (try? fm.copyItem(at: src, to: dst)) != nil ? dst : src
    }

    func enqueue(_ urls: [URL]) {
        for u in urls where !jobs.contains(where: { $0.name == u.lastPathComponent }) {
            let j = Job(); j.name = u.lastPathComponent; j.source = secureCopy(u)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: u.path),
               let bytes = attrs[.size] as? Int64 {
                j.detail = bytes > 1_048_576
                    ? String(format: "%.1f MB · 等待处理", Double(bytes) / 1_048_576)
                    : String(format: "%.0f KB · 等待处理", Double(bytes) / 1024)
            }
            jobs.append(j)
        }
        table.reloadData()
        syncQueue()
        start.isEnabled = !busy && !jobs.isEmpty
        setStatus(jobs.isEmpty ? "就绪" : "已加入 \(jobs.count) 个文件")
    }

    func syncQueue() {
        empty.isHidden = !jobs.isEmpty
        countLabel.stringValue = jobs.isEmpty ? "" : "\(jobs.count)"
        processingRow?.badgeText = jobs.isEmpty ? "" : "\(jobs.count)"
    }

    @objc func clearQueue() {
        guard !busy else { return }
        jobs.removeAll()
        table.reloadData()
        syncQueue()
        start.isEnabled = false
        setStatus("就绪")
    }

    @objc func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf]
        panel.prompt = "加入队列"
        if panel.runModal() == .OK { enqueue(panel.urls) }
    }

    @objc func chooseOutput() {
        OutputStore.shared.choose()
        refreshOutputPath()
    }

    @objc func reveal() {
        let url = OutputStore.shared.url
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.open(url)
    }

    @objc func openRepo() {
        if let u = URL(string: "https://github.com/jpruby0127/ClearPaper") {
            NSWorkspace.shared.open(u)
        }
    }

    @objc func openResult() {
        let row = table.clickedRow
        guard row >= 0, row < jobs.count, let out = jobs[row].output,
              FileManager.default.fileExists(atPath: out.path) else { return }
        NSWorkspace.shared.open(out)
    }

    @objc func begin() {
        guard !busy, !jobs.isEmpty else { return }
        let pending = jobs.filter { ["排队中", "失败", "未通过"].contains($0.state) }
        guard !pending.isEmpty else { setStatus("没有待处理的文件"); return }
        run(pending)
    }

    // MARK: 表格

    func numberOfRows(in t: NSTableView) -> Int { jobs.count }

    func tableView(_ t: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: .string)
        return item
    }

    func tableView(_ t: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard !busy else { return [] }
        return op == .above ? .move : []
    }

    func tableView(_ t: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        guard !busy,
              let item = info.draggingPasteboard.pasteboardItems?.first,
              let s = item.string(forType: .string), let from = Int(s),
              from >= 0, from < jobs.count else { return false }
        var to = row
        let job = jobs.remove(at: from)
        if to > from { to -= 1 }
        to = min(max(to, 0), jobs.count)
        jobs.insert(job, at: to)
        t.reloadData()
        setStatus("已调整顺序 · 合并将按新顺序")
        return true
    }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let cell = t.makeView(withIdentifier: id, owner: self) as? RowCell ?? RowCell()
        cell.identifier = id
        let j = jobs[row]
        cell.name.stringValue = j.name
        cell.meta.stringValue = j.detail.isEmpty ? "等待处理" : j.detail
        cell.pill.text = j.state
        switch j.state {
        case "完成":
            cell.pill.tone = T.green
            cell.bar.isHidden = true
        case "失败", "未通过":
            cell.pill.tone = T.red
            cell.bar.isHidden = true
        case "处理中":
            cell.pill.tone = T.amber
            cell.bar.isHidden = false
            cell.bar.startAnimation(nil)
        default:
            cell.pill.tone = T.mute
            cell.bar.isHidden = true
        }
        return cell
    }

    // MARK: 运行

    func run(_ rows: [Job]) {
        let outBase = OutputStore.shared.url
        let mode = mergeMode
        try? FileManager.default.createDirectory(at: outBase, withIntermediateDirectories: true)
        let tasks = rows.compactMap { j -> (Job, URL)? in
            guard let src = j.source, FileManager.default.fileExists(atPath: src.path) else {
                j.state = "失败"; j.detail = "找不到原文件"; return nil
            }
            return (j, src)
        }
        guard !tasks.isEmpty else { table.reloadData(); return }
        rows.forEach { $0.state = "处理中" }
        table.reloadData()
        busy = true
        start.isEnabled = false
        setStatus("处理中… 全部在本机完成，不上传任何文件")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var results: [(Report, URL)] = []
            for (j, src) in tasks {
                let stem = (j.name as NSString).deletingPathExtension
                let dst = outBase.appendingPathComponent(stem + "-清晰版.pdf")
                DispatchQueue.main.async {
                    j.detail = "正在分析页面…"
                    self.table.reloadData()
                }
                let rep = ScanCore.process(src, to: dst) { msg in
                    DispatchQueue.main.async {
                        j.detail = msg
                        self.table.reloadData()
                    }
                }
                results.append((rep, dst))
                let d = rep.decisions
                let retention = Double(d.retention.min() ?? 1)
                DispatchQueue.main.async {
                    j.output = dst
                    if rep.passed && rep.pages > 0 {
                        j.state = "完成"
                        var detail = String(format: "%d 页 A4 · 纸面 %.0f mm · 笔画保留 %.1f%%",
                                            rep.pages, Double(d.sheetWidthMM), retention * 100)
                        if d.showThrough { detail += " · 已去背面透印" }
                        detail += String(format: " · %.1fs", rep.seconds)
                        j.detail = detail
                    } else {
                        j.state = "未通过"
                        j.detail = rep.problems.first ?? "质量闸门未通过"
                    }
                    self.table.reloadData()
                }
            }

            let failures = results.filter { !$0.0.passed || $0.0.pages == 0 }.count
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.table.reloadData()
                NSApp.activate(ignoringOtherApps: true)
                let autoQuit = ProcessInfo.processInfo.environment["SCANPDF_AUTOQUIT"] == "1"

                let finish: (String, URL?) -> Void = { [weak self] message, revealURL in
                    guard let self else { return }
                    self.busy = false
                    self.start.isEnabled = self.jobs.contains {
                        ["排队中", "失败", "未通过"].contains($0.state)
                    }
                    self.setStatus(message)
                    self.syncQueue()
                    self.refreshDisk()
                    if let u = revealURL {
                        NSWorkspace.shared.activateFileViewerSelecting([u])
                    } else if failures == 0 && !autoQuit {
                        self.reveal()
                    }
                    if autoQuit {
                        for (r, u) in results {
                            let ret = r.decisions.retention
                                .map { String(format: "%.1f", $0 * 100) }.joined(separator: ",")
                            print("RESULT pages=\(r.pages) passed=\(r.passed) "
                                + "showThrough=\(r.decisions.showThrough) retention=[\(ret)] "
                                + "problems=\(r.problems) out=\(u.path)")
                        }
                        NSApp.terminate(nil)
                    }
                }

                let ordered = self.jobs.compactMap { $0.output }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }

                if mode != .separate, ordered.count >= 2 {
                    self.setStatus("正在合并 \(ordered.count) 份…")
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        guard let self else { return }
                        let df = DateFormatter()
                        df.locale = Locale(identifier: "en_US_POSIX")
                        df.dateFormat = "yyyyMMdd-HHmmss"
                        let out = outBase.appendingPathComponent(
                            "合并清晰版-\(df.string(from: Date())).pdf")
                        let pages = mergePDFs(ordered, mode: mode, to: out)
                        DispatchQueue.main.async {
                            if pages > 0 {
                                let extra = failures == 0 ? "" : "（跳过 \(failures) 份未通过）"
                                finish("已合并 \(ordered.count) 份 · \(pages) 页\(extra)", out)
                            } else {
                                self.busy = false
                                self.start.isEnabled = true
                                self.setStatus("合并失败")
                                presentError("合并 PDF 失败，请检查文件是否有效。")
                                if autoQuit { NSApp.terminate(nil) }
                            }
                        }
                    }
                } else if mode != .separate, ordered.count == 1 {
                    finish("仅 1 份，已单独保存（未合并）", nil)
                } else {
                    finish(failures == 0
                        ? "完成 · 结果在输出文件夹"
                        : "有 \(failures) 项未通过质量闸门", nil)
                }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
