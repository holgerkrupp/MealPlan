import CoreGraphics
import Foundation

/// A printout, fully resolved: every number already formatted, every name
/// already localized, nothing left that needs a `ModelContext`.
///
/// The page views take one of these and lay it out; they never look anything
/// up. That is what lets the whole shape of a printout — how many pages it
/// takes, which days land on which sheet, what the summary says — be tested
/// without a store, a renderer or a running app.
struct MealPlanPrintDocument: Sendable, Equatable {

    /// One planned dish (or a night out) in a meal.
    struct Entry: Identifiable, Sendable, Equatable {
        var id: String
        var title: String
        /// "for 6", when the occasion overrides the household's head-count.
        var servingsText: String?
        var note: String?
        /// Per serving, when per-meal nutrition is on and the estimate holds up.
        var energyText: String?
        var macrosText: String?
        var isEatingOut = false
    }

    /// One meal on one day — a column cell.
    struct Meal: Identifiable, Sendable, Equatable {
        var id: String
        var name: String
        var symbolName: String
        var entries: [Entry]
        var isEmpty: Bool { entries.isEmpty }
    }

    struct Day: Identifiable, Sendable, Equatable {
        var id: String
        var weekdayText: String
        /// The abbreviated form, for the calendar block's column headings —
        /// "Wednesday" does not fit across a 76-point cell.
        var weekdayShortText: String = ""
        /// Position in its week, Monday 0 — what lets the calendar block put
        /// every day in the column for its weekday.
        var weekdayIndex: Int = 0
        var dateText: String
        /// The short form for a calendar cell: the day number alone, with the
        /// month added where it changes. "10 Sep" in all thirty cells is
        /// width a month grid hasn't got to spare.
        var dayNumberText: String = ""
        var isToday: Bool
        var isWeekend: Bool
        var meals: [Meal]
        /// Per person across the day, when per-day nutrition is on.
        var energyText: String?
        var macrosText: String?
        /// "↑" / "=" / "↓" against the middle of the printed range.
        var standingSymbolName: String?
        var standingText: String?
    }

    /// What the whole range came to, as a band along the foot of the last
    /// sheet.
    ///
    /// Deliberately aggregates only. The first cut printed a per-day table on
    /// a sheet of its own, which repeated the grid's own "per person" row and
    /// turned every one-page plan into a two-page one.
    struct Summary: Sendable, Equatable {
        var averageEnergyText: String
        /// Only when protein/carbs/fat are switched on.
        var averageMacrosText: String?
        /// How many of the range's days had enough planned to count.
        var countedDaysText: String
        var lightestDayText: String?
        var heaviestDayText: String?
        /// What the figures had to leave out, when anything was missing.
        var coverageNote: String?
        var missingNote: String?
    }

    // MARK: - The shopping list

    /// One line to buy. Amount is a string because the list has already
    /// decided how to write it ("500 g", "3 ×", nothing at all).
    struct ShoppingLine: Identifiable, Sendable, Equatable {
        var id: String
        var name: String
        var amountText: String?
    }

    /// One aisle. A long aisle is cut into slices by the column flow, which is
    /// why `id` carries the slice and `name` doesn't — see
    /// `ShoppingListLayout.flow`.
    struct ShoppingGroup: Identifiable, Sendable, Equatable {
        var id: String
        var name: String
        var lines: [ShoppingLine]
    }

    struct ShoppingList: Sendable, Equatable {
        var title: String
        /// The days the list was built for, when it says.
        var subtitle: String?
        var groups: [ShoppingGroup]
        /// "14 ticked items left out.", when any were.
        var note: String?

        var isEmpty: Bool { groups.allSatisfy { $0.lines.isEmpty } }
    }

    var title: String
    var subtitle: String
    var days: [Day]
    var summary: Summary?
    /// Printed after the plan, on sheets of its own.
    var shoppingList: ShoppingList?
    /// The line along the bottom of every page.
    var footnote: String
    /// Set when any figure appears anywhere, so pages can carry the estimate
    /// disclaimer only when there is something to disclaim.
    var showsNutrition: Bool
}

// MARK: - Pagination

/// One printed sheet.
struct PrintPage: Identifiable, Sendable, Equatable {

