#if os(macOS)
import SwiftUI
import SwiftData

/// Stable values used to open one macOS window per recipe or planned meal.
/// UUIDs keep the scene restorable without passing SwiftData models between
/// scene hierarchies.
enum MacDetailWindowRoute: Codable, Hashable {
    case recipe(UUID)
    case plannedMeal(UUID)
}

@MainActor
struct MacDetailWindow: View {
    let route: MacDetailWindowRoute

    @ViewBuilder
    var body: some View {
        switch route {
        case .recipe(let id):
            MacRecipeWindow(dishID: id)
        case .plannedMeal(let id):
            MacPlannedMealWindow(entryID: id)
        }
    }
}

@MainActor
private struct MacRecipeWindow: View {
    let dishID: UUID
    @Query private var dishes: [Dish]
    @Environment(\.dismissWindow) private var dismissWindow

    init(dishID: UUID) {
        self.dishID = dishID
        _dishes = Query(filter: #Predicate<Dish> { $0.uuid == dishID })
    }

    var body: some View {
        NavigationStack {
            if let dish = dishes.first {
                DishDetailView(dish: dish) {
                    dismissWindow(value: MacDetailWindowRoute.recipe(dishID))
                }
            } else {
                ContentUnavailableView(
                    String(localized: "Recipe unavailable"),
                    systemImage: "fork.knife",
                    description: Text("This recipe may have been deleted.")
                )
            }
        }
    }
}

@MainActor
private struct MacPlannedMealWindow: View {
    let entryID: UUID
    @Query private var entries: [MealPlanEntry]
    @Environment(\.dismissWindow) private var dismissWindow

    init(entryID: UUID) {
        self.entryID = entryID
        _entries = Query(filter: #Predicate<MealPlanEntry> { $0.uuid == entryID })
    }

    var body: some View {
        if let entry = entries.first {
            EntryQuickActionsSheet(entry: entry) {
                dismissWindow(value: MacDetailWindowRoute.plannedMeal(entryID))
            }
        } else {
            ContentUnavailableView(
                String(localized: "Planned meal unavailable"),
                systemImage: "calendar.badge.exclamationmark",
                description: Text("This planned meal may have been removed.")
            )
        }
    }
}
#endif
