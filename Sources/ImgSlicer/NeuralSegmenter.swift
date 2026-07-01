import AppKit
import CoreGraphics
import CoreML
import Foundation

/// Deep-learning detection path: a U-Net segments photo-vs-gutter, then
/// connected components become frame boxes. It sees SEMANTICS (a dark ferry
/// cabin is still a photo), which the pixel-threshold heuristics cannot — so it
/// does not cut into dark frames. The raw component boxes are deliberately left
/// for the existing grid post-processing (split/align/complete) to regularize;
/// that division of labour scored 0.918 box IoU in the Python prototype.
///
/// This is an independent, optional engine. The model (Resources/
/// PhotoSegmenter.mlmodelc, 272 KB) is bundled but only loaded on demand.
struct NeuralSegmenter {
    static let inputHeight = 288
    static let inputWidth = 1024

    private let model: MLModel

    init?() {
        guard let url = Bundle.module.url(forResource: "PhotoSegmenter", withExtension: "mlmodelc"),
              let model = try? MLModel(contentsOf: url) else {
            return nil
        }
        self.model = model
    }

    /// Segment the scan and return frame boxes in normalized coordinates.
    func detect(cgImage: CGImage) -> [CGRect] {
        let W = Self.inputWidth, H = Self.inputHeight
        guard let gray = Self.grayscaleResized(cgImage, width: W, height: H),
              let input = try? MLMultiArray(shape: [1, 1, NSNumber(value: H), NSNumber(value: W)], dataType: .float32) else {
            return []
        }
        let ptr = input.dataPointer.bindMemory(to: Float.self, capacity: W * H)
        for i in 0..<(W * H) { ptr[i] = Float(gray[i]) / 255.0 }

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["image": input]),
              let out = try? model.prediction(from: provider),
              let logits = firstMultiArray(in: out) else {
            return []
        }

        // Threshold the sigmoid at 0.5 → binary foreground.
        let count = W * H
        var fg = [Bool](repeating: false, count: count)
        let lp = logits.dataPointer.bindMemory(to: Float.self, capacity: count)
        for i in 0..<count { fg[i] = lp[i] > 0 }  // sigmoid(x)>0.5 ⇔ x>0

        return Self.componentBoxes(foreground: fg, width: W, height: H)
    }

    private func firstMultiArray(in provider: MLFeatureProvider) -> MLMultiArray? {
        for name in provider.featureNames {
            if let v = provider.featureValue(for: name)?.multiArrayValue { return v }
        }
        return nil
    }

    /// Draw the CGImage into a W×H grayscale byte buffer.
    static func grayscaleResized(_ cgImage: CGImage, width: Int, height: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: width * height)
        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &buffer, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width, space: space,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    /// Two-pass connected-component labelling (4-connectivity) → normalized
    /// bounding boxes, dropping specks and slivers. A morphological open (erode
    /// then dilate) first snaps thin bridges between frames so a weak gutter does
    /// not fuse two photos into one component.
    static func componentBoxes(foreground fgIn: [Bool], width: Int, height: Int) -> [CGRect] {
        var fg = morphologicalOpen(fgIn, width: width, height: height, iterations: 2)
        var labels = [Int](repeating: 0, count: width * height)
        var next = 1
        var stack = [Int]()
        // minX, minY, maxX, maxY, area per label
        var bounds: [(minX: Int, minY: Int, maxX: Int, maxY: Int, area: Int)] = [(0, 0, 0, 0, 0)]

        for start in 0..<(width * height) where fg[start] && labels[start] == 0 {
            let label = next; next += 1
            labels[start] = label
            var b = (minX: start % width, minY: start / width, maxX: start % width, maxY: start / width, area: 0)
            stack.removeAll(keepingCapacity: true); stack.append(start)
            while let p = stack.popLast() {
                let x = p % width, y = p / width
                b.area += 1
                if x < b.minX { b.minX = x }; if x > b.maxX { b.maxX = x }
                if y < b.minY { b.minY = y }; if y > b.maxY { b.maxY = y }
                if x > 0, fg[p-1], labels[p-1] == 0 { labels[p-1] = label; stack.append(p-1) }
                if x < width-1, fg[p+1], labels[p+1] == 0 { labels[p+1] = label; stack.append(p+1) }
                if y > 0, fg[p-width], labels[p-width] == 0 { labels[p-width] = label; stack.append(p-width) }
                if y < height-1, fg[p+width], labels[p+width] == 0 { labels[p+width] = label; stack.append(p+width) }
            }
            bounds.append(b)
        }

        let minArea = Int(0.002 * Double(width * height))
        var rects: [CGRect] = []
        for b in bounds.dropFirst() where b.area >= minArea {
            let w = Double(b.maxX - b.minX) / Double(width)
            let h = Double(b.maxY - b.minY) / Double(height)
            guard w >= 0.03, h >= 0.03 else { continue }
            rects.append(CGRect(x: Double(b.minX) / Double(width), y: Double(b.minY) / Double(height), width: w, height: h))
        }
        return rects
    }

    private static func morphologicalOpen(_ src: [Bool], width: Int, height: Int, iterations: Int) -> [Bool] {
        var a = src
        for _ in 0..<iterations { a = erode(a, width: width, height: height) }
        for _ in 0..<iterations { a = dilate(a, width: width, height: height) }
        return a
    }
    private static func erode(_ s: [Bool], width: Int, height: Int) -> [Bool] {
        var o = s
        for y in 0..<height { for x in 0..<width {
            let p = y*width+x
            if s[p], (x==0 || !s[p-1]) || (x==width-1 || !s[p+1]) || (y==0 || !s[p-width]) || (y==height-1 || !s[p+width]) { o[p] = false }
        }}
        return o
    }
    private static func dilate(_ s: [Bool], width: Int, height: Int) -> [Bool] {
        var o = s
        for y in 0..<height { for x in 0..<width {
            let p = y*width+x
            if !s[p], (x>0 && s[p-1]) || (x<width-1 && s[p+1]) || (y>0 && s[p-width]) || (y<height-1 && s[p+width]) { o[p] = true }
        }}
        return o
    }
}