    enum Body: Sendable, Equatable {
        /// Indices into `MealPlanPrintDocument.days`, as one band: meals down
        /// the side, days across.
        case days(Range<Int>)
        /// The same indices laid out as a month calendar — weekdays across,
        /// weeks down. How a long span fits on one sheet; see
        /// `CalendarBlockLayout`.
        case calendar(Range<Int>)
        /// Aisle groups already flowed into this sheet's columns, left to
        /// right — see `ShoppingListLayout.flow`.
        case shopping([[MealPlanPrintDocument.ShoppingGroup]])
    }

    var body: Body
    var pageNumber: Int
    var pageCount: Int
    /// The summary band, which goes on the last sheet of the *plan* rather
    /// than taking one of its own, and never on a shopping sheet.
    var includesSummary: Bool

    var id: String {
        switch body {
        case let .days(range): "days-\(range.lowerBound)-\(range.upperBound)-\(pageNumber)"
        case let .calendar(range): "calendar-\(range.lowerBound)-\(range.upperBound)-\(pageNumber)"
        case .shopping: "shopping-\(pageNumber)"
        }
    }

    /// The days this sheet carries, however they are laid out.
    var days: Range<Int>? {
        switch body {
        case let .days(range), let .calendar(range): range
        case .shopping: nil
        }
    }
}

/// How a range of days is cut into sheets.
///
/// Pure arithmetic, kept out of the views so the awkward cases — a fortnight
/// on A5, a single leftover day — can be pinned down in tests.
enum PrintPagination {

    /// The column width everything is designed at: a dish name on two lines
    /// without shrinking the type. A sheet with room for this many columns
    /// prints at full size.
    static let preferredColumnWidth: CGFloat = 92

    /// The narrowest a column is allowed to get while squeezing a span onto
    /// one sheet. Below this a dish name is no longer readable at any size, so
    /// the printout takes a second sheet instead.
    ///
    /// Unlike `preferredColumnWidth` this is **not** scaled by the paper: it
    /// is a floor on ink, not on design. `PrintDayGrid` sets its type at
    /// `8.5 pt × columnWidth / preferredColumnWidth × textScale`, in which the
    /// paper's scale cancels against the scaled column width — so what a
    /// squeezed column actually prints at depends on its width in points and
    /// nothing else. 65 pt is where the dish name reaches 6 pt, which is as
    /// small as print gets before it stops being readable.
    static let minimumColumnWidth: CGFloat = 65

    /// Without compacting, never more than a week to a sheet even when a wide
    /// one would take more: a plan is read a week at a time, and a page break
    /// on Sunday night is the one everybody already has in their head.
    static let maximumColumnsPerPage = 7

    /// The strip down the left holding the meal names, which the day columns
    /// don't get to use. See `PrintDayGrid`.
    static let labelColumnWidth: CGFloat = 54

    /// How many day columns one sheet takes.
    ///
    /// - Parameter compact: when true, the whole span is squeezed onto a
    ///   single sheet if the columns stay above `minimumColumnWidth` — which
    ///   is what "fit on one page" means, and why the seven-column cap and
    ///   the comfortable width are both lifted for it.
    static func columnsPerPage(
        contentWidth: CGFloat,
        textScale: CGFloat = 1,
        dayCount: Int = .max,
        compact: Bool = false
    ) -> Int {
        let available = contentWidth - labelColumnWidth * textScale
        let comfortable = min(
            max(Int(available / (preferredColumnWidth * textScale)), 1),
            maximumColumnsPerPage
        )
        guard compact, dayCount > comfortable else { return min(comfortable, max(dayCount, 1)) }

        // The whole span on one sheet, if the columns can bear it.
        if available / CGFloat(dayCount) >= minimumColumnWidth {
            return dayCount
        }
        // It can't — take as many as the narrowest legible column allows and
        // let `chunks` balance the rest.
        let squeezed = max(Int(available / minimumColumnWidth), 1)
        return max(comfortable, min(squeezed, dayCount))
    }

