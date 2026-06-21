import AppKit
import Foundation

struct ExternalDetectionBox: Decodable, Sendable {
    let left: Double
    let top: Double
    let right: Double
    let bottom: Double
    let confidence: Double?
}

struct ExternalDetectionResult: Decodable, Sendable {
    let boxes: [ExternalDetectionBox]
}

enum ExternalDetectionOutcome: Sendable {
    case success(ExternalDetectionResult)
    case failure(String)
}

struct ExternalDetector: Sendable {
    let pythonPath: String
    let scriptURL: URL?

    init(projectRoot: URL? = nil) {
        let root = projectRoot ?? Self.projectRoot()
        self.pythonPath = Self.resolvePython(projectRoot: root)
        self.scriptURL = Self.resolveScript(projectRoot: root)
    }

    func detect(imageURL: URL) -> ExternalDetectionOutcome {
        guard let scriptURL else {
            return .failure("OpenCV detector script not found")
        }
        guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
            return .failure("Python not executable: \(pythonPath)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptURL.path, "--detect-json", imageURL.path]

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failure(error.localizedDescription)
        }

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            return .failure(stderr.isEmpty ? "external detector exited with \(process.terminationStatus)" : stderr)
        }

        do {
            return .success(try JSONDecoder().decode(ExternalDetectionResult.self, from: outputData))
        } catch {
            let raw = String(data: outputData, encoding: .utf8) ?? ""
            return .failure("decode failed: \(error.localizedDescription); output: \(raw)")
        }
    }

    private static func resolvePython(projectRoot: URL) -> String {
        if let override = ProcessInfo.processInfo.environment["IMGSLICER_PYTHON"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }

        var candidates: [String] = []
        if let bundledPython = Bundle.main.resourceURL?.appendingPathComponent("python/bin/python3").path {
            candidates.append(bundledPython)
        }
        candidates.append(contentsOf: [
            projectRoot.appendingPathComponent(".venv/bin/python3").path,
            projectRoot.appendingPathComponent("venv/bin/python3").path,
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ])
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
    }

    private static func resolveScript(projectRoot: URL) -> URL? {
        if let override = ProcessInfo.processInfo.environment["IMGSLICER_DETECTOR_SCRIPT"] {
            let url = URL(fileURLWithPath: override).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        var bundledCandidates = [
            Bundle.main.resourceURL?.appendingPathComponent("detectors/opencv_detector.py")
        ].compactMap { $0 }
#if SWIFT_PACKAGE
        if let packageScript = Bundle.module.url(
            forResource: "opencv_detector",
            withExtension: "py",
            subdirectory: "detectors"
        ) {
            bundledCandidates.append(packageScript)
        }
#endif
        if let bundled = bundledCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return bundled
        }

        let sourceCandidates = [
            projectRoot.appendingPathComponent("Sources/ImgSlicer/Resources/detectors/opencv_detector.py"),
            projectRoot.appendingPathComponent("scripts/opencv_detector.py"),
        ]
        return sourceCandidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func projectRoot() -> URL {
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
