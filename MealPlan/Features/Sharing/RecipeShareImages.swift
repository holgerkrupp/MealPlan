import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Recipe pictures for Instagram, Mastodon, Pixelfed and the like: the dish's
/// photo behind the recipe, in the same three sizes as the meal share images.
///
/// Either one picture each for the ingredients, the method and the nutrition —
/// a carousel — or the whole recipe on one. Like the PDF, what goes on which
/// picture is decided by measuring the rendered rows, so nothing is cut off;
/// a list that doesn't fit is first set a little smaller, then carried on to
/// a second picture ("Method 2/2").

enum RecipeImageLayout: String, CaseIterable, Identifiable {
    case separate
    case combined

    var id: Self { self }

    var title: String {
        switch self {
        case .separate: String(localized: "Separate images")
        case .combined: String(localized: "All in one")
        }
    }
}

/// One picture: which part of the recipe it carries, and exactly which lines.
struct RecipeImagePage: Identifiable, Equatable {
    enum Kind: String, Sendable {
        case ingredients
        case directions
        case nutrition
        case combined
    }

    var kind: Kind
    /// Position among the pictures of the same kind, for "Method 2/3".
    var index = 0
    var count = 1
    /// How far the type was shrunk to make the lines fit, 1 = not at all.
    var fit: CGFloat = 1
    /// The column count the widths were measured for, even if the last
    /// picture of a run doesn't fill them all.
    var columns = 1
    var ingredientColumns: [[RecipeShareContent.IngredientLine]] = []
    /// Each column is a list of step groups — a heading travels with the
    /// step after it.
    var stepColumns: [[[RecipeShareContent.Step]]] = []
    /// All-in-one only: what didn't fit even at the smallest size.
    var hiddenIngredients = 0
    var hiddenSteps = 0

    var id: String { "\(kind.rawValue)-\(index)" }

    var title: String {
        let base = switch kind {
        case .ingredients: String(localized: "Ingredients")
        case .directions: String(localized: "Method")
        case .nutrition: String(localized: "Nutrition")
        case .combined: String(localized: "Recipe")
        }
        return count > 1 ? "\(base) \(index + 1)/\(count)" : base
    }
}

/// Sizes in pixels of the finished picture, shared by the planner (which
/// measures) and the card (which draws), so the two can't drift apart.
struct RecipeImageMetrics: Equatable {
    let aspect: MealShareAspect

    var size: CGSize { aspect.renderSize }

    /// Landscape and square have less height, so everything is set a notch
    /// smaller there, as in the meal share images.
    var scale: CGFloat {
        switch aspect {
        case .portrait: 1
        case .square: 0.92
        case .landscape: 0.84
        }
    }

    var padding: CGFloat { 64 }
    var panelPadding: CGFloat { 34 * scale }
    var columnGap: CGFloat { 40 * scale }
    var sectionSpacing: CGFloat { 30 * scale }

    func bodyFont(combined: Bool) -> CGFloat { (combined ? 23 : 30) * scale }
    func rowSpacing(_ fit: CGFloat) -> CGFloat { 14 * scale * fit }
    func stepSpacing(_ fit: CGFloat) -> CGFloat { 22 * scale * fit }

    // MARK: Separate pictures

    var panelContentWidth: CGFloat { size.width - 2 * padding - 2 * panelPadding }

    func ingredientColumns(count: Int) -> Int {
        guard count > 1 else { return 1 }
        return aspect == .landscape || count > 9 ? 2 : 1
    }

    var stepColumns: Int { aspect == .landscape ? 2 : 1 }

    func columnWidth(total: CGFloat, columns: Int) -> CGFloat {
        let columns = max(1, columns)
        return (total - CGFloat(columns - 1) * columnGap) / CGFloat(columns)
    }

    // MARK: All in one

    /// The photo across the top in portrait and square…
    var combinedPhotoBand: CGFloat {
        switch aspect {
        case .portrait: size.height * 0.36
        case .square: size.height * 0.30
        case .landscape: 0
        }
    }

    /// …and down the left-hand side in landscape.
    var combinedPhotoWidth: CGFloat { aspect == .landscape ? size.width * 0.38 : 0 }

    var combinedTextWidth: CGFloat { size.width - combinedPhotoWidth - 2 * padding }

