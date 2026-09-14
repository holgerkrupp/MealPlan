import SwiftUI
import TipKit

/// The app's TipKit tips, and the few rules that decide who sees them.
///
/// Tips are kept for what the interface can't say by itself — gestures
/// (dragging a meal, dropping one dish onto another) and a setting buried in
/// a menu (hands-free cooking). Each one follows the HIG's "Offering help":
/// one or two sentences, a filled symbol, an eligibility rule so it only
/// reaches someone who hasn't found the feature yet, and invalidation the
/// moment they use it. `displayFrequency(.daily)` keeps it to one new tip a
/// day, so the plan never opens under a stack of them.
///
/// Guests (view-only household members) can rearrange nothing, so the views
/// simply don't attach the editing tips for them.
enum MealPlanTips {
    /// Loads the tips datastore. Called once, from `MealPlanApp.init`, before
    /// any view asks a tip whether it may show.
    ///
    /// Two environment switches for checking the tips by hand, in the style
    /// of `MEALPLAN_NO_PAYWALL`: `MEALPLAN_RESET_TIPS=1` starts from a clean
    /// datastore, `MEALPLAN_SHOW_ALL_TIPS=1` ignores every rule and the daily
    /// cadence so all of them are on screen at once.
    static func configure() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["MEALPLAN_RESET_TIPS"] == "1" {
            try? Tips.resetDatastore()
        }
        if environment["MEALPLAN_SHOW_ALL_TIPS"] == "1" {
            Tips.showAllTipsForTesting()
        }
        #endif
        try? Tips.configure([
            .displayFrequency(.daily),
            .datastoreLocation(.applicationDefault),
        ])
    }

    /// Settings → "Show tips again". Tips someone closed or already acted on
    /// become eligible again; their rules and the daily cadence still apply.
    static func resetEligibility() async {
        await MoveMealTip().resetEligibility()
        await DragToPlanTip().resetEligibility()
        await DishVariantsTip().resetEligibility()
        await HandsFreeCookingTip().resetEligibility()
    }

    /// Which tip a successful drop on the plan has made redundant: dragging a
    /// planned meal is the move tip's gesture, dragging a dish in from the
    /// library is the sidebar's.
    enum PlanDrop: Equatable {
        case movedMeal
        case plannedDish
    }

    static func planDrop(for reference: DishReference) -> PlanDrop {
        reference.sourceEntryUUID == nil ? .plannedDish : .movedMeal
    }

    /// Called by every drop target on the plan once it has accepted a drop.
    static func recordAcceptedDrop(_ reference: DishReference) {
        switch planDrop(for: reference) {
        case .movedMeal: MoveMealTip().invalidate(reason: .actionPerformed)
        case .plannedDish: DragToPlanTip().invalidate(reason: .actionPerformed)
        }
    }

    static func updatePlannedMealCount(_ count: Int) {
        MoveMealTip.plannedMealCount = count
    }

    /// A library that already has a variant group has found the gesture, even
    /// if it was on another device or before this version.
    static func updateLibrary(_ dishes: [Dish]) {
        DishVariantsTip.libraryDishCount = dishes.count
        if dishes.contains(where: { $0.variantGroupID != nil }) {
            DishVariantsTip().invalidate(reason: .actionPerformed)
        }
    }

    static func recordVariantsJoined() {
        DishVariantsTip().invalidate(reason: .actionPerformed)
    }

    static func recordCookingModeOpened() {
        HandsFreeCookingTip.cookingModeOpened.sendDonation()
    }

    static func recordVoiceControlTurnedOn() {
        HandsFreeCookingTip().invalidate(reason: .actionPerformed)
    }
}

/// An inline tip that takes no room at all while it isn't showing.
///
/// A bare `TipView` draws nothing once its tip is ineligible, but padding
/// around it would still leave a gap in the layout; this only lays out the
/// padded tip while TipKit says it should display.
@MainActor
struct InlineTip<Content: Tip>: View {
    let tip: Content
    var padding = EdgeInsets()
    var action: @MainActor @Sendable (Tips.Action) -> Void = { _ in }

    @State private var isShowing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if isShowing {
                TipView(tip, action: action)
                    .padding(padding)
                    .transition(.opacity)
            }
        }
        .task {
            for await shows in tip.shouldDisplayUpdates {
                withAnimation(reduceMotion ? nil : .snappy) { isShowing = shows }
            }
        }
    }
}

// MARK: - Plan

/// Planned meals can be dragged to another card or onto a day in the week
/// strip, but nothing on a card says so — the only hint is the long press.
struct MoveMealTip: Tip {
    /// How many meals are planned. Moving one only makes sense once there are
    /// a few to move, so the tip waits for them rather than greeting an empty
    /// plan.
    @Parameter
    static var plannedMealCount: Int = 0

    var title: Text {
        Text("Move a Meal to Another Day")
    }

    var message: Text? {
        #if os(macOS)
        Text("Drag a meal onto another card, or onto a day in the week strip to move it further.")
        #else
        Text("Touch and hold a meal, then drag it onto another card — or onto a day in the week strip to move it further.")
        #endif
    }

    var image: Image? {
        Image(systemName: "hand.draw.fill")
    }

    var rules: [Rule] {
        #Rule(Self.$plannedMealCount) { $0 >= 3 }
    }
}

/// The dish list beside the plan (iPad, Mac, landscape phones) is a drag
/// source. Tapping a row opens the plan sheet, so someone who never drags
/// never learns there's a faster way.
struct DragToPlanTip: Tip {
    var title: Text {
        Text("Plan by Dragging")
    }

    var message: Text? {
        Text("Drag a dish onto a meal card to plan it, or onto a day in the week strip.")
    }

    var image: Image? {
        Image(systemName: "calendar.badge.plus")
    }
}

// MARK: - Dishes

/// Dropping one dish onto another in the library groups them as variants —
/// entirely invisible until someone tries it.
struct DishVariantsTip: Tip {
    /// Size of the library. Variants only become a question once there is a
    /// library to tidy.
    @Parameter
    static var libraryDishCount: Int = 0

    var title: Text {
        Text("Group Variations of a Dish")
    }

    var message: Text? {
        Text("Drag one dish onto another to keep versions of it — like a weeknight and a weekend chili — together in one place.")
    }

    var image: Image? {
        Image(systemName: "square.stack.fill")
    }

    var rules: [Rule] {
        #Rule(Self.$libraryDishCount) { $0 >= 6 }
    }
}

// MARK: - Cooking

/// Voice control is off by default and sits inside the Voice menu. The tip
/// waits for a second cooking session: the first one is busy enough, and by
/// the second it's clear this is a screen used at the stove.
struct HandsFreeCookingTip: Tip {
    static let cookingModeOpened = Tips.Event(id: "cookingModeOpened")

    static let turnOnActionID = "turn-on-voice-control"

    var title: Text {
        Text("Cook Hands-Free")
    }

    var message: Text? {
        Text("Say “next”, “back”, “repeat” or “start timer” to follow the recipe without touching the screen.")
    }

    var image: Image? {
        Image(systemName: "mic.fill")
    }

    var rules: [Rule] {
        #Rule(Self.cookingModeOpened) { $0.donations.count >= 2 }
    }

    var actions: [Action] {
        Action(id: Self.turnOnActionID, title: String(localized: "Turn On Voice Control"))
    }
}
