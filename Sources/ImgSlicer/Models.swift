import Foundation
import CoreGraphics

enum TaskStatus: String, CaseIterable, Identifiable, Sendable {
    case waiting = "等待中"
    case running = "处理中"
    case needsReview = "需确认"
    case done = "已完成"

    var id: String { rawValue }
}

enum PhotoStatus: String, Sendable {
    case pending = "待处理"
    case locating = "定位中"
    case located = "已定位"
    case running = "处理中"
    case autoDone = "自动完成"
    case manual = "手动微调"
    case failed = "需确认"
}

enum OrientationMode: String, CaseIterable, Identifiable, Sendable {
    case automatic = "自动"
    case landscape = "横向"
    case portrait = "纵向"
    var id: String { rawValue }
}

enum CropBusinessProfile: String, CaseIterable, Identifiable, Codable, Sendable {
    case balanced = "均衡"
    case filmScan = "胶片扫描"
    case gridPhoto = "多宫格照片"

    var id: String { rawValue }
}

enum ImagePreprocessMode: String, CaseIterable, Identifiable, Sendable {
    case original = "原图"
    case highContrast = "增强"
    case mask = "蒙版"
    case inverted = "反转"

    var id: String { rawValue }
}

enum CropAlgorithmMode: String, CaseIterable, Identifiable, Sendable {
    case automatic = "自动"
    case projectionSeparators = "分隔线"
    case filmFrames = "胶片框"
    case visionRectangles = "矩形"
    case foregroundComponents = "主体"
    case localContrastComponents = "局部对比"
    case externalDetector = "智能识别"
    case darkGutters = "暗区网格"

    var id: String { rawValue }
}

struct PhotoItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    let url: URL
    let relativePath: String
    var status: PhotoStatus = .pending
    var cropRegions: [CropRegion] = [CropRegion(index: 1, rect: CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84))]
    var cropCandidates: [CropCandidate] = []
    var selectedCandidateID: CropCandidate.ID?
    var isManual: Bool = false
    var outputURLs: [URL] = []

    var name: String { url.lastPathComponent }
}

struct CropRegion: Identifiable, Hashable, Sendable {
    var id = UUID()
    var index: Int
    var rect: CGRect
    /// Tilt of the frame in degrees, applied as a rotation about `rect`'s
    /// centre. 0 means axis-aligned (the historical behaviour); a non-zero
    /// angle lets a skewed scan be cut out straight.
    var angle: Double = 0
    var isManual: Bool = false
}

struct CropCandidate: Identifiable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var detail: String
    var regions: [CropRegion]
    var marginScale: Double = 1
    var score: Double = 0

    func adjustedRegions(settings: CropSettings) -> [CropRegion] {
        regions.enumerated().map { offset, region in
            CropRegion(
                index: offset + 1,
                rect: region.rect.expanded(
                    top: settings.top * marginScale / 2000,
                    bottom: settings.bottom * marginScale / 2000,
                    left: settings.left * marginScale / 2000,
                    right: settings.right * marginScale / 2000
                ),
                isManual: false
            )
        }
    }
}

struct CropMarginReference: Hashable, Sendable {
    var source: String
    var top: Double
    var bottom: Double
    var left: Double
    var right: Double
}

struct FolderTask: Identifiable, Sendable {
    let id = UUID()
    let rootURL: URL
    let displayName: String
    let imageCount: Int
    let folderCount: Int
    var status: TaskStatus = .waiting
    var detail: String = "等待开始处理"
    var processedCount: Int = 0
    var photos: [PhotoItem]

    var progress: Double {
        guard imageCount > 0 else { return 0 }
        return Double(processedCount) / Double(imageCount)
    }
}

struct ImportSummary: Sendable {
    var folderCount: Int
    var subfolderCount: Int
    var imageCount: Int
}

struct CropSettings: Sendable {
    var businessProfile: CropBusinessProfile = .filmScan
    var preprocessMode: ImagePreprocessMode = .original
    var algorithmMode: CropAlgorithmMode = .automatic
    var orientation: OrientationMode = .automatic
    var top: Double = 0
    var bottom: Double = 0
    var left: Double = 0
    var right: Double = 0
    var sensitivity: Double = 64
    var splitSensitivity: Double = 62
    var minimumRegionPercent: Double = 0.6
}

private extension CGRect {
    func expanded(top: Double, bottom: Double, left: Double, right: Double) -> CGRect {
        let x = min(max(origin.x - left, 0), 0.95)
        let y = min(max(origin.y - top, 0), 0.95)
        let maxX = min(1, self.maxX + right)
        let maxY = min(1, self.maxY + bottom)
        return CGRect(
            x: x,
            y: y,
            width: min(max(maxX - x, 0.05), 1 - x),
            height: min(max(maxY - y, 0.05), 1 - y)
        )
    }
}
