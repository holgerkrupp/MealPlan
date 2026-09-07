import Foundation

/// One planned meal, ready to become a calendar event.
///
/// Deliberately `Sendable` and free of SwiftData — it's how a plan built on
/// the main actor from `MealPlanEntry` objects crosses into the actor that
/// talks to EventKit, which may never see a `@Model` instance.
struct MealPlanPublishPayload: Sendable, Equatable, Identifiable {
    var id: UUID { uuid }
    let uuid: UUID
    /// Start of the day this meal is planned for; the event is all-day.
    let date: Date
    let title: String
    let notes: String?
}

enum MealPlanPublishPayloadBuilder {
    /// Builds one payload per entry, sorted the way the plan reads: by day,
    /// then by the same order the day's meals are shown in.
    static func payloads(for entries: [MealPlanEntry], mealTypesByKey: [String: MealType]) -> [MealPlanPublishPayload] {
        entries
            .sorted { $0.date != $1.date ? $0.date < $1.date : $0.sortIndex < $1.sortIndex }
            .map {
                MealPlanPublishPayload(
                    uuid: $0.uuid,
                    date: $0.date.startOfDay,
                    title: $0.publishedSummary(mealTypesByKey: mealTypesByKey),
                    notes: $0.publishedNotes()
                )
            }
    }
}
