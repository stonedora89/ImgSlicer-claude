import Foundation

struct FolderScanResult {
    var tasks: [FolderTask]
    var folderCount: Int
    var subfolderCount: Int
    var imageCount: Int
}

struct FolderScanner {
    private let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "gif"]

    func scan(url: URL) throws -> FolderScanResult {
        let root = url.standardizedFileURL
        let manager = FileManager.default
        let values = try? root.resourceValues(forKeys: [.isDirectoryKey])

        if values?.isDirectory != true {
            return scanFile(url: root)
        }

        var grouped: [URL: [PhotoItem]] = [:]
        var allFolders: Set<URL> = [root]

        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return FolderScanResult(tasks: [], folderCount: 0, subfolderCount: 0, imageCount: 0)
        }

        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                allFolders.insert(fileURL)
                continue
            }

            guard supportedExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            let parent = fileURL.deletingLastPathComponent().standardizedFileURL
            allFolders.insert(parent)
            let relative = relativePath(from: root, to: fileURL)
            grouped[parent, default: []].append(PhotoItem(url: fileURL, relativePath: relative))
        }

        var tasks: [FolderTask] = []
        for folder in grouped.keys.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
            let photos = (grouped[folder] ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            guard !photos.isEmpty else { continue }
            tasks.append(
                FolderTask(
                    rootURL: root,
                    displayName: folder == root ? root.lastPathComponent : "\(root.lastPathComponent) / \(folder.lastPathComponent)",
                    imageCount: photos.count,
                    folderCount: allFolders.count,
                    photos: photos
                )
            )
        }

        return FolderScanResult(
            tasks: tasks,
            folderCount: max(1, grouped.keys.count),
            subfolderCount: max(0, allFolders.count - 1),
            imageCount: tasks.reduce(0) { $0 + $1.imageCount }
        )
    }

    private func scanFile(url: URL) -> FolderScanResult {
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
            return FolderScanResult(tasks: [], folderCount: 0, subfolderCount: 0, imageCount: 0)
        }

        let parent = url.deletingLastPathComponent().standardizedFileURL
        let photo = PhotoItem(url: url, relativePath: url.lastPathComponent)
        let task = FolderTask(
            rootURL: parent,
            displayName: parent.lastPathComponent.isEmpty ? url.lastPathComponent : parent.lastPathComponent,
            imageCount: 1,
            folderCount: 1,
            photos: [photo]
        )
        return FolderScanResult(tasks: [task], folderCount: 1, subfolderCount: 0, imageCount: 1)
    }

    private func relativePath(from root: URL, to file: URL) -> String {
        let rootPath = root.path(percentEncoded: false)
        let filePath = file.path(percentEncoded: false)
        guard filePath.hasPrefix(rootPath) else { return file.lastPathComponent }
        return String(filePath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
