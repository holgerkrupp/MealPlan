import Foundation

/// The app's own view of Calendar authorization.
///
/// Deliberately free of EventKit so the planner, the settings UI and the tests
/// can reason about permission without importing (or linking) EventKit.
enum CalendarAuthorization: String, Sendable, Equatable, CaseIterable {
    /// The user has never been asked. The only state in which the app may
    /// trigger Apple's permission dialog.
    case notDetermined
    /// Full access — the only state in which events can be read.
    case fullAccess
    /// EventKit granted write-only access. The app never writes to Calendar,
    /// so this is as good as no access for this feature.
    case writeOnly
    case denied
    case restricted
    /// A state this build doesn't know about (or EventKit was unavailable).
    /// Treated exactly like `denied`.
    case unknown

    /// Whether calendar context can be produced at all.
    var canReadEvents: Bool { self == .fullAccess }

    /// Whether asking again could still show the system dialog. Anything else
    /// must be resolved by the user in system Settings — the app must never
    /// re-trigger the request.
    var canRequestAccess: Bool { self == .notDetermined }

    /// Whether the only way forward is the system Settings app.
    var needsSystemSettings: Bool {
        switch self {
        case .denied, .restricted, .writeOnly, .unknown: true
        case .notDetermined, .fullAccess: false
        }
    }

    /// Short explanation shown in Settings for the states that block the
    /// feature. `nil` when there is nothing to explain.
    var localizedExplanation: String? {
        switch self {
        case .fullAccess:
            nil
        case .notDetermined:
            String(localized: "MealPlan hasn’t asked for Calendar access yet.")
        case .writeOnly:
            String(localized: "MealPlan may only add to your calendar, which isn’t enough to show scheduling context. Allow full Calendar access in Settings to use this feature.")
        case .denied:
            String(localized: "Calendar access is turned off for MealPlan. You can allow it in Settings.")
        case .restricted:
            String(localized: "Calendar access isn’t available on this device.")
        case .unknown:
            String(localized: "Calendar access isn’t available right now.")
        }
    }
}
