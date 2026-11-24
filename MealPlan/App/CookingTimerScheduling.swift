import Foundation
import UserNotifications

#if canImport(AlarmKit) && os(iOS)
import AlarmKit
import ActivityKit
import SwiftUI
#endif

/// The clock used by the cooking session store. Keeping it injectable makes
/// timer restoration and scheduling tests deterministic without changing the
/// persisted representation.
protocol CookingTimerClock: Sendable {
    var now: Date { get }
}

struct SystemCookingTimerClock: CookingTimerClock, Sendable {
    var now: Date { .now }
}

enum CookingTimerAlertPreference: String, CaseIterable, Sendable {
    /// The existing, broadly supported delivery mechanism.
    case localNotifications
    /// Meals-owned AlarmKit alarms on supported iOS versions.
    case alarmKit
}

enum CookingTimerAlertAuthorization: Equatable, Sendable {
    case unavailable
    case notDetermined
    case denied
    case authorized
}

enum CookingTimerDeliveryFailure: String, Equatable, Sendable {
    case unsupported
    case authorizationDenied
    case schedulingFailed
}

/// The delivery path for one timer. A status is scoped to a timer UUID; a
/// platform's display limit can therefore never limit the cooking session.
enum CookingTimerDeliveryStatus: Equatable, Sendable {
    case alarmKit
    case localNotification
    case paused
    case expired
    case unavailable(CookingTimerDeliveryFailure)
}

/// The scheduling boundary shared by the app, App Intents and future system
/// integrations. Implementations must use the timer's stable UUID as their
/// platform identifier and must not create a second countdown engine.
protocol CookingTimerScheduling: Sendable {
    func authorizationStatus() async -> CookingTimerAlertAuthorization
    func schedule(_ timer: CookingTimerState, at date: Date) async -> CookingTimerDeliveryStatus
    func cancel(_ id: UUID) async
    func cancel(_ ids: [UUID]) async
    func reconcile(_ timers: [CookingTimerState], at date: Date) async -> [UUID: CookingTimerDeliveryStatus]
}

enum CookingTimerSchedulingKeys {
    static let alertPreference = "CookingSession.timerAlertPreference.v1"
}

/// Production scheduler. AlarmKit is deliberately opt-in and guarded by the
/// installed SDK/platform. Every failure falls back to a per-UUID local
/// notification when notification authorization permits it.
/// `UserDefaults` is documented as thread-safe, but its SDK annotation is not
/// Sendable. This small boundary wrapper makes that fact explicit when the
/// reference is transferred to the scheduler actor; the session store and the
/// scheduler use the same suite, not a copied preference value.
final class CookingTimerUserDefaultsReference: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}