    /// Ingredients take the narrower column; either takes the full width when
    /// the other has nothing in it.
    func combinedWidths(hasIngredients: Bool, hasSteps: Bool) -> (ingredients: CGFloat, steps: CGFloat) {
        let total = combinedTextWidth
        switch (hasIngredients, hasSteps) {
        case (true, true):
            let ingredients = ((total - columnGap) * 0.4).rounded()
            return (ingredients, total - columnGap - ingredients)
        case (true, false): return (total, 0)
        default: return (0, total)
        }
    }
}

// MARK: - Planning

enum RecipeImagePlanner {

    /// What the planner needs measured. The app renders the real views; the
    /// tests hand in fixed numbers.
    enum Measure: Equatable {
        case ingredient(RecipeShareContent.IngredientLine, width: CGFloat, fit: CGFloat, combined: Bool)
        case steps([RecipeShareContent.Step], width: CGFloat, fit: CGFloat, combined: Bool)
        /// A picture of this kind with every list left empty, at its natural
        /// height — everything the lines have to share the picture with.
        case chrome(RecipeImagePage.Kind)
    }

    static let fits: [CGFloat] = [1, 0.9, 0.8]
    static let combinedFits: [CGFloat] = [1, 0.9, 0.8, 0.7]

    static func plan(
        content: RecipeShareContent,
        layout: RecipeImageLayout,
        metrics: RecipeImageMetrics,
        measure: (Measure) -> CGFloat
    ) -> [RecipeImagePage] {
        switch layout {
        case .separate: separatePages(content: content, metrics: metrics, measure: measure)
        case .combined: [combinedPage(content: content, metrics: metrics, measure: measure)]
        }
    }

    // MARK: Separate

    private static func separatePages(
        content: RecipeShareContent,
        metrics: RecipeImageMetrics,
        measure: (Measure) -> CGFloat
    ) -> [RecipeImagePage] {
        var pages: [RecipeImagePage] = []

        let ingredients = content.ingredients
        if !ingredients.isEmpty {
            let columns = metrics.ingredientColumns(count: ingredients.count)
            let width = metrics.columnWidth(total: metrics.panelContentWidth, columns: columns)
            let capacity = metrics.size.height - measure(.chrome(.ingredients))
            let (fit, chunks) = bestFit(columns: columns, capacity: capacity, spacing: metrics.rowSpacing) { fit in
                ingredients.map { measure(.ingredient($0, width: width, fit: fit, combined: false)) }
            }
            pages += grouped(chunks, by: columns).map { columnChunks in
                RecipeImagePage(
                    kind: .ingredients,
                    fit: fit,
                    columns: columns,
                    ingredientColumns: columnChunks.map { $0.map { ingredients[$0] } }
                )
            }
        }

        let groups = stepGroups(content.steps)
        if !groups.isEmpty {
            let columns = groups.count > 1 ? metrics.stepColumns : 1
            let width = metrics.columnWidth(total: metrics.panelContentWidth, columns: columns)
            let capacity = metrics.size.height - measure(.chrome(.directions))
            let (fit, chunks) = bestFit(columns: columns, capacity: capacity, spacing: metrics.stepSpacing) { fit in
                groups.map { measure(.steps($0, width: width, fit: fit, combined: false)) }
            }
            pages += grouped(chunks, by: columns).map { columnChunks in
                RecipeImagePage(
                    kind: .directions,
                    fit: fit,
                    columns: columns,
                    stepColumns: columnChunks.map { $0.map { groups[$0] } }
                )
            }
        }

        if content.nutrition != nil {
            pages.append(RecipeImagePage(kind: .nutrition))
        }

        // Number each run: "Method 1/2", "Method 2/2".
        for kind in [RecipeImagePage.Kind.ingredients, .directions] {
            let positions = pages.indices.filter { pages[$0].kind == kind }
            for (index, position) in positions.enumerated() {
                pages[position].index = index
                pages[position].count = positions.count
            }
        }
        return pages
    }

