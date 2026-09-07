import Foundation

/// What "publishing" the plan shows for one entry — shared by the one-off
/// `.ics` snapshot export and by writing directly into an EventKit calendar,
/// so both describe the same meal the same way.
extension MealPlanEntry {

    /// "Dinner: Spaghetti Bolognese" — or just the dish/place for an extra,
    /// which already says what it is without repeating its slot.
    func publishedSummary(mealTypesByKey: [String: MealType]) -> String {
        let title = displayTitle
        guard !isExtra else { return title }
        return "\(MealType.publishedName(forKey: mealSlotRaw, mealTypesByKey: mealTypesByKey)): \(title)"
    }

    /// The note, plus — for eating out — the place and its address. `nil`
    /// when there's nothing more to say.
    func publishedNotes() -> String? {
        var parts: [String] = []
        if let note, !note.isEmpty { parts.append(note) }
        if isEatingOut {
            if let placeName, !placeName.isEmpty, placeName != displayTitle { parts.append(placeName) }
            if let placeAddress, !placeAddress.isEmpty { parts.append(placeAddress) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}

extension MealType {
    /// What to call a meal in a published feed. Falls back gracefully for the
    /// "Extra" slot and for a meal key whose `MealType` was since deleted.
    static func publishedName(forKey key: String, mealTypesByKey: [String: MealType]) -> String {
        if isExtra(key) { return extraName }
        if let name = mealTypesByKey[key]?.name, !name.isEmpty { return name }
        return String(localized: "Meal")
    }
}
