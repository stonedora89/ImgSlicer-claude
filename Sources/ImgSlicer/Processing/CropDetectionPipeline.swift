import Foundation

enum CropDetectionStage: Sendable {
    case projectionSeparators
    case filmFrames
    case visionRectangles
    case foregroundComponents
    case darkGutters

    var displayName: String {
        switch self {
        case .projectionSeparators:
            return "分隔线识别"
        case .filmFrames:
            return "胶片边框"
        case .visionRectangles:
            return "矩形轮廓"
        case .foregroundComponents:
            return "主体区域"
        case .darkGutters:
            return "暗区网格"
        }
    }
}

struct CropDetectionPerformancePolicy: Sendable {
    var maxAnalysisWidth: Int
    var projectionPreferred: Bool
    var stopAfterFirstMultiRegionCandidate: Bool
    var maxCandidateCount: Int
}

struct CropDetectionPipeline: Sendable {
    func performancePolicy(for settings: CropSettings) -> CropDetectionPerformancePolicy {
        switch settings.businessProfile {
        case .filmScan:
            return CropDetectionPerformancePolicy(maxAnalysisWidth: 600, projectionPreferred: true, stopAfterFirstMultiRegionCandidate: true, maxCandidateCount: 4)
        case .gridPhoto:
            return CropDetectionPerformancePolicy(maxAnalysisWidth: 640, projectionPreferred: true, stopAfterFirstMultiRegionCandidate: true, maxCandidateCount: 4)
        case .balanced:
            return CropDetectionPerformancePolicy(maxAnalysisWidth: 560, projectionPreferred: false, stopAfterFirstMultiRegionCandidate: true, maxCandidateCount: 4)
        }
    }

    func stages(for settings: CropSettings) -> [CropDetectionStage] {
        let automaticStages: [CropDetectionStage]
        switch settings.businessProfile {
        case .filmScan:
            automaticStages = [.projectionSeparators, .filmFrames, .visionRectangles, .foregroundComponents]
        case .gridPhoto:
            automaticStages = [.projectionSeparators, .foregroundComponents, .visionRectangles, .filmFrames]
        case .balanced:
            automaticStages = [.filmFrames, .projectionSeparators, .visionRectangles, .foregroundComponents]
        }

        guard let selectedStage = settings.algorithmMode.stage else {
            return automaticStages
        }
        return [selectedStage] + automaticStages.filter { $0 != selectedStage }
    }
}

private extension CropAlgorithmMode {
    var stage: CropDetectionStage? {
        switch self {
        case .automatic:
            return nil
        case .projectionSeparators:
            return .projectionSeparators
        case .filmFrames:
            return .filmFrames
        case .visionRectangles:
            return .visionRectangles
        case .foregroundComponents:
            return .foregroundComponents
        case .darkGutters:
            return .darkGutters
        }
    }
}

struct ProcessingPolicy: Sendable {
    func shouldReuseLocatedRegions(for photo: PhotoItem) -> Bool {
        guard !photo.isManual else { return true }
        guard photo.status == .located || photo.status == .autoDone else { return false }
        return photo.cropRegions.contains { region in
            region.rect.width > 0.05 && region.rect.height > 0.05
        }
    }
}
