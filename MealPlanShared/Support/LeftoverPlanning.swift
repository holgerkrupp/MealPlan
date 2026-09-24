import Foundation

struct PlannedIngredientRequirement: Equatable, Sendable {
    var ingredientKey: String
    var ingredientName: String
    var quantity: Quantity
    var sourceDishNames: [String]
    var sourceDates: [Date]
}

struct PredictedLeftover: Equatable, Sendable, Identifiable {
    var id: String { "\(ingredientKey)|\(remainder.dimension.rawValue)" }
    var ingredientKey: String
    var ingredientName: String
    var required: Quantity
    var purchased: Quantity
    var remainder: Quantity
    var packageSize: Quantity
    var packageCount: Int
    var sourceDishNames: [String]
    var sourceDates: [Date]
}

enum IngredientPackageCatalogue {
    /// Resolve bundled sizes and household rows without ever mutating either.
    static func effectiveSizes(
        for ingredientKey: String,
        countryCode: String,
        bundled: [PackageSizeDefinition] = IngredientPackageSeedData.all,
        userOverrides: [IngredientPackageSize] = []
    ) -> [PackageSizeDefinition] {
        let region = countryCode.uppercased()
        let bundledForIngredient = bundled.filter {
            $0.countryCode == region && IngredientMatching.keysMatch($0.ingredientKey, ingredientKey)
        }
        let user = userOverrides.filter {
            $0.countryCode.uppercased() == region &&
            IngredientMatching.keysMatch($0.ingredientKey, ingredientKey)
        }

        if user.contains(where: \.overridesProfile) {
            return user.compactMap(PackageSizeDefinition.init)
                .filter(\.isEnabled)
                .sorted(by: packageOrder)
        }

        var resolved = bundledForIngredient
        for model in user {
            guard let quantity = model.quantity else { continue }
            let definition = PackageSizeDefinition(model)
            if let shadowID = model.overridesBundledID ?? model.stableBundledID,
               let index = resolved.firstIndex(where: { $0.id == shadowID }) {
                resolved[index] = definition
            } else {
                resolved.append(definition)
            }
            _ = quantity // The guard also rejects malformed persisted rows.
        }
        return resolved.filter(\.isEnabled).sorted(by: packageOrder)
    }

    static func resetIngredient(_ ingredientKey: String, in household: Household) {
        let rows = household.packageSizeOverrides ?? []
        for row in rows where IngredientMatching.keysMatch(row.ingredientKey, ingredientKey) {
            household.packageSizeOverrides?.removeAll { $0.uuid == row.uuid }
        }
    }

    static func resetAll(in household: Household) {
        household.packageSizeOverrides = []
    }

    private static func packageOrder(_ lhs: PackageSizeDefinition, _ rhs: PackageSizeDefinition) -> Bool {
        if lhs.isPreferred != rhs.isPreferred { return lhs.isPreferred }
        if lhs.priority != rhs.priority { return lhs.priority == .common }
        if lhs.quantity.dimension != rhs.quantity.dimension {
            return lhs.quantity.dimension.rawValue < rhs.quantity.dimension.rawValue
        }
        if lhs.quantity.value != rhs.quantity.value { return lhs.quantity.value < rhs.quantity.value }
        return lhs.id < rhs.id
    }
}

enum LeftoverCalculator {
    static let defaultTolerance: [QuantityDimension: Double] = [
        .mass: 10,
        .volume: 10,
        .count: 0.25,
    ]

    /// The smallest remainder worth suggesting. The tolerance is deliberately
    /// small: it hides crumbs, not meaningful cooking quantities.
    static func remainder(
        for required: Quantity,
        packageSizes: [PackageSizeDefinition],
        tolerance: Double? = nil
    ) -> (purchased: Quantity, remainder: Quantity, packageSize: Quantity, packageCount: Int)? {
        guard required.value > 0, required.value.isFinite else { return nil }
        let candidates = packageSizes.filter {
            $0.isEnabled && $0.quantity.dimension == required.dimension && $0.quantity.value > 0
        }
        guard !candidates.isEmpty else { return nil }

        let smallest = candidates.map(\.quantity.value).min() ?? required.value
        let maxPackages = min(100, max(1, Int(ceil(required.value / smallest)) + 2))
        var best: Combination?

        func visit(_ index: Int, total: Double, counts: [Int], packageCount: Int) {
            if index == candidates.count {
                guard total >= required.value else { return }
                let combination = Combination(total: total, counts: counts, packageCount: packageCount)
                if best == nil || combination.isBetter(than: best!, required: required, candidates: candidates) {
                    best = combination
                }
                return
            }

            let size = candidates[index].quantity.value
            let remaining = maxPackages - packageCount
            for count in 0...remaining {
                visit(index + 1, total: total + Double(count) * size,
                      counts: counts + [count], packageCount: packageCount + count)
            }
        }
        visit(0, total: 0, counts: [], packageCount: 0)

        guard let best else { return nil }
        let purchased = Quantity(value: best.total, dimension: required.dimension)
        let leftover = Quantity(value: max(0, best.total - required.value), dimension: required.dimension)
        let limit = tolerance ?? defaultTolerance[required.dimension] ?? 0
        guard leftover.value > limit else { return nil }
        let selected = candidates.enumerated().first { best.counts[$0.offset] > 0 }?.element.quantity
            ?? candidates[0].quantity
        return (purchased, leftover, selected, best.packageCount)
    }

