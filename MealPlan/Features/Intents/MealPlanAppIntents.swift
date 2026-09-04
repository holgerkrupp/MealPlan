import AppIntents
import SwiftData
import Foundation

// MARK: - Intent resolution

@MainActor
private enum MealPlanIntentResolver {
    static var context: ModelContext { MealPlanIntentStore.context }

    static func requireEditingAllowed() throws {
        let members = try context.fetch(FetchDescriptor<HouseholdMember>())
        if members.contains(where: { $0.isCurrentUser && $0.role == .guest }) {
            throw NSError(
                domain: "MealPlan.AppIntents",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "You have view-only access to this meal plan.")]
            )
        }
    }

    static func requirePlanningAllowed(on date: Date) async throws {
        let purchases = PurchaseManager.shared
        await purchases.updateEntitlement()
        guard purchases.canPlan(on: date) else {
            throw NSError(
                domain: "MealPlan.AppIntents",
                code: 7,
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "Unlock MealPlan in the app to plan more than 7 days ahead."
                    )
                ]
            )
        }
    }

    static func dish(for entity: DishEntity) throws -> Dish {
        let id = entity.id
        guard let dish = try context.fetch(FetchDescriptor<Dish>(
            predicate: #Predicate { $0.uuid == id }
        )).first else {
            throw NSError(
                domain: "MealPlan.AppIntents",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "That dish isn’t in your library.")]
            )
        }
        return dish
    }

    static func meal(for entity: MealTypeEntity) throws -> MealType {
        let key = entity.id
        guard let meal = try context.fetch(FetchDescriptor<MealType>(
            predicate: #Predicate { $0.key == key }
        )).first else {
            throw NSError(
                domain: "MealPlan.AppIntents",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "That meal no longer exists.")]
            )
        }
        return meal
    }

    static func dish(named requestedName: String, household: Household?) throws -> Dish {
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw NSError(
                domain: "MealPlan.AppIntents",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "The dish needs a name.")]
            )
        }
        let dishes = try context.fetch(FetchDescriptor<Dish>(sortBy: [SortDescriptor(\.name)]))
        if let existing = dishes.first(where: {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            return existing
        }

        let dish = Dish(name: name)
        dish.household = household
        dish.createdByName = DeviceOwner.name
        context.insert(dish)
        DishBuilder.addSuggestedTags(to: dish, household: household)
        try context.save()
        return dish
    }

    static func meal(
        mentionedIn text: String,
        at date: Date,
        available meals: [MealType]
    ) -> MealType? {
        if let named = meals.first(where: {
            text.localizedCaseInsensitiveContains($0.name)
                || text.localizedCaseInsensitiveContains($0.key)
        }) {
            return named
        }

        let hour = Calendar.current.component(.hour, from: date)
        let preferredKey: String
        switch hour {
        case ..<11: preferredKey = "breakfast"
        case 11..<15: preferredKey = "lunch"
        case 15..<17: preferredKey = "snack"
        default: preferredKey = "dinner"
        }
        return meals.first(where: { $0.key == preferredKey })
            ?? meals.min(by: { abs($0.sortOrder - 2) < abs($1.sortOrder - 2) })
    }

    static func cleanDishName(_ title: String, meal: MealType?) -> String {
        guard let meal else { return title.trimmingCharacters(in: .whitespacesAndNewlines) }
        var result = title
        for suffix in [" for \(meal.name)", " at \(meal.name)", " \(meal.name)"] {
            if let range = result.range(of: suffix, options: [.caseInsensitive, .backwards]),
               range.upperBound == result.endIndex {
                result.removeSubrange(range)
                break
            }
        }
        let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? title : cleaned
    }

    static func formattedPlan(_ entries: [MealPlanEntry], meals: [String: String]) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.setLocalizedDateFormatFromTemplate("EEEEdMMM")
        return entries.map { entry in
            let meal = meals[entry.mealKey] ?? MealType.legacyName(for: entry.mealKey)
            return "\(dateFormatter.string(from: entry.date)), \(meal): \(entry.displayTitle)"
        }.joined(separator: "\n")
    }

    static func index(_ entry: MealPlanEntry) async {
        let entity = MealPlanIntentStore.entity(for: entry)
        try? await MealPlanSpotlightIndexer.indexEntities([entity])
    }
}

// MARK: - Add a dish

struct AddDishIntent: AppIntent {
    static var title: LocalizedStringResource { "Add Dish to MealPlan" }
    static var description: IntentDescription {
        IntentDescription("Adds a dish by name, or imports one from a recipe link.")
    }