actor DefaultCookingTimerScheduler: CookingTimerScheduling {
    private let defaults: UserDefaults

    init(defaults: CookingTimerUserDefaultsReference) {
        self.defaults = defaults.value
    }

    var preference: CookingTimerAlertPreference {
        get {
            guard let rawValue = defaults.string(forKey: CookingTimerSchedulingKeys.alertPreference),
                  let preference = CookingTimerAlertPreference(rawValue: rawValue) else {
                return .localNotifications
            }
            return preference
        }
    }

    func authorizationStatus() async -> CookingTimerAlertAuthorization {
        #if canImport(AlarmKit) && os(iOS)
        if preference == .alarmKit {
            return alarmKitAuthorizationStatus(AlarmManager.shared.authorizationState)
        }
        #endif
        return await localNotificationAuthorizationStatus()
    }

    func schedule(_ timer: CookingTimerState, at date: Date) async -> CookingTimerDeliveryStatus {
        guard timer.pausedRemaining == nil else { return .paused }
        let interval = timer.remaining(at: date)
        guard interval > 0 else { return .expired }

        #if canImport(AlarmKit) && os(iOS)
        if preference == .alarmKit {
            let authorization = await requestAlarmKitAuthorizationIfNeeded()
            if authorization == .authorized {
                do {
                    try await scheduleAlarmKit(timer, interval: interval)
                    // A previous fallback may have used the same UUID.
                    cancelLocalNotification(timer.id)
                    return .alarmKit
                } catch {
                    // AlarmKit can reject a schedule because of authorization,
                    // system limits, or a transient platform failure. Keep the
                    // domain timer alive and use the existing fallback.
                    cancelAlarmKit(timer.id)
                }
            }
        }
        #endif

        return await scheduleLocalNotification(timer, interval: interval)
    }

    func cancel(_ id: UUID) async {
        cancelLocalNotification(id)
        #if canImport(AlarmKit) && os(iOS)
        cancelAlarmKit(id)
        #endif
    }

    func cancel(_ ids: [UUID]) async {
        ids.forEach(cancelLocalNotification)
        #if canImport(AlarmKit) && os(iOS)
        ids.forEach(cancelAlarmKit)
        #endif
    }

    func reconcile(_ timers: [CookingTimerState], at date: Date) async -> [UUID: CookingTimerDeliveryStatus] {
        // Reconciliation is intentionally idempotent. Re-adding a local
        // request with its UUID replaces the prior request; AlarmKit requests
        // are cancelled first because schedule() has no update API.
        await cancel(timers.map(\.id))

        var statuses: [UUID: CookingTimerDeliveryStatus] = [:]
        for timer in timers {
            statuses[timer.id] = await schedule(timer, at: date)
        }
        return statuses
    }

    private func localNotificationAuthorizationStatus() async -> CookingTimerAlertAuthorization {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        switch status {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional, .ephemeral:
            return .authorized
        @unknown default:
            return .unavailable
        }
    }

    private func scheduleLocalNotification(
        _ timer: CookingTimerState,
        interval: TimeInterval
    ) async -> CookingTimerDeliveryStatus {
        let center = UNUserNotificationCenter.current()
        var authorization = await localNotificationAuthorizationStatus()
        if authorization == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            authorization = await localNotificationAuthorizationStatus()
        }
        guard authorization == .authorized else {
            return .unavailable(.authorizationDenied)
        }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Cooking timer finished")
        content.body = "\(timer.contextLabel): \(timer.label)"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, interval),
            repeats: false
        )
        do {
            try await center.add(UNNotificationRequest(
                identifier: Self.notificationIdentifier(timer.id),
                content: content,
                trigger: trigger
            ))
            return .localNotification
        } catch {
            return .unavailable(.schedulingFailed)
        }
    }

    private func cancelLocalNotification(_ id: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [Self.notificationIdentifier(id)]
        )
    }

    private static func notificationIdentifier(_ id: UUID) -> String {
        "cooking-timer-\(id.uuidString)"
    }

    #if canImport(AlarmKit) && os(iOS)
    @available(iOS 26.0, *)
    private func alarmKitAuthorizationStatus(
        _ state: AlarmManager.AuthorizationState
    ) -> CookingTimerAlertAuthorization {
        switch state {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .unavailable
        }
    }

    @available(iOS 26.0, *)
    private func requestAlarmKitAuthorizationIfNeeded() async -> CookingTimerAlertAuthorization {
        let manager = AlarmManager.shared
        switch manager.authorizationState {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            do {
                return alarmKitAuthorizationStatus(try await manager.requestAuthorization())
            } catch {
                return .denied
            }
        @unknown default:
            return .unavailable
        }
    }

    @available(iOS 26.0, *)
    private func scheduleAlarmKit(_ timer: CookingTimerState, interval: TimeInterval) async throws {
        let stopButton = AlarmButton(
            text: "Stop",
            textColor: .white,
            systemImageName: "stop.fill"
        )
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: "Cooking timer finished")
        } else {
            alert = AlarmPresentation.Alert(title: "Cooking timer finished", stopButton: stopButton)
        }
        let countdown = AlarmPresentation.Countdown(title: "\(timer.label)")
        let presentation = AlarmPresentation(alert: alert, countdown: countdown)
        let attributes = AlarmAttributes<CookingTimerAlarmMetadata>(
            presentation: presentation,
            metadata: CookingTimerAlarmMetadata(
                timerID: timer.id,
                label: timer.label,
                context: timer.contextLabel
            ),
            tintColor: .orange
        )
        let configuration = AlarmManager.AlarmConfiguration.timer(
            duration: max(1, interval),
            attributes: attributes,
            sound: .default
        )
        _ = try await AlarmManager.shared.schedule(id: timer.id, configuration: configuration)
    }

    @available(iOS 26.0, *)
    private func cancelAlarmKit(_ id: UUID) {
        try? AlarmManager.shared.cancel(id: id)
    }

    private struct CookingTimerAlarmMetadata: AlarmMetadata {
        let timerID: UUID
        let label: String
        let context: String
    }
    #endif
}

enum CookingTimerSchedulerFactory {
    static func make(defaults: UserDefaults) -> any CookingTimerScheduling {
        DefaultCookingTimerScheduler(defaults: CookingTimerUserDefaultsReference(defaults))
    }
}
