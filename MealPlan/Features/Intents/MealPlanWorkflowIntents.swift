import AppIntents
import Foundation
import SwiftData

// MARK: - Value entities

/// A shopping row snapshot. App Intents never hands a SwiftData model object
/// to Siri or Shortcuts; the UUID is the only identity crossing that boundary.
struct ShoppingListItemEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Shopping Item" }
    static var defaultQuery: ShoppingListItemEntityQuery { ShoppingListItemEntityQuery() }

    let id: UUID
    @Property(title: "Name") var name: String
    @Property(title: "Amount") var amount: String
    @Property(title: "Category") var category: String
    @Property(title: "Aisle") var aisle: String
    @Property(title: "Checked") var isChecked: Bool
    @Property(title: "Manual") var isManual: Bool

    init(item: ShoppingListItem) {
        id = item.uuid
        name = item.name
        amount = item.displayText ?? ""
        category = item.category.localizedName
        aisle = item.aisleName
        isChecked = item.isChecked
        isManual = item.isManual
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(amount.isEmpty ? aisle : "\(amount) · \(aisle)")",
            image: .init(systemName: isChecked ? "checkmark.circle" : "cart")
        )
    }
}

struct ShoppingListItemEntityQuery: EnumerableEntityQuery, EntityStringQuery {
    @MainActor
    private func items() throws -> [ShoppingListItem] {
        try MealPlanIntentStore.context.fetch(
            FetchDescriptor<ShoppingListItem>(sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.name)])
        )
    }

    @MainActor
    func allEntities() async throws -> [ShoppingListItemEntity] {
        try items().map(ShoppingListItemEntity.init)
    }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ShoppingListItemEntity] {
        try items().filter { identifiers.contains($0.uuid) }.map(ShoppingListItemEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [ShoppingListItemEntity] {
        try items()
            .sorted {
                if $0.isChecked != $1.isChecked { return !$0.isChecked }
                return $0.sortIndex < $1.sortIndex
            }
            .prefix(30)
            .map(ShoppingListItemEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [ShoppingListItemEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return try items()
            .filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.aisleName.localizedCaseInsensitiveContains(query)
                    || ($0.displayText ?? "").localizedCaseInsensitiveContains(query)
            }
            .sorted {
                if $0.isChecked != $1.isChecked { return !$0.isChecked }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            .map(ShoppingListItemEntity.init)
    }
}

struct IngredientEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Ingredient" }
    static var defaultQuery: IngredientEntityQuery { IngredientEntityQuery() }

    let id: UUID
    @Property(title: "Name") var name: String
    @Property(title: "Category") var category: String
    @Property(title: "Inventory") var inventory: String
    @Property(title: "Storage location") var storageLocation: String
    @Property(title: "Pantry staple") var isPantryStaple: Bool

    init(ingredient: Ingredient) {
        id = ingredient.uuid
        name = ingredient.name
        category = ingredient.category.localizedName
        inventory = ingredient.inventoryMode.localizedName
        storageLocation = ingredient.inventoryStorageLocationRaw ?? ""
        isPantryStaple = ingredient.isPantryStaple
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(inventory)\(storageLocation.isEmpty ? "" : " · \(storageLocation)")",
            image: .init(systemName: "shippingbox")
        )
    }
}

struct IngredientEntityQuery: EnumerableEntityQuery, EntityStringQuery {
    @MainActor
    private func ingredients() throws -> [Ingredient] {
        try MealPlanIntentStore.context.fetch(
            FetchDescriptor<Ingredient>(sortBy: [SortDescriptor(\.name)])
        )
    }

    @MainActor
    func allEntities() async throws -> [IngredientEntity] {
        try ingredients().map(IngredientEntity.init)
    }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [IngredientEntity] {
        try ingredients().filter { identifiers.contains($0.uuid) }.map(IngredientEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [IngredientEntity] {
        try ingredients().prefix(40).map(IngredientEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [IngredientEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return try ingredients().filter { ingredient in
            ingredient.name.localizedCaseInsensitiveContains(query)
                || (ingredient.aliases ?? []).contains {
                    $0.name.localizedCaseInsensitiveContains(query)
                }
        }.map(IngredientEntity.init)
    }
}

struct MealRoutineEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Meal Routine" }
    static var defaultQuery: MealRoutineEntityQuery { MealRoutineEntityQuery() }

    let id: UUID
    @Property(title: "Dish") var dishName: String
    @Property(title: "Meal") var mealName: String
    @Property(title: "Schedule") var schedule: String
    @Property(title: "Active") var isActive: Bool

    @MainActor
    init(routine: MealRoutine) {
        id = routine.uuid
        dishName = routine.dish?.name ?? String(localized: "No dish")
        mealName = MealPlanIntentStore.mealTypes().first { $0.key == routine.mealKey }?.name
            ?? MealType.legacyName(for: routine.mealKey)
        schedule = routine.scheduleDescription
        isActive = routine.isActive
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(dishName)",
            subtitle: "\(schedule) · \(mealName)",
            image: .init(systemName: isActive ? "repeat" : "pause.circle")
        )
    }
}

struct MealRoutineEntityQuery: EnumerableEntityQuery, EntityStringQuery {
    @MainActor
    private func routines() throws -> [MealRoutine] {
        try MealPlanIntentStore.context.fetch(
            FetchDescriptor<MealRoutine>(sortBy: [SortDescriptor(\.dateCreated)])
        )
    }

    @MainActor
    func allEntities() async throws -> [MealRoutineEntity] { try routines().map(MealRoutineEntity.init) }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [MealRoutineEntity] {
        try routines().filter { identifiers.contains($0.uuid) }.map(MealRoutineEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [MealRoutineEntity] { try routines().map(MealRoutineEntity.init) }

    @MainActor
    func entities(matching string: String) async throws -> [MealRoutineEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return try routines().filter {
            ($0.dish?.name ?? "").localizedCaseInsensitiveContains(query)
                || $0.scheduleDescription.localizedCaseInsensitiveContains(query)
                || $0.mealKey.localizedCaseInsensitiveContains(query)
        }.map(MealRoutineEntity.init)
    }
}

struct WeekTemplateEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Week Template" }
    static var defaultQuery: WeekTemplateEntityQuery { WeekTemplateEntityQuery() }

    let id: UUID
    @Property(title: "Name") var name: String
    @Property(title: "Meals") var mealCount: Int

    init(template: WeekTemplate) {
        id = template.uuid
        name = template.name
        mealCount = template.sortedEntries.count
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(mealCount) meals", image: .init(systemName: "square.on.square"))
    }
}

struct WeekTemplateEntityQuery: EnumerableEntityQuery, EntityStringQuery {
    @MainActor
    private func templates() throws -> [WeekTemplate] {
        try MealPlanIntentStore.context.fetch(
            FetchDescriptor<WeekTemplate>(sortBy: [SortDescriptor(\.name)])
        )
    }

    @MainActor
    func allEntities() async throws -> [WeekTemplateEntity] { try templates().map(WeekTemplateEntity.init) }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [WeekTemplateEntity] {
        try templates().filter { identifiers.contains($0.uuid) }.map(WeekTemplateEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [WeekTemplateEntity] { try templates().map(WeekTemplateEntity.init) }

    @MainActor
    func entities(matching string: String) async throws -> [WeekTemplateEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return try templates().filter { $0.name.localizedCaseInsensitiveContains(query) }.map(WeekTemplateEntity.init)
    }
}

struct CookingTimerEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Cooking Timer" }
    static var defaultQuery: CookingTimerEntityQuery { CookingTimerEntityQuery() }

    let id: UUID
    @Property(title: "Label") var label: String
    @Property(title: "Dish") var dishName: String
    @Property(title: "Remaining seconds") var remainingSeconds: Double
    @Property(title: "Paused") var isPaused: Bool

    init(timer: CookingTimerState, now: Date = .now) {
        id = timer.id
        label = timer.label
        dishName = timer.dishName
        remainingSeconds = timer.remaining(at: now)
        isPaused = timer.pausedRemaining != nil
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(label)", subtitle: "\(dishName)", image: .init(systemName: "timer"))
    }
}

struct CookingTimerEntityQuery: EnumerableEntityQuery, EntityStringQuery {
    @MainActor
    private func timers() -> [CookingTimerState] { CookingSessionStore.shared.session?.timers ?? [] }

    @MainActor
    func allEntities() async throws -> [CookingTimerEntity] { timers().map { CookingTimerEntity(timer: $0) } }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [CookingTimerEntity] {
        timers().filter { identifiers.contains($0.id) }.map { CookingTimerEntity(timer: $0) }
    }

    @MainActor
    func suggestedEntities() async throws -> [CookingTimerEntity] { timers().map { CookingTimerEntity(timer: $0) } }

    @MainActor
    func entities(matching string: String) async throws -> [CookingTimerEntity] {
        timers().filter { $0.label.localizedCaseInsensitiveContains(string) }.map { CookingTimerEntity(timer: $0) }
    }
}

// MARK: - Shared intent helpers

enum MealPlanWorkflowIntentSupport {
    @MainActor
    static func shoppingItem(for entity: ShoppingListItemEntity) throws -> ShoppingListItem {
        let id = entity.id
        guard let item = try MealPlanIntentStore.context.fetch(FetchDescriptor<ShoppingListItem>(
            predicate: #Predicate { $0.uuid == id }
        )).first else {
            throw NSError(domain: "MealPlan.AppIntents", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "That shopping item no longer exists.")])
        }
        return item
    }

    @MainActor
    static func ingredient(for entity: IngredientEntity) throws -> Ingredient {
        let id = entity.id
        guard let ingredient = try MealPlanIntentStore.context.fetch(FetchDescriptor<Ingredient>(
            predicate: #Predicate { $0.uuid == id }
        )).first else {
            throw NSError(domain: "MealPlan.AppIntents", code: 21,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "That ingredient no longer exists.")])
        }
        return ingredient
    }

    @MainActor
    static func routine(for entity: MealRoutineEntity) throws -> MealRoutine {
        let id = entity.id
        guard let routine = try MealPlanIntentStore.context.fetch(FetchDescriptor<MealRoutine>(
            predicate: #Predicate { $0.uuid == id }
        )).first else {
            throw NSError(domain: "MealPlan.AppIntents", code: 22,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "That meal routine no longer exists.")])
        }
        return routine
    }

    @MainActor
    static func template(for entity: WeekTemplateEntity) throws -> WeekTemplate {
        let id = entity.id
        guard let template = try MealPlanIntentStore.context.fetch(FetchDescriptor<WeekTemplate>(
            predicate: #Predicate { $0.uuid == id }
        )).first else {
            throw NSError(domain: "MealPlan.AppIntents", code: 23,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "That week template no longer exists.")])
        }
        return template
    }

    @MainActor
    static func activeHousehold() throws -> Household {
        guard let household = MealPlanIntentStore.household() else {
            throw NSError(domain: "MealPlan.AppIntents", code: 24,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "No meal plan is available yet.")])
        }
        return household
    }

    @MainActor
    static func entries(from start: Date, through end: Date) throws -> [MealPlanEntry] {
        let endExclusive = end.startOfDay.adding(days: 1)
        return try MealPlanIntentStore.context.fetch(FetchDescriptor<MealPlanEntry>(
            predicate: #Predicate { $0.date >= start.startOfDay && $0.date < endExclusive && $0.skipped == false },
            sortBy: [SortDescriptor(\.date), SortDescriptor(\.sortIndex)]
        ))
    }

    static func amountText(_ quantity: Quantity, ingredientName: String) -> String {
        UnitConversion.string(
            for: quantity,
            system: .metric,
            preferredUnit: nil,
            approximate: false,
            ingredientName: ingredientName,
            roundsAmounts: true
        ).text
    }
}

