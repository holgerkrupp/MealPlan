import Foundation
import SwiftData

/// Flattens the store into the small `WatchPlanSnapshot` the watch lives on.
///
/// Read-only and synchronous: it runs on the main context right after a save,
/// so it must not write and must not be slow. Photos are deliberately left
/// out — an application context is capped at a few hundred kilobytes, and the
/// watch shows glyphs and titles, never a picture.
enum WatchSnapshotBuilder {

    /// How far ahead the watch is told about. Two weeks is the longest span
    /// the plan screen scrolls comfortably on a 45 mm screen, and keeps the
    /// payload well inside the transfer limit.
    static let planWindow = 14

    /// A cap on the shopping list, so a month-long range can't overflow the
    /// transfer. Lines are already ordered by aisle, so the tail that gets cut
    /// is the far end of the shop rather than an arbitrary slice.
    static let shoppingLimit = 300

    @MainActor
    static func snapshot(
        context: ModelContext,
        from start: Date = .now,
        shoppingRangeName: String? = nil
    ) -> WatchPlanSnapshot {
        WatchPlanSnapshot(
            generatedAt: .now,
            days: days(context: context, from: start),
            shopping: shopping(context: context),
            shoppingRangeName: shoppingRangeName
        )
    }

    /// Builds the resumable cooking handoff from the phone's canonical
    /// CookingSessionStore. Recipe models are read only long enough to make a
    /// small value projection; the watch never gets a second SwiftData store.
    @MainActor
    static func cookingSession(context: ModelContext) -> WatchCookingSessionSnapshot? {
        guard let session = CookingSessionStore.shared.session else { return nil }

        let dishIDs = Set(session.dishes.map(\.id))
        let descriptor = FetchDescriptor<Dish>(predicate: #Predicate { dishIDs.contains($0.uuid) })
        let fetchedDishes = (try? context.fetch(descriptor)) ?? []
        let dishesByID = Dictionary(
            fetchedDishes.map { ($0.uuid, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let dishes = session.dishes.compactMap { progress -> WatchCookingDish? in
            guard let dish = dishesByID[progress.id] else { return nil }
            let translated = dish.prefersTranslation
            let steps = CookingRecipe.steps(from: dish.displayRecipeText(translated: translated))
                .map { WatchCookingStep(id: $0.id, text: $0.text) }
            let scaler = ServingScaler(
                baseServings: dish.servings,
                targetServings: progress.targetServings,
                system: dish.household?.unitSystem ?? .metric,
                roundsAmounts: dish.household?.roundsDisplayedAmounts ?? true
            )
            let ingredients = dish.sortedIngredients.enumerated().map { index, line in
                let name = line.displayName(translated: translated)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let note = line.displayNote(translated: translated)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return WatchCookingIngredient(
                    id: line.uuid,
                    index: index,
                    name: name.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Ingredient"),
                    amount: scaler.amountText(for: line),
                    note: (note?.isEmpty == false) ? note : nil,
                    isChecked: progress.checkedIngredientIndexes.contains(index)
                )
            }
            return WatchCookingDish(
                id: progress.id,
                name: dish.displayName(translated: translated),
                targetServings: progress.targetServings,
                currentStep: steps.isEmpty
                    ? 0
                    : min(max(0, progress.currentStep), steps.count - 1),
                steps: steps,
                ingredients: ingredients
            )
        }

        let timers = session.timers.map {
            WatchCookingTimer(
                id: $0.id,
                dishName: $0.dishName,
                stepNumber: $0.stepNumber,
                stepText: $0.stepText,
                label: $0.label,
                duration: $0.duration,
                endDate: $0.endDate,
                pausedRemaining: $0.pausedRemaining
            )
        }
        return WatchCookingSessionSnapshot(
            sessionID: session.id,
            revision: session.updatedAt,
            selectedDishID: session.selectedDishID,
            dishes: dishes,
            timers: timers
        )
    }

    @MainActor
    static func cookingStepCount(dishID: UUID, context: ModelContext) -> Int? {
        let descriptor = FetchDescriptor<Dish>(predicate: #Predicate { $0.uuid == dishID })
        guard let dishes = try? context.fetch(descriptor), let dish = dishes.first else { return nil }
        return CookingRecipe.steps(from: dish.displayRecipeText(translated: dish.prefersTranslation)).count
    }

    // MARK: - Plan

    @MainActor
    static func days(
        context: ModelContext,
        from start: Date = .now,
        count: Int = planWindow
    ) -> [WatchDay] {
        let first = start.startOfDay
        let last = first.adding(days: max(count, 1))
        let blank = (0..<max(count, 1)).map { WatchDay(date: first.adding(days: $0)) }

        let descriptor = FetchDescriptor<MealPlanEntry>(
            predicate: #Predicate { $0.date >= first && $0.date < last && $0.skipped == false },
            sortBy: [SortDescriptor(\.date), SortDescriptor(\.sortIndex)]
        )
        guard let entries = try? context.fetch(descriptor), !entries.isEmpty else { return blank }

        let meals = MealTypeLookup(context: context)
        var grouped: [Date: [MealPlanEntry]] = [:]
        for entry in entries { grouped[entry.date.startOfDay, default: []].append(entry) }

        return blank.map { day in
            let sorted = (grouped[day.date] ?? []).sorted {
                (meals.rank($0), $0.sortIndex) < (meals.rank($1), $1.sortIndex)
            }
            return WatchDay(date: day.date, meals: sorted.map { meal(for: $0, lookup: meals) })
        }
    }

    private static func meal(for entry: MealPlanEntry, lookup: MealTypeLookup) -> WatchMeal {
        let glyph = entry.dish?.glyphRaw.flatMap(DishGlyph.init(rawValue:))
        let note = entry.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return WatchMeal(
            id: entry.uuid,
            mealName: lookup.name(entry),
            mealSymbol: lookup.symbol(entry),
            title: entry.displayTitle,
            emoji: glyph?.emoji,
            symbolName: glyph?.symbolName,
            isEatingOut: entry.isEatingOut,
            placeName: entry.placeName,
            note: (note?.isEmpty ?? true) ? nil : note,
            servings: entry.effectiveServings
        )
    }

    // MARK: - Shopping list

    @MainActor
    static func shopping(context: ModelContext, limit: Int = shoppingLimit) -> [WatchShoppingItem] {
        let descriptor = FetchDescriptor<ShoppingListItem>(
            sortBy: [SortDescriptor(\.sortIndex)]
        )
        guard let items = try? context.fetch(descriptor) else { return [] }
        // Ordered — and cut — by `ShoppingListGrouping`, the same call the
        // app's list, the printed list and the widget make, so a truncated
        // list still reads as the start of one walk through the shop.
        let ordered = ShoppingListGrouping.aisles(items).flatMap(\.items)
        return ordered.prefix(limit).map {
            WatchShoppingItem(
                id: $0.uuid,
                name: $0.name,
                amount: $0.displayText.flatMap { $0.isEmpty ? nil : $0 },
                aisle: $0.aisleName,
                aisleOrder: $0.category.sortOrder,
                sortIndex: $0.sortIndex,
                isChecked: $0.isChecked
            )
        }
    }

    // MARK: - Meal types

    /// Names, symbols and ordering for the household's configured meals — the
    /// same reconciliation the widgets do, for the same reason: CloudKit has
    /// no unique constraint, so duplicates can be in the store until the app
    /// next runs `MealType.ensure`.
    struct MealTypeLookup {
        private var order: [String: Int] = [:]
        private var names: [String: String] = [:]
        private var symbols: [String: String] = [:]

        @MainActor
        init(context: ModelContext) {
            let types = (try? context.fetch(FetchDescriptor<MealType>())) ?? []
            for type in types.sorted(by: { $0.uuid.uuidString < $1.uuid.uuidString })
            where order[type.key] == nil {
                order[type.key] = type.sortOrder
                names[type.key] = type.name
                symbols[type.key] = type.symbolName
            }
        }

        func rank(_ entry: MealPlanEntry) -> Int { order[entry.mealKey] ?? (1_000 + entry.slot.sortOrder) }
        func name(_ entry: MealPlanEntry) -> String { names[entry.mealKey] ?? MealType.legacyName(for: entry.mealKey) }
        func symbol(_ entry: MealPlanEntry) -> String { symbols[entry.mealKey] ?? MealType.legacySymbol(for: entry.mealKey) }
    }
}