    @Parameter(title: "Name", requestValueDialog: "What should the dish be called?")
    var name: String?

    @Parameter(title: "Recipe link")
    var url: URL?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$name) to MealPlan") { \.$url }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<DishEntity> {
        try MealPlanIntentResolver.requireEditingAllowed()
        let context = MealPlanIntentStore.context
        let household = MealPlanIntentStore.household()
        let member = DeviceOwner.name

        let dish: Dish
        if let url {
            var recipe = try? await RecipeSchemaParser().importRecipe(from: url)
            if recipe == nil {
                recipe = try? await StubRecipeImporter().importRecipe(from: url)
            }
            let resolved = recipe ?? ImportedRecipe(name: url.host() ?? "Recipe", sourceURL: url)
            let existing = (try? context.fetch(FetchDescriptor<Dish>())) ?? []
            if let duplicate = RecipeDuplicateDetector.match(resolved, in: existing) {
                let entity = DishEntity(dish: duplicate)
                return .result(value: entity, dialog: "“\(duplicate.name)” is already in MealPlan.")
            }
            dish = DishBuilder.makeDish(
                from: resolved,
                household: household,
                createdByName: member,
                context: context
            )
        } else {
            let title = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw $name.needsValueError("What should the dish be called?")
            }
            dish = Dish(name: title)
            dish.household = household
            dish.createdByName = member
            context.insert(dish)
            DishBuilder.addSuggestedTags(to: dish, household: household)
            try context.save()
        }

        let entity = DishEntity(dish: dish)
        try? await MealPlanSpotlightIndexer.indexEntities([entity])
        SharedStore.reloadWidgets()
        return .result(value: entity, dialog: "Added “\(dish.name)” to MealPlan.")
    }
}

// MARK: - Plan a dish

struct PlanMealIntent: AppIntent {
    static var title: LocalizedStringResource { "Plan a Meal" }
    static var description: IntentDescription {
        IntentDescription("Adds a dish to a chosen day and meal in the meal plan.")
    }

    @Parameter(title: "Dish", requestValueDialog: "Which dish would you like to plan?")
    var dish: DishEntity

    @Parameter(title: "Date", requestValueDialog: "Which day should I plan it for?")
    var date: Date

    @Parameter(title: "Meal", requestValueDialog: "Which meal should I add it to?")
    var meal: MealTypeEntity

    @Parameter(title: "Servings")
    var servings: Int?

    @Parameter(title: "Note")
    var note: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Plan \(\.$dish) for \(\.$meal) on \(\.$date)") {
            \.$servings
            \.$note
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<MealPlanEntryEntity> {
        try MealPlanIntentResolver.requireEditingAllowed()
        try await MealPlanIntentResolver.requirePlanningAllowed(on: date)
        let context = MealPlanIntentStore.context
        let model = try MealPlanIntentResolver.dish(for: dish)
        let mealModel = try MealPlanIntentResolver.meal(for: meal)
        let entry = MealPlanner.plan(
            dish: model,
            on: date,
            mealKey: mealModel.key,
            servings: servings,
            note: note,
            household: MealPlanIntentStore.household(),
            memberName: DeviceOwner.name,
            context: context
        )
        await MealPlanIntentResolver.index(entry)
        let entity = MealPlanEntryEntity(entry: entry, meal: mealModel)
        let day = date.formatted(date: .abbreviated, time: .omitted)
        return .result(
            value: entity,
            dialog: "Planned “\(model.name)” for \(mealModel.name) on \(day)."
        )
    }
}

// MARK: - Ask about the plan

struct GetMealPlanIntent: AppIntent {
    static var title: LocalizedStringResource { "Get Meal Plan" }
    static var description: IntentDescription {
        IntentDescription("Answers what is planned for a day, date range, or meal.")
    }

    @Parameter(title: "Date") var date: Date?
    @Parameter(title: "Through") var endDate: Date?
    @Parameter(title: "Meal") var meal: MealTypeEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get the meal plan") {
            \.$date
            \.$endDate
            \.$meal
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let context = MealPlanIntentStore.context
        let start = (date ?? .now).startOfDay
        let end = endDate.map { $0.startOfDay.adding(days: 1) } ?? start.adding(days: 1)
        var entries = try context.fetch(FetchDescriptor<MealPlanEntry>(
            predicate: #Predicate { $0.date >= start && $0.date < end && $0.skipped == false },
            sortBy: [SortDescriptor(\.date), SortDescriptor(\.sortIndex)]
        ))
        if let meal {
            entries = entries.filter { $0.mealKey == meal.id }
        }

