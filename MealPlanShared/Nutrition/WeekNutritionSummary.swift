import Foundation

/// How a day's estimate sits next to the rest of its week.
///
/// This exists because the useful question while planning is not "how many
/// calories is that" — nobody can answer that from a number in isolation, and
/// MealPlan has no business setting anyone a daily target. It is "is Sunday
/// heavier than the rest of this week, so should Monday be light?". A day is
/// therefore compared against the median of the other planned days, and
/// nothing else.
enum NutritionDayStanding: Sendable, Equatable {
    case lighter
    case typical
    case heavier

    var localizedName: String {
        switch self {
        case .lighter: String(localized: "Lighter than this week")
        case .typical: String(localized: "About average for this week")
        case .heavier: String(localized: "Heavier than this week")
        }
    }

    var symbolName: String {
        switch self {
        case .lighter: "arrow.down"
        case .typical: "equal"
        case .heavier: "arrow.up"
        }
    }
}

/// Per-day estimates for one week, plus where each day stands in it.
struct WeekNutritionSummary: Sendable {

    /// Estimates keyed by `Date.dayID`, so lookups don't depend on calendars.
    private var estimates: [String: NutritionEstimate]
    private var standings: [String: NutritionDayStanding]

    /// A day has to differ from the week's middle by this much before it is
    /// worth pointing out. Under a fifth is well inside the error the estimate
    /// carries anyway, and a badge that flickers between "lighter" and
    /// "heavier" as a recipe is edited would be noise, not information.
    static let deviation = 0.2

    /// Fewer comparable days than this and "for this week" means nothing.
    static let minimumComparableDays = 3

    init(estimatesByDayID: [String: NutritionEstimate]) {
        self.estimates = estimatesByDayID

        let comparable = estimatesByDayID
            .filter { $0.value.isTrustworthy && $0.value.facts.energyKcal > 0 }
        guard comparable.count >= Self.minimumComparableDays,
              let middle = Self.median(comparable.values.map(\.facts.energyKcal)),
              middle > 0
        else {
            self.standings = [:]
            return
        }

        var result: [String: NutritionDayStanding] = [:]
        for (dayID, estimate) in comparable {
            let ratio = estimate.facts.energyKcal / middle
            result[dayID] = if ratio > 1 + Self.deviation {
                .heavier
            } else if ratio < 1 - Self.deviation {
                .lighter
            } else {
                .typical
            }
        }
        self.standings = result
    }

    /// Build from the week's planned meals. Entries for other weeks are
    /// harmless — they simply become days of their own.
    init(entries: [MealPlanEntry]) {
        var byDay: [String: [MealPlanEntry]] = [:]
        for entry in entries {
            byDay[entry.date.dayID, default: []].append(entry)
        }
        self.init(estimatesByDayID: byDay.mapValues { NutritionEstimator.perPerson(for: $0) })
    }

    func estimate(on day: Date) -> NutritionEstimate? {
        estimates[day.dayID]
    }

    /// `nil` when the week is too thin to compare against, which is the normal
    /// state of a half-planned week and must not be dressed up as "average".
    func standing(on day: Date) -> NutritionDayStanding? {
        standings[day.dayID]
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
