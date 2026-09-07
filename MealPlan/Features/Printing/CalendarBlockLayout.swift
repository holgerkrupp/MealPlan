import CoreGraphics
import Foundation

/// The month-calendar layout: weekdays across, weeks down.
///
/// The band layout — meals down the side, days across — is the better way to
/// read a week, but it can only ever be one row of days, so a fortnight needs
/// two sheets and a month needs five. Wrapping the days into week rows is what
/// makes "fit on one page" mean something for a long span: thirty days become
/// five rows of seven on a single sheet.
///
/// Rows are aligned to the week, so every column is the same weekday all the
/// way down. A span starting on a Thursday therefore opens with three blank
/// cells — the alternative, packing seven days into each row whatever they
/// are, produces a grid where no column means anything.
enum CalendarBlockLayout {

    static let columns = 7

    /// A day cell narrower than this can't hold a dish name. Absolute, not
    /// scaled by the paper, for the reason in `PrintPagination`.
    static let minimumColumnWidth: CGFloat = 62

    /// The cell width the type is designed at. A sheet with wider cells may
    /// set it larger; a sheet with narrower ones must set it smaller, or the
    /// dish names truncate and the weekday headings wrap.
    static let preferredColumnWidth: CGFloat = 92

    /// Heights at scale 1: the date line, one meal line, and what a row would
    /// like to have.
    static let headerHeight: CGFloat = 12
    static let lineHeight: CGFloat = 12
    /// The floor a row is allowed to be squeezed to. Below this the dish names
    /// stop being readable and the sheet is worth splitting instead.
    static let minimumLineHeight: CGFloat = 8.5
    static let minimumHeaderHeight: CGFloat = 9

    /// Whether this sheet is wide enough for seven day columns at all.
    static func fitsWidth(contentWidth: CGFloat) -> Bool {
        contentWidth / CGFloat(columns) >= minimumColumnWidth
    }

    /// The shortest a row can be while its cells stay readable.
    static func minimumRowHeight(linesPerCell: Int) -> CGFloat {
        minimumHeaderHeight + CGFloat(max(1, linesPerCell)) * minimumLineHeight
    }

    /// What a row would take if nothing were squeezed.
    static func preferredRowHeight(linesPerCell: Int, textScale: CGFloat = 1) -> CGFloat {
        (headerHeight + CGFloat(max(1, linesPerCell)) * lineHeight) * textScale
    }

    /// How many week rows fit on one sheet.
    static func rowsPerSheet(bodyHeight: CGFloat, linesPerCell: Int) -> Int {
        max(1, Int(bodyHeight / minimumRowHeight(linesPerCell: linesPerCell)))
    }

    /// Split the days into week rows.
    ///
    /// - Parameter weekdayIndexes: each day's position in its week, Monday 0.
    ///   A row ends when the next day is a Monday, so the first row is short
    ///   when the span doesn't start on one.
    static func weekRows(weekdayIndexes: [Int]) -> [Range<Int>] {
        guard !weekdayIndexes.isEmpty else { return [] }
        var rows: [Range<Int>] = []
        var start = 0
        for index in 1..<weekdayIndexes.count where weekdayIndexes[index] == 0 {
            rows.append(start..<index)
            start = index
        }
        rows.append(start..<weekdayIndexes.count)
        return rows
    }

    /// Group the week rows into sheets of at most `rowsPerSheet` rows.
    static func sheets(rows: [Range<Int>], rowsPerSheet: Int) -> [Range<Int>] {
        guard !rows.isEmpty else { return [] }
        let perSheet = max(1, rowsPerSheet)
        return stride(from: 0, to: rows.count, by: perSheet).map { first in
            let last = min(first + perSheet, rows.count) - 1
            return rows[first].lowerBound..<rows[last].upperBound
        }
    }

    /// Whether a span of `dayCount` days starting on weekday `startIndex`
    /// fits, as a calendar block, on a single sheet.
    static func fitsOnOneSheet(
        dayCount: Int,
        startWeekday: Int,
        linesPerCell: Int,
        geometry: PrintPageGeometry
    ) -> Bool {
        guard dayCount > 0, fitsWidth(contentWidth: geometry.contentSize.width) else { return false }
        let rows = Int(((Double(startWeekday + dayCount)) / Double(columns)).rounded(.up))
        return rows <= rowsPerSheet(
            bodyHeight: geometry.bodyHeight,
            linesPerCell: linesPerCell
        )
    }
}
