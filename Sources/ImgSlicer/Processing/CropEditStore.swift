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
            guard let edit = edits.photos[relativePath], !edit.regions.isEmpty else { continue }
            let isManual = edit.isManual ?? true
            restored.photos[photoIndex].cropRegions = edit.regions.enumerated().map { offset, rect in
                CropRegion(index: offset + 1, rect: rect.cgRect, angle: rect.angle ?? 0, isManual: isManual)
            }
            restored.photos[photoIndex].isManual = isManual
            restored.photos[photoIndex].status = isManual ? .manual : .located
        }
        return restored
    }

    func save(photo: PhotoItem, in task: FolderTask) {
        var edits = loadEdits(rootURL: task.rootURL)
        edits.photos[photo.relativePath] = SavedPhotoEdit(
            updatedAt: Date(),
            isManual: photo.isManual,
            regions: photo.cropRegions.map { SavedRect(rect: $0.rect, angle: $0.angle) }
        )
        write(edits: edits, rootURL: task.rootURL)
    }

    func save(photos: [PhotoItem], in task: FolderTask) {
        var edits = loadEdits(rootURL: task.rootURL)
        let now = Date()
        for photo in photos {
            edits.photos[photo.relativePath] = SavedPhotoEdit(
                updatedAt: now,
                isManual: photo.isManual,
                regions: photo.cropRegions.map { SavedRect(rect: $0.rect, angle: $0.angle) }
            )
        }
        write(edits: edits, rootURL: task.rootURL)
    }

    /// Remove only this photo's cached crop state. Explicit re-detection uses
    /// this before reading the source image so a later import cannot resurrect
    /// the discarded manual/automatic boxes.
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
        // MUST match write()'s .iso8601 date strategy. With the default strategy
        // the iso8601 string dates fail to decode, loadEdits silently returns
        // empty, and every save then overwrites the file with only the current
        // photo — wiping all other photos' edits (including manual GT).
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
            // Manual edits are still kept in memory; persistence is a convenience layer.
        }
    }

    private func editsURL(rootURL: URL) -> URL {
        rootURL.appendingPathComponent(fileName, isDirectory: false)
    }
}

private struct SavedCropEdits: Codable {
    var version: Int = 1
    var photos: [String: SavedPhotoEdit] = [:]
}

private struct SavedPhotoEdit: Codable {
    var updatedAt: Date
    var isManual: Bool?
    var regions: [SavedRect]
}

private struct SavedRect: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    // Optional so edits written before deskew existed still decode (missing -> 0).
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
