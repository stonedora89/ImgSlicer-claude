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
    let useSamples: Bool
    let dumpJSONPath: String?

    static func parse(arguments: [String]) -> BenchmarkCommand? {
        guard let commandIndex = arguments.firstIndex(of: "--benchmark") else { return nil }
        guard arguments.indices.contains(commandIndex + 1) else {
            print("Usage: ImgSlicer --benchmark <image-folder> [--profile filmScan|gridPhoto|balanced] [--threshold 0.85] [--use-samples]")
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

        var dumpJSONPath: String?
        if let dumpIndex = arguments.firstIndex(of: "--dump-json"),
           arguments.indices.contains(dumpIndex + 1) {
            dumpJSONPath = arguments[dumpIndex + 1]
        }

        return BenchmarkCommand(
            folderURL: URL(fileURLWithPath: arguments[commandIndex + 1]).standardizedFileURL,
            settings: settings,
            passThreshold: threshold,
            useSamples: arguments.contains("--use-samples"),
            dumpJSONPath: dumpJSONPath
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
        // Mirror the app: load the same sample library the UI feeds into
        // detection so the benchmark measures what the user actually sees.
        let sampleProfiles = useSamples ? SampleLibrary().load(rootURL: folderURL) : []

        var rows: [Row] = []
        for url in imageFiles {
            let key = relativePath(for: url)
            guard let truth = labels[key], !truth.isEmpty else { continue }
            let detected = processor.detectCropRegions(for: url, settings: settings, sampleProfiles: sampleProfiles).map { $0.rect }
            rows.append(Row(name: key, truth: truth, detected: detected, threshold: passThreshold))
        }

        guard !rows.isEmpty else {
            print("Found \(labels.count) labeled entries but none matched image files in \(folderURL.path).")
            return
        }

        if let dumpPath = dumpJSONPath {
            dumpJSON(rows: rows, to: dumpPath)
        }
        report(rows: rows)
    }

    /// Write per-image detected and ground-truth boxes (normalized) to JSON so a
    /// diagnostic script can overlay them on the scan. Pure tooling — lets us see
    /// WHERE a count mismatch happens (which frame was dropped/merged) instead of
    /// guessing from the aggregate score.
    private func dumpJSON(rows: [Row], to path: String) {
        func encode(_ rects: [CGRect]) -> [[String: Double]] {
            rects.map { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
        }
        var payload: [String: [String: [[String: Double]]]] = [:]
        for row in rows {
            payload[row.name] = ["detected": encode(row.detected), "truth": encode(row.truth)]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        print("Dumped boxes to \(path)")
    }

    private func report(rows: [Row]) {
        let meanIoU = rows.flatMap(\.ious).average
        let countMatches = rows.filter { $0.truth.count == $0.detected.count }.count
        let passes = rows.filter(\.passed).count

        print("# ImgSlicer Detection Benchmark")
        print("")
        print("- Folder: \(folderURL.path)")
        print("- Profile: \(settings.businessProfile.rawValue)")
        print("- Samples: \(useSamples ? "on (.imgslicer-samples.json)" : "off")")
        print("- Labeled images: \(rows.count)")
        print("- Pass threshold (mean IoU, count must match): \(String(format: "%.2f", passThreshold))")
        print("- Passing: \(passes)/\(rows.count)")
        print("- Count match: \(countMatches)/\(rows.count)")
        print("- Overall mean IoU: \(String(format: "%.3f", meanIoU))")
        print("")

        reportEdgeErrors(rows: rows)
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

    /// Per-edge signed error across all matched (ground-truth, detected) box
    /// pairs, in units of normalized image size (× the perpendicular box size
    /// is also shown so the bias is readable relative to a cell).
    ///
    /// Sign convention — positive means the detected edge sits *inside* the
    /// truth (the box is too tight on that side); negative means it overshoots
    /// (too loose). This tells us the DIRECTION of the boundary error, which
    /// IoU alone hides: an all-tight box and an all-loose box score the same.
    private func reportEdgeErrors(rows: [Row]) {
        let pairs = rows.flatMap(\.matchedPairs)
        guard !pairs.isEmpty else { return }

        func stats(_ values: [Double]) -> (mean: Double, absMean: Double) {
            (values.average, values.map(abs).average)
        }
        // Inward-positive: left/top use (det - truth); right/bottom use (truth - det).
        let left = stats(pairs.map { ($0.det.minX - $0.gt.minX) / $0.gt.width })
        let right = stats(pairs.map { ($0.gt.maxX - $0.det.maxX) / $0.gt.width })
        let top = stats(pairs.map { ($0.det.minY - $0.gt.minY) / $0.gt.height })
        let bottom = stats(pairs.map { ($0.gt.maxY - $0.det.maxY) / $0.gt.height })

        print("## Edge error (matched pairs: \(pairs.count); +inward/too-tight, −outward/too-loose; % of box side)")
        print("")
        print("| Edge | mean signed | mean abs |")
        print("| --- | ---: | ---: |")
        func pct(_ v: Double) -> String { String(format: "%+.1f%%", v * 100) }
        func apct(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }
        print("| left | \(pct(left.mean)) | \(apct(left.absMean)) |")
        print("| right | \(pct(right.mean)) | \(apct(right.absMean)) |")
        print("| top | \(pct(top.mean)) | \(apct(top.absMean)) |")
        print("| bottom | \(pct(bottom.mean)) | \(apct(bottom.absMean)) |")
        print("")
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
            guard edit.hasLocalOverrides == true else { continue }
            let manualRegions = edit.manualRegions ?? edit.regions
            let rects = manualRegions.map {
                CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            }
            labels[path] = rects
        }
        return labels
    }

    private func relativePath(for url: URL) -> String {
        let root = folderURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(root.count + 1))
    }

    struct MatchedPair {
        let gt: CGRect
        let det: CGRect
    }

    private struct Row {
        let name: String
        let truth: [CGRect]
        let detected: [CGRect]
        let ious: [Double]
        let matchedPairs: [MatchedPair]
        let passed: Bool
        let status: String

        init(name: String, truth: [CGRect], detected: [CGRect], threshold: Double) {
            self.name = name
            self.truth = truth
            self.detected = detected
            let matches = Self.match(truth: truth, detected: detected)
            self.ious = matches.map(\.iou)
            self.matchedPairs = matches.compactMap { match in
                match.detected.map { MatchedPair(gt: match.gt, det: $0) }
            }
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

        struct Match {
            let gt: CGRect
            let detected: CGRect?
            let iou: Double
        }

        /// Greedy IoU match: each ground-truth box takes its best unused
        /// detected box. Missing detections count as IoU 0 (no paired box).
        static func match(truth: [CGRect], detected: [CGRect]) -> [Match] {
            guard !truth.isEmpty else { return [] }
            var available = Array(detected.indices)
            var result: [Match] = []
            for gt in truth {
                let best = available
                    .map { (index: $0, iou: iou(gt, detected[$0])) }
                    .max { $0.iou < $1.iou }
                if let best, best.iou > 0 {
                    available.removeAll { $0 == best.index }
                    result.append(Match(gt: gt, detected: detected[best.index], iou: best.iou))
                } else {
                    result.append(Match(gt: gt, detected: nil, iou: 0))
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
        let hasLocalOverrides: Bool?
        let regions: [SavedRect]
        let manualRegions: [SavedRect]?

        enum CodingKeys: String, CodingKey {
            case hasLocalOverrides
            case isManual
            case regions
            case manualRegions
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hasLocalOverrides = try container.decodeIfPresent(Bool.self, forKey: .hasLocalOverrides)
                ?? container.decodeIfPresent(Bool.self, forKey: .isManual)
            regions = try container.decode([SavedRect].self, forKey: .regions)
            manualRegions = try container.decodeIfPresent([SavedRect].self, forKey: .manualRegions)
        }
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
