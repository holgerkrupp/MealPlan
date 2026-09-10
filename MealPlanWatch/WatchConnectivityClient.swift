import Foundation
import OSLog
import WatchConnectivity

/// The watch's half of the link to the phone.
///
/// Three paths, each for the job it is actually good at:
///
/// * `applicationContext` — the phone's push. One value, always the latest,
///   delivered even while the watch app is not running.
/// * `sendMessage` — a live request for a fresh snapshot, when the phone is
///   reachable and the user is looking at the screen right now.
/// * `transferUserInfo` — ticks going the other way. Queued and guaranteed, so
///   ticking a line in a shop with the phone left at home still arrives.
///
/// Delegate callbacks come in on WatchConnectivity's own queue with
/// non-`Sendable` dictionaries, so each one decodes what it needs *there* and
/// hands the main actor a plain value — never the session or the dictionary.
final class WatchConnectivityClient: NSObject {

    private static let logger = Logger(subsystem: "de.holgerkrupp.mealplan.watchkitapp", category: "watch")

    override init() { super.init() }

    private var session: WCSession? { WCSession.isSupported() ? .default : nil }

    func activate() {
        guard let session else { return }
        if session.delegate !== self { session.delegate = self }
        if session.activationState != .activated { session.activate() }
        deliverCachedContext(of: session)
    }

    /// The context the phone sent while the app was closed is already waiting
    /// on the session at launch — read it rather than waiting for the next one.
    private func deliverCachedContext(of session: WCSession) {
        guard let snapshot = WatchSyncPayload.snapshot(in: session.receivedApplicationContext) else { return }
        Self.deliver(snapshot)
    }

    private static func deliver(_ snapshot: WatchPlanSnapshot) {
        Task { @MainActor in WatchDataStore.shared.receive(snapshot) }
    }

    private static func deliver(reachable: Bool, thenRefresh: Bool = false) {
        Task { @MainActor in
            WatchDataStore.shared.setReachable(reachable)
            if thenRefresh { WatchDataStore.shared.refresh() }
        }
    }

    // MARK: - Sending

    func requestSnapshot() {
        guard let session, session.activationState == .activated else { return }
        let reachable = session.isReachable
        Self.deliver(reachable: reachable)
        guard reachable else { return }
        session.sendMessage(WatchSyncPayload.refreshRequest) { reply in
            guard let snapshot = WatchSyncPayload.snapshot(in: reply) else { return }
            Self.deliver(snapshot)
        } errorHandler: { error in
            Self.logger.error("Could not ask the phone for the plan: \(error.localizedDescription)")
        }
    }

    /// Sends ticks the queued way, so nothing is lost when the phone is away.
    func send(_ checks: [WatchShoppingCheck]) {
        guard let session, session.activationState == .activated,
              let message = WatchSyncPayload.message(for: checks)
        else { return }
        session.transferUserInfo(message)
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityClient: WCSessionDelegate {

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        if let error {
            Self.logger.error("Watch session did not activate: \(error.localizedDescription)")
            return
        }
        if let snapshot = WatchSyncPayload.snapshot(in: session.receivedApplicationContext) {
            Self.deliver(snapshot)
        }
        Self.deliver(reachable: session.isReachable, thenRefresh: true)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let snapshot = WatchSyncPayload.snapshot(in: applicationContext) else { return }
        Self.deliver(snapshot)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let snapshot = WatchSyncPayload.snapshot(in: message) else { return }
        Self.deliver(snapshot)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Self.deliver(reachable: reachable, thenRefresh: reachable)
    }
}
