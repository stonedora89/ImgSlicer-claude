import CoreGraphics
import Foundation
import Testing
@testable import ImgSlicer

@Suite("Film deskew validation")
struct FilmDeskewValidationTests {
    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImgSlicerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Candidate adjustment preserves the estimated angle")
    func adjustedCandidatePreservesEstimatedAngle() {
        let candidate = CropCandidate(
            title: "deskew",
            detail: "validation",
            regions: [
                CropRegion(
                    index: 1,
                    rect: CGRect(x: 0.1, y: 0.2, width: 0.7, height: 0.6),
                    angle: 3.25
                )
            ]
        )

        let adjusted = candidate.adjustedRegions(settings: CropSettings())

        #expect(adjusted.count == 1)
        #expect(
            abs(adjusted[0].angle - 3.25) <= 0.000_001,
            "Applying margins/candidate selection must not erase the detected deskew angle"
        )
    }

    @Test("A uniform frame does not invent tilt")
    func uniformFrameDoesNotInventTilt() {
        let width = 120
        let height = 80
        let gray = [UInt8](repeating: 32, count: width * height)

        let angle = ImageProcessor().estimateRegionTilt(
            gray: gray,
            width: width,
            height: height,
            rect: CGRect(x: 0, y: 0, width: 1, height: 1)
        )

        #expect(abs(angle) <= 0.000_001, "A featureless frame has no evidence of tilt")
    }

    @Test("A smooth gradient does not invent tilt")
    func smoothGradientDoesNotInventTilt() {
        let width = 120
        let height = 80
        let gray = (0..<height).flatMap { _ in
            (0..<width).map { x in UInt8(20 + x / 2) }
        }

        let angle = ImageProcessor().estimateRegionTilt(
            gray: gray,
            width: width,
            height: height,
            rect: CGRect(x: 0, y: 0, width: 1, height: 1)
        )

        #expect(abs(angle) <= 0.000_001, "A smooth exposure gradient is not a tilted frame edge")
    }

    @Test("A known rotated rectangle recovers its tilt magnitude")
    func knownRotatedRectangleRecoversItsMagnitude() {
        let width = 160
        let height = 120
        let expectedDegrees = 4.0
        let radians = expectedDegrees * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        let centerX = Double(width - 1) / 2
        let centerY = Double(height - 1) / 2

        var gray = [UInt8](repeating: 12, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) - centerX
                let dy = Double(y) - centerY
                let localX = dx * cosine + dy * sine
                let localY = -dx * sine + dy * cosine
                if abs(localX) <= 55, abs(localY) <= 34 {
                    gray[y * width + x] = 220
                }
            }
        }

        let angle = ImageProcessor().estimateRegionTilt(
            gray: gray,
            width: width,
            height: height,
            rect: CGRect(x: 0, y: 0, width: 1, height: 1)
        )

        #expect(
            abs(abs(angle) - expectedDegrees) <= 0.75,
            "A clean synthetic frame should yield the known tilt magnitude"
        )
    }

    @Test("Explicit re-detection can remove one photo's persisted crop history")
    func removingPersistedCropHistoryDoesNotRestoreOldBoxes() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let photoURL = root.appendingPathComponent("frame.jpg")
        var photo = PhotoItem(url: photoURL, relativePath: "frame.jpg")
        photo.cropRegions = [
            CropRegion(index: 1, rect: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4), angle: 2.5, isManual: true)
        ]
        photo.isManual = true
        let task = FolderTask(
            rootURL: root,
            displayName: "test",
            imageCount: 1,
            folderCount: 1,
            photos: [photo]
        )
        let store = CropEditStore()
        store.save(photo: photo, in: task)
        store.remove(photoRelativePath: photo.relativePath, rootURL: root)

        let freshPhoto = PhotoItem(url: photoURL, relativePath: "frame.jpg")
        let freshRect = freshPhoto.cropRegions[0].rect
        let freshTask = FolderTask(
            rootURL: root,
            displayName: "test",
            imageCount: 1,
            folderCount: 1,
            photos: [freshPhoto]
        )
        let restored = store.restoredTask(freshTask)

        #expect(restored.photos[0].isManual == false)
        #expect(restored.photos[0].cropRegions[0].rect == freshRect)
        #expect(restored.photos[0].cropRegions[0].angle == 0)
    }

    @Test("Explicit re-detection removes only the current photo's learned sample")
    func removingCurrentPhotoSamplePreservesOtherPhotos() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SampleLibrary()

        func profile(_ sourceName: String) -> SampleProfile {
            SampleProfile(
                sourceName: sourceName,
                layout: .filmScan,
                regionCount: 4,
                averageWidth: 0.2,
                averageHeight: 0.7,
                averageArea: 0.14,
                aspectRatio: 0.286,
                interiorBrightness: 0.5,
                borderBrightness: 0.1,
                contrast: 0.4,
                edgeStrength: 0.3
            )
        }

        library.save(profile: profile("current.jpg"), rootURL: root)
        library.save(profile: profile("other.jpg"), rootURL: root)
        library.removeProfiles(sourceName: "current.jpg", rootURL: root)

        let remaining = library.load(rootURL: root)
        #expect(remaining.map(\.sourceName) == ["other.jpg"])
    }
}
