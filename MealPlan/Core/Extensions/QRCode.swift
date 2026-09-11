import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A QR code as its grid of modules.
///
/// CoreImage hands back a bitmap one pixel per module. Scaled up, that is fine
/// on screen but prints soft, and in a PDF it is a picture of a code rather than
/// a code. Read back into a grid, the same thing draws as `QRCodeShape` — a
/// path of squares that stays sharp at any size.
struct QRCodeMatrix: Equatable, Sendable {
    /// Modules per side, including whatever quiet zone CoreImage leaves.
    let size: Int
    /// Row-major, top row first; `true` is a dark module.
    let modules: [Bool]

    subscript(x: Int, y: Int) -> Bool { modules[y * size + x] }

    /// - Parameter correction: "L", "M", "Q" or "H". "M" survives a smudge on
    ///   a printed page without making the code needlessly dense.
    init?(string: String, correction: String = "M") {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = correction
        guard let output = filter.outputImage else { return nil }
        let extent = output.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, width == height,
              let image = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: extent)
        else { return nil }

        // A bitmap context keeps its rows top first, so reading the buffer in
        // order gives the code the right way up — a mirrored QR code won't scan.
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        size = width
        modules = pixels.map { $0 < 128 }
    }
}

/// Draws a `QRCodeMatrix` into the largest square that fits its frame.
/// Fill it black on a light background; the caller owns the quiet zone.
struct QRCodeShape: Shape {
    let matrix: QRCodeMatrix

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let module = side / CGFloat(max(1, matrix.size))
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        // Neighbouring squares overlap by a hair so anti-aliasing can't leave
        // pale seams between them; the fill is a union, so nothing darkens.
        let bleed = module * 0.02
        var path = Path()
        for y in 0..<matrix.size {
            var x = 0
            while x < matrix.size {
                guard matrix[x, y] else {
                    x += 1
                    continue
                }
                let start = x
                while x < matrix.size, matrix[x, y] { x += 1 }
                path.addRect(CGRect(
                    x: origin.x + CGFloat(start) * module,
                    y: origin.y + CGFloat(y) * module,
                    width: CGFloat(x - start) * module + bleed,
                    height: module + bleed
                ))
            }
        }
        return path
    }
}
