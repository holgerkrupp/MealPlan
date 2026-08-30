import Foundation
import SwiftData
import UserNotifications

/// Local notifications: a daily "tonight's dinner is X" reminder, and an
/// evening-before "don't forget to prep X" for entries the cook flagged.
/// Preferences live in `UserDefaults` (per device — not synced).
@MainActor
final class MealNotificationScheduler {
    static let shared = MealNotificationScheduler()

    private let center = UNUserNotificationCenter.current()
    private let idPrefix = "mealplan."

    enum Keys {
        static let dinnerEnabled = "notify.dinner.enabled"
        static let dinnerHour = "notify.dinner.hour"
    }

    var dinnerEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.dinnerEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.dinnerEnabled) }
    }

    var dinnerHour: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: Keys.dinnerHour)
            return v == 0 ? 16 : v
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.dinnerHour) }
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Rebuild the schedule from the current plan.
    func refreshFromStore(context: ModelContext, now: Date = .now) async {
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) }
        )

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let start = now.startOfDay
        let end = start.adding(days: 14)
        let descriptor = FetchDescriptor<MealPlanEntry>(
            predicate: #Predicate { $0.date >= start && $0.date < end && $0.skipped == false }
        )
        let entries = (try? context.fetch(descriptor)) ?? []
        let calendar = Calendar.current

        if dinnerEnabled {
            let byDay = Dictionary(grouping: entries.filter { $0.slot == .dinner }) { $0.date.startOfDay }
            for (day, dayEntries) in byDay {
                guard let fireDate = calendar.date(bySettingHour: dinnerHour, minute: 0, second: 0, of: day),
                      fireDate > now else { continue }
                let names = dayEntries.map(\.displayTitle).joined(separator: ", ")
                guard !names.isEmpty else { continue }
                schedule(
                    id: "\(idPrefix)dinner.\(day.dayID)",
                    title: String(localized: "Tonight’s dinner"),
                    body: names,
                    at: fireDate,
                    calendar: calendar
                )
            }
        }

        for entry in entries where entry.prepReminder {
            guard let dish = entry.dish else { continue }
            let eveningBefore = entry.date.startOfDay.adding(days: -1)
            guard let fireDate = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: eveningBefore),
                  fireDate > now else { continue }
            schedule(
                id: "\(idPrefix)prep.\(entry.uuid.uuidString)",
                title: String(localized: "Prep reminder"),
                body: String(localized: "Don’t forget to prep “\(dish.name)” for tomorrow."),
                at: fireDate,
                calendar: calendar
            )
        }
    }

    /// Called after the user turns the setting on/changes the time.
    func settingsChanged(context: ModelContext) {
        Task {
            if dinnerEnabled { _ = await requestAuthorization() }
            await refreshFromStore(context: context)
        }
    }

    private func schedule(id: String, title: String, body: String, at date: Date, calendar: Calendar) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
