import Testing
import Foundation
import SwiftData
@testable import MealPlan

/// Covers the export half of the backup.
///
/// Everything runs on transient model objects gathered into a
/// `MealPlanBackup.StoreRows`, because standing up a `ModelContainer` inside
/// the app test host crashes it. That is also why `MealPlanBackupRestore` has
/// no tests here — it needs a live `ModelContext`; it is exercised by hand.
@MainActor
struct MealPlanBackupTests {

    // MARK: - Fixtures

    private func makeHousehold(name: String = "Krupp", created: Date = .now) -> Household {
        let household = Household(name: name)
        household.unitSystem = .metric
        household.roundsDisplayedAmounts = false
        household.calendarStyle = .week
        household.standardServings = 6
        household.dateCreated = created
        return household
    }

    private func makeDish(_ name: String, household: Household?) -> Dish {
        let dish = Dish(name: name)
        dish.servings = 4
        dish.recipeText = "Simmer"
        dish.rating = 4
        dish.isFavorite = true
        dish.collectionNames = ["Weeknight"]
        dish.tagNames = ["vegan"]
        dish.usageCount = 7
        dish.household = household
        return dish
    }

    /// Returns the ingredient so the caller can put it in `rows.ingredients`
    /// when it wants to model a catalogued one.
    @discardableResult
    private func addLine(
        _ dish: Dish,
        _ ingredientName: String,
        category: IngredientCategory = .produce,
        pantryStaple: Bool = false
    ) -> Ingredient {
        let ingredient = Ingredient(name: ingredientName, category: category)
        ingredient.isPantryStaple = pantryStaple
        let line = DishIngredient(
            canonicalValue: 250,
            dimension: .mass,
            displayUnit: "g",
            rawText: "250 g \(ingredientName)",
            sortIndex: dish.ingredients?.count ?? 0
        )
        line.ingredient = ingredient
        line.dish = dish
        // Inverses aren't maintained without a context, so wire both sides.
        dish.ingredients = (dish.ingredients ?? []) + [line]
        return ingredient
    }

    private func roundTrip(_ backup: MealPlanBackup) throws -> MealPlanBackup {
        try MealPlanBackup.decode(MealPlanBackup.encode(backup))
    }

    // MARK: - Gathering

    @Test func carriesTheHouseholdAndItsSettings() throws {
        let household = makeHousehold()
        var rows = MealPlanBackup.StoreRows()
        rows.households = [household]

        let restored = try roundTrip(MealPlanBackup.make(from: rows))

        #expect(restored.household.uuid == household.uuid)
        #expect(restored.household.name == "Krupp")
        #expect(restored.household.unitSystemRaw == UnitSystem.metric.rawValue)
        #expect(restored.household.calendarStyleRaw == CalendarStyle.week.rawValue)
        #expect(restored.household.roundsDisplayedAmounts == false)
        #expect(restored.household.standardServings == 6)
        #expect(restored.householdCount == 1)
    }

    /// Backups written before the household had a standard portion count
    /// still decode; the missing field reads back as the default of 2.
    @Test func aBackupWithoutStandardPortionsDecodesToTheDefault() throws {
        let household = makeHousehold()
        var rows = MealPlanBackup.StoreRows()
        rows.households = [household]

        var backup = MealPlanBackup.make(from: rows)
        backup.household.standardServings = nil
        let data = try MealPlanBackup.encode(backup)
        #expect(String(data: data, encoding: .utf8)?.contains("standardServings") == false)

        let restored = try MealPlanBackup.decode(data)
        #expect(restored.household.standardServings == nil)
        #expect((restored.household.standardServings ?? Household.defaultStandardServings) == 2)
    }

    /// The bug that shipped in the first cut: the backup walked
    /// `household.dishes`, so a dish whose back-reference was never set — the
    /// app only ever reads dishes through `@Query` — vanished from the file
    /// while still being visible in the app.
    @Test func includesDishesThatAreNotLinkedToAHousehold() throws {
        let household = makeHousehold()
        var rows = MealPlanBackup.StoreRows()
        rows.households = [household]
        rows.dishes = [makeDish("Verwaist", household: nil), makeDish("Verbunden", household: household)]

        let backup = MealPlanBackup.make(from: rows)

        #expect(backup.dishes.count == 2)
        #expect(Set(backup.dishes.map(\.name)) == ["Verwaist", "Verbunden"])
        #expect(backup.contents.dishes == 2)
    }

