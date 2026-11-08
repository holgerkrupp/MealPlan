import Foundation

/// Splits pasted text — a list copied from Notes, Reminders, a message or a
/// recipe — into one shopping line per item. Each line is then handed to
/// `ShoppingListBuilder.addManualItem(named:…)`, which parses the amount the
/// same way a single typed item is parsed.
enum ShoppingListPaste {

    /// The non-empty lines of `text`, with list decoration (bullets, dashes,
    /// checkboxes, "1." numbering) removed.
    static func lines(from text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map(clean)
            .filter { !$0.isEmpty }
    }

    /// Whether `text` holds more than one item, so a paste into the single
    /// add field can be spread over several lines.
    static func isMultiLine(_ text: String) -> Bool {
        lines(from: text).count > 1
    }

    private static let bulletPrefixes = [
        "- [ ]", "- [x]", "- [X]", "* [ ]", "* [x]", "[ ]", "[x]", "[X]",
        "☐", "☑", "✓", "✔", "•", "◦", "▪", "‣", "–", "—", "-", "*", "+",
    ]

    private static func clean(_ raw: String) -> String {
        var line = raw.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            for prefix in bulletPrefixes where line.hasPrefix(prefix) {
                line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                changed = true
                break
            }
        }
        // "1. Milch" / "2) Eier" — list numbering, not an amount. An amount
        // like "1.5 kg" has no space after its dot and is left alone.
        if let match = line.firstMatch(of: /^\d{1,3}[.)]\s+/) {
            line = String(line[match.range.upperBound...])
        }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