    /// The largest type at which the whole list fits one picture. When even
    /// the smallest won't, the list runs on over several pictures at the
    /// middle size instead — a carousel reads better than a squint.
    private static func bestFit(
        columns: Int,
        capacity: CGFloat,
        spacing: (CGFloat) -> CGFloat,
        heights: (CGFloat) -> [CGFloat]
    ) -> (CGFloat, [[Int]]) {
        let capacity = max(capacity, 120)
        for fit in fits {
            let measured = heights(fit)
            let chunks = pack(measured, spacing: spacing(fit), capacity: capacity)
            // Everything fits in fewer columns than there are: share it out
            // evenly rather than leave half the picture empty.
            if chunks.count < columns { return (fit, balance(measured, spacing: spacing(fit), columns: columns)) }
            if chunks.count == columns { return (fit, chunks) }
        }
        let fit = fits[1]
        return (fit, pack(heights(fit), spacing: spacing(fit), capacity: capacity))
    }

    // MARK: All in one

    private static func combinedPage(
        content: RecipeShareContent,
        metrics: RecipeImageMetrics,
        measure: (Measure) -> CGFloat
    ) -> RecipeImagePage {
        let ingredients = content.ingredients
        let groups = stepGroups(content.steps)
        let widths = metrics.combinedWidths(hasIngredients: !ingredients.isEmpty, hasSteps: !groups.isEmpty)
        let capacity = max(metrics.size.height - measure(.chrome(.combined)), 120)

        func heights(_ fit: CGFloat) -> (ingredients: [CGFloat], steps: [CGFloat]) {
            (
                ingredients.map { measure(.ingredient($0, width: widths.ingredients, fit: fit, combined: true)) },
                groups.map { measure(.steps($0, width: widths.steps, fit: fit, combined: true)) }
            )
        }

        for fit in combinedFits {
            let measured = heights(fit)
            if total(measured.ingredients, spacing: metrics.rowSpacing(fit)) <= capacity,
               total(measured.steps, spacing: metrics.stepSpacing(fit)) <= capacity {
                return RecipeImagePage(
                    kind: .combined,
                    fit: fit,
                    ingredientColumns: [ingredients],
                    stepColumns: [groups]
                )
            }
        }

        // Still too much: as many lines as fit, and a "+ 3 more" in place of
        // the rest, room for which is kept back before counting.
        let fit = combinedFits[combinedFits.count - 1]
        let measured = heights(fit)
        let moreLine = RecipeShareContent.IngredientLine(amount: nil, name: "+ 99")

        func visibleCount(_ heights: [CGFloat], spacing: CGFloat, width: CGFloat) -> Int {
            let all = fitCount(heights, spacing: spacing, capacity: capacity)
            guard all < heights.count else { return all }
            let reserve = measure(.ingredient(moreLine, width: width, fit: fit, combined: true)) + spacing
            return fitCount(heights, spacing: spacing, capacity: capacity - reserve)
        }

        let shownIngredients = visibleCount(measured.ingredients, spacing: metrics.rowSpacing(fit), width: widths.ingredients)
        let shownGroups = visibleCount(measured.steps, spacing: metrics.stepSpacing(fit), width: widths.steps)
        let hiddenSteps = groups.dropFirst(shownGroups).joined().filter { !$0.isHeading }.count

        return RecipeImagePage(
            kind: .combined,
            fit: fit,
            ingredientColumns: [Array(ingredients.prefix(shownIngredients))],
            stepColumns: [Array(groups.prefix(shownGroups))],
            hiddenIngredients: ingredients.count - shownIngredients,
            hiddenSteps: hiddenSteps
        )
    }

    // MARK: Pure helpers

    /// A heading ("For the sauce") never ends a column: it is kept together
    /// with the step that follows it.
    static func stepGroups(_ steps: [RecipeShareContent.Step]) -> [[RecipeShareContent.Step]] {
        var groups: [[RecipeShareContent.Step]] = []
        var pendingHeadings: [RecipeShareContent.Step] = []
        for step in steps {
            if step.isHeading {
                pendingHeadings.append(step)
            } else {
                groups.append(pendingHeadings + [step])
                pendingHeadings = []
            }
        }
        if !pendingHeadings.isEmpty { groups.append(pendingHeadings) }
        return groups
    }

