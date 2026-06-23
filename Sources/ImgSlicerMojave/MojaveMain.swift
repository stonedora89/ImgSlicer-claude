import AppKit
import Foundation

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
        controller = MojaveWindowController()
        controller?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

final class MojaveWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let scanner = FolderScanner()
    private let processor = ImageProcessor()
    private let editStore = CropEditStore()
    private let sampleLibrary = SampleLibrary()
    private var tasks: [FolderTask] = []
    private var rows: [(task: Int, photo: Int)] = []

    private let tableView = NSTableView()
    private let preview = MojavePreviewView()
    private let statusLabel = NSTextField(labelWithString: "瀵煎叆鍥剧墖鎴栨枃浠跺す寮€濮?)
    private let importButton = NSButton(title: "瀵煎叆", target: nil, action: nil)
    private let locateButton = NSButton(title: "閲嶆柊璇嗗埆", target: nil, action: nil)
    private let exportButton = NSButton(title: "璇嗗埆骞跺鍑?, target: nil, action: nil)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ImgSlicer Mojave"
        window.minSize = NSSize(width: 820, height: 520)
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { nil }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.spacing = 8
        importButton.target = self
        importButton.action = #selector(importItems)
        locateButton.target = self
        locateButton.action = #selector(redetectSelected)
        exportButton.target = self
        exportButton.action = #selector(processAll)
        controls.addArrangedSubview(importButton)
        controls.addArrangedSubview(locateButton)
        controls.addArrangedSubview(exportButton)
        controls.addArrangedSubview(statusLabel)

        let body = NSStackView()
        body.orientation = .horizontal
        body.spacing = 10
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("photos"))
        column.title = "鍥剧墖"
        column.width = 250
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 28
        scroll.documentView = tableView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 270).isActive = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        body.addArrangedSubview(scroll)
        body.addArrangedSubview(preview)

        root.addArrangedSubview(controls)
        root.addArrangedSubview(body)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            body.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
        locateButton.isEnabled = false
        exportButton.isEnabled = false
    }

    @objc private func importItems() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedFileTypes = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "gif"]
        guard panel.runModal() == .OK else { return }

        var imported: [FolderTask] = []
        for url in panel.urls {
            if let result = try? scanner.scan(url: url) {
                imported.append(contentsOf: result.tasks.map { editStore.restoredTask($0) })
            }
        }
        tasks = imported
        rebuildRows()
        statusLabel.stringValue = tasks.isEmpty ? "娌℃湁鎵惧埌鏀寔鐨勫浘鐗? : "宸插鍏?\(rows.count) 寮犲浘鐗?
    }

    @objc private func redetectSelected() {
        let row = tableView.selectedRow
        guard rows.indices.contains(row) else { return }
        let index = rows[row]
        let photo = tasks[index.task].photos[index.photo]
        let rootURL = tasks[index.task].rootURL
        editStore.remove(photoRelativePath: photo.relativePath, rootURL: rootURL)
        sampleLibrary.removeProfiles(sourceName: photo.name, rootURL: rootURL)
        setBusy(true, message: "姝ｅ湪浠庡師鍥鹃噸鏂拌瘑鍒€?)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let results = self.processor.locateSynchronously(
                photos: [photo],
                settings: CropSettings(),
                sampleProfiles: self.sampleLibrary.load(rootURL: rootURL)
            )
            DispatchQueue.main.async {
                if let result = results.first {
                    self.tasks[index.task].photos[index.photo].cropRegions = result.regions
                    self.tasks[index.task].photos[index.photo].cropCandidates = result.candidates
                    self.tasks[index.task].photos[index.photo].status = .located
                    self.tasks[index.task].photos[index.photo].hasLocalOverrides = false
                    self.editStore.save(photo: self.tasks[index.task].photos[index.photo], in: self.tasks[index.task])
                    self.showPhoto(at: row)
                    self.statusLabel.stringValue = "閲嶆柊璇嗗埆瀹屾垚锛歕(result.regions.count) 涓尯鍩?
                }
                self.setBusy(false)
            }
        }
    }

    @objc private func processAll() {
        guard !tasks.isEmpty else { return }
        let jobs = tasks
        setBusy(true, message: "姝ｅ湪璇嗗埆骞跺鍑?\(rows.count) 寮犲浘鐗団€?)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var completed: [(Int, [PhotoProcessResult])] = []
            for (index, task) in jobs.enumerated() {
                let profiles = self.sampleLibrary.load(rootURL: task.rootURL)
                completed.append((index, self.processor.processSynchronously(task: task, settings: CropSettings(), sampleProfiles: profiles)))
            }
            DispatchQueue.main.async {
                var outputCount = 0
                for (taskIndex, results) in completed {
                    for result in results {
                        guard let photoIndex = self.tasks[taskIndex].photos.firstIndex(where: { $0.url == result.photoURL }) else { continue }
                        self.tasks[taskIndex].photos[photoIndex].cropRegions = result.regions
                        self.tasks[taskIndex].photos[photoIndex].outputURLs = result.outputURLs
                        self.tasks[taskIndex].photos[photoIndex].status = result.failed ? .failed : .autoDone
                        outputCount += result.outputURLs.count
                    }
                    self.editStore.save(photos: self.tasks[taskIndex].photos, in: self.tasks[taskIndex])
                }
                self.tableView.reloadData()
                if self.tableView.selectedRow >= 0 { self.showPhoto(at: self.tableView.selectedRow) }
                self.statusLabel.stringValue = "瀹屾垚锛氬凡杈撳嚭 \(outputCount) 寮犺鍒囧浘鐗?
                self.setBusy(false)
            }
        }
    }

    private func setBusy(_ busy: Bool, message: String? = nil) {
        importButton.isEnabled = !busy
        locateButton.isEnabled = !busy && !rows.isEmpty
        exportButton.isEnabled = !busy && !rows.isEmpty
        if let message = message { statusLabel.stringValue = message }
    }

    private func rebuildRows() {
        rows = tasks.indices.flatMap { taskIndex in
            tasks[taskIndex].photos.indices.map { (task: taskIndex, photo: $0) }
        }
        tableView.reloadData()
        locateButton.isEnabled = !rows.isEmpty
        exportButton.isEnabled = !rows.isEmpty
        if !rows.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            showPhoto(at: 0)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let index = rows[row]
        let photo = tasks[index.task].photos[index.photo]
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? NSTableCellView()
        if cell.textField == nil {
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6).isActive = true
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor).isActive = true
            cell.textField = label
            cell.identifier = id
        }
        cell.textField?.stringValue = "\(photo.status.rawValue)  \(photo.name)"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showPhoto(at: tableView.selectedRow)
    }

    private func showPhoto(at row: Int) {
        guard rows.indices.contains(row) else { return }
        let index = rows[row]
        let photo = tasks[index.task].photos[index.photo]
        preview.image = NSImage(contentsOf: photo.url)
        preview.regions = photo.cropRegions
        preview.needsDisplay = true
    }
}

final class MojavePreviewView: NSView {
    var image: NSImage?
    var regions: [CropRegion] = []

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        dirtyRect.fill()
        guard let image = image, image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let imageRect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)

        NSColor.systemOrange.setStroke()
        for region in regions {
            let rect = NSRect(
                x: imageRect.minX + region.rect.minX * imageRect.width,
                y: imageRect.maxY - region.rect.maxY * imageRect.height,
                width: region.rect.width * imageRect.width,
                height: region.rect.height * imageRect.height
            )
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 2
            path.stroke()
        }
    }
}

