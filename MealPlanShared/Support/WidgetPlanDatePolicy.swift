import Foundation

/// The Today widget starts showing tomorrow at the configured evening rollover
/// and keeps doing so after midnight until the next day's timeline refresh.
enum WidgetPlanDatePolicy {
    static func todayIndex(
        at reference: Date,
        relativeTo baseDate: Date,
        rolloverHour: Int,
        calendar: Calendar = .current
    ) -> Int {
        let offset = calendar.dateComponents(
            [.day],
            from: baseDate.startOfDay,
            to: reference.startOfDay
        ).day ?? 0
        let isSameDayAfterRollover = offset == 0
            && calendar.component(.hour, from: reference) >= rolloverHour
        return max(0, offset + (isSameDayAfterRollover ? 1 : 0))
    }
}

enum WidgetPlanAvailability: Hashable {
    case available
    case unavailable
}

enum WidgetPlanContentState: Equatable {
    case unavailable
    case empty
    case planned

    static func resolve(availability: WidgetPlanAvailability, hasMeals: Bool) -> Self {
        guard availability == .available else { return .unavailable }
        return hasMeals ? .planned : .empty
    }
}
