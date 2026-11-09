import AppKit
import UniformTypeIdentifiers

// 试卷扫描清晰化 · macOS 原生版
// 清理引擎（ios/Core.swift 的 ScanCore）直接编译进本包，桌面端零依赖、全离线。
// 输出目录默认在沙盒 Documents/试卷清晰版；用户可在「文件」菜单里改到任意文件夹
// （通过安全作用域书签持久化），因此本 app 完全符合 Mac App Store 沙盒要求。

// MARK: - 输出目录（沙盒安全）

final class OutputStore {
    static let shared = OutputStore()
    private(set) var url: URL
    private var scoped = false
    private let key = "scanpdf.outputBookmark"

    init() {
        let fm = FileManager.default
        // 自动化 / 高级用户可用 SCANPDF_OUTDIR 覆盖输出目录（不持久化）。
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

    /// 让用户挑一个真实文件夹（NSOpenPanel → 安全作用域书签），写入即可被沙盒放行。
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

// MARK: - 小组件

/// 圆角状态药丸，与系统工具类 app 的配色一致。
final class Pill: NSView {
    private let label = NSTextField(labelWithString: "")
    var text = "" { didSet { label.stringValue = text; invalidateIntrinsicContentSize() } }
    var tone: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 64),
            heightAnchor.constraint(equalToConstant: 20),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        layer?.cornerRadius = 10
        layer?.backgroundColor = tone.withAlphaComponent(0.16).cgColor
        label.textColor = tone
    }
}

final class RowCell: NSTableCellView {
    let badge = NSImageView()
    let name = NSTextField(labelWithString: "")
    let meta = NSTextField(labelWithString: "")
    let pill = Pill()
    let bar = NSProgressIndicator()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10

        badge.image = NSImage(systemSymbolName: "doc.text.fill", accessibilityDescription: nil)
        badge.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        badge.contentTintColor = .white
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 7
        badge.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor

        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        meta.font = .systemFont(ofSize: 11)
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingTail

        bar.style = .bar
        bar.controlSize = .small
        bar.isIndeterminate = true
        bar.isHidden = true

        for v in [badge, name, meta, pill, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -4),
            badge.widthAnchor.constraint(equalToConstant: 30),
            badge.heightAnchor.constraint(equalToConstant: 30),
            name.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: pill.leadingAnchor, constant: -10),
            name.topAnchor.constraint(equalTo: badge.topAnchor, constant: 1),
            meta.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            meta.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            meta.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            pill.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            bar.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            bar.topAnchor.constraint(equalTo: meta.bottomAnchor, constant: 5),
            bar.heightAnchor.constraint(equalToConstant: 4),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.045).cgColor
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
    }
}

// MARK: - 拖拽区

final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?
    var onPick: (() -> Void)?
    var hover = false { didSet { needsDisplay = true } }
    private let glyph = NSImageView()
    private let title = NSTextField(labelWithString: "把 PDF 拖到这里")
    private let hint = NSTextField(labelWithString: "扫描或拍照的试卷 · 支持一次多个")
    private let pick = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        layer?.cornerRadius = 20

        glyph.image = NSImage(systemSymbolName: "arrow.down.doc.fill", accessibilityDescription: nil)
        glyph.symbolConfiguration = .init(pointSize: 32, weight: .semibold)
        glyph.contentTintColor = .white
        glyph.imageScaling = .scaleProportionallyDown
        glyph.wantsLayer = true
        glyph.layer?.cornerRadius = 16
        glyph.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        pick.title = "选择文件…"
        pick.bezelStyle = .rounded
        pick.target = self
        pick.action = #selector(pickFiles)

        for v in [glyph, title, hint, pick] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            glyph.widthAnchor.constraint(equalToConstant: 64),
            glyph.heightAnchor.constraint(equalToConstant: 64),
            title.centerXAnchor.constraint(equalTo: centerXAnchor),
            title.topAnchor.constraint(equalTo: glyph.bottomAnchor, constant: 12),
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            pick.centerXAnchor.constraint(equalTo: centerXAnchor),
            pick.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 14),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pickFiles() { onPick?() }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(hover ? 0.16 : 0.07).cgColor
        layer?.borderWidth = hover ? 2 : 1
        layer?.borderColor = NSColor.controlAccentColor
            .withAlphaComponent(hover ? 0.9 : 0.25).cgColor
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

