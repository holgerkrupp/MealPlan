import Testing
import Foundation
@testable import MealPlan

/// The pure rules behind the Pantry screen, the shopping-list paste and the
/// barcode memory, plus the sync/backup round-trip of the pantry note. All
/// on transient models — a `ModelContainer` in the test host crashes it.
@MainActor
struct PantryInventoryTests {

    private func ingredient(
        _ name: String,
        mode: InventoryMode = .none,
        location: InventoryStorageLocation? = nil,
        custom: String? = nil,
        staple: Bool = false,
        note: String? = nil
    ) -> Ingredient {
        let ingredient = Ingredient(name: name)
        ingredient.inventoryModeRaw = mode.rawValue
        ingredient.inventoryStorageLocationRaw = location?.rawValue
        ingredient.inventoryCustomStorageLocation = custom
        ingredient.isPantryStaple = staple
        ingredient.inventoryNote = note
        return ingredient
    }

    // MARK: - Grouping and filtering

    @Test func onlyTrackedIngredientsAreListed() {
        let all = [
            ingredient("Milk", mode: .have, location: .fridge),
            ingredient("Salt", staple: true),
            ingredient("Saffron"),
            ingredient("Capers", note: "half a jar"),
        ]
        let names = PantryInventory.groups(all).flatMap(\.ingredients).map(\.name)
        #expect(Set(names) == ["Milk", "Salt", "Capers"])
    }

    @Test func groupsFollowLocationOrderWithUnsortedLast() {
        let all = [
            ingredient("Peas", mode: .have, location: .freezer),
            ingredient("Wine", mode: .have, location: .custom, custom: "Cellar"),
            ingredient("Rice", mode: .low, location: .pantry),
            ingredient("Eggs", mode: .have, location: .fridge),
            ingredient("Salt", staple: true),
            ingredient("Beer", mode: .have, location: .custom, custom: "cellar"),
        ]
        let groups = PantryInventory.groups(all)
        #expect(groups.map(\.id) == ["pantry", "fridge", "freezer", "custom:cellar", "none"])
        #expect(groups[3].ingredients.map(\.name) == ["Beer", "Wine"])
    }

    @Test func filterAndSearchNarrowTheList() {
        let all = [
            ingredient("Milk", mode: .have, location: .fridge),
            ingredient("Butter", mode: .have, location: .fridge, note: "salted"),
            ingredient("Rice", mode: .have, location: .pantry),
        ]
        let fridge = PantryInventory.groups(all, filter: .location(.fridge))
        #expect(fridge.flatMap(\.ingredients).map(\.name) == ["Butter", "Milk"])
        let searched = PantryInventory.groups(all, search: "SALT")
        #expect(searched.flatMap(\.ingredients).map(\.name) == ["Butter"])
    }

    @Test func searchOffersUntrackedCatalogueEntries() {
        let all = [ingredient("Tomatoes"), ingredient("Tomato paste", mode: .have), ingredient("Basil")]
        #expect(PantryInventory.untrackedMatches(all, search: "tom").map(\.name) == ["Tomatoes"])
        #expect(PantryInventory.untrackedMatches(all, search: " ").isEmpty)
    }

    // MARK: - Quantity transitions

    @Test func parsesTypedAmounts() {
        #expect(PantryInventory.parseAmount("500 g") == .grams(500))
        #expect(PantryInventory.parseAmount("1,5 l") == .millilitres(1500))
        #expect(PantryInventory.parseAmount("3") == .pieces(3))
        #expect(PantryInventory.parseAmount("  ") == nil)
    }

    @Test func usingTheLastPieceMarksOut() {
        let eggs = ingredient("Eggs", mode: .have)
        eggs.inventoryQuantity = .pieces(2)
        #expect(PantryInventory.useOne(eggs))
        #expect(eggs.inventoryQuantity == .pieces(1))
        #expect(eggs.inventoryMode == .have)
        #expect(PantryInventory.useOne(eggs))
        #expect(eggs.inventoryMode == .out)
        #expect(eggs.inventoryQuantity == nil)
    }