    /// Fills columns of `capacity` in order. An item taller than a whole
    /// column gets one to itself rather than being dropped.
    static func pack(_ heights: [CGFloat], spacing: CGFloat, capacity: CGFloat) -> [[Int]] {
        var chunks: [[Int]] = []
        var current: [Int] = []
        var used: CGFloat = 0
        for (index, height) in heights.enumerated() {
            let needed = current.isEmpty ? height : used + spacing + height
            if needed > capacity, !current.isEmpty {
                chunks.append(current)
                current = [index]
                used = height
            } else {
                current.append(index)
                used = needed
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Splits a list that fits one column into `columns` of about the same
    /// height, in order. An item moves to the next column once more than half
    /// of it would stand past the even share.
    static func balance(_ heights: [CGFloat], spacing: CGFloat, columns: Int) -> [[Int]] {
        guard columns > 1, heights.count > 1 else { return heights.isEmpty ? [] : [Array(heights.indices)] }
        let target = total(heights, spacing: spacing) / CGFloat(columns)
        var chunks: [[Int]] = [[]]
        var used: CGFloat = 0
        for (index, height) in heights.enumerated() {
            if !chunks[chunks.count - 1].isEmpty,
               chunks.count < columns,
               used + spacing + height / 2 > target {
                chunks.append([])
                used = 0
            }
            used += (chunks[chunks.count - 1].isEmpty ? 0 : spacing) + height
            chunks[chunks.count - 1].append(index)
        }
        return chunks
    }

    static func total(_ heights: [CGFloat], spacing: CGFloat) -> CGFloat {
        heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1))
    }

    /// How many leading items fit in `capacity`.
    static func fitCount(_ heights: [CGFloat], spacing: CGFloat, capacity: CGFloat) -> Int {
        var used: CGFloat = 0
        for (index, height) in heights.enumerated() {
            used += (index == 0 ? 0 : spacing) + height
            if used > capacity { return index }
        }
        return heights.count
    }

    private static func grouped(_ chunks: [[Int]], by columns: Int) -> [[[Int]]] {
        stride(from: 0, to: chunks.count, by: max(1, columns)).map {
            Array(chunks[$0..<min($0 + max(1, columns), chunks.count)])
        }
    }
}

// MARK: - Rendering

enum RecipeImageRenderer {

    /// The real views, measured at their natural height.
    @MainActor
    static func measure(
        content: RecipeShareContent,
        metrics: RecipeImageMetrics,
        glyph: DishGlyph?
    ) -> (RecipeImagePlanner.Measure) -> CGFloat {
        { request in
            switch request {
            case .ingredient(let line, let width, let fit, let combined):
                height(
                    of: RecipeImageCard.ingredientRow(line, width: width, fontSize: metrics.bodyFont(combined: combined) * fit),
                    width: width
                )
            case .steps(let steps, let width, let fit, let combined):
                height(
                    of: RecipeImageCard.stepGroup(steps, width: width, fontSize: metrics.bodyFont(combined: combined) * fit),
                    width: width
                )
            case .chrome(let kind):
                height(
                    of: RecipeImageCard(
                        content: content,
                        page: RecipeImagePage(kind: kind),
                        metrics: metrics,
                        photo: nil,
                        glyph: glyph,
                        measuring: true
                    ),
                    width: metrics.size.width
                )
            }
        }
    }

    @MainActor
    static func render(
        _ page: RecipeImagePage,
        content: RecipeShareContent,
        metrics: RecipeImageMetrics,
        photo: Image?,
        glyph: DishGlyph?
    ) -> CGImage? {
        let renderer = ImageRenderer(
            content: RecipeImageCard(content: content, page: page, metrics: metrics, photo: photo, glyph: glyph)
        )
        renderer.proposedSize = ProposedViewSize(metrics.size)
        renderer.scale = 1
        return renderer.cgImage
    }

    /// JPEG rather than PNG: it is a photo, and every one of these services
    /// recompresses a 3 MB PNG anyway.
    static func jpegData(_ image: CGImage, quality: CGFloat = 0.9) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    @MainActor
    private static func height(of view: some View, width: CGFloat) -> CGFloat {
        let renderer = ImageRenderer(content: view.frame(width: width))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        renderer.scale = 1
        var height: CGFloat = 0
        renderer.render { size, _ in height = size.height }
        return height
    }
}

// MARK: - The picture

@MainActor
struct RecipeImageCard: View {
    let content: RecipeShareContent
    let page: RecipeImagePage
    let metrics: RecipeImageMetrics
    let photo: Image?
    let glyph: DishGlyph?
    /// Lists empty, no backdrop, natural height: what the planner measures.
    var measuring = false

