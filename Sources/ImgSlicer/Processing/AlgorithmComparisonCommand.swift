import AppKit
import Foundation

struct DetectionOverlayCommand: Sendable {
    let imageURL: URL
    let outputURL: URL
    let settings: CropSettings

    static func parse(arguments: [String]) -> DetectionOverlayCommand? {
        guard let commandIndex = arguments.firstIndex(of: "--export-overlay") else { return nil }
        guard arguments.indices.contains(commandIndex + 1) else {
            print("Usage: ImgSlicer --export-overlay <image-file> [--output overlay.png] [--profile filmScan|gridPhoto|balanced]")
            return nil
        }

        var settings = CropSettings()
        applyCLISettings(arguments: arguments, settings: &settings)

        let imageURL = URL(fileURLWithPath: arguments[commandIndex + 1]).standardizedFileURL
        let outputURL: URL
        if let outputIndex = arguments.firstIndex(of: "--output"),
           arguments.indices.contains(outputIndex + 1) {
            outputURL = URL(fileURLWithPath: arguments[outputIndex + 1]).standardizedFileURL
        } else {
            outputURL = URL(fileURLWithPath: "/private/tmp/imgslicer-overlay.png")
        }

        return DetectionOverlayCommand(imageURL: imageURL, outputURL: outputURL, settings: settings)
    }

    func run() {
        guard let image = NSImage(contentsOf: imageURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("Unable to open image: \(imageURL.path)")
            return
        }

        let processor = ImageProcessor()
        let sampleRoot = Self.sampleRoot(for: imageURL) ?? imageURL.deletingLastPathComponent()
        let sampleProfiles = SampleLibrary().load(rootURL: sampleRoot)
        let candidates = processor.detectCropCandidates(for: imageURL, settings: settings, sampleProfiles: sampleProfiles)
        let regions = candidates.first?.adjustedRegions(settings: settings) ?? []
        let scale = min(1, 1800 / Double(max(cgImage.width, cgImage.height)))
        let outputSize = NSSize(width: Double(cgImage.width) * scale, height: Double(cgImage.height) * scale)
        let overlay = NSImage(size: outputSize)

        overlay.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: outputSize), from: .zero, operation: .copy, fraction: 1)
        NSColor.systemRed.setStroke()
        NSColor.systemRed.withAlphaComponent(0.10).setFill()
        let lineWidth = max(2.0, outputSize.width / 900)

        for region in regions {
            let rect = NSRect(
                x: region.rect.minX * outputSize.width,
                y: outputSize.height - region.rect.maxY * outputSize.height,
                width: region.rect.width * outputSize.width,
                height: region.rect.height * outputSize.height
            )
            let path = NSBezierPath(rect: rect)
            path.lineWidth = lineWidth
            path.fill()
            path.stroke()
        }
        overlay.unlockFocus()

        guard let tiff = overlay.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            print("Unable to render overlay")
            return
        }

        do {
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: outputURL, options: .atomic)
            print("Wrote overlay: \(outputURL.path)")
            print("Regions: \(regions.count)")
            let reliabilities = processor.edgeReliabilities(regions: regions, cgImage: cgImage)
            for (index, region) in regions.enumerated() {
                let r = region.rect
                let rel = index < reliabilities.count ? reliabilities[index] : [0, 0, 0, 0]
                print(String(format: "  [%d] x=%.4f y=%.4f w=%.4f h=%.4f angle=%+.2f  rel L=%.2f R=%.2f T=%.2f B=%.2f",
                             index + 1, r.minX, r.minY, r.width, r.height, region.angle, rel[0], rel[1], rel[2], rel[3]))
            }
        } catch {
            print("Unable to write overlay: \(error.localizedDescription)")
        }
    }

    private static func sampleRoot(for imageURL: URL) -> URL? {
        var url = imageURL.deletingLastPathComponent().standardizedFileURL
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".imgslicer-samples.json").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return nil
    }
}

struct DetectionCountCommand: Sendable {
    let folderURL: URL
    let settings: CropSettings

    static func parse(arguments: [String]) -> DetectionCountCommand? {
        guard let commandIndex = arguments.firstIndex(of: "--detect-count") else { return nil }
        let folderArgumentIndex = commandIndex + 1
        guard arguments.indices.contains(folderArgumentIndex) else {
            print("Usage: ImgSlicer --detect-count <image-folder> [--profile filmScan|gridPhoto|balanced]")
            return nil
        }

        var settings = CropSettings()
        applyCLISettings(arguments: arguments, settings: &settings)

        return DetectionCountCommand(
            folderURL: URL(fileURLWithPath: arguments[folderArgumentIndex]).standardizedFileURL,
            settings: settings
        )
    }

