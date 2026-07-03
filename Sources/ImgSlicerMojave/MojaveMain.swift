import AppKit
import Foundation
import ImageIO

// AppKit port of the modern SwiftUI shell (AppShell.swift) for macOS 10.14:
// top brand bar, folder-task queue on the left, editable crop canvas in the
// middle, parameter panel on the right, filmstrip at the bottom. Interactions
// mirror the modern app; state and pipeline calls live in MojaveStore.

// MARK: - Theme (mirrors AppTheme in AppShell.swift)

enum MojaveTheme {
    static let text = NSColor(srgbRed: 0.93, green: 0.95, blue: 0.97, alpha: 1)
    static let muted = NSColor(srgbRed: 0.59, green: 0.63, blue: 0.69, alpha: 1)
    static let blue = NSColor(srgbRed: 0.37, green: 0.53, blue: 0.72, alpha: 1)
    static let green = NSColor(srgbRed: 0.31, green: 0.65, blue: 0.55, alpha: 1)
    static let orange = NSColor(srgbRed: 0.9, green: 0.55, blue: 0.26, alpha: 1)
    static let cropSelected = NSColor(srgbRed: 0.90, green: 1.00, blue: 0.22, alpha: 1)
    static let cropFrameColors: [NSColor] = [
        NSColor(srgbRed: 0.18, green: 0.96, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.42, green: 1.00, blue: 0.32, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.34, blue: 0.92, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.86, blue: 0.18, alpha: 1),
        NSColor(srgbRed: 0.42, green: 0.62, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.46, blue: 0.20, alpha: 1),
    ]
    static let line = NSColor(white: 1, alpha: 0.08)
    static let background = NSColor(srgbRed: 0.09, green: 0.10, blue: 0.12, alpha: 1)
    static let panel = NSColor(srgbRed: 0.078, green: 0.087, blue: 0.105, alpha: 1)
    static let rowIdle = NSColor(srgbRed: 0.115, green: 0.13, blue: 0.155, alpha: 1)
    static let viewer = NSColor(srgbRed: 0.075, green: 0.085, blue: 0.105, alpha: 1)
    static let topBar = NSColor(srgbRed: 0.095, green: 0.105, blue: 0.125, alpha: 0.96)

    static func statusColor(_ status: TaskStatus) -> NSColor {
        switch status {
        case .waiting: return NSColor(srgbRed: 0.82, green: 0.68, blue: 0.47, alpha: 1)
        case .running: return NSColor(srgbRed: 0.72, green: 0.79, blue: 0.86, alpha: 1)
        case .needsReview: return NSColor(srgbRed: 0.86, green: 0.68, blue: 0.43, alpha: 1)
        case .done: return green
        }
    }
}

// MARK: - Async downsampled image loading (stands in for DownsampledImageView)

final class MojaveImageLoader {
    static let shared = MojaveImageLoader()
    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "imgslicer.mojave.thumbs", qos: .userInitiated, attributes: .concurrent)

    func cached(url: URL, maxPixel: Int) -> NSImage? {
        cache.object(forKey: key(url: url, maxPixel: maxPixel))
    }

    func load(url: URL, maxPixel: Int, completion: @escaping (NSImage?) -> Void) {
        let cacheKey = key(url: url, maxPixel: maxPixel)
        if let hit = cache.object(forKey: cacheKey) {
            completion(hit)
            return
        }
        queue.async { [cache] in
            var image: NSImage?
            if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                    kCGImageSourceShouldCacheImmediately: true,
                ]
                if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                }
            }
            if let image {
                cache.setObject(image, forKey: cacheKey)
            }
            DispatchQueue.main.async { completion(image) }
        }
    }

    private func key(url: URL, maxPixel: Int) -> NSString {
        "\(url.path)#\(maxPixel)" as NSString
    }
}

// MARK: - App bootstrap

@main
enum ImgSlicerMojaveMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = MojaveAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

final class MojaveAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MojaveWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        controller = MojaveWindowController()
        controller?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller?.runStartupArguments()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: "退出 ImgSlicer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        NSApp.mainMenu = mainMenu
    }
}

// MARK: - Window controller

final class MojaveWindowController: NSWindowController, NSWindowDelegate {
    let store = MojaveStore()

    private let queuePanel = QueuePanelView()
    private let previewPanel = PreviewPanelView()
    private let parameterPanel = ParameterPanelView()
    private let filmstrip = FilmstripView()
    private var keyMonitor: Any?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ImgSlicer"
        window.minSize = NSSize(width: 1080, height: 680)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = MojaveTheme.background
        super.init(window: window)
        window.delegate = self
        window.center()
        buildUI()
        wireStore()
        installKeyMonitor()
        refresh()
        // Focus starts on the canvas, not the first margin field — otherwise
        // the Space shortcut (框选新增) types a space into the field instead.
        window.initialFirstResponder = previewPanel.canvas
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    // MARK: Layout

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = MojaveTheme.background.cgColor

        let topBar = TopBarView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(topBar)

        queuePanel.translatesAutoresizingMaskIntoConstraints = false
        previewPanel.translatesAutoresizingMaskIntoConstraints = false
        parameterPanel.translatesAutoresizingMaskIntoConstraints = false
        filmstrip.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(queuePanel)
        content.addSubview(previewPanel)
        content.addSubview(parameterPanel)
        content.addSubview(filmstrip)

