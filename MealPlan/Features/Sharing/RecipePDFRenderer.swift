import CoreGraphics
import SwiftUI

/// Lays a recipe out as a cookbook page and writes it to a PDF.
///
/// The recipe is cut into blocks — the header, a section title, a run of
/// ingredients, one step — and the blocks are poured onto pages in order.
/// Each block is measured by rendering it at the page's width, so the layout
/// that decides the page breaks is exactly the one that gets drawn.
enum RecipePDFRenderer {

    enum Block: Equatable {
        case header
        case sectionTitle(String, detail: String?)
        case ingredients([RecipeShareContent.IngredientLine], columns: Int)
        case step(RecipeShareContent.Step, continuation: Bool)
        case note(String)
        case source

        /// A title or a sub-heading at the foot of a page, with what it
        /// introduces on the next, is the one break every cookbook avoids.
        var keepsWithNext: Bool {
            switch self {
            case .sectionTitle: true
            case .step(let step, _): step.isHeading
            default: false
            }
        }
    }

    /// The paper the user prints on — whatever the print sheet last used —
    /// always portrait: a recipe is a page you read top to bottom.
    @MainActor
    static var defaultGeometry: PrintPageGeometry {
        PrintPageGeometry(paper: MealPlanPrintSettings.load().paper, orientation: .portrait)
    }

    // MARK: - Blocks

    static func blocks(for content: RecipeShareContent, contentWidth: CGFloat) -> [Block] {
        var blocks: [Block] = [.header]

        if !content.ingredients.isEmpty {
            blocks.append(.sectionTitle(String(localized: "Ingredients"), detail: content.servingsText))
            // Two columns once the list is long enough to be worth it and the
            // sheet wide enough to hold them; A5 stays in one.
            let columns = content.ingredients.count >= 6 && contentWidth >= 420 ? 2 : 1
            blocks.append(.ingredients(content.ingredients, columns: columns))
        }

        if !content.steps.isEmpty {
            blocks.append(.sectionTitle(String(localized: "Method"), detail: nil))
            for step in content.steps {
                let pieces = splitLongText(step.text)
                for (index, piece) in pieces.enumerated() {
                    var part = step
                    part.text = piece
                    blocks.append(.step(part, continuation: index > 0))
                }
            }
        }

        if let nutrition = content.nutritionText {
            blocks.append(.note(nutrition))
        }
        if content.hasWebSource {
            blocks.append(.source)
        }
        return blocks
    }

