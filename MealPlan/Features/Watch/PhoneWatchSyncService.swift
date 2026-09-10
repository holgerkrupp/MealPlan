#if os(iOS)
import Foundation
import SwiftData
import OSLog
import WatchConnectivity

/// The phone's half of the watch link.
///
/// It does three things and nothing else:
///
/// * pushes a fresh `WatchPlanSnapshot` whenever the store is saved, as the
///   session's *application context* — the system keeps only the latest one
///   and delivers it in the background, which is exactly right for a screen
///   that always wants the newest state and never a history of it;
/// * answers a watch that asks for a snapshot on its own (first launch, or a
///   watch that has been out of range);
/// * applies check marks made on the wrist back into the store, from where the
///   household's CloudKit sync picks them up like any other local edit.
///
/// Everything the watch shows is derived, so nothing here is authoritative:
/// if the link never works, the app is exactly the app it was before.
@MainActor
final class PhoneWatchSyncService: NSObject {

    static let shared = PhoneWatchSyncService()

    /// Static and `nonisolated` so the delegate callbacks, which arrive off the
    /// main actor, can log without hopping first.
    private nonisolated static let logger = Logger(subsystem: "de.holgerkrupp.mealplan", category: "watch")

    private var context: ModelContext?
    /// Called for the range label under the watch's shopping list. Set by the
    /// app so the watch says "This week" alongside the same lines the phone
    /// built for that week.
    private var shoppingRangeName: (@MainActor () -> String?)?

    private var saveObserver: NSObjectProtocol?
    private var pushTask: Task<Void, Never>?
    /// The last snapshot actually handed to the session, so a burst of saves
    /// that changes nothing the watch shows costs one comparison, not a
    /// transfer.
    private var lastPushed: WatchPlanSnapshot?

    private var session: WCSession? {
        WCSession.isSupported() ? .default : nil
    }

    private override init() { super.init() }

    // MARK: - Lifecycle

    /// Activates the session and starts following the store. Safe to call more
    /// than once; the second call only refreshes the context.
    func start(context: ModelContext, shoppingRangeName: @escaping @MainActor () -> String?) {
        self.context = context
        self.shoppingRangeName = shoppingRangeName

        guard let session else {
            Self.logger.info("WatchConnectivity is not supported on this device")
            return
        }
        if session.delegate !== self {
            session.delegate = self
            session.activate()
        }
        if saveObserver == nil {
            saveObserver = NotificationCenter.default.addObserver(
                forName: ModelContext.didSave,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.schedulePush() }
            }
        }
        schedulePush()
    }

    // MARK: - Pushing

    /// Coalesces the saves that follow a single edit into one transfer.
    func schedulePush() {
        pushTask?.cancel()
        pushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.push()
        }
    }

    /// Builds and sends the snapshot now, skipping the transfer when nothing
    /// the watch shows has changed.
    func push(force: Bool = false) {
        guard let context, let session, session.activationState == .activated else { return }
        #if !targetEnvironment(simulator)
        // A paired watch without the app installed can't be reached at all.
        guard session.isPaired, session.isWatchAppInstalled else { return }
        #endif

        let snapshot = WatchSnapshotBuilder.snapshot(
            context: context,
            shoppingRangeName: shoppingRangeName?()
        )
        if !force, let lastPushed, lastPushed.days == snapshot.days,
           lastPushed.shopping == snapshot.shopping,
           lastPushed.shoppingRangeName == snapshot.shoppingRangeName {
            return
        }
        guard let message = WatchSyncPayload.message(for: snapshot) else { return }
        do {
            try session.updateApplicationContext(message)
            lastPushed = snapshot
        } catch {
            Self.logger.error("Could not send the plan to the watch: \(error.localizedDescription)")
        }
    }

    // MARK: - Receiving

    /// Applies ticks made on the watch. A tick is only about `isChecked`, so
    /// it touches nothing else on the line — and it loses to a newer change
    /// made on the phone, which is what `checkStateModifiedAt` is for.
    private func apply(_ checks: [WatchShoppingCheck]) {
        guard let context, !checks.isEmpty else { return }
        let ids = Set(checks.map(\.id))
        let descriptor = FetchDescriptor<ShoppingListItem>(
            predicate: #Predicate { ids.contains($0.uuid) }
        )
        guard let items = try? context.fetch(descriptor), !items.isEmpty else { return }

        let byID = Dictionary(checks.map { ($0.id, $0) }, uniquingKeysWith: { older, newer in
            older.changedAt >= newer.changedAt ? older : newer
        })

        var changed = false
        for item in items {
            guard let check = byID[item.uuid] else { continue }
            guard check.changedAt > item.checkStateModifiedAt else { continue }
            guard item.isChecked != check.isChecked else { continue }
            item.isChecked = check.isChecked
            item.checkStateModifiedAt = check.changedAt
            item.modifiedAt = check.changedAt
            changed = true
        }
        guard changed else { return }
        try? context.save()
        SharedStore.reloadWidgets()
    }

    /// The main-actor half of a delegate callback, working from values the
    /// callback already decoded — never the dictionary itself, which is not
    /// `Sendable` and belongs to WatchConnectivity's queue.
    private func handle(checks: [WatchShoppingCheck], isRefreshRequest: Bool) {
        if !checks.isEmpty { apply(checks) }
        // A tick already triggers a save, and the save observer a push; only
        // an explicit request needs one forced.
        if isRefreshRequest { push(force: true) }
    }
}

// MARK: - WCSessionDelegate

/// The delegate callbacks arrive on WatchConnectivity's own queue, so each one
/// hops to the main actor before it touches the store.
extension PhoneWatchSyncService: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        if let error {
            Self.logger.error("Watch session did not activate: \(error.localizedDescription)")
            return
        }
        guard activationState == .activated else { return }
        Task { @MainActor in self.push(force: true) }
    }

    /// iOS can be switched to a different watch while the app runs; the old
    /// session has to be torn down and reactivated for the new one.
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.push(force: true) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        deliver(message)
    }

    /// The watch asks with a reply handler so it hears about a failure. The
    /// snapshot itself comes back as an application context rather than in the
    /// reply: building it needs the main actor, and the reply handler cannot
    /// cross to it. Acknowledge here, answer over there.
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        deliver(message)
        replyHandler([:])
    }

    /// The queued, guaranteed-delivery path — how ticks made out of range
    /// eventually arrive.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        deliver(userInfo)
    }

    /// Decodes on the delegate's own queue, then hands the main actor nothing
    /// but plain values.
    private nonisolated func deliver(_ message: [String: Any]) {
        let checks = WatchSyncPayload.checks(in: message)
        let isRefreshRequest = WatchSyncPayload.isRefreshRequest(message)
        guard !checks.isEmpty || isRefreshRequest else { return }
        Task { @MainActor in self.handle(checks: checks, isRefreshRequest: isRefreshRequest) }
    }
}
#endif
