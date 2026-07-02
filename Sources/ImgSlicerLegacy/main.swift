import AppKit
import CoreGraphics
import Foundation
import ImageIO

enum LegacyExportFormat: String {
    case tif = "tif"
    case jpg = "jpg"
}

struct LegacyCrop: Equatable {
    var rect: CGRect
    var angle: CGFloat = 0
}

struct LegacyPhoto {
    var url: URL
    var crops: [LegacyCrop]

    var name: String { url.lastPathComponent }
}

struct LegacyTask {
    let id = UUID()
    var name: String
    var rootURL: URL
    var photos: [LegacyPhoto]
    var isStopped: Bool = false
    let control = LegacyTaskControl()

    var cropCount: Int { photos.reduce(0) { $0 + $1.crops.count } }
}

final class LegacyTaskControl {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

enum LegacyFolderScanner {
    private static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "gif"]

    static func scan(urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            result.append(contentsOf: scan(url: url.standardizedFileURL))
        }
        var seen = Set<String>()
        return result
            .filter { seen.insert($0.path).inserted }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func scan(url: URL) -> [URL] {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if !isDirectory {
            return supportedExtensions.contains(url.pathExtension.lowercased()) ? [url] : []
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }
            if supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                files.append(fileURL)
            }
        }
        return files
    }
}

enum LegacyLaunchLog {
    static let url: URL = {
        // ~/Library/Logs, not Desktop: on Catalina+ the Desktop is TCC-gated
        // per code-signature, which blocks a freshly built (re-signed) app.
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
        if let logs {
            try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            return logs.appendingPathComponent("fiona-spotter-tool-mojave.log")
        }
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fiona-spotter-tool-mojave.log")
    }()

    static func write(_ message: String) {
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: url)
        }
    }
}

final class LegacyAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var controller: LegacyWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        LegacyLaunchLog.write("applicationDidFinishLaunching")
        installMainMenu()
        controller = LegacyWindowController()
        window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.title = "FionaSpotterTool"
        window.setContentSize(NSSize(width: 1280, height: 760))
        window.minSize = NSSize(width: 980, height: 600)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        LegacyLaunchLog.write("window shown")
        controller.runStartupArguments()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "FionaSpotterTool")
        let quitItem = NSMenuItem(title: "退出 FionaSpotterTool", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
    }
}

final class LegacyDropRootView: NSView {
    var onFileDropped: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onFileDropped?(urls)
        return true
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        if let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] {
            return urls
        }
        if let items = sender.draggingPasteboard.propertyList(forType: .fileURL) as? [String],
           !items.isEmpty {
            return items.compactMap { URL(string: $0) }
        }
        if let item = sender.draggingPasteboard.string(forType: .fileURL) {
            return URL(string: item).map { [$0] } ?? []
        }
        return []
    }
}

final class LegacyWindowController: NSViewController {
    private let canvas = LegacyCanvasView()
    private let statusLabel = NSTextField(labelWithString: "拖入或导入 TIFF/JPG 文件开始。")
    private let fileNameLabel = NSTextField(labelWithString: "未导入文件")
    private let outputLabel = NSTextField(labelWithString: "默认导出到原文件夹")
    private let cropCountLabel = NSTextField(labelWithString: "红框 0 个")
    private let taskPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let photoPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let algorithmPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let filmstripScroll = NSScrollView()
    private let filmstripStack = NSStackView()
    private let thumbnailQueue = DispatchQueue(label: "fiona.spotter.legacy.thumbnails", qos: .userInitiated)
    private var tasks: [LegacyTask] = []
    private var selectedTaskIndex = 0
    private var selectedPhotoIndex = 0
    private var exportDirectory: URL?
    private var templateRect: CGRect?
    private var templateImageAspect: Double?
    private var exportFormat: LegacyExportFormat = .tif
    private var algorithmMode: CropAlgorithmMode = .automatic

    private var selectedTask: LegacyTask? {
        tasks.indices.contains(selectedTaskIndex) ? tasks[selectedTaskIndex] : nil
    }

    private var selectedPhoto: LegacyPhoto? {
        guard tasks.indices.contains(selectedTaskIndex),
              tasks[selectedTaskIndex].photos.indices.contains(selectedPhotoIndex) else { return nil }
        return tasks[selectedTaskIndex].photos[selectedPhotoIndex]
    }

    override func loadView() {
        LegacyLaunchLog.write("loadView")
        let rootView = LegacyDropRootView(frame: NSRect(x: 0, y: 0, width: 1280, height: 760))
        rootView.onFileDropped = { [weak self] urls in
            self?.importItems(urls)
        }
        view = rootView
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.08, alpha: 1).cgColor

        let topBar = makeTopBar()
        let leftPanel = makeLeftPanel()
        let rightPanel = makeRightPanel()
        let bottomPanel = makeBottomPanel()

