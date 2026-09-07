import SwiftUI

/// One printed sheet.
///
/// Deliberately plain: hairlines, black on white, no tints and no rounded
/// cards. Everything here is laid out in points at 72 dpi, because that is
/// what `ImageRenderer` hands to a PDF context — a "font size 9" below is
/// nine points on paper, not on a screen.
@MainActor
struct MealPlanPrintPageView: View {
    let document: MealPlanPrintDocument
    let page: PrintPage
    let geometry: PrintPageGeometry
    /// Multiplier for every rule on the page. 1 for print, where a 0.5 pt
    /// hairline is what a printer wants. A caller that shrinks the whole sheet
    /// to fit on screen passes more than 1: at a third of the size a hairline
    /// comes out under half a pixel, and the rasteriser rounds some of them
    /// away entirely — which reads as missing lines between the days rather
    /// than as faint ones. See `PrintPagePreview`.
    var strokeScale: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            header

            switch page.body {
            case let .days(range):
                PrintDayGrid(
                    days: Array(document.days[range]),
                    scale: scale,
                    contentWidth: geometry.contentSize.width,
                    strokeScale: strokeScale,
                    showsDayNutrition: document.days[range].contains { $0.energyText != nil }
                )

                if page.includesSummary, let summary = document.summary {
                    PrintSummaryBand(summary: summary, scale: scale, strokeScale: strokeScale)
                }

            case let .calendar(range):
                PrintCalendarBlock(
                    days: Array(document.days[range]),
                    scale: scale,
                    contentSize: geometry.contentSize,
                    strokeScale: strokeScale
                )

                if page.includesSummary, let summary = document.summary {
                    PrintSummaryBand(summary: summary, scale: scale, strokeScale: strokeScale)
                }

            case let .shopping(columns):
                PrintShoppingColumns(
                    columns: columns,
                    note: document.shoppingList?.note,
                    scale: scale,
                    strokeScale: strokeScale
                )
            }

