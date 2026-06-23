import AppKit
import CoreGraphics
import Foundation
import Vision

struct PhotoProcessResult: Sendable {
    let photoURL: URL
    let regions: [CropRegion]
    let candidates: [CropCandidate]
    let outputURLs: [URL]
    let failed: Bool
}

struct ImageProcessor: Sendable {
    private let detectionPipeline = CropDetectionPipeline()
    private let processingPolicy = ProcessingPolicy()

#if !IMGSLICER_MOJAVE
    func locate(photos: [PhotoItem], settings: CropSettings, sampleProfiles: [SampleProfile] = []) async -> [PhotoProcessResult] {
        var results: [PhotoProcessResult] = []
        for photo in photos where !photo.isManual {
            if Task.isCancelled { break }
            autoreleasepool {
                let candidates = detectCropCandidates(for: photo.url, settings: settings, sampleProfiles: sampleProfiles)
                let regions = preferredRegions(from: candidates, settings: settings)
                results.append(PhotoProcessResult(photoURL: photo.url, regions: regions, candidates: candidates, outputURLs: [], failed: false))
            }
        }
        return results
    }

    func locate(task: FolderTask, settings: CropSettings, sampleProfiles: [SampleProfile] = []) async -> [PhotoProcessResult] {
        await locate(photos: task.photos, settings: settings, sampleProfiles: sampleProfiles)
    }

    func process(task: FolderTask, settings: CropSettings, sampleProfiles: [SampleProfile] = []) async -> [PhotoProcessResult] {
        var results: [PhotoProcessResult] = []
        for photo in task.photos {
            if Task.isCancelled { break }
            autoreleasepool {
                let regions = cropRegions(for: photo, settings: settings, sampleProfiles: sampleProfiles)
                let outputs = writeCrops(photo: photo, task: task, regions: regions)
                let failed = outputs.isEmpty
                results.append(PhotoProcessResult(photoURL: photo.url, regions: regions, candidates: photo.cropCandidates, outputURLs: outputs, failed: failed))
            }
        }
        return results
    }
#else
    /// Synchronous entry points for the AppKit Mojave build. Swift concurrency
    /// cannot be deployed to macOS 10.14, while the underlying detector and
    /// crop writer are already synchronous.
    func locateSynchronously(photos: [PhotoItem], settings: CropSettings, sampleProfiles: [SampleProfile] = []) -> [PhotoProcessResult] {
        photos.filter { !$0.isManual }.map { photo in
            autoreleasepool {
                let candidates = detectCropCandidates(for: photo.url, settings: settings, sampleProfiles: sampleProfiles)
                let regions = preferredRegions(from: candidates, settings: settings)
                return PhotoProcessResult(photoURL: photo.url, regions: regions, candidates: candidates, outputURLs: [], failed: false)
            }
        }
    }

    func processSynchronously(task: FolderTask, settings: CropSettings, sampleProfiles: [SampleProfile] = []) -> [PhotoProcessResult] {
        task.photos.map { photo in
            autoreleasepool {
                let regions = cropRegions(for: photo, settings: settings, sampleProfiles: sampleProfiles)
                let outputs = writeCrops(photo: photo, task: task, regions: regions)
                return PhotoProcessResult(
                    photoURL: photo.url,
                    regions: regions,
                    candidates: photo.cropCandidates,
                    outputURLs: outputs,
                    failed: outputs.isEmpty
                )
            }
        }
    }
#endif

    private func cropRegions(for photo: PhotoItem, settings: CropSettings, sampleProfiles: [SampleProfile]) -> [CropRegion] {
        if photo.isManual || processingPolicy.shouldReuseLocatedRegions(for: photo) {
            return photo.cropRegions
        }
        return detectCropRegions(for: photo.url, settings: settings, sampleProfiles: sampleProfiles)
    }

    func detectCropRegions(for url: URL, settings: CropSettings, sampleProfiles: [SampleProfile] = []) -> [CropRegion] {
        preferredRegions(from: detectCropCandidates(for: url, settings: settings, sampleProfiles: sampleProfiles), settings: settings)
    }

    func detectCropCandidates(for url: URL, settings: CropSettings, sampleProfiles: [SampleProfile] = []) -> [CropCandidate] {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return fallbackCandidates(settings: settings)
        }

        let performance = detectionPipeline.performancePolicy(for: settings)
        let width = min(cgImage.width, performance.maxAnalysisWidth)
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
            return fallbackCandidates(settings: settings)
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let analysisCGImage = bitmap.cgImage ?? cgImage
        let baseGray = grayscaleBytes(bitmap: bitmap, width: width, height: height)
        var cachedBaseLuminances: [Double]?
        var bestFallback: [CropRegion] = []
        var candidates: [CropCandidate] = []
        var signatures = Set<String>()

        func baseLuminances() -> [Double] {
            if let cachedBaseLuminances {
                return cachedBaseLuminances
            }
            let values = baseGray.map { Double($0) / 255.0 }
            cachedBaseLuminances = values
            return values
        }

        var contactSheetRects = detectContactSheetFrames(luminances: baseLuminances(), width: width, height: height, settings: settings)
        if contactSheetRects.count >= 20 {
            // The contact-sheet path emits a single candidate, so sample
            // guidance can't re-rank its way to a better box — fuse the sample
            // here instead, calibrating each cell's size to the dimensions the
            // user's correction taught us.
            contactSheetRects = calibratedToSample(contactSheetRects, sampleProfiles: sampleProfiles)
            let regions = indexedRegions(from: contactSheetRects, settings: settings)
            appendCandidates(
                for: regions,
                stage: .filmFrames,
                preprocessMode: .original,
                preferred: true,
                into: &candidates,
                signatures: &signatures
            )
            candidates = candidates.map { candidate in
                CropCandidate(
                    title: "接触印样主体",
                    detail: "自动识别到 \(regions.count) 个主体区域",
                    regions: candidate.regions,
                    marginScale: 0,
                    score: 0.99
                )
            }
            bestFallback = regions
            candidates = sampleGuidedCandidates(candidates, sampleProfiles: sampleProfiles)
            return rankedCandidates(candidates, limit: performance.maxCandidateCount)
        }

        var shouldStopDetection = false
        for preprocessMode in preprocessModes(for: settings) {
            let gray = preprocessedGray(baseGray, mode: preprocessMode, settings: settings)
            var cachedLuminances: [Double]?

            func luminances() -> [Double] {
                if let cachedLuminances {
                    return cachedLuminances
                }
                let values = gray.map { Double($0) / 255.0 }
                cachedLuminances = values
                return values
            }

            for stage in detectionPipeline.stages(for: settings) {
                let regions: [CropRegion]
                switch stage {
                case .projectionSeparators:
                    regions = detectByProjectionSeparators(gray: gray, width: width, height: height, settings: settings)
                case .filmFrames:
                    regions = detectFilmFrames(luminances: luminances(), width: width, height: height, settings: settings)
                case .visionRectangles:
                    regions = detectWithVision(cgImage: analysisCGImage, settings: settings)
                case .foregroundComponents:
                    regions = detectForegroundComponents(luminances: luminances(), width: width, height: height, settings: settings)
                case .localContrastComponents:
                    regions = detectLocalContrastComponents(luminances: luminances(), width: width, height: height, settings: settings)
                case .externalDetector:
                    regions = detectWithExternalDetector(imageURL: url, imageWidth: cgImage.width, imageHeight: cgImage.height, settings: settings)
                case .darkGutters:
                    regions = detectByDarkGutters(luminances: luminances(), width: width, height: height, settings: settings)
                }

                let refinedRegions = trimWhiteEdges(
                    regions: regions,
                    luminances: baseLuminances(),
                    width: width,
                    height: height
                )
                appendCandidates(
                    for: refinedRegions,
                    stage: stage,
                    preprocessMode: preprocessMode,
                    preferred: candidates.isEmpty,
                    into: &candidates,
                    signatures: &signatures
                )
                if bestFallback.isEmpty, !refinedRegions.isEmpty {
                    bestFallback = refinedRegions
                }
                if performance.stopAfterFirstMultiRegionCandidate,
                   shouldStop(after: refinedRegions, settings: settings) {
                    shouldStopDetection = true
                    break
                }
            }
            if shouldStopDetection {
                break
            }
        }

        candidates = sampleGuidedCandidates(candidates, sampleProfiles: sampleProfiles)
        candidates = rankedCandidates(candidates, limit: performance.maxCandidateCount)

        // Snap each frame's vertical edges to the true gutter↔content boundary
        // at full resolution. The ~600px split confuses a thin black gutter
        // with dark textured content, so left edges either keep the gutter or
        // cut into the subject; the snap fixes both directions.
        if let fullGray = fullResolutionGray(cgImage: cgImage) {
            candidates = candidates.enumerated().map { candidateOffset, candidate in
                // Split a frame that merged two photos (a gutter the 600px pass
                // missed because both frames are dark) before snapping, so the
                // new sub-frames get their edges refined too.
                let split = splitMergedFrames(
                    regions: candidate.regions,
                    gray: fullGray.bytes,
                    width: fullGray.width,
                    height: fullGray.height
                )
                let snapped = snapVerticalBoundaries(
                    regions: split,
                    gray: fullGray.bytes,
                    width: fullGray.width,
                    height: fullGray.height
                )
                // For a left/right edge with NO pixel evidence (reliability ~0 —
                // a dark subject with no detectable gutter), fall back to the
                // strip's regular grid position. Strictly gated: only no-evidence
                // edges that also break the rhythm are moved; edges the snap
                // locked onto real gutters are never overridden.
                let evidenced = gridFallbackUnreliableEdges(
                    regions: snapped,
                    gray: fullGray.bytes,
                    width: fullGray.width,
                    height: fullGray.height
                )
                // Tilt estimation is the costly part, so only run it for the
                // top-ranked candidate (the one shown/output by default).
                let estimateTilt = candidateOffset == 0
                return CropCandidate(
                    title: candidate.title,
                    detail: candidate.detail,
                    regions: evidenced.enumerated().map {
                        let rect = $0.element.rect.normalized
                        let angle = (estimateTilt && !$0.element.isManual) ? estimateRegionTilt(
                            gray: fullGray.bytes, width: fullGray.width, height: fullGray.height, rect: rect
                        ) : 0
                        return CropRegion(index: $0.offset + 1, rect: rect, angle: angle, isManual: $0.element.isManual)
                    },
                    marginScale: candidate.marginScale,
                    score: candidate.score
                )
            }
        }


        // Regularize the strip grid: a roll's frames share one pitch and width,
        // so a frame that breaks the rhythm (one the snap couldn't fix because
        // its gutter was missing/weak) is pulled back onto the regular grid the
        // other frames define. Pure geometry, gated to strip-like layouts.
        candidates = candidates.map { candidate in
            let regular = regularizeStripGrid(candidate.regions)
            guard regular.count == candidate.regions.count else { return candidate }
            return CropCandidate(
                title: candidate.title,
                detail: candidate.detail,
                regions: regular,
                marginScale: candidate.marginScale,
                score: candidate.score
            )
        }

        // Complete multi-row grids: add lattice cells detection missed because
        // the frame had no subject/edges (e.g. a black frame at a row's end).
        // Pure geometry, conservative; only adds cells, never moves boxes.
        candidates = candidates.map { candidate in
            let completed = completeGridLattice(candidate.regions)
            guard completed.count > candidate.regions.count else { return candidate }
            return CropCandidate(
                title: candidate.title,
                detail: candidate.detail,
                regions: completed,
                marginScale: candidate.marginScale,
                score: candidate.score
            )
        }

        if candidates.isEmpty, !bestFallback.isEmpty {
            candidates.append(CropCandidate(
                title: "单图裁切",
                detail: "识别到 1 个主要区域",
                regions: bestFallback,
                marginScale: 1,
                score: score(regions: bestFallback)
            ))
        }

