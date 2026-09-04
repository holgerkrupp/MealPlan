import Foundation

/// The planning window available before the one-time app unlock.
enum PlanningAccess {
    /// Today is not "in advance", so the free window includes today and the
    /// following seven calendar days. The first locked day is today + 8.
    static let freeDaysAhead = 7

    static func latestFreeDate(now: Date = .now, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: freeDaysAhead, to: today) ?? today
    }

    static func canPlan(
        on date: Date,
        isUnlocked: Bool,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Bool {
        guard !isUnlocked else { return true }
        return calendar.startOfDay(for: date) <= latestFreeDate(now: now, calendar: calendar)
    }
}

/// A small App Group cache lets the Share Extension enforce the same planning
/// window. StoreKit remains the source of truth and the main app refreshes this
/// value whenever it reads an entitlement or completes a purchase.
enum PurchaseEntitlementCache {
    private static let key = "purchase.unlimitedPlanning"

    static var isUnlocked: Bool {
        get {
            #if NO_PAYWALL
            return true
            #else
            if ProcessInfo.processInfo.environment["MEALPLAN_NO_PAYWALL"] == "1" { return true }
            return UserDefaults(suiteName: SharedStore.appGroupID)?.bool(forKey: key) ?? false
            #endif
        }
        set {
            UserDefaults(suiteName: SharedStore.appGroupID)?.set(newValue, forKey: key)
        }
    }
}
