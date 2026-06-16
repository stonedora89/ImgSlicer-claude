import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppStore: ObservableObject {
    @Published var tasks: [FolderTask] = []
    @Published var selectedTaskID: FolderTask.ID?
    @Published var selectedPhotoID: PhotoItem.ID?
    @Published var selectedCropRegionID: CropRegion.ID?
    @Published var settings = CropSettings()
    @Published var lastImportSummary: ImportSummary?
    @Published var isDropTargeted = false
    @Published var logMessage = "导入文件或文件夹后，系统会递归识别图片并建立独立任务。"
    @Published var logSubMessage = "原图只读，输出写入新的 ImgSlicer_Output 目录。"

    private let scanner = FolderScanner()
    private let processor = ImageProcessor()
    private let editStore = CropEditStore()
    private let sampleLibrary = SampleLibrary()
    private var processingTask: Task<Void, Never>?
    private var locatingTask: Task<Void, Never>?
    private let maxConcurrentTasks = 3
    private let prefetchForwardCount = 10
    private let prefetchBackwardCount = 2
    private var lastMarginValues = MarginValues()

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

    var canApplyCurrentCropToFolder: Bool {
        guard let task = selectedTask,
              let photo = selectedPhoto else { return false }
        return task.photos.count > 1 && !photo.cropRegions.isEmpty
    }

    var canRetileSelectedPhotoFromTemplate: Bool {
        guard let photo = selectedPhoto else { return false }
        return photo.cropRegions.contains { $0.rect.width > 0.02 && $0.rect.height > 0.02 }
    }

    var recognitionMarginReference: CropMarginReference? {
        guard let photo = selectedPhoto else { return nil }
        let selectedCandidate = photo.selectedCandidateID.flatMap { candidateID in
            photo.cropCandidates.first { $0.id == candidateID }
        } ?? photo.cropCandidates.first

        if let selectedCandidate, let reference = marginReference(regions: selectedCandidate.regions, source: "识别框") {
            return reference
        }
        return marginReference(regions: photo.cropRegions, source: photo.isManual ? "手动框" : "当前框")
    }

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .folder]
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
            return
        }

        let startIndex = tasks.count
        tasks.append(contentsOf: imported)
        selectedTaskID = selectedTaskID ?? imported.first?.id
        selectedPhotoID = selectedPhotoID ?? imported.first?.photos.first?.id
        lastImportSummary = ImportSummary(folderCount: totalFolders, subfolderCount: totalSubfolders, imageCount: totalImages)
        logMessage = "已识别 \(totalFolders) 个文件夹、\(totalSubfolders) 个子文件夹、\(totalImages) 张图片。"
        logSubMessage = "正在优先识别当前与后续照片。"
        scheduleLocator(taskIndexes: Array(startIndex..<tasks.count), priorityTaskIndex: startIndex, priorityPhotoIndex: 0)
    }

    @available(*, deprecated, renamed: "pickFiles")
    func pickFolders() {
        pickFiles()
    }

    @available(*, deprecated, renamed: "importItems")
    func importFolders(_ urls: [URL]) {
        importItems(urls)
    }

    func startProcessing() {
        saveCurrentPhotoIfNeeded()
        processingTask?.cancel()
        processingTask = Task { [weak self] in
            await self?.runQueue()
        }
    }

    func clearFinishedAndIdle() {
        tasks.removeAll { task in
            task.status == .done || (task.status == .waiting && task.processedCount == 0)
        }
        selectedTaskID = tasks.first?.id
        selectedPhotoID = tasks.first?.photos.first?.id
    }

    func openFolder(for taskID: FolderTask.ID) {
        guard let task = tasks.first(where: { $0.id == taskID }) else { return }
        let folderURL = task.status == .done ? outputFolderURL(for: task) : task.rootURL
        guard FileManager.default.fileExists(atPath: folderURL.path) else {
            logMessage = task.status == .done ? "未找到输出文件夹。" : "未找到原始文件夹。"
            logSubMessage = folderURL.path
            return
        }
        NSWorkspace.shared.open(folderURL)
    }

    func selectTask(_ taskID: FolderTask.ID) {
        saveCurrentPhotoIfNeeded()
        selectedTaskID = taskID
        selectedPhotoID = tasks.first(where: { $0.id == taskID })?.photos.first?.id
        selectedCropRegionID = nil
        scheduleLocatorAroundSelection()
    }

    func selectPhoto(_ photoID: PhotoItem.ID) {
        saveCurrentPhotoIfNeeded()
        selectedPhotoID = photoID
        selectedCropRegionID = nil
        scheduleLocatorAroundSelection()
    }

    func selectPreviousPhoto() {
        guard let indexes = selectedIndexes() else { return }
        let photos = tasks[indexes.task].photos
        guard !photos.isEmpty else { return }
        savePhotoIfNeeded(taskIndex: indexes.task, photoIndex: indexes.photo)
        let previousIndex = max(0, indexes.photo - 1)
        selectedPhotoID = photos[previousIndex].id
        selectedCropRegionID = nil
        scheduleLocatorAroundSelection()
    }

    func selectNextPhoto() {
        guard let indexes = selectedIndexes() else { return }
        let photos = tasks[indexes.task].photos
        guard !photos.isEmpty else { return }
        savePhotoIfNeeded(taskIndex: indexes.task, photoIndex: indexes.photo)
        let nextIndex = min(photos.count - 1, indexes.photo + 1)
        selectedPhotoID = photos[nextIndex].id
        selectedCropRegionID = nil
        scheduleLocatorAroundSelection()
    }

    func selectCropRegion(_ regionID: CropRegion.ID) {
        selectedCropRegionID = regionID
    }

    func updateSelectedCrop(regionID: CropRegion.ID, rect: CGRect, manual: Bool = true) {
        guard let indexes = selectedIndexes() else { return }
        guard let regionIndex = tasks[indexes.task].photos[indexes.photo].cropRegions.firstIndex(where: { $0.id == regionID }) else { return }
        selectedCropRegionID = regionID
        tasks[indexes.task].photos[indexes.photo].cropRegions[regionIndex].rect = rect.normalizedCropRect
        tasks[indexes.task].photos[indexes.photo].cropRegions[regionIndex].isManual = manual
        tasks[indexes.task].photos[indexes.photo].isManual = manual
        tasks[indexes.task].photos[indexes.photo].status = manual ? .manual : tasks[indexes.task].photos[indexes.photo].status
        tasks[indexes.task].status = .needsReview
        tasks[indexes.task].detail = "已保存人工微调结果"
        editStore.save(photo: tasks[indexes.task].photos[indexes.photo], in: tasks[indexes.task])
        saveSampleProfileIfPossible(taskIndex: indexes.task, photoIndex: indexes.photo)
        logMessage = "已更新裁切框，人工结果会优先保留。"
        logSubMessage = "\(tasks[indexes.task].photos[indexes.photo].name) · 手动微调已作为参考样本"
    }

    func addCropRegionToSelectedPhoto() {
        guard let indexes = selectedIndexes() else { return }
        let regions = tasks[indexes.task].photos[indexes.photo].cropRegions
        let nextRect = newRegionRect(after: regions.last?.rect)
        let newRegion = CropRegion(index: regions.count + 1, rect: nextRect, isManual: true)
        tasks[indexes.task].photos[indexes.photo].cropRegions.append(newRegion)
        selectedCropRegionID = newRegion.id
        markSelectedPhotoManual(taskIndex: indexes.task, photoIndex: indexes.photo, detail: "已新增标准框")
        logMessage = "已新增一个可拖动标准框。"
        logSubMessage = "拖准后可作为模板重铺当前图片。"
    }

    func deleteSelectedCrop(regionID: CropRegion.ID) {
        guard let indexes = selectedIndexes() else { return }
        guard tasks[indexes.task].photos[indexes.photo].cropRegions.count > 1 else {
            logMessage = "至少需要保留一个裁切框。"
            logSubMessage = "可以拖动当前框调整到正确位置。"
            return
        }
        tasks[indexes.task].photos[indexes.photo].cropRegions.removeAll { $0.id == regionID }
        reindexRegions(taskIndex: indexes.task, photoIndex: indexes.photo)
        selectedCropRegionID = tasks[indexes.task].photos[indexes.photo].cropRegions.first?.id
        markSelectedPhotoManual(taskIndex: indexes.task, photoIndex: indexes.photo, detail: "已删除多余裁切框")
        logMessage = "已删除多余裁切框。"
        logSubMessage = "\(tasks[indexes.task].photos[indexes.photo].name) · 已重新编号"
    }

    func applySelectedCandidate(_ candidateID: CropCandidate.ID) {
        guard let indexes = selectedIndexes(),
              let candidate = tasks[indexes.task].photos[indexes.photo].cropCandidates.first(where: { $0.id == candidateID }) else { return }
        applyCandidate(candidate, taskIndex: indexes.task, photoIndex: indexes.photo)
    }

    func reapplySelectedCandidateMargins() {
        defer { lastMarginValues = MarginValues(settings: settings) }
        guard let indexes = selectedIndexes() else { return }

        if !tasks[indexes.task].photos[indexes.photo].isManual,
           let candidateID = tasks[indexes.task].photos[indexes.photo].selectedCandidateID,
           let candidate = tasks[indexes.task].photos[indexes.photo].cropCandidates.first(where: { $0.id == candidateID }) {
            tasks[indexes.task].photos[indexes.photo].cropRegions = candidate.adjustedRegions(settings: settings)
            editStore.save(photo: tasks[indexes.task].photos[indexes.photo], in: tasks[indexes.task])
            logMessage = "已按当前边距更新自动裁切框。"
            logSubMessage = "\(candidate.title) · 上下左右边距已应用"
            return
        }

        let delta = MarginValues(settings: settings).delta(from: lastMarginValues)
        guard delta.hasChange else { return }
        tasks[indexes.task].photos[indexes.photo].cropRegions = tasks[indexes.task].photos[indexes.photo].cropRegions.map { region in
            CropRegion(
                id: region.id,
                index: region.index,
                rect: region.rect.expanded(
                    top: delta.top / 2000,
                    bottom: delta.bottom / 2000,
                    left: delta.left / 2000,
                    right: delta.right / 2000
                ).normalizedCropRect,
                isManual: true
            )
        }
        tasks[indexes.task].photos[indexes.photo].isManual = true
        tasks[indexes.task].photos[indexes.photo].status = .manual
        tasks[indexes.task].status = .needsReview
        tasks[indexes.task].detail = "已按边距微调当前裁切框"
        editStore.save(photo: tasks[indexes.task].photos[indexes.photo], in: tasks[indexes.task])
        saveSampleProfileIfPossible(taskIndex: indexes.task, photoIndex: indexes.photo)
        logMessage = "已按当前边距微调裁切框。"
        logSubMessage = "当前图已保存为手动调整结果"
    }

    func saveSelectedSampleProfile() {
        guard let indexes = selectedIndexes() else { return }
        let task = tasks[indexes.task]
        let photo = task.photos[indexes.photo]
        guard let profile = sampleLibrary.makeProfile(photo: photo, layout: settings.businessProfile) else {
            logMessage = "当前图片还没有可保存的标准样本。"
            logSubMessage = "先选中并调整一个准确裁切框，再保存为样本。"
            return
        }
        sampleLibrary.save(profile: profile, rootURL: task.rootURL)
        tasks[indexes.task].detail = "已保存识别样本"
        logMessage = "已保存样本：\(profile.regionCount) 个参考框。"
        logSubMessage = "同文件夹后续识别会优先参考宽高、比例、面积和边缘特征。"
    }

    func redetectSelectedPhoto() {
        guard let indexes = selectedIndexes() else { return }
        let photoURL = tasks[indexes.task].photos[indexes.photo].url
        let taskID = tasks[indexes.task].id
        let photoID = tasks[indexes.task].photos[indexes.photo].id
        let currentSettings = settings
        let sampleProfiles = sampleLibrary.load(rootURL: tasks[indexes.task].rootURL)
        tasks[indexes.task].photos[indexes.photo].status = .locating
        tasks[indexes.task].photos[indexes.photo].isManual = false
        tasks[indexes.task].detail = "正在重新识别当前图片"
        logMessage = "正在重新生成自动效果。"
        logSubMessage = tasks[indexes.task].photos[indexes.photo].name

        Task { [weak self, processor, currentSettings, photoURL, taskID, photoID, sampleProfiles] in
            let candidates = await Task.detached {
                processor.detectCropCandidates(for: photoURL, settings: currentSettings, sampleProfiles: sampleProfiles)
            }.value
            self?.applyDetectionCandidates(candidates, taskID: taskID, photoID: photoID)
        }
    }

    func smartRedetectSelectedPhoto() {
        guard let indexes = selectedIndexes() else { return }
        if selectedManualTemplateRegion(taskIndex: indexes.task, photoIndex: indexes.photo) != nil {
            saveSampleProfileIfPossible(taskIndex: indexes.task, photoIndex: indexes.photo)
            retileSelectedPhotoFromTemplate()
        } else {
            redetectSelectedPhoto()
        }
    }

    func applyCurrentCropToSelectedFolder() {
        guard let indexes = selectedIndexes(),
              !tasks[indexes.task].photos[indexes.photo].cropRegions.isEmpty,
              let template = selectedTemplateRegion(taskIndex: indexes.task, photoIndex: indexes.photo)?.rect.normalizedCropRect else { return }

        // Use the adjusted sample as a SIZE reference: re-detect every other
        // image on its own, then calibrate each detected box's edges by the
        // sample's offset. This fits the per-image content while matching the
        // sample's framing — instead of copying the sample's box layout/count
        // verbatim onto images it does not fit.
        let taskIndex = indexes.task
        let taskID = tasks[taskIndex].id
        let sourceID = tasks[taskIndex].photos[indexes.photo].id
        let currentSettings = settings
        let sampleProfiles = sampleLibrary.load(rootURL: tasks[taskIndex].rootURL)

        let targets: [(id: PhotoItem.ID, url: URL)] = tasks[taskIndex].photos.compactMap { photo in
            (photo.id == sourceID || photo.isManual) ? nil : (id: photo.id, url: photo.url)
        }
        guard !targets.isEmpty else {
            logMessage = "没有需要校准的图片（其它图片都已手动调整）。"
            return
        }

        let targetIDs = Set(targets.map(\.id))
        for photoIndex in tasks[taskIndex].photos.indices where targetIDs.contains(tasks[taskIndex].photos[photoIndex].id) {
            tasks[taskIndex].photos[photoIndex].status = .locating
        }
        tasks[taskIndex].detail = "正在按样图尺寸校准整个文件夹"
        logMessage = "正在按样图框尺寸重新识别文件夹内 \(targets.count) 张图片。"
        logSubMessage = "每张图各自识别，再按样图边缘统一校准尺寸。"

        Task { [weak self, processor, currentSettings, sampleProfiles, targets, template, taskID] in
            for target in targets {
                let detected = await Task.detached {
                    processor.detectCropCandidates(for: target.url, settings: currentSettings, sampleProfiles: sampleProfiles).first?.regions ?? []
                }.value
                self?.applyFolderTemplate(detectedRegions: detected, template: template, taskID: taskID, photoID: target.id)
            }
            self?.finishFolderTemplateApply(taskID: taskID, count: targets.count)
        }
    }

    private func applyFolderTemplate(detectedRegions: [CropRegion], template: CGRect, taskID: FolderTask.ID, photoID: PhotoItem.ID) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }),
              let photoIndex = tasks[taskIndex].photos.firstIndex(where: { $0.id == photoID }) else { return }

        let regions = detectedRegions.count > 1
            ? relativeTemplateRegions(from: detectedRegions, template: template)
            : tiledRegions(anchor: template)
        tasks[taskIndex].photos[photoIndex].cropRegions = regions
        tasks[taskIndex].photos[photoIndex].isManual = true
        tasks[taskIndex].photos[photoIndex].status = .manual
        tasks[taskIndex].photos[photoIndex].selectedCandidateID = nil
        editStore.save(photo: tasks[taskIndex].photos[photoIndex], in: tasks[taskIndex])
    }

    private func finishFolderTemplateApply(taskID: FolderTask.ID, count: Int) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[taskIndex].status = .needsReview
        tasks[taskIndex].detail = "已按样图尺寸校准整个文件夹"
        editStore.save(photos: tasks[taskIndex].photos, in: tasks[taskIndex])
        logMessage = "已按样图尺寸重新识别并校准 \(count) 张图片。"
        logSubMessage = "每张图各自识别后按样图边缘统一校准，可继续微调。"
    }

    func retileSelectedPhotoFromTemplate() {
        guard let indexes = selectedIndexes(),
              let template = selectedTemplateRegion(taskIndex: indexes.task, photoIndex: indexes.photo)?.rect.normalizedCropRect else { return }

        let photoURL = tasks[indexes.task].photos[indexes.photo].url
        let taskID = tasks[indexes.task].id
        let photoID = tasks[indexes.task].photos[indexes.photo].id
        let currentSettings = settings
        tasks[indexes.task].photos[indexes.photo].status = .locating
        tasks[indexes.task].detail = "正在按标准框校准当前画布"
        logMessage = "正在应用标准框到当前画布。"
        logSubMessage = "使用选中框校准自动识别到的每个边缘。"

        Task { [weak self, processor, photoURL, taskID, photoID, template, currentSettings] in
            let detected = await Task.detached {
                processor.detectCropCandidates(for: photoURL, settings: currentSettings).first?.regions ?? []
            }.value
            self?.applyTemplateRetile(
                detectedRegions: detected,
                template: template,
                taskID: taskID,
                photoID: photoID
            )
        }
    }

    private func locateInitialCrops(taskIndexes: [Int]) {
        scheduleLocator(taskIndexes: taskIndexes, priorityTaskIndex: taskIndexes.first, priorityPhotoIndex: 0)
    }

    private func scheduleLocatorAroundSelection() {
        guard let indexes = selectedIndexes() else { return }
        scheduleLocator(taskIndexes: Array(tasks.indices), priorityTaskIndex: indexes.task, priorityPhotoIndex: indexes.photo)
    }

    private func scheduleLocator(taskIndexes: [Int], priorityTaskIndex: Int?, priorityPhotoIndex: Int?) {
        locatingTask?.cancel()
        resetInterruptedLocatingStates()
        locatingTask = Task { [weak self] in
            await self?.runLocator(taskIndexes: taskIndexes, priorityTaskIndex: priorityTaskIndex, priorityPhotoIndex: priorityPhotoIndex)
        }
    }

    private func locateSelectedPhotoIfNeeded() {
        guard let indexes = selectedIndexes(),
              tasks[indexes.task].photos[indexes.photo].status == .pending else { return }
        scheduleLocator(taskIndexes: [indexes.task], priorityTaskIndex: indexes.task, priorityPhotoIndex: indexes.photo)
    }

    private func resetInterruptedLocatingStates() {
        for taskIndex in tasks.indices {
            for photoIndex in tasks[taskIndex].photos.indices where tasks[taskIndex].photos[photoIndex].status == .locating {
                tasks[taskIndex].photos[photoIndex].status = .pending
            }
        }
    }

    private func runLocator(taskIndexes: [Int], priorityTaskIndex: Int?, priorityPhotoIndex: Int?) async {
        let validIndexes = taskIndexes.filter { tasks.indices.contains($0) }
        guard !validIndexes.isEmpty else { return }

        let currentSettings = settings
        let jobs = locatorJobs(taskIndexes: validIndexes, priorityTaskIndex: priorityTaskIndex, priorityPhotoIndex: priorityPhotoIndex)
        guard !jobs.isEmpty else { return }

        for job in jobs {
            if tasks.indices.contains(job.taskIndex) {
                tasks[job.taskIndex].detail = "正在预识别当前与后续照片"
                for photo in job.photos {
                    if let photoIndex = tasks[job.taskIndex].photos.firstIndex(where: { $0.id == photo.id }),
                       tasks[job.taskIndex].photos[photoIndex].status == .pending {
                        tasks[job.taskIndex].photos[photoIndex].status = .locating
                    }
                }
            }
        }

        for job in jobs {
            if Task.isCancelled { break }
            for photo in job.photos {
                if Task.isCancelled { break }
                let sampleProfiles = sampleLibrary.load(rootURL: tasks[job.taskIndex].rootURL)
                let results = await processor.locate(photos: [photo], settings: currentSettings, sampleProfiles: sampleProfiles)
                for result in results {
                    updateTaskFromLocator(taskIndex: job.taskIndex, photoURL: result.photoURL, regions: result.regions, candidates: result.candidates)
                }
            }
            if tasks.indices.contains(job.taskIndex), tasks[job.taskIndex].status == .waiting {
                let remaining = tasks[job.taskIndex].photos.filter { $0.status == .pending || $0.status == .locating }.count
                tasks[job.taskIndex].detail = remaining == 0 ? "已完成全部预识别，等待开始处理" : "已预识别，剩余 \(remaining) 张后台继续"
            }
        }
        if !Task.isCancelled {
            logMessage = "已预识别当前位置附近照片。"
            logSubMessage = "向后审核时，后续照片会优先准备好裁切框。"
        }
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
                      !photos[index].isManual,
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

    private func runQueue() async {
        for index in tasks.indices where tasks[index].status == .waiting {
            tasks[index].detail = "等待空闲处理槽位"
        }

        var pending = tasks.indices.filter { tasks[$0].status == .waiting || tasks[$0].status == .needsReview }
        while !pending.isEmpty, !Task.isCancelled {
            let batch = Array(pending.prefix(maxConcurrentTasks))
            pending.removeFirst(batch.count)
            let currentSettings = settings
            let jobs: [(Int, FolderTask, [SampleProfile])] = batch.map { index in
                let task = tasks[index]
                tasks[index].status = .running
                tasks[index].detail = "后台自动识别与输出"
                return (index, task, sampleLibrary.load(rootURL: task.rootURL))
            }

            await withTaskGroup(of: (Int, [PhotoProcessResult]).self) { group in
                for (index, task, sampleProfiles) in jobs {
                    group.addTask { [processor, currentSettings, sampleProfiles] in
                        (index, await processor.process(task: task, settings: currentSettings, sampleProfiles: sampleProfiles))
                    }
                }

                for await (index, results) in group {
                    for result in results {
                        updateTaskFromProcessor(
                            taskIndex: index,
                            photoURL: result.photoURL,
                            regions: result.regions,
                            candidates: result.candidates,
                            outputs: result.outputURLs,
                            failed: result.failed
                        )
                    }
                    if tasks.indices.contains(index) {
                        tasks[index].status = tasks[index].photos.contains(where: { $0.status == .failed }) ? .needsReview : .done
                        tasks[index].detail = tasks[index].status == .done ? "已输出完成" : "部分图片需人工确认"
                    }
                }
            }
        }
    }

    private func updateTaskFromProcessor(taskIndex: Int, photoURL: URL, regions: [CropRegion], candidates: [CropCandidate], outputs: [URL], failed: Bool) {
        guard tasks.indices.contains(taskIndex),
              let photoIndex = tasks[taskIndex].photos.firstIndex(where: { $0.url == photoURL }) else { return }
        if !tasks[taskIndex].photos[photoIndex].isManual {
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

    private func updateTaskFromLocator(taskIndex: Int, photoURL: URL, regions: [CropRegion]) {
        updateTaskFromLocator(taskIndex: taskIndex, photoURL: photoURL, regions: regions, candidates: [])
    }

    private func updateTaskFromLocator(taskIndex: Int, photoURL: URL, regions: [CropRegion], candidates: [CropCandidate]) {
        guard tasks.indices.contains(taskIndex),
              let photoIndex = tasks[taskIndex].photos.firstIndex(where: { $0.url == photoURL }),
              !tasks[taskIndex].photos[photoIndex].isManual else { return }
        tasks[taskIndex].photos[photoIndex].cropRegions = regions
        if !candidates.isEmpty {
            tasks[taskIndex].photos[photoIndex].cropCandidates = candidates
            tasks[taskIndex].photos[photoIndex].selectedCandidateID = candidates.first?.id
        }
        tasks[taskIndex].photos[photoIndex].status = .located
        tasks[taskIndex].detail = "已定位 \(regions.count) 个裁切区域"
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
        tasks[taskIndex].detail = "已重新生成 \(candidates.count) 个自动效果"
    }

    private func applyCandidate(_ candidate: CropCandidate, taskIndex: Int, photoIndex: Int) {
        tasks[taskIndex].photos[photoIndex].cropRegions = candidate.adjustedRegions(settings: settings)
        tasks[taskIndex].photos[photoIndex].selectedCandidateID = candidate.id
        selectedCropRegionID = tasks[taskIndex].photos[photoIndex].cropRegions.first?.id
        tasks[taskIndex].photos[photoIndex].isManual = false
        if tasks[taskIndex].photos[photoIndex].status != .autoDone {
            tasks[taskIndex].photos[photoIndex].status = .located
        }
        tasks[taskIndex].detail = "已应用自动效果：\(candidate.title)"
        editStore.save(photo: tasks[taskIndex].photos[photoIndex], in: tasks[taskIndex])
        logMessage = "已应用 \(candidate.title)。"
        logSubMessage = "\(candidate.detail) · 可继续微调，切换图片会自动保存"
    }

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
              selected.isManual || tasks[taskIndex].photos[photoIndex].isManual else { return nil }
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
        tasks[taskIndex].photos[photoIndex].isManual = true
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
        let template = template.normalizedCropRect
        let templateCenter = CGPoint(x: template.midX, y: template.midY)
        guard let reference = detectedRegions.min(by: { lhs, rhs in
            squaredDistance(from: lhs.rect.center, to: templateCenter) < squaredDistance(from: rhs.rect.center, to: templateCenter)
        })?.rect.normalizedCropRect else {
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
                let detected = region.rect.normalizedCropRect
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
        return CGRect(x: x, y: y, width: width, height: height).normalizedCropRect
    }

    private func tiledRegions(anchor: CGRect) -> [CropRegion] {
        let width = min(max(anchor.width, 0.01), 0.98)
        let height = min(max(anchor.height, 0.01), 0.98)
        let xPositions = tilePositions(anchorStart: anchor.minX, size: width)
        let yPositions = tilePositions(anchorStart: anchor.minY, size: height)
        var regions: [CropRegion] = []
        for y in yPositions {
            for x in xPositions {
                regions.append(CropRegion(index: regions.count + 1, rect: CGRect(x: x, y: y, width: width, height: height).normalizedCropRect, isManual: true))
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

    private func markSelectedPhotoManual(taskIndex: Int, photoIndex: Int, detail: String) {
        tasks[taskIndex].photos[photoIndex].isManual = true
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
                CropRegion(index: offset + 1, rect: region.rect.normalizedCropRect, isManual: true)
            }
    }

    private func newRegionRect(after rect: CGRect?) -> CGRect {
        guard let rect else {
            return CGRect(x: 0.28, y: 0.28, width: 0.44, height: 0.44)
        }

        let width = min(max(rect.width, 0.12), 0.82)
        let height = min(max(rect.height, 0.12), 0.82)
        var x = rect.minX + min(0.06, max(0.03, width * 0.12))
        var y = rect.minY + min(0.06, max(0.03, height * 0.12))
        if x + width > 1 { x = max(0, 1 - width) }
        if y + height > 1 { y = max(0, 1 - height) }
        return CGRect(x: x, y: y, width: width, height: height).normalizedCropRect
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

    private func selectedIndexes() -> (task: Int, photo: Int)? {
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

    private func marginRect() -> CGRect {
        CGRect(
            x: settings.left / 200,
            y: settings.top / 200,
            width: max(0.1, 1 - (settings.left + settings.right) / 200),
            height: max(0.1, 1 - (settings.top + settings.bottom) / 200)
        ).normalizedCropRect
    }

    private func marginReference(regions: [CropRegion], source: String) -> CropMarginReference? {
        guard let first = regions.first else { return nil }
        let bounds = regions.dropFirst().reduce(first.rect.normalizedCropRect) { partial, region in
            partial.union(region.rect.normalizedCropRect)
        }.normalizedCropRect
        return CropMarginReference(
            source: source,
            top: bounds.minY * 200,
            bottom: (1 - bounds.maxY) * 200,
            left: bounds.minX * 200,
            right: (1 - bounds.maxX) * 200
        )
    }

    private func outputFolderURL(for task: FolderTask) -> URL {
        task.rootURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(task.rootURL.lastPathComponent)_ImgSlicer_Output", isDirectory: true)
    }
}

private struct LocatorJob {
    let taskIndex: Int
    let photos: [PhotoItem]
}

private struct MarginValues {
    var top: Double = 0
    var bottom: Double = 0
    var left: Double = 0
    var right: Double = 0

    init() {}

    init(settings: CropSettings) {
        top = settings.top
        bottom = settings.bottom
        left = settings.left
        right = settings.right
    }

    var hasChange: Bool {
        top != 0 || bottom != 0 || left != 0 || right != 0
    }

    func delta(from old: MarginValues) -> MarginValues {
        MarginValues(top: top - old.top, bottom: bottom - old.bottom, left: left - old.left, right: right - old.right)
    }

    private init(top: Double, bottom: Double, left: Double, right: Double) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    func expanded(top: Double, bottom: Double, left: Double, right: Double) -> CGRect {
        let x = min(max(origin.x - left, 0), 0.95)
        let y = min(max(origin.y - top, 0), 0.95)
        let maxX = min(1, self.maxX + right)
        let maxY = min(1, self.maxY + bottom)
        return CGRect(
            x: x,
            y: y,
            width: min(max(maxX - x, 0.05), 1 - x),
            height: min(max(maxY - y, 0.05), 1 - y)
        )
    }

    var normalizedCropRect: CGRect {
        let x = min(max(origin.x, 0), 0.95)
        let y = min(max(origin.y, 0), 0.95)
        let width = min(max(size.width, 0.05), 1 - x)
        let height = min(max(size.height, 0.05), 1 - y)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