    /// A step is only ever broken between pages at a block boundary, so a
    /// paragraph longer than a page would be clipped. Anything that long is
    /// cut at sentence ends into pieces of a few hundred characters first.
    static func splitLongText(_ text: String, limit: Int = 700) -> [String] {
        guard text.count > limit else { return [text] }
        let sentences = text
            .replacingOccurrences(of: #"([.!?])\s+"#, with: "$1\u{1F}", options: .regularExpression)
            .components(separatedBy: "\u{1F}")
        var pieces: [String] = []
        var current = ""
        for sentence in sentences {
            if !current.isEmpty, current.count + sentence.count + 1 > limit / 2 + limit / 4 {
                pieces.append(current)
                current = sentence
            } else {
                current = current.isEmpty ? sentence : "\(current) \(sentence)"
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    // MARK: - Pagination

    /// Pours the blocks onto pages of `pageHeight`.
    ///
    /// * a block that doesn't fit what's left of a page starts the next one;
    /// * a block that `keepsWithNext` moves over together with the first line
    ///   of what follows it;
    /// * an ingredient list is the one block that splits — as many rows as
    ///   fit stay, the rest carries on over the page, and each piece is laid
    ///   out down its own columns so reading order survives the break;
    /// * a block taller than a whole page is placed on its own rather than
    ///   looping forever.
    static func paginate(
        _ blocks: [Block],
        pageHeight: CGFloat,
        measure: (Block) -> CGFloat
    ) -> [[Block]] {
        var pages: [[Block]] = [[]]
        var used: CGFloat = 0
        var pending = blocks
        var index = 0

        func startPage() {
            pages.append([])
            used = 0
        }

        while index < pending.count {
            let block = pending[index]
            let remaining = pageHeight - used
            let pageIsEmpty = pages[pages.count - 1].isEmpty
            let height = measure(block)

            if case .ingredients(let items, let columns) = block, height > remaining {
                let rows = rowCount(items.count, columns: columns)
                var fittingRows = 0
                for candidate in stride(from: rows - 1, through: 1, by: -1) {
                    let chunk = Array(items.prefix(candidate * columns))
                    if measure(.ingredients(chunk, columns: columns)) <= remaining {
                        fittingRows = candidate
                        break
                    }
                }
                if fittingRows > 0 {
                    let taken = fittingRows * columns
                    pages[pages.count - 1].append(.ingredients(Array(items.prefix(taken)), columns: columns))
                    pending.insert(.ingredients(Array(items.dropFirst(taken)), columns: columns), at: index + 1)
                    startPage()
                    index += 1
                    continue
                }
                if !pageIsEmpty {
                    startPage()
                    continue
                }
            }

            var needed = height
            if block.keepsWithNext, index + 1 < pending.count {
                needed += measure(firstPiece(of: pending[index + 1]))
            }
            if needed > remaining, !pageIsEmpty {
                startPage()
                continue
            }
            pages[pages.count - 1].append(block)
            used += height
            index += 1
        }
        return pages.filter { !$0.isEmpty }
    }

    static func rowCount(_ count: Int, columns: Int) -> Int {
        (count + max(1, columns) - 1) / max(1, columns)
    }

    /// The smallest part of a block that can stand at the top of a page.
    private static func firstPiece(of block: Block) -> Block {
        if case .ingredients(let items, let columns) = block {
            return .ingredients(Array(items.prefix(columns)), columns: columns)
        }
        return block
    }

    // MARK: - Rendering

    @MainActor
    static func pdf(
        content: RecipeShareContent,
        geometry: PrintPageGeometry
    ) throws -> URL {
        let style = RecipePageStyle(geometry: geometry)
        let width = geometry.contentSize.width
        let pageHeight = geometry.contentSize.height - style.footerHeight

        let pages = paginate(blocks(for: content, contentWidth: width), pageHeight: pageHeight) { block in
            measuredHeight(of: RecipePDFBlockView(block: block, content: content, style: style), width: width)
        }

        let url = try ShareFileName.stagingURL(
            for: content.title,
            fallback: String(localized: "Recipe"),
            pathExtension: "pdf"
        )
        var mediaBox = CGRect(origin: .zero, size: geometry.size)
        let info: [CFString: Any] = [
            kCGPDFContextTitle: content.title,
            kCGPDFContextCreator: "MealPlan",
        ]
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for (number, blocks) in pages.enumerated() {
            let page = RecipePDFPageView(
                content: content,
                blocks: blocks,
                pageNumber: number + 1,
                pageCount: pages.count,
                geometry: geometry,
                style: style
            )
            let renderer = ImageRenderer(content: page)
            renderer.proposedSize = ProposedViewSize(geometry.size)
            renderer.render { size, draw in
                var box = CGRect(origin: .zero, size: size)
                context.beginPage(mediaBox: &box)
                draw(context)
                context.endPDFPage()
            }
        }
        context.closePDF()
        return url
    }

    @MainActor
    private static func measuredHeight(of view: some View, width: CGFloat) -> CGFloat {
        let renderer = ImageRenderer(content: view.frame(width: width).environment(\.colorScheme, .light))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        var height: CGFloat = 0
        renderer.render { size, _ in height = size.height }
        return height
    }
}

// MARK: - Page views

/// Type sizes and colours for the recipe page, scaled down a notch on A5.
struct RecipePageStyle {
    var scale: CGFloat
    var footerHeight: CGFloat { 26 }
    /// The launch screen's red, so a printed recipe looks like MealPlan's.
    static let accent = Color(.displayP3, red: 0.865, green: 0.325, blue: 0.322)

    init(geometry: PrintPageGeometry) {
        scale = geometry.paper == .a5 ? 0.86 : 1
    }

    func font(_ size: CGFloat, _ weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size * scale, weight: weight, design: design)
    }
}

@MainActor
struct RecipePDFPageView: View {
    let content: RecipeShareContent
    let blocks: [RecipePDFRenderer.Block]
    let pageNumber: Int
    let pageCount: Int
    let geometry: PrintPageGeometry
    let style: RecipePageStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    RecipePDFBlockView(block: block, content: content, style: style)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            footer
        }
        .padding(geometry.margin)
        .frame(width: geometry.size.width, height: geometry.size.height)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Rectangle().fill(Color.black.opacity(0.12)).frame(height: 0.5)
            HStack {
                Text("MealPlan")
                    .foregroundStyle(RecipePageStyle.accent)
                Spacer()
                Text(pageCount > 1
                     ? String(localized: "\(content.title) · \(pageNumber) of \(pageCount)")
                     : content.title)
                    .lineLimit(1)
            }
            .font(style.font(8, .medium))
            .foregroundStyle(Color.black.opacity(0.45))
        }
        .frame(height: style.footerHeight, alignment: .bottom)
    }
}