    private static let ink = Color.white
    private static let muted = Color.white.opacity(0.72)
    /// The launch red, lifted so it reads as text on a dark photo.
    private static let accentText = Color(red: 1, green: 0.62, blue: 0.56)

    private var s: CGFloat { metrics.scale }
    private var size: CGSize { metrics.size }

    var body: some View {
        Group {
            if page.kind == .combined {
                combinedCard
            } else {
                separateCard
            }
        }
        .environment(\.colorScheme, .dark)
    }

    // MARK: Separate

    private var separateCard: some View {
        let layout = VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
            header
            panel {
                switch page.kind {
                case .ingredients: ingredientColumns
                case .directions: stepColumns
                case .nutrition: nutritionPanel
                case .combined: EmptyView()
                }
            }
            // Lists hang from the title; the nutrition figures, which never fill
            // the picture, sit in the middle of it.
            .frame(maxHeight: measuring ? nil : .infinity, alignment: page.kind == .nutrition ? .center : .top)
            footer
        }
        .padding(metrics.padding)
        .frame(width: size.width, alignment: .topLeading)

        return Group {
            if measuring {
                layout
            } else {
                layout
                    .frame(height: size.height, alignment: .top)
                    .background { backdrop(dim: 0.58, blur: 12) }
                    .clipped()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14 * s) {
            HStack(spacing: 14 * s) {
                Text(page.title.uppercased())
                    .font(.system(size: 21 * s, weight: .heavy, design: .rounded))
                    .tracking(1.5)
                    .padding(.horizontal, 16 * s)
                    .padding(.vertical, 8 * s)
                    .background(Capsule().fill(RecipePageStyle.accent))
                Text(headerDetail)
                    .font(.system(size: 22 * s, weight: .semibold, design: .rounded))
                    .foregroundStyle(Self.muted)
                Spacer(minLength: 0)
            }
            Text(content.title)
                .font(.system(size: 64 * s, weight: .bold, design: .serif))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        }
        .foregroundStyle(Self.ink)
    }

    private var headerDetail: String {
        switch page.kind {
        case .ingredients: content.servingsText
        case .nutrition: String(localized: "per serving")
        case .directions, .combined: content.metrics.last.map { "\($0.label) \($0.value)" } ?? ""
        }
    }

