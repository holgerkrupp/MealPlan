import Foundation
import SwiftData

/// One aggregated shopping need, before it's turned into a `ShoppingListItem`.
///
/// One line per ingredient, however many recipes asked for it and however they
/// spelled it. Amounts in the same dimension are summed into `quantity`;
/// anything measured differently — 500 g of yoghurt in one recipe, 2 pots in
/// another — lands in `additionalQuantities` so it can still be read as one
/// line rather than becoming a second row.
struct AggregatedLine: Equatable, Sendable {
    var name: String
    var normalizedName: String
    var category: IngredientCategory
    var customAisleName: String? = nil
    var quantity: Quantity?
    var displayUnit: String?
    var isApproximate: Bool = false
    /// How many times the ingredient appeared without a measurable amount.
    var unmeasuredCount: Int = 0
    var notes: [String] = []
    var sourceDishNames: [String] = []
    /// Amounts that couldn't be added to `quantity` because they are measured
    /// in another dimension, in the order they were met.
    var additionalQuantities: [Quantity] = []

    /// Add one recipe's amount, summing it into whichever dimension it belongs.
    mutating func add(_ amount: Quantity) {
        guard let current = quantity else {
            quantity = amount
            return
        }
        if let sum = current.adding(amount) {
            quantity = sum
        } else if let index = additionalQuantities.firstIndex(where: { $0.dimension == amount.dimension }) {
            additionalQuantities[index] = additionalQuantities[index].adding(amount) ?? amount
        } else {
            additionalQuantities.append(amount)
        }
    }
}

enum ShoppingListBuilder {

    // MARK: - Pure aggregation (unit-tested)

