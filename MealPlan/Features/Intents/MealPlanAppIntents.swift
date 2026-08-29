import AppIntents
import SwiftData
import Foundation

// MARK: - Add Dish

struct AddDishIntent: AppIntent {
    static var title: LocalizedStringResource { "Add Dish to MealPlan" }
    static var description: IntentDescription {
        IntentDescription("Adds a dish by name, or imports one from a recipe link.")
    }

    @Parameter(title: "Name") var name: String?
    @Parameter(title: "Recipe link") var url: URL?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$name) to MealPlan") { \.$url }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = ModelContext(SharedStore.container(cloudKit: false))
        let household = try? context.fetch(FetchDescriptor<Household>()).first
        let member = DeviceOwner.name

        let dish: Dish
        if let url {
            var recipe = try? await RecipeSchemaParser().importRecipe(from: url)
            if recipe == nil {
                recipe = try? await StubRecipeImporter().importRecipe(from: url)
            }
            let resolved = recipe ?? ImportedRecipe(name: url.host() ?? "Recipe", sourceURL: url)
            dish = DishBuilder.makeDish(from: resolved, household: household, createdByName: member, context: context)
        } else {
            let title = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw $name.needsValueError("What should the dish be called?") }
            dish = Dish(name: title)
            dish.household = household
            dish.createdByName = member
            context.insert(dish)
            try? context.save()
        }
        SharedStore.reloadWidgets()
        return .result(dialog: "Added “\(dish.name)” to MealPlan.")
    }
}

// MARK: - Plan Meal for Date

struct PlanMealIntent: AppIntent {
    static var title: LocalizedStringResource { "Plan Meal for Date" }
    static var description: IntentDescription { IntentDescription("Schedules a dish on a day and meal.") }

    @Parameter(title: "Dish") var dish: DishEntity
    @Parameter(title: "Date") var date: Date
    @Parameter(title: "Meal") var slot: MealSlotAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("Plan \(\.$dish) for \(\.$slot) on \(\.$date)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = ModelContext(SharedStore.container(cloudKit: false))
        let household = try? context.fetch(FetchDescriptor<Household>()).first
        let target = dish.id
        guard let model = try context.fetch(FetchDescriptor<Dish>(predicate: #Predicate { $0.uuid == target })).first else {
            throw $dish.needsValueError("That dish isn’t in your library.")
        }
        MealPlanner.plan(
            dish: model, on: date, slot: slot.slot,
            household: household, memberName: DeviceOwner.name, context: context
        )
        return .result(dialog: "Planned “\(model.name)” for \(slot.slot.localizedName).")
    }
}

// MARK: - This Week's Plan

struct ThisWeekPlanIntent: AppIntent {
    static var title: LocalizedStringResource { "Get This Week’s Meal Plan" }
    static var description: IntentDescription { IntentDescription("Returns the meals planned for the current week.") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let context = ModelContext(SharedStore.container(cloudKit: false))
        let start = Date.now.startOfWeek()
        let end = start.adding(weeks: 1)
        let entries = try context.fetch(FetchDescriptor<MealPlanEntry>(
            predicate: #Predicate { $0.date >= start && $0.date < end && $0.skipped == false },
            sortBy: [SortDescriptor(\.date), SortDescriptor(\.sortIndex)]
        ))
        guard !entries.isEmpty else {
            return .result(value: "", dialog: "Nothing is planned for this week yet.")
        }
        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate("EEEEd")
        let text = entries.map { entry in
            "\(df.string(from: entry.date)) – \(entry.slot.localizedName): \(entry.dish?.name ?? "—")"
        }.joined(separator: "\n")
        return .result(value: text, dialog: "Here’s this week’s plan.")
    }
}

// MARK: - Meal slot as an App Enum

enum MealSlotAppEnum: String, AppEnum {
    case breakfast, lunch, dinner, snack

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Meal" }
    static var caseDisplayRepresentations: [MealSlotAppEnum: DisplayRepresentation] {
        [.breakfast: "Breakfast", .lunch: "Lunch", .dinner: "Dinner", .snack: "Snack"]
    }

    var slot: MealSlot { MealSlot(rawValue: rawValue) ?? .dinner }
}

// MARK: - Shortcuts

struct MealPlanShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddDishIntent(),
            phrases: ["Add a dish to \(.applicationName)", "New dish in \(.applicationName)"],
            shortTitle: "Add Dish",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: ThisWeekPlanIntent(),
            phrases: ["What's for dinner in \(.applicationName)", "Show this week's plan in \(.applicationName)"],
            shortTitle: "This Week’s Plan",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: PlanMealIntent(),
            phrases: ["Plan a meal in \(.applicationName)"],
            shortTitle: "Plan Meal",
            systemImageName: "calendar.badge.plus"
        )
    }
}
