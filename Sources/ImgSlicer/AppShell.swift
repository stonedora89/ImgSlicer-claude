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
        .background { keyboardShortcutSinks }
        .onDrop(of: [.fileURL], isTargeted: $store.isDropTargeted) { providers in
            loadDroppedURLs(providers)
        }
        .alert(
            "该图片有手动修正",
            isPresented: Binding(
                get: { store.manualRedetectPrompt != nil },
                set: { if !$0 { store.manualRedetectPrompt = nil } }
            ),
            presenting: store.manualRedetectPrompt
        ) { _ in
            Button("重新识别（丢弃手动修正）", role: .destructive) {
                store.confirmManualRedetect()
            }
            Button("保留手动修正", role: .cancel) {
                store.manualRedetectPrompt = nil
            }
        } message: { prompt in
            Text("「\(prompt.photoName)」已被手动调整。重新识别会用自动结果替换这些手动框，且无法撤销。")
        }
        .alert(
            store.startProcessingPrompt?.title ?? "开始处理",
            isPresented: Binding(
                get: { store.startProcessingPrompt != nil },
                set: { if !$0 { store.startProcessingPrompt = nil } }
            ),
            presenting: store.startProcessingPrompt
        ) { prompt in
            if prompt.canStart {
                Button("开始处理 \(prompt.waitingCount) 个任务") {
                    store.confirmStartProcessing()
                }
                Button("取消", role: .cancel) {
                    store.startProcessingPrompt = nil
                }
            } else {
                Button("知道了", role: .cancel) {
                    store.startProcessingPrompt = nil
                }
            }
        } message: { prompt in
            Text(prompt.message)
        }
    }

    /// Invisible buttons whose keyboard shortcuts work whenever the window is
    /// key — unlike `.onKeyPress`, they don't depend on a particular subview
    /// holding focus, so Delete/Esc fire even after the user has clicked a box
    /// on the canvas. Disabled when not applicable so the keystroke falls
    /// through instead of being silently swallowed.
    private var keyboardShortcutSinks: some View {
        Group {
            Button("Delete frame") { store.deleteSelectedCropRegion() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(store.selectedCropRegionID == nil)
            Button("Delete frame (forward)") { store.deleteSelectedCropRegion() }
                .keyboardShortcut(.deleteForward, modifiers: [])
                .disabled(store.selectedCropRegionID == nil)
            Button("Cancel marquee") { store.cancelDrawNewRegion() }
                .keyboardShortcut(.cancelAction)
                .disabled(!store.isDrawingNewRegion)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
    var body: some View {
        HStack {
            BrandLockup()
            Spacer()
        }
        .padding(.leading, 68)
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
                    store.pickFiles()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(IconButtonStyle())
                .help("追加导入图片或文件夹")

                Button {
                    store.clearFinishedAndIdle()
                } label: {
                    Image(systemName: "eraser")
                }
                .buttonStyle(IconButtonStyle())
                .help("清理所有任务（处理中的除外）")
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
        .background(active ? AppTheme.orange.opacity(0.16) : Color(red: 0.115, green: 0.13, blue: 0.155))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .leading) {
            if active {
                RoundedRectangle(cornerRadius: 3)
                    .fill(AppTheme.orange)
                    .frame(width: 4)
                    .padding(.vertical, 10)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(active ? AppTheme.orange : Color.white.opacity(0.05), lineWidth: active ? 2 : 1)
        }
        .shadow(color: active ? AppTheme.orange.opacity(0.35) : .clear, radius: 6)
        .animation(.easeOut(duration: 0.15), value: active)
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
                if let photo = store.selectedPhoto {
                    DownsampledImageView(url: photo.url, maxPixel: 2200) {
                        ProgressView()
                            .controlSize(.large)
                    } content: { image in
                        AnyView(
                            PhotoCanvas(
                                image: image,
                                regions: photo.cropRegions,
                                selectedRegionID: store.selectedCropRegionID,
                                isDrawing: store.isDrawingNewRegion,
                                onDelete: { regionID in
                                    store.deleteSelectedCrop(regionID: regionID)
                                },
                                onSelect: { regionID in
                                    store.selectCropRegion(regionID)
                                },
                                onDrawNewRegion: { rect in
                                    store.addCropRegion(rect: rect)
                                }
                            ) { regionID, rect in
                                store.updateSelectedCrop(regionID: regionID, rect: rect)
                            }
                        )
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
        .onChange(of: store.selectedPhoto?.id) { _, _ in
            DownsampledImageLoader.prefetch(neighborURLs(), maxPixel: 2200)
        }
    }

    /// URLs of the photos immediately before/after the selection, so left/right
    /// navigation shows the preview from cache without a decode wait.
    private func neighborURLs() -> [URL] {
        guard let photos = store.selectedTask?.photos,
              let index = photos.firstIndex(where: { $0.id == store.selectedPhoto?.id }) else { return [] }
        return [index - 1, index + 1]
            .filter { photos.indices.contains($0) }
            .map { photos[$0].url }
    }
}

struct PhotoCanvas: View {
    let image: NSImage
    let regions: [CropRegion]
    let selectedRegionID: CropRegion.ID?
    let isDrawing: Bool
    let onDelete: (CropRegion.ID) -> Void
    let onSelect: (CropRegion.ID) -> Void
    let onDrawNewRegion: (CGRect) -> Void
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

                if isDrawing {
                    // Marquee layer sits on top while in draw mode: the user drags
                    // a rectangle and we hand back its normalized coordinates.
                    DrawRegionLayer(onComplete: onDrawNewRegion)
                        .frame(width: imageRect.width, height: imageRect.height)
                        .offset(x: imageRect.minX, y: imageRect.minY)
                }
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

/// Full-image overlay shown in marquee mode. The user drags out a rectangle;
/// on release we report it back in normalized [0,1] image coordinates. Tiny
/// drags (an accidental click) are ignored so no zero-size box is created.
struct DrawRegionLayer: View {
    let onComplete: (CGRect) -> Void
    @State private var startPoint: CGPoint?
    @State private var currentRect: CGRect?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.black.opacity(0.28))
                if let rect = currentRect {
                    Rectangle()
                        .fill(AppTheme.orange.opacity(0.16))
                        .overlay(Rectangle().stroke(AppTheme.orange, lineWidth: 2))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
            .contentShape(Rectangle())
            // Crosshair cursor signals "draw a box here". onContinuousHover
            // re-asserts it on every move (so a drag keeps it), and .set() can't
            // unbalance a cursor stack; onDisappear restores the arrow in case
            // draw mode is exited while the pointer is still inside.
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    NSCursor.crosshair.set()
                case .ended:
                    NSCursor.arrow.set()
                }
            }
            .onDisappear { NSCursor.arrow.set() }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        NSCursor.crosshair.set()
                        let start = startPoint ?? value.startLocation
                        startPoint = start
                        currentRect = pixelRect(from: start, to: value.location, in: proxy.size)
                    }
                    .onEnded { value in
                        let start = startPoint ?? value.startLocation
                        let rect = pixelRect(from: start, to: value.location, in: proxy.size)
                        startPoint = nil
                        currentRect = nil
                        guard rect.width > 6, rect.height > 6,
                              proxy.size.width > 0, proxy.size.height > 0 else { return }
                        onComplete(CGRect(
                            x: rect.minX / proxy.size.width,
                            y: rect.minY / proxy.size.height,
                            width: rect.width / proxy.size.width,
                            height: rect.height / proxy.size.height
                        ))
                    }
            )
        }
    }

    private func pixelRect(from a: CGPoint, to b: CGPoint, in size: CGSize) -> CGRect {
        let x = min(a.x, b.x).clamped(to: 0...size.width)
        let y = min(a.y, b.y).clamped(to: 0...size.height)
        let maxX = max(a.x, b.x).clamped(to: 0...size.width)
        let maxY = max(a.y, b.y).clamped(to: 0...size.height)
        return CGRect(x: x, y: y, width: maxX - x, height: maxY - y)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
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
                // Selected box floats above its neighbours so overlapping frames
                // never steal the drag — you always manipulate the one you picked.
                .zIndex(region.id == selectedRegionID ? 1 : 0)
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
                // Full-canvas spacer only — must not capture hits, otherwise the
                // top-most frame's transparent fill would swallow drags meant for
                // a box underneath it.
                Rectangle()
                    .fill(Color.clear)
                    .allowsHitTesting(false)

                // The whole annotated box — stroke, index badge, delete button
                // and corner handles — lives in the box's own local space and
                // rotates as one unit about the box centre. That keeps every
                // handle and label glued to a tilted frame's actual corners
                // instead of leaving them square while only the stroke turns.
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .stroke(activeColor.opacity(isSelected ? 0.95 : 0.78), lineWidth: isSelected ? 3 : 2)
                        .background(Rectangle().fill(Color.black.opacity(0.001)))
                        .frame(width: draw.width, height: draw.height)
                        .gesture(dragGesture(in: proxy.size, corner: nil))
                        .onTapGesture { onSelect() }

                    Text("\(region.index)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: isSelected ? 26 : 22, height: isSelected ? 26 : 22)
                        .background(activeColor)
                        .clipShape(Circle())
                        .position(x: 13, y: 13)
                        .shadow(color: activeColor.opacity(isSelected ? 0.45 : 0), radius: 8, y: 2)
                        .onTapGesture { onSelect() }

                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(CropToolButtonStyle(destructive: true))
                    .position(x: draw.width - 13, y: 13)
                    .help("删除裁切框")

                    ForEach(CropCorner.allCases) { corner in
                        Circle()
                            .fill(Color(red: 0.86, green: 0.91, blue: 0.96))
                            .overlay(Circle().stroke(activeColor, lineWidth: isSelected ? 3 : 2))
                            .frame(width: isSelected ? 16 : 14, height: isSelected ? 16 : 14)
                            .position(corner.point(in: CGRect(origin: .zero, size: draw.size)))
                            .gesture(dragGesture(in: proxy.size, corner: corner))
                    }
                }
                .frame(width: draw.width, height: draw.height, alignment: .topLeading)
                .rotationEffect(.degrees(region.angle))
                .position(x: draw.midX, y: draw.midY)
            }
            .onChange(of: region.rect) { _, newValue in
                workingRect = newValue
            }
        }
    }

    private var activeColor: Color {
        // Selected frame always gets the reserved highlight; others cycle the
        // palette by frame number so adjacent boxes are visibly distinct.
        guard !isSelected else { return AppTheme.orange }
        let palette = AppTheme.frameColors
        return palette[max(0, region.index - 1) % palette.count]
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
    @State private var showMargins = false

    var body: some View {
        content
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

    private var content: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("参数设置")
                    .font(.system(size: 15, weight: .bold))
                HStack(spacing: 7) {
                    Button {
                        store.toggleDrawNewRegion()
                    } label: {
                        Image(systemName: store.isDrawingNewRegion ? "viewfinder" : "plus.viewfinder")
                    }
                    .buttonStyle(AccentIconButtonStyle(color: store.isDrawingNewRegion ? AppTheme.green : AppTheme.orange))
                    .disabled(store.selectedPhoto == nil)
                    .help("框选新增：点亮后在预览图上拖出一个新的裁切框（Esc 取消）")

                    Button {
                        store.redetectSelectedPhoto()
                    } label: {
                        Image(systemName: "wand.and.stars")
                    }
                    .buttonStyle(AccentIconButtonStyle(color: AppTheme.blue))
                    .disabled(store.selectedPhoto == nil)
                    .help("重新识别：丢弃当前图片的历史框和候选，从原图重新生成自动效果")
                }
            }
            .padding(16)
            .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.line).frame(height: 1) }

            ScrollView {
                VStack(spacing: 12) {
                    SettingsGroup("自动效果") {
                        VStack(spacing: 10) {
                            AutoCandidatePicker()
                        }
                    }
                    SettingsGroup("旋转校正") {
                        CropAngleControl()
                    }
                    CollapsibleGroup("高级 · 边距微调", isExpanded: $showMargins) {
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

            Button {
                store.startProcessing()
            } label: {
                Image(systemName: "play.circle.fill")
            }
            .buttonStyle(StartProcessButtonStyle())
            .help("按当前裁切框开始批量输出")
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(16)
            .overlay(alignment: .top) { Rectangle().fill(AppTheme.line).frame(height: 1) }
        }
    }
}

