import AppKit
import Foundation

// GCD port of AppStore for the 10.14 build: Swift concurrency and Combine are
// unavailable there, so @Published becomes an onChange callback and the
// locator/processing tasks become cancellation-token background work. The
// behaviour (import scanning, prioritized pre-locating, processing queue,
// manual-edit persistence, sample profiles) mirrors AppStore.swift — keep the
// two in sync when the modern store changes.

struct MojaveManualRedetectPrompt {
    let photoName: String
    let actionTitle: String
    let message: String
    let action: () -> Void
}

struct MojaveStartProcessingPrompt {
    let waitingCount: Int
    let runningCount: Int
    let doneCount: Int
    let needsReviewCount: Int

    var canStart: Bool { waitingCount > 0 }

    var title: String {
        canStart ? "有 \(waitingCount) 个任务可以开始" : "没有可开始的任务"
    }

    var message: String {
        "等待处理：\(waitingCount) 个\n正在处理：\(runningCount) 个\n已完成：\(doneCount) 个\n需确认：\(needsReviewCount) 个\n\n本次只会启动“等待中”的任务；正在处理、已完成和需确认的任务不会重复处理。"
    }
}

private final class CancellationToken {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

final class MojaveStore {
    var tasks: [FolderTask] = []
    var selectedTaskID: FolderTask.ID?
    var selectedPhotoID: PhotoItem.ID?
    var selectedCropRegionID: CropRegion.ID?
    var isDrawingNewRegion = false
    var settings = CropSettings()
    var lastImportSummary: ImportSummary?
    var logMessage = "导入文件或文件夹后，系统会递归识别图片并建立独立任务。"
    var logSubMessage = "原图只读，输出写入新的 ImgSlicer_Output 目录。"

    /// Fired on the main thread after any state change the UI should reflect.
    var onChange: (() -> Void)?
    /// Fired when an action needs the user to confirm discarding manual edits.
    var onManualRedetectPrompt: ((MojaveManualRedetectPrompt) -> Void)?
    /// Fired when 开始处理 is pressed, with the queue snapshot to confirm.
    var onStartProcessingPrompt: ((MojaveStartProcessingPrompt) -> Void)?

    private let scanner = FolderScanner()
    private let processor = ImageProcessor()
    private let editStore = CropEditStore()
    private let sampleLibrary = SampleLibrary()
    private let locatorQueue = DispatchQueue(label: "imgslicer.mojave.locator", qos: .userInitiated)
    private let processingQueue = DispatchQueue(label: "imgslicer.mojave.processing", qos: .userInitiated)
    private var locatorToken: CancellationToken?
    private var isProcessingQueueRunning = false
    private let prefetchForwardCount = 10
    private let prefetchBackwardCount = 2

    private func notify() {
        onChange?()
    }

    // MARK: - Derived selection state (mirrors AppStore)

    var selectedTask: FolderTask? {
        guard let selectedTaskID else { return tasks.first }
        return tasks.first { $0.id == selectedTaskID } ?? tasks.first
    }

    var selectedPhoto: PhotoItem? {
        guard let task = selectedTask else { return nil }
        if let selectedPhotoID, let photo = task.photos.first(where: { $0.id == selectedPhotoID }) {
            return photo
        }
        return task.photos.first
    }

    var selectedCropRegion: CropRegion? {
        guard let photo = selectedPhoto else { return nil }
        if let selectedCropRegionID, let region = photo.cropRegions.first(where: { $0.id == selectedCropRegionID }) {
            return region
        }
        return photo.cropRegions.first
    }

    var canRestoreSelectedPhotoAutomatic: Bool {
        selectedPhoto?.hasLocalOverrides ?? false
    }

    var canCalibrateSelectedPhotoFromManualFrame: Bool {
        guard let indexes = selectedIndexes() else { return false }
        return selectedManualTemplateRegion(taskIndex: indexes.task, photoIndex: indexes.photo) != nil
    }