        guard !entries.isEmpty else {
            let day = start.formatted(date: .abbreviated, time: .omitted)
            let scope = meal.map { " for \($0.name)" } ?? ""
            let answer = "Nothing is planned\(scope) on \(day)."
            return .result(value: "", dialog: "\(answer)")
        }

        let mealNames = Dictionary(uniqueKeysWithValues: MealPlanIntentStore.mealTypes().map { ($0.key, $0.name) })
        let text = MealPlanIntentResolver.formattedPlan(entries, meals: mealNames)
        return .result(value: text, dialog: "\(text)")
    }
}

struct ThisWeekPlanIntent: AppIntent {
    static var title: LocalizedStringResource { "Get This Week’s Meal Plan" }
    static var description: IntentDescription {
        IntentDescription("Answers what is planned for the current week.")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let context = MealPlanIntentStore.context
        let start = Date.now.startOfWeek()
        let end = start.adding(weeks: 1)
        let entries = try context.fetch(FetchDescriptor<MealPlanEntry>(
            predicate: #Predicate { $0.date >= start && $0.date < end && $0.skipped == false },
            sortBy: [SortDescriptor(\.date), SortDescriptor(\.sortIndex)]
        ))
        guard !entries.isEmpty else {
            return .result(value: "", dialog: "Nothing is planned for this week yet.")
        }
        let mealNames = Dictionary(uniqueKeysWithValues: MealPlanIntentStore.mealTypes().map { ($0.key, $0.name) })
        let text = MealPlanIntentResolver.formattedPlan(entries, meals: mealNames)
        return .result(value: text, dialog: "\(text)")
    }
}

// MARK: - iOS 27 natural-language Calendar schemas

#if compiler(>=6.4)
/// Siri understands planned meals as calendar events. This schema intent maps
/// natural requests such as “Schedule ramen for dinner Friday in MealPlan”
/// back into the app's dish/day/meal model.
@AppIntent(schema: .calendar.createEvent)
struct CreatePlannedMealIntent {
    var title: String
    var startDate: Date
    var endDate: Date?
    var location: MealPlanEventLocation?
    var calendar: MealPlanCalendarEntity
    var isAllDay: Bool
    var recurrence: Calendar.RecurrenceRule?
    var attendees: [MealPlanAttendeeEntity]
    var note: AttributedString?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<MealPlanEntryEntity> {
        try MealPlanIntentResolver.requireEditingAllowed()
        try await MealPlanIntentResolver.requirePlanningAllowed(on: startDate)
        let context = MealPlanIntentStore.context
        let calendarID = calendar.id
        let household = (try? context.fetch(FetchDescriptor<Household>(
            predicate: #Predicate { $0.uuid == calendarID }
        )).first) ?? MealPlanIntentStore.household()
        let meals = MealPlanIntentStore.mealTypes()
        guard let meal = MealPlanIntentResolver.meal(
            mentionedIn: title + " " + (note.map { String($0.characters) } ?? ""),
            at: startDate,
            available: meals
        ) else {
            throw NSError(
                domain: "MealPlan.AppIntents",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "No meals are configured in MealPlan.")]
            )
        }

        let dishName = MealPlanIntentResolver.cleanDishName(title, meal: meal)
        let dish = try MealPlanIntentResolver.dish(named: dishName, household: household)
        let entry = MealPlanner.plan(
            dish: dish,
            on: startDate,
            mealKey: meal.key,
            note: note.map { String($0.characters) },
            household: household,
            memberName: DeviceOwner.name,
            context: context
        )

        if let recurrence, recurrence.frequency == .weekly {
            let routine = MealRoutine(
                dish: dish,
                mealKey: meal.key,
                weekday: Calendar.current.component(.weekday, from: startDate),
                intervalWeeks: recurrence.interval,
                startDate: startDate
            )
            routine.household = household
            context.insert(routine)
            MealRoutineScheduler.apply(
                routine,
                household: household,
                context: context,
                through: PurchaseManager.shared.latestPlanningDate(),
                memberName: DeviceOwner.name
            )
        }

        await MealPlanIntentResolver.index(entry)
        return .result(value: MealPlanEntryEntity(entry: entry, meal: meal))
    }
}