    /// Same failure mode one level up: a second `Household` row (two devices
    /// seeding before their first sync) must not hide the rows under it.
    @Test func includesRowsBelongingToASecondHousehold() throws {
        let first = makeHousehold(created: Date(timeIntervalSince1970: 1_000))
        let second = makeHousehold(name: "Zweite", created: Date(timeIntervalSince1970: 2_000))
        var rows = MealPlanBackup.StoreRows()
        rows.households = [second, first]
        rows.dishes = [makeDish("Bei der ersten", household: first), makeDish("Bei der zweiten", household: second)]

        let backup = MealPlanBackup.make(from: rows)

        #expect(backup.dishes.count == 2)
        #expect(backup.householdCount == 2)
        #expect(backup.contents.households == 2)
        // Settings come from the oldest household, whatever order they arrive in.
        #expect(backup.household.name == "Krupp")
    }

    @Test func carriesDishesWithIngredientsAndPhotos() throws {
        let household = makeHousehold()
        let dish = makeDish("Linseneintopf", household: household)
        let ingredient = addLine(dish, "Linsen", category: .pantry)
        let photo = DishImage(data: Data([1, 2, 3]), isPrimary: true)
        photo.dish = dish
        dish.images = [photo]

        var rows = MealPlanBackup.StoreRows()
        rows.households = [household]
        rows.dishes = [dish]
        rows.ingredients = [ingredient]

        let restored = try roundTrip(MealPlanBackup.make(from: rows))
        let storedDish = try #require(restored.dishes.first)

        #expect(restored.dishes.count == 1)
        #expect(storedDish.uuid == dish.uuid)
        #expect(storedDish.name == "Linseneintopf")
        #expect(storedDish.servings == 4)
        #expect(storedDish.rating == 4)
        #expect(storedDish.isFavorite)
        #expect(storedDish.collectionNames == ["Weeknight"])
        #expect(storedDish.tagNames == ["vegan"])
        #expect(storedDish.usageCount == 7)
        #expect(storedDish.images.first?.data == Data([1, 2, 3]))
        #expect(storedDish.images.first?.isPrimary == true)

        let line = try #require(storedDish.ingredients.first)
        #expect(line.canonicalValue == 250)
        #expect(line.displayUnit == "g")
        #expect(line.rawText == "250 g Linsen")
        #expect(line.ingredientKey == Ingredient.normalize("Linsen"))
        let catalogued = try #require(restored.ingredients.first { $0.normalizedName == line.ingredientKey })
        #expect(catalogued.name == "Linsen")
        #expect(catalogued.categoryRaw == IngredientCategory.pantry.rawValue)
    }

    /// An ingredient reachable only through a dish line still has to reach the
    /// catalogue, or the restored line would point at nothing.
    @Test func cataloguesIngredientsReachableOnlyThroughADish() throws {
        let dish = makeDish("Suppe", household: nil)
        addLine(dish, "Linsen", category: .pantry)
        var rows = MealPlanBackup.StoreRows()
        rows.dishes = [dish]

        let backup = MealPlanBackup.make(from: rows)

        #expect(backup.ingredients.map(\.normalizedName) == ["linsen"])
        #expect(backup.dishes[0].ingredients[0].ingredientKey == "linsen")
    }

    @Test func foldsDuplicateIngredientRowsIntoOneCatalogueEntry() throws {
        // CloudKit has no unique constraints, so two devices can each create
        // their own "Salz" before the first sync.
        let first = makeDish("Suppe", household: nil)
        addLine(first, "Salz", category: .spices, pantryStaple: false)
        let second = makeDish("Brot", household: nil)
        addLine(second, "salz", category: .spices, pantryStaple: true)

        var rows = MealPlanBackup.StoreRows()
        rows.dishes = [first, second]

        let restored = try roundTrip(MealPlanBackup.make(from: rows))

        #expect(restored.ingredients.count == 1)
        // Merging keeps the staple flag, which is what the shopping list uses.
        #expect(restored.ingredients[0].isPantryStaple)
        #expect(restored.dishes.allSatisfy { $0.ingredients[0].ingredientKey == "salz" })
    }

