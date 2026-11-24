import Foundation
import Observation
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif
#if canImport(UIKit)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// App-wide owner for cooking progress. It outlives every cooking sheet and
/// writes after each interaction so a process termination loses no progress.
@Observable
@MainActor
final class CookingSessionStore {
    static let shared = CookingSessionStore()

    private(set) var session: CookingSessionState?
    private(set) var timerDeliveryStatuses: [UUID: CookingTimerDeliveryStatus] = [:]

    private let defaults: UserDefaults
    private let clock: any CookingTimerClock
    private let scheduler: any CookingTimerScheduling
    private let storageKey = "CookingSession.active.v1"
    private var schedulingTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = UserDefaults(suiteName: SharedStore.appGroupID) ?? .standard,
        clock: any CookingTimerClock = SystemCookingTimerClock(),
        scheduler: (any CookingTimerScheduling)? = nil
    ) {
        self.defaults = defaults
        self.clock = clock
        self.scheduler = scheduler ?? CookingTimerSchedulerFactory.make(defaults: defaults)
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(CookingSessionState.self, from: data) {
            session = decoded
            reconcileTimers()
        }
    }

    var hasInterruptedSession: Bool { session != nil }

    var alertPreference: CookingTimerAlertPreference {
        get {
            guard let rawValue = defaults.string(forKey: CookingTimerSchedulingKeys.alertPreference),
                  let preference = CookingTimerAlertPreference(rawValue: rawValue) else {
                return .localNotifications
            }
            return preference
        }
        set {
            defaults.set(newValue.rawValue, forKey: CookingTimerSchedulingKeys.alertPreference)
            reconcileTimers()
        }
    }

    func timerAlertAuthorizationStatus() async -> CookingTimerAlertAuthorization {
        await scheduler.authorizationStatus()
    }

    func begin(with dish: Dish, servings: Int) {
        session = CookingSessionState(
            dishID: dish.uuid,
            dishName: dish.name,
            servings: servings,
            now: clock.now
        )
        timerDeliveryStatuses = [:]
        saveAndRefreshActivity()
    }

    func add(_ dish: Dish, servings: Int) {
        guard session != nil else {
            begin(with: dish, servings: servings)
            return
        }
        session?.addDish(id: dish.uuid, name: dish.name, servings: servings, at: clock.now)
        saveAndRefreshActivity()
    }

    func select(_ dishID: UUID) {
        session?.selectDish(dishID, at: clock.now)
        saveAndRefreshActivity()
    }

    func setServings(_ servings: Int, for dishID: UUID) {
        session?.setServings(servings, for: dishID, at: clock.now)
        saveAndRefreshActivity()
    }

    func setCurrentStep(_ step: Int, for dishID: UUID, stepCount: Int) {
        session?.setCurrentStep(step, for: dishID, stepCount: stepCount, at: clock.now)
        saveAndRefreshActivity()
    }

    func toggleIngredient(_ ingredientIndex: Int, for dishID: UUID) {
        session?.toggleIngredient(ingredientIndex, for: dishID, at: clock.now)
        saveAndRefreshActivity()
    }

    @discardableResult
    func startTimer(
        dishID: UUID,
        dishName: String,
        stepNumber: Int,
        stepText: String,
        label: String,
        duration: TimeInterval
    ) -> UUID? {
        guard session != nil else { return nil }
        let now = clock.now
        let timer = CookingTimerState(
            dishID: dishID,
            dishName: dishName,
            stepNumber: stepNumber,
            stepText: stepText,
            label: label,
            duration: duration,
            endDate: now.addingTimeInterval(max(0.1, duration))
        )
        session?.addTimer(timer, at: now)
        saveAndRefreshActivity()
        schedule(timer)
        return timer.id
    }

    func pauseOrResumeTimer(_ id: UUID, at date: Date) {
        guard let timer = session?.pauseOrResumeTimer(id, at: date) else { return }
        saveAndRefreshActivity()
        if let remaining = timer.pausedRemaining {
            scheduleCancellation(for: id)
        } else {
            schedule(timer)
        }
    }

    func cancelTimer(_ id: UUID) {
        session?.removeTimer(id, at: clock.now)
        timerDeliveryStatuses.removeValue(forKey: id)
        saveAndRefreshActivity()
        scheduleCancellation(for: id)
    }

    /// Finishing is the only action that discards progress. Merely dismissing
    /// a cooking screen deliberately leaves this state intact for resuming.
    func finish() {
        let timerIDs = session?.timers.map(\.id) ?? []
        session = nil
        timerDeliveryStatuses = [:]
        defaults.removeObject(forKey: storageKey)
        scheduleCancellation(for: timerIDs)
        Task { await CookingLiveActivityManager.endAll() }
    }

    /// Reconcile persisted domain timers with platform alerts after relaunch,
    /// foregrounding, or a scheduling permission change. This never mutates
    /// the canonical timer state.
    func reconcileTimers() {
        guard let session else { return }
        let timers = session.timers
        let date = clock.now
        enqueueScheduling { [weak self] scheduler in
            let statuses = await scheduler.reconcile(timers, at: date)
            await MainActor.run { self?.timerDeliveryStatuses = statuses }
        }
    }

    private func saveAndRefreshActivity() {
        if let session, let data = try? JSONEncoder().encode(session) {
            defaults.set(data, forKey: storageKey)
        }
        let session = session
        Task { await CookingLiveActivityManager.refresh(with: session) }
    }

    private func schedule(_ timer: CookingTimerState) {
        let date = clock.now
        enqueueScheduling { [weak self] scheduler in
            let status = await scheduler.schedule(timer, at: date)
            await MainActor.run { self?.timerDeliveryStatuses[timer.id] = status }
        }
    }

    private func scheduleCancellation(for id: UUID) {
        scheduleCancellation(for: [id])
    }

    private func scheduleCancellation(for ids: [UUID]) {
        guard !ids.isEmpty else { return }
        enqueueScheduling { scheduler in await scheduler.cancel(ids) }
    }

    /// Platform scheduling is asynchronous, but user actions are synchronous
    /// MainActor mutations. Serializing adapter calls prevents a fast
    /// start/pause/cancel sequence from allowing an older schedule to win.
    private func enqueueScheduling(
        _ operation: @escaping @Sendable (any CookingTimerScheduling) async -> Void
    ) {
        let previous = schedulingTask
        let scheduler = scheduler
        schedulingTask = Task {
            _ = await previous?.value
            await operation(scheduler)
        }
    }
}