/// Panel control for the selected box's tilt. On first selecting a box it
/// shows the system-detected angle; the 左旋转 / 右旋转 buttons nudge it 1° per
/// click, clamped to ±15°. Every change is persisted as that single photo's
/// parameter, so switching photos keeps the manual angle.
struct CropAngleControl: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        let region = store.selectedCropRegion
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("当前框角度")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.muted)
                Spacer()
                Text(String(format: "%.0f°", region?.angle ?? 0))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.text)
            }
            HStack(spacing: 8) {
                rotateButton(title: "左旋转", systemName: "arrow.counterclockwise", delta: -1, region: region)
                rotateButton(title: "右旋转", systemName: "arrow.clockwise", delta: 1, region: region)
            }
            Text(caption(for: region))
                .font(.system(size: 10))
                .foregroundStyle(AppTheme.muted)
        }
        .padding(10)
        .background(Color.black.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func rotateButton(title: String, systemName: String, delta: Double, region: CropRegion?) -> some View {
        Button {
            guard let region else { return }
            let next = (region.angle + delta).clamped(to: -15...15)
            store.updateSelectedCropAngle(regionID: region.id, angle: next)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemName)
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(region == nil ? AppTheme.blue.opacity(0.35) : AppTheme.blue)
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(region == nil)
    }

    private func caption(for region: CropRegion?) -> String {
        guard let region else { return "请选择一个裁切框" }
        if region.isManual {
            return "手动设置 · 切换后自动保存为单张参数"
        }
        return "系统识别角度，可微调（±15°，每次 1°）"
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

/// A SettingsGroup whose body collapses behind a tappable header — used to tuck
/// rarely-needed advanced controls out of the default view.
struct CollapsibleGroup<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    let content: Content

    init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 0.86, green: 0.89, blue: 0.93))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AppTheme.muted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.05)))
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
                        LazyHStack(spacing: 10) {
                            ForEach(store.selectedTask?.photos ?? []) { photo in
                                FilmFrame(photo: photo, active: photo.id == store.selectedPhoto?.id)
                                    .id(photo.id)
                                    .contentShape(Rectangle())
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
                DownsampledImageView(url: photo.url, maxPixel: 144) {
                    Color(red: 0.22, green: 0.18, blue: 0.14)
                } content: { image in
                    AnyView(
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.low)
                            .antialiased(false)
                            .scaledToFill()
                    )
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
        .background(active ? AppTheme.orange.opacity(0.18) : Color(red: 0.115, green: 0.13, blue: 0.16))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(active ? AppTheme.orange : Color.white.opacity(0.05), lineWidth: active ? 2.5 : 1)
        )
        .shadow(color: active ? AppTheme.orange.opacity(0.5) : .clear, radius: 7)
        .animation(.easeOut(duration: 0.15), value: active)
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
    @EnvironmentObject private var store: AppStore
    @State private var hovering = false

    var body: some View {
        Button {
            store.pickFiles()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 34))
                Text("暂无任务")
                    .font(.system(size: 13, weight: .semibold))
                Text("点击此处导入，或拖入文件夹 / 图片")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.muted)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(AppTheme.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 64)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(store.isDropTargeted ? 0.06 : hovering ? 0.03 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
                    .foregroundStyle((store.isDropTargeted ? AppTheme.blue : AppTheme.line).opacity(store.isDropTargeted ? 0.9 : 1))
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("点击打开导入，或把文件夹 / 图片拖到这里")
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
    /// Cycled across adjacent crop frames so neighbouring boxes never share a
    /// colour — overlaps and mis-cuts stand out at a glance. Orange is reserved
    /// for the selected frame, so it's deliberately excluded here.
    static let frameColors: [Color] = [
        Color(red: 0.37, green: 0.53, blue: 0.72),   // blue
        Color(red: 0.31, green: 0.66, blue: 0.55),   // teal
        Color(red: 0.74, green: 0.43, blue: 0.79),   // purple
        Color(red: 0.86, green: 0.37, blue: 0.47),   // rose
        Color(red: 0.36, green: 0.71, blue: 0.80),   // cyan
        Color(red: 0.80, green: 0.73, blue: 0.33),   // yellow
    ]
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

struct StartProcessButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(AppTheme.text)
            .frame(width: 132, height: 50)
            .background(AppTheme.green.opacity(configuration.isPressed ? 0.78 : 0.92))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
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
