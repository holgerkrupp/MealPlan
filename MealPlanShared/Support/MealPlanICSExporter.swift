import Foundation

/// Builds a standards-compliant iCalendar (`.ics`) feed of a household's
/// planned meals.
///
/// This is what makes the plan readable outside MealPlan: anyone who can
/// subscribe to a calendar URL — Google Calendar, Outlook, an Android phone's
/// stock calendar app — can follow along with what's for dinner without ever
/// installing the app. See `PublishedCalendarService`, which owns *where* the
/// file this produces ends up; this type only knows how to render one.
enum MealPlanICSExporter {

    /// Renders the feed. `entries` should already be narrowed to the
    /// household and window the caller wants published — this only formats
    /// them.
    ///
    /// Every event's `UID` is derived from the entry's own `uuid`, so
    /// republishing the same window updates a subscriber's existing events in
    /// place instead of duplicating them.
    static func makeICS(
        calendarName: String,
        entries: [MealPlanEntry],
        mealTypesByKey: [String: MealType],
        generatedAt: Date = .now
    ) -> String {
        var lines: [String] = []
        lines.append("BEGIN:VCALENDAR")
        lines.append("VERSION:2.0")
        lines.append("PRODID:-//MealPlan//Meal Plan Feed//EN")
        lines.append("CALSCALE:GREGORIAN")
        lines.append("METHOD:PUBLISH")
        lines.append(fold("X-WR-CALNAME:\(escape(calendarName))"))
        // Both forms are in the wild; Google honors neither reliably and
        // simply polls on its own schedule, but Outlook and some Android
        // clients read one of these to decide how often to re-fetch.
        lines.append("X-PUBLISHED-TTL:PT12H")
        lines.append("REFRESH-INTERVAL;VALUE=DURATION:PT12H")

        let sorted = entries.sorted {
            $0.date != $1.date ? $0.date < $1.date : $0.sortIndex < $1.sortIndex
        }
        for entry in sorted {
            lines.append(contentsOf: veventLines(for: entry, mealTypesByKey: mealTypesByKey, generatedAt: generatedAt))
        }

        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// What to call a meal in the feed. Falls back gracefully for the "Extra"
    /// slot and for a meal key whose `MealType` was since deleted.
    static func mealName(forKey key: String, mealTypesByKey: [String: MealType]) -> String {
        if MealType.isExtra(key) { return MealType.extraName }
        if let name = mealTypesByKey[key]?.name, !name.isEmpty { return name }
        return String(localized: "Meal")
    }

    // MARK: - One event

    private static func veventLines(
        for entry: MealPlanEntry,
        mealTypesByKey: [String: MealType],
        generatedAt: Date
    ) -> [String] {
        let title = entry.displayTitle
        // An extra already says what it is ("Birthday cake"); naming its slot
        // too would just repeat "Extra: Birthday cake" for no reason.
        let summary = entry.isExtra ? title : "\(mealName(forKey: entry.mealSlotRaw, mealTypesByKey: mealTypesByKey)): \(title)"

        var descriptionParts: [String] = []
        if let note = entry.note, !note.isEmpty { descriptionParts.append(note) }
        if entry.isEatingOut {
            if let placeName = entry.placeName, !placeName.isEmpty, placeName != title {
                descriptionParts.append(placeName)
            }
            if let address = entry.placeAddress, !address.isEmpty { descriptionParts.append(address) }
        }

        var out: [String] = ["BEGIN:VEVENT"]
        out.append("UID:\(entry.uuid.uuidString)@mealplan.app")
        out.append("DTSTAMP:\(utcStamp(generatedAt))")
        out.append("LAST-MODIFIED:\(utcStamp(entry.modifiedAt))")
        out.append("DTSTART;VALUE=DATE:\(dateStamp(entry.date))")
        out.append("DTEND;VALUE=DATE:\(dateStamp(entry.date.adding(days: 1)))")
        out.append(fold("SUMMARY:\(escape(summary))"))
        if !descriptionParts.isEmpty {
            out.append(fold("DESCRIPTION:\(escape(descriptionParts.joined(separator: "\n")))"))
        }
        // All-day and informational — never shows as "busy" on someone's
        // calendar just because they're subscribed to see what's cooking.
        out.append("TRANSP:TRANSPARENT")
        out.append("END:VEVENT")
        return out
    }

    // MARK: - Formatting helpers

    private static func utcStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private static func dateStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    /// Escapes text per RFC 5545 §3.3.11: backslash, comma, semicolon, and
    /// literal newlines.
    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Folds a content line at 75 octets, continuation lines prefixed with a
    /// single space, per RFC 5545 §3.1. Never splits inside a multi-byte
    /// UTF-8 sequence.
    private static func fold(_ line: String) -> String {
        let bytes = Array(line.utf8)
        guard bytes.count > 75 else { return line }

        var chunks: [[UInt8]] = []
        var start = 0
        var limit = 75
        while start < bytes.count {
            var end = min(start + limit, bytes.count)
            // A continuation byte (10xxxxxx) can't start a chunk — back up
            // until it doesn't split the character it belongs to.
            while end > start + 1 && (bytes[end - 1] & 0xC0) == 0x80 {
                end -= 1
            }
            chunks.append(Array(bytes[start..<end]))
            start = end
            // Continuation lines lose one octet of budget to their leading
            // space.
            limit = 74
        }
        return chunks.enumerated()
            .map { index, chunk in (index == 0 ? "" : " ") + String(decoding: chunk, as: UTF8.self) }
            .joined(separator: "\r\n")
    }
}
