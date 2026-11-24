import Foundation

/// The recipe content needed for a glanceable cooking session. The watch
/// receives value snapshots rather than opening the household SwiftData store.
struct WatchCookingStep: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var text: String
}

struct WatchCookingIngredient: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    /// The position is the stable command address used by CookingSessionState.
    var index: Int
    var name: String
    var amount: String?
    var note: String?
    var isChecked: Bool
}

struct WatchCookingDish: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var targetServings: Int
    var currentStep: Int
    var steps: [WatchCookingStep]
    var ingredients: [WatchCookingIngredient]

    var currentStepText: String? {
        guard steps.indices.contains(currentStep) else { return nil }
        return steps[currentStep].text
    }
}

/// A complete, resumable cooking handoff. `revision` is the persisted
/// CookingSessionState timestamp, not a watch-local clock, so old deliveries
/// cannot undo a newer phone or watch edit.
struct WatchCookingSessionSnapshot: Codable, Hashable, Sendable {
    var sessionID: UUID
    var revision: Date
    var selectedDishID: UUID
    var dishes: [WatchCookingDish]
    var timers: [WatchCookingTimer]

    var selectedDish: WatchCookingDish? {
        dishes.first { $0.id == selectedDishID }
    }
}

enum WatchCookingSessionAction: Codable, Hashable, Sendable {
    case selectDish(UUID)
    case setStep(dishID: UUID, step: Int)
    case toggleIngredient(dishID: UUID, ingredientIndex: Int)
    /// Requests a current snapshot. This makes the phone → watch handoff
    /// explicit while keeping the phone the only owner of session state.
    case handoff
}

struct WatchCookingSessionCommand: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var sessionID: UUID
    var action: WatchCookingSessionAction
    var baseRevision: Date
    var issuedAt: Date

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        action: WatchCookingSessionAction,
        baseRevision: Date,
        issuedAt: Date = .now
    ) {
        self.id = id
        self.sessionID = sessionID
        self.action = action
        self.baseRevision = baseRevision
        self.issuedAt = issuedAt
    }
}

struct WatchCookingSessionCommandAcknowledgement: Codable, Hashable, Sendable {
    var commandID: UUID
    var sessionID: UUID
    var accepted: Bool
    var message: String?
    var revision: Date?
}

/// Pure ordering policy shared by the watch store and its deterministic tests.
enum WatchCookingSessionReconciler {
    static func shouldApply(
        incoming: WatchCookingSessionSnapshot?,
        over current: WatchCookingSessionSnapshot?
    ) -> Bool {
        guard let incoming else { return true }
        guard let current else { return true }
        // A new session is a deliberate handoff. For the same session, only
        // the persisted revision determines freshness.
        guard incoming.sessionID == current.sessionID else { return true }
        return incoming.revision >= current.revision
    }
}