        // Sidebars follow the window like the SwiftUI layout: 15% of the width
        // but never narrower than 220pt.
        let queueWidth = queuePanel.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.15)
        queueWidth.priority = .defaultHigh
        let parameterWidth = parameterPanel.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.15)
        parameterWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: content.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 54),

            queuePanel.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8),
            queuePanel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            queuePanel.bottomAnchor.constraint(equalTo: filmstrip.topAnchor, constant: -8),
            queueWidth,
            queuePanel.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),

            previewPanel.topAnchor.constraint(equalTo: queuePanel.topAnchor),
            previewPanel.leadingAnchor.constraint(equalTo: queuePanel.trailingAnchor, constant: 10),
            previewPanel.bottomAnchor.constraint(equalTo: queuePanel.bottomAnchor),

            parameterPanel.topAnchor.constraint(equalTo: queuePanel.topAnchor),
            parameterPanel.leadingAnchor.constraint(equalTo: previewPanel.trailingAnchor, constant: 10),
            parameterPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            parameterPanel.bottomAnchor.constraint(equalTo: queuePanel.bottomAnchor),
            parameterWidth,
            parameterPanel.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),

            filmstrip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            filmstrip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            filmstrip.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            filmstrip.heightAnchor.constraint(equalToConstant: 132),
        ])

        // Drag & drop import anywhere in the window.
        content.registerForDraggedTypes([.fileURL])
        if let dropView = content as? NSView & NSDraggingDestination {
            _ = dropView
        }
        let dropTarget = DropCatcherView()
        dropTarget.translatesAutoresizingMaskIntoConstraints = false
        dropTarget.onDrop = { [weak self] urls in self?.store.importItems(urls) }
        content.addSubview(dropTarget, positioned: .below, relativeTo: queuePanel)
        NSLayoutConstraint.activate([
            dropTarget.topAnchor.constraint(equalTo: content.topAnchor),
            dropTarget.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            dropTarget.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            dropTarget.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    // MARK: Store wiring

    private func wireStore() {
        store.onChange = { [weak self] in self?.refresh() }
        store.onManualRedetectPrompt = { [weak self] prompt in self?.presentManualRedetectPrompt(prompt) }
        store.onStartProcessingPrompt = { [weak self] prompt in self?.presentStartProcessingPrompt(prompt) }

        queuePanel.onImport = { [weak self] in self?.store.pickFiles() }
        queuePanel.onClear = { [weak self] in self?.store.clearFinishedAndIdle() }
        queuePanel.onSelectTask = { [weak self] taskID in self?.store.selectTask(taskID) }
        queuePanel.onOpenFolder = { [weak self] taskID in self?.store.openFolder(for: taskID) }

        previewPanel.canvas.onSelectRegion = { [weak self] regionID in self?.store.selectCropRegion(regionID) }
        previewPanel.canvas.onDeleteRegion = { [weak self] regionID in self?.store.deleteSelectedCrop(regionID: regionID) }
        previewPanel.canvas.onChangeRegion = { [weak self] regionID, rect in self?.store.updateSelectedCrop(regionID: regionID, rect: rect) }
        previewPanel.canvas.onDrawNewRegion = { [weak self] rect in self?.store.addCropRegion(rect: rect) }

        parameterPanel.onMarginsChanged = { [weak self] top, bottom, left, right in
            guard let self else { return }
            // Extra inward shrink in original-image pixels, on top of the
            // fixed baseline inset; applies to newly located photos and
            // re-bakes the current task's auto boxes immediately.
            self.store.settings.insetTopPixels = top
            self.store.settings.insetBottomPixels = bottom
            self.store.settings.insetLeftPixels = left
            self.store.settings.insetRightPixels = right
            self.store.reapplySelectedCandidateMargins()
        }
        parameterPanel.onToggleDraw = { [weak self] in self?.store.toggleDrawNewRegion() }
        parameterPanel.onRedetect = { [weak self] in self?.store.redetectSelectedPhoto() }
        parameterPanel.onSmartRedetect = { [weak self] in self?.store.smartRedetectSelectedPhoto() }
        parameterPanel.onApplyCandidate = { [weak self] candidateID in self?.store.applySelectedCandidate(candidateID) }
        parameterPanel.onMoveAll = { [weak self] dx, dy in self?.store.moveAllCropRegions(dxPixels: dx, dyPixels: dy) }
        parameterPanel.onRotate = { [weak self] delta in
            guard let self, let region = self.store.selectedCropRegion else { return }
            let next = min(max(region.angle + delta, -15), 15)
            self.store.updateSelectedCropAngle(regionID: region.id, angle: next)
        }
        parameterPanel.onStartProcessing = { [weak self] in self?.store.startProcessing() }

        filmstrip.onSelectPhoto = { [weak self] photoID in self?.store.selectPhoto(photoID) }
        filmstrip.onPrevious = { [weak self] in self?.store.selectPreviousPhoto() }
        filmstrip.onNext = { [weak self] in self?.store.selectNextPhoto() }
    }

    // MARK: Refresh

    func refresh() {
        queuePanel.render(tasks: store.tasks, selectedTaskID: store.selectedTask?.id)
        previewPanel.render(store: store)
        parameterPanel.render(store: store)
        filmstrip.render(store: store)
    }

    // MARK: Keyboard (mirrors keyboardShortcutSinks + onMoveCommand)

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            // Let text editing (margin fields) keep its keystrokes.
            if let responder = self.window?.firstResponder, responder is NSTextView { return event }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let hasCommand = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 123: // left
            if store.selectedCropRegionID != nil { store.moveSelectedCropRegion(dxPixels: -1, dyPixels: 0) } else { store.selectPreviousPhoto() }
            return true
        case 124: // right
            if store.selectedCropRegionID != nil { store.moveSelectedCropRegion(dxPixels: 1, dyPixels: 0) } else { store.selectNextPhoto() }
            return true
        case 126: // up
            if store.selectedCropRegionID != nil { store.moveSelectedCropRegion(dxPixels: 0, dyPixels: -1); return true }
            return false
        case 125: // down
            if store.selectedCropRegionID != nil { store.moveSelectedCropRegion(dxPixels: 0, dyPixels: 1); return true }
            return false
        case 51, 117: // delete / forward delete
            return store.deleteSelectedCropRegion()
        case 53: // esc
            if store.isDrawingNewRegion { store.cancelDrawNewRegion(); return true }
            return false
        case 49: // space
            if store.selectedPhoto != nil { store.toggleDrawNewRegion(); return true }
            return false
        case 8 where hasCommand: // cmd+c
            if store.selectedPhoto != nil { store.copySelectedOriginalToPasteboard(); return true }
            return false
        default:
            return false
        }
    }

    // MARK: Alerts

    private func presentManualRedetectPrompt(_ prompt: MojaveManualRedetectPrompt) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "该图片有手动修正"
        alert.informativeText = "「\(prompt.photoName)」已被手动调整。\(prompt.message)"
        alert.addButton(withTitle: prompt.actionTitle)
        alert.addButton(withTitle: "保留手动修正")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { prompt.action() }
        }
    }

    private func presentStartProcessingPrompt(_ prompt: MojaveStartProcessingPrompt) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        if prompt.canStart {
            alert.addButton(withTitle: "开始处理 \(prompt.waitingCount) 个任务")
            alert.addButton(withTitle: "取消")
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.store.confirmStartProcessing() }
            }
        } else {
            alert.addButton(withTitle: "知道了")
            alert.beginSheetModal(for: window) { _ in }
        }
    }

    // MARK: Scripted smoke driving

    /// `--auto-import <path>` mirrors the 导入 button; add `--auto-process` to
    /// run the whole 开始处理 queue without the confirmation sheet.
    func runStartupArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "--auto-import"), args.indices.contains(flag + 1) else { return }
        store.importItems([URL(fileURLWithPath: args[flag + 1])])
        if args.contains("--auto-process") {
            store.confirmStartProcessing()
        }
    }
}

// MARK: - Drag & drop catcher

final class DropCatcherView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

// MARK: - Shared small views

/// Rounded dark panel container matching the SwiftUI `panelStyle()`.
class PanelBoxView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = MojaveTheme.panel.cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.06).cgColor
    }

    required init?(coder: NSCoder) { nil }
}

func mojaveLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = MojaveTheme.text) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = NSFont.systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.translatesAutoresizingMaskIntoConstraints = false
    label.lineBreakMode = .byTruncatingTail
    return label
}

func mojaveActionButton(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
    let button = NSButton(title: title, target: target, action: action)
    button.bezelStyle = .rounded
    button.controlSize = .small
    button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
    button.translatesAutoresizingMaskIntoConstraints = false
    return button
}

// MARK: - Top bar

