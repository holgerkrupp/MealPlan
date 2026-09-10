import Foundation
import Observation
import OSLog

/// Everything the watch app knows, and the only place it is changed.
///
/// The watch owns no data of its own: the phone sends a `WatchPlanSnapshot`
/// and the watch shows it. The one exception is ticking a shopping line, which
/// has to feel instant on the wrist and therefore happens locally first and
/// travels to the phone afterwards. `pending` is what keeps those two honest —
/// a snapshot the phone built *before* a tick must not silently undo it.
@MainActor
@Observable
final class WatchDataStore {

    static let shared = WatchDataStore()

    private static let logger = Logger(subsystem: "de.holgerkrupp.mealplan.watchkitapp", category: "store")

    /// The plan and list on screen. Starts as the last snapshot from disk, so
    /// the app has something to show before the phone answers — including when
    /// the phone is not reachable at all.
    private(set) var snapshot: WatchPlanSnapshot = .empty
    /// When that snapshot was built on the phone.
    var lastUpdated: Date? { snapshot.generatedAt == .distantPast ? nil : snapshot.generatedAt }
    /// Whether the phone can be talked to right now. Only used to explain an
    /// empty screen; the app works from the cache regardless.
    private(set) var isReachable = false
    /// Ticks made here that the phone has not yet confirmed, newest per line.
    private var pending: [UUID: WatchShoppingCheck] = [:]

    private let cache = WatchSnapshotCache()
    private var link: WatchConnectivityClient?

    private init() {
        snapshot = cache.loadSnapshot() ?? .empty
        pending = cache.loadPending()
        applyPending()
    }

    // MARK: - Lifecycle

    func start() {
        if link == nil { link = WatchConnectivityClient() }
        link?.activate()
        refresh()
    }

    /// Asks the phone for a fresh snapshot. Called at launch and whenever the
    /// app comes back to the foreground — the phone also pushes on its own, so
    /// this is the belt to that pair of braces.
    func refresh() {
        guard let link else { return }
        link.requestSnapshot()
        flushPending()
    }

    // MARK: - Incoming

    /// Takes a snapshot from the phone, then puts back any tick the phone had
    /// not seen when it built that snapshot.
    func receive(_ incoming: WatchPlanSnapshot) {
        // Out-of-order delivery is normal: an application context can land
        // after the reply to a request that was sent later.
        guard incoming.generatedAt >= snapshot.generatedAt else { return }
        snapshot = incoming
        // Anything the phone already knew about is no longer pending.
        pending = pending.filter { $0.value.changedAt > incoming.generatedAt }
        applyPending()
        cache.save(snapshot: snapshot, pending: pending)
    }

    func setReachable(_ reachable: Bool) {
        isReachable = reachable
        if reachable { flushPending() }
    }

    // MARK: - Ticking a line

    /// Ticks or un-ticks a shopping line. Applied here and now; the phone
    /// finds out over the queued transfer, which survives the watch being out
    /// of range or the app being closed.
    func toggle(_ item: WatchShoppingItem) {
        guard let index = snapshot.shopping.firstIndex(where: { $0.id == item.id }) else { return }
        let checked = !snapshot.shopping[index].isChecked
        snapshot.shopping[index].isChecked = checked
        let check = WatchShoppingCheck(id: item.id, isChecked: checked, changedAt: .now)
        pending[item.id] = check
        cache.save(snapshot: snapshot, pending: pending)
        link?.send([check])
    }

    /// Re-sends everything still unconfirmed. Cheap: `transferUserInfo` is
    /// already a queue, and the phone ignores a tick it has applied.
    private func flushPending() {
        guard !pending.isEmpty, let link else { return }
        link.send(Array(pending.values))
    }

    private func applyPending() {
        guard !pending.isEmpty else { return }
        for index in snapshot.shopping.indices {
            guard let check = pending[snapshot.shopping[index].id] else { continue }
            snapshot.shopping[index].isChecked = check.isChecked
        }
    }
}

// MARK: - Cache

/// The last snapshot, on disk. The watch is opened in a shop, in a lift, with
/// the phone in another room — arriving at an empty list in that moment would
/// make the app useless exactly when it is wanted.
private struct WatchSnapshotCache {

    private static let logger = Logger(subsystem: "de.holgerkrupp.mealplan.watchkitapp", category: "cache")

    private var directory: URL {
        let base = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private var snapshotURL: URL { directory.appending(path: "WatchSnapshot.json") }
    private var pendingURL: URL { directory.appending(path: "WatchPendingChecks.json") }

    func loadSnapshot() -> WatchPlanSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? WatchSyncPayload.decoder.decode(WatchPlanSnapshot.self, from: data)
    }

    func loadPending() -> [UUID: WatchShoppingCheck] {
        guard let data = try? Data(contentsOf: pendingURL),
              let checks = try? WatchSyncPayload.decoder.decode([WatchShoppingCheck].self, from: data)
        else { return [:] }
        return Dictionary(checks.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
    }

    func save(snapshot: WatchPlanSnapshot, pending: [UUID: WatchShoppingCheck]) {
        do {
            try WatchSyncPayload.encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)
            try WatchSyncPayload.encoder.encode(Array(pending.values)).write(to: pendingURL, options: .atomic)
        } catch {
            Self.logger.error("Could not cache the plan: \(error.localizedDescription)")
        }
    }
}