    static func requirements(for entries: [MealPlanEntry]) -> [PlannedIngredientRequirement] {
        var result: [PlannedIngredientRequirement] = []
        for entry in entries where !entry.skipped && !entry.isEatingOut {
            guard let dish = entry.dish else { continue }
            let factor = Double(entry.effectiveServings) / Double(max(1, dish.servings))
            for line in dish.sortedIngredients {
                guard let quantity = line.quantity?.scaled(by: factor), quantity.value > 0 else { continue }
                guard line.ingredient?.isPantryStaple != true else { continue }
                let name = line.ingredient?.name ?? line.rawText ?? String(localized: "Ingredient")
                add(
                    PlannedIngredientRequirement(
                        ingredientKey: IngredientMatching.key(for: name), ingredientName: name,
                        quantity: quantity, sourceDishNames: [dish.name], sourceDates: [entry.date]
                    ), to: &result
                )
            }
        }
        return result
    }

    static func calculate(
        entries: [MealPlanEntry],
        countryCode: String,
        userOverrides: [IngredientPackageSize] = [],
        bundled: [PackageSizeDefinition] = IngredientPackageSeedData.all,
        tolerance: [QuantityDimension: Double] = defaultTolerance
    ) -> [PredictedLeftover] {
        requirements(for: entries).compactMap { requirement in
            let sizes = IngredientPackageCatalogue.effectiveSizes(
                for: requirement.ingredientKey, countryCode: countryCode,
                bundled: bundled, userOverrides: userOverrides
            )
            guard let result = remainder(
                for: requirement.quantity,
                packageSizes: sizes,
                tolerance: tolerance[requirement.quantity.dimension]
            ) else { return nil }
            return PredictedLeftover(
                ingredientKey: requirement.ingredientKey, ingredientName: requirement.ingredientName,
                required: requirement.quantity, purchased: result.purchased, remainder: result.remainder,
                packageSize: result.packageSize, packageCount: result.packageCount,
                sourceDishNames: requirement.sourceDishNames, sourceDates: requirement.sourceDates
            )
        }
    }

    private static func add(_ requirement: PlannedIngredientRequirement, to result: inout [PlannedIngredientRequirement]) {
        guard let index = result.firstIndex(where: {
            IngredientMatching.keysMatch($0.ingredientKey, requirement.ingredientKey) &&
            $0.quantity.dimension == requirement.quantity.dimension
        }) else {
            result.append(requirement)
            return
        }
        result[index].quantity = result[index].quantity.adding(requirement.quantity) ?? result[index].quantity
        result[index].ingredientName = IngredientMatching.preferredName(
            result[index].ingredientName, requirement.ingredientName
        )
        for name in requirement.sourceDishNames where !result[index].sourceDishNames.contains(name) {
            result[index].sourceDishNames.append(name)
        }
        result[index].sourceDates.append(contentsOf: requirement.sourceDates)
    }

    private struct Combination {
        var total: Double
        var counts: [Int]
        var packageCount: Int

        func isBetter(
            than other: Combination,
            required: Quantity,
            candidates: [PackageSizeDefinition]
        ) -> Bool {
            let excess = total - required.value
            let otherExcess = other.total - required.value
            if abs(excess - otherExcess) > 0.000_001 { return excess < otherExcess }
            if packageCount != other.packageCount { return packageCount < other.packageCount }
            let preferred = counts.enumerated().reduce(0) { $0 + (candidates[$1.offset].isPreferred ? $1.element : 0) }
            let otherPreferred = other.counts.enumerated().reduce(0) { $0 + (candidates[$1.offset].isPreferred ? $1.element : 0) }
            if preferred != otherPreferred { return preferred > otherPreferred }
            return counts.lexicographicallyPrecedes(other.counts)
        }
    }
}

struct LeftoverDishSuggestion: Identifiable {
    var id: UUID { dish.uuid }
    var dish: Dish
    var score: Double
    var uses: [LeftoverDishUse]
    var reasons: [String]
    var expectedLeftoverReduction: [Quantity]
}

struct LeftoverDishUse: Identifiable {
    var id: String
    var ingredientName: String
    var quantity: Quantity
    var available: Quantity
}