    // MARK: - Import

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedFileTypes = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "gif"]
        panel.prompt = "导入"
        panel.message = "选择图片文件或包含图片的文件夹"
        if panel.runModal() == .OK {
            importItems(panel.urls)
        }
    }

    func importItems(_ urls: [URL]) {
        var imported: [FolderTask] = []
        var totalFolders = 0
        var totalSubfolders = 0
        var totalImages = 0

        for url in urls {
            guard let result = try? scanner.scan(url: url), !result.tasks.isEmpty else { continue }
            imported.append(contentsOf: result.tasks.map { editStore.restoredTask($0) })
            totalFolders += result.folderCount
            totalSubfolders += result.subfolderCount
            totalImages += result.imageCount
        }

        guard !imported.isEmpty else {
            logMessage = "没有找到可处理图片。"
            logSubMessage = "支持 jpg、jpeg、png、heic、heif、tiff、bmp、gif。"
            notify()
            return
        }

        let startIndex = tasks.count
        tasks.append(contentsOf: imported)
        selectedTaskID = selectedTaskID ?? imported.first?.id
        selectedPhotoID = selectedPhotoID ?? imported.first?.photos.first?.id
        lastImportSummary = ImportSummary(folderCount: totalFolders, subfolderCount: totalSubfolders, imageCount: totalImages)
        logMessage = "已识别 \(totalFolders) 个文件夹、\(totalSubfolders) 个子文件夹、\(totalImages) 张图片。"
        logSubMessage = "正在优先识别当前与后续照片。"
        notify()
        scheduleLocator(taskIndexes: Array(startIndex..<tasks.count), priorityTaskIndex: startIndex, priorityPhotoIndex: 0)
    }

    func copySelectedOriginalToPasteboard() {
        guard let photo = selectedPhoto else { return }
        copyOriginalToPasteboard(photo)
    }

    func copyOriginalToPasteboard(_ photo: PhotoItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.writeObjects([photo.url as NSURL]) {
            logMessage = "已复制原图"
            logSubMessage = photo.name
        } else {
            logMessage = "复制原图失败"
            logSubMessage = photo.url.path
        }
        notify()
    }

    // MARK: - Processing queue

    func startProcessing() {
        saveCurrentPhotoIfNeeded()
        onStartProcessingPrompt?(processingSummary())
    }

    func confirmStartProcessing() {
        let summary = processingSummary()
        guard summary.canStart else { return }

        logMessage = "已安排 \(summary.waitingCount) 个等待中的任务开始处理。"
        logSubMessage = "跳过 \(summary.runningCount) 个处理中、\(summary.doneCount) 个已完成、\(summary.needsReviewCount) 个需确认任务。"
        for index in tasks.indices where tasks[index].status == .waiting {
            tasks[index].detail = "等待空闲处理槽位"
        }
        notify()

        // A live queue picks up any newly imported waiting tasks after its
        // current batch; never start a second loop.
        guard !isProcessingQueueRunning else { return }
        isProcessingQueueRunning = true
        processNextWaitingTask()
    }

    private func processingSummary() -> MojaveStartProcessingPrompt {
        MojaveStartProcessingPrompt(
            waitingCount: tasks.filter { $0.status == .waiting }.count,
            runningCount: tasks.filter { $0.status == .running }.count,
            doneCount: tasks.filter { $0.status == .done }.count,
            needsReviewCount: tasks.filter { $0.status == .needsReview }.count
        )
    }

    /// Serial task queue: takes the first waiting task, processes it on the
    /// background queue, applies results on main, repeats until none are left.
    private func processNextWaitingTask() {
        guard let index = tasks.firstIndex(where: { $0.status == .waiting }) else {
            isProcessingQueueRunning = false
            return
        }
        tasks[index].status = .running
        tasks[index].detail = "后台自动识别与输出"
        notify()

        let task = tasks[index]
        let currentSettings = settings
        processingQueue.async { [weak self] in
            guard let self else { return }
            let sampleProfiles = self.sampleLibrary.load(rootURL: task.rootURL)
            let results = self.processor.processSynchronously(task: task, settings: currentSettings, sampleProfiles: sampleProfiles)
            DispatchQueue.main.async {
                for result in results {
                    guard let taskIndex = self.tasks.firstIndex(where: { $0.id == task.id }) else { continue }
                    self.updateTaskFromProcessor(
                        taskIndex: taskIndex,
                        photoURL: result.photoURL,
                        regions: result.regions,
                        candidates: result.candidates,
                        outputs: result.outputURLs,
                        failed: result.failed
                    )
                }
                if let taskIndex = self.tasks.firstIndex(where: { $0.id == task.id }) {
                    self.tasks[taskIndex].status = self.tasks[taskIndex].photos.contains(where: { $0.status == .failed }) ? .needsReview : .done
                    self.tasks[taskIndex].detail = self.tasks[taskIndex].status == .done ? "已输出完成" : "部分图片需人工确认"
                }
                self.notify()
                self.processNextWaitingTask()
            }
        }
    }

    func clearFinishedAndIdle() {
        tasks.removeAll { $0.status != .running }
        if selectedTask?.status != .running {
            selectedTaskID = tasks.first?.id
            selectedPhotoID = tasks.first?.photos.first?.id
            selectedCropRegionID = nil
        }
        notify()
    }

    func openFolder(for taskID: FolderTask.ID) {
        guard let task = tasks.first(where: { $0.id == taskID }) else { return }
        let folderURL = task.status == .done ? outputFolderURL(for: task) : task.rootURL
        guard FileManager.default.fileExists(atPath: folderURL.path) else {
            logMessage = task.status == .done ? "未找到输出文件夹。" : "未找到原始文件夹。"
            logSubMessage = folderURL.path
            notify()
            return
        }
        NSWorkspace.shared.open(folderURL)
    }

    // MARK: - Selection

    func selectTask(_ taskID: FolderTask.ID) {
        saveCurrentPhotoIfNeeded()
        selectedTaskID = taskID
        selectedPhotoID = tasks.first(where: { $0.id == taskID })?.photos.first?.id
        selectedCropRegionID = nil
        notify()
        scheduleLocatorAroundSelection()
    }

    func selectPhoto(_ photoID: PhotoItem.ID) {
        saveCurrentPhotoIfNeeded()
        selectedPhotoID = photoID
        selectedCropRegionID = nil
        notify()
        scheduleLocatorAroundSelection()
    }

    func selectPreviousPhoto() {
        guard let indexes = selectedIndexes() else { return }
        let photos = tasks[indexes.task].photos
        guard !photos.isEmpty else { return }
        savePhotoIfNeeded(taskIndex: indexes.task, photoIndex: indexes.photo)
        selectedPhotoID = photos[max(0, indexes.photo - 1)].id
        selectedCropRegionID = nil
        notify()
        scheduleLocatorAroundSelection()
    }

    func selectNextPhoto() {
        guard let indexes = selectedIndexes() else { return }
        let photos = tasks[indexes.task].photos
        guard !photos.isEmpty else { return }
        savePhotoIfNeeded(taskIndex: indexes.task, photoIndex: indexes.photo)
        selectedPhotoID = photos[min(photos.count - 1, indexes.photo + 1)].id
        selectedCropRegionID = nil
        notify()
        scheduleLocatorAroundSelection()
    }

    func selectCropRegion(_ regionID: CropRegion.ID) {
        selectedCropRegionID = regionID
        notify()
    }

    // MARK: - Crop editing

    func updateSelectedCrop(regionID: CropRegion.ID, rect: CGRect, manual: Bool = true) {
        guard let indexes = selectedIndexes() else { return }
        guard let regionIndex = tasks[indexes.task].photos[indexes.photo].cropRegions.firstIndex(where: { $0.id == regionID }) else { return }
        selectedCropRegionID = regionID
        tasks[indexes.task].photos[indexes.photo].cropRegions[regionIndex].rect = rect.normalizedCrop
        tasks[indexes.task].photos[indexes.photo].cropRegions[regionIndex].isManual = manual
        if manual {
            tasks[indexes.task].photos[indexes.photo].hasLocalOverrides = true
        }
        tasks[indexes.task].photos[indexes.photo].status = manual ? .manual : tasks[indexes.task].photos[indexes.photo].status
        tasks[indexes.task].status = .needsReview
        tasks[indexes.task].detail = "已保存人工微调结果"
        editStore.save(photo: tasks[indexes.task].photos[indexes.photo], in: tasks[indexes.task])
        let photo = tasks[indexes.task].photos[indexes.photo]
        sampleLibrary.removeProfiles(sourceName: photo.name, rootURL: tasks[indexes.task].rootURL)
        saveSampleProfileIfPossible(taskIndex: indexes.task, photoIndex: indexes.photo)
        logMessage = "已更新裁切框，人工结果会优先保留。"
        logSubMessage = "\(tasks[indexes.task].photos[indexes.photo].name) · 手动微调已作为参考样本"
        notify()
    }

    func updateSelectedCropAngle(regionID: CropRegion.ID, angle: Double) {
        guard let indexes = selectedIndexes() else { return }
        guard let regionIndex = tasks[indexes.task].photos[indexes.photo].cropRegions.firstIndex(where: { $0.id == regionID }) else { return }
        selectedCropRegionID = regionID
        tasks[indexes.task].photos[indexes.photo].cropRegions[regionIndex].angle = angle
        tasks[indexes.task].photos[indexes.photo].cropRegions[regionIndex].isManual = true
        tasks[indexes.task].photos[indexes.photo].hasLocalOverrides = true
        tasks[indexes.task].photos[indexes.photo].status = .manual
        tasks[indexes.task].status = .needsReview
        tasks[indexes.task].detail = "已保存人工旋转结果"
        editStore.save(photo: tasks[indexes.task].photos[indexes.photo], in: tasks[indexes.task])
        saveSampleProfileIfPossible(taskIndex: indexes.task, photoIndex: indexes.photo)
        logMessage = "已更新裁切框角度，人工结果会优先保留。"
        logSubMessage = "\(tasks[indexes.task].photos[indexes.photo].name) · \(String(format: "%.1f", angle))° 手动旋转"
        notify()
    }

    func moveSelectedCropRegion(dxPixels: Double, dyPixels: Double) {
        guard dxPixels != 0 || dyPixels != 0,
              let regionID = selectedCropRegionID,
              let indexes = selectedIndexes() else { return }

        let photo = tasks[indexes.task].photos[indexes.photo]
        guard let regionIndex = photo.cropRegions.firstIndex(where: { $0.id == regionID }) else { return }
        let imageSize = Self.imagePixelSize(url: photo.url)
        let dx = dxPixels / max(imageSize.width, 1)
        let dy = dyPixels / max(imageSize.height, 1)
        var region = photo.cropRegions[regionIndex]
        region.rect = CGRect(
            x: region.rect.minX + dx,
            y: region.rect.minY + dy,
            width: region.rect.width,
            height: region.rect.height
        ).normalizedCrop
        region.isManual = true
        tasks[indexes.task].photos[indexes.photo].cropRegions[regionIndex] = region
        markSelectedPhotoManual(taskIndex: indexes.task, photoIndex: indexes.photo, detail: "已移动选中框")
        logMessage = "已移动选中框。"
        logSubMessage = "水平 \(String(format: "%+.0f", dxPixels)) px · 垂直 \(String(format: "%+.0f", dyPixels)) px"
        notify()
    }

    func moveAllCropRegions(dxPixels: Double, dyPixels: Double) {
        guard dxPixels != 0 || dyPixels != 0,
              let indexes = selectedIndexes() else { return }

        let photo = tasks[indexes.task].photos[indexes.photo]
        let imageSize = Self.imagePixelSize(url: photo.url)
        let dx = dxPixels / max(imageSize.width, 1)
        let dy = dyPixels / max(imageSize.height, 1)

        tasks[indexes.task].photos[indexes.photo].cropRegions = photo.cropRegions.map { region in
            CropRegion(
                id: region.id,
                index: region.index,
                rect: CGRect(
                    x: region.rect.minX + dx,
                    y: region.rect.minY + dy,
                    width: region.rect.width,
                    height: region.rect.height
                ).normalizedCrop,
                angle: region.angle,
                isManual: true
            )
        }
        markSelectedPhotoManual(taskIndex: indexes.task, photoIndex: indexes.photo, detail: "已整体移动当前画布")
        logMessage = "已整体移动当前画布。"
        logSubMessage = "水平 \(String(format: "%+.0f", dxPixels)) px · 垂直 \(String(format: "%+.0f", dyPixels)) px"
        notify()
    }

    private static func imagePixelSize(url: URL) -> CGSize {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Double,
              let height = props[kCGImagePropertyPixelHeight] as? Double else {
            return CGSize(width: 2000, height: 2000)
        }
        return CGSize(width: width, height: height)
    }

    func toggleDrawNewRegion() {
        guard selectedPhoto != nil else { return }
        isDrawingNewRegion.toggle()
        if isDrawingNewRegion {
            logMessage = "拖动画布新建选择框。"
            logSubMessage = "按空格或 Esc 可退出"
        } else {
            logMessage = "已退出框选模式。"
            logSubMessage = ""
        }
        notify()
    }

    func cancelDrawNewRegion() {
        guard isDrawingNewRegion else { return }
        isDrawingNewRegion = false
        logMessage = "已取消框选。"
        logSubMessage = ""
        notify()
    }

    func addCropRegion(rect: CGRect) {
        isDrawingNewRegion = false
        guard let indexes = selectedIndexes() else { return }
        let regions = tasks[indexes.task].photos[indexes.photo].cropRegions
        let newRegion = CropRegion(index: regions.count + 1, rect: rect.normalizedCrop, isManual: true)
        tasks[indexes.task].photos[indexes.photo].cropRegions.append(newRegion)
        selectedCropRegionID = newRegion.id
        markSelectedPhotoManual(taskIndex: indexes.task, photoIndex: indexes.photo, detail: "已框选新增裁切框")
        logMessage = "已按你框选的位置新增裁切框。"
        logSubMessage = "可继续拖动框体或调整四角。"
        notify()
    }

    @discardableResult
    func deleteSelectedCropRegion() -> Bool {
        guard let regionID = selectedCropRegionID else { return false }
        deleteSelectedCrop(regionID: regionID)
        return true
    }

    func deleteSelectedCrop(regionID: CropRegion.ID) {
        guard let indexes = selectedIndexes() else { return }
        tasks[indexes.task].photos[indexes.photo].cropRegions.removeAll { $0.id == regionID }
        reindexRegions(taskIndex: indexes.task, photoIndex: indexes.photo)
        selectedCropRegionID = tasks[indexes.task].photos[indexes.photo].cropRegions.first?.id
        markSelectedPhotoManual(taskIndex: indexes.task, photoIndex: indexes.photo, detail: "已删除多余裁切框")
        if tasks[indexes.task].photos[indexes.photo].cropRegions.isEmpty {
            logMessage = "已删除全部裁切框。"
            logSubMessage = "\(tasks[indexes.task].photos[indexes.photo].name) · 当前画布不会输出裁切结果"
        } else {
            logMessage = "已删除多余裁切框。"
            logSubMessage = "\(tasks[indexes.task].photos[indexes.photo].name) · 已重新编号"
        }
        notify()
    }

    // MARK: - Candidates and margins

    func applySelectedCandidate(_ candidateID: CropCandidate.ID) {
        guardingManualCorrections(
            actionTitle: "使用自动结果（丢弃手动修正）",
            message: "使用自动识别结果会替换当前手动框，并清除这张图片的手动覆盖。"
        ) { [weak self] in
            self?.performApplySelectedCandidate(candidateID)
        }
    }

    private func performApplySelectedCandidate(_ candidateID: CropCandidate.ID) {
        guard let indexes = selectedIndexes(),
              let candidate = tasks[indexes.task].photos[indexes.photo].cropCandidates.first(where: { $0.id == candidateID }) else { return }
        applyCandidate(candidate, taskIndex: indexes.task, photoIndex: indexes.photo)
        notify()
    }

    func reapplySelectedCandidateMargins() {
        guard let taskIndex = selectedTaskIndex() else { return }

        var applied = 0
        for photoIndex in tasks[taskIndex].photos.indices {
            guard !tasks[taskIndex].photos[photoIndex].hasLocalOverrides,
                  let candidateID = tasks[taskIndex].photos[photoIndex].selectedCandidateID,
                  let candidate = tasks[taskIndex].photos[photoIndex].cropCandidates.first(where: { $0.id == candidateID }) else { continue }
            // Re-run the same finalize pass as detection so the new inset
            // pixels take effect from the stored raw candidate boxes.
            let adjusted = processor.finalizeRegions(
                candidate.adjustedRegions(settings: settings),
                url: tasks[taskIndex].photos[photoIndex].url,
                settings: settings
            )
            tasks[taskIndex].photos[photoIndex].autoCropRegions = adjusted
            tasks[taskIndex].photos[photoIndex].cropRegions = adjusted
            editStore.save(photo: tasks[taskIndex].photos[photoIndex], in: tasks[taskIndex])
            applied += 1
        }

        if applied > 0 {
            logMessage = "已按当前内收像素更新自动裁切框。"
            logSubMessage = "本任务 \(applied) 张自动图已重新内收；手动图未改动。"
        } else {
            logMessage = "当前任务没有可应用内收的自动裁切框。"
            logSubMessage = "手动调整过的图片保留本地结果，不随全局内收变化。"
        }
        notify()
    }

    // MARK: - Re-detection

    func redetectSelectedPhoto() {
        guardingManualCorrections(
            actionTitle: "重新识别（丢弃手动修正）",
            message: "重新识别会用新的自动结果替换这些手动框，并清除这张图片的手动覆盖。"
        ) { [weak self] in self?.performRedetectSelectedPhoto() }
    }

    private func guardingManualCorrections(
        actionTitle: String,
        message: String,
        _ action: @escaping () -> Void
    ) {
        guard let indexes = selectedIndexes(),
              tasks[indexes.task].photos[indexes.photo].hasLocalOverrides else {
            action()
            return
        }
        let name = tasks[indexes.task].photos[indexes.photo].name
        onManualRedetectPrompt?(MojaveManualRedetectPrompt(photoName: name, actionTitle: actionTitle, message: message, action: action))
    }

    private func performRedetectSelectedPhoto() {
        guard let indexes = selectedIndexes() else { return }
        locatorToken?.cancel()
        locatorToken = nil

        let photo = tasks[indexes.task].photos[indexes.photo]
        let photoURL = photo.url
        let taskID = tasks[indexes.task].id
        let photoID = photo.id
        let rootURL = tasks[indexes.task].rootURL
        let currentSettings = settings

        // A hard reset for this photo: drop its persisted crops and any sample
        // learned from its previous boxes; other photos' samples still guide.
        editStore.remove(photoRelativePath: photo.relativePath, rootURL: rootURL)
        sampleLibrary.removeProfiles(sourceName: photo.name, rootURL: rootURL)
        let sampleProfiles = sampleLibrary.load(rootURL: rootURL)

        tasks[indexes.task].photos[indexes.photo].cropRegions = []
        tasks[indexes.task].photos[indexes.photo].cropCandidates = []
        tasks[indexes.task].photos[indexes.photo].selectedCandidateID = nil
        tasks[indexes.task].photos[indexes.photo].status = .locating
        tasks[indexes.task].photos[indexes.photo].hasLocalOverrides = false
        selectedCropRegionID = nil
        tasks[indexes.task].detail = "正在重新识别当前图片"
        logMessage = "正在重新生成自动效果。"
        logSubMessage = tasks[indexes.task].photos[indexes.photo].name
        notify()

        locatorQueue.async { [weak self] in
            guard let self else { return }
            let candidates = self.processor.detectCropCandidates(for: photoURL, settings: currentSettings, sampleProfiles: sampleProfiles)
            DispatchQueue.main.async {
                self.applyDetectionCandidates(candidates, taskID: taskID, photoID: photoID)
                self.notify()
            }
        }
    }

    func smartRedetectSelectedPhoto() {
        guard let indexes = selectedIndexes(),
              selectedManualTemplateRegion(taskIndex: indexes.task, photoIndex: indexes.photo) != nil else {
            logMessage = "当前图片还没有可保存的标准样本。"
            logSubMessage = "先选中并调整一个准确裁切框，再保存为样本。"
            notify()
            return
        }
        let photo = tasks[indexes.task].photos[indexes.photo]
        let rootURL = tasks[indexes.task].rootURL
        editStore.remove(photoRelativePath: photo.relativePath, rootURL: rootURL)
        sampleLibrary.removeProfiles(sourceName: photo.name, rootURL: rootURL)
        saveSampleProfileIfPossible(taskIndex: indexes.task, photoIndex: indexes.photo)
        retileSelectedPhotoFromTemplate()
    }

    func retileSelectedPhotoFromTemplate() {
        guard let indexes = selectedIndexes(),
              let template = selectedTemplateRegion(taskIndex: indexes.task, photoIndex: indexes.photo)?.rect.normalizedCrop else { return }

        let photoURL = tasks[indexes.task].photos[indexes.photo].url
        let taskID = tasks[indexes.task].id
        let photoID = tasks[indexes.task].photos[indexes.photo].id
        let currentSettings = settings
        tasks[indexes.task].photos[indexes.photo].status = .locating
        tasks[indexes.task].detail = "正在按标准框校准当前画布"
        logMessage = "正在应用标准框到当前画布。"
        logSubMessage = "使用选中框校准自动识别到的每个边缘。"
        notify()

        locatorQueue.async { [weak self] in
            guard let self else { return }
            let detected = self.processor.detectCropCandidates(for: photoURL, settings: currentSettings).first?.regions ?? []
            DispatchQueue.main.async {
                self.applyTemplateRetile(detectedRegions: detected, template: template, taskID: taskID, photoID: photoID)
                self.notify()
            }
        }
    }

    // MARK: - Background locator

    private func scheduleLocatorAroundSelection() {
        guard let indexes = selectedIndexes() else { return }
        scheduleLocator(taskIndexes: Array(tasks.indices), priorityTaskIndex: indexes.task, priorityPhotoIndex: indexes.photo)
    }

    private func scheduleLocator(taskIndexes: [Int], priorityTaskIndex: Int?, priorityPhotoIndex: Int?) {
        locatorToken?.cancel()
        resetInterruptedLocatingStates()
        let token = CancellationToken()
        locatorToken = token

        // Debounce: rapid photo navigation reschedules constantly; wait for a
        // pause before the heavy pre-detection starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !token.isCancelled else { return }
            let jobs = self.locatorJobs(taskIndexes: taskIndexes, priorityTaskIndex: priorityTaskIndex, priorityPhotoIndex: priorityPhotoIndex)
            guard !jobs.isEmpty else { return }
            for job in jobs where self.tasks.indices.contains(job.taskIndex) {
                self.tasks[job.taskIndex].detail = "正在预识别当前与后续照片"
                for photo in job.photos {
                    if let photoIndex = self.tasks[job.taskIndex].photos.firstIndex(where: { $0.id == photo.id }),
                       self.tasks[job.taskIndex].photos[photoIndex].status == .pending {
                        self.tasks[job.taskIndex].photos[photoIndex].status = .locating
                    }
                }
            }
            self.notify()
            let jobsSnapshot = jobs.map { (taskID: self.tasks[$0.taskIndex].id, rootURL: self.tasks[$0.taskIndex].rootURL, photos: $0.photos) }
            let currentSettings = self.settings
            self.locatorQueue.async { [weak self] in
                self?.runLocator(jobs: jobsSnapshot, settings: currentSettings, token: token)
            }
        }
    }

    private func runLocator(jobs: [(taskID: FolderTask.ID, rootURL: URL, photos: [PhotoItem])], settings: CropSettings, token: CancellationToken) {
        for job in jobs {
            if token.isCancelled { return }
            for photo in job.photos {
                if token.isCancelled { return }
                let sampleProfiles = sampleLibrary.load(rootURL: job.rootURL)
                let results = processor.locateSynchronously(photos: [photo], settings: settings, sampleProfiles: sampleProfiles)
                DispatchQueue.main.async { [weak self] in
                    guard let self, !token.isCancelled else { return }
                    for result in results {
                        if let taskIndex = self.tasks.firstIndex(where: { $0.id == job.taskID }) {
                            self.updateTaskFromLocator(taskIndex: taskIndex, photoURL: result.photoURL, regions: result.regions, candidates: result.candidates)
                        }
                    }
                    self.notify()
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !token.isCancelled,
                      let taskIndex = self.tasks.firstIndex(where: { $0.id == job.taskID }),
                      self.tasks[taskIndex].status == .waiting else { return }
                let remaining = self.tasks[taskIndex].photos.filter { $0.status == .pending || $0.status == .locating }.count
                self.tasks[taskIndex].detail = remaining == 0 ? "已完成全部预识别，等待开始处理" : "已预识别，剩余 \(remaining) 张后台继续"
                self.notify()
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, !token.isCancelled else { return }
            self.logMessage = "已预识别当前位置附近照片。"
            self.logSubMessage = "向后审核时，后续照片会优先准备好裁切框。"
            self.notify()
        }
    }

    private func resetInterruptedLocatingStates() {
        for taskIndex in tasks.indices {
            for photoIndex in tasks[taskIndex].photos.indices
            where tasks[taskIndex].photos[photoIndex].status == .locating {
                tasks[taskIndex].photos[photoIndex].status = .pending
            }
        }
    }

    private struct LocatorJob {
        let taskIndex: Int
        let photos: [PhotoItem]
    }

    private func locatorJobs(taskIndexes: [Int], priorityTaskIndex: Int?, priorityPhotoIndex: Int?) -> [LocatorJob] {
        var jobs: [LocatorJob] = []
        let orderedTaskIndexes = taskIndexes.sorted { lhs, rhs in
            if lhs == priorityTaskIndex { return true }
            if rhs == priorityTaskIndex { return false }
            return lhs < rhs
        }

        for taskIndex in orderedTaskIndexes where tasks.indices.contains(taskIndex) {
            let photos = tasks[taskIndex].photos
            guard !photos.isEmpty else { continue }
            let focus = taskIndex == priorityTaskIndex ? min(max(priorityPhotoIndex ?? 0, 0), photos.count - 1) : 0
            let orderedIndexes = orderedPhotoIndexes(count: photos.count, focus: focus)
            let pendingPhotos = orderedIndexes.compactMap { index -> PhotoItem? in
                guard photos.indices.contains(index),
                      !photos[index].hasLocalOverrides,
                      photos[index].status == .pending || photos[index].status == .locating else { return nil }
                return photos[index]
            }
            if !pendingPhotos.isEmpty {
                jobs.append(LocatorJob(taskIndex: taskIndex, photos: pendingPhotos))
            }
        }
        return jobs
    }

    private func orderedPhotoIndexes(count: Int, focus: Int) -> [Int] {
        guard count > 0 else { return [] }
        var seen = Set<Int>()
        var ordered: [Int] = []

        func appendRange(_ range: ClosedRange<Int>) {
            for index in range where index >= 0 && index < count && !seen.contains(index) {
                seen.insert(index)
                ordered.append(index)
            }
        }

        let forwardEnd = min(count - 1, focus + prefetchForwardCount)
        appendRange(focus...forwardEnd)
        let backwardStart = max(0, focus - prefetchBackwardCount)
        if backwardStart <= focus {
            appendRange(backwardStart...focus)
        }
        if forwardEnd + 1 <= count - 1 {
            appendRange((forwardEnd + 1)...(count - 1))
        }
        if backwardStart > 0 {
            appendRange(0...(backwardStart - 1))
        }
        return ordered
    }

    // MARK: - Task write-backs

    private func updateTaskFromProcessor(taskIndex: Int, photoURL: URL, regions: [CropRegion], candidates: [CropCandidate], outputs: [URL], failed: Bool) {
        guard tasks.indices.contains(taskIndex),
              let photoIndex = tasks[taskIndex].photos.firstIndex(where: { $0.url == photoURL }) else { return }
        tasks[taskIndex].photos[photoIndex].autoCropRegions = regions
        if !tasks[taskIndex].photos[photoIndex].hasLocalOverrides {
            tasks[taskIndex].photos[photoIndex].cropRegions = regions
        }
        if !candidates.isEmpty {
            tasks[taskIndex].photos[photoIndex].cropCandidates = candidates
            tasks[taskIndex].photos[photoIndex].selectedCandidateID = candidates.first?.id
        }
        tasks[taskIndex].photos[photoIndex].status = failed ? .failed : .autoDone
        tasks[taskIndex].photos[photoIndex].outputURLs = outputs
        tasks[taskIndex].processedCount += 1
        tasks[taskIndex].detail = failed ? "识别困难，等待人工确认" : "已处理 \(tasks[taskIndex].processedCount) / \(tasks[taskIndex].imageCount)"
        if selectedTaskID == tasks[taskIndex].id || selectedTaskID == nil {
            logMessage = failed ? "自动识别结果需要确认。" : "已按 \(regions.count) 个裁切区域输出。"
            logSubMessage = tasks[taskIndex].photos[photoIndex].name
        }
    }

    private func updateTaskFromLocator(taskIndex: Int, photoURL: URL, regions: [CropRegion], candidates: [CropCandidate]) {
        guard tasks.indices.contains(taskIndex),
              let photoIndex = tasks[taskIndex].photos.firstIndex(where: { $0.url == photoURL }) else { return }
        tasks[taskIndex].photos[photoIndex].autoCropRegions = regions
        if tasks[taskIndex].photos[photoIndex].hasLocalOverrides {
            editStore.save(photo: tasks[taskIndex].photos[photoIndex], in: tasks[taskIndex])
            return
        }
        tasks[taskIndex].photos[photoIndex].cropRegions = regions
        if !candidates.isEmpty {
            tasks[taskIndex].photos[photoIndex].cropCandidates = candidates
            tasks[taskIndex].photos[photoIndex].selectedCandidateID = candidates.first?.id
        }
        tasks[taskIndex].photos[photoIndex].status = .located
        tasks[taskIndex].detail = "已重新生成 \(candidates.count) 个自动效果"
        if selectedTaskID == tasks[taskIndex].id,
           selectedPhotoID == tasks[taskIndex].photos[photoIndex].id || selectedPhotoID == nil {
            logMessage = "已识别出 \(regions.count) 个可切分照片区域。"
            logSubMessage = "每个编号框都可以单独拖动和调整四角。"
        }
    }

    private func applyDetectionCandidates(_ candidates: [CropCandidate], taskID: FolderTask.ID, photoID: PhotoItem.ID) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }),
              let photoIndex = tasks[taskIndex].photos.firstIndex(where: { $0.id == photoID }),
              let candidate = candidates.first else { return }
        tasks[taskIndex].photos[photoIndex].cropCandidates = candidates
        tasks[taskIndex].photos[photoIndex].selectedCandidateID = candidate.id
        applyCandidate(candidate, taskIndex: taskIndex, photoIndex: photoIndex)
        tasks[taskIndex].detail = "已应用自动效果：\(candidate.title)"
    }

    private func applyCandidate(_ candidate: CropCandidate, taskIndex: Int, photoIndex: Int) {
        let adjusted = candidate.adjustedRegions(settings: settings)
        tasks[taskIndex].photos[photoIndex].autoCropRegions = adjusted
        tasks[taskIndex].photos[photoIndex].cropRegions = adjusted
        tasks[taskIndex].photos[photoIndex].selectedCandidateID = candidate.id
        selectedCropRegionID = tasks[taskIndex].photos[photoIndex].cropRegions.first?.id
        tasks[taskIndex].photos[photoIndex].hasLocalOverrides = false
        if tasks[taskIndex].photos[photoIndex].status != .autoDone {
            tasks[taskIndex].photos[photoIndex].status = .located
        }
        tasks[taskIndex].detail = "已应用自动效果：\(candidate.title)"
        editStore.save(photo: tasks[taskIndex].photos[photoIndex], in: tasks[taskIndex])
        logMessage = "已应用 \(candidate.title)。"
        logSubMessage = "\(candidate.detail) · 可继续微调，切换图片会自动保存"
    }

    // MARK: - Template retile (手动校准)

    private func selectedTemplateRegion(taskIndex: Int, photoIndex: Int) -> CropRegion? {
        let regions = tasks[taskIndex].photos[photoIndex].cropRegions
        if let selectedCropRegionID,
           let selected = regions.first(where: { $0.id == selectedCropRegionID }) {
            return selected
        }
        return regions.first
    }

    private func selectedManualTemplateRegion(taskIndex: Int, photoIndex: Int) -> CropRegion? {
        guard tasks.indices.contains(taskIndex),
              tasks[taskIndex].photos.indices.contains(photoIndex),
              let selectedCropRegionID,
              let selected = tasks[taskIndex].photos[photoIndex].cropRegions.first(where: { $0.id == selectedCropRegionID }),
              selected.isManual else { return nil }
        return selected
    }

    private func applyTemplateRetile(detectedRegions: [CropRegion], template: CGRect, taskID: FolderTask.ID, photoID: PhotoItem.ID) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }),
              let photoIndex = tasks[taskIndex].photos.firstIndex(where: { $0.id == photoID }) else { return }

        let regions: [CropRegion]
        if detectedRegions.count > 1 {
            regions = relativeTemplateRegions(from: detectedRegions, template: template)
        } else {
            regions = tiledRegions(anchor: template)
        }

        tasks[taskIndex].photos[photoIndex].cropRegions = regions
        selectedCropRegionID = regions.first?.id
        tasks[taskIndex].photos[photoIndex].hasLocalOverrides = true
        tasks[taskIndex].photos[photoIndex].status = .manual
        tasks[taskIndex].photos[photoIndex].selectedCandidateID = nil
        tasks[taskIndex].status = .needsReview
        tasks[taskIndex].detail = "已按标准框校准当前画布"
        editStore.save(photo: tasks[taskIndex].photos[photoIndex], in: tasks[taskIndex])
        saveSampleProfileIfPossible(taskIndex: taskIndex, photoIndex: photoIndex)
        logMessage = "已应用标准框到当前画布。"
        logSubMessage = "共生成 \(regions.count) 个框，可继续微调，切换图片会自动保存。"
    }

    private func relativeTemplateRegions(from detectedRegions: [CropRegion], template: CGRect) -> [CropRegion] {
        let template = template.normalizedCrop
        let templateCenter = CGPoint(x: template.midX, y: template.midY)
        guard let reference = detectedRegions.min(by: { lhs, rhs in
            squaredDistance(from: lhs.rect.center, to: templateCenter) < squaredDistance(from: rhs.rect.center, to: templateCenter)
        })?.rect.normalizedCrop else {
            return tiledRegions(anchor: template)
        }

        let leftOffset = template.minX - reference.minX
        let rightOffset = template.maxX - reference.maxX
        let topOffset = template.minY - reference.minY
        let bottomOffset = template.maxY - reference.maxY

        return detectedRegions
            .sorted { lhs, rhs in
                if abs(lhs.rect.minY - rhs.rect.minY) > 0.045 { return lhs.rect.minY < rhs.rect.minY }
                return lhs.rect.minX < rhs.rect.minX
            }
            .enumerated()
            .map { offset, region in
                let detected = region.rect.normalizedCrop
                let minX = detected.minX + leftOffset
                let maxX = detected.maxX + rightOffset
                let minY = detected.minY + topOffset
                let maxY = detected.maxY + bottomOffset
                let rect = clampedRect(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
                return CropRegion(index: offset + 1, rect: rect, isManual: true)
            }
    }

    private func squaredDistance(from lhs: CGPoint, to rhs: CGPoint) -> Double {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private func clampedRect(minX: Double, minY: Double, maxX: Double, maxY: Double) -> CGRect {
        let width = min(max(maxX - minX, 0.01), 0.98)
        let height = min(max(maxY - minY, 0.01), 0.98)
        let x = min(max(minX, 0), 1 - width)
        let y = min(max(minY, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height).normalizedCrop
    }

    private func tiledRegions(anchor: CGRect) -> [CropRegion] {
        let width = min(max(anchor.width, 0.01), 0.98)
        let height = min(max(anchor.height, 0.01), 0.98)
        let xPositions = tilePositions(anchorStart: anchor.minX, size: width)
        let yPositions = tilePositions(anchorStart: anchor.minY, size: height)
        var regions: [CropRegion] = []
        for y in yPositions {
            for x in xPositions {
                regions.append(CropRegion(index: regions.count + 1, rect: CGRect(x: x, y: y, width: width, height: height).normalizedCrop, isManual: true))
            }
        }
        return regions
    }

    private func tilePositions(anchorStart: Double, size: Double) -> [Double] {
        guard size > 0 else { return [0] }
        var positions: [Double] = []
        var value = anchorStart
        while value - size >= -0.001 {
            value -= size
        }
        while value <= 1 - size + 0.001 {
            positions.append(min(max(value, 0), 1 - size))
            value += size
        }
        return Array(Set(positions.map { round($0 * 10000) / 10000 })).sorted()
    }

    // MARK: - Shared helpers

    private func markSelectedPhotoManual(taskIndex: Int, photoIndex: Int, detail: String) {
        tasks[taskIndex].photos[photoIndex].hasLocalOverrides = true
        tasks[taskIndex].photos[photoIndex].status = .manual
        tasks[taskIndex].photos[photoIndex].selectedCandidateID = nil
        tasks[taskIndex].status = .needsReview
        tasks[taskIndex].detail = detail
        editStore.save(photo: tasks[taskIndex].photos[photoIndex], in: tasks[taskIndex])
        saveSampleProfileIfPossible(taskIndex: taskIndex, photoIndex: photoIndex)
    }

    private func saveSampleProfileIfPossible(taskIndex: Int, photoIndex: Int) {
        guard tasks.indices.contains(taskIndex),
              tasks[taskIndex].photos.indices.contains(photoIndex),
              let profile = sampleLibrary.makeProfile(photo: tasks[taskIndex].photos[photoIndex], layout: settings.businessProfile) else { return }
        sampleLibrary.save(profile: profile, rootURL: tasks[taskIndex].rootURL)
    }

    private func reindexRegions(taskIndex: Int, photoIndex: Int) {
        tasks[taskIndex].photos[photoIndex].cropRegions = tasks[taskIndex].photos[photoIndex].cropRegions
            .sorted { lhs, rhs in
                if abs(lhs.rect.minY - rhs.rect.minY) > 0.045 { return lhs.rect.minY < rhs.rect.minY }
                return lhs.rect.minX < rhs.rect.minX
            }
            .enumerated()
            .map { offset, region in
                CropRegion(index: offset + 1, rect: region.rect.normalizedCrop, angle: region.angle, isManual: true)
            }
    }

    private func saveCurrentPhotoIfNeeded() {
        guard let indexes = selectedIndexes() else { return }
        savePhotoIfNeeded(taskIndex: indexes.task, photoIndex: indexes.photo)
    }

    private func savePhotoIfNeeded(taskIndex: Int, photoIndex: Int) {
        guard tasks.indices.contains(taskIndex),
              tasks[taskIndex].photos.indices.contains(photoIndex) else { return }
        let photo = tasks[taskIndex].photos[photoIndex]
        guard photo.status == .located || photo.status == .manual || photo.status == .autoDone else { return }
        editStore.save(photo: photo, in: tasks[taskIndex])
    }

    func selectedIndexes() -> (task: Int, photo: Int)? {
        guard let taskIndex = selectedTaskIndex() else { return nil }
        let photoID = selectedPhotoID ?? tasks[taskIndex].photos.first?.id
        guard let photoID,
              let photoIndex = tasks[taskIndex].photos.firstIndex(where: { $0.id == photoID }) else { return nil }
        return (taskIndex, photoIndex)
    }

    private func selectedTaskIndex() -> Int? {
        let taskID = selectedTaskID ?? tasks.first?.id
        guard let taskID else { return nil }
        return tasks.firstIndex { $0.id == taskID }
    }

    private func outputFolderURL(for task: FolderTask) -> URL {
        task.rootURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(task.rootURL.lastPathComponent)_ImgSlicer_Output", isDirectory: true)
    }
}

extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    /// Same clamping as AppStore's normalizedCropRect (whose twin in
    /// CropEditStore.swift is fileprivate, hence the distinct name).
    var normalizedCrop: CGRect {
        let x = min(max(origin.x, 0), 0.95)
        let y = min(max(origin.y, 0), 0.95)
        let width = min(max(size.width, 0.05), 1 - x)
        let height = min(max(size.height, 0.05), 1 - y)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