// MARK: - Shopping list

struct AddShoppingItemIntent: AppIntent {
    static var title: LocalizedStringResource { "Add Shopping Item" }
    static var description: IntentDescription { "Adds a manual item to the MealPlan shopping list." }

    @Parameter(title: "Item", requestValueDialog: "What should I add to the shopping list?")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<ShoppingListItemEntity> {
        try MealPlanIntentResolver.requireEditingAllowed()
        let household = try MealPlanWorkflowIntentSupport.activeHousehold()
        guard let item = ShoppingListBuilder.addManualItem(
            named: text,
            household: household,
            system: household.presentationUnitSystem,
            roundsAmounts: household.roundsDisplayedAmounts,
            context: MealPlanIntentStore.context
        ) else { throw $text.needsValueError("What should I add to the shopping list?") }
        return .result(value: ShoppingListItemEntity(item: item), dialog: "Added \(item.name) to the shopping list.")
    }
}

struct GetShoppingListIntent: AppIntent {
    static var title: LocalizedStringResource { "Get Shopping List" }
    static var description: IntentDescription { "Finds current shopping items, optionally filtered by aisle or category." }

    @Parameter(title: "Unchecked only") var uncheckedOnly: Bool
    @Parameter(title: "Category") var category: String?
    @Parameter(title: "Aisle") var aisle: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[ShoppingListItemEntity]> {
        let all = try await ShoppingListItemEntityQuery().allEntities()
        let result = all.filter { item in
            (!uncheckedOnly || !item.isChecked)
                && (category == nil || item.category.localizedCaseInsensitiveContains(category!))
                && (aisle == nil || item.aisle.localizedCaseInsensitiveContains(aisle!))
        }
        let dialog = result.isEmpty
            ? String(localized: "There are no matching shopping items.")
            : result.map { $0.amount.isEmpty ? $0.name : "\($0.name), \($0.amount)" }.joined(separator: ", ")
        return .result(value: result, dialog: dialog.intentDialog)
    }
}

