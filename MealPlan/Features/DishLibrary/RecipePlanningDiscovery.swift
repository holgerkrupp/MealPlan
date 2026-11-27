import SwiftData
import SwiftUI

extension RecipePlanningContext: Identifiable {
    /// Taken from the value, so a presentation fed by it never re-presents on
    /// a redraw (see the sheet-identity rule).
    var id: Self { self }
}

/// Closes Discover once a recipe found in it has been planned into the slot
/// Discover was opened for, landing the cook back on the plan.
struct FinishRecipePlanningAction: Sendable {
    let action: @MainActor @Sendable () -> Void
    @MainActor func callAsFunction() { action() }
}

extension EnvironmentValues {
    /// The slot Discover was opened for from the plan. Set on the navigation
    /// stack itself, so every pushed shelf, grid and reader sees it.
    @Entry var recipePlanningContext: RecipePlanningContext? = nil
    @Entry var finishRecipePlanning: FinishRecipePlanningAction? = nil
}

/// Discover opened from a meal slot's "Find something new": a sheet on
/// iPhone and iPad, its own window on the Mac.
@MainActor
struct PlanningDiscoveryView: View {
    let planningContext: RecipePlanningContext

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let dismiss = dismiss
        NavigationStack {
            RecipeDiscoveryView(planningContext: planningContext)
                #if os(iOS)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Close"), systemImage: "xmark") { dismiss() }
                    }
                }
                #endif
        }
        .environment(\.recipePlanningContext, planningContext)
        .environment(\.finishRecipePlanning, FinishRecipePlanningAction { dismiss() })
    }
}

/// "Tuesday, 1 December · Dinner" for a planning context, with the meal's
/// own name and symbol.
@MainActor
struct RecipePlanningContextLabel: View {
    let planningContext: RecipePlanningContext

    @Query private var mealTypes: [MealType]

    private var meal: (name: String, symbol: String) {
        if MealType.isExtra(planningContext.mealKey) {
            return (MealType.extraName, MealType.extraSymbolName)
        }
        let match = mealTypes.first { $0.key == planningContext.mealKey }
        return (match?.name ?? "", match?.symbolName ?? "fork.knife")
    }

    /// The sentence a cook reads: which day and which meal.
    var text: String { Self.text(day: planningContext.date, mealName: meal.name) }

    static func text(day: Date, mealName: String) -> String {
        let dayText = day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        return mealName.isEmpty ? dayText : "\(dayText) · \(mealName)"
    }

    var body: some View {
        Label(text, systemImage: meal.symbol)
    }
}