        return candidates.isEmpty ? fallbackCandidates(settings: settings) : candidates
    }

    private func shouldStop(after regions: [CropRegion], settings: CropSettings) -> Bool {
        guard regions.count > 1 else { return false }
        guard settings.algorithmMode == .automatic else { return true }
        return regions.count >= 3 || score(regions: regions) >= 0.56
    }

    private func preferredRegions(from candidates: [CropCandidate], settings: CropSettings) -> [CropRegion] {
        candidates.first?.adjustedRegions(settings: settings) ?? [CropRegion(index: 1, rect: marginRect(settings))]
    }

    private func appendCandidates(
        for regions: [CropRegion],
        stage: CropDetectionStage,
        preprocessMode: ImagePreprocessMode,
        preferred: Bool,
        into candidates: inout [CropCandidate],
        signatures: inout Set<String>
    ) {
        guard !regions.isEmpty else { return }
        let base = regions.enumerated().map { offset, region in
            CropRegion(index: offset + 1, rect: region.rect.normalized, isManual: false)
        }
        let stagePenalty = stage == .darkGutters ? 0.18 : 0
        let baseScore = max(0, score(regions: base) - stagePenalty)
        guard baseScore > 0.18 else { return }

        let variants: [(String, String, Double)]
        if preferred {
            variants = [("自动最佳", "\(stage.displayName) / \(preprocessMode.rawValue) · \(base.count) 个区域", 1)]
        } else {
            variants = [("\(stage.displayName)", "\(preprocessMode.rawValue) · \(base.count) 个区域", 1)]
        }

        for variant in variants {
            let signature = candidateSignature(regions: base, marginScale: variant.2)
            guard !signatures.contains(signature) else { continue }
            signatures.insert(signature)
            candidates.append(CropCandidate(
                title: variant.0,
                detail: variant.1,
                regions: base,
                marginScale: variant.2,
                score: max(0, min(1, baseScore - abs(variant.2 - 1) * 0.025))
            ))
        }
    }

    private func sampleGuidedCandidates(_ candidates: [CropCandidate], sampleProfiles: [SampleProfile]) -> [CropCandidate] {
        guard !sampleProfiles.isEmpty else { return candidates }
        let profiles = Array(sampleProfiles.prefix(5))
        return candidates.map { candidate in
            let similarity = profiles.map { sampleSimilarity(candidate: candidate, profile: $0) }.max() ?? 0
            let guidedScore = min(1, candidate.score * 0.78 + similarity * 0.22)
            let detail = similarity > 0.58
                ? "\(candidate.detail) · 样本匹配 \(Int(similarity * 100))%"
                : candidate.detail
            return CropCandidate(
                title: candidate.title,
                detail: detail,
                regions: candidate.regions,
                marginScale: candidate.marginScale,
                score: guidedScore
            )
        }
    }

    /// Calibrate detected cell rects toward the size a saved sample taught us.
    ///
    /// Sample guidance only re-ranks candidates, which is useless when a layout
    /// (like a contact sheet) produces a single candidate. Here we instead pull
    /// each cell's width/height toward the sample's learned average, anchored on
    /// the cell centre so the grid position is preserved. This fixes a
    /// systematic size bias (e.g. cells detected ~8% too tall) that no amount of
    /// re-ranking could touch.
    ///
    /// Guarded so it only fires when the sample plausibly describes this layout:
    /// the region count must match and the aspect ratio must be in the same
    /// ballpark. The pull is a partial blend, so a genuinely different image
    /// still keeps most of its own detected geometry.
    private func calibratedToSample(_ rects: [CGRect], sampleProfiles: [SampleProfile]) -> [CGRect] {
        guard !rects.isEmpty else { return rects }
        let avgWidth = rects.map { Double($0.width) }.average
        let avgHeight = rects.map { Double($0.height) }.average
        let aspect = avgWidth / max(avgHeight, 0.001)

        let candidate = sampleProfiles.first { profile in
            profile.regionCount == rects.count &&
            abs(log(max(profile.aspectRatio, 0.001)) - log(max(aspect, 0.001))) < 0.30
        }
        guard let profile = candidate,
              profile.averageWidth > 0.01, profile.averageHeight > 0.01 else { return rects }

        let blend = 0.6
        let targetWidth = avgWidth * (1 - blend) + profile.averageWidth * blend
        let targetHeight = avgHeight * (1 - blend) + profile.averageHeight * blend

        return rects.map { rect in
            let cx = rect.midX
            let cy = rect.midY
            var newRect = CGRect(
                x: cx - targetWidth / 2,
                y: cy - targetHeight / 2,
                width: targetWidth,
                height: targetHeight
            )
            newRect = newRect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            return newRect.isNull ? rect : newRect
        }
    }

    private func sampleSimilarity(candidate: CropCandidate, profile: SampleProfile) -> Double {
        guard !candidate.regions.isEmpty else { return 0 }
        let rects = candidate.regions.map(\.rect)
        let averageWidth = rects.map { Double($0.width) }.average
        let averageHeight = rects.map { Double($0.height) }.average
        let averageArea = rects.map(\.area).average
        let aspectRatio = averageWidth / max(averageHeight, 0.001)

        func closeness(_ lhs: Double, _ rhs: Double, scale: Double) -> Double {
            guard lhs.isFinite, rhs.isFinite, scale > 0 else { return 0 }
            return max(0, 1 - abs(lhs - rhs) / scale)
        }

        let aspect = closeness(log(aspectRatio), log(max(profile.aspectRatio, 0.001)), scale: 0.45)
        let width = closeness(averageWidth, profile.averageWidth, scale: max(0.06, profile.averageWidth * 0.45))
        let height = closeness(averageHeight, profile.averageHeight, scale: max(0.06, profile.averageHeight * 0.45))
        let area = closeness(averageArea, profile.averageArea, scale: max(0.02, profile.averageArea * 0.55))
        let count = closeness(Double(candidate.regions.count), Double(profile.regionCount), scale: max(3, Double(profile.regionCount) * 0.5))

        return aspect * 0.36 + area * 0.22 + width * 0.16 + height * 0.16 + count * 0.10
    }

    private func rankedCandidates(_ candidates: [CropCandidate], limit: Int) -> [CropCandidate] {
        candidates
            .sorted {
                if abs($0.score - $1.score) > 0.001 { return $0.score > $1.score }
                return $0.regions.count > $1.regions.count
            }
            .prefix(limit)
            .map { $0 }
    }

    private func score(regions: [CropRegion]) -> Double {
        guard !regions.isEmpty else { return 0 }
        let countScore = regions.count > 1 ? 0.24 : 0.08
        let areas = regions.map { max(0, $0.rect.area) }
        let totalArea = areas.reduce(0, +)
        let averageArea = totalArea / Double(max(1, areas.count))
        let areaScore = min(0.28, totalArea * 0.42)
        let consistency = areaConsistencyScore(areas: areas, averageArea: averageArea)
        let alignment = alignmentScore(regions: regions)
        let wholeScanPenalty = regions.contains { $0.rect.width > 0.94 && $0.rect.height > 0.94 } ? 0.32 : 0
        let tinyPenalty = regions.contains { $0.rect.width < 0.035 || $0.rect.height < 0.035 } ? 0.18 : 0
        return max(0, min(1, countScore + areaScore + consistency + alignment - wholeScanPenalty - tinyPenalty))
    }

    private func areaConsistencyScore(areas: [Double], averageArea: Double) -> Double {
        guard areas.count > 1, averageArea > 0 else { return 0.06 }
        let variance = areas.reduce(0) { $0 + pow($1 - averageArea, 2) } / Double(areas.count)
        let coefficient = sqrt(variance) / averageArea
        return max(0, 0.22 - min(0.22, coefficient * 0.16))
    }

    private func alignmentScore(regions: [CropRegion]) -> Double {
        guard regions.count > 1 else { return 0.04 }
        let rowTolerance = 0.045
        var rows: [[CGRect]] = []
        for rect in regions.map(\.rect).sorted(by: { $0.minY < $1.minY }) {
            if let lastRow = rows.indices.last,
               abs(rows[lastRow][0].minY - rect.minY) <= rowTolerance {
                rows[lastRow].append(rect)
            } else {
                rows.append([rect])
            }
        }
        let multiColumnRows = rows.filter { $0.count > 1 }.count
        let rowScore = min(0.14, Double(multiColumnRows) * 0.05)
        let sortedRows = rows.map { $0.sorted { $0.minX < $1.minX } }
        let columnScore = sortedRows.contains { $0.count > 2 } ? 0.08 : 0.04
        return rowScore + columnScore
    }

    private func candidateSignature(regions: [CropRegion], marginScale: Double) -> String {
        let rects = regions.map { region -> String in
            let rect = region.rect
            return [
                rect.minX,
                rect.minY,
                rect.width,
                rect.height
            ].map { String(Int(round($0 * 100))) }.joined(separator: ",")
        }.joined(separator: "|")
        return "\(regions.count)-\(Int(round(marginScale * 10)))-\(rects)"
    }

    private func trimWhiteEdges(regions: [CropRegion], luminances: [Double], width: Int, height: Int) -> [CropRegion] {
        regions
            .map { trimWhiteEdge(region: $0, luminances: luminances, width: width, height: height) }
            .filter { $0.rect.width > 0.01 && $0.rect.height > 0.01 }
            .enumerated()
            .map { offset, region in
                CropRegion(index: offset + 1, rect: region.rect.normalized, isManual: region.isManual)
            }
    }

    private func trimWhiteEdge(region: CropRegion, luminances: [Double], width: Int, height: Int) -> CropRegion {
        guard width > 4, height > 4, luminances.count >= width * height else { return region }

        let rect = region.rect.normalized
        var minX = max(0, min(width - 1, Int(floor(rect.minX * Double(width)))))
        var maxX = max(minX + 1, min(width, Int(ceil(rect.maxX * Double(width)))))
        var minY = max(0, min(height - 1, Int(floor(rect.minY * Double(height)))))
        var maxY = max(minY + 1, min(height, Int(ceil(rect.maxY * Double(height)))))
        let originalMinX = minX
        let originalMaxX = maxX
        let originalMinY = minY
        let originalMaxY = maxY
        let minimumSpan = 12
        let maxHorizontalTrim = max(1, Int(Double(maxX - minX) * 0.24))
        let maxVerticalTrim = max(1, Int(Double(maxY - minY) * 0.24))

        func isWhiteEdgeLine(_ stats: (whiteRatio: Double, darkRatio: Double)) -> Bool {
            stats.whiteRatio >= 0.9 && stats.darkRatio <= 0.025
        }

        while minX + minimumSpan < maxX,
              minX - originalMinX < maxHorizontalTrim,
              isWhiteEdgeLine(columnWhiteStats(x: minX, yRange: minY..<maxY, luminances: luminances, width: width)) {
            minX += 1
        }

        while minX + minimumSpan < maxX,
              originalMaxX - maxX < maxHorizontalTrim,
              isWhiteEdgeLine(columnWhiteStats(x: maxX - 1, yRange: minY..<maxY, luminances: luminances, width: width)) {
            maxX -= 1
        }

        while minY + minimumSpan < maxY,
              minY - originalMinY < maxVerticalTrim,
              isWhiteEdgeLine(rowWhiteStats(y: minY, xRange: minX..<maxX, luminances: luminances, width: width)) {
            minY += 1
        }

        while minY + minimumSpan < maxY,
              originalMaxY - maxY < maxVerticalTrim,
              isWhiteEdgeLine(rowWhiteStats(y: maxY - 1, xRange: minX..<maxX, luminances: luminances, width: width)) {
            maxY -= 1
        }

        let sprocketTrim = trimSprocketBands(
            minX: minX,
            maxX: maxX,
            minY: minY,
            maxY: maxY,
            luminances: luminances,
            width: width
        )
        minY = sprocketTrim.minY
        maxY = sprocketTrim.maxY

        guard minX < maxX, minY < maxY else { return region }
        let trimmedRect = CGRect(
            x: Double(minX) / Double(width),
            y: Double(minY) / Double(height),
            width: Double(maxX - minX) / Double(width),
            height: Double(maxY - minY) / Double(height)
        ).normalized
        let refinedRect = locallyRefinedEdges(rect: trimmedRect, luminances: luminances, width: width, height: height)
        return CropRegion(
            index: region.index,
            rect: refinedRect.normalized,
            isManual: region.isManual
        )
    }

    private func locallyRefinedEdges(rect: CGRect, luminances: [Double], width: Int, height: Int) -> CGRect {
        guard width > 8, height > 8 else { return rect }
        let minX = max(1, min(width - 2, Int(rect.minX * Double(width))))
        let maxX = max(minX + 2, min(width - 2, Int(rect.maxX * Double(width))))
        let minY = max(1, min(height - 2, Int(rect.minY * Double(height))))
        let maxY = max(minY + 2, min(height - 2, Int(rect.maxY * Double(height))))
        let spanX = maxX - minX
        let spanY = maxY - minY
        let searchX = max(3, min(20, spanX / 10))
        let searchY = max(3, min(20, spanY / 10))
        let yRange = minY...maxY
        let xRange = minX...maxX

        let leftRange = max(1, minX - searchX)...min(width - 2, minX + searchX)
        let rightRange = max(1, maxX - searchX)...min(width - 2, maxX + searchX)
        let topRange = max(1, minY - searchY)...min(height - 2, minY + searchY)
        let bottomRange = max(1, maxY - searchY)...min(height - 2, maxY + searchY)

        let left = strongestVerticalEdge(luminances: luminances, width: width, xCandidates: leftRange, yRange: yRange) ?? minX
        let right = strongestVerticalEdge(luminances: luminances, width: width, xCandidates: rightRange, yRange: yRange) ?? maxX
        let top = strongestHorizontalEdge(luminances: luminances, width: width, xRange: xRange, yCandidates: topRange) ?? minY
        let bottom = strongestHorizontalEdge(luminances: luminances, width: width, xRange: xRange, yCandidates: bottomRange) ?? maxY

        guard right - left > max(8, spanX / 2), bottom - top > max(8, spanY / 2) else { return rect }
        return CGRect(
            x: Double(left) / Double(width),
            y: Double(top) / Double(height),
            width: Double(right - left) / Double(width),
            height: Double(bottom - top) / Double(height)
        ).normalized
    }

    private func columnWhiteStats(x: Int, yRange: Range<Int>, luminances: [Double], width: Int) -> (whiteRatio: Double, darkRatio: Double) {
        guard !yRange.isEmpty else { return (0, 0) }
        var whiteCount = 0
        var darkCount = 0
        for y in yRange {
            let value = luminances[y * width + x]
            if value >= 0.94 { whiteCount += 1 }
            if value <= 0.55 { darkCount += 1 }
        }
        let total = Double(yRange.count)
        return (Double(whiteCount) / total, Double(darkCount) / total)
    }

    private func rowWhiteStats(y: Int, xRange: Range<Int>, luminances: [Double], width: Int) -> (whiteRatio: Double, darkRatio: Double) {
        guard !xRange.isEmpty else { return (0, 0) }
        var whiteCount = 0
        var darkCount = 0
        let offset = y * width
        for x in xRange {
            let value = luminances[offset + x]
            if value >= 0.94 { whiteCount += 1 }
            if value <= 0.55 { darkCount += 1 }
        }
        let total = Double(xRange.count)
        return (Double(whiteCount) / total, Double(darkCount) / total)
    }

    private func trimSprocketBands(minX: Int, maxX: Int, minY: Int, maxY: Int, luminances: [Double], width: Int) -> (minY: Int, maxY: Int) {
        let regionHeight = maxY - minY
        let regionWidth = maxX - minX
        guard regionHeight > 40, regionWidth > 40 else { return (minY, maxY) }

        let maxInset = max(4, Int(Double(regionHeight) * 0.34))
        let minimumBody = max(18, Int(Double(regionHeight) * 0.28))
        var top = minY
        var bottom = maxY

        func rowFilmStats(_ y: Int) -> (white: Double, black: Double, body: Double) {
            var white = 0
            var black = 0
            var body = 0
            for x in minX..<maxX {
                let value = luminances[y * width + x]
                if value >= 0.9 { white += 1 }
                if value <= 0.18 { black += 1 }
                if value > 0.2 && value < 0.985 { body += 1 }
            }
            let total = Double(max(1, regionWidth))
            return (Double(white) / total, Double(black) / total, Double(body) / total)
        }

        func isPerforationRow(_ y: Int) -> Bool {
            let stats = rowFilmStats(y)
            return stats.black >= 0.36 && stats.white >= 0.045 && stats.body <= 0.62
        }

        func isBodyRow(_ y: Int) -> Bool {
            let stats = rowFilmStats(y)
            return stats.body >= 0.24 && stats.black < 0.72
        }

        let topSearchEnd = min(maxY - minimumBody, minY + maxInset)
        let topPerforationRows = topSearchEnd > minY ? (minY..<topSearchEnd).filter(isPerforationRow) : []
        if let lastTopPerforation = topPerforationRows.last {
            var candidate = lastTopPerforation + 1
            while candidate + minimumBody < maxY,
                  candidate - minY < maxInset,
                  !isBodyRow(candidate) {
                candidate += 1
            }
            if candidate + minimumBody < maxY {
                top = candidate
            }
        }

        let bottomSearchStart = max(top + minimumBody, maxY - maxInset)
        let bottomPerforationRows = bottomSearchStart < maxY ? (bottomSearchStart..<maxY).filter(isPerforationRow) : []
        if let firstBottomPerforation = bottomPerforationRows.first {
            var candidate = firstBottomPerforation
            while candidate - minimumBody > top,
                  maxY - candidate < maxInset,
                  !isBodyRow(candidate - 1) {
                candidate -= 1
            }
            if candidate - minimumBody > top {
                bottom = candidate
            }
        }

        guard !topPerforationRows.isEmpty || !bottomPerforationRows.isEmpty else { return (minY, maxY) }
        let safety = max(1, regionHeight / 160)
        return (max(minY, top - safety), min(maxY, bottom + safety))
    }

    private func fallbackCandidates(settings: CropSettings) -> [CropCandidate] {
        [
            CropCandidate(
                title: "整图留边",
                detail: "未识别到稳定分隔，先按边距裁切",
                regions: [CropRegion(index: 1, rect: marginRect(settings))],
                marginScale: 0,
                score: 0
            )
        ]
    }

    private func detectForegroundComponents(luminances: [Double], width: Int, height: Int, settings: CropSettings) -> [CropRegion] {
        let background = estimatedBackground(luminances: luminances, width: width, height: height)
        let threshold = max(0.045, (105 - settings.sensitivity) / 700)
        var mask = [Bool](repeating: false, count: width * height)

        for y in 0..<height {
            for x in 0..<width {
                let value = luminances[y * width + x]
                mask[y * width + x] = abs(value - background) > threshold
            }
        }

        mask = dilated(mask, width: width, height: height, iterations: 3)
        var boxes = connectedBoxes(mask: mask, width: width, height: height)
        boxes = mergeCloseBoxes(boxes, width: width, height: height)

        let minimumAreaRatio = max(0.001, settings.minimumRegionPercent / 100)
        let minimumArea = max(80, Int(Double(width * height) * minimumAreaRatio))
        boxes = boxes.filter { box in
            let area = box.width * box.height
            let notTiny = area >= minimumArea && box.width > width / 24 && box.height > height / 24
            let notWholeScan = !(Double(box.width) / Double(width) > 0.94 && Double(box.height) / Double(height) > 0.94)
            return notTiny && notWholeScan
        }

        guard !boxes.isEmpty else { return [] }

        let padX = max(3, Int(settings.left + settings.right) / 5)
        let padY = max(3, Int(settings.top + settings.bottom) / 5)
        return boxes
            .sorted { lhs, rhs in
                if abs(lhs.minY - rhs.minY) > max(8, height / 20) { return lhs.minY < rhs.minY }
                return lhs.minX < rhs.minX
            }
            .enumerated()
            .map { offset, box in
                let x = max(0, box.minX - padX)
                let y = max(0, box.minY - padY)
                let maxX = min(width, box.maxX + padX)
                let maxY = min(height, box.maxY + padY)
                let rect = CGRect(
                    x: Double(x) / Double(width),
                    y: Double(y) / Double(height),
                    width: Double(maxX - x) / Double(width),
                    height: Double(maxY - y) / Double(height)
                ).normalized
                return CropRegion(index: offset + 1, rect: rect)
            }
    }

    private func detectLocalContrastComponents(luminances: [Double], width: Int, height: Int, settings: CropSettings) -> [CropRegion] {
        guard width > 40, height > 40, luminances.count >= width * height else { return [] }

        let analysis = downsampledLuminancesIfNeeded(luminances: luminances, width: width, height: height, maxPixels: 260_000)
        let workLuminances = analysis.luminances
        let workWidth = analysis.width
        let workHeight = analysis.height
        let background = estimatedBackground(luminances: workLuminances, width: workWidth, height: workHeight)
        let radius = max(3, min(10, min(workWidth, workHeight) / 70))
        let localMeans = localMeanLuminances(luminances: workLuminances, width: workWidth, height: workHeight, radius: radius)
        var scores = [Double](repeating: 0, count: workWidth * workHeight)
        var sampleScores: [Double] = []
        sampleScores.reserveCapacity(workWidth * workHeight / 4)

        for y in 1..<(workHeight - 1) {
            for x in 1..<(workWidth - 1) {
                let index = y * workWidth + x
                let value = workLuminances[index]
                let localContrast = abs(value - localMeans[index])
                let horizontalEdge = abs(workLuminances[index + 1] - workLuminances[index - 1])
                let verticalEdge = abs(workLuminances[index + workWidth] - workLuminances[index - workWidth])
                let gradient = max(horizontalEdge, verticalEdge)
                let backgroundContrast = abs(value - background)
                let score = localContrast * 0.78 + gradient * 0.92 + backgroundContrast * 0.14
                scores[index] = score

                if x % 2 == 0, y % 2 == 0 {
                    sampleScores.append(score)
                }
            }
        }

        guard !sampleScores.isEmpty else { return [] }
        let baseThreshold = percentile(sampleScores, fraction: 0.82)
        let sensitivityAdjustment = (settings.sensitivity - 50) / 900
        let threshold = max(0.026, min(0.18, baseThreshold - sensitivityAdjustment))
        let borderInset = max(2, min(workWidth, workHeight) / 180)
        var mask = [Bool](repeating: false, count: workWidth * workHeight)

        for y in borderInset..<(workHeight - borderInset) {
            for x in borderInset..<(workWidth - borderInset) {
                let index = y * workWidth + x
                guard scores[index] >= threshold else { continue }
                let value = workLuminances[index]
                let notFlatBackground = abs(value - background) > 0.035 || scores[index] >= threshold * 1.35
                mask[index] = notFlatBackground && value > 0.025 && value < 0.995
            }
        }

        mask = dilated(mask, width: workWidth, height: workHeight, iterations: 2)
        var boxes = connectedBoxes(mask: mask, width: workWidth, height: workHeight)
        boxes = mergeLocalContrastBoxes(boxes, width: workWidth, height: workHeight)

        let minimumAreaRatio = max(0.0007, settings.minimumRegionPercent / 180)
        let minimumArea = max(70, Int(Double(workWidth * workHeight) * minimumAreaRatio))
        let maximumWholeScanArea = Double(workWidth * workHeight) * 0.92

        let rects = boxes.compactMap { box -> CGRect? in
            let area = box.width * box.height
            guard area >= minimumArea,
                  Double(area) < maximumWholeScanArea,
                  box.width > max(16, workWidth / 36),
                  box.height > max(16, workHeight / 36) else {
                return nil
            }

            let density = maskDensity(mask: mask, width: workWidth, box: box)
            guard density >= 0.018 else { return nil }

            let padX = max(2, min(workWidth / 90, box.width / 14))
            let padY = max(2, min(workHeight / 90, box.height / 14))
            let rect = CGRect(
                x: Double(max(0, box.minX - padX)) / Double(workWidth),
                y: Double(max(0, box.minY - padY)) / Double(workHeight),
                width: Double(min(workWidth - 1, box.maxX + padX) - max(0, box.minX - padX) + 1) / Double(workWidth),
                height: Double(min(workHeight - 1, box.maxY + padY) - max(0, box.minY - padY) + 1) / Double(workHeight)
            ).normalized

            let refined = refinedByOtsuAndEdges(luminances: workLuminances, width: workWidth, height: workHeight, rect: rect) ?? rect
            let aspect = refined.width / max(refined.height, 0.001)
            guard refined.area >= 0.0035,
                  refined.width > 0.035,
                  refined.height > 0.035,
                  aspect >= 0.16,
                  aspect <= 7.5,
                  !(refined.width > 0.94 && refined.height > 0.94) else {
                return nil
            }
            return refined
        }

        let merged = mergeNormalizedRects(rects, overlapThreshold: 0.46)
        return indexedRegions(from: merged, settings: settings)
    }

    private func detectWithExternalDetector(imageURL: URL, imageWidth: Int, imageHeight: Int, settings: CropSettings) -> [CropRegion] {
        guard imageWidth > 0, imageHeight > 0 else { return [] }
        let detector = ExternalDetector()
        let result = detector.detect(imageURL: imageURL)

        guard case .success(let detection) = result else {
            return []
        }

        let rects = detection.boxes.compactMap { box -> CGRect? in
            let confidence = box.confidence ?? 0.5
            guard confidence >= 0.12 else { return nil }

            let left = max(0, min(Double(imageWidth), box.left))
            let top = max(0, min(Double(imageHeight), box.top))
            let right = max(left, min(Double(imageWidth), box.right))
            let bottom = max(top, min(Double(imageHeight), box.bottom))
            guard right - left > Double(imageWidth) * 0.025,
                  bottom - top > Double(imageHeight) * 0.025 else {
                return nil
            }

            let rect = CGRect(
                x: left / Double(imageWidth),
                y: top / Double(imageHeight),
                width: (right - left) / Double(imageWidth),
                height: (bottom - top) / Double(imageHeight)
            ).normalized
            guard rect.area >= 0.0035,
                  !(rect.width > 0.94 && rect.height > 0.94) else {
                return nil
            }
            return rect
        }

        let merged = mergeNormalizedRects(rects, overlapThreshold: 0.42)
        return indexedRegions(from: merged, settings: settings)
    }

    private func writeCrops(photo: PhotoItem, task: FolderTask, regions: [CropRegion]) -> [URL] {
        guard let image = NSImage(contentsOf: photo.url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }

        var outputs: [URL] = []
        for (offset, region) in regions.enumerated() {
            let crop = region.rect
            let cropped: CGImage?
            if abs(region.angle) > 0.05 {
                cropped = rotatedCrop(cgImage, normalizedRect: crop, angleDegrees: region.angle)
            } else {
                let pixelRect = CGRect(
                    x: crop.minX * Double(cgImage.width),
                    y: crop.minY * Double(cgImage.height),
                    width: crop.width * Double(cgImage.width),
                    height: crop.height * Double(cgImage.height)
                ).integral
                cropped = cgImage.cropping(to: pixelRect)
            }
            guard let cropped else { continue }
            let outputURL = outputURL(for: photo, task: task, sliceIndex: offset + 1)
            do {
                try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let bitmap = NSBitmapImageRep(cgImage: cropped)
                guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.94]) else { continue }
                try data.write(to: outputURL, options: .atomic)
                outputs.append(outputURL)
            } catch {
                continue
            }
        }
        return outputs
    }

    /// Estimates a frame's tilt (degrees, about its centre) by projection-profile
    /// sharpness: a frame's straight gutters/edges produce the crispest row and
    /// column projections when the sampling axes line up with them, so we sweep a
    /// small angle range and keep the angle that maximises that crispness. Returns
    /// 0 unless a tilt is clearly better than straight, so square frames stay put.
    // Internal so the validation test target can exercise the production
    // estimator directly.
    func estimateRegionTilt(gray: [UInt8], width: Int, height: Int, rect: CGRect) -> Double {
        let x0 = Int((rect.minX * Double(width)).rounded())
        let y0 = Int((rect.minY * Double(height)).rounded())
        let bw = Int((rect.width * Double(width)).rounded())
        let bh = Int((rect.height * Double(height)).rounded())
        guard bw > 24, bh > 24, x0 >= 0, y0 >= 0, x0 + bw <= width, y0 + bh <= height else { return 0 }

        // Downsample the box to keep the sweep cheap; tilt is scale-invariant.
        let maxDim = 240
        let step = max(1, max(bw, bh) / maxDim)
        let sw = bw / step
        let sh = bh / step
        guard sw > 8, sh > 8 else { return 0 }

        var buf = [Double](repeating: 0, count: sw * sh)
        for sy in 0..<sh {
            let srcY = y0 + sy * step
            for sx in 0..<sw {
                buf[sy * sw + sx] = Double(gray[srcY * width + x0 + sx * step])
            }
        }

        // A tilt estimate needs actual edges. Without this guard, a uniform
        // frame or a smooth exposure gradient can win solely because rotated
        // projection bins contain different numbers of pixels.
        var strongEdgeCount = 0
        let edgeThreshold = 12.0
        for y in 0..<sh {
            for x in 0..<sw {
                let value = buf[y * sw + x]
                if x > 0, abs(value - buf[y * sw + x - 1]) >= edgeThreshold {
                    strongEdgeCount += 1
                }
                if y > 0, abs(value - buf[(y - 1) * sw + x]) >= edgeThreshold {
                    strongEdgeCount += 1
                }
            }
        }
        guard strongEdgeCount >= max(8, (sw + sh) / 4) else { return 0 }

        let cxF = Double(sw) / 2, cyF = Double(sh) / 2
        func sharpness(_ angle: Double) -> Double {
            let s = sin(angle), c = cos(angle)
            var rows = [Double](repeating: 0, count: sh)
            var cols = [Double](repeating: 0, count: sw)
            var rowCounts = [Int](repeating: 0, count: sh)
            var colCounts = [Int](repeating: 0, count: sw)
            for y in 0..<sh {
                let dy = Double(y) - cyF
                for x in 0..<sw {
                    let dx = Double(x) - cxF
                    let v = buf[y * sw + x]
                    let r = Int((dx * s + dy * c + cyF).rounded())
                    let k = Int((dx * c - dy * s + cxF).rounded())
                    if r >= 0, r < sh { rows[r] += v; rowCounts[r] += 1 }
                    if k >= 0, k < sw { cols[k] += v; colCounts[k] += 1 }
                }
            }
            for i in rows.indices where rowCounts[i] > 0 { rows[i] /= Double(rowCounts[i]) }
            for i in cols.indices where colCounts[i] > 0 { cols[i] /= Double(colCounts[i]) }

            func crisp(_ p: [Double], counts: [Int]) -> Double {
                var sum = 0.0
                for i in 1..<p.count where counts[i] > 0 && counts[i - 1] > 0 {
                    let d = p[i] - p[i - 1]
                    sum += d * d
                }
                return sum
            }
            return crisp(rows, counts: rowCounts) + crisp(cols, counts: colCounts)
        }

        let base = sharpness(0)
        var bestAngle = 0.0
        var bestScore = base
        var a = -8.0
        while a <= 8.0 {
            if abs(a) > 0.01 {
                let sc = sharpness(a * .pi / 180)
                if sc > bestScore { bestScore = sc; bestAngle = a }
            }
            a += 0.25
        }
        // Require a clear win over straight, otherwise leave the frame as-is.
        return bestScore > base * 1.04 ? bestAngle : 0
    }

    /// Cuts out a tilted frame and rotates it upright. `normalizedRect` is the
    /// un-rotated box (0…1, top-left origin); `angleDegrees` is its tilt about
    /// the box centre. The output is the box's content, deskewed.
    private func rotatedCrop(_ src: CGImage, normalizedRect rect: CGRect, angleDegrees: Double) -> CGImage? {
        let imgW = Double(src.width)
        let imgH = Double(src.height)
        let outW = max(1, Int((rect.width * imgW).rounded()))
        let outH = max(1, Int((rect.height * imgH).rounded()))
        // Box centre in CoreGraphics' bottom-left, y-up pixel space.
        let cx = rect.midX * imgW
        let cy = (1.0 - rect.midY) * imgH

        let colorSpace = src.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high
        // Place the (rotated) box centre at the output centre, undo the tilt,
        // then draw the whole source upright (CG-native orientation).
        ctx.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        ctx.rotate(by: CGFloat(angleDegrees * .pi / 180))
        ctx.translateBy(x: -CGFloat(cx), y: -CGFloat(cy))
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: imgW, height: imgH))
        return ctx.makeImage()
    }

    private func outputURL(for photo: PhotoItem, task: FolderTask, sliceIndex: Int) -> URL {
        let relativeParent = URL(fileURLWithPath: photo.relativePath).deletingLastPathComponent().path
        let outputRoot = task.rootURL.deletingLastPathComponent().appendingPathComponent("\(task.rootURL.lastPathComponent)_ImgSlicer_Output", isDirectory: true)
        let parent = relativeParent == "." ? outputRoot : outputRoot.appendingPathComponent(relativeParent, isDirectory: true)
        let stem = photo.url.deletingPathExtension().lastPathComponent
        return parent.appendingPathComponent("\(stem)_slice_\(String(format: "%02d", sliceIndex)).jpg")
    }

    private func detectByProjectionSeparators(gray: [UInt8], width: Int, height: Int, settings: CropSettings) -> [CropRegion] {
        let orientation = projectionOrientation(width: width, height: height, settings: settings)
        let boxes: [IntBox]

        if orientation == .portrait {
            let rotated = rotateClockwise(gray: gray, width: width, height: height)
            let rotatedBoxes = detectProjectionBoxes(gray: rotated.bytes, width: height, height: width, settings: settings)
            boxes = rotatedBoxes.map { box in
                IntBox(
                    left: width - box.bottom,
                    top: box.left,
                    right: width - box.top,
                    bottom: box.right
                ).clamped(width: width, height: height)
            }
        } else {
            boxes = detectProjectionBoxes(gray: gray, width: width, height: height, settings: settings)
        }

        let merged = mergeFalseProjectionSplits(gray: gray, width: width, height: height, boxes: orderBoxes(boxes, imageWidth: width, imageHeight: height))
        let trimmed = merged.map { trimUniformBlackEdges(gray: gray, width: width, height: height, box: $0) }.filter(\.isValid)
        guard trimmed.count > 1 else { return [] }

        let rects = orderBoxes(trimmed, imageWidth: width, imageHeight: height).map { box in
            CGRect(
                x: Double(box.left) / Double(width),
                y: Double(box.top) / Double(height),
                width: Double(box.width) / Double(width),
                height: Double(box.height) / Double(height)
            ).normalized
        }
        return indexedRegions(from: mergeNormalizedRects(rects, overlapThreshold: 0.5), settings: settings)
    }

    private enum ProjectionOrientation {
        case landscape
        case portrait
    }

    private func projectionOrientation(width: Int, height: Int, settings: CropSettings) -> ProjectionOrientation {
        switch settings.orientation {
        case .portrait:
            return .portrait
        case .landscape:
            return .landscape
        case .automatic:
            return width >= height ? .landscape : .portrait
        }
    }

    private func detectProjectionBoxes(gray: [UInt8], width: Int, height: Int, settings: CropSettings) -> [IntBox] {
        let rows = detectProjectionRows(gray: gray, width: width, height: height)
        guard !rows.isEmpty else { return [] }

        var rowColumns: [[IntSegment]] = []
        for row in rows {
            rowColumns.append(detectColumnsInRow(gray: gray, width: width, row: row, settings: settings))
        }

        let referenceColumns = chooseReferenceColumns(rowColumns)
        var boxes: [IntBox] = []
        for (rowIndex, row) in rows.enumerated() {
            var columns = forceColumnsFromLayout(
                gray: gray,
                width: width,
                row: row,
                columns: rowColumns[rowIndex],
                reference: referenceColumns
            )
            columns = trimOuterBlankColumnEdges(gray: gray, width: width, row: row, columns: columns)

            if columns.isEmpty {
                let box = IntBox(left: 0, top: row.start, right: width, bottom: row.end)
                if box.isValid { boxes.append(box) }
                continue
            }

            for column in columns {
                let box = IntBox(left: column.start, top: row.start, right: column.end, bottom: row.end).clamped(width: width, height: height)
                if box.isValid { boxes.append(box) }
            }
        }

        return mergeFalseProjectionSplits(gray: gray, width: width, height: height, boxes: boxes)
    }

    /// Render the original image to a full-resolution grayscale buffer for the
    /// final boundary snap. Capped at ~5000px on the long side so the scan stays
    /// crisp without unbounded memory. nil on failure (snap skipped).
    private func fullResolutionGray(cgImage: CGImage) -> (bytes: [UInt8], width: Int, height: Int)? {
        let cap = 5000
        let longSide = max(cgImage.width, cgImage.height)
        let scale = longSide > cap ? Double(cap) / Double(longSide) : 1.0
        let width = max(1, Int(Double(cgImage.width) * scale))
        let height = max(1, Int(Double(cgImage.height) * scale))
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
            return nil
        }
        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (grayscaleBytes(bitmap: bitmap, width: width, height: height), width, height)
    }

    // Shadow-lift LUT (gamma 0.45): expands dark tones so the texture of dark
    // *content* (shaded wood, deep shadow) becomes visible, while a flat black
    // gutter stays flat. This is a detection-only transform — output crops use
    // the original pixels — exactly the "temporarily brighten to recognise"
    // idea, applied to the analysis buffer.
    private static let shadowLiftLUT: [Double] = (0..<256).map { pow(Double($0) / 255.0, 0.45) * 255.0 }

    /// Snap each frame's left/right edge to the true gutter↔content transition.
    ///
    /// The split step (run at ~600px) can't tell a thin black gutter from dark
    /// textured content, so an edge may keep the gutter (too loose) or sit
    /// inside the subject (too tight). Working at full resolution and on
    /// shadow-lifted values, every column is classed as flat *gutter* (dark and
    /// textureless) or *content* (textured). The edge is then moved either
    /// inward — off a gutter onto the first content — or outward — back across
    /// dark-but-textured content until the real gutter — so both failure
    /// directions converge on the same boundary.
    /// Pull frames that break a film strip's regular rhythm back onto the grid.
    ///
    /// A roll's frames share one pitch (left-edge to left-edge) and one width,
    /// so the consistent majority of frames defines a grid; an outlier — a frame
    /// whose width or position deviates (because the split mis-cut it and the
    /// edge snap had no clean gutter to lock onto) — is replaced by its grid
    /// prediction. Conservative: it only fires on a clearly single-row strip
    /// where most frames already agree, and only moves the outliers.
    /// Last-resort placement for an edge with NO pixel evidence: when a left or
    /// right edge's reliability is ~0 (a dark subject with no detectable gutter,
    /// where the snap had nothing to lock onto), put it at the strip's regular
    /// grid position. The consensus idea applied safely — it ONLY moves edges
    /// the reliability flags as evidence-free that ALSO break the rhythm, so an
    /// edge snapped to a real gutter is never overridden. Top/bottom are left
    /// alone (low reliability there is tilt, not a placement error).
    private func gridFallbackUnreliableEdges(regions: [CropRegion], gray: [UInt8], width: Int, height: Int) -> [CropRegion] {
        guard regions.count >= 4 else { return regions }
        let rel = edgeReliabilities(regions: regions, gray: gray, width: width, height: height)
        guard rel.count == regions.count else { return regions }
        func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }

        let order = regions.indices.sorted { regions[$0].rect.normalized.midX < regions[$1].rect.normalized.midX }
        let rects = order.map { regions[$0].rect.normalized }

        // Single-row gate.
        let heights = rects.map { Double($0.height) }
        guard let hMin = heights.min(), let hMax = heights.max(), hMin > 0, hMax / hMin < 1.4 else { return regions }
        let centreYs = rects.map { Double($0.midY) }
        let meanY = centreYs.reduce(0, +) / Double(centreYs.count)
        let stdY = (centreYs.reduce(0) { $0 + ($1 - meanY) * ($1 - meanY) } / Double(centreYs.count)).squareRoot()
        guard stdY < median(heights) * 0.15 else { return regions }

        let widths = rects.map { Double($0.width) }
        let centres = rects.map { Double($0.midX) }
        let medianW = median(widths)
        guard medianW > 0.02 else { return regions }
        let gaps = zip(centres.dropFirst(), centres).map { $0 - $1 }
        guard !gaps.isEmpty else { return regions }
        let pitch = median(gaps)
        guard pitch > medianW * 0.5 else { return regions }
        let residuals = centres.enumerated().map { $0.element - Double($0.offset) * pitch }
        let anchor = median(residuals)
        func predictedCentre(_ i: Int) -> Double { anchor + Double(i) * pitch }

        // Trust the grid only if it's a regular strip: most frames already sit
        // near the median width. (Width consistency is a steadier "is this a
        // regular roll" signal than per-edge reliability, which runs low on
        // right edges even when the layout is regular.)
        let consistentFrames = widths.filter { $0 >= medianW * 0.75 && $0 <= medianW * 1.3 }.count
        guard consistentFrames >= regions.count - 1 else { return regions }

        let relThresh = 0.12
        let minDeviation = medianW * 0.10

        var output = regions
        for (sortedIdx, origIdx) in order.enumerated() {
            let r = rects[sortedIdx]
            var left = Double(r.minX), right = Double(r.maxX)
            let predL = predictedCentre(sortedIdx) - medianW / 2
            let predR = predictedCentre(sortedIdx) + medianW / 2
            var changed = false
            if rel[origIdx][0] <= relThresh, abs(left - predL) > minDeviation { left = max(0, predL); changed = true }
            if rel[origIdx][1] <= relThresh, abs(right - predR) > minDeviation { right = min(1, predR); changed = true }
            guard changed, right - left > 0.02 else { continue }
            let newRect = CGRect(x: left, y: r.minY, width: right - left, height: r.height).normalized
            output[origIdx] = CropRegion(index: regions[origIdx].index, rect: newRect, angle: regions[origIdx].angle, isManual: regions[origIdx].isManual)
        }
        return output
    }

    private func regularizeStripGrid(_ regions: [CropRegion]) -> [CropRegion] {
        guard regions.count >= 3 else { return regions }
        let sorted = regions.enumerated().sorted { $0.element.rect.normalized.midX < $1.element.rect.normalized.midX }
        let rects = sorted.map { $0.element.rect.normalized }

        // Single-row gate: similar heights and vertical centres in a tight band.
        let heights = rects.map { Double($0.height) }
        guard let hMin = heights.min(), let hMax = heights.max(), hMin > 0, hMax / hMin < 1.4 else { return regions }
        let centreYs = rects.map { Double($0.midY) }
        let meanY = centreYs.reduce(0, +) / Double(centreYs.count)
        let stdY = (centreYs.reduce(0) { $0 + ($1 - meanY) * ($1 - meanY) } / Double(centreYs.count)).squareRoot()
        let medianH = heights.sorted()[heights.count / 2]
        guard stdY < medianH * 0.15 else { return regions }   // a grid (multi-row) would spread Y

        func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }
        let widths = rects.map { Double($0.width) }
        let centres = rects.map { Double($0.midX) }
        let medianW = median(widths)
        guard medianW > 0 else { return regions }

        // Pitch from consecutive centre gaps; anchor from the median residual.
        let gaps = zip(centres.dropFirst(), centres).map { $0 - $1 }
        guard !gaps.isEmpty else { return regions }
        let pitch = median(gaps)
        guard pitch > medianW * 0.5 else { return regions }
        let residuals = centres.enumerated().map { $0.element - Double($0.offset) * pitch }
        let anchor = median(residuals)
        func predictedCentre(_ i: Int) -> Double { anchor + Double(i) * pitch }

        // Need a consistent majority before trusting the grid.
        let consistent = (0..<rects.count).filter { i in
            abs(centres[i] - predictedCentre(i)) <= pitch * 0.18 &&
            widths[i] >= medianW * 0.85 && widths[i] <= medianW * 1.15
        }
        guard consistent.count >= max(3, (rects.count * 2 + 2) / 3) else { return regions }

        // The frames of a single row also share one top and one bottom edge, so
        // a frame whose top/bottom broke from the row — e.g. a bright sky top
        // that edge-trimming mistook for the film border and cut into — is
        // snapped back to the row's consensus top/bottom.
        let tops = rects.map { Double($0.minY) }
        let bottoms = rects.map { Double($0.maxY) }
        let medianTop = median(tops)
        let medianBottom = median(bottoms)
        let yTolerance = medianH * 0.08

        // Rebuild, correcting only the outliers (X grid and Y row-edges).
        var output = regions
        for (i, item) in sorted.enumerated() {
            let r = rects[i]
            let xOutlier = abs(centres[i] - predictedCentre(i)) > pitch * 0.35 ||
                widths[i] < medianW * 0.78 || widths[i] > medianW * 1.28
            let newX = xOutlier ? predictedCentre(i) - medianW / 2 : Double(r.minX)
            let newW = xOutlier ? medianW : Double(r.width)

            var newTop = Double(r.minY)
            var newBottom = Double(r.maxY)
            if abs(newTop - medianTop) > yTolerance { newTop = medianTop }
            if abs(newBottom - medianBottom) > yTolerance { newBottom = medianBottom }

            let yChanged = newTop != Double(r.minY) || newBottom != Double(r.maxY)
            guard xOutlier || yChanged else { continue }

            let newRect = CGRect(x: newX, y: newTop, width: newW, height: newBottom - newTop)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !newRect.isNull, newRect.width > 0.02, newRect.height > 0.02 else { continue }
            output[item.offset] = CropRegion(index: item.element.index, rect: newRect.normalized, angle: item.element.angle, isManual: item.element.isManual)
        }
        return output
    }

    /// Fill in grid cells the layout implies but detection missed — e.g. a black
    /// or subject-less frame at the end of a film-strip row that produced no
    /// edges, so no box was ever created for it. Pure geometry: it groups the
    /// detected boxes into rows, learns the column lattice (pitch/width/origin)
    /// from the most-populated (fully-occupied) row, and adds any lattice cell a
    /// row is missing. Conservative — it requires a clean multi-row grid whose
    /// richest row is evenly spaced (so the true column count is known), never
    /// moves existing boxes, never invents whole rows, and skips rows that don't
    /// align to the lattice. Synthesized cells stay axis-aligned (angle 0): an
    /// empty frame has no content to deskew.
    private func completeGridLattice(_ regions: [CropRegion]) -> [CropRegion] {
        guard regions.count >= 4 else { return regions }
        let rects = regions.map { $0.rect.normalized }
        func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }

        let medianH = median(rects.map { Double($0.height) })
        guard medianH > 0 else { return regions }

        // Group boxes into rows by vertical centre proximity.
        let rowTol = medianH * 0.4
        let order = regions.indices.sorted { Double(rects[$0].midY) < Double(rects[$1].midY) }
        var rows: [[Int]] = []
        for i in order {
            if let ref = rows.last?.first, abs(Double(rects[i].midY) - Double(rects[ref].midY)) <= rowTol {
                rows[rows.count - 1].append(i)
            } else {
                rows.append([i])
            }
        }
        guard rows.count >= 2 else { return regions }

        let medianW = median(rects.map { Double($0.width) })
        guard medianW > 0.02 else { return regions }

        // The richest row defines the column lattice. It must be evenly spaced,
        // i.e. genuinely fully populated, so its cell count is the column count.
        guard let richest = rows.max(by: { $0.count < $1.count }), richest.count >= 3 else { return regions }
        let richCentres = richest.map { Double(rects[$0].midX) }.sorted()
        let richGaps = zip(richCentres.dropFirst(), richCentres).map { $0 - $1 }
        guard !richGaps.isEmpty else { return regions }
        let pitch = median(richGaps)
        guard pitch > medianW * 0.85, pitch < medianW * 1.8 else { return regions }
        guard richGaps.allSatisfy({ $0 > pitch * 0.8 && $0 < pitch * 1.2 }) else { return regions }

        let originX = richCentres.first!
        let columnCount = richest.count
        guard columnCount <= 24 else { return regions }
        func columnCentre(_ c: Int) -> Double { originX + Double(c) * pitch }

        var added: [CropRegion] = []
        for row in rows {
            // Only synthesize for rows that cleanly align to the lattice.
            var occupied = Set<Int>()
            var aligned = true
            for idx in row {
                let c = Int(((Double(rects[idx].midX) - originX) / pitch).rounded())
                if c < 0 || c >= columnCount || occupied.contains(c) { aligned = false; break }
                occupied.insert(c)
            }
            guard aligned, occupied.count < columnCount else { continue }

            let rRects = row.map { rects[$0] }
            let topC = median(rRects.map { Double($0.minY) })
            let botC = median(rRects.map { Double($0.maxY) })
            guard botC - topC > 0.02 else { continue }

            for c in 0..<columnCount where !occupied.contains(c) {
                let x = max(0, columnCentre(c) - medianW / 2)
                let w = min(medianW, 1 - x)
                let y = max(0, topC)
                let h = min(botC, 1) - y
                guard w > 0.02, h > 0.02 else { continue }
                let rect = CGRect(x: x, y: y, width: w, height: h).normalized
                // Never duplicate a box that already covers this cell.
                let overlaps = regions.contains { existing in
                    let e = existing.rect.normalized
                    let iw = max(0, min(Double(e.maxX), Double(rect.maxX)) - max(Double(e.minX), Double(rect.minX)))
                    let ih = max(0, min(Double(e.maxY), Double(rect.maxY)) - max(Double(e.minY), Double(rect.minY)))
                    return iw * ih > 0.4 * Double(rect.width * rect.height)
                }
                if !overlaps {
                    added.append(CropRegion(index: 0, rect: rect, angle: 0, isManual: false))
                }
            }
        }
        guard !added.isEmpty else { return regions }

        // Re-sort row-major (top-to-bottom, then left-to-right) and re-index.
        let merged = (regions + added).sorted {
            let a = $0.rect.normalized, b = $1.rect.normalized
            if abs(Double(a.midY) - Double(b.midY)) > rowTol { return Double(a.midY) < Double(b.midY) }
            return Double(a.midX) < Double(b.midX)
        }
        return merged.enumerated().map {
            CropRegion(index: $0.offset + 1, rect: $0.element.rect, angle: $0.element.angle, isManual: $0.element.isManual)
        }
    }

    /// Per-frame edge reliability in [0,1] for [left, right, top, bottom]: how
    /// cleanly each edge sits at a gutter→content transition — film gutter just
    /// OUTSIDE the box, photographic content just INSIDE. A clean boundary scores
    /// high; an edge cut into the subject (no gutter outside) or one that still
    /// includes gutter (no content inside) scores low. This is the trust signal
    /// the consensus-template step uses to decide which edges to keep and which
    /// to reconstruct from the template.
    func edgeReliabilities(regions: [CropRegion], cgImage: CGImage) -> [[Double]] {
        guard let g = fullResolutionGray(cgImage: cgImage) else { return regions.map { _ in [0, 0, 0, 0] } }
        return edgeReliabilities(regions: regions, gray: g.bytes, width: g.width, height: g.height)
    }

    func edgeReliabilities(regions: [CropRegion], gray: [UInt8], width W: Int, height H: Int) -> [[Double]] {
        guard W > 8, H > 8, gray.count >= W * H else { return regions.map { _ in [0, 0, 0, 0] } }
        let lut = ImageProcessor.shadowLiftLUT
        let textureMin = 22.0, darkMax = 70.0, brightMin = 215.0, rawFlatMax = 12.0

        func columnIsContentGutter(_ x: Int, _ yr: Range<Int>) -> (content: Bool, gutter: Bool) {
            var s = 0.0, sq = 0.0, r = 0.0, rsq = 0.0
            for y in yr { let v = gray[y * W + x]; s += lut[Int(v)]; sq += lut[Int(v)] * lut[Int(v)]; r += Double(v); rsq += Double(v) * Double(v) }
            let n = Double(yr.count), m = r / n
            let ls = (sq / n - (s / n) * (s / n)).squareRoot(), rs = (rsq / n - m * m).squareRoot()
            let gut = rs <= rawFlatMax && (m <= darkMax || m >= brightMin)
            return (!gut && ls >= textureMin, gut)
        }
        func rowIsContentGutter(_ y: Int, _ xr: Range<Int>) -> (content: Bool, gutter: Bool) {
            var s = 0.0, sq = 0.0, r = 0.0, rsq = 0.0
            let off = y * W
            for x in xr { let v = gray[off + x]; s += lut[Int(v)]; sq += lut[Int(v)] * lut[Int(v)]; r += Double(v); rsq += Double(v) * Double(v) }
            let n = Double(xr.count), m = r / n
            let ls = (sq / n - (s / n) * (s / n)).squareRoot(), rs = (rsq / n - m * m).squareRoot()
            let gut = rs <= rawFlatMax && (m <= darkMax || m >= brightMin)
            return (!gut && ls >= textureMin, gut)
        }

        return regions.map { region in
            let rect = region.rect.normalized
            let minX = max(0, min(W - 1, Int(rect.minX * Double(W))))
            let maxX = max(minX + 1, min(W, Int(rect.maxX * Double(W))))
            let minY = max(0, min(H - 1, Int(rect.minY * Double(H))))
            let maxY = max(minY + 1, min(H, Int(rect.maxY * Double(H))))
            let bw = maxX - minX, bh = maxY - minY
            guard bw > 16, bh > 16 else { return [0, 0, 0, 0] }
            let band = max(2, Int(Double(min(bw, bh)) * 0.012))
            let slices = 6

            // A vertical edge is scored in horizontal slices so a TILTED gutter
            // (gutter only over part of the height of any single column) still
            // scores high: each slice checks its own local outside-gutter /
            // inside-content transition. Reliability = fraction of slices that
            // show the transition.
            func verticalEdge(at x: Int, outsideLeft: Bool) -> Double {
                guard x > 0, x < W else { return 1.0 }  // image border: nothing to verify
                var ok = 0, total = 0
                for s in 0..<slices {
                    let y0 = minY + bh / 10 + (bh * 8 / 10) * s / slices
                    let y1 = minY + bh / 10 + (bh * 8 / 10) * (s + 1) / slices
                    guard y1 > y0 else { continue }
                    let yr = y0..<y1
                    let insideRange = outsideLeft ? x..<min(x + band, maxX) : max(minX, x - band)..<x
                    let outsideRange = outsideLeft ? max(0, x - band)..<x : x..<min(W, x + band)
                    let inside = insideRange.contains { columnIsContentGutter($0, yr).content }
                    let outside = outsideRange.contains { columnIsContentGutter($0, yr).gutter }
                    total += 1
                    if inside && outside { ok += 1 }
                }
                return total == 0 ? 0 : Double(ok) / Double(total)
            }
            func horizontalEdge(at y: Int, outsideTop: Bool) -> Double {
                guard y > 0, y < H else { return 1.0 }
                var ok = 0, total = 0
                for s in 0..<slices {
                    let x0 = minX + bw / 10 + (bw * 8 / 10) * s / slices
                    let x1 = minX + bw / 10 + (bw * 8 / 10) * (s + 1) / slices
                    guard x1 > x0 else { continue }
                    let xr = x0..<x1
                    let insideRange = outsideTop ? y..<min(y + band, maxY) : max(minY, y - band)..<y
                    let outsideRange = outsideTop ? max(0, y - band)..<y : y..<min(H, y + band)
                    let inside = insideRange.contains { rowIsContentGutter($0, xr).content }
                    let outside = outsideRange.contains { rowIsContentGutter($0, xr).gutter }
                    total += 1
                    if inside && outside { ok += 1 }
                }
                return total == 0 ? 0 : Double(ok) / Double(total)
            }
            return [
                verticalEdge(at: minX, outsideLeft: true),
                verticalEdge(at: maxX, outsideLeft: false),
                horizontalEdge(at: minY, outsideTop: true),
                horizontalEdge(at: maxY, outsideTop: false),
            ]
        }
    }

    /// Split a frame that actually holds two (or more) photos because the 600px
    /// pass missed the dark gutter between them — common when both neighbours
    /// are dark (an aquarium strip). A frame much wider than the strip's median
    /// is a merge of k≈width/median photos; the hidden gutter near each expected
    /// boundary is recovered at full resolution (the darkest flat column) and
    /// the frame is cut there. Conservative: only fires when EVERY expected
    /// gutter is actually found, so a genuinely wide single frame is left alone.
    /// The new sub-frame edges sit on the gutters; the following snap refines
    /// them onto the content.
    private func splitMergedFrames(regions: [CropRegion], gray: [UInt8], width: Int, height: Int) -> [CropRegion] {
        guard regions.count >= 2, width > 8, height > 8, gray.count >= width * height else { return regions }
        let normWidths = regions.map { Double($0.rect.normalized.width) }.sorted()
        let medianW = normWidths[normWidths.count / 2]
        guard medianW > 0.04 else { return regions }

        func columnMeanStd(_ x: Int, _ yr: Range<Int>) -> (mean: Double, std: Double) {
            var sum = 0.0, sq = 0.0
            for y in yr { let v = Double(gray[y * width + x]); sum += v; sq += v * v }
            let n = Double(yr.count), m = sum / n
            return (m, (sq / n - m * m).squareRoot())
        }

        var out: [CropRegion] = []
        for region in regions {
            let r = region.rect.normalized
            let k = Int((Double(r.width) / medianW).rounded())
            // ≥1.45× median = at least a double frame. The "every gutter must be
            // found" guard below is the real safety against splitting a genuinely
            // wide single frame, so this threshold can be generous.
            guard k >= 2, Double(r.width) >= medianW * 1.45 else { out.append(region); continue }
            let x0 = max(0, Int(r.minX * Double(width))), x1 = min(width, Int(r.maxX * Double(width)))
            let y0 = max(0, Int(r.minY * Double(height))), y1 = min(height, Int(r.maxY * Double(height)))
            guard x1 - x0 > 16, y1 - y0 > 16 else { out.append(region); continue }
            let yr = (y0 + (y1 - y0) / 6)..<(y1 - (y1 - y0) / 6)
            guard !yr.isEmpty else { out.append(region); continue }

            // Find a dark, flat gutter near each of the k-1 expected boundaries.
            var cuts: [Int] = []
            for i in 1..<k {
                let target = x0 + (x1 - x0) * i / k
                let win = max(8, (x1 - x0) / (k * 3))
                var best: (mean: Double, x: Int)? = nil
                for x in max(x0 + 6, target - win)..<min(x1 - 6, target + win) {
                    let s = columnMeanStd(x, yr)
                    guard s.mean <= 60, s.std <= 22 else { continue }
                    if best == nil || s.mean < best!.mean { best = (s.mean, x) }
                }
                if let b = best { cuts.append(b.x) }
            }
            guard cuts.count == k - 1 else { out.append(region); continue }

            let bounds = [x0] + cuts.sorted() + [x1]
            for j in 0..<(bounds.count - 1) {
                let a = bounds[j], b = bounds[j + 1]
                guard b - a > 16 else { continue }
                let rect = CGRect(x: Double(a) / Double(width), y: r.minY,
                                  width: Double(b - a) / Double(width), height: r.height).normalized
                out.append(CropRegion(index: out.count + 1, rect: rect, isManual: region.isManual))
            }
        }
        guard out.count > regions.count else { return regions }
        return out.enumerated().map { CropRegion(index: $0.offset + 1, rect: $0.element.rect, isManual: $0.element.isManual) }
    }

    private func snapVerticalBoundaries(regions: [CropRegion], gray: [UInt8], width: Int, height: Int) -> [CropRegion] {
        guard width > 8, height > 8, gray.count >= width * height else { return regions }
        let lut = ImageProcessor.shadowLiftLUT
        let textureMin = 22.0   // lifted std above this = photographic content
        let darkMax = 70.0      // raw mean below this (and flat) = film gutter

        // Search radius is based on the MEDIAN frame width, not each box's own
        // width: a frame that was badly cut is anomalously narrow, so its own
        // width would shrink the window below the distance to the real gutter.
        let widths = regions.map { $0.rect.normalized.width * Double(width) }.sorted()
        let medianWidth = widths.isEmpty ? Double(width) : widths[widths.count / 2]
        let cap = max(1, Int(medianWidth * 0.30))

        // Classify a column on a per-frame auto-levelled view: each value is
        // contrast-stretched into the frame's own 2–98% range (lo…lo+span). In a
        // very dark frame (an aquarium) the subject sits in raw 10–20 with tiny
        // raw variance — indistinguishable from the black gutter — but stretching
        // the frame's own range reveals its texture, so dark CONTENT separates
        // from the still-flat gutter. `lut` (shadow lift) is kept as a floor for
        // normal frames. The transform is detection-only; crops use raw pixels.
        func classify(_ x: Int, _ yRange: Range<Int>, _ lo: Double, _ span: Double) -> (content: Bool, gutter: Bool) {
            var sum = 0.0, sumSq = 0.0, rawSum = 0.0, sSum = 0.0, sSumSq = 0.0
            for y in yRange {
                let raw = gray[y * width + x]
                sum += lut[Int(raw)]; sumSq += lut[Int(raw)] * lut[Int(raw)]
                rawSum += Double(raw)
                let s = min(255.0, max(0.0, (Double(raw) - lo) / span * 255.0))
                sSum += s; sSumSq += s * s
            }
            let n = Double(yRange.count)
            let liftedStd = (sumSq / n - (sum / n) * (sum / n)).squareRoot()
            let stretchedStd = (sSumSq / n - (sSum / n) * (sSum / n)).squareRoot()
            let rawMean = rawSum / n
            // Gutter: dark AND flat after the per-frame stretch. Keying flatness
            // on the STRETCHED std (not raw) is essential in dark frames — the
            // subject right at the edge is near-black with tiny RAW variance, so a
            // raw-std test would brand it gutter and the edge would never pull in;
            // the stretch lifts its texture above the flat gutter. A real gutter
            // stays flat under the stretch. Content: textured under the lift or
            // the stretch.
            let gutter = rawMean <= darkMax && stretchedStd <= 15.0
            let content = !gutter && (liftedStd >= textureMin || stretchedStd >= textureMin)
            return (content, gutter)
        }

        return regions.map { region in
            let rect = region.rect.normalized
            let minX = max(0, min(width - 1, Int(floor(rect.minX * Double(width)))))
            let maxX = max(minX + 1, min(width, Int(ceil(rect.maxX * Double(width)))))
            let minY = max(0, min(height - 1, Int(floor(rect.minY * Double(height)))))
            let maxY = max(minY + 1, min(height, Int(ceil(rect.maxY * Double(height)))))
            let boxW = maxX - minX, boxH = maxY - minY
            guard boxW > 24, boxH > 24 else { return region }
            let inset = boxH / 10
            let yRange = (minY + inset)..<(maxY - inset)
            guard !yRange.isEmpty else { return region }

            // Per-frame auto-levels bounds (2–98% of the frame interior), so the
            // stretch in `classify` adapts to this frame's own exposure.
            var samples: [UInt8] = []
            let sStepX = max(1, boxW / 100), sStepY = max(1, boxH / 100)
            var sy = minY
            while sy < maxY {
                var sx = minX
                while sx < maxX { samples.append(gray[sy * width + sx]); sx += sStepX }
                sy += sStepY
            }
            samples.sort()
            let loV = samples.isEmpty ? 0.0 : Double(samples[samples.count * 2 / 100])
            let hiV = samples.isEmpty ? 255.0 : Double(samples[min(samples.count - 1, samples.count * 98 / 100)])
            let spanV = max(1.0, hiV - loV)

            // Precompute gutter/content for the search windows around each edge.
            var cls: [Int: (content: Bool, gutter: Bool)] = [:]
            func c(_ x: Int) -> (content: Bool, gutter: Bool) {
                if let v = cls[x] { return v }
                let v = classify(x, yRange, loV, spanV); cls[x] = v; return v
            }

            // A real inter-frame gutter is a solid black band several pixels
            // wide; a 1–2px "gutter" dip inside dark content (shaded wood) is
            // not. Require a gutter run of at least this many columns next to a
            // transition, so the snap locks onto the true frame boundary rather
            // than a speck of shadow.
            // Require a real gutter run beside the transition, but tolerate a
            // few anti-aliased columns between the solid black and the content:
            // count gutter columns in a slightly wider span and demand at least
            // minGutterRun of them. A 1–2px shadow speck still can't reach the
            // count, while a gradual gutter→content edge (a dark subject right
            // against the black band) is no longer missed and left in the frame.
            let minGutterRun = max(3, Int(medianWidth * 0.006))
            let gutterSpan = minGutterRun + 3
            func gutterRunLeftOf(_ x: Int) -> Bool {
                guard x - gutterSpan >= 0 else { return false }
                var g = 0
                for k in 1...gutterSpan where c(x - k).gutter { g += 1 }
                return g >= minGutterRun
            }
            func gutterRunRightOf(_ x: Int) -> Bool {
                guard x + gutterSpan < width else { return false }
                var g = 0
                for k in 1...gutterSpan where c(x + k).gutter { g += 1 }
                return g >= minGutterRun
            }

            // LEFT edge → gutter→content transition (content backed by a real
            // gutter run) nearest minX.
            var left = minX
            var bestL: Int? = nil
            for x in max(1, minX - cap)...min(width - 1, minX + cap) where c(x).content && gutterRunLeftOf(x) {
                if bestL == nil || abs(x - minX) < abs(bestL! - minX) { bestL = x }
            }
            if let b = bestL { left = b }

            // RIGHT edge → content→gutter transition nearest maxX-1.
            var right = maxX - 1
            var bestR: Int? = nil
            for x in max(1, (maxX - 1) - cap)...min(width - 2, (maxX - 1) + cap) where c(x).content && gutterRunRightOf(x) {
                if bestR == nil || abs(x - (maxX - 1)) < abs(bestR! - (maxX - 1)) { bestR = x }
            }
            if let b = bestR { right = b }

            guard left + 12 < right else { return region }
            let snapped = CGRect(
                x: Double(left) / Double(width),
                y: rect.minY,
                width: Double(right + 1 - left) / Double(width),
                height: rect.height
            ).normalized
            return CropRegion(index: region.index, rect: snapped, isManual: region.isManual)
        }
    }

    private func grayscaleBytes(bitmap: NSBitmapImageRep, width: Int, height: Int) -> [UInt8] {
        if let data = bitmap.bitmapData {
            let samples = max(1, bitmap.samplesPerPixel)
            let bytesPerRow = bitmap.bytesPerRow
            var gray = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height {
                let row = data.advanced(by: y * bytesPerRow)
                for x in 0..<width {
                    let offset = x * samples
                    let red = Int(row[offset])
                    let green = Int(row[min(offset + 1, bytesPerRow - 1)])
                    let blue = Int(row[min(offset + 2, bytesPerRow - 1)])
                    gray[y * width + x] = UInt8(min(255, (54 * red + 183 * green + 19 * blue) >> 8))
                }
            }
            return gray
        }

        var gray = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let value = min(255, max(0, Int(round(luminance(bitmap.colorAt(x: x, y: y)) * 255))))
                gray[y * width + x] = UInt8(value)
            }
        }
        return gray
    }

    private func preprocessModes(for settings: CropSettings) -> [ImagePreprocessMode] {
        guard settings.preprocessMode == .original,
              settings.algorithmMode == .automatic else {
            return [settings.preprocessMode]
        }
        switch settings.businessProfile {
        case .filmScan:
            return [.original, .highContrast, .mask, .inverted]
        case .gridPhoto:
            return [.original, .mask, .highContrast]
        case .balanced:
            return [.original, .highContrast, .mask]
        }
    }

    private func preprocessedGray(_ gray: [UInt8], mode: ImagePreprocessMode, settings: CropSettings) -> [UInt8] {
        switch mode {
        case .original:
            return gray
        case .inverted:
            return gray.map { 255 &- $0 }
        case .mask:
            let threshold = UInt8(max(0, min(255, Int(255 - settings.sensitivity * 1.45))))
            return gray.map { $0 <= threshold ? 0 : 255 }
        case .highContrast:
            return gray.map { value in
                let adjusted = 128 + Int((Double(Int(value) - 128) * 1.45).rounded())
                return UInt8(max(0, min(255, adjusted)))
            }
        }
    }

    private func rotateClockwise(gray: [UInt8], width: Int, height: Int) -> (bytes: [UInt8], width: Int, height: Int) {
        var rotated = [UInt8](repeating: 0, count: gray.count)
        for y in 0..<height {
            for x in 0..<width {
                let newX = height - 1 - y
                let newY = x
                rotated[newY * height + newX] = gray[y * width + x]
            }
        }
        return (rotated, height, width)
    }

    private func detectProjectionRows(gray: [UInt8], width: Int, height: Int) -> [IntSegment] {
        var darkness = [Double](repeating: 0, count: height)
        var nonWhite = [Double](repeating: 0, count: height)
        var horizontalEdge = [Double](repeating: 0, count: height)

        for y in 0..<height {
            var darkCount = 0
            var nonWhiteCount = 0
            var edgeSum = 0
            for x in 0..<width {
                let value = Int(gray[y * width + x])
                if value <= 70 { darkCount += 1 }
                if value <= 242 { nonWhiteCount += 1 }
                if y > 0 {
                    edgeSum += abs(value - Int(gray[(y - 1) * width + x]))
                }
            }
            darkness[y] = Double(darkCount) / Double(width)
            nonWhite[y] = Double(nonWhiteCount) / Double(width)
            horizontalEdge[y] = Double(edgeSum) / (255.0 * Double(width))
        }

        let window = max(3, Int(Double(height) * 0.01))
        let darkSmoothed = movingAverage(darkness, window: window)
        let nonWhiteSmoothed = movingAverage(nonWhite, window: window)
        let edgeSmoothed = movingAverage(horizontalEdge, window: max(3, window / 2))
        let maxEdge = max(edgeSmoothed.max() ?? 0, 0.001)
        let contentProfile = darkSmoothed.indices.map { index in
            min(1, darkSmoothed[index] * 2.2 + nonWhiteSmoothed[index] * 0.62 + (edgeSmoothed[index] / maxEdge) * 0.16)
        }

        let adaptiveThreshold = max(0.055, min(0.22, median(contentProfile) + 0.035))
        let minimumRowHeight = max(18, Int(Double(height) * 0.055))
        let contentRows = thresholdSegments(
            values: movingAverage(contentProfile, window: window),
            threshold: adaptiveThreshold,
            minimumSize: minimumRowHeight,
            lessThan: false
        )

        let darkRows = thresholdSegments(
            values: darkSmoothed,
            threshold: max(0.035, median(darkSmoothed) + 0.025),
            minimumSize: max(10, Int(Double(height) * 0.025)),
            lessThan: false
        )
        let edgeRows = thresholdSegments(
            values: edgeSmoothed.map { $0 / maxEdge },
            threshold: 0.34,
            minimumSize: max(2, Int(Double(height) * 0.006)),
            lessThan: false
        )

        let combined = mergeCloseSegments(contentRows + bridgeRows(from: darkRows, edgeRows: edgeRows, height: height), maxGap: max(8, Int(Double(height) * 0.018)))
        return combined.filter { $0.size >= minimumRowHeight }
    }

    private func bridgeRows(from darkRows: [IntSegment], edgeRows: [IntSegment], height: Int) -> [IntSegment] {
        guard !darkRows.isEmpty else { return [] }
        let maxBridgeGap = max(10, Int(Double(height) * 0.035))
        return darkRows.map { darkRow in
            let topEdge = edgeRows.last { $0.end <= darkRow.start && darkRow.start - $0.end <= maxBridgeGap }
            let bottomEdge = edgeRows.first { $0.start >= darkRow.end && $0.start - darkRow.end <= maxBridgeGap }
            return IntSegment(
                start: topEdge?.start ?? darkRow.start,
                end: bottomEdge?.end ?? darkRow.end
            )
        }
    }

    private func detectColumnsInRow(gray: [UInt8], width: Int, row: IntSegment, settings: CropSettings) -> [IntSegment] {
        let height = row.size
        guard height > 0 else { return [] }

        let continuous = continuousDarkSeparatorProfile(gray: gray, width: width, row: row)
        var darkProfile = [Double](repeating: 0, count: width)
        for x in 0..<width {
            var dark = 0
            for y in row.start..<row.end where gray[y * width + x] <= 55 {
                dark += 1
            }
            darkProfile[x] = Double(dark) / Double(height)
        }
        darkProfile = movingAverage(darkProfile, window: max(3, Int(Double(width) * 0.01)))
        guard let maxDark = darkProfile.max(), maxDark > 0 else { return [] }

        let medianDark = median(darkProfile)
        let separatorBase = 0.72 - min(max(settings.splitSensitivity, 1), 100) * 0.0034
        let threshold = max(separatorBase, medianDark + (maxDark - medianDark) * 0.45)
        let minBandWidth = max(2, width / 600)
        let mergeGap = max(2, width / 220)
        let maxBandWidth = max(24, Int(Double(width) * 0.012))
        let looseBandWidth = max(maxBandWidth * 3, Int(Double(width) * 0.06))
        let edgeLimit = max(16, Int(Double(width) * 0.03))
        let minimumColumn = max(24, Int(Double(width) * 0.035))

        var bands = mergeCloseSegments(
            thresholdSegments(values: darkProfile, threshold: threshold, minimumSize: minBandWidth, lessThan: false),
            maxGap: mergeGap
        )
        bands = bands.compactMap { band in
            guard band.size <= looseBandWidth, separatorBandIsContinuous(profile: continuous, band: band) else { return nil }
            return clampSeparatorBand(band, profile: continuous, maxWidth: maxBandWidth)
        }
        bands = coalesceNearSeparatorBands(bands, width: width)
        guard !bands.isEmpty else { return [] }

        var start = 0
        var end = width
        var interior: [IntSegment] = []
        for band in bands {
            if band.end <= edgeLimit {
                start = max(start, band.start)
            } else if band.start >= width - edgeLimit {
                end = min(end, band.end)
            } else {
                interior.append(band)
            }
        }
        guard start < end else { return [] }

        var columns: [IntSegment] = []
        var cursor = start
        for band in interior {
            if band.start - cursor >= minimumColumn {
                columns.append(IntSegment(start: cursor, end: band.start))
            }
            cursor = max(cursor, band.end)
        }
        if end - cursor >= minimumColumn {
            columns.append(IntSegment(start: cursor, end: end))
        }

        return columns.count >= 2 ? protectOuterColumnEdges(gray: gray, width: width, row: row, columns: mergeNarrowSegments(columns, fullSize: width)) : []
    }

    private func continuousDarkSeparatorProfile(gray: [UInt8], width: Int, row: IntSegment) -> [Double] {
        let height = row.size
        guard height > 0, width > 0 else { return [Double](repeating: 0, count: width) }
        let sliceCount = height >= 80 ? 5 : 3
        var profiles: [[Double]] = []

        for index in 0..<sliceCount {
            let startOffset = Int(round(Double(height * index) / Double(sliceCount)))
            let endOffset = Int(round(Double(height * (index + 1)) / Double(sliceCount)))
            guard endOffset > startOffset else { continue }

            let sliceStart = row.start + startOffset
            let sliceEnd = row.start + endOffset
            var profile = [Double](repeating: 0, count: width)
            for x in 0..<width {
                var dark = 0
                for y in sliceStart..<sliceEnd where gray[y * width + x] <= 55 {
                    dark += 1
                }
                profile[x] = Double(dark) / Double(sliceEnd - sliceStart)
            }
            profiles.append(movingAverage(profile, window: max(3, Int(Double(width) * 0.01))))
        }

        guard var combined = profiles.first else { return [Double](repeating: 0, count: width) }
        for profile in profiles.dropFirst() {
            for index in combined.indices {
                combined[index] = min(combined[index], profile[index])
            }
        }
        return combined
    }

    private func forceColumnsFromLayout(gray: [UInt8], width: Int, row: IntSegment, columns: [IntSegment], reference: [IntSegment]) -> [IntSegment] {
        var adjusted = columns
        var targetWidth: Double?

        if !reference.isEmpty {
            targetWidth = median(reference.map { Double($0.size) })
            adjusted = splitColumnsByReference(columns: adjusted, reference: reference, width: width)
        }

        if adjusted.isEmpty, let targetWidth {
            let count = max(1, Int(round(Double(width) / targetWidth)))
            if count >= 2 {
                var generated: [IntSegment] = []
                for index in 0..<count {
                    let start = Int(round(Double(width * index) / Double(count)))
                    let end = Int(round(Double(width * (index + 1)) / Double(count)))
                    if end - start >= max(24, Int(Double(width) * 0.035)) {
                        generated.append(IntSegment(start: start, end: end))
                    }
                }
                adjusted = generated
            }
        }

        if !adjusted.isEmpty {
            adjusted = splitWideColumnsByLocalEdges(gray: gray, width: width, row: row, columns: adjusted, targetWidth: targetWidth)
        }
        return adjusted
    }

    private func splitWideColumnsByLocalEdges(gray: [UInt8], width: Int, row: IntSegment, columns: [IntSegment], targetWidth: Double?) -> [IntSegment] {
        guard !columns.isEmpty, row.size > 0, width > 0 else { return columns }
        let minimum = max(24, Int(Double(width) * 0.035))
        let resolvedTarget: Double
        if let targetWidth {
            resolvedTarget = targetWidth
        } else {
            let normalWidths = columns.map(\.size).filter { Double($0) / Double(max(1, row.size)) <= 2.35 }
            resolvedTarget = normalWidths.isEmpty ? Double(row.size) * 1.6 : median(normalWidths.map(Double.init))
        }
        guard resolvedTarget >= Double(minimum) else { return columns }

        let darkProfile = continuousDarkSeparatorProfile(gray: gray, width: width, row: row)
        var edgeProfile = [Double](repeating: 0, count: width)
        if width > 1 {
            for x in 1..<width {
                var sum = 0
                for y in row.start..<row.end {
                    sum += abs(Int(gray[y * width + x]) - Int(gray[y * width + x - 1]))
                }
                edgeProfile[x] = Double(sum) / Double(max(1, row.size))
            }
            edgeProfile = movingAverage(edgeProfile, window: max(3, Int(Double(width) * 0.01)))
            if let maxEdge = edgeProfile.max(), maxEdge > 0 {
                edgeProfile = edgeProfile.map { $0 / maxEdge }
            }
        }
        let score = zip(darkProfile, edgeProfile).map { $0 * 2.0 + $1 * 0.75 }

        var balanced: [IntSegment] = []
        for column in columns {
            if Double(column.size) <= resolvedTarget * 1.85 {
                balanced.append(column)
                continue
            }

            let maxParts = max(2, column.size / minimum)
            let parts = max(2, min(Int(round(Double(column.size) / resolvedTarget)), maxParts))
            let searchRadius = max(8, Int(round(resolvedTarget * 0.18)))
            var splitPoints: [Int] = []
            for part in 1..<parts {
                let ideal = Int(round(Double(column.start) + Double(column.size * part) / Double(parts)))
                let left = max(column.start + minimum, ideal - searchRadius)
                let right = min(column.end - minimum, ideal + searchRadius)
                guard right > left else {
                    splitPoints.append(ideal)
                    continue
                }
                let best = (left..<right).max { score[$0] < score[$1] } ?? ideal
                splitPoints.append(best)
            }

            let points = [column.start] + chooseCandidateBoundaries(splitPoints, width: width) + [column.end]
            for (start, end) in zip(points, points.dropFirst()) where end - start >= minimum {
                balanced.append(IntSegment(start: start, end: end))
            }
        }
        return balanced
    }

    private func trimOuterBlankColumnEdges(gray: [UInt8], width: Int, row: IntSegment, columns: [IntSegment]) -> [IntSegment] {
        guard !columns.isEmpty, row.size > 0, width > 0 else { return columns }
        let scanLimit = max(1, width / 4)

        func columnStats(_ x: Int) -> (white: Double, dark: Double) {
            var white = 0
            var dark = 0
            for y in row.start..<row.end {
                let value = gray[y * width + x]
                if value >= 245 { white += 1 }
                if value <= 55 { dark += 1 }
            }
            let count = Double(max(1, row.size))
            return (Double(white) / count, Double(dark) / count)
        }

        var leftBound = 0
        for x in 0..<min(scanLimit, width) {
            let stats = columnStats(x)
            if stats.white >= 0.97, stats.dark <= 0.01 {
                leftBound = x + 1
            } else {
                break
            }
        }

        var rightBound = width
        for offset in 1...min(scanLimit, width) {
            let x = width - offset
            let stats = columnStats(x)
            if stats.white >= 0.97, stats.dark <= 0.01 {
                rightBound = x
            } else {
                break
            }
        }
        guard leftBound < rightBound else { return columns }

        let trimmed = columns.compactMap { column -> IntSegment? in
            let start = max(column.start, leftBound)
            let end = min(column.end, rightBound)
            return end - start >= max(24, Int(Double(width) * 0.035)) ? IntSegment(start: start, end: end) : nil
        }
        return trimmed.isEmpty ? columns : trimmed
    }

    private func protectOuterColumnEdges(gray: [UInt8], width: Int, row: IntSegment, columns: [IntSegment]) -> [IntSegment] {
        guard !columns.isEmpty else { return columns }
        let edgeLimit = max(48, Int(Double(width) * 0.04))
        var adjusted = columns

        let first = adjusted[0]
        if first.start > edgeLimit, !marginIsBlank(gray: gray, width: width, row: row, xRange: 0..<first.start) {
            adjusted[0] = IntSegment(start: 0, end: first.end)
        }

        let lastIndex = adjusted.count - 1
        let last = adjusted[lastIndex]
        if width - last.end > edgeLimit, !marginIsBlank(gray: gray, width: width, row: row, xRange: last.end..<width) {
            adjusted[lastIndex] = IntSegment(start: last.start, end: width)
        }
        return adjusted
    }

    private func marginIsBlank(gray: [UInt8], width: Int, row: IntSegment, xRange: Range<Int>) -> Bool {
        guard !xRange.isEmpty, row.size > 0 else { return true }
        var sum = 0
        var dark = 0
        var count = 0
        for y in row.start..<row.end {
            for x in xRange {
                let value = Int(gray[y * width + x])
                sum += value
                if value <= 55 { dark += 1 }
                count += 1
            }
        }
        guard count > 0 else { return true }
        return Double(sum) / Double(count) >= 235 && Double(dark) / Double(count) <= 0.03
    }

    private func chooseReferenceColumns(_ rowColumns: [[IntSegment]]) -> [IntSegment] {
        let candidates = rowColumns.filter { $0.count >= 2 }
        guard !candidates.isEmpty else { return [] }
        return candidates.max { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count < rhs.count }
            return standardDeviation(lhs.map { Double($0.size) }) > standardDeviation(rhs.map { Double($0.size) })
        } ?? []
    }

    private func splitColumnsByReference(columns: [IntSegment], reference: [IntSegment], width: Int) -> [IntSegment] {
        guard !reference.isEmpty else { return columns }
        guard !columns.isEmpty else { return reference }
        let typicalWidth = median(reference.map { Double($0.size) })

        if columns.count == reference.count {
            var changed = false
            let adjusted = zip(columns, reference).map { column, ref in
                if Double(column.size) < typicalWidth * 0.86, Double(ref.size) >= typicalWidth * 0.86 {
                    changed = true
                    return ref
                }
                return column
            }
            return changed ? adjusted : columns
        }

        guard columns.count < reference.count else { return columns }
        let minOverlap = max(24, Int(Double(width) * 0.012))
        var adjusted: [IntSegment] = []
        var changed = false
        for column in columns {
            let matches = reference.filter { ref in
                overlapSize(column, ref) >= minOverlap || column.contains(center(of: ref))
            }
            if matches.count >= 2, Double(column.size) >= typicalWidth * 1.25 {
                adjusted.append(contentsOf: matches)
                changed = true
            } else {
                adjusted.append(column)
            }
        }
        return changed ? mergeNarrowSegments(adjusted.sorted { $0.start < $1.start }, fullSize: width) : columns
    }

    private func mergeFalseProjectionSplits(gray: [UInt8], width: Int, height: Int, boxes: [IntBox]) -> [IntBox] {
        guard boxes.count > 1 else { return boxes }
        var merged = orderBoxes(boxes, imageWidth: width, imageHeight: height)
        var changed = true

        while changed {
            changed = false
            var result: [IntBox] = []
            var index = 0
            while index < merged.count {
                var current = merged[index]
                if index + 1 < merged.count {
                    let next = merged[index + 1]
                    if !separatorIsBlack(gray: gray, width: width, height: height, current, next) {
                        current = current.union(next)
                        changed = true
                        index += 2
                        result.append(current)
                        continue
                    }
                }
                result.append(current)
                index += 1
            }
            merged = orderBoxes(result, imageWidth: width, imageHeight: height)
        }
        return merged
    }

    private func separatorIsBlack(gray: [UInt8], width: Int, height: Int, _ a: IntBox, _ b: IntBox) -> Bool {
        let horizontalOverlap = min(a.right, b.right) - max(a.left, b.left)
        guard horizontalOverlap > min(a.width, b.width) * 70 / 100 else { return true }

        let band = max(6, Int(round(Double(min(width, height)) * 0.006)))
        let center = (a.bottom + b.top) / 2
        let left = max(a.left, b.left)
        let right = min(a.right, b.right)
        let top = max(0, center - band)
        let bottom = min(height, center + band)
        guard left < right, top < bottom else { return true }

        var sum = 0
        var veryDark = 0
        var count = 0
        for y in top..<bottom {
            for x in left..<right {
                let value = Int(gray[y * width + x])
                sum += value
                if value <= 55 { veryDark += 1 }
                count += 1
            }
        }
        guard count > 0 else { return true }
        return Double(sum) / Double(count) <= 38 && Double(veryDark) / Double(count) >= 0.82
    }

    private func trimUniformBlackEdges(gray: [UInt8], width: Int, height: Int, box: IntBox) -> IntBox {
        guard box.isValid else { return box }
        // Black film base / inter-frame gutters can be wider than the old 8%
        // cap, leaving a black margin on the crop. Allow trimming up to 20%,
        // but make the test specific to *film base* rather than "dark": a line
        // is trimmed only when it is near-black (≤ blackLevel) AND uniform (a
        // bright-pixel escape hatch). A dark but textured subject (a shaded
        // wooden door, a deep shadow) carries some brighter pixels and survives,
        // so we stop eating into the photo where the old darkness-only test did.
        let maxTrimX = max(1, Int(Double(box.width) * 0.20))
        let maxTrimY = max(1, Int(Double(box.height) * 0.20))
        let blackLevel: UInt8 = 50
        let brightLevel: UInt8 = 110

        func isFilmBaseColumn(_ x: Int) -> Bool {
            var dark = 0
            var bright = 0
            for y in box.top..<box.bottom {
                let v = gray[y * width + x]
                if v <= blackLevel { dark += 1 }
                if v >= brightLevel { bright += 1 }
            }
            let total = Double(max(1, box.height))
            return Double(dark) / total >= 0.92 && Double(bright) / total <= 0.02
        }

        func isFilmBaseRow(_ y: Int) -> Bool {
            var dark = 0
            var bright = 0
            for x in box.left..<box.right {
                let v = gray[y * width + x]
                if v <= blackLevel { dark += 1 }
                if v >= brightLevel { bright += 1 }
            }
            let total = Double(max(1, box.width))
            return Double(dark) / total >= 0.92 && Double(bright) / total <= 0.02
        }

        var trimLeft = 0
        for offset in 0..<min(maxTrimX, box.width) {
            if isFilmBaseColumn(box.left + offset) {
                trimLeft = offset + 1
            } else {
                break
            }
        }

        var trimRight = 0
        let trimRightLimit = min(maxTrimX, box.width)
        if trimRightLimit > 0 {
            for offset in 1...trimRightLimit {
                if isFilmBaseColumn(box.right - offset) {
                    trimRight = offset
                } else {
                    break
                }
            }
        }

        var trimTop = 0
        for offset in 0..<min(maxTrimY, box.height) {
            if isFilmBaseRow(box.top + offset) {
                trimTop = offset + 1
            } else {
                break
            }
        }

        var trimBottom = 0
        let trimBottomLimit = min(maxTrimY, box.height)
        if trimBottomLimit > 0 {
            for offset in 1...trimBottomLimit {
                if isFilmBaseRow(box.bottom - offset) {
                    trimBottom = offset
                } else {
                    break
                }
            }
        }

        let trimmed = IntBox(left: box.left + trimLeft, top: box.top + trimTop, right: box.right - trimRight, bottom: box.bottom - trimBottom).clamped(width: width, height: height)
        return trimmed.isValid ? trimmed : box
    }

    private func orderBoxes(_ boxes: [IntBox], imageWidth: Int, imageHeight: Int) -> [IntBox] {
        guard boxes.count > 1 else { return boxes }
        let rowThreshold = max(12, Int(Double(imageHeight) * 0.035))
        let ordered = boxes.sorted { lhs, rhs in
            lhs.top == rhs.top ? lhs.left < rhs.left : lhs.top < rhs.top
        }

        var rows: [[IntBox]] = []
        for box in ordered {
            if rows.isEmpty || abs(box.top - rows[rows.count - 1][0].top) > rowThreshold {
                rows.append([box])
            } else {
                rows[rows.count - 1].append(box)
            }
        }
        return rows.flatMap { $0.sorted { $0.left < $1.left } }
    }

    private func movingAverage(_ values: [Double], window: Int) -> [Double] {
        guard !values.isEmpty else { return values }
        let window = max(1, min(window, values.count))
        let radius = window / 2
        var result = [Double](repeating: 0, count: values.count)
        var prefix = [Double](repeating: 0, count: values.count + 1)
        for index in values.indices {
            prefix[index + 1] = prefix[index] + values[index]
        }
        for index in values.indices {
            let start = max(0, index - radius)
            let end = min(values.count, index + radius + 1)
            result[index] = (prefix[end] - prefix[start]) / Double(end - start)
        }
        return result
    }

    private func thresholdSegments(values: [Double], threshold: Double, minimumSize: Int, lessThan: Bool) -> [IntSegment] {
        var segments: [IntSegment] = []
        var start: Int?
        for (index, value) in values.enumerated() {
            let matched = lessThan ? value < threshold : value > threshold
            if matched {
                if start == nil { start = index }
            } else if let s = start {
                if index - s >= minimumSize {
                    segments.append(IntSegment(start: s, end: index))
                }
                start = nil
            }
        }
        if let s = start, values.count - s >= minimumSize {
            segments.append(IntSegment(start: s, end: values.count))
        }
        return segments
    }

    private func mergeCloseSegments(_ segments: [IntSegment], maxGap: Int) -> [IntSegment] {
        let ordered = segments.sorted { $0.start < $1.start }
        guard let first = ordered.first else { return [] }
        var merged = [first]
        for segment in ordered.dropFirst() {
            let previous = merged[merged.count - 1]
            if segment.start - previous.end <= maxGap {
                merged[merged.count - 1] = IntSegment(start: previous.start, end: max(previous.end, segment.end))
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    private func mergeNarrowSegments(_ segments: [IntSegment], fullSize: Int) -> [IntSegment] {
        guard segments.count > 1 else { return segments }
        let minimum = max(36, Int(Double(fullSize) * 0.09))
        var merged = segments
        var changed = true

        while changed, merged.count > 1 {
            changed = false
            for index in merged.indices where merged[index].size < minimum {
                if index == 0 {
                    let neighbor = merged[1]
                    merged[1] = IntSegment(start: merged[index].start, end: neighbor.end)
                    merged.remove(at: 0)
                } else if index == merged.count - 1 {
                    let neighbor = merged[index - 1]
                    merged[index - 1] = IntSegment(start: neighbor.start, end: merged[index].end)
                    merged.remove(at: index)
                } else {
                    let left = merged[index - 1]
                    let right = merged[index + 1]
                    if left.size <= right.size {
                        merged[index - 1] = IntSegment(start: left.start, end: merged[index].end)
                        merged.remove(at: index)
                    } else {
                        merged[index + 1] = IntSegment(start: merged[index].start, end: right.end)
                        merged.remove(at: index)
                    }
                }
                changed = true
                break
            }
        }
        return merged
    }

    private func chooseCandidateBoundaries(_ candidates: [Int], width: Int) -> [Int] {
        let candidates = Array(Set(candidates.filter { $0 > 0 && $0 < width })).sorted()
        guard candidates.count > 1 else { return candidates }
        var groups: [[Int]] = [[candidates[0]]]
        for candidate in candidates.dropFirst() {
            let lastGroupIndex = groups.count - 1
            if candidate - groups[lastGroupIndex][groups[lastGroupIndex].count - 1] <= max(4, width / 120) {
                groups[lastGroupIndex].append(candidate)
            } else {
                groups.append([candidate])
            }
        }
        return groups.map { group in group.reduce(0, +) / group.count }
    }

    private func separatorBandIsContinuous(profile: [Double], band: IntSegment) -> Bool {
        let start = max(0, band.start)
        let end = min(profile.count, band.end)
        guard start < end else { return false }
        let sample = profile[start..<end]
        let maxValue = sample.max() ?? 0
        let mean = sample.reduce(0, +) / Double(sample.count)
        return maxValue >= 0.42 && mean >= 0.24
    }

    private func clampSeparatorBand(_ band: IntSegment, profile: [Double], maxWidth: Int) -> IntSegment {
        guard band.size > maxWidth else { return band }
        let start = max(0, band.start)
        let end = min(profile.count, band.end)
        guard start < end else { return IntSegment(start: band.start, end: min(band.end, band.start + maxWidth)) }
        let sample = Array(profile[start..<end])
        let threshold = max(0.42, (sample.max() ?? 0) * 0.80)
        let coreCandidates = mergeCloseSegments(
            thresholdSegments(values: sample, threshold: threshold, minimumSize: max(2, maxWidth / 12), lessThan: false),
            maxGap: max(2, maxWidth / 20)
        )
        if let core = coreCandidates.first {
            let coreStart = start + core.start
            return IntSegment(start: coreStart, end: min(band.end, coreStart + maxWidth))
        }
        return IntSegment(start: band.start, end: min(band.end, band.start + maxWidth))
    }

    private func coalesceNearSeparatorBands(_ bands: [IntSegment], width: Int) -> [IntSegment] {
        guard bands.count > 1 else { return bands }
        let minPhotoWidth = max(24, Int(Double(width) * 0.055))
        let ordered = bands.sorted { $0.start < $1.start }
        var result: [IntSegment] = []
        var group: [IntSegment] = [ordered[0]]

        for band in ordered.dropFirst() {
            let previous = group[group.count - 1]
            if band.start - previous.end < minPhotoWidth {
                group.append(band)
            } else {
                result.append(group[0])
                group = [band]
            }
        }
        result.append(group[0])
        return result
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func standardDeviation(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        return sqrt(variance)
    }

    private func overlapSize(_ lhs: IntSegment, _ rhs: IntSegment) -> Int {
        max(0, min(lhs.end, rhs.end) - max(lhs.start, rhs.start))
    }

    private func center(of segment: IntSegment) -> Int {
        (segment.start + segment.end) / 2
    }

    private func detectFilmFrames(luminances: [Double], width: Int, height: Int, settings: CropSettings) -> [CropRegion] {
        let contactSheetRects = detectContactSheetFrames(luminances: luminances, width: width, height: height, settings: settings)
        if contactSheetRects.count >= 30 {
            return indexedRegions(from: contactSheetRects, settings: settings)
        }

        let sprocketRects = detectSprocketSubjectFrames(luminances: luminances, width: width, height: height, settings: settings)
        if sprocketRects.count > 1 {
            return indexedRegions(from: sprocketRects, settings: settings)
        }

        let nonWhiteThreshold = 0.92
        let blackThreshold = 0.18
        var rowInk = [Double](repeating: 0, count: height)
        var colInk = [Double](repeating: 0, count: width)
        for y in 0..<height {
            var count = 0
            for x in 0..<width where luminances[y * width + x] < nonWhiteThreshold {
                count += 1
            }
            rowInk[y] = Double(count) / Double(width)
        }
        for x in 0..<width {
            var count = 0
            for y in 0..<height where luminances[y * width + x] < nonWhiteThreshold {
                count += 1
            }
            colInk[x] = Double(count) / Double(height)
        }

        let stripRows = bands(from: rowInk, threshold: 0.08, minLength: max(10, height / 45), gapTolerance: max(2, height / 180))
        let stripCols = bands(from: colInk, threshold: 0.08, minLength: max(10, width / 45), gapTolerance: max(2, width / 180))

        var rects: [CGRect] = []
        if stripRows.count > 1 {
            for row in stripRows {
                rects.append(contentsOf: splitStrip(luminances: luminances, width: width, height: height, xRange: 0...(width - 1), yRange: row, blackThreshold: blackThreshold, settings: settings))
            }
        } else if stripCols.count > 1 {
            for col in stripCols {
                rects.append(contentsOf: splitStrip(luminances: luminances, width: width, height: height, xRange: col, yRange: 0...(height - 1), blackThreshold: blackThreshold, settings: settings))
            }
        } else if let row = stripRows.first {
            rects.append(contentsOf: splitStrip(luminances: luminances, width: width, height: height, xRange: 0...(width - 1), yRange: row, blackThreshold: blackThreshold, settings: settings))
        }

        let filtered = mergeNormalizedRects(rects, overlapThreshold: 0.48).filter { rect in
            rect.area > 0.006 && rect.width > 0.045 && rect.height > 0.045 && !(rect.width > 0.94 && rect.height > 0.94)
        }
        return indexedRegions(from: filtered, settings: settings)
    }

    private func detectContactSheetFrames(luminances: [Double], width: Int, height: Int, settings: CropSettings) -> [CGRect] {
        guard width > 180, height > 140 else { return [] }

        let mainXEnd = max(1, min(width, Int(Double(width) * 0.90)))
        var rowContent = [Double](repeating: 0, count: height)
        for y in 0..<height {
            var content = 0
            for x in 0..<mainXEnd {
                if isPhotoBody(luminances[y * width + x]) {
                    content += 1
                }
            }
            rowContent[y] = Double(content) / Double(mainXEnd)
        }

        let rowWindow = max(3, height / 160)
        let rowSmoothed = movingAverage(rowContent, window: rowWindow)
        let rowThreshold = max(0.09, min(0.30, median(rowSmoothed) + standardDeviation(rowSmoothed) * 0.35))
        let rawRows = thresholdSegments(
            values: rowSmoothed,
            threshold: rowThreshold,
            minimumSize: max(12, height / 22),
            lessThan: false
        )
        let rows = selectContactSheetRows(rawRows, rowContent: rowContent, height: height)
        guard rows.count == 6 else { return [] }

        var rects: [CGRect] = []
        for row in rows {
            let columns = contactSheetColumns(luminances: luminances, width: width, yRange: row)
            guard columns.count == 6 else { continue }
            for column in columns {
                let xRange = column.start...max(column.start, column.end - 1)
                let yRange = row.start...max(row.start, row.end - 1)
                let rect = contactSheetSubjectRect(
                    luminances: luminances,
                    width: width,
                    height: height,
                    xRange: xRange,
                    yRange: yRange
                )
                rects.append(rect)
            }
        }

        return rects.count == 36 ? rects : []
    }

    private func isPhotoBody(_ value: Double) -> Bool {
        value > 0.16 && value < 0.985
    }

    private func selectContactSheetRows(_ rows: [IntSegment], rowContent: [Double], height: Int) -> [IntSegment] {
        guard !rows.isEmpty else { return [] }
        let normalizedRows = rows.filter { $0.size >= max(12, height / 28) }
        let ranked = normalizedRows.sorted { lhs, rhs in
            let lhsScore = segmentMean(rowContent, lhs) * Double(lhs.size)
            let rhsScore = segmentMean(rowContent, rhs) * Double(rhs.size)
            return lhsScore > rhsScore
        }
        let selected = Array(ranked.prefix(6)).sorted { $0.start < $1.start }
        guard selected.count == 6 else { return [] }
        let sizes = selected.map { Double($0.size) }
        let medianSize = median(sizes)
        guard medianSize > 0 else { return [] }
        let regular = selected.allSatisfy { row in
            let ratio = Double(row.size) / medianSize
            return ratio > 0.55 && ratio < 1.65
        }
        return regular ? selected : []
    }

    private func contactSheetColumns(luminances: [Double], width: Int, yRange row: IntSegment) -> [IntSegment] {
        let mainXEnd = max(1, min(width, Int(Double(width) * 0.755)))
        return (0..<6).map { index in
            let start = Int(round(Double(mainXEnd * index) / 6.0))
            let end = Int(round(Double(mainXEnd * (index + 1)) / 6.0))
            return IntSegment(start: start, end: max(start + 1, end))
        }
    }

    private func segmentMean(_ values: [Double], _ segment: IntSegment) -> Double {
        let start = max(0, min(values.count, segment.start))
        let end = max(start, min(values.count, segment.end))
        guard start < end else { return 0 }
        return values[start..<end].reduce(0, +) / Double(end - start)
    }

    private func contactSheetSubjectRect(luminances: [Double], width: Int, height: Int, xRange: ClosedRange<Int>, yRange: ClosedRange<Int>) -> CGRect {
        var left = xRange.lowerBound
        var right = xRange.upperBound
        let slotInsetX = max(2, xRange.count / 28)
        left = min(right, left + slotInsetX)
        right = max(left, right - slotInsetX)

        // The row span already brackets the photo tightly. Search the FULL row
        // range for the true top/bottom edges rather than pre-cropping a fixed
        // fraction first: an up-front inset became a hard cap the refinement
        // could never grow back out of, which cut ~1/6 off every cell's top.
        // The modest inset survives only as a fallback when refinement fails.
        let slotInsetY = max(2, yRange.count / 18)
        var top = min(yRange.upperBound, yRange.lowerBound + slotInsetY)
        var bottom = max(yRange.lowerBound, yRange.upperBound - slotInsetY)
        if let refinedY = contactSheetSubjectYRange(
            luminances: luminances,
            width: width,
            xRange: left...right,
            yRange: yRange
        ), Double(refinedY.count) >= Double(max(1, yRange.count)) * 0.45 {
            top = refinedY.lowerBound
            bottom = refinedY.upperBound
        }
        return CGRect(
            x: Double(left) / Double(width),
            y: Double(top) / Double(height),
            width: Double(right - left + 1) / Double(width),
            height: Double(bottom - top + 1) / Double(height)
        ).normalized
    }

    private func contactSheetSubjectYRange(luminances: [Double], width: Int, xRange: ClosedRange<Int>, yRange: ClosedRange<Int>) -> ClosedRange<Int>? {
        guard xRange.count > 12, yRange.count > 12 else { return nil }
        let imageHeight = max(1, luminances.count / width)
        let yStart = max(1, min(imageHeight - 2, yRange.lowerBound))
        let yEnd = max(yStart + 1, min(imageHeight - 2, yRange.upperBound))
        let boundedY = yStart...yEnd

        var contentProfile = [Double]()
        var edgeProfile = [Double]()
        contentProfile.reserveCapacity(boundedY.count)
        edgeProfile.reserveCapacity(boundedY.count)

        for y in boundedY {
            var content = 0
            var border = 0
            var white = 0
            var dark = 0
            var edge = 0.0
            for x in xRange {
                let value = luminances[y * width + x]
                if value > 0.16 && value < 0.985 { content += 1 }
                if value <= 0.14 || value >= 0.94 { border += 1 }
                if value >= 0.92 { white += 1 }
                if value <= 0.18 { dark += 1 }
                edge += abs(luminances[(y + 1) * width + x] - luminances[(y - 1) * width + x])
            }
            let total = Double(max(1, xRange.count))
            let contentRatio = Double(content) / total
            let borderRatio = Double(border) / total
            let whiteRatio = Double(white) / total
            let darkRatio = Double(dark) / total
            let perforationPenalty = (whiteRatio >= 0.08 && darkRatio >= 0.18) ? min(0.55, whiteRatio * 1.8 + darkRatio * 0.45) : 0
            contentProfile.append(max(0, contentRatio - max(0, borderRatio - 0.48) * 0.40 - perforationPenalty))
            edgeProfile.append(edge / total)
        }

        let contentSmoothed = movingAverage(contentProfile, window: max(3, yRange.count / 80))
        let edgeSmoothed = movingAverage(edgeProfile, window: max(3, yRange.count / 120))
        let maxEdge = max(edgeSmoothed.max() ?? 0, 0.001)
        let score = contentSmoothed.indices.map { index in
            min(1, contentSmoothed[index] * 0.90 + (edgeSmoothed[index] / maxEdge) * 0.10)
        }
        let threshold = max(0.10, min(0.36, median(score) + standardDeviation(score) * 0.18))
        let segments = mergeCloseSegments(
            thresholdSegments(values: score, threshold: threshold, minimumSize: max(6, yRange.count / 5), lessThan: false),
            maxGap: max(2, yRange.count / 40)
        )
        guard let best = segments.max(by: { lhs, rhs in
            let lhsScore = segmentMean(score, lhs) * Double(lhs.size)
            let rhsScore = segmentMean(score, rhs) * Double(rhs.size)
            return lhsScore < rhsScore
        }) else { return nil }

        let top = yStart + best.start
        let bottom = min(yEnd, yStart + best.end - 1)
        guard bottom - top + 1 >= max(8, yRange.count / 4) else { return nil }
        let safety = max(1, yRange.count / 90)
        return max(yStart, top - safety)...min(yEnd, bottom + safety)
    }

    private func detectSprocketSubjectFrames(luminances: [Double], width: Int, height: Int, settings: CropSettings) -> [CGRect] {
        guard width > 80, height > 60 else { return [] }

        var sprocketScore = [Double](repeating: 0, count: height)
        for y in 0..<height {
            var white = 0
            var dark = 0
            for x in 0..<width {
                let value = luminances[y * width + x]
                if value >= 0.92 { white += 1 }
                if value <= 0.18 { dark += 1 }
            }
            let whiteRatio = Double(white) / Double(width)
            let darkRatio = Double(dark) / Double(width)
            sprocketScore[y] = min(1, whiteRatio * 4.2) * min(1, darkRatio * 1.8)
        }

        let smoothed = movingAverage(sprocketScore, window: max(3, height / 120))
        let threshold = max(0.12, min(0.34, median(smoothed) + standardDeviation(smoothed) * 0.75))
        let holeBands = mergeCloseSegments(
            thresholdSegments(values: smoothed, threshold: threshold, minimumSize: max(3, height / 80), lessThan: false),
            maxGap: max(2, height / 90)
        )
        guard holeBands.count >= 2 else { return [] }

        let subjectRows = sprocketSubjectRows(from: holeBands, height: height)
        guard !subjectRows.isEmpty else { return [] }

        var rects: [CGRect] = []
        for row in subjectRows {
            rects.append(contentsOf: sprocketFrameRectsInSubjectRow(luminances: luminances, width: width, height: height, yRange: row, settings: settings))
        }
        return mergeNormalizedRects(rects, overlapThreshold: 0.42).filter { rect in
            rect.area > 0.006 && rect.width > 0.045 && rect.height > 0.045 && !(rect.width > 0.94 && rect.height > 0.94)
        }
    }

    private func sprocketSubjectRows(from holeBands: [IntSegment], height: Int) -> [ClosedRange<Int>] {
        let ordered = holeBands.sorted { $0.start < $1.start }
        let minimumSubjectHeight = max(20, Int(Double(height) * 0.16))
        let verticalPad = max(1, height / 180)
        var rows: [ClosedRange<Int>] = []

        for pair in zip(ordered, ordered.dropFirst()) {
            let topBand = pair.0
            let bottomBand = pair.1
            let start = min(height - 1, topBand.end + verticalPad)
            let end = max(0, bottomBand.start - verticalPad)
            if end - start + 1 >= minimumSubjectHeight {
                rows.append(start...end)
            }
        }
        return rows
    }

    private func sprocketFrameRectsInSubjectRow(luminances: [Double], width: Int, height: Int, yRange: ClosedRange<Int>, settings: CropSettings) -> [CGRect] {
        let rowHeight = yRange.count
        guard rowHeight > 20 else { return [] }

        var blackProfile = [Double](repeating: 0, count: width)
        var contentProfile = [Double](repeating: 0, count: width)
        for x in 0..<width {
            var black = 0
            var content = 0
            for y in yRange {
                let value = luminances[y * width + x]
                if value <= 0.18 { black += 1 }
                if value > 0.2 && value < 0.985 { content += 1 }
            }
            blackProfile[x] = Double(black) / Double(rowHeight)
            contentProfile[x] = Double(content) / Double(rowHeight)
        }

        let blackSmoothed = movingAverage(blackProfile, window: max(3, width / 180))
        var separatorBands = thresholdSegments(
            values: blackSmoothed,
            threshold: 0.72,
            minimumSize: max(2, width / 350),
            lessThan: false
        )

        if separatorBands.isEmpty {
            separatorBands = thresholdSegments(
                values: blackSmoothed,
                threshold: max(0.46, median(blackSmoothed) + standardDeviation(blackSmoothed) * 0.8),
                minimumSize: max(2, width / 380),
                lessThan: false
            )
        }

        separatorBands = mergeCloseSegments(separatorBands, maxGap: max(2, width / 260))
        let spans = contentSpans(
            between: separatorBands.map { $0.start...max($0.start, $0.end - 1) },
            lower: 0,
            upper: width - 1,
            minLength: max(24, width / 14)
        )

        return spans.compactMap { span in
            let trimmedX = trimSprocketSubjectX(contentProfile: contentProfile, span: span)
            guard trimmedX.count >= max(20, width / 18) else { return nil }
            let rect = refineSprocketSubjectRect(luminances: luminances, width: width, height: height, xRange: trimmedX, yRange: yRange)
            let aspect = rect.width / max(rect.height, 0.001)
            guard aspect >= 0.35 && aspect <= 3.8 else { return nil }
            return rect
        }
    }

    private func trimSprocketSubjectX(contentProfile: [Double], span: ClosedRange<Int>) -> ClosedRange<Int> {
        var left = span.lowerBound
        var right = span.upperBound
        let maxInset = max(2, span.count / 6)
        while left < right,
              left - span.lowerBound < maxInset,
              contentProfile[left] < 0.08 {
            left += 1
        }
        while right > left,
              span.upperBound - right < maxInset,
              contentProfile[right] < 0.08 {
            right -= 1
        }
        return left...right
    }

    private func refineSprocketSubjectRect(luminances: [Double], width: Int, height: Int, xRange: ClosedRange<Int>, yRange: ClosedRange<Int>) -> CGRect {
        var top = yRange.lowerBound
        var bottom = yRange.upperBound
        let maxInset = max(2, yRange.count / 5)

        func rowContentRatio(_ y: Int) -> Double {
            var content = 0
            for x in xRange {
                let value = luminances[y * width + x]
                if value > 0.2 && value < 0.985 {
                    content += 1
                }
            }
            return Double(content) / Double(max(1, xRange.count))
        }

        while top < bottom,
              top - yRange.lowerBound < maxInset,
              rowContentRatio(top) < 0.18 {
            top += 1
        }
        while bottom > top,
              yRange.upperBound - bottom < maxInset,
              rowContentRatio(bottom) < 0.18 {
            bottom -= 1
        }

        let safetyY = max(1, yRange.count / 120)
        top = max(yRange.lowerBound, top - safetyY)
        bottom = min(yRange.upperBound, bottom + safetyY)
        return CGRect(
            x: Double(xRange.lowerBound) / Double(width),
            y: Double(top) / Double(height),
            width: Double(xRange.count) / Double(width),
            height: Double(bottom - top + 1) / Double(height)
        ).normalized
    }

    private func splitStrip(luminances: [Double], width: Int, height: Int, xRange: ClosedRange<Int>, yRange: ClosedRange<Int>, blackThreshold: Double, settings: CropSettings) -> [CGRect] {
        let stripWidth = xRange.count
        let stripHeight = yRange.count
        guard stripWidth > 10, stripHeight > 10 else { return [] }

        var verticalBlack = [Double](repeating: 0, count: stripWidth)
        for (offset, x) in xRange.enumerated() {
            var count = 0
            for y in yRange where luminances[y * width + x] < blackThreshold {
                count += 1
            }
            verticalBlack[offset] = Double(count) / Double(stripHeight)
        }

        var horizontalBlack = [Double](repeating: 0, count: stripHeight)
        for (offset, y) in yRange.enumerated() {
            var count = 0
            for x in xRange where luminances[y * width + x] < blackThreshold {
                count += 1
            }
            horizontalBlack[offset] = Double(count) / Double(stripWidth)
        }

        let verticalLines = adaptiveSeparatorBands(from: verticalBlack, absoluteOffset: xRange.lowerBound, minLength: max(2, width / 300))
        let horizontalLines = adaptiveSeparatorBands(from: horizontalBlack, absoluteOffset: yRange.lowerBound, minLength: max(2, height / 300))

        if stripWidth >= stripHeight {
            let spans = contentSpans(between: verticalLines, lower: xRange.lowerBound, upper: xRange.upperBound, minLength: max(20, stripWidth / 18))
            return spans.compactMap { span in
                trimPhotoCell(luminances: luminances, width: width, height: height, xRange: span, yRange: yRange, blackThreshold: blackThreshold)
            }
        } else {
            let spans = contentSpans(between: horizontalLines, lower: yRange.lowerBound, upper: yRange.upperBound, minLength: max(20, stripHeight / 18))
            return spans.compactMap { span in
                trimPhotoCell(luminances: luminances, width: width, height: height, xRange: xRange, yRange: span, blackThreshold: blackThreshold)
            }
        }
    }

    private func bands(from values: [Double], threshold: Double, minLength: Int, gapTolerance: Int) -> [ClosedRange<Int>] {
        var bands: [ClosedRange<Int>] = []
        var start: Int?
        var lastHit: Int?
        for (index, value) in values.enumerated() {
            if value >= threshold {
                if start == nil { start = index }
                lastHit = index
            } else if let s = start, let last = lastHit, index - last > gapTolerance {
                if last - s + 1 >= minLength {
                    bands.append(s...last)
                }
                start = nil
                lastHit = nil
            }
        }
        if let s = start, let last = lastHit, last - s + 1 >= minLength {
            bands.append(s...last)
        }
        return bands
    }

    private func separatorBands(from values: [Double], absoluteOffset: Int, minLength: Int, threshold: Double) -> [ClosedRange<Int>] {
        let smoothed = values.indices.map { index in
            let start = max(0, index - 2)
            let end = min(values.count - 1, index + 2)
            return values[start...end].reduce(0, +) / Double(end - start + 1)
        }
        return bands(from: smoothed, threshold: threshold, minLength: minLength, gapTolerance: 2)
            .map { (absoluteOffset + $0.lowerBound)...(absoluteOffset + $0.upperBound) }
    }

    private func adaptiveSeparatorBands(from values: [Double], absoluteOffset: Int, minLength: Int) -> [ClosedRange<Int>] {
        guard let maxValue = values.max(), maxValue > 0.18 else { return [] }
        let sorted = values.sorted()
        let p90 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.90))]
        let threshold = max(0.24, min(0.72, max(p90, maxValue * 0.58)))
        var lines = separatorBands(from: values, absoluteOffset: absoluteOffset, minLength: minLength, threshold: threshold)
        let peakLines = peakSeparatorBands(from: values, absoluteOffset: absoluteOffset, minLength: minLength, threshold: max(0.18, threshold * 0.62))
        lines.append(contentsOf: peakLines)

        if lines.isEmpty, maxValue > 0.35 {
            lines = separatorBands(from: values, absoluteOffset: absoluteOffset, minLength: minLength, threshold: maxValue * 0.42)
        }
        return mergeLineBands(lines)
    }

    private func peakSeparatorBands(from values: [Double], absoluteOffset: Int, minLength: Int, threshold: Double) -> [ClosedRange<Int>] {
        guard values.count > 6 else { return [] }
        let smoothed = values.indices.map { index in
            let start = max(0, index - 3)
            let end = min(values.count - 1, index + 3)
            return values[start...end].reduce(0, +) / Double(end - start + 1)
        }

        var peaks: [(index: Int, value: Double)] = []
        for index in 1..<(smoothed.count - 1) {
            if smoothed[index] >= threshold,
               smoothed[index] >= smoothed[index - 1],
               smoothed[index] >= smoothed[index + 1] {
                peaks.append((index, smoothed[index]))
            }
        }

        let minDistance = max(minLength * 2, values.count / 36)
        var selected: [(index: Int, value: Double)] = []
        for peak in peaks.sorted(by: { $0.value > $1.value }) {
            if !selected.contains(where: { abs($0.index - peak.index) < minDistance }) {
                selected.append(peak)
            }
        }

        return selected.map { peak in
            let floor = max(threshold * 0.62, peak.value * 0.45)
            var left = peak.index
            var right = peak.index
            while left > 0, smoothed[left - 1] >= floor { left -= 1 }
            while right < smoothed.count - 1, smoothed[right + 1] >= floor { right += 1 }
            if right - left + 1 < minLength {
                let grow = (minLength - (right - left + 1) + 1) / 2
                left = max(0, left - grow)
                right = min(smoothed.count - 1, right + grow)
            }
            return (absoluteOffset + left)...(absoluteOffset + right)
        }
    }

    private func mergeLineBands(_ bands: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        let sorted = bands.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Int>] = []
        for band in sorted {
            guard let last = merged.last else {
                merged.append(band)
                continue
            }
            if band.lowerBound <= last.upperBound + 3 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, band.upperBound)
            } else {
                merged.append(band)
            }
        }
        return merged
    }

    private func contentSpans(between separators: [ClosedRange<Int>], lower: Int, upper: Int, minLength: Int) -> [ClosedRange<Int>] {
        let sorted = separators.sorted { $0.lowerBound < $1.lowerBound }
        var spans: [ClosedRange<Int>] = []
        var cursor = lower
        for separator in sorted {
            let start = cursor
            let end = separator.lowerBound - 1
            if end - start + 1 >= minLength {
                spans.append(start...end)
            }
            cursor = max(cursor, separator.upperBound + 1)
        }
        if upper - cursor + 1 >= minLength {
            spans.append(cursor...upper)
        }
        return spans
    }

    private func trimPhotoCell(luminances: [Double], width: Int, height: Int, xRange: ClosedRange<Int>, yRange: ClosedRange<Int>, blackThreshold: Double) -> CGRect? {
        let inner = stripBlackBorder(
            luminances: luminances,
            width: width,
            xRange: xRange,
            yRange: yRange,
            blackThreshold: blackThreshold
        )
        let snapped = snapToSubjectEdges(
            luminances: luminances,
            width: width,
            height: height,
            xRange: inner.x,
            yRange: inner.y,
            blackThreshold: blackThreshold
        )
        guard snapped.x.count > 8, snapped.y.count > 8 else { return nil }
        return CGRect(
            x: Double(snapped.x.lowerBound) / Double(width),
            y: Double(snapped.y.lowerBound) / Double(height),
            width: Double(snapped.x.count) / Double(width),
            height: Double(snapped.y.count) / Double(height)
        ).normalized
    }

    private func stripBlackBorder(luminances: [Double], width: Int, xRange: ClosedRange<Int>, yRange: ClosedRange<Int>, blackThreshold: Double) -> (x: ClosedRange<Int>, y: ClosedRange<Int>) {
        var left = xRange.lowerBound
        var right = xRange.upperBound
        var top = yRange.lowerBound
        var bottom = yRange.upperBound
        let lineThreshold = 0.72

        func columnBlackRatio(_ x: Int, _ yRange: ClosedRange<Int>) -> Double {
            var count = 0
            for y in yRange where luminances[y * width + x] < blackThreshold {
                count += 1
            }
            return Double(count) / Double(max(1, yRange.count))
        }

        func rowBlackRatio(_ y: Int, _ xRange: ClosedRange<Int>) -> Double {
            var count = 0
            for x in xRange where luminances[y * width + x] < blackThreshold {
                count += 1
            }
            return Double(count) / Double(max(1, xRange.count))
        }

        let maxInsetX = max(1, xRange.count / 80)
        let maxInsetY = max(1, yRange.count / 80)

        while left < right,
              left - xRange.lowerBound < maxInsetX,
              columnBlackRatio(left, top...bottom) > lineThreshold {
            left += 1
        }
        while right > left,
              xRange.upperBound - right < maxInsetX,
              columnBlackRatio(right, top...bottom) > lineThreshold {
            right -= 1
        }
        while top < bottom,
              top - yRange.lowerBound < maxInsetY,
              rowBlackRatio(top, left...right) > lineThreshold {
            top += 1
        }
        while bottom > top,
              yRange.upperBound - bottom < maxInsetY,
              rowBlackRatio(bottom, left...right) > lineThreshold {
            bottom -= 1
        }

        let safetyX = max(1, xRange.count / 120)
        let safetyY = max(1, yRange.count / 120)
        left = max(xRange.lowerBound, left - safetyX)
        right = min(xRange.upperBound, right + safetyX)
        top = max(yRange.lowerBound, top - safetyY)
        bottom = min(yRange.upperBound, bottom + safetyY)
        return (left...right, top...bottom)
    }

    private func snapToSubjectEdges(luminances: [Double], width: Int, height: Int, xRange: ClosedRange<Int>, yRange: ClosedRange<Int>, blackThreshold: Double) -> (x: ClosedRange<Int>, y: ClosedRange<Int>) {
        var left = xRange.lowerBound
        var right = xRange.upperBound
        var top = yRange.lowerBound
        var bottom = yRange.upperBound

        let maxInsetX = max(2, xRange.count / 18)
        let maxInsetY = max(2, yRange.count / 18)
        let leftLimit = min(xRange.upperBound - 2, xRange.lowerBound + maxInsetX)
        let rightLimit = max(xRange.lowerBound + 2, xRange.upperBound - maxInsetX)
        let topLimit = min(yRange.upperBound - 2, yRange.lowerBound + maxInsetY)
        let bottomLimit = max(yRange.lowerBound + 2, yRange.upperBound - maxInsetY)

        if let edge = subjectVerticalEdge(
            luminances: luminances,
            width: width,
            xCandidates: xRange.lowerBound...leftLimit,
            yRange: yRange,
            borderSide: .before,
            blackThreshold: blackThreshold
        ) {
            left = edge
        }

        if let edge = subjectVerticalEdge(
            luminances: luminances,
            width: width,
            xCandidates: rightLimit...xRange.upperBound,
            yRange: yRange,
            borderSide: .after,
            blackThreshold: blackThreshold
        ) {
            right = edge
        }

        if let edge = subjectHorizontalEdge(
            luminances: luminances,
            width: width,
            yCandidates: yRange.lowerBound...topLimit,
            xRange: left...right,
            borderSide: .before,
            blackThreshold: blackThreshold
        ) {
            top = edge
        }

        if let edge = subjectHorizontalEdge(
            luminances: luminances,
            width: width,
            yCandidates: bottomLimit...yRange.upperBound,
            xRange: left...right,
            borderSide: .after,
            blackThreshold: blackThreshold
        ) {
            bottom = edge
        }

        let safetyX = max(1, xRange.count / 160)
        let safetyY = max(1, yRange.count / 160)
        left = max(xRange.lowerBound, left - safetyX)
        right = min(xRange.upperBound, right + safetyX)
        top = max(yRange.lowerBound, top - safetyY)
        bottom = min(yRange.upperBound, bottom + safetyY)
        return (left...right, top...bottom)
    }

    private enum BorderSide {
        case before
        case after
    }

    private func subjectVerticalEdge(luminances: [Double], width: Int, xCandidates: ClosedRange<Int>, yRange: ClosedRange<Int>, borderSide: BorderSide, blackThreshold: Double) -> Int? {
        var best: (x: Int, score: Double)?
        for x in xCandidates where x > 1 && x < width - 2 {
            let outsideX = borderSide == .before ? x - 1 : x + 1
            let insideX = borderSide == .before ? x + 1 : x - 1
            var edge = 0.0
            var outsideBorder = 0
            var insideContent = 0
            for y in yRange {
                let outside = luminances[y * width + outsideX]
                let inside = luminances[y * width + insideX]
                edge += abs(inside - outside)
                if outside < blackThreshold || outside > 0.92 { outsideBorder += 1 }
                if inside > blackThreshold + 0.06 && inside < 0.985 { insideContent += 1 }
            }
            let n = Double(max(1, yRange.count))
            let borderRatio = Double(outsideBorder) / n
            let contentRatio = Double(insideContent) / n
            let score = edge / n * min(1, borderRatio * 1.6) * min(1, contentRatio * 1.4)
            if score > (best?.score ?? 0) {
                best = (x, score)
            }
        }
        return (best?.score ?? 0) > 0.018 ? best?.x : nil
    }

    private func subjectHorizontalEdge(luminances: [Double], width: Int, yCandidates: ClosedRange<Int>, xRange: ClosedRange<Int>, borderSide: BorderSide, blackThreshold: Double) -> Int? {
        let imageHeight = max(1, luminances.count / width)
        var best: (y: Int, score: Double)?
        for y in yCandidates where y > 1 && y < imageHeight - 2 {
            let outsideY = borderSide == .before ? y - 1 : y + 1
            let insideY = borderSide == .before ? y + 1 : y - 1
            var edge = 0.0
            var outsideBorder = 0
            var insideContent = 0
            for x in xRange {
                let outside = luminances[outsideY * width + x]
                let inside = luminances[insideY * width + x]
                edge += abs(inside - outside)
                if outside < blackThreshold || outside > 0.92 { outsideBorder += 1 }
                if inside > blackThreshold + 0.06 && inside < 0.985 { insideContent += 1 }
            }
            let n = Double(max(1, xRange.count))
            let borderRatio = Double(outsideBorder) / n
            let contentRatio = Double(insideContent) / n
            let score = edge / n * min(1, borderRatio * 1.6) * min(1, contentRatio * 1.4)
            if score > (best?.score ?? 0) {
                best = (y, score)
            }
        }
        return (best?.score ?? 0) > 0.018 ? best?.y : nil
    }

    private func trimmedByContentMask(luminances: [Double], width: Int, height: Int, xRange: ClosedRange<Int>, yRange: ClosedRange<Int>, minValue: Double, maxValue: Double) -> CGRect? {
        var minX = xRange.upperBound
        var minY = yRange.upperBound
        var maxX = xRange.lowerBound
        var maxY = yRange.lowerBound

        for y in yRange {
            for x in xRange {
                let value = luminances[y * width + x]
                if value > minValue && value < maxValue {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }
        guard minX < maxX, minY < maxY else { return nil }
        return CGRect(x: Double(minX) / Double(width), y: Double(minY) / Double(height), width: Double(maxX - minX + 1) / Double(width), height: Double(maxY - minY + 1) / Double(height)).normalized
    }

    private func refinedByOtsuAndEdges(luminances: [Double], width: Int, height: Int, rect: CGRect) -> CGRect? {
        let x0 = max(0, Int(rect.minX * Double(width)))
        let y0 = max(0, Int(rect.minY * Double(height)))
        let x1 = min(width - 1, Int(rect.maxX * Double(width)))
        let y1 = min(height - 1, Int(rect.maxY * Double(height)))
        guard x1 - x0 > 12, y1 - y0 > 12 else { return rect }

        var samples: [Double] = []
        samples.reserveCapacity((x1 - x0 + 1) * (y1 - y0 + 1))
        for y in y0...y1 {
            for x in x0...x1 {
                samples.append(luminances[y * width + x])
            }
        }
        let threshold = otsuThreshold(samples)
        let whiteCutoff = max(0.88, min(0.98, threshold + 0.18))
        let darkCutoff = min(0.22, threshold - 0.10)

        var rowContent = [Double](repeating: 0, count: y1 - y0 + 1)
        var colContent = [Double](repeating: 0, count: x1 - x0 + 1)
        for y in y0...y1 {
            var rowCount = 0
            for x in x0...x1 {
                let value = luminances[y * width + x]
                if value > darkCutoff && value < whiteCutoff {
                    rowCount += 1
                    colContent[x - x0] += 1
                }
            }
            rowContent[y - y0] = Double(rowCount) / Double(x1 - x0 + 1)
        }
        for index in colContent.indices {
            colContent[index] /= Double(y1 - y0 + 1)
        }

        guard let xSpan = strongestContentSpan(colContent, absoluteOffset: x0, minCoverage: 0.06),
              let ySpan = strongestContentSpan(rowContent, absoluteOffset: y0, minCoverage: 0.06) else {
            return rect
        }

        let edgeRect = refineByGradient(luminances: luminances, width: width, height: height, xRange: xSpan, yRange: ySpan)
        return edgeRect.normalized
    }

    private func otsuThreshold(_ values: [Double]) -> Double {
        var histogram = [Int](repeating: 0, count: 256)
        for value in values {
            let bucket = min(255, max(0, Int(value * 255)))
            histogram[bucket] += 1
        }

        let total = values.count
        let sum = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset * $1.element) }
        var backgroundWeight = 0
        var backgroundSum = 0.0
        var bestVariance = 0.0
        var bestThreshold = 128

        for index in 0..<256 {
            backgroundWeight += histogram[index]
            guard backgroundWeight > 0 else { continue }
            let foregroundWeight = total - backgroundWeight
            guard foregroundWeight > 0 else { break }
            backgroundSum += Double(index * histogram[index])
            let backgroundMean = backgroundSum / Double(backgroundWeight)
            let foregroundMean = (sum - backgroundSum) / Double(foregroundWeight)
            let variance = Double(backgroundWeight * foregroundWeight) * pow(backgroundMean - foregroundMean, 2)
            if variance > bestVariance {
                bestVariance = variance
                bestThreshold = index
            }
        }
        return Double(bestThreshold) / 255.0
    }

    private func strongestContentSpan(_ values: [Double], absoluteOffset: Int, minCoverage: Double) -> ClosedRange<Int>? {
        let smoothed = values.indices.map { index in
            let start = max(0, index - 3)
            let end = min(values.count - 1, index + 3)
            return values[start...end].reduce(0, +) / Double(end - start + 1)
        }
        var start: Int?
        var best: ClosedRange<Int>?
        for (index, value) in smoothed.enumerated() {
            if value >= minCoverage {
                if start == nil { start = index }
            } else if let s = start {
                if best == nil || index - s > best!.count {
                    best = s...(index - 1)
                }
                start = nil
            }
        }
        if let s = start, best == nil || values.count - s > best!.count {
            best = s...(values.count - 1)
        }
        return best.map { (absoluteOffset + $0.lowerBound)...(absoluteOffset + $0.upperBound) }
    }

    private func refineByGradient(luminances: [Double], width: Int, height: Int, xRange: ClosedRange<Int>, yRange: ClosedRange<Int>) -> CGRect {
        let left = strongestVerticalEdge(luminances: luminances, width: width, xCandidates: xRange.lowerBound...min(xRange.upperBound, xRange.lowerBound + max(4, xRange.count / 8)), yRange: yRange) ?? xRange.lowerBound
        let right = strongestVerticalEdge(luminances: luminances, width: width, xCandidates: max(xRange.lowerBound, xRange.upperBound - max(4, xRange.count / 8))...xRange.upperBound, yRange: yRange) ?? xRange.upperBound
        let top = strongestHorizontalEdge(luminances: luminances, width: width, xRange: xRange, yCandidates: yRange.lowerBound...min(yRange.upperBound, yRange.lowerBound + max(4, yRange.count / 8))) ?? yRange.lowerBound
        let bottom = strongestHorizontalEdge(luminances: luminances, width: width, xRange: xRange, yCandidates: max(yRange.lowerBound, yRange.upperBound - max(4, yRange.count / 8))...yRange.upperBound) ?? yRange.upperBound

        let x = min(left, right)
        let y = min(top, bottom)
        let maxX = max(left, right)
        let maxY = max(top, bottom)
        return CGRect(x: Double(x) / Double(width), y: Double(y) / Double(height), width: Double(maxX - x + 1) / Double(width), height: Double(maxY - y + 1) / Double(height))
    }

    private func strongestVerticalEdge(luminances: [Double], width: Int, xCandidates: ClosedRange<Int>, yRange: ClosedRange<Int>) -> Int? {
        var bestX: Int?
        var bestScore = 0.0
        for x in xCandidates where x > 0 && x < width - 1 {
            var score = 0.0
            for y in yRange {
                score += abs(luminances[y * width + x] - luminances[y * width + x - 1])
                score += abs(luminances[y * width + x + 1] - luminances[y * width + x])
            }
            score /= Double(max(1, yRange.count))
            if score > bestScore {
                bestScore = score
                bestX = x
            }
        }
        return bestScore > 0.035 ? bestX : nil
    }

    private func strongestHorizontalEdge(luminances: [Double], width: Int, xRange: ClosedRange<Int>, yCandidates: ClosedRange<Int>) -> Int? {
        var bestY: Int?
        var bestScore = 0.0
        for y in yCandidates where y > 0 && y < (luminances.count / width) - 1 {
            var score = 0.0
            for x in xRange {
                score += abs(luminances[y * width + x] - luminances[(y - 1) * width + x])
                score += abs(luminances[(y + 1) * width + x] - luminances[y * width + x])
            }
            score /= Double(max(1, xRange.count))
            if score > bestScore {
                bestScore = score
                bestY = y
            }
        }
        return bestScore > 0.035 ? bestY : nil
    }

    private func detectWithVision(cgImage: CGImage, settings: CropSettings) -> [CropRegion] {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 80
        request.minimumConfidence = 0.28
        request.minimumAspectRatio = 0.15
        request.maximumAspectRatio = 8.0
        request.minimumSize = 0.035
        request.quadratureTolerance = 35

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let observations = (request.results ?? [])
            .compactMap { observation -> CGRect? in
                let box = observation.boundingBox
                let rect = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height).normalized
                let area = rect.width * rect.height
                let notWholeScan = !(rect.width > 0.94 && rect.height > 0.94)
                return area >= 0.004 && notWholeScan ? rect : nil
            }

        let merged = mergeNormalizedRects(observations, overlapThreshold: 0.62)
        return indexedRegions(from: merged, settings: settings)
    }

    private func detectByDarkGutters(luminances: [Double], width: Int, height: Int, settings: CropSettings) -> [CropRegion] {
        let sorted = luminances.sorted()
        let darkCutoff = sorted[max(0, Int(Double(sorted.count) * 0.18))]

        var rowDark = [Double](repeating: 0, count: height)
        var colDark = [Double](repeating: 0, count: width)
        for y in 0..<height {
            var count = 0
            for x in 0..<width where luminances[y * width + x] <= darkCutoff + 0.035 {
                count += 1
            }
            rowDark[y] = Double(count) / Double(width)
        }
        for x in 0..<width {
            var count = 0
            for y in 0..<height where luminances[y * width + x] <= darkCutoff + 0.035 {
                count += 1
            }
            colDark[x] = Double(count) / Double(height)
        }

        let rowBands = contentBands(fromDarkness: rowDark, minLength: max(18, height / 18))
        let colBands = contentBands(fromDarkness: colDark, minLength: max(18, width / 18))
        guard rowBands.count * colBands.count > 1 else { return [] }

        var rects: [CGRect] = []
        for row in rowBands {
            for col in colBands {
                let rect = trimCell(
                    luminances: luminances,
                    width: width,
                    height: height,
                    xRange: col,
                    yRange: row,
                    darkCutoff: darkCutoff
                )
                let area = rect.width * rect.height
                if area >= 0.004, rect.width > 0.04, rect.height > 0.04 {
                    rects.append(rect)
                }
            }
        }

        return indexedRegions(from: mergeNormalizedRects(rects, overlapThreshold: 0.5), settings: settings)
    }

    private func contentBands(fromDarkness values: [Double], minLength: Int) -> [ClosedRange<Int>] {
        let smoothed = values.indices.map { index in
            let start = max(0, index - 3)
            let end = min(values.count - 1, index + 3)
            return values[start...end].reduce(0, +) / Double(end - start + 1)
        }

        var bands: [ClosedRange<Int>] = []
        var start: Int?
        for (index, value) in smoothed.enumerated() {
            let isGutter = value > 0.55
            if isGutter {
                if let s = start, index - s >= minLength {
                    bands.append(s...(index - 1))
                }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        if let s = start, values.count - s >= minLength {
            bands.append(s...(values.count - 1))
        }
        return bands
    }

    private func trimCell(luminances: [Double], width: Int, height: Int, xRange: ClosedRange<Int>, yRange: ClosedRange<Int>, darkCutoff: Double) -> CGRect {
        var minX = xRange.upperBound
        var minY = yRange.upperBound
        var maxX = xRange.lowerBound
        var maxY = yRange.lowerBound
        let threshold = darkCutoff + 0.08

        for y in yRange {
            for x in xRange {
                let value = luminances[y * width + x]
                if value > threshold {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }

        guard minX < maxX, minY < maxY else {
            return CGRect(x: Double(xRange.lowerBound) / Double(width), y: Double(yRange.lowerBound) / Double(height), width: Double(xRange.count) / Double(width), height: Double(yRange.count) / Double(height)).normalized
        }
        return CGRect(x: Double(minX) / Double(width), y: Double(minY) / Double(height), width: Double(maxX - minX + 1) / Double(width), height: Double(maxY - minY + 1) / Double(height)).normalized
    }

    private func indexedRegions(from rects: [CGRect], settings: CropSettings) -> [CropRegion] {
        return rects
            .sorted { lhs, rhs in
                if abs(lhs.minY - rhs.minY) > 0.045 { return lhs.minY < rhs.minY }
                return lhs.minX < rhs.minX
            }
            .enumerated()
            .map { offset, rect in
                CropRegion(
                    index: offset + 1,
                    rect: rect.normalized
                )
            }
    }

    private func mergeNormalizedRects(_ rects: [CGRect], overlapThreshold: Double) -> [CGRect] {
        var merged: [CGRect] = []
        for rect in rects {
            var current = rect
            var didMerge = true
            while didMerge {
                didMerge = false
                for index in merged.indices where overlapRatio(current, merged[index]) > overlapThreshold || current.intersection(merged[index]).area > min(current.area, merged[index].area) * 0.45 {
                    current = current.union(merged[index]).normalized
                    merged.remove(at: index)
                    didMerge = true
                    break
                }
            }
            merged.append(current)
        }
        return merged
    }

    private func overlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.area / max(0.0001, min(lhs.area, rhs.area))
    }

    private func marginRect(_ settings: CropSettings) -> CGRect {
        CGRect(
            x: settings.left / 200,
            y: settings.top / 200,
            width: max(0.1, 1 - (settings.left + settings.right) / 200),
            height: max(0.1, 1 - (settings.top + settings.bottom) / 200)
        ).normalized
    }

    private func luminance(_ color: NSColor?) -> Double {
        guard let rgb = color?.usingColorSpace(.deviceRGB) else { return 0 }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }

    private func estimatedBackground(luminances: [Double], width: Int, height: Int) -> Double {
        var samples: [Double] = []
        let step = max(1, min(width, height) / 80)
        for x in stride(from: 0, to: width, by: step) {
            samples.append(luminances[x])
            samples.append(luminances[(height - 1) * width + x])
        }
        for y in stride(from: 0, to: height, by: step) {
            samples.append(luminances[y * width])
            samples.append(luminances[y * width + width - 1])
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    private func localMeanLuminances(luminances: [Double], width: Int, height: Int, radius: Int) -> [Double] {
        let stride = width + 1
        var integral = [Double](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0..<height {
            var rowSum = 0.0
            for x in 0..<width {
                rowSum += luminances[y * width + x]
                integral[(y + 1) * stride + x + 1] = integral[y * stride + x + 1] + rowSum
            }
        }

        var means = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            let top = max(0, y - radius)
            let bottom = min(height - 1, y + radius)
            for x in 0..<width {
                let left = max(0, x - radius)
                let right = min(width - 1, x + radius)
                let x0 = left
                let y0 = top
                let x1 = right + 1
                let y1 = bottom + 1
                let sum = integral[y1 * stride + x1] - integral[y0 * stride + x1] - integral[y1 * stride + x0] + integral[y0 * stride + x0]
                means[y * width + x] = sum / Double((right - left + 1) * (bottom - top + 1))
            }
        }
        return means
    }

    private func downsampledLuminancesIfNeeded(luminances: [Double], width: Int, height: Int, maxPixels: Int) -> (luminances: [Double], width: Int, height: Int) {
        let pixelCount = width * height
        guard pixelCount > maxPixels else {
            return (luminances, width, height)
        }

        let scale = sqrt(Double(maxPixels) / Double(pixelCount))
        let targetWidth = max(32, Int(Double(width) * scale))
        let targetHeight = max(32, Int(Double(height) * scale))
        var resized = [Double](repeating: 0, count: targetWidth * targetHeight)

        for y in 0..<targetHeight {
            let sourceY = min(height - 1, Int(Double(y) / Double(targetHeight) * Double(height)))
            for x in 0..<targetWidth {
                let sourceX = min(width - 1, Int(Double(x) / Double(targetWidth) * Double(width)))
                resized[y * targetWidth + x] = luminances[sourceY * width + sourceX]
            }
        }
        return (resized, targetWidth, targetHeight)
    }

    private func percentile(_ values: [Double], fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * fraction)))
        return sorted[index]
    }

    private func dilated(_ mask: [Bool], width: Int, height: Int, iterations: Int) -> [Bool] {
        var current = mask
        for _ in 0..<iterations {
            var next = current
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) where current[y * width + x] {
                    for yy in (y - 1)...(y + 1) {
                        for xx in (x - 1)...(x + 1) {
                            next[yy * width + xx] = true
                        }
                    }
                }
            }
            current = next
        }
        return current
    }

    private func connectedBoxes(mask: [Bool], width: Int, height: Int) -> [PixelBox] {
        var visited = [Bool](repeating: false, count: width * height)
        var boxes: [PixelBox] = []
        var queue: [(Int, Int)] = []

        for y in 0..<height {
            for x in 0..<width {
                let start = y * width + x
                guard mask[start], !visited[start] else { continue }
                var box = PixelBox(minX: x, minY: y, maxX: x, maxY: y)
                visited[start] = true
                queue.removeAll(keepingCapacity: true)
                queue.append((x, y))
                var head = 0

                while head < queue.count {
                    let (cx, cy) = queue[head]
                    head += 1
                    box.include(x: cx, y: cy)
                    for (nx, ny) in [(cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)] {
                        guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                        let index = ny * width + nx
                        if mask[index], !visited[index] {
                            visited[index] = true
                            queue.append((nx, ny))
                        }
                    }
                }
                boxes.append(box)
            }
        }
        return boxes
    }

    private func maskDensity(mask: [Bool], width: Int, box: PixelBox) -> Double {
        var count = 0
        for y in box.minY...box.maxY {
            for x in box.minX...box.maxX where mask[y * width + x] {
                count += 1
            }
        }
        return Double(count) / Double(max(1, box.width * box.height))
    }

    private func mergeLocalContrastBoxes(_ boxes: [PixelBox], width: Int, height: Int) -> [PixelBox] {
        let gap = max(4, min(width, height) / 85)
        var merged: [PixelBox] = []
        for box in boxes {
            var current = box
            var didMerge = true
            while didMerge {
                didMerge = false
                for index in merged.indices where merged[index].isClose(to: current, gap: gap) {
                    let union = merged[index].merged(with: current)
                    let addedArea = union.width * union.height - merged[index].width * merged[index].height - current.width * current.height
                    let reasonableBridge = addedArea < max(120, min(width, height) * min(width, height) / 90)
                    let similarRow = abs(merged[index].minY - current.minY) < max(18, height / 18)
                        || abs(merged[index].maxY - current.maxY) < max(18, height / 18)
                    if reasonableBridge || similarRow {
                        current = union
                        merged.remove(at: index)
                        didMerge = true
                        break
                    }
                }
            }
            merged.append(current)
        }
        return merged
    }

    private func mergeCloseBoxes(_ boxes: [PixelBox], width: Int, height: Int) -> [PixelBox] {
        let gap = max(8, min(width, height) / 35)
        var merged: [PixelBox] = []
        for box in boxes {
            var current = box
            var didMerge = true
            while didMerge {
                didMerge = false
                for index in merged.indices where merged[index].isClose(to: current, gap: gap) {
                    current = merged[index].merged(with: current)
                    merged.remove(at: index)
                    didMerge = true
                    break
                }
            }
            merged.append(current)
        }
        return merged
    }
}

