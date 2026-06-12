import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppShell: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            HStack(spacing: 16) {
                QueuePanel()
                    .frame(width: 292)
                PreviewWorkspace()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ParameterPanel()
                    .frame(width: 336)
            }
            .padding(16)
            .frame(maxHeight: .infinity)
            Filmstrip()
                .frame(height: 132)
        }
        .background(AppTheme.background)
        .overlay(DropZoneOverlay())
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left:
                store.selectPreviousPhoto()
            case .right:
                store.selectNextPhoto()
            default:
                break
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $store.isDropTargeted) { providers in
            loadDroppedURLs(providers)
        }
    }

    private func loadDroppedURLs(_ providers: [NSItemProvider]) -> Bool {
        let collector = URLCollector()
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let foundURL: URL?
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    foundURL = url
                } else if let url = item as? URL {
                    foundURL = url
                } else {
                    foundURL = nil
                }
                if let foundURL {
                    collector.append(foundURL)
                }
            }
        }
        group.notify(queue: .main) {
            store.importItems(collector.values)
        }
        return true
    }
}

final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var values: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }
}

struct TopBar: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack {
            BrandLockup()
            Spacer()
            HStack(spacing: 10) {
                Button("导入文件") { store.pickFiles() }
                    .buttonStyle(TopBarButtonStyle())
                    .help("导入图片文件或包含图片的文件夹")
                Button { store.startProcessing() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("开始")
                    }
                }
                    .buttonStyle(StartProcessButtonStyle())
                    .help("按当前裁切框开始批量输出")
            }
        }
        .padding(.leading, 84)
        .padding(.trailing, 18)
        .padding(.top, 17)
        .frame(height: 72, alignment: .topLeading)
        .background(Color(red: 0.095, green: 0.105, blue: 0.125).opacity(0.96))
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.line).frame(height: 1)
        }
    }
}

struct BrandLockup: View {
    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            LogoMark()
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text("ImgSlicer")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.text)
                    .lineLimit(1)
                Text("批量底片切分与边界微调")
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(1)
            }
            .padding(.top, 1)
        }
        .frame(width: 252, height: 38, alignment: .leading)
    }
}

struct QueuePanel: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("任务列表")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    store.clearFinishedAndIdle()
                } label: {
                    Image(systemName: "eraser")
                }
                .buttonStyle(IconButtonStyle())
                .help("清理已完成与未开始任务")
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.line).frame(height: 1) }

            ScrollView {
                LazyVStack(spacing: 10) {
                    if store.tasks.isEmpty {
                        EmptyQueueView()
                    } else {
                        ForEach(store.tasks) { task in
                            FolderTaskRow(task: task, active: task.id == store.selectedTask?.id)
                                .onTapGesture { store.selectTask(task.id) }
                        }
                    }
                }
                .padding(12)
            }
        }
        .panelStyle()
    }
}

struct FolderTaskRow: View {
    @EnvironmentObject private var store: AppStore

    let task: FolderTask
    let active: Bool

    var body: some View {
        VStack(spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(task.status == .done ? AppTheme.green.opacity(0.18) : Color(red: 0.09, green: 0.1, blue: 0.12))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.14)))
                    if task.status == .done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(AppTheme.green)
                    }
                }
                .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 6) {
                    Text(task.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("\(task.imageCount) 张图片 · \(task.detail)\n已处理 \(task.processedCount) / \(task.imageCount)")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(2)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    StatusLabel(status: task.status)
                    Button {
                        store.openFolder(for: task.id)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(IconButtonStyle())
                    .help(task.status == .done ? "打开输出文件夹" : "打开原始文件夹")
                }
            }

            ProgressView(value: task.progress)
                .tint(AppTheme.blue)
                .controlSize(.small)
        }
        .padding(12)
        .background(active ? Color(red: 0.125, green: 0.145, blue: 0.176) : Color(red: 0.115, green: 0.13, blue: 0.155))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(active ? AppTheme.blue.opacity(0.32) : Color.white.opacity(0.05))
        }
    }
}

struct StatusLabel: View {
    let status: TaskStatus

