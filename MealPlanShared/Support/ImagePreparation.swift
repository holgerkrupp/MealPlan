import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Shrinks photos before they're stored so sync payloads stay small.
/// Pure ImageIO, so it works in the app, the Share Extension and tests.
enum ImagePreparation {
    static func prepared(from data: Data, maxDimension: CGFloat = 1400, quality: CGFloat = 0.8) -> Data {
        preparedImage(from: data, maxDimension: maxDimension, quality: quality) ?? data
    }

    /// For bytes from outside the app: `nil` unless they really are a picture,
    /// so a file or web page can't put anything else where a photo is stored.
    static func preparedImage(from data: Data, maxDimension: CGFloat = 1400, quality: CGFloat = 0.8) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Download and downscale an image URL. Returns nil on any failure.
    static func download(_ url: URL) async -> Data? {
        guard let (data, response) = try? await BoundedDownload.data(for: URLRequest(url: url)),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !data.isEmpty else { return nil }
        return preparedImage(from: data)
    }

    /// Whether stored bytes decode as a picture, without re-encoding them.
    static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0 && CGImageSourceGetType(source) != nil
    }
}