struct CompleteShoppingItemIntent: AppIntent {
    static var title: LocalizedStringResource { "Complete Shopping Item" }
    @Parameter(title: "Item") var item: ShoppingListItemEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<ShoppingListItemEntity> {
        try MealPlanIntentResolver.requireEditingAllowed()
        let model = try MealPlanWorkflowIntentSupport.shoppingItem(for: item)
        ShoppingListMutationService.setChecked(model, checked: true, context: MealPlanIntentStore.context)
        return .result(value: ShoppingListItemEntity(item: model), dialog: "Marked \(model.name) as bought.")
    }
}

struct ReopenShoppingItemIntent: AppIntent {
    static var title: LocalizedStringResource { "Put Shopping Item Back" }
    @Parameter(title: "Item") var item: ShoppingListItemEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<ShoppingListItemEntity> {
        try MealPlanIntentResolver.requireEditingAllowed()
        let model = try MealPlanWorkflowIntentSupport.shoppingItem(for: item)
        ShoppingListMutationService.setChecked(model, checked: false, context: MealPlanIntentStore.context)
        return .result(value: ShoppingListItemEntity(item: model), dialog: "Put \(model.name) back on the list.")
    }
}

struct RemoveShoppingItemIntent: AppIntent {
    static var title: LocalizedStringResource { "Remove Shopping Item" }
    @Parameter(title: "Item") var item: ShoppingListItemEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try MealPlanIntentResolver.requireEditingAllowed()
        let model = try MealPlanWorkflowIntentSupport.shoppingItem(for: item)
        let name = model.name
        ShoppingListMutationService.remove(model, context: MealPlanIntentStore.context)
        return .result(dialog: "Removed \(name) from the shopping list.")
    }
}

struct ClearCompletedShoppingItemsIntent: AppIntent {
    static var title: LocalizedStringResource { "Clear Completed Shopping Items" }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try MealPlanIntentResolver.requireEditingAllowed()
        let items = try MealPlanIntentStore.context.fetch(FetchDescriptor<ShoppingListItem>())
        let count = items.filter(\.isChecked).count
        ShoppingListMutationService.clearCompleted(from: items, context: MealPlanIntentStore.context)
        return .result(dialog: (count == 0 ? "There were no completed shopping items." : "Cleared \(count) completed shopping items.").intentDialog)
    }
}