    func run() {
        let processor = ImageProcessor()
        for imageURL in AlgorithmComparisonCommand.imageFiles(in: folderURL) {
            let start = Date()
            let candidates = processor.detectCropCandidates(for: imageURL, settings: settings)
            let regions = candidates.first?.adjustedRegions(settings: settings) ?? []
            let elapsed = Date().timeIntervalSince(start)
            print("\(imageURL.lastPathComponent)\tregions=\(regions.count)\tcandidates=\(candidates.count)\ttime=\(String(format: "%.3f", elapsed))s")
        }
    }
}

struct AlgorithmComparisonCommand: Sendable {
    let folderURL: URL
    let outputURL: URL?
    let settings: CropSettings

    static func parse(arguments: [String]) -> AlgorithmComparisonCommand? {
        guard let commandIndex = arguments.firstIndex(of: "--compare-algorithms") else { return nil }
        let folderArgumentIndex = commandIndex + 1
        guard arguments.indices.contains(folderArgumentIndex) else {
            print("Usage: ImgSlicer --compare-algorithms <image-folder> [--output report.md] [--profile filmScan|gridPhoto|balanced]")
            return nil
        }

        let folderURL = URL(fileURLWithPath: arguments[folderArgumentIndex]).standardizedFileURL
        var outputURL: URL?
        var settings = CropSettings()

        if let outputIndex = arguments.firstIndex(of: "--output"),
           arguments.indices.contains(outputIndex + 1) {
            outputURL = URL(fileURLWithPath: arguments[outputIndex + 1]).standardizedFileURL
        }

        if let profileIndex = arguments.firstIndex(of: "--profile"),
           arguments.indices.contains(profileIndex + 1),
           let profile = CropBusinessProfile(cliValue: arguments[profileIndex + 1]) {
            settings.businessProfile = profile
        }

        return AlgorithmComparisonCommand(folderURL: folderURL, outputURL: outputURL, settings: settings)
    }

    func run() {
        let images = Self.imageFiles(in: folderURL)
        guard !images.isEmpty else {
            print("No image files found in \(folderURL.path)")
            return
        }

        let processor = ImageProcessor()
        let pythonRunner = PythonReferenceDetector(projectRoot: Self.projectRoot())
        let results = images.map { imageURL in
            compare(imageURL: imageURL, processor: processor, pythonRunner: pythonRunner)
        }
        let report = renderReport(results: results, pythonPath: pythonRunner.pythonPath, detectorPath: pythonRunner.scriptPath)

        if let outputURL {
            do {
                try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try report.write(to: outputURL, atomically: true, encoding: .utf8)
                print("Wrote comparison report: \(outputURL.path)")
            } catch {
                print("Failed to write report: \(error.localizedDescription)")
                print(report)
            }
        } else {
            print(report)
        }
    }