    var color: Color {
        switch status {
        case .waiting: Color(red: 0.82, green: 0.68, blue: 0.47)
        case .running: Color(red: 0.72, green: 0.79, blue: 0.86)
        case .needsReview: Color(red: 0.86, green: 0.68, blue: 0.43)
        case .done: AppTheme.green
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(status.rawValue)
                .font(.system(size: 11))
        }
        .foregroundStyle(color)
        .fixedSize()
    }
}

struct PreviewWorkspace: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                GridBackground()
                if let photo = store.selectedPhoto, let image = NSImage(contentsOf: photo.url) {
                    PhotoCanvas(
                        image: image,
                        regions: photo.cropRegions,
                        selectedRegionID: store.selectedCropRegionID,
                        onDelete: { regionID in
                            store.deleteSelectedCrop(regionID: regionID)
                        },
                        onSelect: { regionID in
                            store.selectCropRegion(regionID)
                        }
                    ) { regionID, rect in
                        store.updateSelectedCrop(regionID: regionID, rect: rect)
                    }
                    .padding(.horizontal, 68)
                    .padding(.vertical, 82)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 42))
                            .foregroundStyle(AppTheme.muted)
                        Text("拖入文件夹或点击导入开始")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppTheme.text)
                    }
                }

                VStack {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("当前图片：\(store.selectedPhoto?.name ?? "未选择")")
                                .font(.system(size: 14, weight: .bold))
                            if let folder = store.selectedTask?.displayName {
                                Text("当前文件夹：\(folder)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(AppTheme.muted)
                            }
                        }
                        Spacer()
                        Text(store.selectedPhoto?.status.rawValue ?? "等待导入")
                            .font(.system(size: 11))
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(Color.black.opacity(0.35))
                            .clipShape(Capsule())
                    }
                    Spacer()
                    ViewerLog()
                }
                .padding(18)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(AppTheme.viewer)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.05)))
    }
}

struct PhotoCanvas: View {
    let image: NSImage
    let regions: [CropRegion]
    let selectedRegionID: CropRegion.ID?
    let onDelete: (CropRegion.ID) -> Void
    let onSelect: (CropRegion.ID) -> Void
    let onCropChange: (CropRegion.ID, CGRect) -> Void

    var body: some View {
        GeometryReader { proxy in
            let imageRect = aspectFitRect(imageSize: image.size, bounds: proxy.size)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipped()
                    .shadow(color: .black.opacity(0.36), radius: 26, y: 18)
                    .frame(width: proxy.size.width, height: proxy.size.height)

                MultiCropOverlay(
                    regions: regions,
                    selectedRegionID: selectedRegionID,
                    onDelete: onDelete,
                    onSelect: onSelect,
                    onChange: onCropChange
                )
                .frame(width: imageRect.width, height: imageRect.height)
                .offset(x: imageRect.minX, y: imageRect.minY)
            }
        }
    }

    private func aspectFitRect(imageSize: CGSize, bounds: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }
}

struct MultiCropOverlay: View {
    let regions: [CropRegion]
    let selectedRegionID: CropRegion.ID?
    let onDelete: (CropRegion.ID) -> Void
    let onSelect: (CropRegion.ID) -> Void
    let onChange: (CropRegion.ID, CGRect) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(regions) { region in
                CropOverlay(region: region, isSelected: region.id == selectedRegionID, onDelete: {
                    onDelete(region.id)
                }, onSelect: {
                    onSelect(region.id)
                }) { rect in
                    onChange(region.id, rect)
                }
            }
        }
    }
}

struct CropOverlay: View {
    let region: CropRegion
    let isSelected: Bool
    let onDelete: () -> Void
    let onSelect: () -> Void
    let onChange: (CGRect) -> Void
    @State private var workingRect: CGRect?