struct RegenerateShoppingListIntent: AppIntent {
    static var title: LocalizedStringResource { "Rebuild Shopping List" }
    @Parameter(title: "From") var startDate: Date
    @Parameter(title: "Through") var endDate: Date?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[ShoppingListItemEntity]> {
        try MealPlanIntentResolver.requireEditingAllowed()
        let household = try MealPlanWorkflowIntentSupport.activeHousehold()
        let start = startDate.startOfDay
        let end = max(start, (endDate ?? start).startOfDay)
        ShoppingListBuilder.regenerate(
            range: DayRange(start: start, end: end.adding(days: 1)),
            household: household,
            system: household.presentationUnitSystem,
            roundsAmounts: household.roundsDisplayedAmounts,
            context: MealPlanIntentStore.context
        )
        let items = try await ShoppingListItemEntityQuery().allEntities().filter { !$0.isChecked }
        return .result(value: items, dialog: "Rebuilt the shopping list with \(items.count) items.")
    }
}

// MARK: - Recipes

struct SearchDishesIntent: AppIntent {
    static var title: LocalizedStringResource { "Search Dishes" }
    static var description: IntentDescription { "Searches saved recipes by name, tag, ingredient, or meal type." }

    @Parameter(title: "Search") var query: String?
    @Parameter(title: "Tag") var tag: String?
    @Parameter(title: "Ingredient") var ingredient: String?
    @Parameter(title: "Meal type") var mealType: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[DishEntity]> {
        let dishes = try MealPlanIntentStore.context.fetch(FetchDescriptor<Dish>(sortBy: [SortDescriptor(\.name)]))
        let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let result = dishes.filter { dish in
            (normalizedQuery.isEmpty || dish.searchableText.localizedCaseInsensitiveContains(normalizedQuery))
                && (tag == nil || dish.tagNames.contains { $0.localizedCaseInsensitiveContains(tag!) })
                && (ingredient == nil || dish.sortedIngredients.contains {
                    ($0.ingredient?.name ?? $0.rawText ?? "").localizedCaseInsensitiveContains(ingredient!)
                })
                && (mealType == nil || dish.mealTypeTagsRaw.contains {
                    $0.localizedCaseInsensitiveContains(mealType!)
                })
        }
        .prefix(50)
        .map(DishEntity.init)
        let dialog = result.isEmpty
            ? String(localized: "I couldn't find a matching dish.")
            : result.map(\.name).joined(separator: ", ")
        return .result(value: result, dialog: dialog.intentDialog)
    }
}

struct OpenDishIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Dish" }
    static var description: IntentDescription { "Opens a saved recipe in MealPlan." }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Dish") var dish: DishEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try MealPlanIntentResolver.dish(for: dish)
        let url = model.deepLinkURL ?? DeepLink.dish(model.uuid).url
        return .result(opensIntent: OpenURLIntent(url), dialog: "Opening \(model.name) in MealPlan.")
    }
}

// MARK: - Cooking mode

struct StartCookingIntent: AppIntent {
    static var title: LocalizedStringResource { "Start Cooking" }
    @Parameter(title: "Dish") var dish: DishEntity
    @Parameter(title: "Servings") var servings: Int?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try MealPlanIntentResolver.dish(for: dish)
        CookingSessionStore.shared.begin(with: model, servings: max(1, servings ?? model.servings))
        return .result(dialog: "Started cooking \(model.name).")
    }
}

enum CookingStepIntentDirection: String, AppEnum {
    case next, previous
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Cooking step direction" }
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .next: "Next", .previous: "Previous",
    ]
}

struct GetCurrentCookingStepIntent: AppIntent {
    static var title: LocalizedStringResource { "Get Current Cooking Step" }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard let session = CookingSessionStore.shared.session,
              let progress = session.selectedDish else {
            return .result(value: "", dialog: "There is no active cooking session.")
        }
        let dish = try? MealPlanIntentStore.context.fetch(FetchDescriptor<Dish>(
            predicate: #Predicate { $0.uuid == progress.id }
        )).first
        let steps = CookingRecipe.steps(from: dish?.recipeText)
        guard steps.indices.contains(progress.currentStep) else {
            return .result(value: "", dialog: "The current recipe has no more steps.")
        }
        let text = String(localized: "Step \(progress.currentStep + 1) of \(steps.count): \(steps[progress.currentStep].text)")
        return .result(value: text, dialog: text.intentDialog)
    }
}

struct NextCookingStepIntent: AppIntent {
    static var title: LocalizedStringResource { "Next Cooking Step" }
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await CookingStepNavigationIntentSupport.move(by: 1)
    }
}

struct PreviousCookingStepIntent: AppIntent {
    static var title: LocalizedStringResource { "Previous Cooking Step" }
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await CookingStepNavigationIntentSupport.move(by: -1)
    }
}

struct RepeatCookingStepIntent: AppIntent {
    static var title: LocalizedStringResource { "Repeat Cooking Step" }
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await GetCurrentCookingStepIntent().perform()
        _ = result
        return .result(dialog: "Repeat the current cooking step.")
    }
}

struct MarkCookingStepDoneIntent: AppIntent {
    static var title: LocalizedStringResource { "Mark Cooking Step Done" }
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await CookingStepNavigationIntentSupport.move(by: 1, prefix: String(localized: "Done."))
    }
}