// MARK: - 队列模型

final class Job: NSObject {
    @objc var name = ""
    @objc var state = "排队中"
    @objc var detail = ""
    var source: URL?
    var output: URL?
}

// MARK: - 关于 / 帮助窗口

func presentAbout() {
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 280),
                       styleMask: [.titled, .closable],
                       backing: .buffered, defer: false)
    win.title = "关于 试卷扫描清晰化"
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

    let name = NSTextField(labelWithString: "试卷扫描清晰化")
    name.font = .systemFont(ofSize: 20, weight: .bold)
    let ver = NSTextField(labelWithString:
        "版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")"
        + "（\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")）")
    ver.font = .systemFont(ofSize: 11)
    ver.textColor = .secondaryLabelColor
    let desc = NSTextField(labelWithString:
        "把扫描 / 拍照的试卷，转成可直接打印的 A4 清晰版。")
    desc.font = .systemFont(ofSize: 12)
    desc.textColor = .secondaryLabelColor
    desc.lineBreakMode = .byWordWrapping
    let copy = NSTextField(labelWithString: "全离线运行 · 不上传任何文件 · 数据只在本机")
    copy.font = .systemFont(ofSize: 11)
    copy.textColor = .tertiaryLabelColor

    for v in [icon, name, ver, desc, copy] {
        v.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(v)
    }
    NSLayoutConstraint.activate([
        icon.topAnchor.constraint(equalTo: box.topAnchor, constant: 28),
        icon.centerXAnchor.constraint(equalTo: box.centerXAnchor),
        icon.widthAnchor.constraint(equalToConstant: 80),
        icon.heightAnchor.constraint(equalToConstant: 80),
        name.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 16),
        name.centerXAnchor.constraint(equalTo: box.centerXAnchor),
        ver.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 4),
        ver.centerXAnchor.constraint(equalTo: box.centerXAnchor),
        desc.topAnchor.constraint(equalTo: ver.bottomAnchor, constant: 14),
        desc.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 36),
        desc.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -36),
        copy.topAnchor.constraint(equalTo: desc.bottomAnchor, constant: 6),
        copy.centerXAnchor.constraint(equalTo: box.centerXAnchor),
    ])
    win.center()
    win.makeKeyAndOrderFront(nil)
}