@AppIntent(schema: .calendar.updateEvent)
struct UpdatePlannedMealIntent {
    var event: MealPlanEntryEntity
    var title: String?
    var attendees: [MealPlanAttendeeEntity]?
    var startDate: Date?
    var endDate: Date?
    var isAllDay: Bool?
    var calendar: MealPlanCalendarEntity?
    var recurrence: Calendar.RecurrenceRule?
    var note: String?
    var location: MealPlanEventLocation?
    var span: MealPlanEventSpan?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<MealPlanEntryEntity> {
        try MealPlanIntentResolver.requireEditingAllowed()
        let context = MealPlanIntentStore.context
        let id = event.id
        guard let entry = try context.fetch(FetchDescriptor<MealPlanEntry>(
            predicate: #Predicate { $0.uuid == id }
        )).first else {
            throw NSError(
                domain: "MealPlan.AppIntents",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "That planned meal no longer exists.")]
            )
        }

        let meals = MealPlanIntentStore.mealTypes()
        let effectiveDate = startDate ?? entry.date
        if startDate != nil {
            try await MealPlanIntentResolver.requirePlanningAllowed(on: effectiveDate)
        }
        let effectiveTitle = title ?? entry.displayTitle
        let meal = MealPlanIntentResolver.meal(
            mentionedIn: effectiveTitle + " " + (note ?? ""),
            at: effectiveDate,
            available: meals
        )

        if let title {
            entry.dish = try MealPlanIntentResolver.dish(
                named: MealPlanIntentResolver.cleanDishName(title, meal: meal),
                household: entry.household
            )
            entry.isEatingOut = false
        }
        if startDate != nil || (meal?.key != entry.mealKey) {
            MealPlanner.move(
                entry,
                to: effectiveDate,
                mealKey: meal?.key ?? entry.mealKey,
                memberName: DeviceOwner.name,
                context: context
            )
        }
        if let note { entry.note = note }
        if case .address(let address) = location { entry.placeAddress = address }
        entry.lastEditedByName = DeviceOwner.name
        entry.lastEditedDate = .now
        try context.save()
        SharedStore.reloadWidgets()

        await MealPlanIntentResolver.index(entry)
        return .result(value: MealPlanIntentStore.entity(for: entry))
    }
}

@AppIntent(schema: .calendar.deleteEvent)
struct DeletePlannedMealIntent {
    var entity: MealPlanEntryEntity
    var span: MealPlanEventSpan?

    @MainActor
    func perform() async throws -> some IntentResult {
        try MealPlanIntentResolver.requireEditingAllowed()
        let context = MealPlanIntentStore.context
        let id = entity.id
        guard let selected = try context.fetch(FetchDescriptor<MealPlanEntry>(
            predicate: #Predicate { $0.uuid == id }
        )).first else {
            return .result()
        }

        if let routineID = selected.routineUUID, span != .this {
            let selectedDate = selected.date
            let all = try context.fetch(FetchDescriptor<MealPlanEntry>(
                predicate: #Predicate { $0.routineUUID == routineID }
            ))
            for entry in all where span == .all || entry.date >= selectedDate {
                context.delete(entry)
            }
        } else {
            context.delete(selected)
        }
        try context.save()
        SharedStore.reloadWidgets()
        MealPlanSpotlightIndexer.scheduleReindex(context: context)
        return .result()
    }
}
#endif

// MARK: - App Shortcuts and classic Siri phrases

struct MealPlanShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddDishIntent(),
            phrases: [
                "Add a dish to \(.applicationName)",
                "New dish in \(.applicationName)",
            ],
            shortTitle: "Add Dish",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: PlanMealIntent(),
            phrases: [
                "Plan a meal in \(.applicationName)",
                "Add a dish to the plan in \(.applicationName)",
            ],
            shortTitle: "Plan Meal",
            systemImageName: "calendar.badge.plus"
        )
        AppShortcut(
            intent: GetMealPlanIntent(),
            phrases: [
                "What is planned today in \(.applicationName)",
                "What are we eating today in \(.applicationName)",
            ],
            shortTitle: "What’s Planned?",
            systemImageName: "questionmark.circle"
        )
        AppShortcut(
            intent: ThisWeekPlanIntent(),
            phrases: [
                "Show this week's plan in \(.applicationName)",
                "What are we eating this week in \(.applicationName)",
            ],
            shortTitle: "This Week’s Plan",
            systemImageName: "calendar"
        )
    }
}
