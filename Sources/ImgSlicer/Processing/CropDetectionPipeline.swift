import Foundation

enum CropDetectionStage: Sendable {
    case projectionSeparators
    case filmFrames
    case visionRectangles
    case foregroundComponents
    case localContrastComponents
    case externalDetector
    case darkGutters

    var displayName: String {
        switch self {
        case .projectionSeparators:
            return "分隔线识别"
        case .filmFrames:
            return "胶片边框"
        case .visionRectangles:
            return "鐭╁舰杞粨"
        case .foregroundComponents:
            return "涓讳綋鍖哄煙"
        case .localContrastComponents:
            return "局部对比"
        case .externalDetector:
            return "智能识别"
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
            automaticStages = [.projectionSeparators, .darkGutters, .filmFrames, .localContrastComponents, .visionRectangles, .foregroundComponents]
        case .gridPhoto:
            automaticStages = [.projectionSeparators, .darkGutters, .localContrastComponents, .foregroundComponents, .visionRectangles, .filmFrames]
        case .balanced:
            automaticStages = [.filmFrames, .projectionSeparators, .darkGutters, .localContrastComponents, .visionRectangles, .foregroundComponents]
        }

        guard let selectedStage = settings.algorithmMode.stage else {
            return automaticStages
        }
        if selectedStage == .externalDetector {
            return [selectedStage]
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
        case .localContrastComponents:
            return .localContrastComponents
        case .externalDetector:
            return .externalDetector
        case .darkGutters:
            return .darkGutters
        }
    }
}

struct ProcessingPolicy: Sendable {
    func shouldReuseLocatedRegions(for photo: PhotoItem) -> Bool {
        guard !photo.hasLocalOverrides else { return true }
        guard photo.status == .located || photo.status == .autoDone else { return false }
        return photo.cropRegions.contains { region in
            region.rect.width > 0.05 && region.rect.height > 0.05
        }
    }
}

