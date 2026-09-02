import Foundation

/// Parsed representation of a `mealplan://` URL (also used by App Intents and
/// the Share Extension hand-off).
enum DeepLink: Equatable, Sendable {
    case today
    case date(Date)
    case addDish(url: URL?, name: String?)
    case plan(dishName: String?, dishUUID: UUID?, date: Date?, slot: MealSlot?)
    case shoppingList

    static let scheme = "mealplan"

    init?(url: URL) {
        guard url.scheme?.lowercased() == DeepLink.scheme else { return nil }
        let host = url.host()?.lowercased() ?? ""
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        func q(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.removingPercentEncoding
        }

        switch host {
        case "today", "":
            self = .today
        case "shopping", "shopping-list", "einkaufsliste":
            self = .shoppingList
        case "date":
            let iso = url.pathComponents.dropFirst().first ?? q("value") ?? ""
            guard let date = DeepLink.parseDate(iso) else { return nil }
            self = .date(date)
        case "add-dish", "adddish", "add":
            self = .addDish(url: q("url").flatMap(URL.init(string:)), name: q("name"))
        case "plan", "plan-meal":
            self = .plan(
                dishName: q("dish") ?? q("name"),
                dishUUID: q("id").flatMap(UUID.init(uuidString:)),
                date: q("date").flatMap(DeepLink.parseDate),
                slot: q("slot").flatMap { MealSlot(rawValue: $0.lowercased()) }
            )
        default:
            return nil
        }
    }

    static func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased() == "today" { return Date.now.startOfDay }
        if trimmed.lowercased() == "tomorrow" { return Date.now.adding(days: 1).startOfDay }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate]
        if let d = iso.date(from: trimmed) { return d.startOfDay }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd", "dd.MM.yyyy", "yyyy/MM/dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: trimmed) { return d.startOfDay }
        }
        return nil
    }
}

// MARK: - Building links

extension DeepLink {

    /// The URL that reopens this destination — the inverse of `init?(url:)`,
    /// for the cases something outside the app needs to link back in. The
    /// widgets use these; anything `init?(url:)` can parse round-trips.
    var url: URL {
        switch self {
        case .today:
            return URL(string: "\(DeepLink.scheme)://today") ?? URL(fileURLWithPath: "/")
        case .date(let date):
            return URL(string: "\(DeepLink.scheme)://date/\(date.dayID)") ?? DeepLink.today.url
        case .shoppingList:
            return URL(string: "\(DeepLink.scheme)://shopping") ?? DeepLink.today.url
        case .addDish, .plan:
            // Both carry free-form text that would need escaping, and nothing
            // links *into* them from outside yet.
            return DeepLink.today.url
        }
    }
}