@MainActor
struct RecipePDFBlockView: View {
    let block: RecipePDFRenderer.Block
    let content: RecipeShareContent
    let style: RecipePageStyle

    private let ink = Color.black.opacity(0.86)
    private let muted = Color.black.opacity(0.52)

    var body: some View {
        Group {
            switch block {
            case .header:
                header
            case .sectionTitle(let title, let detail):
                sectionTitle(title, detail: detail)
            case .ingredients(let items, let columns):
                ingredients(items, columns: columns)
            case .step(let step, let continuation):
                stepView(step, continuation: continuation)
            case .note(let text):
                Label(text, systemImage: "flame")
                    .font(style.font(9))
                    .foregroundStyle(muted)
                    .padding(.top, 16 * style.scale)
            case .source:
                source
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10 * style.scale) {
            if let data = content.imageData, let image = Image(data: data) {
                Color.clear
                    .frame(height: 210 * style.scale)
                    .overlay {
                        image
                            .resizable()
                            .scaledToFill()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.bottom, 6 * style.scale)
            }

            Text(content.title)
                .font(style.font(26, .bold, design: .serif))
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)

            if let host = content.sourceHost, content.hasWebSource {
                Text(String(localized: "from \(host)"))
                    .font(style.font(10, .medium))
                    .foregroundStyle(muted)
            }

            HStack(spacing: 18 * style.scale) {
                metric(String(localized: "Serves"), "\(content.servings)")
                ForEach(content.metrics, id: \.label) { metric($0.label, $0.value) }
            }
            .padding(.top, 2)

            if !content.tags.isEmpty {
                Text(content.tags.joined(separator: "  ·  "))
                    .font(style.font(9))
                    .foregroundStyle(muted)
            }

            Rectangle()
                .fill(RecipePageStyle.accent)
                .frame(width: 44, height: 2)
                .padding(.top, 4 * style.scale)
        }
        .padding(.bottom, 4 * style.scale)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(style.font(7.5, .semibold))
                .tracking(0.8)
                .foregroundStyle(muted)
            Text(value)
                .font(style.font(11, .semibold))
                .foregroundStyle(ink)
        }
    }

    // MARK: Sections

    private func sectionTitle(_ title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title.uppercased())
                .font(style.font(10, .bold))
                .tracking(1.2)
                .foregroundStyle(RecipePageStyle.accent)
            if let detail {
                Text(detail)
                    .font(style.font(9))
                    .foregroundStyle(muted)
            }
        }
        .padding(.top, 18 * style.scale)
        .padding(.bottom, 8 * style.scale)
    }

    /// Laid out down each column in turn, so the list reads in the recipe's
    /// own order.
    private func ingredients(_ items: [RecipeShareContent.IngredientLine], columns: Int) -> some View {
        let rows = RecipePDFRenderer.rowCount(items.count, columns: columns)
        let chunks = stride(from: 0, to: items.count, by: max(1, rows)).map {
            Array(items[$0..<min($0 + rows, items.count)])
        }
        return HStack(alignment: .top, spacing: 22 * style.scale) {
            ForEach(Array(chunks.enumerated()), id: \.offset) { _, column in
                VStack(alignment: .leading, spacing: 5 * style.scale) {
                    ForEach(Array(column.enumerated()), id: \.offset) { _, line in
                        ingredientRow(line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func ingredientRow(_ line: RecipeShareContent.IngredientLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // A space, not "", so a line without an amount keeps a baseline
            // to line up on instead of sitting a few points low.
            Text(line.amount ?? " ")
                .font(style.font(10.5, .semibold).monospacedDigit())
                .foregroundStyle(ink)
                .frame(width: 58 * style.scale, alignment: .trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text(ingredientText(line))
                .font(style.font(10.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The name in ink, a note after it in grey, wrapping as one run of text.
    private func ingredientText(_ line: RecipeShareContent.IngredientLine) -> AttributedString {
        var text = AttributedString(line.name)
        text.foregroundColor = ink
        if let note = line.note {
            var tail = AttributedString(", \(note)")
            tail.foregroundColor = muted
            text += tail
        }
        return text
    }

    @ViewBuilder
    private func stepView(_ step: RecipeShareContent.Step, continuation: Bool) -> some View {
        if step.isHeading {
            Text(step.text)
                .font(style.font(11, .semibold, design: .serif))
                .italic()
                .foregroundStyle(ink)
                .padding(.top, 8 * style.scale)
                .padding(.bottom, 6 * style.scale)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(continuation ? " " : step.number.map { "\($0)" } ?? " ")
                    .font(style.font(12, .bold, design: .serif))
                    .foregroundStyle(RecipePageStyle.accent)
                    .frame(width: 18 * style.scale, alignment: .trailing)
                Text(step.text)
                    .font(style.font(10.5))
                    .lineSpacing(2.5 * style.scale)
                    .foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 9 * style.scale)
        }
    }

    private var source: some View {
        let qrCode = sourceQRCode
        return HStack(alignment: .center, spacing: 16 * style.scale) {
            VStack(alignment: .leading, spacing: 2) {
                if let host = content.sourceHost {
                    Text(String(localized: "Original recipe: \(host)"))
                        .font(style.font(9, .semibold))
                        .foregroundStyle(ink)
                }
                if let url = content.sourceURL, !content.sourceIsGone {
                    Text(url.absoluteString)
                        .font(style.font(8))
                        .foregroundStyle(muted)
                        .lineLimit(2)
                }
                if qrCode != nil {
                    Text("Scan the code to open the original recipe.")
                        .font(style.font(8))
                        .foregroundStyle(muted)
                        .padding(.top, 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let qrCode {
                // About 25 mm across: small enough to sit beside the credit,
                // large enough for a phone held over a kitchen counter.
                QRCodeShape(matrix: qrCode)
                    .fill(Color.black)
                    .frame(width: 72 * style.scale, height: 72 * style.scale)
            }
        }
        .padding(.top, 18 * style.scale)
    }

    /// Only for a page that is still there — a code that leads to a 404 is
    /// worse on paper than no code, because nobody can see where it goes.
    private var sourceQRCode: QRCodeMatrix? {
        guard content.hasWebSource, !content.sourceIsGone, let url = content.sourceURL else { return nil }
        return QRCodeMatrix(string: url.absoluteString)
    }
}
