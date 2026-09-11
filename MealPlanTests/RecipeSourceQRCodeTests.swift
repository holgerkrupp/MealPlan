import Testing
import Foundation
import CoreGraphics
import CoreImage
@testable import MealPlan

/// The QR code printed under a recipe has to actually scan — so these render
/// the real PDF and read the code back off the page.
@MainActor
@Suite(.serialized)
struct RecipeSourceQRCodeTests {

    private let recipeURL = URL(string: "https://www.chefkoch.de/rezepte/123456/omas-apfelpfannkuchen.html")!

    private func content(sourceIsGone: Bool = false) -> RecipeShareContent {
        RecipeShareContent(
            title: "Pancakes",
            servingsText: "2 servings",
            metrics: [],
            tags: [],
            ingredients: [.init(amount: "250 g", name: "flour"), .init(amount: "3", name: "eggs")],
            steps: RecipeShareContent.steps(from: "Whisk everything.\nFry in butter."),
            nutritionText: nil,
            sourceURL: recipeURL,
            sourceIsGone: sourceIsGone
        )
    }

    // MARK: - The grid

    /// The 7 × 7 finder square: a dark ring, a light ring, a dark 3 × 3 core.
    private func hasFinder(_ matrix: QRCodeMatrix, atX left: Int, y top: Int) -> Bool {
        for dy in 0..<7 {
            for dx in 0..<7 {
                let ring = min(dx, dy, 6 - dx, 6 - dy)
                let shouldBeDark = ring != 1
                if matrix[left + dx, top + dy] != shouldBeDark { return false }
            }
        }
        return true
    }

    @Test func theGridIsTheRightWayUp() throws {
        let matrix = try #require(QRCodeMatrix(string: recipeURL.absoluteString))
        #expect(matrix.modules.count == matrix.size * matrix.size)

        // Find the code inside whatever quiet zone CoreImage leaves.
        let dark = matrix.modules.indices.filter { matrix.modules[$0] }
        let xs = dark.map { $0 % matrix.size }
        let ys = dark.map { $0 / matrix.size }
        let (minX, maxX, minY, maxY) = (xs.min()!, xs.max()!, ys.min()!, ys.max()!)
        #expect(maxX - minX == maxY - minY)
        #expect(maxX - minX + 1 >= 21)

        // Finder squares top-left, top-right and bottom-left. Upside down or
        // mirrored, one of them would be in the bottom-right instead.
        #expect(hasFinder(matrix, atX: minX, y: minY))
        #expect(hasFinder(matrix, atX: maxX - 6, y: minY))
        #expect(hasFinder(matrix, atX: minX, y: maxY - 6))
        #expect(!hasFinder(matrix, atX: maxX - 6, y: maxY - 6))
    }

    // MARK: - On the page

    /// Renders the PDF and reads every QR code off its last page.
    private func codesOnLastPage(of content: RecipeShareContent) throws -> [String] {
        let url = try RecipePDFRenderer.pdf(
            content: content,
            geometry: PrintPageGeometry(paper: .a4, orientation: .portrait)
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try #require(CGPDFDocument(url as CFURL))
        let page = try #require(document.page(at: document.numberOfPages))
        let box = page.getBoxRect(.mediaBox)

        // Three pixels a point: about what a phone camera sees of the sheet.
        let scale: CGFloat = 3
        let context = try #require(CGContext(
            data: nil,
            width: Int(box.width * scale),
            height: Int(box.height * scale),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: box.width * scale, height: box.height * scale))
        context.scaleBy(x: scale, y: scale)
        context.drawPDFPage(page)
        let raster = try #require(context.makeImage())

        let detector = try #require(CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ))
        return detector.features(in: CIImage(cgImage: raster))
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    @Test func thePrintedCodeScansBackToTheRecipe() throws {
        #expect(try codesOnLastPage(of: content()) == [recipeURL.absoluteString])
    }

    @Test func aPageThatIsGoneGetsNoCode() throws {
        #expect(try codesOnLastPage(of: content(sourceIsGone: true)).isEmpty)
    }
}