    var body: some View {
        GeometryReader { proxy in
            let current = workingRect ?? region.rect
            let draw = CGRect(
                x: current.minX * proxy.size.width,
                y: current.minY * proxy.size.height,
                width: current.width * proxy.size.width,
                height: current.height * proxy.size.height
            )

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.clear)
                Rectangle()
                    .stroke(activeColor.opacity(isSelected ? 0.95 : 0.78), lineWidth: isSelected ? 3 : 2)
                    .background(Rectangle().fill(Color.black.opacity(0.001)))
                    .frame(width: draw.width, height: draw.height)
                    .offset(x: draw.minX, y: draw.minY)
                    .gesture(dragGesture(in: proxy.size, corner: nil))
                    .onTapGesture { onSelect() }

                Text("\(region.index)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: isSelected ? 26 : 22, height: isSelected ? 26 : 22)
                    .background(activeColor)
                    .clipShape(Circle())
                    .position(x: draw.minX + 13, y: draw.minY + 13)
                    .shadow(color: activeColor.opacity(isSelected ? 0.45 : 0), radius: 8, y: 2)
                    .onTapGesture { onSelect() }

                Button {
                    onDelete()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(CropToolButtonStyle(destructive: true))
                .position(x: draw.maxX - 13, y: draw.minY + 13)
                .help("删除裁切框")

                ForEach(CropCorner.allCases) { corner in
                    Circle()
                        .fill(Color(red: 0.86, green: 0.91, blue: 0.96))
                        .overlay(Circle().stroke(activeColor, lineWidth: isSelected ? 3 : 2))
                        .frame(width: isSelected ? 16 : 14, height: isSelected ? 16 : 14)
                        .position(corner.point(in: draw))
                        .gesture(dragGesture(in: proxy.size, corner: corner))
                }
            }
            .onChange(of: region.rect) { _, newValue in
                workingRect = newValue
            }
        }
    }

    private var activeColor: Color {
        isSelected ? AppTheme.orange : AppTheme.blue
    }

    private func dragGesture(in size: CGSize, corner: CropCorner?) -> some Gesture {
        DragGesture()
            .onChanged { value in
                onSelect()
                if workingRect == nil { workingRect = region.rect }
                let dx = value.translation.width / max(1, size.width)
                let dy = value.translation.height / max(1, size.height)
                var next = region.rect
                if let corner {
                    next = corner.resize(rect: region.rect, dx: dx, dy: dy)
                } else {
                    next.origin.x += dx
                    next.origin.y += dy
                }
                workingRect = next.normalized
            }
            .onEnded { _ in
                if let workingRect {
                    onChange(workingRect.normalized)
                }
            }
    }
}

enum CropCorner: CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { String(describing: self) }

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    func resize(rect: CGRect, dx: Double, dy: Double) -> CGRect {
        var next = rect
        switch self {
        case .topLeft:
            next.origin.x += dx; next.origin.y += dy; next.size.width -= dx; next.size.height -= dy
        case .topRight:
            next.origin.y += dy; next.size.width += dx; next.size.height -= dy
        case .bottomLeft:
            next.origin.x += dx; next.size.width -= dx; next.size.height += dy
        case .bottomRight:
            next.size.width += dx; next.size.height += dy
        }
        return next
    }
}

struct ViewerLog: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(AppTheme.green).frame(width: 6, height: 6)
                    Text("当前操作反馈")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 0.79, green: 0.83, blue: 0.88))
                }
                Text(store.logMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.text)
                Text(store.logSubMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.muted)
            }
            .padding(14)
            .frame(maxWidth: 430, alignment: .leading)
            .background(Color.black.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            Spacer()
            if let summary = store.lastImportSummary {
                VStack(alignment: .leading, spacing: 6) {
                    Text("导入统计")
                        .font(.system(size: 11, weight: .semibold))
                    Text("\(summary.folderCount) 个文件夹 · \(summary.subfolderCount) 个子文件夹\n\(summary.imageCount) 张图片")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.muted)
                }
                .padding(12)
                .frame(width: 220, alignment: .leading)
                .background(Color.black.opacity(0.34))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }
}

