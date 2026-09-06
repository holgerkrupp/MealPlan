import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
import PDFKit
#elseif os(iOS)
import UIKit
#endif

/// Renders a print document to a multi-page PDF.
///
/// `ImageRenderer` draws one SwiftUI view into one CGContext, so a run of
/// sheets is a run of renderers writing into the same PDF context — the page
/// break is `beginPage` / `endPDFPage`, not a second file.
enum MealPlanPDFRenderer {

    /// Write the whole document into a PDF in the temporary directory.
    ///
    /// - Returns: the file's URL, or `nil` when the context couldn't be
    ///   created (a full disk, essentially) or the document has no pages.
    @MainActor
    static func pdf(
        document: MealPlanPrintDocument,
        geometry: PrintPageGeometry,
        compact: Bool = true,
        filename: String = defaultFilename()
    ) -> URL? {
        let pages = PrintPagination.pages(for: document, geometry: geometry, compact: compact)
        guard !pages.isEmpty else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appending(path: filename)
            .appendingPathExtension(for: .pdf)
        try? FileManager.default.removeItem(at: url)

        var mediaBox = CGRect(origin: .zero, size: geometry.size)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { return nil }

        var rendered = 0
        for page in pages {
            let view = MealPlanPrintPageView(document: document, page: page, geometry: geometry)
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(geometry.size)
            renderer.render { size, draw in
                var box = CGRect(origin: .zero, size: size)
                context.beginPage(mediaBox: &box)
                draw(context)
                context.endPDFPage()
                rendered += 1
            }
        }
        context.closePDF()

        guard rendered > 0 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    /// A filename someone will recognise in their Downloads folder a month
    /// later — the plan's dates, not a timestamp.
    static func filename(for range: DayRange, householdName: String) -> String {
        let days = range.days
        let stamp = [days.first?.dayID, days.count > 1 ? days.last?.dayID : nil]
            .compactMap { $0 }
            .joined(separator: "_")
        let household = householdName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let name = household.isEmpty ? "MealPlan" : household
        return stamp.isEmpty ? name : "\(name)-\(stamp)"
    }

    static func defaultFilename() -> String {
        "MealPlan-\(Date.now.dayID)"
    }
}

/// Hands an already-rendered PDF to the system print panel.
///
/// The PDF carries the paper size the user picked in its media box, so the
/// print panel opens on the right sheet and the pages are placed 1:1 —
/// nothing here re-lays anything out.
enum PlanPrinter {

    @discardableResult
    @MainActor
    static func print(pdf url: URL, jobName: String) -> Bool {
        #if os(iOS)
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo.printInfo()
        info.jobName = jobName
        info.outputType = .general
        controller.printInfo = info
        controller.printingItem = url

        // On iPhone the panel is presented modally; on iPad it is a popover
        // and needs something to point at, so it is anchored to the middle of
        // the key window rather than to a button that may already be gone.
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            let window = scene.keyWindow ?? scene.windows.first
        else { return false }

        if UIDevice.current.userInterfaceIdiom == .pad {
            let anchor = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 1, height: 1)
            controller.present(from: anchor, in: window, animated: true)
        } else {
            controller.present(animated: true)
        }
        return true
        #elseif os(macOS)
        guard let pdf = PDFDocument(url: url) else { return false }
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.jobDisposition = .spool
        // The page is already the right size; scaling it again is how a plan
        // ends up with a hairline of white where a column used to be.
        guard let operation = pdf.printOperation(
            for: info,
            scalingMode: .pageScaleDownToFit,
            autoRotate: true
        ) else { return false }
        operation.jobTitle = jobName
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        return operation.run()
        #else
        return false
        #endif
    }
}

/// Wraps the rendered PDF for `fileExporter`. `ShareLink` alone isn't enough
/// on macOS, where the share menu offers AirDrop and Mail but no "save to
/// folder" — the same reason `BackupDocument` exists.
struct PlanPDFDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }

    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