func presentHelp() {
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
                       styleMask: [.titled, .closable],
                       backing: .buffered, defer: false)
    win.title = "使用帮助"
    win.isReleasedWhenClosed = false
    let scroll = NSScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    let text = NSTextView()
    text.isEditable = false
    text.isSelectable = true
    text.font = .systemFont(ofSize: 13)
    text.textContainerInset = NSSize(width: 18, height: 18)
    text.string = """
欢迎使用「试卷扫描清晰化」

它能把老师发的扫描版 / 拍照版试卷，自动裁掉黑边、扶正、增强文字，输出成标准 A4、可直接打印的清晰 PDF。全部在你自己的电脑上完成，不上传任何文件。

使用方法
1. 把一份或多份试卷 PDF 拖进主窗口，或点「选择文件…」。
2. 点击「开始处理」。处理进度会逐行显示。
3. 完成后点「输出文件夹」打开结果所在的文件夹。

输出去哪了？
• 默认保存在 文稿 › 试卷清晰版。
• 想改到别处（例如 桌面 或 U 盘），在顶部菜单「文件 › 选择输出文件夹…」里挑一个即可，下次自动记住。

打印小贴士
打印时选 A4、缩放「实际大小 / 100%」，不要选「适合页面」，效果最准。

支持
• 一次拖入多份 PDF，会按顺序全部处理。
• 双击已完成的一行，可直接打开对应的清晰版 PDF。
• 把 PDF 直接拖到 Dock 上的 app 图标也能加入队列。
"""
    scroll.documentView = text
    win.contentView = scroll
    NSLayoutConstraint.activate([
        scroll.topAnchor.constraint(equalTo: win.contentView!.topAnchor),
        scroll.leadingAnchor.constraint(equalTo: win.contentView!.leadingAnchor),
        scroll.trailingAnchor.constraint(equalTo: win.contentView!.trailingAnchor),
        scroll.bottomAnchor.constraint(equalTo: win.contentView!.bottomAnchor),
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
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 660),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
    let drop = DropView(frame: .zero)
    let table = NSTableView()
    let empty = NSView()
    let status = NSTextField(labelWithString: "全离线 · 拖入 PDF 即可")
    let start = NSButton()
    let openBtn = NSButton()
    var jobs: [Job] = []
    var busy = false
    var queueMinH: NSLayoutConstraint!
    var flex: NSView!
    var queueBox: NSView!

    // MARK: 菜单栏

    func buildMenu() {
        let main = NSMenu()
        let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "App"

        let appMenu = NSMenu(title: appName)
        let aboutItem = NSMenuItem(title: "关于 \(appName)", action: #selector(about), keyEquivalent: "")
        let quit = NSMenuItem(title: "退出 \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(aboutItem)
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
        appMenu.addItem(quit)
        let appItem = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let file = NSMenu(title: "文件")
        let open = NSMenuItem(title: "打开 PDF…", action: #selector(pick), keyEquivalent: "o")
        let chooseOut = NSMenuItem(title: "选择输出文件夹…", action: #selector(chooseOutput), keyEquivalent: "")
        let openOut = NSMenuItem(title: "打开输出文件夹", action: #selector(reveal), keyEquivalent: "")
        file.addItem(open)
        file.addItem(chooseOut)
        file.addItem(openOut)
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
        help.addItem(NSMenuItem(title: "使用帮助", action: #selector(showHelp), keyEquivalent: ""))
        help.addItem(NSMenuItem(title: "关于", action: #selector(about), keyEquivalent: ""))
        let helpItem = NSMenuItem(title: "帮助", action: nil, keyEquivalent: "")
        helpItem.submenu = help
        main.addItem(helpItem)

        NSApp.mainMenu = main
    }

    @objc func about() { presentAbout() }
    @objc func showHelp() { presentHelp() }

    // MARK: 启动

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()

        window.title = "试卷扫描清晰化"
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.backgroundColor = .windowBackgroundColor
        window.minSize = NSSize(width: 460, height: 560)
        window.center()

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 26, left: 20, bottom: 18, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        let head = NSStackView()
        head.orientation = .horizontal
        head.spacing = 12
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        if let url = Bundle.main.url(forResource: "Icon", withExtension: "icns"),
           let art = NSImage(contentsOf: url) {
            icon.image = art
        } else {
            icon.image = NSImage(systemSymbolName: "doc.text.magnifyingglass",
                                 accessibilityDescription: nil)
            icon.symbolConfiguration = .init(pointSize: 26, weight: .semibold)
            icon.contentTintColor = .controlAccentColor
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 9
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
        ])
        let titles = NSStackView()
        titles.orientation = .vertical
        titles.spacing = 2
        titles.alignment = .leading
        let t1 = NSTextField(labelWithString: "试卷扫描清晰化")
        t1.font = .systemFont(ofSize: 16, weight: .bold)
        let t2 = NSTextField(labelWithString: "扫描 / 拍照的试卷 → 可直接打印的 A4 清晰版 · 全离线")
        t2.font = .systemFont(ofSize: 11.5)
        t2.textColor = .secondaryLabelColor
        titles.addArrangedSubview(t1); titles.addArrangedSubview(t2)

        // 设置（选择输出文件夹）齿轮按钮
        let gear = NSButton()
        gear.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置")
        gear.imageScaling = .scaleProportionallyDown
        gear.bezelStyle = .regularSquare
        gear.isBordered = false
        gear.contentTintColor = .secondaryLabelColor
        gear.target = self
        gear.action = #selector(chooseOutput)
        gear.toolTip = "选择输出文件夹"

        head.addArrangedSubview(icon)
        head.addArrangedSubview(titles)
        head.addArrangedSubview(gear)
        head.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titles.setContentHuggingPriority(.defaultLow, for: .horizontal)
        gear.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        drop.heightAnchor.constraint(equalToConstant: 190).isActive = true
        drop.onDrop = { [weak self] in self?.enqueue($0) }
        drop.onPick = { [weak self] in self?.pick() }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        table.style = .plain
        table.rowHeight = 58
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 8)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openResult)
        table.addTableColumn(NSTableColumn(identifier: .init("row")))
        scroll.documentView = table

        let emptyGlyph = NSImageView()
        emptyGlyph.image = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)
        emptyGlyph.symbolConfiguration = .init(pointSize: 28, weight: .light)
        emptyGlyph.contentTintColor = .tertiaryLabelColor
        let emptyText = NSTextField(labelWithString: "还没有文件\n拖入或选择 PDF 后点「开始处理」")
        emptyText.font = .systemFont(ofSize: 12)
        emptyText.textColor = .tertiaryLabelColor
        emptyText.alignment = .center
        empty.wantsLayer = true
        empty.layer?.cornerRadius = 14
        empty.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.03).cgColor
        empty.layer?.borderWidth = 1
        empty.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        empty.addSubview(emptyGlyph); empty.addSubview(emptyText)
        emptyGlyph.translatesAutoresizingMaskIntoConstraints = false
        emptyText.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyGlyph.centerXAnchor.constraint(equalTo: empty.centerXAnchor),
            emptyGlyph.centerYAnchor.constraint(equalTo: empty.centerYAnchor, constant: -22),
            emptyText.centerXAnchor.constraint(equalTo: empty.centerXAnchor),
            emptyText.topAnchor.constraint(equalTo: emptyGlyph.bottomAnchor, constant: 8),
        ])

        queueBox = NSView()
        queueBox.translatesAutoresizingMaskIntoConstraints = false
        flex = NSView()
        flex.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        empty.translatesAutoresizingMaskIntoConstraints = false
        queueBox.addSubview(scroll); queueBox.addSubview(empty)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: queueBox.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: queueBox.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: queueBox.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: queueBox.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: queueBox.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: queueBox.centerYAnchor),
            empty.widthAnchor.constraint(equalToConstant: 300),
            empty.heightAnchor.constraint(equalToConstant: 150),
        ])
        queueMinH = queueBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)
        queueMinH.isActive = true
        queueBox.setContentHuggingPriority(.defaultHigh, for: .vertical)
        flex.setContentHuggingPriority(.defaultLow, for: .vertical)
        syncQueue()

        let foot = NSStackView()
        foot.orientation = .horizontal
        foot.spacing = 10
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        openBtn.title = "输出文件夹"
        openBtn.bezelStyle = .rounded
        openBtn.target = self
        openBtn.action = #selector(reveal)
        start.title = "开始处理"
        start.bezelStyle = .rounded
        start.keyEquivalent = "\r"
        start.target = self
        start.action = #selector(begin)
        start.isEnabled = false
        foot.addArrangedSubview(status)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        foot.addArrangedSubview(spacer)
        foot.addArrangedSubview(openBtn)
        foot.addArrangedSubview(start)

        root.addArrangedSubview(head)
        root.addArrangedSubview(drop)
        root.addArrangedSubview(queueBox)
        root.addArrangedSubview(flex)
        root.addArrangedSubview(foot)

        window.contentView = root
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 命令行入口：拖 PDF 路径进来即可排队，SCANPDF_AUTORUN=1 立即处理。
        // 同一段代码也是按钮走的路径，顺带当自动化测试用。
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

    /// 沙盒下，拖入 / 打开的 PDF 在处理时可能已失去访问权。入队时立刻把源文件
    /// 拷进 App 自己的 Inbox（沙盒内始终可写），之后只处理这份副本，绝不丢文件。
    func secureCopy(_ src: URL) -> URL {
        let fm = FileManager.default
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        let inbox = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("试卷扫描清晰化/Inbox", isDirectory: true)
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
        status.stringValue = jobs.isEmpty ? "就绪" : "已加入 \(jobs.count) 个文件"
    }

    func syncQueue() {
        empty.isHidden = !jobs.isEmpty
        queueMinH.constant = jobs.isEmpty ? 150 : 220
        queueBox.setContentHuggingPriority(jobs.isEmpty ? .defaultHigh : .defaultLow,
                                            for: .vertical)
        flex.setContentHuggingPriority(jobs.isEmpty ? .defaultLow : .defaultHigh,
                                       for: .vertical)
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

    @objc func chooseOutput() { OutputStore.shared.choose() }

    @objc func reveal() {
        let url = OutputStore.shared.url
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.open(url)
    }

    @objc func openResult() {
        let row = table.clickedRow
        guard row >= 0, row < jobs.count, let out = jobs[row].output,
              FileManager.default.fileExists(atPath: out.path) else { return }
        NSWorkspace.shared.open(out)
    }

    @objc func begin() {
        guard !busy, !jobs.isEmpty else { return }
        let pending = jobs.filter { $0.state == "排队中" || $0.state == "失败" }
        guard !pending.isEmpty else { return }
        run(pending)
    }

    // MARK: 表格

    func numberOfRows(in t: NSTableView) -> Int { jobs.count }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let cell = t.makeView(withIdentifier: id, owner: self) as? RowCell ?? RowCell()
        cell.identifier = id
        let j = jobs[row]
        cell.name.stringValue = j.name
        cell.meta.stringValue = j.detail.isEmpty ? "等待处理" : j.detail
        cell.pill.text = j.state
        switch j.state {
        case "完成": cell.pill.tone = .systemGreen; cell.bar.isHidden = true
        case "失败", "未通过": cell.pill.tone = .systemRed; cell.bar.isHidden = true
        case "处理中": cell.pill.tone = .controlAccentColor; cell.bar.isHidden = false
                     cell.bar.startAnimation(nil)
        default: cell.pill.tone = .secondaryLabelColor; cell.bar.isHidden = true
        }
        return cell
    }

    // MARK: 运行

    func run(_ rows: [Job]) {
        let outBase = OutputStore.shared.url
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
        status.stringValue = "处理中… 全部在本机完成，不上传任何文件"

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
                        j.detail = String(format: "%d 页 A4 · 纸面 %.0f mm · 笔画保留 %.1f%% · %.1fs",
                                          rep.pages, Double(d.sheetWidthMM), retention * 100,
                                          rep.seconds)
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
                self.busy = false
                self.table.reloadData()
                self.start.isEnabled = self.jobs.contains {
                    $0.state == "排队中" || $0.state == "失败" || $0.state == "未通过"
                }
                self.status.stringValue = failures == 0
                    ? "完成 · 结果在 文稿/试卷清晰版"
                    : "有 \(failures) 项未通过质量闸门"
                NSApp.activate(ignoringOtherApps: true)
                let autoQuit = ProcessInfo.processInfo.environment["SCANPDF_AUTOQUIT"] == "1"
                if failures == 0 && !autoQuit { self.reveal() }
                if autoQuit { NSApp.terminate(nil) }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