struct ParameterPanel: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("参数设置")
                    .font(.system(size: 15, weight: .bold))
                HStack(spacing: 7) {
                    Button {
                        store.addCropRegionToSelectedPhoto()
                    } label: {
                        Image(systemName: "plus.viewfinder")
                    }
                    .buttonStyle(AccentIconButtonStyle(color: AppTheme.orange))
                    .disabled(store.selectedPhoto == nil)
                    .help("添加一个新的裁切框，可在预览区拖动和调整四角")

                    Button {
                        store.smartRedetectSelectedPhoto()
                    } label: {
                        Image(systemName: "wand.and.stars")
                    }
                    .buttonStyle(AccentIconButtonStyle(color: AppTheme.blue))
                    .disabled(store.selectedPhoto == nil)
                    .help("智能重识别：有选中参考框时按实例重识别当前画布，否则重新生成自动候选效果")

                    Button {
                        store.applyCurrentCropToSelectedFolder()
                    } label: {
                        Image(systemName: "rectangle.stack")
                    }
                    .buttonStyle(AccentIconButtonStyle(color: AppTheme.green))
                    .disabled(!store.canApplyCurrentCropToFolder)
                    .help("将当前图片的裁切框应用到当前文件夹内未手动调整的图片")
                }
            }
            .padding(16)
            .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.line).frame(height: 1) }

            ScrollView {
                VStack(spacing: 12) {
                    SettingsGroup("识别模式") {
                        AutoModeSummary()
                    }
                    SettingsGroup("自动效果") {
                        VStack(spacing: 10) {
                            AutoCandidatePicker()
                        }
                    }
                    SettingsGroup("边距设置") {
                        VStack(spacing: 10) {
                            if let reference = store.recognitionMarginReference {
                                RecognitionMarginReferenceView(reference: reference)
                            }
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                MarginField(title: "上边距", value: $store.settings.top)
                                MarginField(title: "下边距", value: $store.settings.bottom)
                                MarginField(title: "左边距", value: $store.settings.left)
                                MarginField(title: "右边距", value: $store.settings.right)
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
        .panelStyle()
        .onChange(of: store.settings.top) { _, _ in store.reapplySelectedCandidateMargins() }
        .onChange(of: store.settings.bottom) { _, _ in store.reapplySelectedCandidateMargins() }
        .onChange(of: store.settings.left) { _, _ in store.reapplySelectedCandidateMargins() }
        .onChange(of: store.settings.right) { _, _ in store.reapplySelectedCandidateMargins() }
        .onChange(of: store.settings.businessProfile) { _, _ in store.redetectSelectedPhoto() }
        .onChange(of: store.settings.preprocessMode) { _, _ in store.redetectSelectedPhoto() }
        .onChange(of: store.settings.algorithmMode) { _, _ in store.redetectSelectedPhoto() }
        .onChange(of: store.settings.orientation) { _, _ in store.redetectSelectedPhoto() }
    }
}

struct AutoCandidatePicker: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("候选效果")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.muted)
                Spacer()
            }

            if let photo = store.selectedPhoto {
                if !photo.cropCandidates.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(photo.cropCandidates) { candidate in
                            Button {
                                store.applySelectedCandidate(candidate.id)
                            } label: {
                                CandidateRow(
                                    icon: photo.selectedCandidateID == candidate.id ? "checkmark.circle.fill" : "circle",
                                    title: candidate.title,
                                    detail: "\(candidate.detail) · 可信度 \(Int(candidate.score * 100))%"
                                )
                            }
                            .buttonStyle(CandidateButtonStyle(active: photo.selectedCandidateID == candidate.id))
                        }
                    }
                } else if !photo.cropRegions.isEmpty {
                    CandidateRow(
                        icon: "checkmark.circle.fill",
                        title: "当前裁切框",
                        detail: "已保留当前结果，可重新生成自动效果"
                    )
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(AppTheme.blue.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(AppTheme.blue.opacity(0.42))
                    }
                }
            } else {
                Text("选择图片后生成自动效果")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.black.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

struct AutoModeSummary: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(AppTheme.blue)
                .frame(width: 26, height: 26)
                .background(AppTheme.blue.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text("自动最佳")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.text)
                Text("自动组合胶片框、分隔线与主体检测")
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.black.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct CandidateRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.muted)
            }
            Spacer()
        }
    }
}