    @Test func carriesThePlanRoutinesAndCookedHistory() throws {
        let household = makeHousehold()
        let dish = makeDish("Tacos", household: household)

        let entry = MealPlanEntry(date: Date(timeIntervalSince1970: 1_770_000_000), mealKey: "dinner", dish: dish)
        entry.servingsOverride = 6
        entry.note = "extra Guacamole"
        entry.prepReminder = true
        entry.household = household

        let routine = MealRoutine(dish: dish, mealKey: "dinner", weekday: 3, intervalWeeks: 2)
        routine.household = household

        let log = CookedLog(date: .now, dish: dish, servings: 6)
        log.entry = entry
        log.household = household

        var rows = MealPlanBackup.StoreRows()
        rows.households = [household]
        rows.dishes = [dish]
        rows.entries = [entry]
        rows.routines = [routine]
        rows.cookedLogs = [log]

        let restored = try roundTrip(MealPlanBackup.make(from: rows))

        let storedEntry = try #require(restored.entries.first)
        #expect(storedEntry.uuid == entry.uuid)
        #expect(storedEntry.dishUUID == dish.uuid)
        #expect(storedEntry.mealKey == "dinner")
        #expect(storedEntry.servingsOverride == 6)
        #expect(storedEntry.note == "extra Guacamole")
        #expect(storedEntry.prepReminder)

        let storedRoutine = try #require(restored.routines.first)
        #expect(storedRoutine.dishUUID == dish.uuid)
        #expect(storedRoutine.intervalWeeks == 2)
        #expect(storedRoutine.weekday == 3)

        // Both ends of a cooked log are references, so a restore can re-link
        // it to the same dish and the same planned meal.
        let storedLog = try #require(restored.cookedLogs.first)
        #expect(storedLog.dishUUID == dish.uuid)
        #expect(storedLog.entryUUID == entry.uuid)
        #expect(storedLog.dishName == "Tacos")
    }

    @Test func carriesMealTypesInOrderAndDropsDuplicateKeys() throws {
        var rows = MealPlanBackup.StoreRows()
        rows.mealTypes = [
            MealType(key: "dinner", name: "Abendessen", symbolName: "sunset", sortOrder: 1),
            MealType(key: "breakfast", name: "Frühstück", symbolName: "sunrise", sortOrder: 0),
            // The duplicate CloudKit produces when two devices both seed.
            MealType(key: "dinner", name: "Abendessen", symbolName: "sunset", sortOrder: 1),
        ]

        let restored = try roundTrip(MealPlanBackup.make(from: rows))

        #expect(restored.mealTypes.map(\.key) == ["breakfast", "dinner"])
        #expect(restored.mealTypes[0].name == "Frühstück")
    }

    @Test func carriesWeekTemplatesWithTheirEntries() throws {
        let dish = makeDish("Pizza", household: nil)
        let template = WeekTemplate(name: "Ferienwoche")
        let entry = WeekTemplateEntry(weekday: 5, mealKey: "dinner", dish: dish)
        entry.servingsOverride = 8
        entry.template = template
        template.entries = [entry]

        var rows = MealPlanBackup.StoreRows()
        rows.dishes = [dish]
        rows.weekTemplates = [template]

        let restored = try roundTrip(MealPlanBackup.make(from: rows))
        let storedTemplate = try #require(restored.weekTemplates.first)

        #expect(storedTemplate.uuid == template.uuid)
        #expect(storedTemplate.name == "Ferienwoche")
        #expect(storedTemplate.entries.first?.weekday == 5)
        #expect(storedTemplate.entries.first?.dishUUID == dish.uuid)
        #expect(storedTemplate.entries.first?.servingsOverride == 8)
    }

    @Test func carriesShoppingListLinesAndTheirIngredient() throws {
        let ingredient = Ingredient(name: "Hafermilch", category: .dairy)
        let item = ShoppingListItem(name: "Hafermilch", category: .dairy)
        item.canonicalValue = 1000
        item.canonicalDimensionRaw = QuantityDimension.volume.rawValue
        item.displayText = "1 l"
        item.isChecked = true
        item.sourceDishNames = ["Porridge"]
        item.ingredient = ingredient

        var rows = MealPlanBackup.StoreRows()
        rows.ingredients = [ingredient]
        rows.shoppingItems = [item]

        let restored = try roundTrip(MealPlanBackup.make(from: rows))
        let stored = try #require(restored.shoppingItems.first)

        #expect(stored.name == "Hafermilch")
        #expect(stored.displayText == "1 l")
        #expect(stored.isChecked)
        #expect(stored.sourceDishNames == ["Porridge"])
        #expect(stored.ingredientKey == Ingredient.normalize("Hafermilch"))
    }