enum CookingStepNavigationIntentSupport {
    @MainActor
    static func move(by offset: Int, prefix: String? = nil) async throws -> some IntentResult & ProvidesDialog {
        guard let session = CookingSessionStore.shared.session,
              let progress = session.selectedDish else {
            return .result(dialog: "There is no active cooking session.")
        }
        let dish = try? MealPlanIntentStore.context.fetch(FetchDescriptor<Dish>(
            predicate: #Predicate { $0.uuid == progress.id }
        )).first
        let steps = CookingRecipe.steps(from: dish?.recipeText)
        guard !steps.isEmpty else { return .result(dialog: "This recipe has no cooking steps.") }
        let next = min(max(0, progress.currentStep + offset), steps.count - 1)
        CookingSessionStore.shared.setCurrentStep(next, for: progress.id, stepCount: steps.count)
        let message = "Step \(next + 1) of \(steps.count): \(steps[next].text)"
        return .result(dialog: (prefix.map { "\($0) \(message)" } ?? message).intentDialog)
    }
}

struct StartCookingTimerIntent: AppIntent {
    static var title: LocalizedStringResource { "Start Cooking Timer" }
    @Parameter(title: "Duration in minutes") var minutes: Double
    @Parameter(title: "Label") var label: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<CookingTimerEntity> {
        guard let session = CookingSessionStore.shared.session,
              let progress = session.selectedDish else {
            throw NSError(domain: "MealPlan.AppIntents", code: 25,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "There is no active cooking session.")])
        }
        let dish = try? MealPlanIntentStore.context.fetch(FetchDescriptor<Dish>(
            predicate: #Predicate { $0.uuid == progress.id }
        )).first
        let steps = CookingRecipe.steps(from: dish?.recipeText)
        let step = steps.indices.contains(progress.currentStep) ? steps[progress.currentStep] : nil
        let timerLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? label!
            : (step?.timers.first?.label ?? String(localized: "Cooking timer"))
        CookingSessionStore.shared.startTimer(
            dishID: progress.id,
            dishName: progress.name,
            stepNumber: progress.currentStep + 1,
            stepText: step?.text ?? "",
            label: timerLabel,
            duration: max(0.1, minutes * 60)
        )
        guard let timer = CookingSessionStore.shared.session?.timers.last else {
            throw NSError(domain: "MealPlan.AppIntents", code: 26,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "The cooking timer could not be started.")])
        }
        return .result(value: CookingTimerEntity(timer: timer), dialog: "Started a \(Int(minutes)) minute timer.")
    }
}

struct PauseResumeCookingTimerIntent: AppIntent {
    static var title: LocalizedStringResource { "Pause or Resume Cooking Timer" }
    @Parameter(title: "Timer") var timer: CookingTimerEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard CookingSessionStore.shared.session?.timers.contains(where: { $0.id == timer.id }) == true else {
            throw NSError(domain: "MealPlan.AppIntents", code: 27,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "That cooking timer no longer exists.")])
        }
        CookingSessionStore.shared.pauseOrResumeTimer(timer.id, at: .now)
        let state = CookingSessionStore.shared.session?.timers.first { $0.id == timer.id }
        return .result(dialog: (state?.pausedRemaining == nil ? "Resumed \(timer.label)." : "Paused \(timer.label).").intentDialog)
    }
}

struct CancelCookingTimerIntent: AppIntent {
    static var title: LocalizedStringResource { "Cancel Cooking Timer" }
    @Parameter(title: "Timer") var timer: CookingTimerEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        CookingSessionStore.shared.cancelTimer(timer.id)
        return .result(dialog: "Cancelled \(timer.label).")
    }
}

struct FinishCookingIntent: AppIntent {
    static var title: LocalizedStringResource { "Finish Cooking" }
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        CookingSessionStore.shared.finish()
        return .result(dialog: "Finished cooking.")
    }
}

// MARK: - Pantry and inventory

enum InventoryIntentMode: String, AppEnum {
    case have, low, out, clear
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Inventory state" }
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .have: "Have", .low: "Low", .out: "Out", .clear: "Clear tracking",
    ]

    var modelValue: InventoryMode {
        switch self {
        case .have: .have
        case .low: .low
        case .out: .out
        case .clear: .none
        }
    }
}

struct SetIngredientInventoryIntent: AppIntent {
    static var title: LocalizedStringResource { "Set Ingredient Inventory" }
    static var description: IntentDescription { "Records whether an ingredient is available, low, or out." }

