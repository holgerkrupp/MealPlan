import Foundation

/// The progress for one recipe inside a multi-dish cooking session.
///
/// Ingredient positions are stored instead of model references because a
/// cooking session is short-lived and deliberately lives outside SwiftData.
/// This also lets an interrupted session be decoded before the store opens.
struct CookingDishProgress: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var targetServings: Int
    var currentStep: Int = 0
    var checkedIngredientIndexes: Set<Int> = []
}

/// A timer belongs to both a dish and a step. Keeping that context in the
/// persisted value prevents two simultaneous pots from becoming anonymous on
/// the Lock Screen or after the app relaunches.
struct CookingTimerState: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var dishID: UUID
    var dishName: String
    var stepNumber: Int
    var stepText: String
    var label: String
    var duration: TimeInterval
    var endDate: Date
    var pausedRemaining: TimeInterval?

    func remaining(at date: Date) -> TimeInterval {
        max(0, pausedRemaining ?? endDate.timeIntervalSince(date))
    }

    var contextLabel: String {
        "\(dishName) · \(String(localized: "Step \(stepNumber)"))"
    }
}

/// The complete resumable state of a cooking session.
struct CookingSessionState: Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var startedAt: Date = .now
    var updatedAt: Date = .now
    var selectedDishID: UUID
    var dishes: [CookingDishProgress]
    var timers: [CookingTimerState] = []

    init(dishID: UUID, dishName: String, servings: Int) {
        selectedDishID = dishID
        dishes = [CookingDishProgress(id: dishID, name: dishName, targetServings: max(1, servings))]
    }

    var selectedDish: CookingDishProgress? {
        dishes.first { $0.id == selectedDishID }
    }

    mutating func addDish(id: UUID, name: String, servings: Int) {
        if !dishes.contains(where: { $0.id == id }) {
            dishes.append(CookingDishProgress(id: id, name: name, targetServings: max(1, servings)))
        }
        selectedDishID = id
        touch()
    }

    mutating func selectDish(_ id: UUID) {
        guard dishes.contains(where: { $0.id == id }) else { return }
        selectedDishID = id
        touch()
    }

    mutating func setServings(_ servings: Int, for dishID: UUID) {
        guard let index = dishes.firstIndex(where: { $0.id == dishID }) else { return }
        dishes[index].targetServings = max(1, servings)
        touch()
    }

    mutating func setCurrentStep(_ step: Int, for dishID: UUID, stepCount: Int) {
        guard let index = dishes.firstIndex(where: { $0.id == dishID }) else { return }
        dishes[index].currentStep = min(max(0, step), max(0, stepCount - 1))
        touch()
    }

    mutating func toggleIngredient(_ ingredientIndex: Int, for dishID: UUID) {
        guard let index = dishes.firstIndex(where: { $0.id == dishID }) else { return }
        if dishes[index].checkedIngredientIndexes.contains(ingredientIndex) {
            dishes[index].checkedIngredientIndexes.remove(ingredientIndex)
        } else {
            dishes[index].checkedIngredientIndexes.insert(ingredientIndex)
        }
        touch()
    }

    mutating func addTimer(_ timer: CookingTimerState) {
        timers.append(timer)
        touch()
    }

    mutating func pauseOrResumeTimer(_ id: UUID, at date: Date) -> CookingTimerState? {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return nil }
        if let remaining = timers[index].pausedRemaining {
            timers[index].pausedRemaining = nil
            timers[index].endDate = date.addingTimeInterval(remaining)
        } else {
            timers[index].pausedRemaining = timers[index].remaining(at: date)
        }
        touch()
        return timers[index]
    }

    mutating func removeTimer(_ id: UUID) {
        timers.removeAll { $0.id == id }
        touch()
    }

    private mutating func touch() {
        updatedAt = .now
    }
}