    private func compare(imageURL: URL, processor: ImageProcessor, pythonRunner: PythonReferenceDetector) -> AlgorithmComparisonResult {
        let swiftStart = Date()
        let swiftRegions = processor.detectCropRegions(for: imageURL, settings: settings)
        let swiftDuration = Date().timeIntervalSince(swiftStart)

        let cgImage = NSImage(contentsOf: imageURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let imageSize = cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        let swiftBoxes = swiftRegions.map { region in
            PixelRect(
                left: region.rect.minX * imageSize.width,
                top: region.rect.minY * imageSize.height,
                right: region.rect.maxX * imageSize.width,
                bottom: region.rect.maxY * imageSize.height
            )
        }

        let pythonStart = Date()
        let pythonResult = pythonRunner.detect(imageURL: imageURL)
        let pythonDuration = Date().timeIntervalSince(pythonStart)

        switch pythonResult {
        case .success(let reference):
            let matches = Self.match(swiftBoxes: swiftBoxes, pythonBoxes: reference.boxes)
            return AlgorithmComparisonResult(
                imageURL: imageURL,
                imageSize: imageSize,
                swiftBoxes: swiftBoxes,
                pythonBoxes: reference.boxes,
                matchMetrics: matches,
                swiftDuration: swiftDuration,
                pythonDuration: pythonDuration,
                pythonError: nil
            )
        case .failure(let error):
            return AlgorithmComparisonResult(
                imageURL: imageURL,
                imageSize: imageSize,
                swiftBoxes: swiftBoxes,
                pythonBoxes: [],
                matchMetrics: [],
                swiftDuration: swiftDuration,
                pythonDuration: pythonDuration,
                pythonError: error
            )
        }
    }

    private func renderReport(results: [AlgorithmComparisonResult], pythonPath: String, detectorPath: String) -> String {
        let comparable = results.filter { $0.pythonError == nil }
        let averageIoU = comparable.flatMap(\.matchMetrics).map(\.iou).average
        let exactCountMatches = comparable.filter { $0.swiftBoxes.count == $0.pythonBoxes.count }.count
        let totalSwiftTime = results.map(\.swiftDuration).reduce(0, +)
        let totalPythonTime = results.map(\.pythonDuration).reduce(0, +)

        var lines: [String] = []
        lines.append("# ImgSlicer Algorithm Comparison")
        lines.append("")
        lines.append("- Folder: `\(folderURL.path)`")
        lines.append("- Business profile: `\(settings.businessProfile.rawValue)`")
        lines.append("- Images: \(results.count)")
        lines.append("- Python runner: `\(pythonPath)`")
        lines.append("- External detector: `\(detectorPath)`")
        lines.append("- Python override: set `IMGSLICER_PYTHON=/path/to/python` when running the command")
        lines.append("- Detector override: set `IMGSLICER_DETECTOR_SCRIPT=/path/to/opencv_detector.py` when running the command")
        lines.append("- Count match: \(exactCountMatches) / \(comparable.count)")
        lines.append("- Average matched IoU: \(String(format: "%.3f", averageIoU))")
        lines.append("- Swift total: \(String(format: "%.2fs", totalSwiftTime))")
        lines.append("- Python total: \(String(format: "%.2fs", totalPythonTime))")
        lines.append("")
        lines.append("| Image | Swift | Python | Avg IoU | Swift Time | Python Time | Notes |")
        lines.append("| --- | ---: | ---: | ---: | ---: | ---: | --- |")

        for result in results {
            let name = result.imageURL.lastPathComponent
            let avgIoU = result.matchMetrics.map(\.iou).average
            let note: String
            if let pythonError = result.pythonError {
                note = "Python error: \(sanitizeTableCell(pythonError))"
            } else if result.swiftBoxes.count != result.pythonBoxes.count {
                note = "count differs"
            } else if avgIoU < 0.85 {
                note = "boundary differs"
            } else {
                note = "ok"
            }
            lines.append("| \(name) | \(result.swiftBoxes.count) | \(result.pythonBoxes.count) | \(String(format: "%.3f", avgIoU)) | \(String(format: "%.2fs", result.swiftDuration)) | \(String(format: "%.2fs", result.pythonDuration)) | \(note) |")
        }

        lines.append("")
        lines.append("## Box Details")
        for result in results {
            lines.append("")
            lines.append("### \(result.imageURL.lastPathComponent)")
            if let pythonError = result.pythonError {
                lines.append("External detector error: `\(pythonError)`")
            }
            lines.append("- Swift: \(result.swiftBoxes.map(\.description).joined(separator: ", "))")
            lines.append("- Python: \(result.pythonBoxes.map(\.description).joined(separator: ", "))")
        }

        return lines.joined(separator: "\n")
    }

    private func sanitizeTableCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "/")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "")
    }

    private static func match(swiftBoxes: [PixelRect], pythonBoxes: [PixelRect]) -> [BoxMatchMetric] {
        var unusedPython = Set(pythonBoxes.indices)
        var metrics: [BoxMatchMetric] = []

        for swiftBox in swiftBoxes {
            let best = unusedPython
                .map { index in (index: index, iou: swiftBox.iou(with: pythonBoxes[index])) }
                .max { $0.iou < $1.iou }
            guard let best else { continue }
            unusedPython.remove(best.index)
            metrics.append(BoxMatchMetric(iou: best.iou))
        }
        return metrics
    }

    static func imageFiles(in folderURL: URL) -> [URL] {
        let supported = Set(["jpg", "jpeg", "png", "tif", "tiff", "bmp", "webp", "heic", "heif"])
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: Array(keys)) else {
            return []
        }

        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  supported.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: keys).isRegularFile) == true else { return nil }
            return url
        }
        .sorted { $0.path < $1.path }
    }

    private static func projectRoot() -> URL {
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
    }
}