struct Filmstrip: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("图片胶片栏")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(AppTheme.green).frame(width: 6, height: 6)
                    Text("\(store.tasks.filter { $0.status == .running }.count) 个运行中 · \(store.tasks.filter { $0.status == .waiting }.count) 个等待")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.muted)
                }
            }
            HStack(spacing: 10) {
                Button {
                    store.selectPreviousPhoto()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(FilmstripNavButtonStyle())
                .disabled(!canMovePrevious)
                .help("上一张")

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(store.selectedTask?.photos ?? []) { photo in
                                FilmFrame(photo: photo, active: photo.id == store.selectedPhoto?.id)
                                    .id(photo.id)
                                    .onTapGesture { store.selectPhoto(photo.id) }
                            }
                        }
                    }
                    .onChange(of: store.selectedPhoto?.id) { _, photoID in
                        guard let photoID else { return }
                        withAnimation(.easeInOut(duration: 0.18)) {
                            proxy.scrollTo(photoID, anchor: .center)
                        }
                    }
                }

                Button {
                    store.selectNextPhoto()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(FilmstripNavButtonStyle())
                .disabled(!canMoveNext)
                .help("下一张")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(red: 0.08, green: 0.09, blue: 0.11))
        .overlay(alignment: .top) { Rectangle().fill(AppTheme.line).frame(height: 1) }
    }

    private var selectedPhotoIndex: Int? {
        guard let selectedID = store.selectedPhoto?.id else { return nil }
        return store.selectedTask?.photos.firstIndex { $0.id == selectedID }
    }

    private var canMovePrevious: Bool {
        (selectedPhotoIndex ?? 0) > 0
    }

    private var canMoveNext: Bool {
        guard let photos = store.selectedTask?.photos, let index = selectedPhotoIndex else { return false }
        return index < photos.count - 1
    }
}

struct FilmFrame: View {
    let photo: PhotoItem
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topTrailing) {
                if let image = NSImage(contentsOf: photo.url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(red: 0.22, green: 0.18, blue: 0.14)
                }
                Circle().fill(statusColor).frame(width: 8, height: 8).padding(5)
            }
            .frame(width: 112, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(photo.name)
                .font(.system(size: 10))
                .foregroundStyle(AppTheme.muted)
                .lineLimit(1)
            Text(photo.status.rawValue)
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 0.5, green: 0.54, blue: 0.6))
                .lineLimit(1)
        }
        .padding(6)
        .frame(width: 124, height: 78)
        .background(Color(red: 0.115, green: 0.13, blue: 0.16))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(active ? AppTheme.blue.opacity(0.45) : Color.white.opacity(0.05)))
    }

    private var statusColor: Color {
        switch photo.status {
        case .autoDone, .located: AppTheme.green
        case .manual, .failed: Color(red: 0.87, green: 0.69, blue: 0.43)
        case .running, .locating: AppTheme.blue
        case .pending: Color(red: 0.4, green: 0.44, blue: 0.5)
        }
    }
}

struct DropZoneOverlay: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        if store.isDropTargeted {
            ZStack {
                Color.black.opacity(0.38)
                RoundedRectangle(cornerRadius: 22)
                    .stroke(AppTheme.blue, style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                    .padding(34)
                Text("松开后导入文件夹并递归识别图片")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.text)
            }
        }
    }
}

struct EmptyQueueView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 34))
            Text("暂无任务")
                .font(.system(size: 13, weight: .semibold))
            Text("导入文件夹后会按来源建立队列")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.muted)
        }
        .foregroundStyle(AppTheme.muted)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 0.86, green: 0.89, blue: 0.93))
            content
        }
        .padding(14)
        .background(Color.white.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.05)))
    }
}

struct LabeledPicker<Selection: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: Selection
    let content: Content

    init(title: String, selection: Binding<Selection>, @ViewBuilder content: () -> Content) {
        self.title = title
        self._selection = selection
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.muted)
                .frame(width: 48, alignment: .leading)
            Picker("", selection: $selection) {
                content
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
        .padding(10)
        .background(Color.black.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct RecognitionMarginReferenceView: View {
    let reference: CropMarginReference

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "ruler")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppTheme.blue)
                Text("\(reference.source)基准")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.text)
                Spacer()
                Text("用于对照微调")
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.muted)
            }
            HStack(spacing: 6) {
                ReferenceValue(label: "上", value: reference.top)
                ReferenceValue(label: "下", value: reference.bottom)
                ReferenceValue(label: "左", value: reference.left)
                ReferenceValue(label: "右", value: reference.right)
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.blue.opacity(0.16)))
    }
}