final class TopBarView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = MojaveTheme.topBar.cgColor

        let logo = NSView()
        logo.wantsLayer = true
        logo.layer?.backgroundColor = MojaveTheme.orange.cgColor
        logo.layer?.cornerRadius = 6
        logo.translatesAutoresizingMaskIntoConstraints = false
        addSubview(logo)

        let title = mojaveLabel("ImgSlicer", size: 14, weight: .semibold)
        addSubview(title)

        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = MojaveTheme.line.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)

        NSLayoutConstraint.activate([
            logo.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            logo.centerYAnchor.constraint(equalTo: centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 26),
            logo.heightAnchor.constraint(equalToConstant: 26),
            title.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: logo.centerYAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

// MARK: - Queue panel (任务列表)

final class QueuePanelView: PanelBoxView {
    var onImport: (() -> Void)?
    var onClear: (() -> Void)?
    var onSelectTask: ((FolderTask.ID) -> Void)?
    var onOpenFolder: ((FolderTask.ID) -> Void)?

    private let rowsStack = NSStackView()
    private let emptyLabel = mojaveLabel("拖入文件夹或点击 + 导入", size: 12, color: MojaveTheme.muted)
    private var renderedSignature: String = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let title = mojaveLabel("任务列表", size: 13, weight: .semibold)
        addSubview(title)

        let importButton = mojaveActionButton("＋ 导入", target: self, action: #selector(importTapped))
        importButton.toolTip = "追加导入图片或文件夹"
        addSubview(importButton)

        let clearButton = mojaveActionButton("清理", target: self, action: #selector(clearTapped))
        clearButton.toolTip = "清理所有任务（处理中的除外）"
        addSubview(clearButton)

        let headerLine = NSView()
        headerLine.wantsLayer = true
        headerLine.layer?.backgroundColor = MojaveTheme.line.cgColor
        headerLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerLine)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        rowsStack.orientation = .vertical
        rowsStack.spacing = 10
        rowsStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let clip = FlippedClipDocumentView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(rowsStack)
        scroll.documentView = clip

        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 13),

            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            clearButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            importButton.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -6),
            importButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            headerLine.topAnchor.constraint(equalTo: topAnchor, constant: 42),
            headerLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerLine.heightAnchor.constraint(equalToConstant: 1),

            scroll.topAnchor.constraint(equalTo: headerLine.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            clip.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            rowsStack.topAnchor.constraint(equalTo: clip.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: clip.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: topAnchor, constant: 84),
        ])
    }

    required init?(coder: NSCoder) { nil }

    @objc private func importTapped() { onImport?() }
    @objc private func clearTapped() { onClear?() }

    func render(tasks: [FolderTask], selectedTaskID: FolderTask.ID?) {
        emptyLabel.isHidden = !tasks.isEmpty
        let signature = tasks.map { "\($0.id)|\($0.status.rawValue)|\($0.detail)|\($0.processedCount)|\($0.id == selectedTaskID)" }.joined(separator: "#")
        guard signature != renderedSignature else { return }
        renderedSignature = signature

        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for task in tasks {
            let row = TaskRowView(task: task, active: task.id == selectedTaskID)
            row.onSelect = { [weak self] in self?.onSelectTask?(task.id) }
            row.onOpenFolder = { [weak self] in self?.onOpenFolder?(task.id) }
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor, constant: -24).isActive = true
        }
    }
}

/// Top-anchored document view so stacked task rows grow downward.
final class FlippedClipDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class TaskRowView: NSView {
    var onSelect: (() -> Void)?
    var onOpenFolder: (() -> Void)?

    init(task: FolderTask, active: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = active
            ? MojaveTheme.orange.withAlphaComponent(0.16).cgColor
            : MojaveTheme.rowIdle.cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = active ? 2 : 1
        layer?.borderColor = active ? MojaveTheme.orange.cgColor : NSColor(white: 1, alpha: 0.05).cgColor

        let doneBadge = NSView()
        doneBadge.wantsLayer = true
        doneBadge.layer?.cornerRadius = 5
        doneBadge.layer?.borderWidth = 1
        doneBadge.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        doneBadge.layer?.backgroundColor = task.status == .done
            ? MojaveTheme.green.withAlphaComponent(0.35).cgColor
            : NSColor(srgbRed: 0.09, green: 0.1, blue: 0.12, alpha: 1).cgColor
        doneBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(doneBadge)

        let name = mojaveLabel(task.displayName, size: 13, weight: .semibold)
        addSubview(name)

        let detail = mojaveLabel("\(task.imageCount) 张图片 · \(task.detail)", size: 11, color: MojaveTheme.muted)
        addSubview(detail)

        let processed = mojaveLabel("已处理 \(task.processedCount) / \(task.imageCount)", size: 11, color: MojaveTheme.muted)
        addSubview(processed)

        let statusColor = MojaveTheme.statusColor(task.status)
        let statusDot = NSView()
        statusDot.wantsLayer = true
        statusDot.layer?.backgroundColor = statusColor.cgColor
        statusDot.layer?.cornerRadius = 3.5
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusDot)

        let statusLabel = mojaveLabel(task.status.rawValue, size: 11, color: statusColor)
        addSubview(statusLabel)

        let folderButton = NSButton(title: "📂", target: self, action: #selector(openFolderTapped))
        folderButton.isBordered = false
        folderButton.font = NSFont.systemFont(ofSize: 12)
        folderButton.toolTip = task.status == .done ? "打开输出文件夹" : "打开原始文件夹"
        folderButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(folderButton)

        let progress = NSProgressIndicator()
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.doubleValue = task.progress
        progress.controlSize = .small
        progress.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progress)

