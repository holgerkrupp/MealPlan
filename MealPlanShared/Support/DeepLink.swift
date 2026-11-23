import Foundation

/// One-shot destination queued by the share extension for the next user-open
/// of the app. Keeping this in the existing App Group avoids unsupported
/// attempts to launch the containing app from a Share extension.
enum ShareHandoff {
    enum Destination: Codable, Sendable {
        case site(URL)
        case dish(UUID)
        case addDish(url: URL?, name: String?)
    }

    struct Pending: Codable, Sendable {
        let id: UUID
        let destination: Destination
    }

    private static let key = "pendingShareHandoff.v1"

    /// Stores exactly one destination for the next app opening. The extension
    /// cannot reliably activate its containing app, so this is the durable
    /// boundary between the extension process and the app process.
    static func store(_ destination: Destination) -> Bool {
        guard let defaults = UserDefaults(suiteName: SharedStore.appGroupID),
              let data = try? JSONEncoder().encode(Pending(id: UUID(), destination: destination))
        else { return false }
        defaults.set(data, forKey: key)
        // The share extension can be torn down as soon as its view is
        // dismissed. Ask UserDefaults to flush the App Group write before
        // reporting success to the user.
        return defaults.synchronize()
    }

    static func pending() -> Pending? {
        guard let data = UserDefaults(suiteName: SharedStore.appGroupID)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Pending.self, from: data)
    }

    static func consume(id: UUID) {
        guard let defaults = UserDefaults(suiteName: SharedStore.appGroupID),
              let current = pending(), current.id == id else { return }
        defaults.removeObject(forKey: key)
        defaults.synchronize()
    }
}

/// Parsed representation of a `mealplan://` URL (also used by App Intents and
/// the Share Extension hand-off).
enum DeepLink: Equatable, Sendable {
    case today
    case date(Date)
    case addDish(url: URL?, name: String?)
    case plan(dishName: String?, dishUUID: UUID?, date: Date?, slot: MealSlot?)
    case dish(UUID)
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
            self = .addDish(
                url: q("url").flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? $0 : nil },
                name: q("name")
            )
        case "plan", "plan-meal":
            self = .plan(
                dishName: q("dish") ?? q("name"),
                dishUUID: q("id").flatMap(UUID.init(uuidString:)),
                date: q("date").flatMap(DeepLink.parseDate),
                slot: q("slot").flatMap { MealSlot(rawValue: $0.lowercased()) }
            )
        case "dish", "recipe":
            guard let id = q("id").flatMap(UUID.init(uuidString:))
                ?? url.pathComponents.dropFirst().first.flatMap(UUID.init(uuidString:))
            else { return nil }
            self = .dish(id)
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
        case .plan(let dishName, let dishUUID, let date, let slot):
            var components = URLComponents()
            components.scheme = DeepLink.scheme
            components.host = "plan"
            var items: [URLQueryItem] = []
            if let dishName { items.append(URLQueryItem(name: "dish", value: dishName)) }
            if let dishUUID { items.append(URLQueryItem(name: "id", value: dishUUID.uuidString)) }
            if let date { items.append(URLQueryItem(name: "date", value: date.dayID)) }
            if let slot { items.append(URLQueryItem(name: "slot", value: slot.rawValue)) }
            components.queryItems = items.isEmpty ? nil : items
            return components.url ?? DeepLink.today.url
        case .addDish:
            // Both carry free-form text that would need escaping, and nothing
            // links *into* add-dish from outside yet.
            return DeepLink.today.url
        case .dish(let id):
            var components = URLComponents()
            components.scheme = DeepLink.scheme
            components.host = "dish"
            components.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
            return components.url ?? DeepLink.today.url
        }
    }
}
