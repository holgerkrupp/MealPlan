import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Shrinks photos before they're stored so sync payloads stay small.
/// Pure ImageIO, so it works in the app, the Share Extension and tests.
enum ImagePreparation {
    static func prepared(from data: Data, maxDimension: CGFloat = 1400, quality: CGFloat = 0.8) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return data }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return data
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return data
        }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return data }
        return out as Data
    }

    /// Download and downscale an image URL. Returns nil on any failure.
    static func download(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              !data.isEmpty else { return nil }
        return prepared(from: data)
    }
}