    @Test func useOneLeavesWeighedStockAlone() {
        let flour = ingredient("Flour", mode: .have)
        flour.inventoryQuantity = .grams(800)
        #expect(!PantryInventory.useOne(flour))
        #expect(flour.inventoryQuantity == .grams(800))
    }

    @Test func runningOutClearsAmountButLowKeepsIt() {
        let milk = ingredient("Milk", mode: .have, location: .fridge)
        milk.inventoryQuantity = .millilitres(1000)
        PantryInventory.setMode(.low, for: milk)
        #expect(milk.inventoryQuantity == .millilitres(1000))
        PantryInventory.setMode(.out, for: milk)
        #expect(milk.inventoryQuantity == nil)
        #expect(milk.inventoryStorageLocationRaw == "fridge")
    }

    @Test func bestBeforeFreshness() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let item = ingredient("Yogurt", mode: .have)
        #expect(PantryInventory.freshness(of: item, now: now) == nil)
        item.inventoryBestBefore = Calendar.current.date(byAdding: .day, value: -1, to: now)
        #expect(PantryInventory.freshness(of: item, now: now) == .expired)
        item.inventoryBestBefore = Calendar.current.date(byAdding: .day, value: 2, to: now)
        #expect(PantryInventory.freshness(of: item, now: now) == .useSoon)
        item.inventoryBestBefore = Calendar.current.date(byAdding: .day, value: 10, to: now)
        #expect(PantryInventory.freshness(of: item, now: now) == .fine)
    }

    // MARK: - Multi-line paste

    @Test func pasteSplitsLinesAndStripsListDecoration() {
        let text = """
        - 500 g Mehl
        • 2 Eier

          * [ ] Milch
        1. Butter
        2) Zucker
        ☐ 1.5 kg Kartoffeln
        """
        #expect(ShoppingListPaste.lines(from: text) == [
            "500 g Mehl", "2 Eier", "Milch", "Butter", "Zucker", "1.5 kg Kartoffeln",
        ])
        #expect(ShoppingListPaste.isMultiLine(text))
        #expect(!ShoppingListPaste.isMultiLine("3 Tomaten\n\n"))
    }

    // MARK: - Barcode memory

    @Test func barcodeMemoryRemembersNamesPerCode() throws {
        let suite = "PantryInventoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = BarcodeProductMemory(defaults: defaults)
        #expect(memory.name(for: "4006381333931") == nil)
        memory.remember("  Oat milk ", for: "4006381333931")
        #expect(memory.name(for: " 4006381333931\n") == "Oat milk")
        memory.remember("", for: "4006381333931")
        #expect(memory.name(for: "4006381333931") == "Oat milk")
        memory.remember("Ignored", for: "no digits")
        #expect(memory.name(for: "no digits") == nil)
    }

    // MARK: - Pantry note persistence

    @Test func pantryNoteRoundTripsThroughTheSyncCodec() throws {
        var portable = MealPlanBackup.PortableIngredient(
            name: "Capers", normalizedName: "capers", categoryRaw: IngredientCategory.pantry.rawValue,
            customAisleName: nil, isPantryStaple: false
        )
        portable.inventoryModeRaw = InventoryMode.low.rawValue
        portable.inventoryNote = "opened jar, top shelf"
        let data = try HouseholdRecordCodec.encode(HouseholdRecordPayload.ingredient(portable))
        guard case .ingredient(let decoded) = try HouseholdRecordCodec.decode(data) else {
            Issue.record("Expected an ingredient payload")
            return
        }
        #expect(decoded.inventoryNote == "opened jar, top shelf")
        #expect(decoded.inventoryModeRaw == InventoryMode.low.rawValue)
    }

    @Test func ingredientRecordsWithoutANoteStillDecode() throws {
        let json = #"{"name":"Salt","normalizedName":"salt","categoryRaw":"spices","isPantryStaple":true}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MealPlanBackup.PortableIngredient.self, from: Data(json.utf8))
        #expect(decoded.inventoryNote == nil)
        #expect(decoded.isPantryStaple)
    }
}