    /// Split `dayCount` days into per-page chunks of at most `columnsPerPage`.
    ///
    /// Chunks are balanced rather than greedy: eight days at seven to a page
    /// prints as 4 + 4, not 7 + 1, because a sheet holding a single Monday is
    /// a waste of paper and looks like a bug. Whole weeks are the exception —
    /// at exactly seven columns a fortnight stays 7 + 7, since splitting a
    /// week across sheets is worse than an uneven last page.
    static func chunks(dayCount: Int, columnsPerPage: Int) -> [Range<Int>] {
        guard dayCount > 0 else { return [] }
        let perPage = max(1, columnsPerPage)
        guard dayCount > perPage else { return [0..<dayCount] }

        let pageCount = Int((Double(dayCount) / Double(perPage)).rounded(.up))
        // Whole weeks: keep them whole.
        if perPage == 7, dayCount.isMultiple(of: 7) {
            return stride(from: 0, to: dayCount, by: 7).map { $0..<($0 + 7) }
        }

        let base = dayCount / pageCount
        let remainder = dayCount % pageCount
        var result: [Range<Int>] = []
        var start = 0
        for page in 0..<pageCount {
            let length = base + (page < remainder ? 1 : 0)
            result.append(start..<(start + length))
            start += length
        }
        return result
    }

    /// How the plan's days are cut into sheets.
    ///
    /// Three shapes, in order of preference: one band; a month calendar on one
    /// sheet; and, failing both, several sheets. Which of the last two is used
    /// depends on `compact` — the band is the better way to read a week, so it
    /// is tried first and the calendar only steps in when a span is too long
    /// for one.
    static func planSheets(
        for document: MealPlanPrintDocument,
        geometry: PrintPageGeometry,
        compact: Bool
    ) -> [PrintPage.Body] {
        let dayCount = document.days.count
        guard dayCount > 0 else { return [] }

        let columns = columnsPerPage(
            contentWidth: geometry.contentSize.width,
            textScale: geometry.textScale,
            dayCount: dayCount,
            compact: compact
        )
        if columns >= dayCount {
            return [.days(0..<dayCount)]
        }

        guard compact else {
            return chunks(dayCount: dayCount, columnsPerPage: columns).map { .days($0) }
        }

        // Too long for one band. Wrap it into week rows instead, which is what
        // makes a fortnight or a month a single sheet.
        let weekdayIndexes = document.days.map(\.weekdayIndex)
        // Every row is as tall as its tallest cell, so the busiest day of the
        // span sets the height. A meal with nothing planned still takes its
        // line — that blank is what someone fills in with a pen.
        let linesPerCell = document.days
            .map { $0.meals.reduce(0) { $0 + max(1, $1.entries.count) } }
            .max() ?? 1
        let rows = CalendarBlockLayout.weekRows(weekdayIndexes: weekdayIndexes)
        let perSheet = CalendarBlockLayout.rowsPerSheet(
            bodyHeight: geometry.bodyHeight,
            linesPerCell: linesPerCell
        )
        guard CalendarBlockLayout.fitsWidth(contentWidth: geometry.contentSize.width) else {
            return chunks(dayCount: dayCount, columnsPerPage: columns).map { .days($0) }
        }
        return CalendarBlockLayout.sheets(rows: rows, rowsPerSheet: perSheet).map { .calendar($0) }
    }

    /// Every sheet of a document, in order: the plan, then the shopping list.
    ///
    /// The summary never takes a sheet of its own: it is a band along the foot
    /// of the last plan sheet. A whole page for six numbers is exactly the
    /// kind of thing that turns a one-page plan into a two-page one.
    static func pages(
        for document: MealPlanPrintDocument,
        geometry: PrintPageGeometry,
        compact: Bool = true
    ) -> [PrintPage] {
        let planBodies = planSheets(for: document, geometry: geometry, compact: compact)

        let shoppingSheets: [[[MealPlanPrintDocument.ShoppingGroup]]] = {
            guard let list = document.shoppingList, !list.isEmpty else { return [] }
            return ShoppingListLayout.flow(
                groups: list.groups,
                columns: ShoppingListLayout.columns(
                    contentWidth: geometry.contentSize.width,
                    textScale: geometry.textScale
                ),
                columnHeight: geometry.bodyHeight,
                textScale: geometry.textScale
            )
        }()

        let total = planBodies.count + shoppingSheets.count
        var pages: [PrintPage] = planBodies.enumerated().map { index, body in
            PrintPage(
                body: body,
                pageNumber: index + 1,
                pageCount: total,
                includesSummary: document.summary != nil && index == planBodies.count - 1
            )
        }
        for (index, sheet) in shoppingSheets.enumerated() {
            pages.append(PrintPage(
                body: .shopping(sheet),
                pageNumber: planBodies.count + index + 1,
                pageCount: total,
                includesSummary: false
            ))
        }
        return pages
    }
}
