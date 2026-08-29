import Foundation
@preconcurrency import Vision
import PDFKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum RecipeTextScanner {
    static func recognize(imageData: Data) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = Array(Locale.preferredLanguages.prefix(3))
            let handler = VNImageRequestHandler(data: imageData)
            try handler.perform([request])
            return (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }

    static func images(fromPDF data: Data) -> [Data] {
        guard let document = PDFDocument(data: data) else { return [] }
        return (0..<document.pageCount).compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            let thumbnail = page.thumbnail(of: CGSize(width: 2200, height: 3000), for: .mediaBox)
            #if canImport(UIKit)
            return thumbnail.jpegData(compressionQuality: 0.92)
            #elseif canImport(AppKit)
            guard let tiff = thumbnail.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
            return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
            #else
            return nil
            #endif
        }
    }
}