        var constraints: [NSLayoutConstraint] = [
            heightAnchor.constraint(equalToConstant: 92),

            doneBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            doneBadge.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            doneBadge.widthAnchor.constraint(equalToConstant: 16),
            doneBadge.heightAnchor.constraint(equalToConstant: 16),

            name.leadingAnchor.constraint(equalTo: doneBadge.trailingAnchor, constant: 8),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            name.trailingAnchor.constraint(lessThanOrEqualTo: statusDot.leadingAnchor, constant: -6),

            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 4),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: folderButton.leadingAnchor, constant: -6),

            processed.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            processed.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 2),

            statusDot.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -5),
            statusDot.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),

            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            statusLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),

            folderButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            folderButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),

            progress.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            progress.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ]
        if task.status == .done {
            let check = mojaveLabel("✓", size: 10, weight: .bold, color: MojaveTheme.green)
            addSubview(check)
            constraints.append(contentsOf: [
                check.centerXAnchor.constraint(equalTo: doneBadge.centerXAnchor),
                check.centerYAnchor.constraint(equalTo: doneBadge.centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func openFolderTapped() { onOpenFolder?() }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }
}

// MARK: - Preview workspace (canvas + header + log overlay)

final class PreviewPanelView: NSView {
    let canvas = CropCanvasView()

    private let photoTitle = mojaveLabel("当前图片：未选择", size: 14, weight: .bold)
    private let folderTitle = mojaveLabel("", size: 11, color: MojaveTheme.muted)
    private let statusChip = mojaveLabel("等待导入", size: 11)
    private let statusChipBox = NSView()
    private let placeholder = mojaveLabel("拖入文件夹或点击导入开始", size: 14, weight: .semibold)
    private let logTitle = mojaveLabel("当前操作反馈", size: 11, color: NSColor(srgbRed: 0.79, green: 0.83, blue: 0.88, alpha: 1))
    private let logLine = mojaveLabel("", size: 12)
    private let logSubLine = mojaveLabel("", size: 11, color: MojaveTheme.muted)
    private let logBox = NSView()
    private let summaryBox = NSView()
    private let summaryTitle = mojaveLabel("导入统计", size: 11, weight: .semibold)
    private let summaryLine = mojaveLabel("", size: 11, color: MojaveTheme.muted)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = MojaveTheme.viewer.cgColor
        layer?.cornerRadius = 18
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.05).cgColor

        canvas.translatesAutoresizingMaskIntoConstraints = false
        addSubview(canvas)

        addSubview(photoTitle)
        addSubview(folderTitle)

        statusChipBox.wantsLayer = true
        statusChipBox.layer?.backgroundColor = NSColor(white: 0, alpha: 0.35).cgColor
        statusChipBox.layer?.cornerRadius = 14
        statusChipBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusChipBox)
        statusChipBox.addSubview(statusChip)

        placeholder.textColor = MojaveTheme.text
        addSubview(placeholder)

        logBox.wantsLayer = true
        logBox.layer?.backgroundColor = NSColor(white: 0, alpha: 0.45).cgColor
        logBox.layer?.cornerRadius = 14
        logBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(logBox)
        logBox.addSubview(logTitle)
        logBox.addSubview(logLine)
        logBox.addSubview(logSubLine)
        logLine.lineBreakMode = .byTruncatingTail
        logSubLine.lineBreakMode = .byTruncatingTail

        summaryBox.wantsLayer = true
        summaryBox.layer?.backgroundColor = NSColor(white: 0, alpha: 0.34).cgColor
        summaryBox.layer?.cornerRadius = 12
        summaryBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(summaryBox)
        summaryBox.addSubview(summaryTitle)
        summaryBox.addSubview(summaryLine)

        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: topAnchor, constant: 58),
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 48),
            canvas.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -48),
            canvas.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -92),

            photoTitle.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            photoTitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            photoTitle.trailingAnchor.constraint(lessThanOrEqualTo: statusChipBox.leadingAnchor, constant: -12),
            folderTitle.topAnchor.constraint(equalTo: photoTitle.bottomAnchor, constant: 4),
            folderTitle.leadingAnchor.constraint(equalTo: photoTitle.leadingAnchor),

            statusChipBox.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            statusChipBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            statusChipBox.heightAnchor.constraint(equalToConstant: 28),
            statusChip.leadingAnchor.constraint(equalTo: statusChipBox.leadingAnchor, constant: 12),
            statusChip.trailingAnchor.constraint(equalTo: statusChipBox.trailingAnchor, constant: -12),
            statusChip.centerYAnchor.constraint(equalTo: statusChipBox.centerYAnchor),

            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),

            logBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            logBox.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            logBox.widthAnchor.constraint(lessThanOrEqualToConstant: 430),
            logTitle.topAnchor.constraint(equalTo: logBox.topAnchor, constant: 12),
            logTitle.leadingAnchor.constraint(equalTo: logBox.leadingAnchor, constant: 14),
            logLine.topAnchor.constraint(equalTo: logTitle.bottomAnchor, constant: 6),
            logLine.leadingAnchor.constraint(equalTo: logTitle.leadingAnchor),
            logLine.trailingAnchor.constraint(equalTo: logBox.trailingAnchor, constant: -14),
            logSubLine.topAnchor.constraint(equalTo: logLine.bottomAnchor, constant: 4),
            logSubLine.leadingAnchor.constraint(equalTo: logTitle.leadingAnchor),
            logSubLine.trailingAnchor.constraint(equalTo: logBox.trailingAnchor, constant: -14),
            logSubLine.bottomAnchor.constraint(equalTo: logBox.bottomAnchor, constant: -12),

            summaryBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            summaryBox.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            summaryBox.widthAnchor.constraint(equalToConstant: 220),
            summaryTitle.topAnchor.constraint(equalTo: summaryBox.topAnchor, constant: 10),
            summaryTitle.leadingAnchor.constraint(equalTo: summaryBox.leadingAnchor, constant: 12),
            summaryLine.topAnchor.constraint(equalTo: summaryTitle.bottomAnchor, constant: 4),
            summaryLine.leadingAnchor.constraint(equalTo: summaryTitle.leadingAnchor),
            summaryLine.trailingAnchor.constraint(equalTo: summaryBox.trailingAnchor, constant: -12),
            summaryLine.bottomAnchor.constraint(equalTo: summaryBox.bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func render(store: MojaveStore) {
        let photo = store.selectedPhoto
        photoTitle.stringValue = "当前图片：\(photo?.name ?? "未选择")"
        folderTitle.stringValue = store.selectedTask.map { "当前文件夹：\($0.displayName)" } ?? ""
        statusChip.stringValue = photo?.status.rawValue ?? "等待导入"
        placeholder.isHidden = photo != nil
        canvas.isHidden = photo == nil
        logLine.stringValue = store.logMessage
        logSubLine.stringValue = store.logSubMessage
        if let summary = store.lastImportSummary {
            summaryBox.isHidden = false
            summaryLine.stringValue = "\(summary.folderCount) 个文件夹 · \(summary.subfolderCount) 个子文件夹 · \(summary.imageCount) 张图片"
        } else {
            summaryBox.isHidden = true
        }
        canvas.render(photo: photo, selectedRegionID: store.selectedCropRegionID, isDrawing: store.isDrawingNewRegion)
        prefetchNeighbors(store: store)
    }

    /// Decode the previous/next photos at canvas size in the background, so
    /// stepping through the roll shows instantly instead of buffering.
    private func prefetchNeighbors(store: MojaveStore) {
        guard let photos = store.selectedTask?.photos,
              let index = photos.firstIndex(where: { $0.id == store.selectedPhoto?.id }) else { return }
        for neighbor in [index - 1, index + 1, index + 2] where photos.indices.contains(neighbor) {
            MojaveImageLoader.shared.load(url: photos[neighbor].url, maxPixel: CropCanvasView.canvasMaxPixel) { _ in }
        }
    }
}

// MARK: - Crop canvas (image + draggable boxes; port of PhotoCanvas/MultiCropOverlay)

final class CropCanvasView: NSView {
    static let canvasMaxPixel = 1600
    static let filmstripMaxPixel = 140

    var onSelectRegion: ((CropRegion.ID) -> Void)?
    var onDeleteRegion: ((CropRegion.ID) -> Void)?
    var onChangeRegion: ((CropRegion.ID, CGRect) -> Void)?
    var onDrawNewRegion: ((CGRect) -> Void)?

