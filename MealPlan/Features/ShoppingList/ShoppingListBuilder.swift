import Foundation
import SwiftData

/// One aggregated shopping need, before it's turned into a `ShoppingListItem`.
struct AggregatedLine: Equatable, Sendable {
    var name: String
    var normalizedName: String
    var category: IngredientCategory
    var quantity: Quantity?
    var displayUnit: String?
    var isApproximate: Bool = false
    /// How many times the ingredient appeared without a measurable amount.
    var unmeasuredCount: Int = 0
    var notes: [String] = []
    var sourceDishNames: [String] = []
}

enum ShoppingListBuilder {

    // MARK: - Pure aggregation (unit-tested)

    /// Aggregate the ingredients of the given planned meals, scaling each
    /// dish to the head-count planned for that occasion and summing per
    /// ingredient + dimension.
    static func aggregate(_ entries: [MealPlanEntry]) -> [AggregatedLine] {
        var lines: [String: AggregatedLine] = [:]

        for entry in entries where !entry.skipped {
            guard let dish = entry.dish else { continue }
            let base = max(dish.servings, 1)
            let factor = Double(entry.effectiveServings) / Double(base)

            for item in dish.sortedIngredients {
                let displayName = item.ingredient?.name
                    ?? item.rawText
                    ?? String(localized: "Ingredient")
                let normalized = item.ingredient?.normalizedName ?? Ingredient.normalize(displayName)
                let category = item.ingredient?.category ?? .other
                let dimensionKey = item.quantity?.dimension.rawValue ?? "none"
                let key = "\(normalized)|\(dimensionKey)"

                var line = lines[key] ?? AggregatedLine(
                    name: displayName,
                    normalizedName: normalized,
                    category: category,
                    displayUnit: item.displayUnit
                )

                if let quantity = item.quantity {
                    let scaled = quantity.scaled(by: factor)
                    if let existing = line.quantity, let sum = existing.adding(scaled) {
                        line.quantity = sum
                    } else {
                        line.quantity = scaled
                    }
                    line.isApproximate = line.isApproximate || item.isApproximate
                    if line.displayUnit == nil { line.displayUnit = item.displayUnit }
                } else {
                    line.unmeasuredCount += 1
                }

                if let note = item.note, !note.isEmpty, !line.notes.contains(note) {
                    line.notes.append(note)
                }
                if !line.sourceDishNames.contains(dish.name) {
                    line.sourceDishNames.append(dish.name)
                }
                lines[key] = line
            }
        }

        return lines.values.sorted {
            if $0.category.sortOrder != $1.category.sortOrder {
                return $0.category.sortOrder < $1.category.sortOrder
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func displayText(for line: AggregatedLine, system: UnitSystem, locale: Locale = .current) -> String {
        var pieces: [String] = []
        if let quantity = line.quantity {
            let d = UnitConversion.string(
                for: quantity, system: system, preferredUnit: line.displayUnit,
                approximate: line.isApproximate, ingredientName: line.name, locale: locale
            )
            pieces.append((d.isApproximate ? "≈ " : "") + d.text)
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
        context: ModelContext
    ) {
        let start = range.start
        let end = range.end
        let predicate = #Predicate<MealPlanEntry> { $0.date >= start && $0.date < end && $0.skipped == false }
        let entries = (try? context.fetch(FetchDescriptor(predicate: predicate))) ?? []
        let aggregated = aggregate(entries)

        // Remember what was already ticked off.
        let existing = household.shoppingItems ?? []
        var checkedByName: [String: Bool] = [:]
        for item in existing where !item.isManual {
            checkedByName[item.normalizedName] = item.isChecked
        }

        // Replace generated items, keep manual ones.
        for item in existing where !item.isManual {
            context.delete(item)
        }

        for (index, line) in aggregated.enumerated() {
            let item = ShoppingListItem(name: line.name, category: line.category)
            item.household = household
            item.canonicalValue = line.quantity?.value
            item.dimension = line.quantity?.dimension
            item.isApproximate = line.isApproximate
            item.displayText = displayText(for: line, system: system)
            item.sourceDishNames = line.sourceDishNames
            item.isChecked = checkedByName[line.normalizedName] ?? false
            item.rangeStart = range.start
            item.rangeEnd = range.end
            item.sortIndex = line.category.sortOrder * 1000 + index
            context.insert(item)
        }

        try? context.save()
    }
}