@MainActor
enum CookingLiveActivityManager {
    static func refresh(with session: CookingSessionState?) async {
        #if canImport(ActivityKit) && os(iOS)
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              let session,
              !session.timers.isEmpty else {
            await endAll()
            return
        }
        let state = CookingActivityAttributes.ContentState(
            timers: session.timers.prefix(4).map {
                CookingActivityTimer(
                    id: $0.id,
                    contextLabel: $0.contextLabel,
                    timerLabel: $0.label,
                    endDate: $0.endDate,
                    pausedRemaining: $0.pausedRemaining
                )
            }
        )
        let content = ActivityContent(state: state, staleDate: session.timers.map(\.endDate).max())
        if let activity = Activity<CookingActivityAttributes>.activities.first {
            await activity.update(content)
        } else {
            _ = try? Activity.request(
                attributes: CookingActivityAttributes(sessionID: session.id),
                content: content,
                pushType: nil
            )
        }
        #endif
    }

    static func endAll() async {
        #if canImport(ActivityKit) && os(iOS)
        for activity in Activity<CookingActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        #endif
    }
}

/// Display-awake requests can overlap when sheets or windows transition. A
/// shared reference count prevents one disappearing screen from cancelling
/// another screen's still-active request.
@MainActor
final class DisplayAwakeCoordinator {
    static let shared = DisplayAwakeCoordinator()
    private var requestCount = 0
    #if os(macOS)
    private var activity: NSObjectProtocol?
    #endif

    func acquire() {
        requestCount += 1
        guard requestCount == 1 else { return }
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = true
        #elseif os(macOS)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Cooking with MealPlan"
        )
        #endif
    }

    func release() {
        requestCount = max(0, requestCount - 1)
        guard requestCount == 0 else { return }
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = false
        #elseif os(macOS)
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        #endif
    }
}