        formatPopup.addItems(withTitles: ["TIF 16-bit", "JPG"])
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)
        taskPopup.target = self
        taskPopup.action = #selector(taskSelectionChanged)
        photoPopup.target = self
        photoPopup.action = #selector(photoSelectionChanged)
        let availableAlgorithms = CropAlgorithmMode.allCases.filter {
            $0 != .externalDetector || LegacyAutomaticDetector.isExternalDetectorAvailable
        }
        algorithmPopup.addItems(withTitles: availableAlgorithms.map(\.rawValue))
        algorithmPopup.target = self
        algorithmPopup.action = #selector(algorithmChanged)

        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.wantsLayer = true
        canvas.layer?.cornerRadius = 8
        canvas.layer?.masksToBounds = true
        canvas.onCropChanged = { [weak self] rect in
            self?.templateRect = rect
            self?.templateImageAspect = self?.selectedPhoto.flatMap { Self.imageAspect(url: $0.url) }
            self?.saveCurrentCrops()
            self?.refreshSummary()
        }
        canvas.onCropsChanged = { [weak self] in
            self?.saveCurrentCrops()
            self?.refreshSummary()
        }
        canvas.onFileDropped = { [weak self] urls in
            self?.importItems(urls)
        }

        view.addSubview(topBar)
        view.addSubview(leftPanel)
        view.addSubview(rightPanel)
        view.addSubview(canvas)
        view.addSubview(bottomPanel)

        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: view.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 72),

            leftPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            leftPanel.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 16),
            leftPanel.bottomAnchor.constraint(equalTo: bottomPanel.topAnchor, constant: -16),
            leftPanel.widthAnchor.constraint(equalToConstant: 292),

            rightPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            rightPanel.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 16),
            rightPanel.bottomAnchor.constraint(equalTo: bottomPanel.topAnchor, constant: -16),
            rightPanel.widthAnchor.constraint(equalToConstant: 336),

            canvas.leadingAnchor.constraint(equalTo: leftPanel.trailingAnchor, constant: 16),
            canvas.trailingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: -16),
            canvas.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 16),
            canvas.bottomAnchor.constraint(equalTo: bottomPanel.topAnchor, constant: -16),

            bottomPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            bottomPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            bottomPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            bottomPanel.heightAnchor.constraint(equalToConstant: 170)
        ])
        LegacyLaunchLog.write("loadView finished")
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func iconImage(_ name: String) -> NSImage? {
        let image = NSImage(named: NSImage.Name(name))
        image?.isTemplate = true
        return image
    }

    private func stackedRectanglesIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18))
        image.lockFocus()
        NSColor.black.setStroke()
        let lineWidth: CGFloat = 1.6
        let rects = [
            NSRect(x: 2, y: 8, width: 11, height: 7),
            NSRect(x: 6, y: 5, width: 11, height: 7),
            NSRect(x: 10, y: 2, width: 11, height: 7)
        ]
        for rect in rects {
            let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
            path.lineWidth = lineWidth
            path.stroke()
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func iconButton(_ iconName: String, title: String = "", action: Selector, help: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.image = iconImage(iconName)
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeft
        button.toolTip = help
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        if title.isEmpty {
            button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        }
        return button
    }

    private func iconWideButton(_ title: String, iconName: String, action: Selector, help: String) -> NSButton {
        let button = iconButton(iconName, title: title, action: action, help: help)
        button.alignment = .center
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    private func applyAllButton(title: String = "", compact: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(applyCropsToCurrentTask))
        button.bezelStyle = .texturedRounded
        button.image = stackedRectanglesIcon()
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeft
        button.toolTip = "以左上第一帧黑边为基准，将当前红框应用到全部图片"
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: compact ? 30 : 32).isActive = true
        if title.isEmpty {
            button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        }
        return button
    }

    private func makeTopBar() -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(calibratedRed: 0.095, green: 0.105, blue: 0.125, alpha: 1).cgColor

        let title = label("FionaSpotterTool", size: 16, weight: .semibold, color: NSColor(calibratedWhite: 0.95, alpha: 1))
        let subtitle = label("film frame spotting and export", size: 11, weight: .regular, color: NSColor(calibratedWhite: 0.62, alpha: 1))
        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        let importButton = iconWideButton("导入文件", iconName: "NSFolder", action: #selector(importFile), help: "导入图片文件或文件夹")
        let exportButton = iconWideButton("导出", iconName: "NSShareTemplate", action: #selector(exportCrops), help: "按当前红框导出")
        let actions = NSStackView(views: [importButton, exportButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 10
        actions.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        bar.addSubview(actions)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 18),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -18),
            actions.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])
        return bar
    }

    private func makeLeftPanel() -> NSView {
        let box = panel()
        let title = label("任务列表", size: 13, weight: .semibold)
        let clearButton = iconButton("NSEraserTemplate", action: #selector(deleteSelectedTask), help: "删除当前任务")
        let titleRow = NSStackView(views: [title, clearButton])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        let importButton = iconWideButton("导入", iconName: "NSFolder", action: #selector(importFile), help: "导入图片文件或文件夹")
        let stopButton = iconWideButton("终止", iconName: "NSStopProgressTemplate", action: #selector(stopSelectedTask), help: "终止当前任务")
        let deleteButton = iconWideButton("删除", iconName: "NSTrashFull", action: #selector(deleteSelectedTask), help: "删除当前任务")
        let applyButton = applyAllButton(title: "应用到全部")
        let taskActions = NSStackView(views: [applyButton, stopButton, deleteButton])
        taskActions.orientation = .horizontal
        taskActions.alignment = .centerY
        taskActions.spacing = 8
        taskPopup.translatesAutoresizingMaskIntoConstraints = false
        photoPopup.translatesAutoresizingMaskIntoConstraints = false
        fileNameLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        fileNameLabel.textColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        fileNameLabel.lineBreakMode = .byTruncatingMiddle
        let hint = label("可拖入文件夹或多张图片；首次红框会作为后续自动识别的尺寸参考。", size: 11, color: NSColor(calibratedWhite: 0.58, alpha: 1))
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 4
        let stack = NSStackView(views: [
            titleRow,
            separator(),
            taskPopup,
            photoPopup,
            fileNameLabel,
            taskActions,
            hint,
            importButton
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 16),
            taskPopup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            photoPopup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            taskActions.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            importButton.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return box
    }

    private func makeRightPanel() -> NSView {
        let box = panel()
        let title = label("参数设置", size: 15, weight: .bold)
        let add = iconButton("NSAddTemplate", action: #selector(addBox), help: "新增红框")
        let identify = iconButton("NSRefreshTemplate", action: #selector(autoIdentify), help: "自动识别")
        let apply = applyAllButton(compact: true)
        let clearCrops = iconButton("NSTrashFull", action: #selector(clearCurrentCrops), help: "清除当前图片所有红框")
        let toolRow = NSStackView(views: [add, identify, apply, clearCrops])
        toolRow.orientation = .horizontal
        toolRow.alignment = .centerY
        toolRow.spacing = 9
        let nudgeUp = arrowButton("↑", action: #selector(nudgeCropsUp), help: "所有红框向上微调")
        let nudgeDown = arrowButton("↓", action: #selector(nudgeCropsDown), help: "所有红框向下微调")
        let nudgeLeft = arrowButton("←", action: #selector(nudgeCropsLeft), help: "所有红框向左微调")
        let nudgeRight = arrowButton("→", action: #selector(nudgeCropsRight), help: "所有红框向右微调")
        let nudgeRow = NSStackView(views: [nudgeLeft, nudgeUp, nudgeDown, nudgeRight])
        nudgeRow.orientation = .horizontal
        nudgeRow.alignment = .centerY
        nudgeRow.spacing = 8
        let choose = iconWideButton("选择导出文件夹", iconName: "NSFolder", action: #selector(chooseOutput), help: "选择导出文件夹")
        let export = iconWideButton("导出", iconName: "NSShareTemplate", action: #selector(exportCrops), help: "导出当前任务")
        let zoomRow = NSStackView(views: [
            iconButton("NSExitFullScreenTemplate", action: #selector(zoomOut), help: "缩小预览"),
            smallButton("100%", action: #selector(resetZoom)),
            iconButton("NSEnterFullScreenTemplate", action: #selector(zoomIn), help: "放大预览")
        ])
        zoomRow.orientation = .horizontal
        zoomRow.spacing = 8
        formatPopup.translatesAutoresizingMaskIntoConstraints = false
        algorithmPopup.translatesAutoresizingMaskIntoConstraints = false
        outputLabel.textColor = NSColor(calibratedWhite: 0.6, alpha: 1)
        outputLabel.font = NSFont.systemFont(ofSize: 11)
        outputLabel.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [
            title,
            separator(),
            label("裁切框", size: 12, weight: .semibold),
            toolRow,
            label("识别算法", size: 12, weight: .semibold),
            algorithmPopup,
            label("统一微调", size: 12, weight: .semibold),
            nudgeRow,
            label("预览缩放", size: 12, weight: .semibold),
            zoomRow,
            label("导出格式", size: 12, weight: .semibold),
            formatPopup,
            choose,
            outputLabel,
            export
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 16),
            algorithmPopup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            formatPopup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            choose.widthAnchor.constraint(equalTo: stack.widthAnchor),
            export.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return box
    }

    private func makeBottomPanel() -> NSView {
        let box = panel()
        statusLabel.textColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        cropCountLabel.textColor = NSColor(calibratedWhite: 0.62, alpha: 1)
        cropCountLabel.font = NSFont.systemFont(ofSize: 11)
        filmstripStack.orientation = .horizontal
        filmstripStack.alignment = .top
        filmstripStack.spacing = 10
        filmstripStack.translatesAutoresizingMaskIntoConstraints = false
        filmstripScroll.documentView = filmstripStack
        filmstripScroll.hasHorizontalScroller = true
        filmstripScroll.hasVerticalScroller = false
        filmstripScroll.drawsBackground = false
        filmstripScroll.translatesAutoresizingMaskIntoConstraints = false

        let feedback = NSStackView(views: [
            label("当前操作反馈", size: 11, weight: .semibold, color: NSColor(calibratedRed: 0.6, green: 0.85, blue: 0.65, alpha: 1)),
            statusLabel,
            cropCountLabel
        ])
        feedback.orientation = .vertical
        feedback.alignment = .leading
        feedback.spacing = 6
        feedback.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [feedback, filmstripScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
            filmstripScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            filmstripScroll.heightAnchor.constraint(equalToConstant: 78)
        ])
        return box
    }

    private func panel() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedRed: 0.095, green: 0.11, blue: 0.135, alpha: 1).cgColor
        view.layer?.cornerRadius = 8
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        view.layer?.borderWidth = 1
        return view
    }

    private func separator() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        view.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return view
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = NSColor(calibratedWhite: 0.88, alpha: 1)) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func wideButton(_ title: String, action: Selector) -> NSButton {
        let button = button(title, action: action)
        button.controlSize = .regular
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    private func smallButton(_ title: String, action: Selector) -> NSButton {
        let button = button(title, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: title == "100%" ? 72 : 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private func arrowButton(_ title: String, action: Selector, help: String) -> NSButton {
        let button = button(title, action: action)
        button.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        button.toolTip = help
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    @objc private func importFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedFileTypes = ["tif", "tiff", "jpg", "jpeg", "png", "bmp", "heic", "heif", "gif"]
        if panel.runModal() == .OK {
            importItems(panel.urls)
        }
    }

    private func importItems(_ urls: [URL]) {
        let found = LegacyFolderScanner.scan(urls: urls)
        guard !found.isEmpty else {
            statusLabel.stringValue = "没有找到可处理图片。"
            return
        }
        let template = templateCompatible(with: found.first) ? templateRect : nil
        let photos = found.map { url in
            let crop = template ?? CGRect(x: 0.05, y: 0.08, width: 0.18, height: 0.72)
            return LegacyPhoto(url: url, crops: [LegacyCrop(rect: crop)])
        }
        let root = taskRootURL(from: urls, fallback: found[0].deletingLastPathComponent())
        let task = LegacyTask(name: taskName(from: urls, fallback: root), rootURL: root, photos: photos)
        tasks.append(task)
        selectedTaskIndex = tasks.count - 1
        selectedPhotoIndex = 0
        exportDirectory = found.first?.deletingLastPathComponent()
        templateRect = photos.first?.crops.first?.rect ?? template
        templateImageAspect = found.first.flatMap { Self.imageAspect(url: $0) }
        rebuildTaskPopup()
        rebuildPhotoPopup()
        rebuildFilmstrip()
        loadSelectedPhoto()
        statusLabel.stringValue = "已导入 \(photos.count) 张图片。"
        refreshSummary()
    }

    private func loadSelectedPhoto() {
        guard let task = selectedTask, task.photos.indices.contains(selectedPhotoIndex) else {
            canvas.setImage(NSImage(size: NSSize(width: 1, height: 1)), crops: [])
            fileNameLabel.stringValue = "未导入文件"
            refreshSummary()
            return
        }
        let photo = task.photos[selectedPhotoIndex]
        guard let image = LegacyImageIO.thumbnail(url: photo.url, maxPixelSize: 6200) else {
            statusLabel.stringValue = "无法打开图片。"
            return
        }
        canvas.setImage(image, crops: photo.crops)
        fileNameLabel.stringValue = "\(task.name)：\(selectedPhotoIndex + 1) / \(task.photos.count)  \(photo.name)"
        outputLabel.stringValue = "输出：\(exportDirectory?.path ?? photo.url.deletingLastPathComponent().path)"
        photoPopup.selectItem(at: selectedPhotoIndex)
        taskPopup.selectItem(at: selectedTaskIndex)
        updateFilmstripSelection()
        refreshSummary()
    }

    private func saveCurrentCrops() {
        guard tasks.indices.contains(selectedTaskIndex),
              tasks[selectedTaskIndex].photos.indices.contains(selectedPhotoIndex) else { return }
        tasks[selectedTaskIndex].photos[selectedPhotoIndex].crops = canvas.crops
        if let selected = canvas.currentTemplateRect {
            templateRect = selected
            templateImageAspect = selectedPhoto.flatMap { Self.imageAspect(url: $0.url) }
        }
    }

    private func templateCompatible(with url: URL?) -> Bool {
        guard let templateImageAspect,
              let url,
              let currentAspect = Self.imageAspect(url: url) else {
            return true
        }
        let diff = abs(currentAspect - templateImageAspect) / max(max(currentAspect, templateImageAspect), 0.0001)
        return diff < 0.18
    }

    private static func imageAspect(url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: false
            ] as CFDictionary
        ),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              height > 0 else {
            return nil
        }
        return Double(width) / Double(height)
    }

    private func rebuildTaskPopup() {
        taskPopup.removeAllItems()
        if tasks.isEmpty {
            taskPopup.addItem(withTitle: "未导入任务")
        } else {
            taskPopup.addItems(withTitles: tasks.enumerated().map { item in
                let stopped = item.element.isStopped ? "已终止" : "运行中"
                return "\(item.offset + 1). \(item.element.name) · \(item.element.photos.count) 张 · \(stopped)"
            })
        }
    }

    private func rebuildPhotoPopup() {
        photoPopup.removeAllItems()
        guard let task = selectedTask, !task.photos.isEmpty else {
            photoPopup.addItem(withTitle: "未导入图片")
            return
        }
        photoPopup.addItems(withTitles: task.photos.enumerated().map { "\($0.offset + 1). \($0.element.name)" })
    }

    private func rebuildFilmstrip() {
        for subview in filmstripStack.arrangedSubviews {
            filmstripStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        guard let task = selectedTask else { return }
        for (index, photo) in task.photos.enumerated() {
            let button = NSButton(title: photo.name, target: self, action: #selector(filmstripPhotoSelected(_:)))
            button.tag = index
            button.bezelStyle = .regularSquare
            button.imagePosition = .imageAbove
            button.alignment = .center
            button.font = NSFont.systemFont(ofSize: 10)
            button.lineBreakMode = .byTruncatingMiddle
            button.setButtonType(.momentaryPushIn)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 118).isActive = true
            button.heightAnchor.constraint(equalToConstant: 70).isActive = true
            filmstripStack.addArrangedSubview(button)
            let taskIndex = selectedTaskIndex
            thumbnailQueue.async { [weak self, weak button] in
                guard let thumb = LegacyImageIO.thumbnail(url: photo.url, maxPixelSize: 180) else { return }
                thumb.size = NSSize(width: 92, height: 44)
                DispatchQueue.main.async {
                    guard let self = self,
                          self.selectedTaskIndex == taskIndex,
                          button?.tag == index else { return }
                    button?.image = thumb
                }
            }
        }
        updateFilmstripSelection()
    }

    private func updateFilmstripSelection() {
        for view in filmstripStack.arrangedSubviews {
            guard let button = view as? NSButton else { continue }
            button.state = button.tag == selectedPhotoIndex ? .on : .off
        }
    }

    @objc private func taskSelectionChanged() {
        saveCurrentCrops()
        selectedTaskIndex = max(0, taskPopup.indexOfSelectedItem)
        selectedPhotoIndex = 0
        exportDirectory = selectedTask?.rootURL
        rebuildPhotoPopup()
        rebuildFilmstrip()
        loadSelectedPhoto()
    }

    @objc private func photoSelectionChanged() {
        saveCurrentCrops()
        selectedPhotoIndex = max(0, photoPopup.indexOfSelectedItem)
        loadSelectedPhoto()
    }

    @objc private func filmstripPhotoSelected(_ sender: NSButton) {
        saveCurrentCrops()
        selectedPhotoIndex = sender.tag
        loadSelectedPhoto()
    }

    @objc private func stopSelectedTask() {
        guard tasks.indices.contains(selectedTaskIndex) else { return }
        tasks[selectedTaskIndex].isStopped = true
        tasks[selectedTaskIndex].control.cancel()
        statusLabel.stringValue = "已终止任务：\(tasks[selectedTaskIndex].name)"
        rebuildTaskPopup()
        refreshSummary()
    }

    @objc private func deleteSelectedTask() {
        guard tasks.indices.contains(selectedTaskIndex) else { return }
        let name = tasks[selectedTaskIndex].name
        tasks.remove(at: selectedTaskIndex)
        selectedTaskIndex = min(selectedTaskIndex, max(0, tasks.count - 1))
        selectedPhotoIndex = 0
        rebuildTaskPopup()
        rebuildPhotoPopup()
        rebuildFilmstrip()
        loadSelectedPhoto()
        statusLabel.stringValue = "已删除任务：\(name)"
    }

    @objc private func applyCropsToCurrentTask() {
        saveCurrentCrops()
        guard tasks.indices.contains(selectedTaskIndex), !canvas.crops.isEmpty else { return }
        guard !tasks[selectedTaskIndex].isStopped else {
            statusLabel.stringValue = "当前任务已终止，无法应用到全部。"
            return
        }
        let taskIndex = selectedTaskIndex
        let sourceCrops = canvas.crops.sortedForReadingOrder()
        let anchor = sourceCrops[0].rect.normalized
        let photos = tasks[taskIndex].photos
        let selectedIndex = selectedPhotoIndex
        let control = tasks[taskIndex].control
        statusLabel.stringValue = "正在以左上第一帧黑边为基准应用到其他图片..."
        DispatchQueue.global(qos: .userInitiated).async {
            var results = [[LegacyCrop]]()
            for (index, photo) in photos.enumerated() {
                if control.isCancelled { break }
                if index == selectedIndex {
                    results.append(sourceCrops)
                } else {
                    results.append(LegacyFrameDetector.anchorAlignedCrops(url: photo.url, sourceCrops: sourceCrops, anchor: anchor))
                }
            }
            DispatchQueue.main.async {
                guard self.tasks.indices.contains(taskIndex) else { return }
                for index in results.indices {
                    self.tasks[taskIndex].photos[index].crops = results[index]
                }
                self.loadSelectedPhoto()
                self.statusLabel.stringValue = control.isCancelled
                    ? "已终止应用，已保留完成部分。"
                    : "已保留当前图片微调结果，并按左上第一帧黑边基准应用到其他图片。"
                self.refreshSummary()
            }
        }
    }

    @objc private func addBox() {
        let rect = templateRect ?? canvas.currentTemplateRect ?? CGRect(x: 0.05, y: 0.08, width: 0.18, height: 0.72)
        canvas.crops.append(LegacyCrop(rect: rect))
        canvas.selectedIndex = canvas.crops.count - 1
        templateRect = rect
        canvas.needsDisplay = true
        saveCurrentCrops()
        refreshSummary()
    }

    @objc private func clearCurrentCrops() {
        canvas.crops.removeAll()
        canvas.selectedIndex = nil
        saveCurrentCrops()
        statusLabel.stringValue = "已清除当前图片所有红框。"
        refreshSummary()
    }

    @objc private func nudgeCropsUp() { nudgeAllCrops(dx: 0, dy: 0.001) }
    @objc private func nudgeCropsDown() { nudgeAllCrops(dx: 0, dy: -0.001) }
    @objc private func nudgeCropsLeft() { nudgeAllCrops(dx: -0.001, dy: 0) }
    @objc private func nudgeCropsRight() { nudgeAllCrops(dx: 0.001, dy: 0) }

    private func nudgeAllCrops(dx: CGFloat, dy: CGFloat) {
        guard !canvas.crops.isEmpty else { return }
        canvas.crops = canvas.crops.map { LegacyCrop(rect: $0.rect.offsetBy(dx: dx, dy: dy).normalized, angle: $0.angle) }
        saveCurrentCrops()
        statusLabel.stringValue = "已统一微调当前图片全部红框。"
        refreshSummary()
    }

    @objc private func autoIdentify() {
        identify()
    }

    /// Scripted driving for hosts that block synthetic clicks into a
    /// 10.14-target binary: `--auto-import <path>` mirrors the 导入 button,
    /// `--auto-identify` runs 自动识别, `--auto-export` exports when done.
    func runStartupArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "--auto-import"), args.indices.contains(flag + 1) else { return }
        importItems([URL(fileURLWithPath: args[flag + 1])])
        guard args.contains("--auto-identify") else { return }
        identify { [weak self] in
            if args.contains("--auto-export") { self?.exportCrops() }
        }
    }

    private func identify(completion: (() -> Void)? = nil) {
        saveCurrentCrops()
        guard tasks.indices.contains(selectedTaskIndex), !tasks[selectedTaskIndex].photos.isEmpty else { return }
        guard !tasks[selectedTaskIndex].isStopped else {
            statusLabel.stringValue = "当前任务已终止，无法自动识别。"
            return
        }
        let template = templateRect ?? canvas.currentTemplateRect
        let taskIndex = selectedTaskIndex
        let photos = tasks[taskIndex].photos
        let control = tasks[taskIndex].control
        let selectedAlgorithm = algorithmMode
        statusLabel.stringValue = "正在批量识别图中全部画幅..."
        DispatchQueue.global(qos: .userInitiated).async {
            var results = [[LegacyCrop]]()
            for photo in photos {
                if control.isCancelled { break }
                let automatic = LegacyAutomaticDetector.detect(url: photo.url, algorithmMode: selectedAlgorithm)
                guard let template else {
                    results.append(automatic)
                    continue
                }
                let templateDetected = LegacyFrameDetector.detectBestTemplateCrops(url: photo.url, template: template)
                let preferred = [automatic, templateDetected].max { $0.count < $1.count } ?? []
                results.append(preferred.isEmpty ? LegacyFrameDetector.tiledCrops(template: template) : preferred)
            }
            DispatchQueue.main.async {
                guard self.tasks.indices.contains(taskIndex) else { return }
                for index in results.indices {
                    self.tasks[taskIndex].photos[index].crops = results[index]
                }
                self.loadSelectedPhoto()
                let count = results.reduce(0) { $0 + $1.count }
                self.statusLabel.stringValue = control.isCancelled
                    ? "已终止识别，已完成 \(results.count) 张图片、\(count) 个红框。"
                    : "已识别 \(photos.count) 张图片，共 \(count) 个红框。"
                self.refreshSummary()
                completion?()
            }
        }
    }

    @objc private func exportCrops() {
        saveCurrentCrops()
        guard let task = selectedTask, !task.photos.isEmpty else { return }
        guard !task.isStopped else {
            statusLabel.stringValue = "当前任务已终止，无法导出。"
            return
        }
        let directory = exportDirectory ?? task.rootURL
        let format = exportFormat
        let photos = task.photos
        let control = task.control
        statusLabel.stringValue = "正在批量导出..."
        DispatchQueue.global(qos: .userInitiated).async {
            var outputs: [URL] = []
            for photo in photos {
                if control.isCancelled { break }
                outputs.append(contentsOf: LegacyExporter.export(url: photo.url, crops: photo.crops, directory: directory, format: format))
            }
            DispatchQueue.main.async {
                self.statusLabel.stringValue = control.isCancelled
                    ? "已终止导出，已输出 \(outputs.count) 个文件。"
                    : "已导出 \(outputs.count) 个文件到 \(directory.path)"
            }
        }
    }

    @objc private func chooseOutput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = exportDirectory
        if panel.runModal() == .OK, let url = panel.url {
            exportDirectory = url
            outputLabel.stringValue = "输出：\(url.path)"
            statusLabel.stringValue = "已选择导出文件夹。"
        }
    }

    @objc private func formatChanged() {
        exportFormat = formatPopup.indexOfSelectedItem == 0 ? .tif : .jpg
    }

    @objc private func algorithmChanged() {
        guard let selected = CropAlgorithmMode(rawValue: algorithmPopup.titleOfSelectedItem ?? "") else { return }
        algorithmMode = selected
        statusLabel.stringValue = "识别算法已切换为：\(selected.rawValue)"
    }

    @objc private func zoomIn() { canvas.zoom *= 1.2 }
    @objc private func zoomOut() { canvas.zoom = max(0.25, canvas.zoom / 1.2) }
    @objc private func resetZoom() { canvas.resetViewTransform() }

    private func refreshSummary() {
        let totalPhotos = tasks.reduce(0) { $0 + $1.photos.count }
        let totalCrops = tasks.reduce(0) { $0 + $1.cropCount }
        let taskText = selectedTask.map { "\($0.name) · \($0.photos.count) 张" } ?? "未导入任务"
        cropCountLabel.stringValue = "\(tasks.count) 个任务 · \(totalPhotos) 张图片 · 当前任务 \(taskText) · 当前红框 \(canvas.crops.count) 个 · 全部红框 \(totalCrops) 个 · A 新增，Delete 删除，滚轮缩放"
    }

    private func taskRootURL(from urls: [URL], fallback: URL) -> URL {
        if urls.count == 1 {
            let url = urls[0].standardizedFileURL
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDirectory ? url : url.deletingLastPathComponent()
        }
        return fallback
    }

    private func taskName(from urls: [URL], fallback: URL) -> String {
        if urls.count == 1 {
            let url = urls[0].standardizedFileURL
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDirectory ? url.lastPathComponent : url.deletingLastPathComponent().lastPathComponent
        }
        return fallback.lastPathComponent.isEmpty ? "导入任务 \(tasks.count + 1)" : fallback.lastPathComponent
    }
}

final class LegacyCanvasView: NSView {
    var crops: [LegacyCrop] = [] { didSet { needsDisplay = true } }
    var selectedIndex: Int?
    var onCropChanged: ((CGRect) -> Void)?
    var onCropsChanged: (() -> Void)?
    var onFileDropped: (([URL]) -> Void)?
    var zoom: CGFloat = 1 { didSet { needsDisplay = true } }

    private var image: NSImage?
    private var activeHandle: CropHandle?
    private var activeIndex: Int?
    private var startCrop = CGRect.zero
    private var startAngle: CGFloat = 0
    private var startPoint = CGPoint.zero
    private var panOffset = CGPoint.zero
    private var startPanOffset = CGPoint.zero
    private var isPanning = false

    var currentTemplateRect: CGRect? {
        selectedIndex.flatMap { crops.indices.contains($0) ? crops[$0].rect : nil } ?? crops.first?.rect
    }

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    func setImage(_ image: NSImage, crops: [LegacyCrop]) {
        self.image = image
        self.crops = crops
        selectedIndex = crops.isEmpty ? nil : 0
        panOffset = .zero
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        dirtyRect.fill()
        guard let image else { return }
        let rect = imageRect()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: rect)
        NSColor.red.setStroke()
        for (index, crop) in crops.enumerated() {
            let r = viewRect(from: crop.rect, imageRect: rect)
            let path = rotatedRectPath(rect: r, angleDegrees: crop.angle)
            path.lineWidth = index == selectedIndex ? 1.4 : 1.0
            path.stroke()
            let handle = rotateHandlePoint(rect: r, angleDegrees: crop.angle)
            NSColor.red.setFill()
            NSBezierPath(ovalIn: CGRect(x: handle.x - 4, y: handle.y - 4, width: 8, height: 8)).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let imgRect = imageRect()
        for index in crops.indices.reversed() {
            let rect = viewRect(from: crops[index].rect, imageRect: imgRect)
            if let handle = hitHandle(point: point, rect: rect, angleDegrees: crops[index].angle) {
                selectedIndex = index
                activeIndex = index
                activeHandle = handle
                startCrop = crops[index].rect
                startAngle = crops[index].angle
                startPoint = point
                needsDisplay = true
                return
            }
        }
        selectedIndex = nil
        if image != nil, imageRect().contains(point) {
            isPanning = true
            startPoint = point
            startPanOffset = panOffset
            NSCursor.closedHand.set()
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if isPanning {
            let point = convert(event.locationInWindow, from: nil)
            panOffset = CGPoint(
                x: startPanOffset.x + point.x - startPoint.x,
                y: startPanOffset.y + point.y - startPoint.y
            )
            needsDisplay = true
            return
        }
        guard let activeIndex, crops.indices.contains(activeIndex), let activeHandle else { return }
        let point = convert(event.locationInWindow, from: nil)
        let imgRect = imageRect()
        if activeHandle == .rotate {
            let rect = viewRect(from: crops[activeIndex].rect, imageRect: imgRect)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let start = atan2(startPoint.y - center.y, startPoint.x - center.x)
            let current = atan2(point.y - center.y, point.x - center.x)
            crops[activeIndex].angle = startAngle + (current - start) * 180 / .pi
            onCropsChanged?()
            needsDisplay = true
            return
        }
        let dx = (point.x - startPoint.x) / max(1, imgRect.width)
        let dy = (point.y - startPoint.y) / max(1, imgRect.height)
        crops[activeIndex].rect = activeHandle.adjust(rect: startCrop, dx: dx, dy: dy).normalized
        onCropsChanged?()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let activeIndex, crops.indices.contains(activeIndex) {
            onCropChanged?(crops[activeIndex].rect)
        }
        activeIndex = nil
        activeHandle = nil
        isPanning = false
        NSCursor.arrow.set()
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers?.lowercased() == "a" {
            let rect = currentTemplateRect ?? CGRect(x: 0.05, y: 0.08, width: 0.18, height: 0.72)
            crops.append(LegacyCrop(rect: rect))
            selectedIndex = crops.count - 1
            onCropChanged?(rect)
            onCropsChanged?()
        } else if event.keyCode == 51, let selectedIndex, crops.indices.contains(selectedIndex), crops.count > 1 {
            crops.remove(at: selectedIndex)
            self.selectedIndex = crops.indices.first
            onCropsChanged?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        zoom = event.scrollingDeltaY < 0 ? zoom * 1.1 : max(0.25, zoom / 1.1)
    }

    func resetViewTransform() {
        zoom = 1
        panOffset = .zero
        needsDisplay = true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onFileDropped?(urls)
        return true
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        if let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] {
            return urls
        }
        if let items = sender.draggingPasteboard.propertyList(forType: .fileURL) as? [String],
           !items.isEmpty {
            return items.compactMap { URL(string: $0) }
        }
        if let item = sender.draggingPasteboard.string(forType: .fileURL) {
            return URL(string: item).map { [$0] } ?? []
        }
        return []
    }

    private func imageRect() -> CGRect {
        guard let image else { return bounds }
        let inset = bounds.insetBy(dx: 24, dy: 24)
        let scale = min(inset.width / max(1, image.size.width), inset.height / max(1, image.size.height)) * zoom
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2 + panOffset.x,
            y: bounds.midY - size.height / 2 + panOffset.y,
            width: size.width,
            height: size.height
        )
    }

    private func viewRect(from normalized: CGRect, imageRect: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX + normalized.minX * imageRect.width,
            y: imageRect.minY + normalized.minY * imageRect.height,
            width: normalized.width * imageRect.width,
            height: normalized.height * imageRect.height
        )
    }

    private func rotatedRectPath(rect: CGRect, angleDegrees: CGFloat) -> NSBezierPath {
        var transform = AffineTransform()
        transform.translate(x: rect.midX, y: rect.midY)
        transform.rotate(byRadians: angleDegrees * .pi / 180)
        transform.translate(x: -rect.midX, y: -rect.midY)
        let path = NSBezierPath(rect: rect)
        path.transform(using: transform)
        return path
    }

    private func rotateHandlePoint(rect: CGRect, angleDegrees: CGFloat) -> CGPoint {
        rotate(point: CGPoint(x: rect.minX - 14, y: rect.minY - 14), around: CGPoint(x: rect.midX, y: rect.midY), angleDegrees: angleDegrees)
    }

    private func rotate(point: CGPoint, around center: CGPoint, angleDegrees: CGFloat) -> CGPoint {
        let angle = angleDegrees * .pi / 180
        let dx = point.x - center.x
        let dy = point.y - center.y
        return CGPoint(
            x: center.x + dx * cos(angle) - dy * sin(angle),
            y: center.y + dx * sin(angle) + dy * cos(angle)
        )
    }

    private func hitHandle(point: CGPoint, rect: CGRect, angleDegrees: CGFloat) -> CropHandle? {
        let corner: CGFloat = 42
        let edge: CGFloat = 24
        let rotatePoint = rotateHandlePoint(rect: rect, angleDegrees: angleDegrees)
        if CGRect(x: rotatePoint.x - 12, y: rotatePoint.y - 12, width: 24, height: 24).contains(point) { return .rotate }
        let localPoint = rotate(
            point: point,
            around: CGPoint(x: rect.midX, y: rect.midY),
            angleDegrees: -angleDegrees
        )
        let corners: [(CropHandle, CGRect)] = [
            (.topLeft, CGRect(x: rect.minX - corner / 2, y: rect.minY - corner / 2, width: corner, height: corner)),
            (.topRight, CGRect(x: rect.maxX - corner / 2, y: rect.minY - corner / 2, width: corner, height: corner)),
            (.bottomRight, CGRect(x: rect.maxX - corner / 2, y: rect.maxY - corner / 2, width: corner, height: corner)),
            (.bottomLeft, CGRect(x: rect.minX - corner / 2, y: rect.maxY - corner / 2, width: corner, height: corner))
        ]
        for item in corners where item.1.contains(localPoint) { return item.0 }
        if CGRect(x: rect.minX, y: rect.minY - edge / 2, width: rect.width, height: edge).contains(localPoint) { return .top }
        if CGRect(x: rect.maxX - edge / 2, y: rect.minY, width: edge, height: rect.height).contains(localPoint) { return .right }
        if CGRect(x: rect.minX, y: rect.maxY - edge / 2, width: rect.width, height: edge).contains(localPoint) { return .bottom }
        if CGRect(x: rect.minX - edge / 2, y: rect.minY, width: edge, height: rect.height).contains(localPoint) { return .left }
        if rect.contains(localPoint) { return .move }
        return nil
    }
}

enum CropHandle {
    case move, rotate, topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    func adjust(rect: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        var next = rect
        switch self {
        case .move:
            next.origin.x += dx; next.origin.y += dy
        case .rotate:
            break
        case .topLeft:
            next.origin.x += dx; next.origin.y += dy; next.size.width -= dx; next.size.height -= dy
        case .top:
            next.origin.y += dy; next.size.height -= dy
        case .topRight:
            next.origin.y += dy; next.size.width += dx; next.size.height -= dy
        case .right:
            next.size.width += dx
        case .bottomRight:
            next.size.width += dx; next.size.height += dy
        case .bottom:
            next.size.height += dy
        case .bottomLeft:
            next.origin.x += dx; next.size.width -= dx; next.size.height += dy
        case .left:
            next.origin.x += dx; next.size.width -= dx
        }
        return next
    }
}

enum LegacyImageIO {
    static func thumbnail(url: URL, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    static func grayThumbnail(url: URL, maxPixelSize: Int) -> (bytes: [UInt8], width: Int, height: Int)? {
        guard let image = thumbnail(url: url, maxPixelSize: maxPixelSize)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? (bytes, width, height) : nil
    }
}

enum LegacyFrameDetector {
    static func anchorAlignedCrops(url: URL, sourceCrops: [LegacyCrop], anchor: CGRect) -> [LegacyCrop] {
        guard !sourceCrops.isEmpty else { return [] }
        let detected = detectBestTemplateCrops(url: url, template: anchor)
        guard let roughAnchor = detected.map(\.rect).sortedForReadingOrder().first else {
            return sourceCrops
        }
        let detectedAnchor = refinedContentAnchor(url: url, roughAnchor: roughAnchor, template: anchor) ?? roughAnchor
        let dx = detectedAnchor.minX - anchor.minX
        let dy = detectedAnchor.minY - anchor.minY
        return sourceCrops.map { crop in
            LegacyCrop(rect: crop.rect.offsetBy(dx: dx, dy: dy).normalized, angle: crop.angle)
        }
    }

    static func detectBestTemplateCrops(url: URL, template: CGRect) -> [LegacyCrop] {
        let templateCrops = detectTemplatePositionCrops(url: url, template: template)
        if !templateCrops.isEmpty {
            return nonOverlappingCrops(sameSizeTemplateCrops(from: templateCrops.map(\.rect), template: template))
        }
        let centerCrops = detectFrameCenters(url: url).map { crop(center: $0, size: template.size) }
        return nonOverlappingCrops(sameSizeTemplateCrops(from: centerCrops.map(\.rect), template: template))
    }

    static func detectTemplatePositionCrops(url: URL, template: CGRect) -> [LegacyCrop] {
        guard let gray = LegacyImageIO.grayThumbnail(url: url, maxPixelSize: 4096) else { return [] }
        let bytes = gray.bytes
        let width = gray.width
        let height = gray.height
        guard width > 80, height > 80 else { return [] }

        let brightThreshold: UInt8 = 42
        let rows = projectionSegments(
            count: height,
            minSize: max(18, Int(Double(height) * max(0.045, template.height * 0.45))),
            mergeGap: max(8, height / 70),
            minimumThreshold: 0.030
        ) { y in
            var content = 0
            var edge = 0
            let row = y * width
            for x in 0..<width {
                let value = bytes[row + x]
                if value > brightThreshold && value < 248 { content += 1 }
                if y > 0 {
                    edge += abs(Int(bytes[row + x]) - Int(bytes[(y - 1) * width + x]))
                }
            }
            let contentRatio = Double(content) / Double(width)
            let edgeRatio = Double(edge) / Double(width * 255)
            return contentRatio * 0.95 + edgeRatio * 1.10
        }

        let filteredRows = rows.filter { segment in
            let normalizedHeight = Double(segment.size) / Double(height)
            return normalizedHeight > template.height * 0.35 && normalizedHeight < min(0.68, template.height * 2.35)
        }

        var rects: [CGRect] = []
        for row in filteredRows {
            let columnScores = (0..<width).map { x in
                var content = 0
                var edge = 0
                for y in row.start..<row.end {
                    let index = y * width + x
                    let value = bytes[index]
                    if value > brightThreshold && value < 248 { content += 1 }
                    if x > 0 {
                        edge += abs(Int(bytes[index]) - Int(bytes[y * width + x - 1]))
                    }
                }
                let count = max(1, row.size)
                let contentRatio = Double(content) / Double(count)
                let edgeRatio = Double(edge) / Double(count * 255)
                return contentRatio * 0.95 + edgeRatio * 0.95
            }

            let templatePixels = max(18, Int(Double(width) * template.width))
            let gapColumns = frameColumnsByDarkGaps(scores: columnScores, templatePixels: templatePixels, imageWidth: width)
            let projectionColumns = projectionSegments(
                values: columnScores,
                minSize: max(18, Int(Double(width) * template.width * 0.36)),
                mergeGap: max(5, Int(Double(width) * min(0.018, max(0.006, template.width * 0.16)))),
                minimumThreshold: 0.055
            )
            let columns = gapColumns.count >= projectionColumns.count ? gapColumns : projectionColumns
            let splitColumns = splitSegmentsByExpectedSize(columns, expectedSize: templatePixels)
            let filteredColumns = splitColumns.filter { segment in
                let normalizedWidth = Double(segment.size) / Double(width)
                return normalizedWidth > template.width * 0.28 && normalizedWidth < min(0.55, template.width * 2.65)
            }

            for column in filteredColumns {
                let center = CGPoint(
                    x: Double(column.start + column.end) / 2 / Double(width),
                    y: Double(row.start + row.end) / 2 / Double(height)
                )
                rects.append(templateRect(center: center, size: template.size))
            }
        }

        return mergeNormalizedRects(rects, overlapThreshold: 0.72)
            .sorted {
                if abs($0.minY - $1.minY) > 0.045 { return $0.minY < $1.minY }
                return $0.minX < $1.minX
            }
            .enumerated()
            .map { LegacyCrop(rect: $0.element.normalized) }
    }

    private static func sameSizeTemplateCrops(from rects: [CGRect], template: CGRect) -> [LegacyCrop] {
        let template = template.normalized
        guard !rects.isEmpty else { return [] }
        return rects
            .map { $0.normalized }
            .sorted {
                if abs($0.minY - $1.minY) > 0.045 { return $0.minY < $1.minY }
                return $0.minX < $1.minX
            }
            .enumerated()
            .map { _, rect in
                LegacyCrop(rect: templateRect(center: CGPoint(x: rect.midX, y: rect.midY), size: template.size))
            }
    }

    private static func nonOverlappingCrops(_ crops: [LegacyCrop]) -> [LegacyCrop] {
        var accepted: [LegacyCrop] = []
        for crop in crops.sortedForReadingOrder() {
            let rect = crop.rect.normalized
            let overlapsExisting = accepted.contains { existing in
                intersectionRatio(existing.rect.normalized, rect) > 0.18
            }
            if !overlapsExisting {
                accepted.append(LegacyCrop(rect: rect))
            }
        }
        return accepted
    }

    private static func refinedContentAnchor(url: URL, roughAnchor: CGRect, template: CGRect) -> CGRect? {
        guard let gray = LegacyImageIO.grayThumbnail(url: url, maxPixelSize: 4096) else { return nil }
        let bytes = gray.bytes
        let width = gray.width
        let height = gray.height
        let rough = roughAnchor.normalized
        let x0 = min(max(Int(rough.minX * CGFloat(width)), 0), width - 1)
        let y0 = min(max(Int(rough.minY * CGFloat(height)), 0), height - 1)
        let x1 = min(max(Int(rough.maxX * CGFloat(width)), x0 + 1), width)
        let y1 = min(max(Int(rough.maxY * CGFloat(height)), y0 + 1), height)
        let boxWidth = max(1, x1 - x0)
        let boxHeight = max(1, y1 - y0)

        let verticalRange = max(y0, y0 + boxHeight / 8)..<min(y1, y1 - boxHeight / 8)
        let horizontalRange = max(x0, x0 + boxWidth / 8)..<min(x1, x1 - boxWidth / 8)
        let leftLimit = min(x1 - 1, x0 + max(8, Int(Double(boxWidth) * 0.24)))
        let topLimit = min(y1 - 1, y0 + max(8, Int(Double(boxHeight) * 0.24)))

        let refinedX = firstContentColumn(
            bytes: bytes,
            width: width,
            xRange: x0...leftLimit,
            yRange: verticalRange
        ) ?? x0
        let refinedY = firstContentRow(
            bytes: bytes,
            width: width,
            yRange: y0...topLimit,
            xRange: horizontalRange
        ) ?? y0

        let nx = CGFloat(refinedX) / CGFloat(width)
        let ny = CGFloat(refinedY) / CGFloat(height)
        return CGRect(x: nx, y: ny, width: template.normalized.width, height: template.normalized.height).normalized
    }

    private static func firstContentColumn(bytes: [UInt8], width: Int, xRange: ClosedRange<Int>, yRange: Range<Int>) -> Int? {
        var runStart: Int?
        for x in xRange {
            let stats = columnBorderStats(bytes: bytes, width: width, x: x, yRange: yRange)
            let isContent = stats.darkRatio < 0.50 && !(stats.whiteRatio > 0.90 && stats.edgeRatio < 0.018)
            if isContent {
                if runStart == nil { runStart = x }
                if let start = runStart, x - start >= 2 { return start }
            } else {
                runStart = nil
            }
        }
        return nil
    }

    private static func firstContentRow(bytes: [UInt8], width: Int, yRange: ClosedRange<Int>, xRange: Range<Int>) -> Int? {
        var runStart: Int?
        for y in yRange {
            let stats = rowBorderStats(bytes: bytes, width: width, y: y, xRange: xRange)
            let isContent = stats.darkRatio < 0.50 && !(stats.whiteRatio > 0.88 && stats.edgeRatio < 0.018)
            if isContent {
                if runStart == nil { runStart = y }
                if let start = runStart, y - start >= 2 { return start }
            } else {
                runStart = nil
            }
        }
        return nil
    }

    private static func columnBorderStats(bytes: [UInt8], width: Int, x: Int, yRange: Range<Int>) -> (darkRatio: Double, whiteRatio: Double, edgeRatio: Double) {
        var dark = 0
        var white = 0
        var edge = 0
        var previous: UInt8?
        for y in yRange {
            let value = bytes[y * width + x]
            if value <= 42 { dark += 1 }
            if value >= 242 { white += 1 }
            if let previous { edge += abs(Int(value) - Int(previous)) }
            previous = value
        }
        let count = max(1, yRange.count)
        return (Double(dark) / Double(count), Double(white) / Double(count), Double(edge) / Double(max(1, count - 1) * 255))
    }

    private static func rowBorderStats(bytes: [UInt8], width: Int, y: Int, xRange: Range<Int>) -> (darkRatio: Double, whiteRatio: Double, edgeRatio: Double) {
        var dark = 0
        var white = 0
        var edge = 0
        var previous: UInt8?
        let row = y * width
        for x in xRange {
            let value = bytes[row + x]
            if value <= 42 { dark += 1 }
            if value >= 242 { white += 1 }
            if let previous { edge += abs(Int(value) - Int(previous)) }
            previous = value
        }
        let count = max(1, xRange.count)
        return (Double(dark) / Double(count), Double(white) / Double(count), Double(edge) / Double(max(1, count - 1) * 255))
    }

    private static func templateRect(center: CGPoint, size: CGSize) -> CGRect {
        let width = min(max(size.width, 0.01), 0.98)
        let height = min(max(size.height, 0.01), 0.98)
        let x = min(max(center.x - width / 2, 0), 1 - width)
        let y = min(max(center.y - height / 2, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height).normalized
    }

    private static func projectionSegments(count: Int, minSize: Int, mergeGap: Int, minimumThreshold: Double, score: (Int) -> Double) -> [IntSegment] {
        projectionSegments(values: (0..<count).map(score), minSize: minSize, mergeGap: mergeGap, minimumThreshold: minimumThreshold)
    }

    private static func projectionSegments(values raw: [Double], minSize: Int, mergeGap: Int, minimumThreshold: Double) -> [IntSegment] {
        let count = raw.count
        guard count > 0 else { return [] }
        let smoothed = movingAverage(raw, window: max(3, count / 260))
        let sorted = smoothed.sorted()
        let low = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.20))]
        let high = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.86))]
        let threshold = max(minimumThreshold, low + (high - low) * 0.36)
        let initial = mergeCloseSegments(thresholdSegments(values: smoothed, threshold: threshold, minimumSize: minSize, lessThan: false), maxGap: mergeGap)
        return splitOverwideSegments(initial, values: smoothed, idealSize: max(minSize, count / 8), gapThreshold: max(minimumThreshold * 0.75, threshold * 0.64))
    }

    private static func frameColumnsByDarkGaps(scores rawScores: [Double], templatePixels: Int, imageWidth: Int) -> [IntSegment] {
        guard rawScores.count > 8, templatePixels > 8 else { return [] }
        let scores = movingAverage(rawScores, window: max(3, rawScores.count / 360))
        let sorted = scores.sorted()
        let low = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.18))]
        let median = sorted[sorted.count / 2]
        let gapThreshold = min(0.16, max(0.018, low + (median - low) * 0.34))
        let minGap = max(3, min(templatePixels / 14, imageWidth / 500))
        let rawGaps = thresholdSegments(values: scores, threshold: gapThreshold, minimumSize: minGap, lessThan: true)
        let maxGap = max(minGap * 2, templatePixels / 3)
        let gaps = mergeCloseSegments(rawGaps, maxGap: max(2, minGap / 2))
            .filter { gap in
                gap.size <= maxGap || gap.start <= imageWidth / 80 || gap.end >= imageWidth - imageWidth / 80
            }
            .sorted { $0.start < $1.start }
        guard gaps.count >= 2 else { return [] }

        var boundaries: [IntSegment] = []
        if let first = gaps.first, first.start > max(4, templatePixels / 6) {
            boundaries.append(IntSegment(start: 0, end: 0))
        }
        boundaries.append(contentsOf: gaps)
        if let last = gaps.last, imageWidth - last.end > max(4, templatePixels / 6) {
            boundaries.append(IntSegment(start: imageWidth, end: imageWidth))
        }

        var frames: [IntSegment] = []
        for pair in zip(boundaries, boundaries.dropFirst()) {
            let left = pair.0.end
            let right = pair.1.start
            let size = right - left
            guard size >= max(12, templatePixels / 3) else { continue }
            if size > Int(Double(templatePixels) * 1.75) {
                frames.append(contentsOf: splitSegmentsByExpectedSize([IntSegment(start: left, end: right)], expectedSize: templatePixels))
            } else {
                frames.append(IntSegment(start: left, end: right))
            }
        }

        return frames.filter { segment in
            let ratio = Double(segment.size) / Double(templatePixels)
            return ratio >= 0.42 && ratio <= 1.85
        }
    }

    private static func splitOverwideSegments(_ segments: [IntSegment], values: [Double], idealSize: Int, gapThreshold: Double) -> [IntSegment] {
        var result: [IntSegment] = []
        for segment in segments {
            if segment.size <= idealSize * 2 {
                result.append(segment)
                continue
            }
            let inner = thresholdSegments(
                values: Array(values[segment.start..<segment.end]),
                threshold: gapThreshold,
                minimumSize: max(4, idealSize / 12),
                lessThan: true
            )
            var cursor = segment.start
            var didSplit = false
            for gap in inner {
                let gapStart = segment.start + gap.start
                let gapEnd = segment.start + gap.end
                if gapStart - cursor >= max(8, idealSize / 3) {
                    result.append(IntSegment(start: cursor, end: gapStart))
                    didSplit = true
                }
                cursor = gapEnd
            }
            if segment.end - cursor >= max(8, idealSize / 3) {
                result.append(IntSegment(start: cursor, end: segment.end))
                didSplit = true
            }
            if !didSplit { result.append(segment) }
        }
        return result
    }

    private static func splitSegmentsByExpectedSize(_ segments: [IntSegment], expectedSize: Int) -> [IntSegment] {
        guard expectedSize > 0 else { return segments }
        var result: [IntSegment] = []
        for segment in segments {
            let estimatedCount = Int(round(Double(segment.size) / Double(expectedSize)))
            guard estimatedCount >= 2, segment.size > Int(Double(expectedSize) * 1.45) else {
                result.append(segment)
                continue
            }
            let partSize = Double(segment.size) / Double(estimatedCount)
            for part in 0..<estimatedCount {
                let start = segment.start + Int(round(Double(part) * partSize))
                let end = segment.start + Int(round(Double(part + 1) * partSize))
                if end - start >= max(8, expectedSize / 3) {
                    result.append(IntSegment(start: start, end: end))
                }
            }
        }
        return result
    }

    private static func movingAverage(_ values: [Double], window: Int) -> [Double] {
        guard values.count > 1, window > 1 else { return values }
        let radius = max(1, window / 2)
        var result = [Double](repeating: 0, count: values.count)
        var sum = 0.0
        var left = 0
        for index in values.indices {
            let right = min(values.count - 1, index + radius)
            while left < max(0, index - radius) {
                sum -= values[left]
                left += 1
            }
            if index == 0 {
                sum = values[0...right].reduce(0, +)
            } else if index + radius < values.count {
                sum += values[index + radius]
            }
            result[index] = sum / Double(right - left + 1)
        }
        return result
    }

    private static func thresholdSegments(values: [Double], threshold: Double, minimumSize: Int, lessThan: Bool) -> [IntSegment] {
        var segments: [IntSegment] = []
        var start: Int?
        for (index, value) in values.enumerated() {
            let active = lessThan ? value < threshold : value > threshold
            if active {
                if start == nil { start = index }
            } else if let s = start {
                if index - s >= minimumSize { segments.append(IntSegment(start: s, end: index)) }
                start = nil
            }
        }
        if let s = start, values.count - s >= minimumSize {
            segments.append(IntSegment(start: s, end: values.count))
        }
        return segments
    }

    private static func mergeCloseSegments(_ segments: [IntSegment], maxGap: Int) -> [IntSegment] {
        guard var current = segments.sorted(by: { $0.start < $1.start }).first else { return [] }
        var result: [IntSegment] = []
        for segment in segments.sorted(by: { $0.start < $1.start }).dropFirst() {
            if segment.start - current.end <= maxGap {
                current.end = max(current.end, segment.end)
            } else {
                result.append(current)
                current = segment
            }
        }
        result.append(current)
        return result
    }

    private static func mergeNormalizedRects(_ rects: [CGRect], overlapThreshold: CGFloat) -> [CGRect] {
        var result: [CGRect] = []
        for rect in rects.map({ $0.normalized }) {
            if let index = result.firstIndex(where: { intersectionRatio($0, rect) > overlapThreshold }) {
                result[index] = average(result[index], rect).normalized
            } else {
                result.append(rect)
            }
        }
        return result
    }

    private static func intersectionRatio(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let minArea = max(0.0001, min(a.width * a.height, b.width * b.height))
        return intersection.width * intersection.height / minArea
    }

    private static func average(_ a: CGRect, _ b: CGRect) -> CGRect {
        CGRect(
            x: (a.minX + b.minX) / 2,
            y: (a.minY + b.minY) / 2,
            width: (a.width + b.width) / 2,
            height: (a.height + b.height) / 2
        )
    }

    static func detectFrameCenters(url: URL) -> [CGPoint] {
        guard let gray = LegacyImageIO.grayThumbnail(url: url, maxPixelSize: 4096) else { return [] }
        let rows = contentSegments(axisCount: gray.height) { y in
            var count = 0
            let row = y * gray.width
            for x in 0..<gray.width where gray.bytes[row + x] > 42 && gray.bytes[row + x] < 248 { count += 1 }
            return Double(count) / Double(gray.width)
        }.filter { $0.size > max(24, gray.height / 18) && $0.size < max(48, gray.height * 7 / 10) }
        var centers: [CGPoint] = []
        for row in rows {
            let columns = contentSegments(axisCount: gray.width) { x in
                var count = 0
                for y in row.start..<row.end where gray.bytes[y * gray.width + x] > 42 && gray.bytes[y * gray.width + x] < 248 { count += 1 }
                return Double(count) / Double(max(1, row.size))
            }.filter { $0.size > max(24, gray.width / 40) && $0.size < max(48, gray.width * 8 / 10) }
            for column in columns {
                centers.append(CGPoint(x: Double(column.mid) / Double(gray.width), y: Double(row.mid) / Double(gray.height)))
            }
        }
        return centers.sorted {
            abs($0.y - $1.y) > 0.04 ? $0.y < $1.y : $0.x < $1.x
        }
    }

    static func crop(center: CGPoint, size: CGSize) -> LegacyCrop {
        let x = min(max(center.x - size.width / 2, 0), 1 - size.width)
        let y = min(max(center.y - size.height / 2, 0), 1 - size.height)
        return LegacyCrop(rect: CGRect(x: x, y: y, width: size.width, height: size.height).normalized)
    }

    static func tiledCrops(template: CGRect) -> [LegacyCrop] {
        [LegacyCrop(rect: template.normalized)]
    }

    private static func contentSegments(axisCount: Int, value: (Int) -> Double) -> [IntSegment] {
        var segments: [IntSegment] = []
        var start: Int?
        for index in 0..<axisCount {
            let active = value(index) > 0.045
            if active {
                if start == nil { start = index }
            } else if let s = start {
                if index - s > 4 { segments.append(IntSegment(start: s, end: index)) }
                start = nil
            }
        }
        if let s = start, axisCount - s > 4 { segments.append(IntSegment(start: s, end: axisCount)) }
        return merge(segments, gap: max(4, axisCount / 180))
    }

    private static func merge(_ segments: [IntSegment], gap: Int) -> [IntSegment] {
        guard var current = segments.first else { return [] }
        var result: [IntSegment] = []
        for segment in segments.dropFirst() {
            if segment.start - current.end <= gap {
                current.end = segment.end
            } else {
                result.append(current)
                current = segment
            }
        }
        result.append(current)
        return result
    }
}

/// Bridges the complete algorithm-optimization detection pipeline to the
/// AppKit/Mojave interface. The modern engine returns several candidate
/// layouts; its top-ranked candidate becomes the legacy canvas' crop list.
enum LegacyAutomaticDetector {
    static var isExternalDetectorAvailable: Bool {
        let detector = ExternalDetector()
        return detector.scriptURL != nil && FileManager.default.isExecutableFile(atPath: detector.pythonPath)
    }

    static func detect(url: URL, algorithmMode: CropAlgorithmMode) -> [LegacyCrop] {
        var settings = CropSettings()
        settings.businessProfile = .filmScan
        settings.algorithmMode = algorithmMode
        settings.top = 0
        settings.bottom = 0
        settings.left = 0
        settings.right = 0
        // detectCropRegions (not raw candidates) so the hybrid neural border
        // trim ("no black border") applies, same as the modern app's export path.
        let regions = ImageProcessor().detectCropRegions(for: url, settings: settings)
        return regions
            .filter { $0.rect.width > 0.01 && $0.rect.height > 0.01 }
            .sorted {
                if abs($0.rect.minY - $1.rect.minY) > 0.045 { return $0.rect.minY < $1.rect.minY }
                return $0.rect.minX < $1.rect.minX
            }
            .map { LegacyCrop(rect: $0.rect.normalized, angle: CGFloat($0.angle)) }
    }
}

private struct IntSegment {
    var start: Int
    var end: Int
    var size: Int { end - start }
    var mid: Int { (start + end) / 2 }
}

enum LegacyExporter {
    static func export(url: URL, crops: [LegacyCrop], directory: URL, format: LegacyExportFormat) -> [URL] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { return [] }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var next = nextIndex(directory: directory, ext: format.rawValue)
        var outputs: [URL] = []
        for crop in crops {
            let rect = pixelCropRect(from: crop, imageWidth: image.width, imageHeight: image.height)
            guard let cropped = image.cropping(to: rect) else { continue }
            let out = directory.appendingPathComponent(String(format: "%02d.%@", next, format.rawValue))
            next += 1
            let ok = format == .tif ? writeTIFF(cropped, url: out, props: props) : writeJPEG(cropped, url: out)
            if ok { outputs.append(out) }
        }
        return outputs
    }

    private static func pixelCropRect(from crop: LegacyCrop, imageWidth: Int, imageHeight: Int) -> CGRect {
        let raw = crop.angle == 0 ? crop.rect.normalized : rotatedBoundingRect(crop).normalized
        let normalized = sourceCropRect(for: raw, imageWidth: imageWidth, imageHeight: imageHeight)
        let imageWidth = CGFloat(imageWidth)
        let imageHeight = CGFloat(imageHeight)
        let x = floor(normalized.minX * imageWidth)
        let y = floor((1 - normalized.maxY) * imageHeight)
        let width = ceil(normalized.width * imageWidth)
        let height = ceil(normalized.height * imageHeight)
        return CGRect(
            x: min(max(x, 0), imageWidth - 1),
            y: min(max(y, 0), imageHeight - 1),
            width: min(max(width, 1), imageWidth - min(max(x, 0), imageWidth - 1)),
            height: min(max(height, 1), imageHeight - min(max(y, 0), imageHeight - 1))
        ).integral
    }

    private static func sourceCropRect(for rect: CGRect, imageWidth: Int, imageHeight: Int) -> CGRect {
        let crop = rect.normalized
        let sourceAspect = CGFloat(imageHeight) / max(CGFloat(imageWidth), 1)
        let cropAspect = crop.height / max(crop.width, 0.0001)

        if sourceAspect > 2.5,
           cropAspect > 2.5,
           crop.width < 0.35,
           crop.height > 0.55 {
            return CGRect(
                x: 1 - crop.maxY,
                y: crop.minX,
                width: crop.height,
                height: crop.width
            ).normalized
        }

        return crop
    }

    private static func rotatedBoundingRect(_ crop: LegacyCrop) -> CGRect {
        let rect = crop.rect.normalized
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ].map { point -> CGPoint in
            let angle = crop.angle * .pi / 180
            let dx = point.x - center.x
            let dy = point.y - center.y
            return CGPoint(
                x: center.x + dx * cos(angle) - dy * sin(angle),
                y: center.y + dx * sin(angle) + dy * cos(angle)
            )
        }
        let minX = corners.map(\.x).min() ?? rect.minX
        let maxX = corners.map(\.x).max() ?? rect.maxX
        let minY = corners.map(\.y).min() ?? rect.minY
        let maxY = corners.map(\.y).max() ?? rect.maxY
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func nextIndex(directory: URL, ext: String) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return (files.compactMap { $0.pathExtension.lowercased() == ext ? Int($0.deletingPathExtension().lastPathComponent) : nil }.max() ?? 0) + 1
    }

    private static func writeTIFF(_ image: CGImage, url: URL, props: [CFString: Any]?) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil) else { return false }
        var outProps: [CFString: Any] = [kCGImagePropertyDepth: image.bitsPerComponent]
        if let props {
            for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight, kCGImagePropertyTIFFDictionary, kCGImagePropertyExifDictionary] {
                if let value = props[key] { outProps[key] = value }
            }
        }
        CGImageDestinationAddImage(dest, image, outProps as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    private static func writeJPEG(_ image: CGImage, url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.94] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}

private extension CGRect {
    var normalized: CGRect {
        let width = min(max(size.width, 0.01), 0.98)
        let height = min(max(size.height, 0.01), 0.98)
        let x = min(max(origin.x, 0), 1 - width)
        let y = min(max(origin.y, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private extension Array where Element == LegacyCrop {
    func sortedForReadingOrder() -> [LegacyCrop] {
        sorted {
            if abs($0.rect.minY - $1.rect.minY) > 0.045 { return $0.rect.minY < $1.rect.minY }
            return $0.rect.minX < $1.rect.minX
        }
    }
}

private extension Array where Element == CGRect {
    func sortedForReadingOrder() -> [CGRect] {
        sorted {
            if abs($0.minY - $1.minY) > 0.045 { return $0.minY < $1.minY }
            return $0.minX < $1.minX
        }
    }
}

LegacyLaunchLog.write("process started")
let app = NSApplication.shared
let delegate = LegacyAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
LegacyLaunchLog.write("before app.run")
app.run()
LegacyLaunchLog.write("app.run returned")
