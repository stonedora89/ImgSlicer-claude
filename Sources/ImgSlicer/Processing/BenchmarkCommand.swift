import AppKit
import Foundation

/// Scores the real detection pipeline against the user's saved manual
/// corrections (`.imgslicer-edits.json`), which act as ground-truth labels.
///
/// Everything is compared in NORMALIZED coordinates (both the detector output
/// and the saved edits are normalized), so there is no coordinate-scale bug
/// like the Swift-vs-Python `--compare-algorithms` report had.
///
/// Usage: `ImgSlicer --benchmark <image-folder> [--profile filmScan|gridPhoto|balanced] [--threshold 0.85]`
struct BenchmarkCommand: Sendable {
    let folderURL: URL
    let settings: CropSettings
    let passThreshold: Double

    static func parse(arguments: [String]) -> BenchmarkCommand? {
        guard let commandIndex = arguments.firstIndex(of: "--benchmark") else { return nil }
        guard arguments.indices.contains(commandIndex + 1) else {
            print("Usage: ImgSlicer --benchmark <image-folder> [--profile filmScan|gridPhoto|balanced] [--threshold 0.85]")
            return nil
        }

        var settings = CropSettings()
        if let profileIndex = arguments.firstIndex(of: "--profile"),
           arguments.indices.contains(profileIndex + 1),
           let profile = CropBusinessProfile(benchmarkCLIValue: arguments[profileIndex + 1]) {
            settings.businessProfile = profile
        }

        var threshold = 0.85
        if let thresholdIndex = arguments.firstIndex(of: "--threshold"),
           arguments.indices.contains(thresholdIndex + 1),
           let value = Double(arguments[thresholdIndex + 1]) {
            threshold = value
        }

        return BenchmarkCommand(
            folderURL: URL(fileURLWithPath: arguments[commandIndex + 1]).standardizedFileURL,
            settings: settings,
            passThreshold: threshold
        )
    }

    func run() {
        guard let labels = loadLabels() else {
            print("No labels found: \(folderURL.appendingPathComponent(".imgslicer-edits.json").path)")
            print("Adjust some images in the app first — every manual correction is saved as a label.")
            return
        }

        let processor = ImageProcessor()
        let imageFiles = AlgorithmComparisonCommand.imageFiles(in: folderURL)

        var rows: [Row] = []
        for url in imageFiles {
            guard let truth = labels[url.lastPathComponent], !truth.isEmpty else { continue }
            let detected = processor.detectCropRegions(for: url, settings: settings).map { $0.rect }
            rows.append(Row(name: url.lastPathComponent, truth: truth, detected: detected, threshold: passThreshold))
        }

        guard !rows.isEmpty else {
            print("Found \(labels.count) labeled entries but none matched image files in \(folderURL.path).")
            return
        }

        report(rows: rows)
    }

    private func report(rows: [Row]) {
        let meanIoU = rows.flatMap(\.ious).average
        let countMatches = rows.filter { $0.truth.count == $0.detected.count }.count
        let passes = rows.filter(\.passed).count

        print("# ImgSlicer Detection Benchmark")
        print("")
        print("- Folder: \(folderURL.path)")
        print("- Profile: \(settings.businessProfile.rawValue)")
        print("- Labeled images: \(rows.count)")
        print("- Pass threshold (mean IoU, count must match): \(String(format: "%.2f", passThreshold))")
        print("- Passing: \(passes)/\(rows.count)")
        print("- Count match: \(countMatches)/\(rows.count)")
        print("- Overall mean IoU: \(String(format: "%.3f", meanIoU))")
        print("")
        print("| Image | GT | Det | mean IoU | min IoU | status |")
        print("| --- | ---: | ---: | ---: | ---: | --- |")
        for row in rows.sorted(by: { $0.meanIoU < $1.meanIoU }) {
            print("| \(row.name) | \(row.truth.count) | \(row.detected.count) | \(String(format: "%.3f", row.meanIoU)) | \(String(format: "%.3f", row.minIoU)) | \(row.status) |")
        }

        let worst = rows.filter { !$0.passed }.sorted { $0.meanIoU < $1.meanIoU }
        if !worst.isEmpty {
            print("")
            print("## Needs work (\(worst.count))")
            for row in worst {
                print("- \(row.name): \(row.status), mean IoU \(String(format: "%.3f", row.meanIoU)) (GT \(row.truth.count) vs detected \(row.detected.count))")
            }
        }
    }

    private func loadLabels() -> [String: [CGRect]]? {
        let url = folderURL.appendingPathComponent(".imgslicer-edits.json", isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let edits = try? JSONDecoder().decode(SavedEdits.self, from: data) else {
            return nil
        }
        var labels: [String: [CGRect]] = [:]
        for (path, edit) in edits.photos {
            // Only hand-adjusted entries are ground truth. The app also caches
            // auto-detected regions here; those would just have the detector
            // grade itself (IoU 1.0) and inflate the score.
            guard edit.isManual == true else { continue }
            let rects = edit.regions.map {
                CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            }
            // Key by file name so a flat folder import matches regardless of how
            // the relative path was stored.
            labels[(path as NSString).lastPathComponent] = rects
        }
        return labels
    }

    private struct Row {
        let name: String
        let truth: [CGRect]
        let detected: [CGRect]
        let ious: [Double]
        let passed: Bool
        let status: String

        init(name: String, truth: [CGRect], detected: [CGRect], threshold: Double) {
            self.name = name
            self.truth = truth
            self.detected = detected
            self.ious = Self.match(truth: truth, detected: detected)
            let mean = ious.average
            let countMatch = truth.count == detected.count
            self.passed = countMatch && mean >= threshold
            if !countMatch {
                self.status = "count (\(detected.count) vs \(truth.count))"
            } else if mean >= threshold {
                self.status = "ok"
            } else {
                self.status = "loose"
            }
        }

        var meanIoU: Double { ious.average }
        var minIoU: Double { ious.min() ?? 0 }

        /// Greedy IoU match: each ground-truth box takes its best unused
        /// detected box. Missing detections count as IoU 0.
        static func match(truth: [CGRect], detected: [CGRect]) -> [Double] {
            guard !truth.isEmpty else { return [] }
            var available = Array(detected.indices)
            var result: [Double] = []
            for gt in truth {
                let best = available
                    .map { (index: $0, iou: iou(gt, detected[$0])) }
                    .max { $0.iou < $1.iou }
                if let best, best.iou > 0 {
                    available.removeAll { $0 == best.index }
                    result.append(best.iou)
                } else {
                    result.append(0)
                }
            }
            return result
        }

        static func iou(_ a: CGRect, _ b: CGRect) -> Double {
            let inter = a.intersection(b)
            guard !inter.isNull else { return 0 }
            let interArea = inter.width * inter.height
            let union = a.width * a.height + b.width * b.height - interArea
            return union > 0 ? interArea / union : 0
        }
    }

    private struct SavedEdits: Decodable {
        let photos: [String: SavedPhotoEdit]
    }

    private struct SavedPhotoEdit: Decodable {
        let isManual: Bool?
        let regions: [SavedRect]
    }

    private struct SavedRect: Decodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }
}

private extension CropBusinessProfile {
    init?(benchmarkCLIValue value: String) {
        switch value {
        case "balanced": self = .balanced
        case "filmScan", "film", "scan": self = .filmScan
        case "gridPhoto", "grid": self = .gridPhoto
        default: return nil
        }
    }
}

private extension Array where Element == Double {
    var average: Double {
        isEmpty ? 0 : reduce(0, +) / Double(count)
    }
}