struct ReferenceValue: View {
    let label: String
    let value: Double

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppTheme.muted)
            Text("\(Int(round(value)))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct MarginField: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.muted)
            Stepper(value: $value, in: 0...80, step: 1) {
                Text("\(Int(value)) px")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct LogoMark: View {
    var body: some View {
        Image(nsImage: AppIcon.image())
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ParameterActionLabel: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
    }
}

struct GridBackground: View {
    var body: some View {
        Canvas { context, size in
            let color = Color.white.opacity(0.035)
            for x in stride(from: 0, through: size.width, by: 40) {
                context.stroke(Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }, with: .color(color), lineWidth: 1)
            }
            for y in stride(from: 0, through: size.height, by: 40) {
                context.stroke(Path { path in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }, with: .color(color), lineWidth: 1)
            }
        }
    }
}

enum AppTheme {
    static let text = Color(red: 0.93, green: 0.95, blue: 0.97)
    static let muted = Color(red: 0.59, green: 0.63, blue: 0.69)
    static let blue = Color(red: 0.37, green: 0.53, blue: 0.72)
    static let green = Color(red: 0.31, green: 0.65, blue: 0.55)
    static let orange = Color(red: 0.9, green: 0.55, blue: 0.26)
    static let line = Color.white.opacity(0.08)
    static let background = LinearGradient(colors: [Color(red: 0.125, green: 0.14, blue: 0.17), Color(red: 0.055, green: 0.063, blue: 0.075)], startPoint: .top, endPoint: .bottom)
    static let viewer = RadialGradient(colors: [Color(red: 0.105, green: 0.12, blue: 0.15), Color(red: 0.05, green: 0.055, blue: 0.07)], center: .top, startRadius: 0, endRadius: 760)
}

struct PanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(LinearGradient(colors: [Color(red: 0.102, green: 0.115, blue: 0.138), Color(red: 0.078, green: 0.087, blue: 0.105)], startPoint: .top, endPoint: .bottom))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.05)))
    }
}

extension View {
    func panelStyle() -> some View {
        modifier(PanelStyle())
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AppTheme.muted)
            .frame(width: 30, height: 30)
            .background(configuration.isPressed ? Color.white.opacity(0.08) : Color.white.opacity(0.025))
            .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct AccentIconButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 31, height: 31)
            .background(color.opacity(configuration.isPressed ? 0.24 : 0.14))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(color.opacity(configuration.isPressed ? 0.58 : 0.36), lineWidth: 1)
            }
            .shadow(color: color.opacity(0.18), radius: 8, y: 3)
            .opacity(configuration.isPressed ? 0.84 : 1)
    }
}

struct ParameterActionButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(color.opacity(configuration.isPressed ? 0.18 : 0.075))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(color.opacity(configuration.isPressed ? 0.46 : 0.22), lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.84 : 1)
    }
}

struct TopBarButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(primary ? AppTheme.text : Color(red: 0.78, green: 0.83, blue: 0.89))
            .frame(width: 94, height: 34)
            .background(primary ? AppTheme.blue : Color.white.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(primary ? Color.white.opacity(0.08) : Color.white.opacity(0.06))
            }
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

struct StartProcessButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(AppTheme.text)
            .frame(width: 82, height: 34)
            .background(AppTheme.green.opacity(configuration.isPressed ? 0.78 : 0.92))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(configuration.isPressed ? 0.18 : 0.12))
            }
            .shadow(color: AppTheme.green.opacity(0.22), radius: 8, y: 3)
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

struct FilmstripNavButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(AppTheme.muted)
            .frame(width: 30, height: 78)
            .background(configuration.isPressed ? Color.white.opacity(0.075) : Color.white.opacity(0.025))
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(Color.white.opacity(0.05))
            }
    }
}

struct PanelButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(primary ? AppTheme.text : Color(red: 0.8, green: 0.84, blue: 0.88))
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(primary ? AppTheme.blue : Color(red: 0.14, green: 0.155, blue: 0.185))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

struct CandidateButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(active ? AppTheme.text : Color(red: 0.78, green: 0.83, blue: 0.89))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(active ? AppTheme.blue.opacity(0.18) : Color.black.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(active ? AppTheme.blue.opacity(0.42) : Color.white.opacity(0.05))
            }
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

struct TemplateRetileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color(red: 0.78, green: 0.83, blue: 0.89))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(Color.white.opacity(configuration.isPressed ? 0.075 : 0.035))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.08))
            }
    }
}

struct CropToolButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(destructive ? Color(red: 0.76, green: 0.25, blue: 0.25) : AppTheme.blue)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

private extension CGRect {
    var normalized: CGRect {
        let x = min(max(origin.x, 0), 0.95)
        let y = min(max(origin.y, 0), 0.95)
        let width = min(max(size.width, 0.05), 1 - x)
        let height = min(max(size.height, 0.05), 1 - y)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
