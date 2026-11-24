#if os(iOS)
import Foundation
import SwiftData
import OSLog
import WatchConnectivity

enum WatchShoppingCheckAuthorization {
    static func canApply(_ item: ShoppingListItem) -> Bool {
        HouseholdMutationAuthorization.canMutate(household: item.household)
    }
}

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
    private var cookingSessionObserver: NSObjectProtocol?
    private var pushTask: Task<Void, Never>?
    /// The last snapshot actually handed to the session, so a burst of saves
    /// that changes nothing the watch shows costs one comparison, not a
    /// transfer.
    private var lastPushed: WatchPlanSnapshot?
    /// Command IDs are local phone state, not household data. Keeping a small
    /// journal makes a live-message retry followed by queued delivery safe.
    private let commandDefaults = UserDefaults.standard
    private let processedCommandIDsKey = "MealPlan.Watch.processedCookingTimerCommandIDs"

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
        if cookingSessionObserver == nil {
            // CookingSessionStore persists outside SwiftData. Its local
            // UserDefaults write is the only change signal available here
            // without coupling the domain store to WatchConnectivity.
            cookingSessionObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
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

        var snapshot = WatchSnapshotBuilder.snapshot(
            context: context,
            shoppingRangeName: shoppingRangeName?()
        )
        snapshot.cookingSession = WatchSnapshotBuilder.cookingSession(context: context)
        if let cookingSession = snapshot.cookingSession {
            snapshot.cookingTimers = WatchCookingTimersSnapshot(
                sessionID: cookingSession.sessionID,
                revision: cookingSession.revision,
                timers: cookingSession.timers
            )
        }
        if !force, let lastPushed, lastPushed.days == snapshot.days,
           lastPushed.shopping == snapshot.shopping,
           lastPushed.shoppingRangeName == snapshot.shoppingRangeName,
           lastPushed.cookingTimers == snapshot.cookingTimers {
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
    private func apply(_ checks: [WatchShoppingCheck]) -> Bool {
        guard let context, !checks.isEmpty else { return false }
        let ids = Set(checks.map(\.id))
        let descriptor = FetchDescriptor<ShoppingListItem>(
            predicate: #Predicate { ids.contains($0.uuid) }
        )
        guard let items = try? context.fetch(descriptor), !items.isEmpty else { return false }

        let byID = Dictionary(checks.map { ($0.id, $0) }, uniquingKeysWith: { older, newer in
            older.changedAt >= newer.changedAt ? older : newer
        })

        var changed = false
        var rejectedReadOnlyEdit = false
        for item in items {
            guard let check = byID[item.uuid] else { continue }
            guard WatchShoppingCheckAuthorization.canApply(item) else {
                rejectedReadOnlyEdit = true
                continue
            }
            guard check.changedAt > item.checkStateModifiedAt else { continue }
            guard item.isChecked != check.isChecked else { continue }
            item.isChecked = check.isChecked
            item.checkStateModifiedAt = check.changedAt
            item.modifiedAt = check.changedAt
            changed = true
        }
        if changed, (try? context.save()) != nil {
            // The app's sync observer also notices this local save. The
            // generation is needed for a watch write received while the app
            // has no active observer yet, and is safe to coalesce with it.
            HouseholdStoreGeneration.markDirty()
            SharedStore.reloadWidgets()
        }
        return rejectedReadOnlyEdit
    }

    /// The main-actor half of a delegate callback, working from values the
    /// callback already decoded — never the dictionary itself, which is not
    /// `Sendable` and belongs to WatchConnectivity's queue.
    private func handle(
        checks: [WatchShoppingCheck],
        command: WatchCookingTimerCommand?,
        sessionCommand: WatchCookingSessionCommand?,
        isRefreshRequest: Bool,
        replyHandler: WatchReplyHandler? = nil
    ) {
        let rejectedReadOnlyEdit = !checks.isEmpty && apply(checks)
        // A tick already triggers a save, and the save observer a push; only
        // an explicit request or rejected edit needs one forced snapshot.
        if isRefreshRequest || rejectedReadOnlyEdit { push(force: true) }

        guard command != nil || sessionCommand != nil else {
            replyHandler?.call([:])
            return
        }

        let message: [String: Any]?
        if let command {
            let acknowledgement = apply(command: command)
            if acknowledgement.accepted || acknowledgement.revision != nil {
                push(force: true)
            }
            message = WatchSyncPayload.message(for: acknowledgement)
        } else if let sessionCommand {
            let acknowledgement = apply(sessionCommand: sessionCommand)
            if acknowledgement.accepted || acknowledgement.revision != nil {
                push(force: true)
            }
            message = WatchSyncPayload.message(for: acknowledgement)
        } else {
            message = nil
        }
        guard let message else {
            replyHandler?.call([:])
            return
        }
        if let replyHandler {
            replyHandler.call(message)
        } else {
            // Queued commands need a queued acknowledgement. The watch keeps
            // the button pending until this arrives, so offline actions never
            // look successful merely because they were enqueued.
            session?.transferUserInfo(message)
        }
    }

    /// Applies a watch command only at the phone-owned store boundary.
    private func apply(
        command: WatchCookingTimerCommand
    ) -> WatchCookingTimerCommandAcknowledgement {
        let sessionStore = CookingSessionStore.shared
        guard let current = sessionStore.session else {
            return WatchCookingTimerCommandAcknowledgement(
                commandID: command.id,
                timerID: command.timerID,
                accepted: false,
                message: String(localized: "No active cooking session."),
                revision: nil
            )
        }

        if hasProcessedCommand(command.id) {
            return WatchCookingTimerCommandAcknowledgement(
                commandID: command.id,
                timerID: command.timerID,
                accepted: true,
                message: String(localized: "Already applied."),
                revision: current.updatedAt
            )
        }

        // A command based on an older snapshot must not undo a newer phone or
        // watch action. Send the current snapshot so the watch can reconcile.
        guard command.baseRevision >= current.updatedAt else {
            rememberProcessedCommand(command.id)
            return WatchCookingTimerCommandAcknowledgement(
                commandID: command.id,
                timerID: command.timerID,
                accepted: false,
                message: String(localized: "The timer changed on iPhone."),
                revision: current.updatedAt
            )
        }

        guard current.timers.contains(where: { $0.id == command.timerID }) else {
            rememberProcessedCommand(command.id)
            return WatchCookingTimerCommandAcknowledgement(
                commandID: command.id,
                timerID: command.timerID,
                accepted: false,
                message: String(localized: "That timer is no longer active."),
                revision: current.updatedAt
            )
        }

        switch command.action {
        case .pauseOrResume:
            sessionStore.pauseOrResumeTimer(command.timerID, at: .now)
        case .extend:
            sessionStore.extendTimer(command.timerID)
        case .repeatTimer:
            sessionStore.repeatTimer(command.timerID)
        case .cancel:
            sessionStore.cancelTimer(command.timerID)
        }
        rememberProcessedCommand(command.id)
        return WatchCookingTimerCommandAcknowledgement(
            commandID: command.id,
            timerID: command.timerID,
            accepted: true,
            message: nil,
            revision: sessionStore.session?.updatedAt
        )
    }

    /// Applies step navigation and ingredient checkoffs at the phone-owned
    /// session boundary. The watch never mutates or persists a competing
    /// cooking session.
    private func apply(
        sessionCommand command: WatchCookingSessionCommand
    ) -> WatchCookingSessionCommandAcknowledgement {
        let sessionStore = CookingSessionStore.shared
        guard let current = sessionStore.session else {
            return WatchCookingSessionCommandAcknowledgement(
                commandID: command.id,
                sessionID: command.sessionID,
                accepted: false,
                message: String(localized: "No active cooking session."),
                revision: nil
            )
        }

        if hasProcessedCommand(command.id) {
            return WatchCookingSessionCommandAcknowledgement(
                commandID: command.id,
                sessionID: command.sessionID,
                accepted: true,
                message: String(localized: "Already applied."),
                revision: current.updatedAt
            )
        }

        guard command.sessionID == current.id else {
            rememberProcessedCommand(command.id)
            return WatchCookingSessionCommandAcknowledgement(
                commandID: command.id,
                sessionID: command.sessionID,
                accepted: false,
                message: String(localized: "That cooking session is no longer active."),
                revision: current.updatedAt
            )
        }

        guard command.baseRevision >= current.updatedAt else {
            rememberProcessedCommand(command.id)
            return WatchCookingSessionCommandAcknowledgement(
                commandID: command.id,
                sessionID: command.sessionID,
                accepted: false,
                message: String(localized: "The cooking session changed on iPhone."),
                revision: current.updatedAt
            )
        }

        let accepted: Bool
        switch command.action {
        case .handoff:
            accepted = true
        case .selectDish(let dishID):
            guard current.dishes.contains(where: { $0.id == dishID }) else {
                rememberProcessedCommand(command.id)
                return WatchCookingSessionCommandAcknowledgement(
                    commandID: command.id,
                    sessionID: command.sessionID,
                    accepted: false,
                    message: String(localized: "That dish is no longer in the session."),
                    revision: current.updatedAt
                )
            }
            sessionStore.select(dishID)
            accepted = true
        case .setStep(let dishID, let step):
            guard let context,
                  let stepCount = WatchSnapshotBuilder.cookingStepCount(
                      dishID: dishID,
                      context: context
                  ),
                  current.dishes.contains(where: { $0.id == dishID }),
                  step >= 0, step < stepCount else {
                rememberProcessedCommand(command.id)
                return WatchCookingSessionCommandAcknowledgement(
                    commandID: command.id,
                    sessionID: command.sessionID,
                    accepted: false,
                    message: String(localized: "That cooking step is unavailable."),
                    revision: current.updatedAt
                )
            }
            sessionStore.setCurrentStep(step, for: dishID, stepCount: stepCount)
            accepted = true
        case .toggleIngredient(let dishID, let ingredientIndex):
            guard let context,
                  let dish = try? context.fetch(
                      FetchDescriptor<Dish>(predicate: #Predicate { $0.uuid == dishID })
                  ).first,
                  current.dishes.contains(where: { $0.id == dishID }),
                  dish.sortedIngredients.indices.contains(ingredientIndex) else {
                rememberProcessedCommand(command.id)
                return WatchCookingSessionCommandAcknowledgement(
                    commandID: command.id,
                    sessionID: command.sessionID,
                    accepted: false,
                    message: String(localized: "That ingredient is unavailable."),
                    revision: current.updatedAt
                )
            }
            sessionStore.toggleIngredient(ingredientIndex, for: dishID)
            accepted = true
        }

        rememberProcessedCommand(command.id)
        return WatchCookingSessionCommandAcknowledgement(
            commandID: command.id,
            sessionID: command.sessionID,
            accepted: accepted,
            message: nil,
            revision: sessionStore.session?.updatedAt
        )
    }

    private func hasProcessedCommand(_ id: UUID) -> Bool {
        (commandDefaults.stringArray(forKey: processedCommandIDsKey) ?? [])
            .contains(id.uuidString)
    }

    private func rememberProcessedCommand(_ id: UUID) {
        var ids = commandDefaults.stringArray(forKey: processedCommandIDsKey) ?? []
        ids.removeAll { $0 == id.uuidString }
        ids.append(id.uuidString)
        if ids.count > 512 { ids.removeFirst(ids.count - 512) }
        commandDefaults.set(ids, forKey: processedCommandIDsKey)
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
        let checks = WatchSyncPayload.checks(in: message)
        let command = WatchSyncPayload.command(in: message)
        let sessionCommand = WatchSyncPayload.sessionCommand(in: message)
        let isRefreshRequest = WatchSyncPayload.isRefreshRequest(message)
        guard !checks.isEmpty || command != nil || sessionCommand != nil || isRefreshRequest else {
            replyHandler([:])
            return
        }
        let boxedReplyHandler = WatchReplyHandler(replyHandler)
        Task { @MainActor in
            self.handle(
                checks: checks,
                command: command,
                sessionCommand: sessionCommand,
                isRefreshRequest: isRefreshRequest,
                replyHandler: boxedReplyHandler
            )
        }
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
        let command = WatchSyncPayload.command(in: message)
        let sessionCommand = WatchSyncPayload.sessionCommand(in: message)
        let isRefreshRequest = WatchSyncPayload.isRefreshRequest(message)
        guard !checks.isEmpty || command != nil || sessionCommand != nil || isRefreshRequest else { return }
        Task { @MainActor in
            self.handle(
                checks: checks,
                command: command,
                sessionCommand: sessionCommand,
                isRefreshRequest: isRefreshRequest
            )
        }
    }
}

/// WatchConnectivity's reply closure is supplied by a nonisolated delegate
/// callback. This tiny bridge lets the main actor finish the authoritative
/// store mutation before answering without moving WCSession or its dictionary
/// across actor boundaries.
private final class WatchReplyHandler: @unchecked Sendable {
    private let handler: ([String: Any]) -> Void

    init(_ handler: @escaping ([String: Any]) -> Void) {
        self.handler = handler
    }

    func call(_ message: [String: Any]) {
        handler(message)
    }
}
#endif
