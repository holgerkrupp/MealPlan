import Foundation
import Observation
import UserNotifications
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
    private(set) var session: CookingSessionState?

    private let defaults: UserDefaults
    private let storageKey = "CookingSession.active.v1"

    init(defaults: UserDefaults = UserDefaults(suiteName: SharedStore.appGroupID) ?? .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(CookingSessionState.self, from: data) {
            session = decoded
        }
    }

    var hasInterruptedSession: Bool { session != nil }

    func begin(with dish: Dish, servings: Int) {
        session = CookingSessionState(dishID: dish.uuid, dishName: dish.name, servings: servings)
        saveAndRefreshActivity()
    }

    func add(_ dish: Dish, servings: Int) {
        guard session != nil else {
            begin(with: dish, servings: servings)
            return
        }
        session?.addDish(id: dish.uuid, name: dish.name, servings: servings)
        saveAndRefreshActivity()
    }

    func select(_ dishID: UUID) {
        session?.selectDish(dishID)
        saveAndRefreshActivity()
    }

    func setServings(_ servings: Int, for dishID: UUID) {
        session?.setServings(servings, for: dishID)
        saveAndRefreshActivity()
    }

    func setCurrentStep(_ step: Int, for dishID: UUID, stepCount: Int) {
        session?.setCurrentStep(step, for: dishID, stepCount: stepCount)
        saveAndRefreshActivity()
    }

    func toggleIngredient(_ ingredientIndex: Int, for dishID: UUID) {
        session?.toggleIngredient(ingredientIndex, for: dishID)
        saveAndRefreshActivity()
    }

    func startTimer(
        dishID: UUID,
        dishName: String,
        stepNumber: Int,
        stepText: String,
        label: String,
        duration: TimeInterval
    ) {
        let timer = CookingTimerState(
            dishID: dishID,
            dishName: dishName,
            stepNumber: stepNumber,
            stepText: stepText,
            label: label,
            duration: duration,
            endDate: .now.addingTimeInterval(duration)
        )
        session?.addTimer(timer)
        saveAndRefreshActivity()
        Task { await CookingTimerNotifier.schedule(timer) }
    }

    func pauseOrResumeTimer(_ id: UUID, at date: Date) {
        guard let timer = session?.pauseOrResumeTimer(id, at: date) else { return }
        saveAndRefreshActivity()
        if let remaining = timer.pausedRemaining {
            CookingTimerNotifier.cancel(id)
            _ = remaining
        } else {
            Task { await CookingTimerNotifier.schedule(timer, after: timer.remaining(at: date)) }
        }
    }

    func cancelTimer(_ id: UUID) {
        session?.removeTimer(id)
        saveAndRefreshActivity()
        CookingTimerNotifier.cancel(id)
    }

    /// Finishing is the only action that discards progress. Merely dismissing
    /// a cooking screen deliberately leaves this state intact for resuming.
    func finish() {
        let timerIDs = session?.timers.map(\.id) ?? []
        session = nil
        defaults.removeObject(forKey: storageKey)
        CookingTimerNotifier.cancel(timerIDs)
        Task { await CookingLiveActivityManager.endAll() }
    }

    private func saveAndRefreshActivity() {
        if let session, let data = try? JSONEncoder().encode(session) {
            defaults.set(data, forKey: storageKey)
        }
        let session = session
        Task { await CookingLiveActivityManager.refresh(with: session) }
    }
}

enum CookingTimerNotifier {
    static func schedule(_ timer: CookingTimerState, after interval: TimeInterval? = nil) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Cooking timer finished")
        content.body = "\(timer.contextLabel): \(timer.label)"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, interval ?? timer.duration), repeats: false
        )
        try? await center.add(UNNotificationRequest(
            identifier: identifier(timer.id), content: content, trigger: trigger
        ))
    }

    static func cancel(_ id: UUID) {
        cancel([id])
    }

    static func cancel(_ ids: [UUID]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ids.map(identifier)
        )
    }

    private static func identifier(_ id: UUID) -> String { "cooking-timer-\(id.uuidString)" }
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