    @Parameter(title: "Ingredient") var ingredient: IngredientEntity
    @Parameter(title: "State") var mode: InventoryIntentMode
    @Parameter(title: "Amount") var amount: String?
    @Parameter(title: "Best before") var bestBefore: Date?
    @Parameter(title: "Storage location") var storageLocation: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<IngredientEntity> {
        try MealPlanIntentResolver.requireEditingAllowed()
        let model = try MealPlanWorkflowIntentSupport.ingredient(for: ingredient)
        let parsed = amount.flatMap { GermanUnitParser.parse($0).quantity }
        model.markInventory(mode.modelValue, quantity: parsed, bestBefore: bestBefore)
        if let storageLocation {
            model.inventoryStorageLocationRaw = storageLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if mode == .clear {
            model.inventoryStorageLocationRaw = nil
        }
        model.modifiedAt = .now
        try MealPlanIntentStore.context.save()
        ShoppingListBuilder.regenerate(
            range: DayRange(start: .now.startOfDay, end: .now.startOfWeek().adding(weeks: 1)),
            household: try MealPlanWorkflowIntentSupport.activeHousehold(),
            system: .metric,
            context: MealPlanIntentStore.context
        )
        return .result(value: IngredientEntity(ingredient: model), dialog: "Set \(model.name) to \(model.inventoryMode.localizedName.lowercased()).")
    }
}

struct GetIngredientInventoryIntent: AppIntent {
    static var title: LocalizedStringResource { "Get Ingredient Inventory" }
    @Parameter(title: "Ingredient") var ingredient: IngredientEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<IngredientEntity> {
        let model = try MealPlanWorkflowIntentSupport.ingredient(for: ingredient)
        return .result(value: IngredientEntity(ingredient: model), dialog: "\(model.name): \(model.inventoryMode.localizedName.lowercased()).")
    }
}

struct GetLowStockIngredientsIntent: AppIntent {
    static var title: LocalizedStringResource { "Get Low Stock Ingredients" }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[IngredientEntity]> {
        let ingredients = try MealPlanIntentStore.context.fetch(FetchDescriptor<Ingredient>(sortBy: [SortDescriptor(\.name)]))
            .filter { $0.inventoryMode == .low || $0.inventoryMode == .out }
            .map(IngredientEntity.init)
        let dialog = ingredients.isEmpty
            ? String(localized: "Nothing is marked low or out.")
            : ingredients.map(\.name).joined(separator: ", ")
        return .result(value: ingredients, dialog: dialog.intentDialog)
    }
}

struct GetExpiringIngredientsIntent: AppIntent {
    static var title: LocalizedStringResource { "Get Expiring Ingredients" }
    @Parameter(title: "Within days") var days: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[IngredientEntity]> {
        let limit = Date.now.adding(days: max(0, days)).startOfDay.adding(days: 1)
        let ingredients = try MealPlanIntentStore.context.fetch(FetchDescriptor<Ingredient>(sortBy: [SortDescriptor(\.name)]))
            .filter { ingredient in
                guard let date = ingredient.inventoryBestBefore else { return false }
                return date >= .now && date <= limit
            }
            .map(IngredientEntity.init)
        let dialog = ingredients.isEmpty
            ? String(localized: "Nothing is expiring in that period.")
            : ingredients.map(\.name).joined(separator: ", ")
        return .result(value: ingredients, dialog: dialog.intentDialog)
    }
}

struct AddLowOrOutIngredientsToShoppingListIntent: AppIntent {
    static var title: LocalizedStringResource { "Add Low or Out Ingredients to Shopping List" }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[ShoppingListItemEntity]> {
        try MealPlanIntentResolver.requireEditingAllowed()
        let household = try MealPlanWorkflowIntentSupport.activeHousehold()
        let candidates = (household.ingredients ?? []).filter { $0.inventoryMode == .low || $0.inventoryMode == .out }
        let existing = Set((household.shoppingItems ?? []).map { IngredientMatching.key(for: $0.name) })
        for ingredient in candidates where !existing.contains(IngredientMatching.key(for: ingredient.name)) {
            _ = ShoppingListBuilder.addManualItem(for: ingredient, household: household, context: MealPlanIntentStore.context)
        }
        let items = try await ShoppingListItemEntityQuery().allEntities().filter { !$0.isChecked }
        return .result(value: items, dialog: (candidates.isEmpty ? "Nothing is marked low or out." : "Added low and out ingredients to the shopping list.").intentDialog)
    }
}

// MARK: - Routines and templates

struct CreateMealRoutineIntent: AppIntent {
    static var title: LocalizedStringResource { "Create Meal Routine" }
    @Parameter(title: "Dish") var dish: DishEntity
    @Parameter(title: "Meal") var meal: MealTypeEntity
    @Parameter(title: "Weekday") var weekday: Int
    @Parameter(title: "Every N weeks") var intervalWeeks: Int
    @Parameter(title: "Starting") var startDate: Date

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<MealRoutineEntity> {
        try MealPlanIntentResolver.requireEditingAllowed()
        let household = try MealPlanWorkflowIntentSupport.activeHousehold()
        try await MealPlanIntentResolver.requirePlanningAllowed(on: startDate)
        let routine = MealRoutine(
            dish: try MealPlanIntentResolver.dish(for: dish),
            mealKey: meal.id,
            weekday: min(max(1, weekday), 7),
            intervalWeeks: min(max(1, intervalWeeks), 52),
            startDate: startDate
        )
        routine.household = household
        MealPlanIntentStore.context.insert(routine)
        try MealPlanIntentStore.context.save()
        MealRoutineScheduler.apply(
            routine,
            household: household,
            context: MealPlanIntentStore.context,
            through: PurchaseManager.shared.latestPlanningDate(),
            memberName: MealPlanIntentStore.currentMemberName
        )
        return .result(value: MealRoutineEntity(routine: routine), dialog: "Created \(routine.scheduleDescription.lowercased()) routine for \(dish.name).")
    }
}

struct GetMealRoutinesIntent: AppIntent {
    static var title: LocalizedStringResource { "Get Meal Routines" }
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[MealRoutineEntity]> {
        let routines = try await MealRoutineEntityQuery().allEntities()
        let dialog = routines.isEmpty ? String(localized: "There are no meal routines.") : routines.map(\.dishName).joined(separator: ", ")
        return .result(value: routines, dialog: dialog.intentDialog)
    }
}

struct PauseMealRoutineIntent: AppIntent {
    static var title: LocalizedStringResource { "Pause Meal Routine" }
    @Parameter(title: "Routine") var routine: MealRoutineEntity
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<MealRoutineEntity> {
        try MealPlanIntentResolver.requireEditingAllowed()
        let model = try MealPlanWorkflowIntentSupport.routine(for: routine)
        model.isActive = false
        try MealPlanIntentStore.context.save()
        return .result(value: MealRoutineEntity(routine: model), dialog: "Paused \(model.dish?.name ?? "meal") routine.")
    }
}

struct ResumeMealRoutineIntent: AppIntent {
    static var title: LocalizedStringResource { "Resume Meal Routine" }
    @Parameter(title: "Routine") var routine: MealRoutineEntity
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<MealRoutineEntity> {
        try MealPlanIntentResolver.requireEditingAllowed()
        let model = try MealPlanWorkflowIntentSupport.routine(for: routine)
        model.isActive = true
        model.plannedThrough = nil
        try MealPlanIntentStore.context.save()
        if let household = model.household {
            try await MealPlanIntentResolver.requirePlanningAllowed(on: .now)
            MealRoutineScheduler.apply(model, household: household, context: MealPlanIntentStore.context, through: PurchaseManager.shared.latestPlanningDate(), memberName: MealPlanIntentStore.currentMemberName)
        }
        return .result(value: MealRoutineEntity(routine: model), dialog: "Resumed \(model.dish?.name ?? "meal") routine.")
    }
}

struct DeleteMealRoutineIntent: AppIntent {
    static var title: LocalizedStringResource { "Delete Meal Routine" }
    @Parameter(title: "Routine") var routine: MealRoutineEntity
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try MealPlanIntentResolver.requireEditingAllowed()
        let model = try MealPlanWorkflowIntentSupport.routine(for: routine)
        let name = model.dish?.name ?? String(localized: "meal")
        MealRoutineScheduler.removeFutureEntries(of: model, context: MealPlanIntentStore.context)
        MealPlanIntentStore.context.delete(model)
        try MealPlanIntentStore.context.save()
        return .result(dialog: "Deleted the \(name) routine.")
    }
}

