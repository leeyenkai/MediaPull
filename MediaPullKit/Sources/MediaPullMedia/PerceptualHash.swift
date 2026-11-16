import CoreGraphics
import Foundation
import ImageIO

/// Two 64-bit perceptual hashes of an image (SPEC section 33). Deterministic: the image is reduced to a
/// small greyscale copy and summarised; no learned model is involved.
public struct ImageFingerprint: Codable, Hashable, Sendable {
    /// DCT hash: the sign of the 63 lowest-frequency coefficients of a 32×32 copy against their median.
    public var pHash: UInt64
    /// Difference hash: whether each pixel of a 9×8 copy is brighter than its right-hand neighbour.
    public var dHash: UInt64
    /// Average red, green and blue of each cell of an 8×8 grid. The hashes see only brightness, so this
    /// keeps colour versions of one photo (the same product in another colour) apart.
    public var colors: [UInt8]

    public init(pHash: UInt64, dHash: UInt64, colors: [UInt8]) {
        self.pHash = pHash
        self.dHash = dHash
        self.colors = colors
    }

    /// How far apart the colours are, from 0 to 255: the per-cell mean channel difference at the given
    /// percentile of cells (1 = the most different cell). Background that matches cannot hide a recoloured subject.
    public func colorDifference(to other: ImageFingerprint, percentile: Double = 1) -> Double {
        guard colors.count == other.colors.count, colors.count >= 3 else { return 255 }
        var cells: [Double] = []
        for cell in stride(from: 0, to: colors.count - 2, by: 3) {
            let sum = (0 ..< 3).reduce(0) { $0 + abs(Int(colors[cell + $1]) - Int(other.colors[cell + $1])) }
            cells.append(Double(sum) / 3)
        }
        cells.sort()
        let index = min(cells.count - 1, max(0, Int((Double(cells.count) * percentile).rounded(.up)) - 1))
        return cells[index]
    }

    /// The larger of the two Hamming distances, so both summaries must agree before images count as similar.
    public func distance(to other: ImageFingerprint) -> Int {
        max((pHash ^ other.pHash).nonzeroBitCount, (dHash ^ other.dHash).nonzeroBitCount)
    }
}

public enum PerceptualHash {
    /// The fingerprint of the first frame of an image file, with its camera orientation applied, or nil for
    /// files that cannot be decoded or are nearly flat (a blank frame says nothing about similarity).
    public static func fingerprint(of url: URL) -> ImageFingerprint? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 128,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return fingerprint(of: image)
    }

    public static func fingerprint(of image: CGImage) -> ImageFingerprint? {
        guard let large = grey(image, width: 32, height: 32), let small = grey(image, width: 9, height: 8) else { return nil }
        let mean = large.reduce(0, +) / Double(large.count)
        let variance = large.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(large.count)
        guard variance > 4 else { return nil }

        // 2D DCT-II of the 32×32 copy, keeping the top-left 8×8 block.
        var coefficients = [Double](repeating: 0, count: 64)
        let table = cosineTable
        for u in 0 ..< 8 {
            for v in 0 ..< 8 {
                var sum = 0.0
                for y in 0 ..< 32 {
                    let row = y * 32
                    let cv = table[v * 32 + y]
                    for x in 0 ..< 32 {
                        sum += large[row + x] * table[u * 32 + x] * cv
                    }
                }
                coefficients[v * 8 + u] = sum
            }
        }
        let ac = Array(coefficients.dropFirst())
        let median = ac.sorted()[ac.count / 2]
        var pHash: UInt64 = 0
        for (index, value) in coefficients.enumerated() where index > 0 && value > median {
            pHash |= 1 << UInt64(index)
        }

        var dHash: UInt64 = 0
        var bit: UInt64 = 0
        for y in 0 ..< 8 {
            for x in 0 ..< 8 {
                if small[y * 9 + x] > small[y * 9 + x + 1] { dHash |= 1 << bit }
                bit += 1
            }
        }
        return ImageFingerprint(pHash: pHash, dHash: dHash, colors: colorGrid(image))
    }

    private static let cosineTable: [Double] = {
        var table = [Double](repeating: 0, count: 8 * 32)
        for u in 0 ..< 8 {
            for x in 0 ..< 32 {
                table[u * 32 + x] = cos(Double(2 * x + 1) * Double(u) * .pi / 64)
            }
        }
        return table
    }()

    /// The image drawn over white into an 8×8 RGB bitmap: 192 bytes. Also the grid analysis names a colour from.
    public static func colorGrid(_ image: CGImage) -> [UInt8] {
        guard let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 32,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
        else { return [] }
        context.interpolationQuality = .high
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let data = context.data else { return [] }
        let bytes = data.bindMemory(to: UInt8.self, capacity: 256)
        return (0 ..< 64).flatMap { pixel in (0 ..< 3).map { bytes[pixel * 4 + $0] } }
    }

    /// The image drawn over white into an 8-bit greyscale bitmap of the given size.
    private static func grey(_ image: CGImage, width: Int, height: Int) -> [Double]? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)
        return (0 ..< width * height).map { Double(pixels[$0]) }
    }
}