            footer
        }
        .padding(geometry.margin)
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        .background(.white)
        .foregroundStyle(.black)
        .environment(\.colorScheme, .light)
        .tint(.black)
    }

    private var scale: CGFloat { geometry.textScale }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(document.title)
                .font(.system(size: 16 * scale, weight: .bold))
            Spacer(minLength: 8)
            Text(headline)
                .font(.system(size: 10 * scale))
                .foregroundStyle(.secondary)
        }
        .overlay(alignment: .bottom) {
            Rectangle().frame(height: 0.75 * strokeScale).foregroundStyle(.black.opacity(0.5))
                .offset(y: 5 * scale)
        }
    }

    /// The right-hand side of the title line. A shopping sheet says so — it
    /// may well be the only sheet someone takes to the shop, so it has to
    /// stand on its own.
    private var headline: String {
        guard case .shopping = page.body, let list = document.shoppingList else {
            return document.subtitle
        }
        guard let subtitle = list.subtitle else { return list.title }
        return "\(list.title) · \(subtitle)"
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(document.footnote)
                .font(.system(size: 6.5 * scale))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if page.pageCount > 1 {
                Text(String(localized: "Page \(page.pageNumber) of \(page.pageCount)"))
                    .font(.system(size: 6.5 * scale))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The calendar itself: meals down the side, days across the top.
///
/// A row label column costs about 60 points and earns them back — without it
/// every cell has to repeat "Breakfast", which on A5 leaves no room for the
/// dish. Row order is the union of the meals that actually appear on this
/// sheet, in the household's own order, so a one-off extra shows up as a row
/// only on the pages that have one.
@MainActor
private struct PrintDayGrid: View {
    let days: [MealPlanPrintDocument.Day]
    /// The sheet's own text scale (A5 sets smaller type than A4).
    let scale: CGFloat
    let contentWidth: CGFloat
    let strokeScale: CGFloat
    let showsDayNutrition: Bool

    /// What one day column actually gets on this sheet.
    private var columnWidth: CGFloat {
        let available = contentWidth - PrintPagination.labelColumnWidth * scale
        return max(1, available / CGFloat(max(1, days.count)))
    }

    /// How far the type has to come down for the columns this sheet ended up
    /// with. A sheet at or above the comfortable column width prints at full
    /// size; a squeezed one shrinks in step. `PrintPagination` is what keeps
    /// that from going too far — it refuses to squeeze a column below
    /// `minimumColumnWidth`, and the lower bound here is only a backstop for a
    /// sheet paginated some other way.
    private var density: CGFloat {
        let comfortable = PrintPagination.preferredColumnWidth * scale
        return min(1, max(0.5, columnWidth / comfortable))
    }

    /// Every size in this grid is in these units: the sheet's scale, tightened
    /// by how many columns it is carrying.
    private var s: CGFloat { scale * density }

    private var labelWidth: CGFloat { PrintPagination.labelColumnWidth * s }

    /// The rule between two days.
    private var columnRuleWidth: CGFloat { 0.5 * strokeScale }

    private var rows: [MealPlanPrintDocument.Meal] {
        var seen: Set<String> = []
        var result: [MealPlanPrintDocument.Meal] = []
        for day in days {
            for meal in day.meals where !seen.contains(meal.id) {
                seen.insert(meal.id)
                result.append(meal)
            }
        }
        return result
    }

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                Color.clear.frame(width: labelWidth, height: 1)
                ForEach(days) { day in
                    dayHeader(day)
                }
            }

            ForEach(rows) { row in
                GridRow {
                    Text(row.name)
                        .font(.system(size: 7.5 * s, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .frame(width: labelWidth, alignment: .topLeading)
                        .padding(.top, 4 * s)
                        .padding(.trailing, 4 * s)
                    ForEach(days) { day in
                        cell(day.meals.first { $0.id == row.id }, isWeekend: day.isWeekend)
                    }
                }
            }

            if showsDayNutrition {
                GridRow {
                    Text(String(localized: "Per person"))
                        .font(.system(size: 6.5 * s, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .frame(width: labelWidth, alignment: .topLeading)
                        .padding(.top, 4 * s)
                    ForEach(days) { day in
                        dayTotal(day)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay { columnRules }
    }

    /// The vertical rules, drawn once for the whole grid rather than as a
    /// leading edge on each cell.
    ///
    /// Every day column is the same width — they all take `maxWidth:
    /// .infinity` beside a fixed label strip — so the boundaries are simple
    /// arithmetic, and one rule per boundary runs unbroken from the weekday
    /// down past the day's total. Per-cell edges used to draw the same lines
    /// in as many pieces as there were meals, which is one rounding error away
    /// from a visible seam.
    private var columnRules: some View {
        GeometryReader { proxy in
            let columnWidth = (proxy.size.width - labelWidth) / CGFloat(max(1, days.count))
            ForEach(0..<days.count, id: \.self) { index in
                Rectangle()
                    .fill(.black.opacity(0.2))
                    .frame(width: columnRuleWidth)
                    .offset(x: labelWidth + CGFloat(index) * columnWidth)
            }
        }
        .allowsHitTesting(false)
    }

    private func dayHeader(_ day: MealPlanPrintDocument.Day) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(day.weekdayText)
                .font(.system(size: 9 * s, weight: day.isToday ? .heavy : .semibold))
            Text(day.dateText)
                .font(.system(size: 7.5 * s))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 4 * s)
        .padding(.vertical, 3 * s)
        .background(day.isWeekend ? Color.black.opacity(0.05) : .clear)
        .overlay(alignment: .bottom) {
            Rectangle().frame(height: 0.5 * strokeScale).foregroundStyle(.black.opacity(0.35))
        }
    }

    private func cell(_ meal: MealPlanPrintDocument.Meal?, isWeekend: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2 * s) {
            ForEach(meal?.entries ?? []) { entry in
                entryView(entry)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 4 * s)
        .padding(.vertical, 3 * s)
        // The weekend runs as a tint down the whole column, not just its
        // header: on a sheet stuck to a fridge door it is the fastest way to
        // find where the week ends.
        .background(isWeekend ? Color.black.opacity(0.035) : .clear)
        .overlay(alignment: .top) {
            Rectangle().frame(height: 0.25 * strokeScale).foregroundStyle(.black.opacity(0.2))
        }
    }

    private func entryView(_ entry: MealPlanPrintDocument.Entry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 3 * s) {
                if entry.isEatingOut {
                    Image(systemName: "takeoutbag.and.cup.and.straw")
                        .font(.system(size: 6 * s))
                        .foregroundStyle(.secondary)
                }
                Text(entry.title)
                    .font(.system(size: 8.5 * s))
                    .lineLimit(3)
                    .minimumScaleFactor(0.75)
                if let servings = entry.servingsText {
                    Text(servings)
                        .font(.system(size: 6.5 * s))
                        .foregroundStyle(.secondary)
                }
            }
            if let note = entry.note {
                Text(note)
                    .font(.system(size: 6.5 * s).italic())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let energy = entry.energyText {
                Text(entry.macrosText.map { "\(energy) · \($0)" } ?? energy)
                    .font(.system(size: 6.5 * s))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dayTotal(_ day: MealPlanPrintDocument.Day) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3 * s) {
                Text(day.energyText ?? "—")
                    .font(.system(size: 7.5 * s, weight: .semibold))
                    .monospacedDigit()
                if let standing = day.standingSymbolName {
                    Image(systemName: standing)
                        .font(.system(size: 6 * s, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if let macros = day.macrosText {
                Text(macros)
                    .font(.system(size: 6.5 * s))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 4 * s)
        .padding(.vertical, 3 * s)
        .background(day.isWeekend ? Color.black.opacity(0.035) : .clear)
        .overlay(alignment: .top) {
            Rectangle().frame(height: 0.75 * strokeScale).foregroundStyle(.black.opacity(0.5))
        }
    }
}

/// A month calendar: weekdays across, weeks down, each day's meals inside its
/// cell.
///
/// The meals are named by their symbol rather than in words — a cell 80 points
/// wide has no room for "Breakfast" next to the dish — with a legend along the
/// foot saying which is which. That legend is not optional decoration: without
/// it the symbols are a guessing game for anyone who didn't set the meals up.
@MainActor
private struct PrintCalendarBlock: View {
    let days: [MealPlanPrintDocument.Day]
    let scale: CGFloat
    let contentSize: CGSize
    let strokeScale: CGFloat

    /// Monday-based weekday names for the column headings, taken from the
    /// days themselves so they are already localized.
    private var weekdayNames: [String] {
        var names = Array(repeating: "", count: CalendarBlockLayout.columns)
        for day in days where names[day.weekdayIndex].isEmpty {
            names[day.weekdayIndex] = day.weekdayShortText.isEmpty
                ? day.weekdayText
                : day.weekdayShortText
        }
        return names
    }

    private var rows: [Range<Int>] {
        CalendarBlockLayout.weekRows(weekdayIndexes: days.map(\.weekdayIndex))
    }

    /// The tallest cell on the sheet, in lines — what every row is sized for.
    private var linesPerCell: Int {
        days.map { $0.meals.reduce(0) { $0 + max(1, $1.entries.count) } }.max() ?? 1
    }

    /// How the type is sized for the rows this sheet ended up carrying.
    ///
    /// Unlike the band grid's density this is allowed *above* 1: a fortnight
    /// on an A4 sheet has room to spare, and a month grid set at week-grid
    /// sizes leaves the cells half empty with meal symbols too small to tell
    /// apart. It grows to fill the sheet, within reason.
    private var density: CGFloat {
        let available = (contentSize.height - legendHeight) / CGFloat(max(1, rows.count))
        let preferred = CalendarBlockLayout.preferredRowHeight(
            linesPerCell: linesPerCell,
            textScale: scale
        )
        // Width has a vote too, and usually the deciding one: type sized only
        // by the room above and below it truncates every dish name and wraps
        // the weekday headings.
        let columnWidth = contentSize.width / CGFloat(CalendarBlockLayout.columns)
        let widthRatio = columnWidth / (CalendarBlockLayout.preferredColumnWidth * scale)
        return min(1.5, max(0.55, min(available / preferred, widthRatio)))
    }

    private var s: CGFloat { scale * density }

    private var legendHeight: CGFloat { 16 * scale }

    /// Every meal that appears anywhere on this sheet, in the household's own
    /// order — the same ordered union the band grid takes its rows from.
    private var legend: [(symbol: String, name: String)] {
        var seen: Set<String> = []
        var result: [(String, String)] = []
        for day in days {
            for meal in day.meals where !seen.contains(meal.id) {
                seen.insert(meal.id)
                result.append((meal.symbolName, meal.name))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(weekdayNames.enumerated()), id: \.offset) { _, name in
                        Text(name)
                            .font(.system(size: 7.5 * s, weight: .semibold))
                            .textCase(.uppercase)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 3 * s)
                            .padding(.bottom, 2 * s)
                    }
                }
                .overlay(alignment: .bottom) {
                    Rectangle().frame(height: 0.5 * strokeScale).foregroundStyle(.black.opacity(0.5))
                }

                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<CalendarBlockLayout.columns, id: \.self) { column in
                            cell(days[row].first { $0.weekdayIndex == column })
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay { columnRules }

            legendRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The vertical rules, drawn once for the whole block — see the note on
    /// `PrintDayGrid.columnRules`.
    private var columnRules: some View {
        GeometryReader { proxy in
            let width = proxy.size.width / CGFloat(CalendarBlockLayout.columns)
            ForEach(1..<CalendarBlockLayout.columns, id: \.self) { index in
                Rectangle()
                    .fill(.black.opacity(0.2))
                    .frame(width: 0.5 * strokeScale)
                    .offset(x: width * CGFloat(index))
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func cell(_ day: MealPlanPrintDocument.Day?) -> some View {
        VStack(alignment: .leading, spacing: 1 * s) {
            if let day {
                HStack(alignment: .firstTextBaseline, spacing: 3 * s) {
                    Text(day.dayNumberText.isEmpty ? day.dateText : day.dayNumberText)
                        .font(.system(size: 7.5 * s, weight: day.isToday ? .heavy : .semibold))
                    Spacer(minLength: 0)
                    if let energy = day.energyText {
                        Text(energy)
                            .font(.system(size: 6 * s))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                ForEach(day.meals) { meal in
                    if meal.entries.isEmpty {
                        line(symbol: meal.symbolName, text: nil)
                    } else {
                        ForEach(meal.entries) { entry in
                            line(symbol: meal.symbolName, text: entry.title)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 3 * s)
        .padding(.vertical, 2 * s)
        .background((day?.isWeekend ?? false) ? Color.black.opacity(0.035) : .clear)
        .overlay(alignment: .top) {
            Rectangle().frame(height: 0.25 * strokeScale).foregroundStyle(.black.opacity(0.2))
        }
    }

    /// One meal in a cell: its symbol, then the dish — or a rule to write on
    /// when nothing is planned.
    private func line(symbol: String, text: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2.5 * s) {
            Image(systemName: symbol)
                .font(.system(size: 5.5 * s))
                .foregroundStyle(.secondary)
                .frame(width: 7 * s, alignment: .leading)
            if let text {
                Text(text)
                    .font(.system(size: 7 * s))
                    .lineLimit(1)
                    // Shrink a little to save a long name, then truncate:
                    // dropping much further makes one cell look like a
                    // different typeface from its neighbours.
                    .minimumScaleFactor(0.82)
            } else {
                Rectangle()
                    .fill(.black.opacity(0.12))
                    .frame(height: 0.5 * strokeScale)
                    .padding(.trailing, 4 * s)
            }
            Spacer(minLength: 0)
        }
        .frame(height: CalendarBlockLayout.lineHeight * s, alignment: .center)
    }

    private var legendRow: some View {
        HStack(spacing: 9 * s) {
            ForEach(Array(legend.enumerated()), id: \.offset) { _, meal in
                HStack(spacing: 3 * s) {
                    Image(systemName: meal.symbol)
                        .font(.system(size: 6.5 * s))
                    Text(meal.name)
                        .font(.system(size: 7 * s))
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(height: legendHeight, alignment: .bottom)
    }
}

/// The shopping list, in columns.
///
/// Every line gets a box to tick with a pen, which is the whole reason to
/// print a list rather than carry it on a phone. Heights here are the ones
/// `ShoppingListLayout` estimates with — change one and change the other, or
/// a column will run off the bottom of the sheet.
@MainActor
private struct PrintShoppingColumns: View {
    let columns: [[MealPlanPrintDocument.ShoppingGroup]]
    let note: String?
    let scale: CGFloat
    let strokeScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            HStack(alignment: .top, spacing: 14 * scale) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    VStack(alignment: .leading, spacing: ShoppingListLayout.aisleSpacing * scale) {
                        ForEach(column) { group in
                            aisle(group)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let note {
                Text(note)
                    .font(.system(size: 6.5 * scale))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func aisle(_ group: MealPlanPrintDocument.ShoppingGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(group.name)
                .font(.system(size: 7.5 * scale, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .frame(height: ShoppingListLayout.aisleHeaderHeight * scale, alignment: .bottomLeading)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .frame(height: 0.5 * strokeScale)
                        .foregroundStyle(.black.opacity(0.35))
                }
            ForEach(group.lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 5 * scale) {
                    Rectangle()
                        .strokeBorder(.black.opacity(0.45), lineWidth: 0.5 * strokeScale)
                        .frame(width: 6 * scale, height: 6 * scale)
                        .alignmentGuide(.firstTextBaseline) { $0.height }
                    Text(line.name)
                        .font(.system(size: 8.5 * scale))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 4 * scale)
                    if let amount = line.amountText {
                        Text(amount)
                            .font(.system(size: 7.5 * scale))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                .frame(height: ShoppingListLayout.lineHeight * scale)
            }
        }
    }
}

/// What the range came to, as a band across the foot of the last sheet.
///
/// One line of figures and one of caveats. The per-day numbers are already in
/// the grid's own "per person" row directly above it, so repeating them here
/// would cost a whole sheet to say the same thing twice.
@MainActor
private struct PrintSummaryBand: View {
    let summary: MealPlanPrintDocument.Summary
    let scale: CGFloat
    let strokeScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 2 * scale) {
            HStack(alignment: .firstTextBaseline, spacing: 6 * scale) {
                Text(String(localized: "Average per day"))
                    .font(.system(size: 7 * scale, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Text(summary.averageEnergyText)
                    .font(.system(size: 9 * scale, weight: .semibold))
                    .monospacedDigit()
                if let macros = summary.averageMacrosText {
                    Text(macros)
                        .font(.system(size: 7.5 * scale))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 6 * scale)
                Text(aside)
                    .font(.system(size: 7 * scale))
                    .foregroundStyle(.secondary)
            }
            if let caveats {
                Text(caveats)
                    .font(.system(size: 6.5 * scale))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4 * scale)
        .overlay(alignment: .top) {
            Rectangle().frame(height: 0.75 * strokeScale).foregroundStyle(.black.opacity(0.5))
        }
    }

    private var aside: String {
        [summary.countedDaysText, summary.lightestDayText, summary.heaviestDayText]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var caveats: String? {
        let parts = [summary.coverageNote, summary.missingNote].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

#Preview("A4 landscape") {
    let geometry = PrintPageGeometry(paper: .a4, orientation: .landscape)
    let document = MealPlanPrintPreview.document
    return MealPlanPrintPageView(
        document: document,
        page: PrintPagination.pages(for: document, geometry: geometry)[0],
        geometry: geometry
    )
    .scaleEffect(0.8)
}

#Preview("A5 portrait") {
    let geometry = PrintPageGeometry(paper: .a5, orientation: .portrait)
    let document = MealPlanPrintPreview.document
    return MealPlanPrintPageView(
        document: document,
        page: PrintPagination.pages(for: document, geometry: geometry)[0],
        geometry: geometry
    )
}
