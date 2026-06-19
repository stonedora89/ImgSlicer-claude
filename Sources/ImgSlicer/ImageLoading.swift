import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Efficient, cached, downsampled image loading.
///
/// The app routinely opens very large scans (tens of megapixels). Decoding
/// them at full resolution on the main thread — as `NSImage(contentsOf:)` in a
/// SwiftUI `body` does — both blocks the UI and balloons memory, which is what
/// made loading feel slow and sometimes froze the whole window.
///
/// Here we use `ImageIO` to decode a *downsampled* thumbnail directly from the
/// file (it never materialises the full-resolution bitmap) and cache the
/// result keyed by URL + target size.
/// `NSImage` isn't `Sendable`; the images produced here are treated as
/// immutable, so this box lets us hand them across task boundaries safely.
struct SendableImage: @unchecked Sendable {
    let image: NSImage
}

enum DownsampledImageLoader {
    // NSCache is documented as thread-safe, so unchecked shared access is fine.
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }()

    private static func key(_ url: URL, _ maxPixel: Int) -> NSString {
        "\(url.path)#\(maxPixel)" as NSString
    }

    static func cached(_ url: URL, maxPixel: Int) -> NSImage? {
        cache.object(forKey: key(url, maxPixel))
    }

    /// Decodes a downsampled image whose longest side is at most `maxPixel`.
    /// Safe to call off the main thread.
    static func load(_ url: URL, maxPixel: Int) -> NSImage? {
        let cacheKey = key(url, maxPixel)
        if let hit = cache.object(forKey: cacheKey) { return hit }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: cacheKey)
        return image
    }

    /// Warm the cache for the given URLs in the background (e.g. the photos
    /// adjacent to the current selection) so navigating to them is instant.
    static func prefetch(_ urls: [URL], maxPixel: Int) {
        for url in urls where cache.object(forKey: key(url, maxPixel)) == nil {
            Task.detached(priority: .utility) {
                _ = load(url, maxPixel: maxPixel)
            }
        }
    }
}

/// A SwiftUI view that loads a downsampled image asynchronously off the main
/// thread, showing `placeholder` until it is ready. Reloads when `url` or
/// `maxPixel` changes.
struct DownsampledImageView<Placeholder: View>: View {
    let url: URL
    let maxPixel: Int
    let content: (NSImage) -> AnyView
    let placeholder: () -> Placeholder

    @State private var image: NSImage?

    init(
        url: URL,
        maxPixel: Int,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        content: @escaping (NSImage) -> AnyView
    ) {
        self.url = url
        self.maxPixel = maxPixel
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image {
                content(image)
            } else {
                placeholder()
            }
        }
        .task(id: "\(url.path)#\(maxPixel)") {
            // Serve a cache hit synchronously to avoid a placeholder flash.
            if let hit = DownsampledImageLoader.cached(url, maxPixel: maxPixel) {
                image = hit
                return
            }
            let target = url
            let pixels = maxPixel
            let loaded = await Task.detached(priority: .userInitiated) {
                DownsampledImageLoader.load(target, maxPixel: pixels).map(SendableImage.init)
            }.value
            if !Task.isCancelled {
                image = loaded?.image
            }
        }
    }
}