struct GetWeekTemplatesIntent: AppIntent {
    static var title: LocalizedStringResource { "Get Week Templates" }
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[WeekTemplateEntity]> {
        let templates = try await WeekTemplateEntityQuery().allEntities()
        return .result(value: templates, dialog: (templates.isEmpty ? "There are no week templates." : templates.map(\.name).joined(separator: ", ")).intentDialog)
    }
}

struct ApplyWeekTemplateIntent: AppIntent {
    static var title: LocalizedStringResource { "Apply Week Template" }
    @Parameter(title: "Template") var template: WeekTemplateEntity
    @Parameter(title: "Week starting") var weekStart: Date
    @Parameter(title: "Replace existing meals") var replaceExisting: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        try MealPlanIntentResolver.requireEditingAllowed()
        let household = try MealPlanWorkflowIntentSupport.activeHousehold()
        try await MealPlanIntentResolver.requirePlanningAllowed(on: weekStart.adding(days: 6))
        let model = try MealPlanWorkflowIntentSupport.template(for: template)
        if replaceExisting {
            // The destructive branch is explicit in the Shortcut parameter;
            // there is no silent replacement of manually planned meals.
        }
        TemplateEngine.apply(
            model,
            toWeekContaining: weekStart,
            replaceExisting: replaceExisting,
            household: household,
            memberName: MealPlanIntentStore.currentMemberName,
            context: MealPlanIntentStore.context
        )
        let message = "Applied \(model.name) to the week of \(weekStart.formatted(date: .abbreviated, time: .omitted))."
        return .result(value: message, dialog: message.intentDialog)
    }
}

// MARK: - Leftovers and nutrition

struct LeftoverEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Likely Leftover" }
    static var defaultQuery: LeftoverEntityQuery { LeftoverEntityQuery() }

    let id: String
    @Property(title: "Ingredient") var ingredientName: String
    @Property(title: "Amount") var amount: String
    @Property(title: "Source dishes") var sourceDishes: String

    init(leftover: PredictedLeftover) {
        id = leftover.id
        ingredientName = leftover.ingredientName
        amount = MealPlanWorkflowIntentSupport.amountText(leftover.remainder, ingredientName: leftover.ingredientName)
        sourceDishes = leftover.sourceDishNames.joined(separator: ", ")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(ingredientName)", subtitle: "\(amount)", image: .init(systemName: "arrow.uturn.left.circle"))
    }
}

struct LeftoverEntityQuery: EnumerableEntityQuery, EntityStringQuery {
    @MainActor
    func allEntities() async throws -> [LeftoverEntity] { [] }
    @MainActor
    func entities(for identifiers: [String]) async throws -> [LeftoverEntity] { [] }
    @MainActor
    func suggestedEntities() async throws -> [LeftoverEntity] { [] }
    @MainActor
    func entities(matching string: String) async throws -> [LeftoverEntity] { [] }
}

struct GetLikelyLeftoversIntent: AppIntent {
    static var title: LocalizedStringResource { "Get Likely Leftovers" }
    @Parameter(title: "From") var startDate: Date
    @Parameter(title: "Through") var endDate: Date?
    @Parameter(title: "Ingredient") var ingredient: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[LeftoverEntity]> {
        let household = try MealPlanWorkflowIntentSupport.activeHousehold()
        let end = endDate ?? startDate
        let entries = try MealPlanWorkflowIntentSupport.entries(from: startDate, through: max(startDate, end))
        let leftovers = LeftoverCalculator.calculate(
            entries: entries,
            countryCode: household.packageSizeCountryCode,
            userOverrides: household.packageSizeOverrides ?? []
        ).filter {
            ingredient == nil || $0.ingredientName.localizedCaseInsensitiveContains(ingredient!)
        }
        let result = leftovers.map(LeftoverEntity.init)
        let dialog = result.isEmpty
            ? String(localized: "No likely leftovers were found for that period.")
            : result.map { "\($0.ingredientName), \($0.amount)" }.joined(separator: ", ")
        return .result(value: result, dialog: dialog.intentDialog)
    }
}