    // The photo sits in its own view below a transparent overlay that draws
    // the boxes, so dragging a box only repaints the overlay strokes —
    // redrawing the large image every mouse-move was the drag lag (same fix
    // as the modern app's .drawingGroup()). Both children pass hits through
    // so the canvas keeps all mouse handling.
    private final class PassthroughImageView: NSImageView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    fileprivate final class CanvasOverlayView: NSView {
        weak var owner: CropCanvasView?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            owner?.drawOverlay(dirtyRect)
        }
    }

    private let photoView = PassthroughImageView()
    private let overlay = CanvasOverlayView()
    private var photoURL: URL?
    private var image: NSImage?
    private var regions: [CropRegion] = []
    private var selectedRegionID: CropRegion.ID?
    private var isDrawingMode = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        photoView.imageScaling = .scaleProportionallyUpOrDown
        photoView.autoresizingMask = [.width, .height]
        photoView.frame = bounds
        addSubview(photoView)
        overlay.owner = self
        overlay.autoresizingMask = [.width, .height]
        overlay.frame = bounds
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { nil }

    private func refreshOverlay() {
        overlay.needsDisplay = true
    }

    private enum DragKind {
        case move
        case corner(CropCorner)
        case edge(CropEdge)
        case marquee
    }

    private enum CropCorner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private enum CropEdge: CaseIterable {
        case top, bottom, left, right
    }

    private struct DragState {
        let regionID: CropRegion.ID?
        let kind: DragKind
        let startPoint: CGPoint
        let startRect: CGRect
        let angle: Double
        var currentRect: CGRect
    }

    private var dragState: DragState?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func render(photo: PhotoItem?, selectedRegionID: CropRegion.ID?, isDrawing: Bool) {
        self.selectedRegionID = selectedRegionID
        self.isDrawingMode = isDrawing
        regions = photo?.cropRegions ?? []
        if let photo {
            if photoURL != photo.url {
                photoURL = photo.url
                image = MojaveImageLoader.shared.cached(url: photo.url, maxPixel: Self.canvasMaxPixel)
                if image == nil {
                    // Show the filmstrip-resolution thumb immediately (enough
                    // to know which photo this is), swap in the editing-size
                    // decode when it lands.
                    image = MojaveImageLoader.shared.cached(url: photo.url, maxPixel: Self.filmstripMaxPixel)
                    let url = photo.url
                    MojaveImageLoader.shared.load(url: url, maxPixel: Self.canvasMaxPixel) { [weak self] loaded in
                        guard let self, self.photoURL == url, let loaded else { return }
                        self.image = loaded
                        self.photoView.image = loaded
                        self.refreshOverlay()
                    }
                }
            }
        } else {
            photoURL = nil
            image = nil
        }
        if isDrawing {
            NSCursor.crosshair.set()
        }
        photoView.image = image
        refreshOverlay()
    }

    private var imageRect: CGRect {
        guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let width = image.size.width * scale
        let height = image.size.height * scale
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }

    fileprivate func drawOverlay(_ dirtyRect: NSRect) {
        // Clip explicitly: macOS 14+ hands a window-sized dirtyRect and no
        // longer clips draws to view bounds by default.
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: bounds)
        defer { context.restoreGState() }

        guard image != nil else { return }
        let frame = imageRect

        if isDrawingMode {
            NSColor(white: 0, alpha: 0.28).setFill()
            context.fill(frame)
        }

        // Boxes: selected drawn last so it floats above its neighbours.
        let ordered = displayRegions().sorted { lhs, rhs in
            let lhsSelected = lhs.id == activeRegionID
            let rhsSelected = rhs.id == activeRegionID
            if lhsSelected != rhsSelected { return !lhsSelected }
            return lhs.index < rhs.index
        }
        for region in ordered {
            drawRegion(region, in: frame, context: context)
        }

        if let state = dragState, case .marquee = state.kind {
            let rect = state.currentRect
            MojaveTheme.orange.withAlphaComponent(0.16).setFill()
            context.fill(rect)
            MojaveTheme.orange.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 2
            path.stroke()
        }
    }

    private var activeRegionID: CropRegion.ID? {
        dragState?.regionID ?? selectedRegionID
    }

    private func displayRegions() -> [CropRegion] {
        regions.map { region in
            guard let state = dragState, state.regionID == region.id else { return region }
            var shown = region
            shown.rect = state.currentRect
            return shown
        }
    }

    private func regionColor(_ region: CropRegion, isSelected: Bool) -> NSColor {
        guard !isSelected else { return MojaveTheme.cropSelected }
        let palette = MojaveTheme.cropFrameColors
        return palette[max(0, region.index - 1) % palette.count]
    }

    private func drawRegion(_ region: CropRegion, in frame: CGRect, context: CGContext) {
        let isSelected = region.id == activeRegionID
        let rect = denormalize(region.rect, in: frame)
        let color = regionColor(region, isSelected: isSelected)

        context.saveGState()
        if abs(region.angle) > 0.001 {
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: CGFloat(region.angle) * .pi / 180)
            context.translateBy(x: -rect.midX, y: -rect.midY)
        }

        // Triple stroke like the SwiftUI overlay: dark halo, white core, colour.
        for (strokeColor, width) in [
            (NSColor(white: 0, alpha: 0.72), isSelected ? 2.2 : 1.8),
            (NSColor(white: 1, alpha: 0.82), isSelected ? 1.4 : 1.0),
            (color, isSelected ? 1.1 : 0.9),
        ] {
            strokeColor.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = CGFloat(width)
            path.stroke()
        }

        // Index badge (top-left).
        let badgeSize: CGFloat = isSelected ? 24 : 20
        let badgeRect = CGRect(x: rect.minX + 3, y: rect.minY + 3, width: badgeSize, height: badgeSize)
        color.setFill()
        context.fillEllipse(in: badgeRect)
        let badgeText = "\(region.index)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.black,
        ]
        let textSize = badgeText.size(withAttributes: attrs)
        badgeText.draw(
            at: NSPoint(x: badgeRect.midX - textSize.width / 2, y: badgeRect.midY - textSize.height / 2),
            withAttributes: attrs
        )

        // Delete ✕ (top-right).
        let deleteRect = deleteButtonRect(for: rect)
        NSColor(srgbRed: 0.8, green: 0.25, blue: 0.28, alpha: 0.92).setFill()
        context.fillEllipse(in: deleteRect)
        let xText = "✕" as NSString
        let xAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let xSize = xText.size(withAttributes: xAttrs)
        xText.draw(at: NSPoint(x: deleteRect.midX - xSize.width / 2, y: deleteRect.midY - xSize.height / 2), withAttributes: xAttrs)

        // Corner handles.
        let handleSize: CGFloat = isSelected ? 9 : 7
        for corner in CropCorner.allCases {
            let point = cornerPoint(corner, rect: rect)
            let handleRect = CGRect(x: point.x - handleSize / 2, y: point.y - handleSize / 2, width: handleSize, height: handleSize)
            NSColor(srgbRed: 0.86, green: 0.91, blue: 0.96, alpha: 1).setFill()
            context.fillEllipse(in: handleRect)
            color.setStroke()
            let ring = NSBezierPath(ovalIn: handleRect)
            ring.lineWidth = 0.8
            ring.stroke()
        }
        context.restoreGState()
    }

    private func deleteButtonRect(for rect: CGRect) -> CGRect {
        CGRect(x: rect.maxX - 23, y: rect.minY + 3, width: 20, height: 20)
    }

    private func cornerPoint(_ corner: CropCorner, rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    private func denormalize(_ rect: CGRect, in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + rect.minX * frame.width,
            y: frame.minY + rect.minY * frame.height,
            width: rect.width * frame.width,
            height: rect.height * frame.height
        )
    }

    private func normalize(_ rect: CGRect, in frame: CGRect) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        return CGRect(
            x: (rect.minX - frame.minX) / frame.width,
            y: (rect.minY - frame.minY) / frame.height,
            width: rect.width / frame.width,
            height: rect.height / frame.height
        )
    }

    // MARK: Mouse interaction

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let frame = imageRect
        guard frame.width > 0 else { return }

        if isDrawingMode {
            dragState = DragState(regionID: nil, kind: .marquee, startPoint: point, startRect: .zero, angle: 0, currentRect: CGRect(origin: point, size: .zero))
            return
        }

        // Delete ✕ has priority; selected box first so overlaps behave.
        for region in hitOrderedRegions() {
            let rect = denormalize(region.rect, in: frame)
            if deleteButtonRect(for: rect).insetBy(dx: -4, dy: -4).contains(point) {
                onDeleteRegion?(region.id)
                return
            }
        }

        guard let hit = hitTest(point: point, in: frame) else { return }
        onSelectRegion?(hit.region.id)
        let rect = denormalize(hit.region.rect, in: frame)
        dragState = DragState(
            regionID: hit.region.id,
            kind: hit.kind,
            startPoint: point,
            startRect: rect,
            angle: hit.region.angle,
            currentRect: hit.region.rect
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard var state = dragState else { return }
        let point = convert(event.locationInWindow, from: nil)
        let frame = imageRect

        if case .marquee = state.kind {
            let x = min(state.startPoint.x, point.x)
            let y = min(state.startPoint.y, point.y)
            state.currentRect = CGRect(x: x, y: y, width: abs(point.x - state.startPoint.x), height: abs(point.y - state.startPoint.y))
            dragState = state
            refreshOverlay()
            return
        }

        let dxScreen = point.x - state.startPoint.x
        let dyScreen = point.y - state.startPoint.y
        // A tilted box resizes along its own axes.
        var dx = dxScreen
        var dy = dyScreen
        if abs(state.angle) > 0.001, !isMove(state.kind) {
            let radians = -state.angle * .pi / 180
            let cosA = CGFloat(cos(radians))
            let sinA = CGFloat(sin(radians))
            dx = dxScreen * cosA - dyScreen * sinA
            dy = dxScreen * sinA + dyScreen * cosA
        }

        var next = state.startRect
        switch state.kind {
        case .move:
            next.origin.x += dxScreen
            next.origin.y += dyScreen
        case .corner(let corner):
            switch corner {
            case .topLeft:
                next.origin.x += dx; next.origin.y += dy; next.size.width -= dx; next.size.height -= dy
            case .topRight:
                next.origin.y += dy; next.size.width += dx; next.size.height -= dy
            case .bottomLeft:
                next.origin.x += dx; next.size.width -= dx; next.size.height += dy
            case .bottomRight:
                next.size.width += dx; next.size.height += dy
            }
        case .edge(let edge):
            switch edge {
            case .top: next.origin.y += dy; next.size.height -= dy
            case .bottom: next.size.height += dy
            case .left: next.origin.x += dx; next.size.width -= dx
            case .right: next.size.width += dx
            }
        case .marquee:
            break
        }
        if next.width < 8 { next.size.width = 8 }
        if next.height < 8 { next.size.height = 8 }
        state.currentRect = normalize(next, in: frame)
        dragState = state
        refreshOverlay()
    }

    override func mouseUp(with event: NSEvent) {
        guard let state = dragState else { return }
        dragState = nil
        let frame = imageRect

        if case .marquee = state.kind {
            let rect = state.currentRect
            NSCursor.arrow.set()
            guard rect.width > 6, rect.height > 6, frame.width > 0 else {
                refreshOverlay()
                return
            }
            onDrawNewRegion?(normalize(rect.intersection(frame), in: frame))
            return
        }

        if let regionID = state.regionID {
            onChangeRegion?(regionID, state.currentRect)
        }
        refreshOverlay()
    }

    private func isMove(_ kind: DragKind) -> Bool {
        if case .move = kind { return true }
        return false
    }

    private struct CanvasHit {
        let region: CropRegion
        let kind: DragKind
    }

    private func hitOrderedRegions() -> [CropRegion] {
        regions.sorted { lhs, rhs in
            if lhs.id == selectedRegionID { return true }
            if rhs.id == selectedRegionID { return false }
            return lhs.index > rhs.index
        }
    }

    private func hitTest(point: CGPoint, in frame: CGRect) -> CanvasHit? {
        for region in hitOrderedRegions() {
            let rect = denormalize(region.rect, in: frame)
            let expanded = rect.insetBy(dx: -10, dy: -10)
            guard expanded.contains(point) else { continue }
            if let corner = CropCorner.allCases.first(where: { hypot(cornerPoint($0, rect: rect).x - point.x, cornerPoint($0, rect: rect).y - point.y) <= 14 }) {
                return CanvasHit(region: region, kind: .corner(corner))
            }
            if region.id == selectedRegionID,
               let edge = CropEdge.allCases.first(where: { edgeHit($0, rect: rect, point: point) }) {
                return CanvasHit(region: region, kind: .edge(edge))
            }
            if rect.contains(point) {
                return CanvasHit(region: region, kind: .move)
            }
        }
        return nil
    }

    private func edgeHit(_ edge: CropEdge, rect: CGRect, point: CGPoint) -> Bool {
        let tolerance: CGFloat = 12
        switch edge {
        case .top:
            return abs(point.y - rect.minY) <= tolerance && point.x >= rect.minX && point.x <= rect.maxX
        case .bottom:
            return abs(point.y - rect.maxY) <= tolerance && point.x >= rect.minX && point.x <= rect.maxX
        case .left:
            return abs(point.x - rect.minX) <= tolerance && point.y >= rect.minY && point.y <= rect.maxY
        case .right:
            return abs(point.x - rect.maxX) <= tolerance && point.y >= rect.minY && point.y <= rect.maxY
        }
    }
}