enum LeftoverDishSuggester {
    static func suggestions(
        for leftovers: [PredictedLeftover],
        dishes: [Dish],
        servings: Int,
        countryCode: String = "DE",
        userOverrides: [IngredientPackageSize] = [],
        bundled: [PackageSizeDefinition] = IngredientPackageSeedData.all,
        limit: Int = 5
    ) -> [LeftoverDishSuggestion] {
        guard !leftovers.isEmpty else { return [] }
        return dishes.compactMap { dish in
            guard !dish.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let requirements = requirements(for: dish, servings: servings)
            var uses: [LeftoverDishUse] = []
            var usedIDs = Set<String>()
            var score = 0.0
            var unrelatedWaste = 0.0
            var unrelatedCount = 0

            for requirement in requirements {
                guard let leftover = leftovers.first(where: {
                    !usedIDs.contains($0.id) &&
                    IngredientMatching.keysMatch($0.ingredientKey, requirement.ingredientKey) &&
                    $0.remainder.dimension == requirement.quantity.dimension
                }) else {
                    unrelatedCount += 1
                    if let sizes = packageSizes(for: requirement, countryCode: countryCode, userOverrides: userOverrides, bundled: bundled),
                       let waste = LeftoverCalculator.remainder(for: requirement.quantity, packageSizes: sizes) {
                        unrelatedWaste += waste.remainder.value
                    }
                    continue
                }

                usedIDs.insert(leftover.id)
                let amount = min(leftover.remainder.value, requirement.quantity.value)
                let closeness = 1 - abs(leftover.remainder.value - requirement.quantity.value)
                    / max(leftover.remainder.value, requirement.quantity.value)
                let coverage = amount / leftover.remainder.value
                score += coverage * 100 + max(0, closeness) * 20
                if requirement.quantity.value > leftover.remainder.value * 1.25 {
                    score -= (requirement.quantity.value - leftover.remainder.value) / leftover.remainder.value * 12
                }
                uses.append(LeftoverDishUse(
                    id: "\(leftover.id)-\(requirement.ingredientKey)",
                    ingredientName: leftover.ingredientName,
                    quantity: Quantity(value: amount, dimension: leftover.remainder.dimension),
                    available: leftover.remainder
                ))
            }

            guard !uses.isEmpty else { return nil }
            score += Double(uses.count) * 12
            score -= Double(unrelatedCount) * 8
            score -= min(60, unrelatedWaste / 10)
            let reasons = uses.map { use in
                "Uses ~\(format(use.quantity)) of the \(format(use.available)) \(use.ingredientName) likely left over."
            }
            return LeftoverDishSuggestion(
                dish: dish, score: score, uses: uses, reasons: reasons,
                expectedLeftoverReduction: uses.map { $0.quantity }
            )
        }
        .sorted {
            if abs($0.score - $1.score) > 0.000_001 { return $0.score > $1.score }
            return $0.dish.name.localizedCaseInsensitiveCompare($1.dish.name) == .orderedAscending
        }
        .prefix(max(0, limit))
        .map { $0 }
    }

    private static func requirements(for dish: Dish, servings: Int) -> [PlannedIngredientRequirement] {
        let factor = Double(max(1, servings)) / Double(max(1, dish.servings))
        var result: [PlannedIngredientRequirement] = []
        for line in dish.sortedIngredients {
            guard let quantity = line.quantity?.scaled(by: factor), quantity.value > 0 else { continue }
            let name = line.ingredient?.name ?? line.rawText ?? String(localized: "Ingredient")
            let requirement = PlannedIngredientRequirement(
                ingredientKey: IngredientMatching.key(for: name), ingredientName: name,
                quantity: quantity, sourceDishNames: [dish.name], sourceDates: []
            )
            if let index = result.firstIndex(where: {
                IngredientMatching.keysMatch($0.ingredientKey, requirement.ingredientKey) &&
                $0.quantity.dimension == requirement.quantity.dimension
            }) {
                result[index].quantity = result[index].quantity.adding(quantity) ?? result[index].quantity
            } else {
                result.append(requirement)
            }
        }
        return result
    }

    private static func packageSizes(
        for requirement: PlannedIngredientRequirement,
        countryCode: String,
        userOverrides: [IngredientPackageSize],
        bundled: [PackageSizeDefinition]
    ) -> [PackageSizeDefinition]? {
        let sizes = IngredientPackageCatalogue.effectiveSizes(
            for: requirement.ingredientKey, countryCode: countryCode,
            bundled: bundled, userOverrides: userOverrides
        ).filter { $0.quantity.dimension == requirement.quantity.dimension }
        return sizes.isEmpty ? nil : sizes
    }

    private static func format(_ quantity: Quantity) -> String {
        let value: String
        if abs(quantity.value.rounded() - quantity.value) < 0.000_001 {
            value = String(Int(quantity.value.rounded()))
        } else {
            value = String(format: "%.1f", quantity.value).replacingOccurrences(of: ".0", with: "")
        }
        switch quantity.dimension {
        case .mass: return "\(value) g"
        case .volume: return "\(value) ml"
        case .count: return "\(value)"
        }
    }
}