    @Test func carriesHouseholdMembers() throws {
        let member = HouseholdMember(name: "Holger", role: .owner, isCurrentUser: true)
        var rows = MealPlanBackup.StoreRows()
        rows.members = [member]

        let restored = try roundTrip(MealPlanBackup.make(from: rows))

        #expect(restored.members.first?.name == "Holger")
        #expect(restored.members.first?.roleRaw == MemberRole.owner.rawValue)
        #expect(restored.members.first?.isCurrentUser == true)
    }

    @Test func leavesPhotosOutWhenAskedTo() throws {
        let dish = makeDish("Auflauf", household: nil)
        let photo = DishImage(data: Data(repeating: 9, count: 2048), isPrimary: true)
        photo.dish = dish
        dish.images = [photo]
        let log = CookedLog(date: .now, dish: dish, servings: 4)
        log.photoData = Data(repeating: 8, count: 2048)

        var rows = MealPlanBackup.StoreRows()
        rows.dishes = [dish]
        rows.cookedLogs = [log]

        let withPhotos = try roundTrip(MealPlanBackup.make(from: rows, includePhotos: true))
        let without = try roundTrip(MealPlanBackup.make(from: rows, includePhotos: false))

        #expect(withPhotos.includesPhotos)
        #expect(withPhotos.contents.photos == 2)
        #expect(without.includesPhotos == false)
        #expect(without.contents.photos == 0)
        #expect(without.dishes[0].images.isEmpty)
        #expect(without.cookedLogs[0].photoData == nil)
        // The dish itself is still there — only the pixels are gone.
        #expect(without.dishes[0].name == "Auflauf")
        #expect(try MealPlanBackup.encode(without).count < MealPlanBackup.encode(withPhotos).count)
    }

    // MARK: - Format

    @Test func summarisesWhatItHolds() throws {
        var rows = MealPlanBackup.StoreRows()
        rows.households = [makeHousehold()]
        rows.dishes = [makeDish("Eins", household: nil), makeDish("Zwei", household: nil)]
        rows.entries = [MealPlanEntry(date: .now, mealKey: "lunch")]

        let contents = MealPlanBackup.make(from: rows).contents
        #expect(contents.dishes == 2)
        #expect(contents.plannedMeals == 1)
        #expect(contents.cookedMeals == 0)
        #expect(BackupSummary.sentence(for: contents) == "2 dishes, 1 planned meals")
    }

    @Test func refusesFilesThatAreNotBackups() throws {
        #expect(throws: (any Error).self) {
            try MealPlanBackup.decode(Data(#"{"hello":"world"}"#.utf8))
        }

        // A recipe archive is a different format and must not be mistaken for
        // a whole-store backup — restoring one would wipe the plan.
        let recipeArchive = try MealPlanRecipeArchive.data(from: [Dish(name: "Suppe")])
        #expect(throws: (any Error).self) {
            try MealPlanBackup.decode(recipeArchive)
        }
    }

    @Test func refusesArchivesFromANewerVersion() throws {
        var rows = MealPlanBackup.StoreRows()
        rows.households = [makeHousehold()]
        var backup = MealPlanBackup.make(from: rows)
        backup.version = MealPlanBackup.currentVersion + 1
        let data = try MealPlanBackup.encode(backup)
        #expect(throws: (any Error).self) {
            try MealPlanBackup.decode(data)
        }
    }

    @Test func recordsWhichEnvironmentItCameFrom() {
        var rows = MealPlanBackup.StoreRows()
        rows.households = [makeHousehold()]
        let origin = MealPlanBackup.make(from: rows).origin
        #expect(origin?.cloudEnvironment == BuildEnvironment.cloudKit.rawValue)
        #expect(CloudKitEnvironment(rawValue: origin?.cloudEnvironment ?? "") != nil)
    }

    /// A backup written before `householdCount` existed still decodes, and
    /// reports one family rather than zero.
    @Test func toleratesArchivesWithoutAHouseholdCount() throws {
        var rows = MealPlanBackup.StoreRows()
        rows.households = [makeHousehold()]
        var backup = MealPlanBackup.make(from: rows)
        backup.householdCount = nil

        let restored = try roundTrip(backup)
        #expect(restored.contents.households == 1)
    }
}