private func applyCLISettings(arguments: [String], settings: inout CropSettings) {
    if let profileIndex = arguments.firstIndex(of: "--profile"),
       arguments.indices.contains(profileIndex + 1),
       let profile = CropBusinessProfile(cliValue: arguments[profileIndex + 1]) {
        settings.businessProfile = profile
    }

    if let algorithmIndex = arguments.firstIndex(of: "--algorithm"),
       arguments.indices.contains(algorithmIndex + 1),
       let algorithm = CropAlgorithmMode(cliValue: arguments[algorithmIndex + 1]) {
        settings.algorithmMode = algorithm
    }

    if let preprocessIndex = arguments.firstIndex(of: "--preprocess"),
       arguments.indices.contains(preprocessIndex + 1),
       let preprocess = ImagePreprocessMode(cliValue: arguments[preprocessIndex + 1]) {
        settings.preprocessMode = preprocess
    }
}

private struct PythonReferenceDetector {
    let pythonPath: String
    let scriptPath: String

    init(projectRoot: URL) {
        let detector = ExternalDetector(projectRoot: projectRoot)
        self.pythonPath = detector.pythonPath
        self.scriptPath = detector.scriptURL?.path ?? "not found"
    }

    func detect(imageURL: URL) -> PythonDetectionOutcome {
        switch ExternalDetector().detect(imageURL: imageURL) {
        case .success(let result):
            let boxes = result.boxes.map { box in
                PixelRect(left: box.left, top: box.top, right: box.right, bottom: box.bottom)
            }
            return .success(PythonDetectionResult(boxes: boxes))
        case .failure(let error):
            return .failure(error)
        }
    }
}

private enum PythonDetectionOutcome {
    case success(PythonDetectionResult)
    case failure(String)
}

private struct PythonDetectionResult: Decodable {
    let boxes: [PixelRect]
}

private struct AlgorithmComparisonResult {
    let imageURL: URL
    let imageSize: CGSize
    let swiftBoxes: [PixelRect]
    let pythonBoxes: [PixelRect]
    let matchMetrics: [BoxMatchMetric]
    let swiftDuration: TimeInterval
    let pythonDuration: TimeInterval
    let pythonError: String?
}

private struct BoxMatchMetric {
    let iou: Double
}

private struct PixelRect: Decodable, CustomStringConvertible {
    let left: Double
    let top: Double
    let right: Double
    let bottom: Double

    var area: Double {
        max(0, right - left) * max(0, bottom - top)
    }

    var description: String {
        "[\(Int(round(left))), \(Int(round(top))), \(Int(round(right))), \(Int(round(bottom)))]"
    }

    enum CodingKeys: String, CodingKey {
        case left
        case top
        case right
        case bottom
    }

    func iou(with other: PixelRect) -> Double {
        let intersectionLeft = max(left, other.left)
        let intersectionTop = max(top, other.top)
        let intersectionRight = min(right, other.right)
        let intersectionBottom = min(bottom, other.bottom)
        let intersection = max(0, intersectionRight - intersectionLeft) * max(0, intersectionBottom - intersectionTop)
        let union = area + other.area - intersection
        return union > 0 ? intersection / union : 0
    }
}

private extension CropBusinessProfile {
    init?(cliValue: String) {
        switch cliValue {
        case "balanced":
            self = .balanced
        case "filmScan", "film", "scan":
            self = .filmScan
        case "gridPhoto", "grid":
            self = .gridPhoto
        default:
            return nil
        }
    }
}

private extension CropAlgorithmMode {
    init?(cliValue: String) {
        switch cliValue {
        case "automatic", "auto":
            self = .automatic
        case "projectionSeparators", "projection", "separators":
            self = .projectionSeparators
        case "filmFrames", "film":
            self = .filmFrames
        case "visionRectangles", "vision", "rectangles":
            self = .visionRectangles
        case "foregroundComponents", "foreground", "components":
            self = .foregroundComponents
        case "localContrastComponents", "localContrast", "contrastComponents", "local":
            self = .localContrastComponents
        case "externalDetector", "external", "opencv", "python", "smart":
            self = .externalDetector
        case "darkGutters", "dark", "gutters":
            self = .darkGutters
        default:
            return nil
        }
    }
}

private extension ImagePreprocessMode {
    init?(cliValue: String) {
        switch cliValue {
        case "original", "raw":
            self = .original
        case "highContrast", "contrast":
            self = .highContrast
        case "mask":
            self = .mask
        case "inverted", "invert":
            self = .inverted
        default:
            return nil
        }
    }
}

private extension Array where Element == Double {
    var average: Double {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / Double(count)
    }
}