private struct PixelBox {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int

    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }

    mutating func include(x: Int, y: Int) {
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
    }

    func isClose(to other: PixelBox, gap: Int) -> Bool {
        !(maxX + gap < other.minX || other.maxX + gap < minX || maxY + gap < other.minY || other.maxY + gap < minY)
    }

    func merged(with other: PixelBox) -> PixelBox {
        PixelBox(minX: min(minX, other.minX), minY: min(minY, other.minY), maxX: max(maxX, other.maxX), maxY: max(maxY, other.maxY))
    }
}

private struct IntSegment {
    var start: Int
    var end: Int

    var size: Int { end - start }

    func contains(_ value: Int) -> Bool {
        start <= value && value <= end
    }
}

private struct IntBox {
    var left: Int
    var top: Int
    var right: Int
    var bottom: Int

    var width: Int { right - left }
    var height: Int { bottom - top }
    var isValid: Bool { width > 30 && height > 30 }

    func clamped(width: Int, height: Int) -> IntBox {
        IntBox(
            left: max(0, min(width, left)),
            top: max(0, min(height, top)),
            right: max(0, min(width, right)),
            bottom: max(0, min(height, bottom))
        )
    }

    func union(_ other: IntBox) -> IntBox {
        IntBox(
            left: min(left, other.left),
            top: min(top, other.top),
            right: max(right, other.right),
            bottom: max(bottom, other.bottom)
        )
    }
}

private extension CGRect {
    var area: Double {
        guard !isNull else { return 0 }
        return max(0, width) * max(0, height)
    }

    var normalized: CGRect {
        let x = min(max(origin.x, 0), 0.95)
        let y = min(max(origin.y, 0), 0.95)
        let width = min(max(size.width, 0.05), 1 - x)
        let height = min(max(size.height, 0.05), 1 - y)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private extension Array where Element == Double {
    var average: Double {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / Double(count)
    }
}
