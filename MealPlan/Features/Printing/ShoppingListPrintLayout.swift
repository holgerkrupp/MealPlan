import CoreGraphics
import Foundation

/// How the shopping list is poured into columns and sheets.
///
/// A shopping list is a long thin thing and a sheet of paper is not, so it is
/// set in columns — three across an A4 portrait page — and an aisle that runs
/// past the bottom of one column continues at the top of the next.
///
/// Nothing here measures anything: heights are estimated from the same
/// constants `PrintShoppingColumns` draws with. That is the price of laying
/// out ahead of the render, and it is why the estimates are deliberately a
/// little generous — a column that is one line shorter than it could be looks
/// fine, while one line too many would be clipped by the edge of the sheet.
enum ShoppingListLayout {

    /// Below this a column can't hold an ingredient name and its amount side
    /// by side without wrapping every other line.
    static let minimumColumnWidth: CGFloat = 150
    static let maximumColumns = 4

    /// Estimated heights at scale 1, matching `PrintShoppingColumns`.
    static let aisleHeaderHeight: CGFloat = 12
    static let lineHeight: CGFloat = 11
    static let aisleSpacing: CGFloat = 8

    static func columns(contentWidth: CGFloat, textScale: CGFloat = 1) -> Int {
        let fit = Int(contentWidth / (minimumColumnWidth * textScale))
        return min(max(fit, 1), maximumColumns)
    }

    /// The height one aisle takes with `lineCount` of its lines in a column.
    static func height(lineCount: Int, textScale: CGFloat = 1) -> CGFloat {
        (aisleHeaderHeight + CGFloat(lineCount) * lineHeight) * textScale
    }

    /// A column holding fewer lines than this isn't a column, it's a ragged
    /// edge — a six-item list belongs in one column, not three columns of two.
    static let minimumLinesPerColumn = 8

    /// Pour the aisles into columns, and the columns into sheets.
    ///
    /// - Returns: sheets, each a left-to-right array of columns, each an array
    ///   of aisle slices. A split aisle repeats its name at the top of the
    ///   continuation — a shopper reading the second column shouldn't have to
    ///   look back at the first to find out what they are looking at.
    static func flow(
        groups: [MealPlanPrintDocument.ShoppingGroup],
        columns: Int,
        columnHeight: CGFloat,
        textScale: CGFloat = 1
    ) -> [[[MealPlanPrintDocument.ShoppingGroup]]] {
        let filled = groups.filter { !$0.lines.isEmpty }
        guard !filled.isEmpty else { return [] }

        let lineCount = filled.reduce(0) { $0 + $1.lines.count }
        let perSheet = max(1, min(columns, lineCount / minimumLinesPerColumn))
        let usable = max(columnHeight, height(lineCount: 1, textScale: textScale))

        // A list that fits on one sheet is balanced across that sheet's
        // columns rather than filling the first one and leaving the rest
        // blank: three short columns read better than one long one, and the
        // amounts stay beside the names instead of stranded at the page edge.
        let total = filled.enumerated().reduce(CGFloat.zero) { running, pair in
            running
                + (pair.offset == 0 ? 0 : aisleSpacing * textScale)
                + height(lineCount: pair.element.lines.count, textScale: textScale)
        }
        if perSheet > 1, total <= usable * CGFloat(perSheet) {
            // An even share of the total is only a first guess: aisles don't
            // split at arbitrary heights, and every column that starts one
            // spends a header on it. So grow the target a line at a time until
            // the whole list lands on a single sheet, which is the shortest
            // column height that balances it.
            var target = max(
                height(lineCount: minimumLinesPerColumn, textScale: textScale),
                (total / CGFloat(perSheet)).rounded(.up)
            )
            while target < usable {
                let attempt = pour(filled, perSheet: perSheet, columnHeight: target, textScale: textScale)
                if attempt.count == 1 { return attempt }
                target = min(usable, target + lineHeight * textScale)
            }
        }

        return pour(filled, perSheet: perSheet, columnHeight: usable, textScale: textScale)
    }

    /// Fill columns to `columnHeight`, left to right, sheet after sheet.
    private static func pour(
        _ groups: [MealPlanPrintDocument.ShoppingGroup],
        perSheet: Int,
        columnHeight: CGFloat,
        textScale: CGFloat
    ) -> [[[MealPlanPrintDocument.ShoppingGroup]]] {
        var sheets: [[[MealPlanPrintDocument.ShoppingGroup]]] = []
        var sheet: [[MealPlanPrintDocument.ShoppingGroup]] = []
        var column: [MealPlanPrintDocument.ShoppingGroup] = []
        var used: CGFloat = 0

        func closeColumn() {
            sheet.append(column)
            column = []
            used = 0
            if sheet.count == perSheet {
                sheets.append(sheet)
                sheet = []
            }
        }

        for group in groups {
            var remaining = group.lines[...]
            var slice = 0
            while !remaining.isEmpty {
                let spacing = column.isEmpty ? 0 : aisleSpacing * textScale
                let free = columnHeight - used - spacing
                // How many lines fit under a header in what's left.
                let fits = Int((free - aisleHeaderHeight * textScale) / (lineHeight * textScale))
                guard fits >= 1 else {
                    // Not even a header and one line: start the next column,
                    // unless this one is already empty, in which case the sheet
                    // is too short for anything and one line goes in regardless.
                    if column.isEmpty {
                        column.append(MealPlanPrintDocument.ShoppingGroup(
                            id: "\(group.id)#\(slice)",
                            name: group.name,
                            lines: Array(remaining.prefix(1))
                        ))
                        remaining = remaining.dropFirst()
                        slice += 1
                    }
                    closeColumn()
                    continue
                }
                let take = min(fits, remaining.count)
                column.append(MealPlanPrintDocument.ShoppingGroup(
                    id: "\(group.id)#\(slice)",
                    name: group.name,
                    lines: Array(remaining.prefix(take))
                ))
                used += spacing + height(lineCount: take, textScale: textScale)
                remaining = remaining.dropFirst(take)
                slice += 1
                if !remaining.isEmpty { closeColumn() }
            }
        }

        if !column.isEmpty { closeColumn() }
        if !sheet.isEmpty { sheets.append(sheet) }
        return sheets
    }
}
