import AppKit
import CoreGraphics
import Foundation

struct SampleProfile: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var sourceName: String
    var layout: CropBusinessProfile
    var regionCount: Int
    var averageWidth: Double
    var averageHeight: Double
    var averageArea: Double
    var aspectRatio: Double
    var interiorBrightness: Double
    var borderBrightness: Double
    var contrast: Double
    var edgeStrength: Double
}

struct SampleLibrary: Sendable {
    private let fileName = ".imgslicer-samples.json"

    func load(rootURL: URL) -> [SampleProfile] {
        let url = samplesURL(rootURL: rootURL)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode(SavedSampleLibrary.self, from: data))?.profiles ?? []
    }

    func save(profile: SampleProfile, rootURL: URL) {
        var library = SavedSampleLibrary(profiles: load(rootURL: rootURL))
        library.profiles.removeAll { existing in
            existing.sourceName == profile.sourceName &&
            abs(existing.aspectRatio - profile.aspectRatio) < 0.03 &&
            abs(existing.averageArea - profile.averageArea) < 0.01
        }
        library.profiles.insert(profile, at: 0)
        library.profiles = Array(library.profiles.prefix(32))
        write(library: library, rootURL: rootURL)
    }

    func makeProfile(photo: PhotoItem, layout: CropBusinessProfile) -> SampleProfile? {
        let regions = photo.cropRegions
            .map { $0.rect.normalizedCropRect }
            .filter { $0.width > 0.02 && $0.height > 0.02 }
        guard !regions.isEmpty else { return nil }

        let averageWidth = regions.map { Double($0.width) }.average
        let averageHeight = regions.map { Double($0.height) }.average
        let averageArea = regions.map(\.area).average
        let aspectRatio = averageWidth / max(averageHeight, 0.001)
        let imageStats = imageStatistics(url: photo.url, regions: regions)

        return SampleProfile(
            sourceName: photo.name,
            layout: layout,
            regionCount: regions.count,
            averageWidth: averageWidth,
            averageHeight: averageHeight,
            averageArea: averageArea,
            aspectRatio: aspectRatio,
            interiorBrightness: imageStats.interiorBrightness,
            borderBrightness: imageStats.borderBrightness,
            contrast: imageStats.contrast,
            edgeStrength: imageStats.edgeStrength
        )
    }

    private func write(library: SavedSampleLibrary, rootURL: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(library)
            try data.write(to: samplesURL(rootURL: rootURL), options: .atomic)
        } catch {
            // The current manual edit still remains in memory; the sample library is a learning cache.
        }
    }

    private func samplesURL(rootURL: URL) -> URL {
        rootURL.appendingPathComponent(fileName, isDirectory: false)
    }

    private func imageStatistics(url: URL, regions: [CGRect]) -> (interiorBrightness: Double, borderBrightness: Double, contrast: Double, edgeStrength: Double) {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return (0.5, 0.5, 0, 0)
        }

        let maxWidth = 420
        let width = min(cgImage.width, maxWidth)
        let height = max(1, Int(Double(cgImage.height) * Double(width) / Double(cgImage.width)))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext else {
            return (0.5, 0.5, 0, 0)
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = bitmap.bitmapData else { return (0.5, 0.5, 0, 0) }

        func luminance(x: Int, y: Int) -> Double {
            let offset = y * bitmap.bytesPerRow + x * 4
            let blue = Double(data[offset])
            let green = Double(data[offset + 1])
            let red = Double(data[offset + 2])
            return (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255.0
        }

        var interior: [Double] = []
        var border: [Double] = []
        var edgeSum = 0.0
        var edgeCount = 0

        for rect in regions {
            let x0 = max(1, min(width - 2, Int(rect.minX * Double(width))))
            let x1 = max(x0 + 1, min(width - 2, Int(rect.maxX * Double(width))))
            let y0 = max(1, min(height - 2, Int(rect.minY * Double(height))))
            let y1 = max(y0 + 1, min(height - 2, Int(rect.maxY * Double(height))))
            let stepX = max(1, (x1 - x0) / 20)
            let stepY = max(1, (y1 - y0) / 20)

            for y in stride(from: y0, through: y1, by: stepY) {
                for x in stride(from: x0, through: x1, by: stepX) {
                    let value = luminance(x: x, y: y)
                    let nearBorder = x - x0 <= stepX || x1 - x <= stepX || y - y0 <= stepY || y1 - y <= stepY
                    if nearBorder {
                        border.append(value)
                    } else {
                        interior.append(value)
                    }
                    edgeSum += abs(luminance(x: x + 1, y: y) - luminance(x: x - 1, y: y))
                    edgeSum += abs(luminance(x: x, y: y + 1) - luminance(x: x, y: y - 1))
                    edgeCount += 2
                }
            }
        }

        let interiorMean = interior.averageOr(0.5)
        let borderMean = border.averageOr(interiorMean)
        let contrast = abs(interiorMean - borderMean)
        let edgeStrength = edgeSum / Double(max(1, edgeCount))
        return (interiorMean, borderMean, contrast, edgeStrength)
    }
}

private struct SavedSampleLibrary: Codable {
    var version: Int = 1
    var profiles: [SampleProfile] = []
}

private extension Array where Element == Double {
    var average: Double {
        averageOr(0)
    }

    func averageOr(_ fallback: Double) -> Double {
        guard !isEmpty else { return fallback }
        return reduce(0, +) / Double(count)
    }
}

private extension CGRect {
    var area: Double {
        width * height
    }

    var normalizedCropRect: CGRect {
        let x = min(max(origin.x, 0), 0.95)
        let y = min(max(origin.y, 0), 0.95)
        let width = min(max(size.width, 0.01), 1 - x)
        let height = min(max(size.height, 0.01), 1 - y)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
