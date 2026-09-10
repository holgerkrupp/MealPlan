import Foundation

/// How the phone and the watch package what they send each other.
///
/// WatchConnectivity dictionaries carry property-list values only, so both
/// directions travel as one JSON `Data` under a known key. Dates are encoded
/// as ISO 8601 so a payload stays readable in a log and survives a version
/// where one side re-encodes it.
enum WatchSyncPayload {

    // MARK: Keys

    /// Phone → watch: the whole snapshot.
    static let snapshotKey = "mealplan.snapshot"
    /// Watch → phone: ticks made on the wrist.
    static let checksKey = "mealplan.shoppingChecks"
    /// Watch → phone: "send me a fresh snapshot".
    static let refreshRequestKey = "mealplan.refreshRequest"

    // MARK: Coders

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: Snapshot

    static func message(for snapshot: WatchPlanSnapshot) -> [String: Any]? {
        guard let data = try? encoder.encode(snapshot) else { return nil }
        return [snapshotKey: data]
    }

    static func snapshot(in message: [String: Any]) -> WatchPlanSnapshot? {
        guard let data = message[snapshotKey] as? Data else { return nil }
        return try? decoder.decode(WatchPlanSnapshot.self, from: data)
    }

    // MARK: Check marks

    static func message(for checks: [WatchShoppingCheck]) -> [String: Any]? {
        guard !checks.isEmpty, let data = try? encoder.encode(checks) else { return nil }
        return [checksKey: data]
    }

    static func checks(in message: [String: Any]) -> [WatchShoppingCheck] {
        guard let data = message[checksKey] as? Data else { return [] }
        return (try? decoder.decode([WatchShoppingCheck].self, from: data)) ?? []
    }

    // MARK: Refresh

    static var refreshRequest: [String: Any] { [refreshRequestKey: Date.now.timeIntervalSince1970] }

    static func isRefreshRequest(_ message: [String: Any]) -> Bool {
        message[refreshRequestKey] != nil
    }
}