// MARK: - Parameter panel (参数)

final class ParameterPanelView: PanelBoxView {
    var onMarginsChanged: ((Double, Double, Double, Double) -> Void)?
    var onToggleDraw: (() -> Void)?
    var onRedetect: (() -> Void)?
    var onSmartRedetect: (() -> Void)?
    var onApplyCandidate: ((CropCandidate.ID) -> Void)?
    var onMoveAll: ((Double, Double) -> Void)?
    var onRotate: ((Double) -> Void)?
    var onStartProcessing: (() -> Void)?

    private let topField = NSTextField()
    private let bottomField = NSTextField()
    private let leftField = NSTextField()
    private let rightField = NSTextField()
    private let drawButton = mojaveActionButton("框选新增", target: nil, action: nil)
    private let redetectButton = mojaveActionButton("恢复自动", target: nil, action: nil)
    private let calibrateButton = mojaveActionButton("手动校准", target: nil, action: nil)
    private let candidatesStack = NSStackView()
    private let angleValue = mojaveLabel("0°", size: 13, weight: .semibold)
    private let rotateLeft = mojaveActionButton("↺ 左旋", target: nil, action: nil)
    private let rotateRight = mojaveActionButton("↻ 右旋", target: nil, action: nil)
    private let startButton = NSButton(title: "▶ 开始处理", target: nil, action: nil)
    private var candidateIDs: [CropCandidate.ID] = []
    private var renderedCandidateSignature = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let title = mojaveLabel("参数", size: 12, weight: .semibold, color: MojaveTheme.muted)
        addSubview(title)

