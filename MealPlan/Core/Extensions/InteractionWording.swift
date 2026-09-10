import Foundation

/// Sentences that name the gesture the person actually makes.
///
/// "Tap" is wrong on a Mac and "click" is wrong on a phone, so each of these
/// is written out twice rather than assembled from a verb and a sentence: the
/// whole sentence is the key in `Localizable.xcstrings`, which is what keeps
/// the German translations grammatical.
///
/// Note that macOS-only branches are never picked up by the catalog's
/// extraction pass — their keys are added to `Localizable.xcstrings` by hand.
enum InteractionWording {
    /// Header above the planner strip when planning a dish.
    static var pickASlotToPlan: String {
        #if os(macOS)
        String(localized: "Click a slot to plan it")
        #else
        String(localized: "Tap a slot to plan it")
        #endif
    }

    /// Footer under the planner strip when moving a meal that is already planned.
    static var pickASlotToMove: String {
        #if os(macOS)
        String(localized: "Click a slot to move this meal. The bottom row makes it an extra on that day, outside your usual meals.")
        #else
        String(localized: "Tap a slot to move this meal. The bottom row makes it an extra on that day, outside your usual meals.")
        #endif
    }

    /// How a dish gets onto the plan, in the first-run tour.
    static var fillAMealCard: String {
        #if os(macOS)
        String(localized: "Click a meal to pick a dish, or drag a dish over from the list beside the plan.")
        #else
        String(localized: "Tap a meal to pick a dish, or drag a dish over from the list beside the plan.")
        #endif
    }

    /// VoiceOver hint on a shopping line or a cooking step's ingredient.
    static var checkOffHint: String {
        #if os(macOS)
        String(localized: "Click to check off")
        #else
        String(localized: "Double tap to check off")
        #endif
    }

    /// VoiceOver hint on a step in cooking mode.
    static var jumpToStepHint: String {
        #if os(macOS)
        String(localized: "Click to jump to this step")
        #else
        String(localized: "Double tap to jump to this step")
        #endif
    }
}