struct SuggestDishesForLeftoversIntent: AppIntent {
    static var title: LocalizedStringResource { "Suggest Dishes for Leftovers" }
    @Parameter(title: "From") var startDate: Date
    @Parameter(title: "Through") var endDate: Date?
    @Parameter(title: "Servings") var servings: Int
    @Parameter(title: "Ingredient") var ingredient: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[DishEntity]> {
        let household = try MealPlanWorkflowIntentSupport.activeHousehold()
        let entries = try MealPlanWorkflowIntentSupport.entries(from: startDate, through: max(startDate, endDate ?? startDate))
        let leftovers = LeftoverCalculator.calculate(
            entries: entries,
            countryCode: household.packageSizeCountryCode,
            userOverrides: household.packageSizeOverrides ?? []
        ).filter {
            ingredient == nil || $0.ingredientName.localizedCaseInsensitiveContains(ingredient!)
        }
        let dishes = try MealPlanIntentStore.context.fetch(FetchDescriptor<Dish>(sortBy: [SortDescriptor(\.name)]))
        let suggestions = LeftoverDishSuggester.suggestions(
            for: leftovers,
            dishes: dishes,
            servings: max(1, servings),
            countryCode: household.packageSizeCountryCode,
            userOverrides: household.packageSizeOverrides ?? []
        )
        let result = suggestions.map { DishEntity(dish: $0.dish) }
        return .result(
            value: result,
            dialog: (result.isEmpty ? "I couldn't find a saved dish that uses those leftovers." : result.map(\.name).joined(separator: ", ")).intentDialog
        )
    }
}

enum MealPlanNutritionIntentSupport {
    static func text(for estimate: NutritionEstimate, energyUnit: EnergyUnit) -> String {
        guard estimate.origin != .none else { return String(localized: "Nutrition data is unavailable.") }
        let energy = NutritionFormatting.energy(estimate.facts, unit: energyUnit)
        let protein = NutritionFormatting.grams(estimate.facts.proteinGrams)
        let carbs = NutritionFormatting.grams(estimate.facts.carbGrams)
        let fat = NutritionFormatting.grams(estimate.facts.fatGrams)
        let coverage = NutritionFormatting.coverageNote(for: estimate).map { " \($0)" } ?? ""
        return String(localized: "\(energy); protein \(protein), carbohydrates \(carbs), fat \(fat).\(coverage)")
    }
}

struct GetMealNutritionIntent: AppIntent {
    static var title: LocalizedStringResource { "Get Meal Nutrition" }
    @Parameter(title: "Planned meal") var meal: MealPlanEntryEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let id = meal.id
        guard let entry = try MealPlanIntentStore.context.fetch(FetchDescriptor<MealPlanEntry>(
            predicate: #Predicate { $0.uuid == id }
        )).first else {
            throw NSError(domain: "MealPlan.AppIntents", code: 28,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "That planned meal no longer exists.")])
        }
        let estimate = NutritionEstimator.perPerson(for: [entry])
        let household = try MealPlanWorkflowIntentSupport.activeHousehold()
        let text = MealPlanNutritionIntentSupport.text(for: estimate, energyUnit: household.energyUnit)
        return .result(value: text, dialog: text.intentDialog)
    }
}

struct GetDayNutritionIntent: AppIntent {
    static var title: LocalizedStringResource { "Get Day Nutrition" }
    @Parameter(title: "Date") var date: Date

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let entries = try MealPlanWorkflowIntentSupport.entries(from: date, through: date)
        let household = try MealPlanWorkflowIntentSupport.activeHousehold()
        let text = MealPlanNutritionIntentSupport.text(
            for: NutritionEstimator.perPerson(for: entries),
            energyUnit: household.energyUnit
        )
        return .result(value: text, dialog: "\(date.formatted(date: .complete, time: .omitted)): \(text)")
    }
}

struct GetWeekNutritionIntent: AppIntent {
    static var title: LocalizedStringResource { "Get Week Nutrition" }
    @Parameter(title: "Week") var week: Date

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let start = week.startOfWeek()
        let entries = try MealPlanWorkflowIntentSupport.entries(from: start, through: start.adding(weeks: 1).adding(days: -1))
        let household = try MealPlanWorkflowIntentSupport.activeHousehold()
        let summary = WeekNutritionSummary(entries: entries)
        let estimates = summary
            .estimatesForIntent(from: start, through: start.adding(weeks: 1))
        let text: String
        if estimates.isEmpty {
            text = String(localized: "Nutrition data is unavailable for this week.")
        } else {
            text = estimates.map { day, estimate in
                "\(day.formatted(date: .abbreviated, time: .omitted)): \(MealPlanNutritionIntentSupport.text(for: estimate, energyUnit: household.energyUnit))"
            }.joined(separator: "\n")
        }
        return .result(value: text, dialog: text.intentDialog)
    }
}

private extension WeekNutritionSummary {
    func estimatesForIntent(from start: Date, through end: Date) -> [(Date, NutritionEstimate)] {
        var result: [(Date, NutritionEstimate)] = []
        var cursor = start.startOfDay
        while cursor < end.startOfDay {
            if let value = estimate(on: cursor) { result.append((cursor, value)) }
            cursor = cursor.adding(days: 1)
        }
        return result
    }
}

private extension String {
    var intentDialog: IntentDialog { IntentDialog(stringLiteral: self) }
}