        let headerLine = NSView()
        headerLine.wantsLayer = true
        headerLine.layer?.backgroundColor = MojaveTheme.line.cgColor
        headerLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerLine)

        let marginsTitle = mojaveLabel("▤ 全局内收", size: 11, weight: .medium, color: MojaveTheme.blue)
        addSubview(marginsTitle)

        let grid = NSStackView()
        grid.orientation = .vertical
        grid.spacing = 6
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        let row1 = NSStackView(views: [marginField("上收 (px)", topField), marginField("下收 (px)", bottomField)])
        row1.spacing = 8
        row1.distribution = .fillEqually
        let row2 = NSStackView(views: [marginField("左收 (px)", leftField), marginField("右收 (px)", rightField)])
        row2.spacing = 8
        row2.distribution = .fillEqually
        grid.addArrangedSubview(row1)
        grid.addArrangedSubview(row2)

        let sectionLine = NSView()
        sectionLine.wantsLayer = true
        sectionLine.layer?.backgroundColor = MojaveTheme.line.cgColor
        sectionLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sectionLine)

        let canvasTitle = mojaveLabel("▣ 当前画布", size: 11, weight: .medium, color: MojaveTheme.orange)
        addSubview(canvasTitle)

        drawButton.target = self
        drawButton.action = #selector(drawTapped)
        drawButton.toolTip = "新增裁切框"
        redetectButton.target = self
        redetectButton.action = #selector(redetectTapped)
        redetectButton.toolTip = "恢复自动识别结果"
        calibrateButton.target = self
        calibrateButton.action = #selector(calibrateTapped)
        calibrateButton.toolTip = "按当前手动框校准整个画布"
        let actions = NSStackView(views: [drawButton, redetectButton, calibrateButton])
        actions.spacing = 5
        actions.distribution = .fillEqually
        actions.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actions)

        candidatesStack.orientation = .vertical
        candidatesStack.spacing = 4
        candidatesStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(candidatesStack)

        let moveTitle = mojaveLabel("整体移动", size: 11, color: MojaveTheme.muted)
        addSubview(moveTitle)
        let up = arrowButton("↑", dx: 0, dy: -1)
        let left = arrowButton("←", dx: -1, dy: 0)
        let down = arrowButton("↓", dx: 0, dy: 1)
        let right = arrowButton("→", dx: 1, dy: 0)
        let moveRow = NSStackView(views: [left, down, right])
        moveRow.spacing = 3
        let moveCluster = NSStackView(views: [up, moveRow])
        moveCluster.orientation = .vertical
        moveCluster.alignment = .centerX
        moveCluster.spacing = 3
        moveCluster.translatesAutoresizingMaskIntoConstraints = false
        addSubview(moveCluster)

        let angleTitle = mojaveLabel("当前框角度", size: 11, color: MojaveTheme.muted)
        addSubview(angleTitle)
        addSubview(angleValue)
        rotateLeft.target = self
        rotateLeft.action = #selector(rotateLeftTapped)
        rotateRight.target = self
        rotateRight.action = #selector(rotateRightTapped)
        let rotateRow = NSStackView(views: [rotateLeft, rotateRight])
        rotateRow.spacing = 5
        rotateRow.distribution = .fillEqually
        rotateRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rotateRow)

        startButton.target = self
        startButton.action = #selector(startTapped)
        startButton.bezelStyle = .rounded
        startButton.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        startButton.contentTintColor = MojaveTheme.green
        startButton.toolTip = "按当前裁切框开始批量输出"
        startButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(startButton)

        let bottomLine = NSView()
        bottomLine.wantsLayer = true
        bottomLine.layer?.backgroundColor = MojaveTheme.line.cgColor
        bottomLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomLine)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            headerLine.topAnchor.constraint(equalTo: topAnchor, constant: 36),
            headerLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerLine.heightAnchor.constraint(equalToConstant: 1),

            marginsTitle.topAnchor.constraint(equalTo: headerLine.bottomAnchor, constant: 10),
            marginsTitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            grid.topAnchor.constraint(equalTo: marginsTitle.bottomAnchor, constant: 8),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            sectionLine.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 10),
            sectionLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            sectionLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            sectionLine.heightAnchor.constraint(equalToConstant: 1),

            canvasTitle.topAnchor.constraint(equalTo: sectionLine.bottomAnchor, constant: 10),
            canvasTitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            actions.topAnchor.constraint(equalTo: canvasTitle.bottomAnchor, constant: 8),
            actions.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            candidatesStack.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 8),
            candidatesStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            candidatesStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            moveTitle.topAnchor.constraint(equalTo: candidatesStack.bottomAnchor, constant: 12),
            moveTitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            moveCluster.centerYAnchor.constraint(equalTo: moveTitle.centerYAnchor, constant: 12),
            moveCluster.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            angleTitle.topAnchor.constraint(equalTo: moveCluster.bottomAnchor, constant: 14),
            angleTitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            angleValue.centerYAnchor.constraint(equalTo: angleTitle.centerYAnchor),
            angleValue.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rotateRow.topAnchor.constraint(equalTo: angleTitle.bottomAnchor, constant: 8),
            rotateRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            rotateRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            bottomLine.bottomAnchor.constraint(equalTo: startButton.topAnchor, constant: -10),
            bottomLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomLine.heightAnchor.constraint(equalToConstant: 1),
            startButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            startButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            startButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            startButton.heightAnchor.constraint(equalToConstant: 34),
        ])

        for field in [topField, bottomField, leftField, rightField] {
            field.target = self
            field.action = #selector(marginChanged)
        }
    }

    required init?(coder: NSCoder) { nil }

    private func marginField(_ title: String, _ field: NSTextField) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let label = mojaveLabel(title, size: 10, color: MojaveTheme.muted)
        container.addSubview(label)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.stringValue = "0"
        field.font = NSFont.systemFont(ofSize: 11)
        field.alignment = .center
        container.addSubview(field)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            field.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 3),
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            field.heightAnchor.constraint(equalToConstant: 22),
        ])
        return container
    }

    private func arrowButton(_ title: String, dx: Double, dy: Double) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(moveTapped(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.tag = Int(dy) * 10 + Int(dx)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    @objc private func moveTapped(_ sender: NSButton) {
        let dy = Double(sender.tag / 10)
        let dx = Double(sender.tag % 10)
        // Integer division truncates toward zero, so decode negatives exactly.
        let decodedDx = sender.tag == -1 ? -1.0 : dx
        let decodedDy = sender.tag == -10 ? -1.0 : dy
        onMoveAll?(decodedDx, decodedDy)
    }

    @objc private func marginChanged() {
        onMarginsChanged?(
            Double(topField.stringValue) ?? 0,
            Double(bottomField.stringValue) ?? 0,
            Double(leftField.stringValue) ?? 0,
            Double(rightField.stringValue) ?? 0
        )
    }

    @objc private func drawTapped() { onToggleDraw?() }
    @objc private func redetectTapped() { onRedetect?() }
    @objc private func calibrateTapped() { onSmartRedetect?() }
    @objc private func rotateLeftTapped() { onRotate?(-1) }
    @objc private func rotateRightTapped() { onRotate?(1) }
    @objc private func startTapped() { onStartProcessing?() }
    @objc private func candidateTapped(_ sender: NSButton) {
        guard candidateIDs.indices.contains(sender.tag) else { return }
        onApplyCandidate?(candidateIDs[sender.tag])
    }

    func render(store: MojaveStore) {
        let photo = store.selectedPhoto
        drawButton.isEnabled = photo != nil
        drawButton.title = store.isDrawingNewRegion ? "退出框选" : "框选新增"
        redetectButton.isEnabled = store.canRestoreSelectedPhotoAutomatic
        calibrateButton.isEnabled = store.canCalibrateSelectedPhotoFromManualFrame
        angleValue.stringValue = String(format: "%.0f°", store.selectedCropRegion?.angle ?? 0)
        let hasRegion = store.selectedCropRegion != nil
        rotateLeft.isEnabled = hasRegion
        rotateRight.isEnabled = hasRegion

        // Only rebuild candidate buttons when the list or the pick changed.
        let candidates = photo?.cropCandidates ?? []
        let signature = candidates.map { "\($0.id)|\($0.id == photo?.selectedCandidateID)" }.joined()
        if signature != renderedCandidateSignature {
            renderedCandidateSignature = signature
            candidateIDs = candidates.map { $0.id }
            for view in candidatesStack.arrangedSubviews {
                candidatesStack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            for (offset, candidate) in candidates.enumerated() {
                let active = candidate.id == photo?.selectedCandidateID
                let button = NSButton(title: "\(active ? "◉" : "○") \(candidate.title)", target: self, action: #selector(candidateTapped(_:)))
                button.tag = offset
                button.bezelStyle = .rounded
                button.controlSize = .small
                button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
                button.contentTintColor = active ? MojaveTheme.blue : MojaveTheme.text
                candidatesStack.addArrangedSubview(button)
                button.widthAnchor.constraint(equalTo: candidatesStack.widthAnchor).isActive = true
            }
        }
    }
}

// MARK: - Filmstrip (图片胶片栏)

final class FilmstripView: NSView {
    var onSelectPhoto: ((PhotoItem.ID) -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?

    private let title = mojaveLabel("图片胶片栏", size: 13, weight: .semibold)
    private let statusLine = mojaveLabel("", size: 11, color: MojaveTheme.muted)
    private let previousButton = NSButton(title: "‹ 上一张", target: nil, action: nil)
    private let nextButton = NSButton(title: "下一张 ›", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let thumbsStack = NSStackView()
    private var photoIDs: [PhotoItem.ID] = []
    private var renderedSignature = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 1).cgColor

        let topLine = NSView()
        topLine.wantsLayer = true
        topLine.layer?.backgroundColor = MojaveTheme.line.cgColor
        topLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topLine)

        addSubview(title)
        addSubview(statusLine)

        for button in [previousButton, nextButton] {
            button.bezelStyle = .rounded
            button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 78).isActive = true
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }
        previousButton.target = self
        previousButton.action = #selector(previousTapped)
        previousButton.toolTip = "上一张（← 方向键）"
        addSubview(previousButton)
        nextButton.target = self
        nextButton.action = #selector(nextTapped)
        nextButton.toolTip = "下一张（→ 方向键）"
        addSubview(nextButton)

        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        thumbsStack.orientation = .horizontal
        thumbsStack.spacing = 10
        thumbsStack.translatesAutoresizingMaskIntoConstraints = false
        let clip = NSView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(thumbsStack)
        scroll.documentView = clip

        NSLayoutConstraint.activate([
            topLine.topAnchor.constraint(equalTo: topAnchor),
            topLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 1),

            title.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            statusLine.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            statusLine.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            previousButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            previousButton.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            nextButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            nextButton.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: previousButton.trailingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            clip.heightAnchor.constraint(equalTo: scroll.heightAnchor),
            thumbsStack.topAnchor.constraint(equalTo: clip.topAnchor),
            thumbsStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            thumbsStack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            thumbsStack.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    @objc private func previousTapped() { onPrevious?() }
    @objc private func nextTapped() { onNext?() }
    @objc private func thumbTapped(_ sender: NSButton) {
        guard photoIDs.indices.contains(sender.tag) else { return }
        onSelectPhoto?(photoIDs[sender.tag])
    }

    func render(store: MojaveStore) {
        let running = store.tasks.filter { $0.status == .running }.count
        let waiting = store.tasks.filter { $0.status == .waiting }.count
        statusLine.stringValue = "● \(running) 个运行中 · \(waiting) 个等待"

        let photos = store.selectedTask?.photos ?? []
        let selectedID = store.selectedPhoto?.id
        let index = photos.firstIndex { $0.id == selectedID } ?? 0
        previousButton.isEnabled = index > 0
        nextButton.isEnabled = !photos.isEmpty && index < photos.count - 1

        let signature = photos.map { "\($0.id)|\($0.id == selectedID)|\($0.status.rawValue)" }.joined()
        guard signature != renderedSignature else { return }
        renderedSignature = signature
        photoIDs = photos.map { $0.id }

        for view in thumbsStack.arrangedSubviews {
            thumbsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (offset, photo) in photos.enumerated() {
            let active = photo.id == selectedID
            let thumb = FilmThumbView(photo: photo, active: active)
            thumb.button.tag = offset
            thumb.button.target = self
            thumb.button.action = #selector(thumbTapped(_:))
            thumbsStack.addArrangedSubview(thumb)
        }
        if let selectedIndex = photos.firstIndex(where: { $0.id == selectedID }),
           thumbsStack.arrangedSubviews.indices.contains(selectedIndex) {
            let target = thumbsStack.arrangedSubviews[selectedIndex]
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scroll.contentView.scrollToVisible(target.frame.insetBy(dx: -20, dy: 0))
            }
        }
    }
}

final class FilmThumbView: NSView {
    let button: NSButton

    init(photo: PhotoItem, active: Bool) {
        button = NSButton(title: "", target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = active ? 2 : 1
        layer?.borderColor = active ? MojaveTheme.orange.cgColor : NSColor(white: 1, alpha: 0.10).cgColor
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.3).cgColor

        button.isBordered = false
        button.imageScaling = .scaleProportionallyUpOrDown
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        let statusLabel = mojaveLabel(photo.status.rawValue, size: 9, color: active ? MojaveTheme.orange : MojaveTheme.muted)
        addSubview(statusLabel)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 96),
            button.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            statusLabel.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 2),
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])

        // Identification-size only — the filmstrip just needs to show which
        // photo this is, not navigable detail.
        let url = photo.url
        if let cached = MojaveImageLoader.shared.cached(url: url, maxPixel: CropCanvasView.filmstripMaxPixel) {
            button.image = cached
        } else {
            MojaveImageLoader.shared.load(url: url, maxPixel: CropCanvasView.filmstripMaxPixel) { [weak button] image in
                button?.image = image
            }
        }
    }

    required init?(coder: NSCoder) { nil }
}