    /// Aggregate the ingredients of the given planned meals, scaling each
    /// dish to the head-count planned for that occasion.
    ///
    /// One ingredient, one line: names are matched through
    /// `IngredientMatching`, so "Joghurt" from one recipe and "Jogurt*" from
    /// another are the same row with both amounts in it. A line that lists two
    /// things without an amount ("Salz und Pfeffer") is split into them, and a
    /// name in `stapleKeys` — the household's pantry staples, as
    /// `IngredientMatching.key(for:)` — never reaches the list at all.
    static func aggregate(
        _ entries: [MealPlanEntry],
        stapleKeys: Set<String> = []
    ) -> [AggregatedLine] {
        var lines: [AggregatedLine] = []
        /// Bucket index per key, including every alias that resolved to it, so
        /// the fuzzy comparison runs once per new spelling rather than per line.
        var indexByKey: [String: Int] = [:]
        var bucketKeys: [String] = []

        func bucket(for key: String, name: String, item: DishIngredient) -> Int {
            if let index = indexByKey[key] { return index }
            if let index = bucketKeys.firstIndex(where: { IngredientMatching.keysMatch($0, key) }) {
                indexByKey[key] = index
                return index
            }
            lines.append(AggregatedLine(
                name: name,
                normalizedName: Ingredient.normalize(name),
                category: item.ingredient?.category ?? .other,
                customAisleName: item.ingredient?.customAisleName
            ))
            bucketKeys.append(key)
            indexByKey[key] = lines.count - 1
            return lines.count - 1
        }

        for entry in entries where !entry.skipped {
            guard let dish = entry.dish else { continue }
            let base = max(dish.servings, 1)
            let factor = Double(entry.effectiveServings) / Double(base)

            for item in dish.sortedIngredients {
                // Pantry staples are always at home; see `PantryStaples`.
                guard item.ingredient?.isPantryStaple != true else { continue }
                let displayName = item.ingredient?.name
                    ?? item.rawText
                    ?? String(localized: "Ingredient")
                let amount = item.quantity?.scaled(by: factor)
                // "Salz und Pfeffer" is two things to buy — but only when there
                // is no amount that would have to be split along with it.
                let names = amount == nil ? IngredientMatching.components(of: displayName) : [displayName]

                for name in names {
                    let key = IngredientMatching.key(for: name)
                    // A staple can be spelled differently in the recipe than in
                    // the household's list, so match those by name too.
                    guard !stapleKeys.contains(where: { IngredientMatching.keysMatch($0, key) }) else {
                        continue
                    }

                    let index = bucket(for: key, name: name, item: item)
                    var line = lines[index]
                    line.name = IngredientMatching.preferredName(line.name, name)
                    line.normalizedName = Ingredient.normalize(line.name)
                    if line.category == .other, let category = item.ingredient?.category {
                        line.category = category
                    }
                    if line.customAisleName == nil {
                        line.customAisleName = item.ingredient?.customAisleName
                    }

                    if let amount {
                        let wasEmpty = line.quantity == nil
                        line.add(amount)
                        line.isApproximate = line.isApproximate || item.isApproximate
                        // The unit label belongs to the first amount that set
                        // the line's own dimension; a later one in a different
                        // dimension mustn't relabel it.
                        if wasEmpty || (line.displayUnit == nil && line.quantity?.dimension == amount.dimension) {
                            line.displayUnit = item.displayUnit
                        }
                    } else {
                        line.unmeasuredCount += 1
                    }

                    if let note = item.note, !note.isEmpty, !line.notes.contains(note) {
                        line.notes.append(note)
                    }
                    if !line.sourceDishNames.contains(dish.name) {
                        line.sourceDishNames.append(dish.name)
                    }
                    lines[index] = line
                }
            }
        }

        return lines.sorted {
            if $0.category.sortOrder != $1.category.sortOrder {
                return $0.category.sortOrder < $1.category.sortOrder
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func displayText(
        for line: AggregatedLine,
        system: UnitSystem,
        roundsAmounts: Bool = true,
        locale: Locale = .current
    ) -> String {
        var pieces: [String] = []
        if let quantity = line.quantity {
            let d = UnitConversion.string(
                for: quantity, system: system, preferredUnit: line.displayUnit,
                approximate: line.isApproximate, ingredientName: line.name,
                roundsAmounts: roundsAmounts, locale: locale
            )
            pieces.append((d.isApproximate ? "≈ " : "") + d.text)
        }
        // Amounts that couldn't be added together are read out side by side —
        // "500 g + 2 ×" is still one thing to buy.
        for extra in line.additionalQuantities {
            let d = UnitConversion.string(
                for: extra, system: system, preferredUnit: nil,
                approximate: line.isApproximate, ingredientName: line.name,
                roundsAmounts: roundsAmounts, locale: locale
            )
            pieces.append("+ " + (d.isApproximate ? "≈ " : "") + d.text)
        }
        if line.unmeasuredCount > 0 {
            pieces.append(line.quantity == nil && line.unmeasuredCount == 1
                          ? String(localized: "as needed")
                          : String(localized: "+ \(line.unmeasuredCount)×"))
        }
        return pieces.joined(separator: "  ")
    }

    // MARK: - Persistence

    @MainActor
    static func regenerate(
        range: DayRange,
        household: Household,
        system: UnitSystem,
        roundsAmounts: Bool = true,
        context: ModelContext
    ) {
        let start = range.start
        let end = range.end
        let predicate = #Predicate<MealPlanEntry> { $0.date >= start && $0.date < end && $0.skipped == false }
        let entries = (try? context.fetch(FetchDescriptor(predicate: predicate))) ?? []
        let staples = Set(household.pantryStaples.map { IngredientMatching.key(for: $0.name) })
        let aggregated = aggregate(entries, stapleKeys: staples)

        // Remember what was already ticked off, under the same key the merging
        // uses — a line that comes back spelled differently is still the one
        // the family already crossed out.
        let existing = household.shoppingItems ?? []
        var checkedByKey: [String: Bool] = [:]
        for item in existing where !item.isManual {
            checkedByKey[IngredientMatching.key(for: item.name)] = item.isChecked
        }

        // Replace generated items, keep manual ones.
        for item in existing where !item.isManual {
            context.delete(item)
        }

        let catalogue = household.ingredients ?? []
        for (index, line) in aggregated.enumerated() {
            let item = ShoppingListItem(name: line.name, category: line.category)
            item.household = household
            item.canonicalValue = line.quantity?.value
            item.dimension = line.quantity?.dimension
            item.additionalQuantities = line.additionalQuantities
            item.unmeasuredCount = line.unmeasuredCount
            item.isApproximate = line.isApproximate
            item.displayUnit = line.displayUnit
            item.displayText = displayText(
                for: line,
                system: system,
                roundsAmounts: roundsAmounts
            )
            item.sourceDishNames = line.sourceDishNames
            item.ingredient = IngredientMatching.match(line.name, in: catalogue)
            item.customAisleName = line.customAisleName
            item.isChecked = checkedByKey[IngredientMatching.key(for: line.name)] ?? false
            item.rangeStart = range.start
            item.rangeEnd = range.end
            item.sortIndex = line.category.sortOrder * 1000 + index
            context.insert(item)
        }

        try? context.save()
    }

    /// Put a line on the list by hand, the way the "Add an item" field does.
    ///
    /// The text is parsed for a leading amount ("2 Dosen Tomaten"), and the
    /// line is tied to the household's catalogue entry when there is one, so a
    /// hand-added item lands in the same aisle as the generated one would.
    /// Manual lines survive the next rebuild.
    @MainActor
    @discardableResult
    static func addManualItem(
        named text: String,
        household: Household,
        system: UnitSystem,
        roundsAmounts: Bool = true,
        context: ModelContext
    ) -> ShoppingListItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parsed = GermanUnitParser.parse(trimmed)
        let name = parsed.name.isEmpty ? trimmed : parsed.name
        let normalized = Ingredient.normalize(name)
        let ingredient = IngredientMatching.match(name, in: household.ingredients ?? [])

        let item = ShoppingListItem(name: name, category: ingredient?.category ?? .other, isManual: true)
        item.household = household
        item.ingredient = ingredient
        item.customAisleName = ingredient?.customAisleName
        if let quantity = parsed.quantity {
            item.canonicalValue = quantity.value
            item.dimension = quantity.dimension
            item.isApproximate = parsed.isApproximate
            item.displayUnit = parsed.displayUnit
            item.displayText = displayText(
                for: AggregatedLine(
                    name: name,
                    normalizedName: normalized,
                    category: item.category,
                    quantity: quantity,
                    displayUnit: parsed.displayUnit,
                    isApproximate: parsed.isApproximate
                ),
                system: system,
                roundsAmounts: roundsAmounts
            )
        }
        item.sortIndex = item.category.sortOrder * 1000 + 999
        context.insert(item)
        try? context.save()
        return item
    }

    /// Put a pantry staple on the list — the "we've run out of salt" case.
    /// Staples are never generated from the plan, so this is a manual line
    /// like any other and stays put when the list is rebuilt.
    @MainActor
    @discardableResult
    static func addManualItem(
        for ingredient: Ingredient,
        household: Household,
        context: ModelContext
    ) -> ShoppingListItem {
        let item = ShoppingListItem(name: ingredient.name, category: ingredient.category, isManual: true)
        item.household = household
        item.ingredient = ingredient
        item.customAisleName = ingredient.customAisleName
        item.sortIndex = ingredient.category.sortOrder * 1000 + 999
        context.insert(item)
        try? context.save()
        return item
    }

    /// Reformat persisted shopping amounts immediately after a unit or
    /// rounding preference changes. Canonical quantities remain untouched.
    static func refreshDisplayText(
        for items: [ShoppingListItem],
        system: UnitSystem,
        roundsAmounts: Bool
    ) {
        for item in items {
            let quantity = item.canonicalValue.flatMap { value in
                item.dimension.map { Quantity(value: value, dimension: $0) }
            }
            // Everything the merged line said, not only its first amount, so a
            // "500 g + 2 ×  + 1×" line survives a change of units intact.
            guard quantity != nil || !item.additionalQuantities.isEmpty || item.unmeasuredCount > 0 else {
                continue
            }
            let line = AggregatedLine(
                name: item.name,
                normalizedName: item.normalizedName,
                category: item.category,
                quantity: quantity,
                displayUnit: item.displayUnit,
                isApproximate: item.isApproximate,
                unmeasuredCount: item.unmeasuredCount,
                additionalQuantities: item.additionalQuantities
            )
            item.displayText = displayText(
                for: line,
                system: system,
                roundsAmounts: roundsAmounts
            )
        }
    }
}
