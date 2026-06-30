import CoreGraphics
import Foundation

struct CropEditStore: Sendable {
    private let fileName = ".imgslicer-edits.json"

    func restoredTask(_ task: FolderTask) -> FolderTask {
        let edits = loadEdits(rootURL: task.rootURL)
        guard !edits.photos.isEmpty else { return task }

        var restored = task
        for photoIndex in restored.photos.indices {
            let relativePath = restored.photos[photoIndex].relativePath
            guard let edit = edits.photos[relativePath] else { continue }
            let isManual = edit.hasLocalOverrides ?? false
            let finalRegions = edit.manualRegions ?? edit.regions
            let automaticRegions = edit.autoRegions ?? (isManual ? [] : edit.regions)
            // Restoring a photo-level local override must not mark every box as manual.
            // Box-level `isManual` is reserved for an actually hand-picked template/manual box.
            restored.photos[photoIndex].cropRegions = finalRegions.enumerated().map { offset, rect in
                CropRegion(index: offset + 1, rect: rect.cgRect, angle: rect.angle ?? 0, isManual: false)
            }
            if !automaticRegions.isEmpty {
                restored.photos[photoIndex].autoCropRegions = automaticRegions.enumerated().map { offset, rect in
                    CropRegion(index: offset + 1, rect: rect.cgRect, angle: rect.angle ?? 0, isManual: false)
                }
            } else if !isManual {
                restored.photos[photoIndex].autoCropRegions = restored.photos[photoIndex].cropRegions
            } else {
                restored.photos[photoIndex].autoCropRegions = []
            }
            restored.photos[photoIndex].hasLocalOverrides = isManual
            restored.photos[photoIndex].status = isManual ? .manual : .located
        }
        return restored
    }

    func save(photo: PhotoItem, in task: FolderTask) {
        var edits = loadEdits(rootURL: task.rootURL)
        edits.photos[photo.relativePath] = SavedPhotoEdit(
            updatedAt: Date(),
            hasLocalOverrides: photo.hasLocalOverrides,
            regions: photo.cropRegions.map { SavedRect(rect: $0.rect, angle: $0.angle) },
            autoRegions: savedAutoRegions(from: photo),
            manualRegions: photo.hasLocalOverrides ? photo.cropRegions.map { SavedRect(rect: $0.rect, angle: $0.angle) } : nil
        )
        write(edits: edits, rootURL: task.rootURL)
    }

    func save(photos: [PhotoItem], in task: FolderTask) {
        var edits = loadEdits(rootURL: task.rootURL)
        let now = Date()
        for photo in photos {
            edits.photos[photo.relativePath] = SavedPhotoEdit(
                updatedAt: now,
                hasLocalOverrides: photo.hasLocalOverrides,
                regions: photo.cropRegions.map { SavedRect(rect: $0.rect, angle: $0.angle) },
                autoRegions: savedAutoRegions(from: photo),
                manualRegions: photo.hasLocalOverrides ? photo.cropRegions.map { SavedRect(rect: $0.rect, angle: $0.angle) } : nil
            )
        }
        write(edits: edits, rootURL: task.rootURL)
    }

    func remove(photoRelativePath: String, rootURL: URL) {
        var edits = loadEdits(rootURL: rootURL)
        guard edits.photos.removeValue(forKey: photoRelativePath) != nil else { return }
        write(edits: edits, rootURL: rootURL)
    }

    private func loadEdits(rootURL: URL) -> SavedCropEdits {
        let url = editsURL(rootURL: rootURL)
        guard let data = try? Data(contentsOf: url) else {
            return SavedCropEdits()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(SavedCropEdits.self, from: data)) ?? SavedCropEdits()
    }

    private func write(edits: SavedCropEdits, rootURL: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let url = editsURL(rootURL: rootURL)
            let data = try encoder.encode(edits)
            try data.write(to: url, options: .atomic)
        } catch {
        }
    }

    private func editsURL(rootURL: URL) -> URL {
        rootURL.appendingPathComponent(fileName, isDirectory: false)
    }

    private func savedAutoRegions(from photo: PhotoItem) -> [SavedRect]? {
        guard !photo.autoCropRegions.isEmpty else { return nil }
        return photo.autoCropRegions.map { SavedRect(rect: $0.rect, angle: $0.angle) }
    }
}

private struct SavedCropEdits: Codable {
    var version: Int = 2
    var photos: [String: SavedPhotoEdit] = [:]
}

private struct SavedPhotoEdit: Codable {
    var updatedAt: Date
    var hasLocalOverrides: Bool?
    /// Backward-compatible current/final regions. For manual photos this is the
    /// manual result used for cropping; for automatic photos it equals autoRegions.
    var regions: [SavedRect]
    /// Raw automatic recognition result preserved for later comparison.
    var autoRegions: [SavedRect]?
    /// User-adjusted result. Cropping/export uses this when hasLocalOverrides is true.
    var manualRegions: [SavedRect]?

    enum CodingKeys: String, CodingKey {
        case updatedAt
        case hasLocalOverrides
        case isManual
        case regions
        case autoRegions
        case manualRegions
    }

    init(
        updatedAt: Date,
        hasLocalOverrides: Bool?,
        regions: [SavedRect],
        autoRegions: [SavedRect]?,
        manualRegions: [SavedRect]?
    ) {
        self.updatedAt = updatedAt
        self.hasLocalOverrides = hasLocalOverrides
        self.regions = regions
        self.autoRegions = autoRegions
        self.manualRegions = manualRegions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        hasLocalOverrides = try container.decodeIfPresent(Bool.self, forKey: .hasLocalOverrides)
            ?? container.decodeIfPresent(Bool.self, forKey: .isManual)
        regions = try container.decode([SavedRect].self, forKey: .regions)
        autoRegions = try container.decodeIfPresent([SavedRect].self, forKey: .autoRegions)
        manualRegions = try container.decodeIfPresent([SavedRect].self, forKey: .manualRegions)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(hasLocalOverrides, forKey: .hasLocalOverrides)
        try container.encode(regions, forKey: .regions)
        try container.encodeIfPresent(autoRegions, forKey: .autoRegions)
        try container.encodeIfPresent(manualRegions, forKey: .manualRegions)
    }
}

private struct SavedRect: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var angle: Double?

    init(rect: CGRect, angle: Double) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
        self.angle = angle
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height).normalizedCropRect
    }
}

private extension CGRect {
    var normalizedCropRect: CGRect {
        let x = min(max(origin.x, 0), 0.95)
        let y = min(max(origin.y, 0), 0.95)
        let width = min(max(size.width, 0.05), 1 - x)
        let height = min(max(size.height, 0.05), 1 - y)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