    private func panel<Content: View>(@ViewBuilder _ inside: () -> Content) -> some View {
        inside()
            .padding(metrics.panelPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 34 * s, style: .continuous)
                    .fill(Color.black.opacity(0.36))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 34 * s, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1.5)
            )
    }

    private var ingredientColumns: some View {
        let width = metrics.columnWidth(total: metrics.panelContentWidth, columns: page.columns)
        let fontSize = metrics.bodyFont(combined: false) * page.fit
        return HStack(alignment: .top, spacing: metrics.columnGap) {
            ForEach(Array(page.ingredientColumns.enumerated()), id: \.offset) { _, column in
                VStack(alignment: .leading, spacing: metrics.rowSpacing(page.fit)) {
                    ForEach(Array(column.enumerated()), id: \.offset) { _, line in
                        Self.ingredientRow(line, width: width, fontSize: fontSize)
                    }
                }
                .frame(width: width, alignment: .topLeading)
            }
        }
    }

    private var stepColumns: some View {
        let width = metrics.columnWidth(total: metrics.panelContentWidth, columns: page.columns)
        let fontSize = metrics.bodyFont(combined: false) * page.fit
        return HStack(alignment: .top, spacing: metrics.columnGap) {
            ForEach(Array(page.stepColumns.enumerated()), id: \.offset) { _, column in
                VStack(alignment: .leading, spacing: metrics.stepSpacing(page.fit)) {
                    ForEach(Array(column.enumerated()), id: \.offset) { _, group in
                        Self.stepGroup(group, width: width, fontSize: fontSize)
                    }
                }
                .frame(width: width, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private var nutritionPanel: some View {
        if let nutrition = content.nutrition {
            VStack(alignment: .leading, spacing: 30 * s) {
                Text(nutrition.energy)
                    .font(.system(size: 104 * s, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                HStack(spacing: 20 * s) {
                    macroTile(String(localized: "Protein"), nutrition.protein, color: .pink)
                    macroTile(String(localized: "Carbs"), nutrition.carbs, color: .orange)
                    macroTile(String(localized: "Fat"), nutrition.fat, color: .mint)
                }
                Text("An estimate, not a nutrition label.")
                    .font(.system(size: 21 * s, weight: .medium, design: .rounded))
                    .foregroundStyle(Self.muted)
            }
            .foregroundStyle(Self.ink)
        }
    }

    private func macroTile(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12 * s) {
            Circle().fill(color).frame(width: 18 * s, height: 18 * s)
            Text(value)
                .font(.system(size: 42 * s, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 20 * s, weight: .semibold, design: .rounded))
                .foregroundStyle(Self.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24 * s)
        .background(RoundedRectangle(cornerRadius: 26 * s, style: .continuous).fill(Color.white.opacity(0.10)))
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("MealPlan", systemImage: "fork.knife")
                .font(.system(size: 24 * s, weight: .bold, design: .rounded))
            Spacer()
            if let host = content.sourceHost, content.hasWebSource {
                Text(host)
                    .font(.system(size: 20 * s, weight: .medium, design: .rounded))
                    .foregroundStyle(Self.muted)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(Self.ink)
    }

    // MARK: All in one

    @ViewBuilder
    private var combinedCard: some View {
        if metrics.aspect == .landscape {
            HStack(spacing: 0) {
                if !measuring {
                    photoWithTitle
                        .frame(width: metrics.combinedPhotoWidth, height: size.height)
                        .clipped()
                }
                combinedText
                    .frame(width: size.width - metrics.combinedPhotoWidth, alignment: .topLeading)
                    .frame(maxHeight: measuring ? nil : .infinity, alignment: .top)
            }
            .frame(width: size.width, height: measuring ? nil : size.height, alignment: .topLeading)
            .background { if !measuring { backdrop(dim: 0.8, blur: 30) } }
            .clipped()
        } else {
            VStack(spacing: 0) {
                photoWithTitle
                    .frame(width: size.width, height: metrics.combinedPhotoBand)
                    .clipped()
                combinedText
                    .frame(maxHeight: measuring ? nil : .infinity, alignment: .top)
            }
            .frame(width: size.width, height: measuring ? nil : size.height, alignment: .top)
            .background { if !measuring { backdrop(dim: 0.8, blur: 30) } }
            .clipped()
        }
    }

    /// The sharp photo, with the name over its lower edge.
    private var photoWithTitle: some View {
        ZStack(alignment: .bottomLeading) {
            if measuring {
                Color.clear
            } else {
                photoOrFallback(blur: 0)
                LinearGradient(
                    colors: [.clear, .black.opacity(0.25), .black.opacity(0.78)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            VStack(alignment: .leading, spacing: 10 * s) {
                Text(([content.servingsText] + content.metrics.suffix(1).map { "\($0.label) \($0.value)" })
                    .joined(separator: " · "))
                    .font(.system(size: 22 * s, weight: .semibold, design: .rounded))
                    .foregroundStyle(Self.muted)
                Text(content.title)
                    .font(.system(size: 56 * s, weight: .bold, design: .serif))
                    .lineLimit(metrics.aspect == .landscape ? 4 : 2)
                    .minimumScaleFactor(0.7)
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
            }
            .foregroundStyle(Self.ink)
            .padding(.horizontal, metrics.padding * 0.8)
            .padding(.bottom, 26 * s)
        }
    }

    private var combinedText: some View {
        let widths = metrics.combinedWidths(
            hasIngredients: !content.ingredients.isEmpty,
            hasSteps: !content.steps.isEmpty
        )
        let fontSize = metrics.bodyFont(combined: true) * page.fit
        return VStack(alignment: .leading, spacing: 24 * s) {
            HStack(alignment: .top, spacing: metrics.columnGap) {
                if !content.ingredients.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        columnTitle(String(localized: "Ingredients"))
                        VStack(alignment: .leading, spacing: metrics.rowSpacing(page.fit)) {
                            ForEach(Array(page.ingredientColumns.joined().enumerated()), id: \.offset) { _, line in
                                Self.ingredientRow(line, width: widths.ingredients, fontSize: fontSize)
                            }
                            if page.hiddenIngredients > 0 {
                                moreLine(String(localized: "+ \(page.hiddenIngredients) more"), fontSize: fontSize)
                            }
                        }
                    }
                    .frame(width: widths.ingredients, alignment: .topLeading)
                }
                if !content.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        columnTitle(String(localized: "Method"))
                        VStack(alignment: .leading, spacing: metrics.stepSpacing(page.fit)) {
                            ForEach(Array(page.stepColumns.joined().enumerated()), id: \.offset) { _, group in
                                Self.stepGroup(group, width: widths.steps, fontSize: fontSize)
                            }
                            if page.hiddenSteps > 0 {
                                moreLine(String(localized: "+ \(page.hiddenSteps) more steps"), fontSize: fontSize)
                            }
                        }
                    }
                    .frame(width: widths.steps, alignment: .topLeading)
                }
            }
            .frame(maxHeight: measuring ? nil : .infinity, alignment: .top)

            if let nutrition = content.nutritionText {
                Label(nutrition, systemImage: "flame.fill")
                    .font(.system(size: 20 * s, weight: .semibold, design: .rounded))
                    .foregroundStyle(Self.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            footer
        }
        .padding(.horizontal, metrics.padding)
        .padding(.top, 30 * s)
        .padding(.bottom, metrics.padding * 0.75)
        .foregroundStyle(Self.ink)
    }

    private func columnTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 19 * s, weight: .heavy, design: .rounded))
            .tracking(1.4)
            .foregroundStyle(Self.accentText)
            .padding(.bottom, 14 * s)
    }

    private func moreLine(_ text: String, fontSize: CGFloat) -> some View {
        Text(text)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(Self.accentText)
    }

    // MARK: Backgrounds

    private func backdrop(dim: Double, blur: CGFloat) -> some View {
        ZStack {
            photoOrFallback(blur: blur)
            LinearGradient(
                colors: [.black.opacity(dim * 0.8), .black.opacity(dim), .black.opacity(min(0.95, dim + 0.12))],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    /// The dish photo — or, for a dish without one, its colour and glyph.
    @ViewBuilder
    private func photoOrFallback(blur: CGFloat) -> some View {
        if let photo {
            Color.clear
                .overlay {
                    photo
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
                .blur(radius: blur, opaque: true)
        } else {
            let tint = DishGlyph.tint(forName: content.title)
            ZStack {
                LinearGradient(colors: [tint, tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .background(Color.black)
                Group {
                    if let emoji = glyph?.emoji {
                        Text(emoji).font(.system(size: 360 * s))
                    } else {
                        Image(systemName: glyph?.symbolName ?? "fork.knife")
                            .font(.system(size: 300 * s, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
                .opacity(0.22)
            }
        }
    }

    // MARK: Rows, shared with the planner's measuring

    static func ingredientRow(
        _ line: RecipeShareContent.IngredientLine,
        width: CGFloat,
        fontSize: CGFloat
    ) -> some View {
        var text = AttributedString(line.name)
        text.foregroundColor = ink
        if let note = line.note {
            var tail = AttributedString(", \(note)")
            tail.foregroundColor = muted
            text += tail
        }
        return HStack(alignment: .firstTextBaseline, spacing: fontSize * 0.5) {
            // A space, not "", so a line without an amount keeps its baseline.
            Text(line.amount ?? " ")
                .font(.system(size: fontSize, weight: .bold).monospacedDigit())
                .foregroundStyle(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: fontSize * 4.2, alignment: .trailing)
            Text(text)
                .font(.system(size: fontSize))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: width, alignment: .leading)
    }

    static func stepGroup(
        _ steps: [RecipeShareContent.Step],
        width: CGFloat,
        fontSize: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: fontSize * 0.45) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                if step.isHeading {
                    Text(step.text)
                        .font(.system(size: fontSize * 1.05, weight: .semibold, design: .serif))
                        .italic()
                        .foregroundStyle(accentText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: fontSize * 0.55) {
                        if let number = step.number {
                            Text("\(number)")
                                .font(.system(size: fontSize * 0.78, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(width: fontSize * 1.45, height: fontSize * 1.45)
                                .background(Circle().fill(RecipePageStyle.accent))
                        }
                        Text(step.text)
                            .font(.system(size: fontSize))
                            .lineSpacing(fontSize * 0.22)
                            .foregroundStyle(ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(width: width, alignment: .leading)
    }
}
