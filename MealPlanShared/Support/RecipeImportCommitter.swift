import Foundation
import SwiftData

/// The single place recipes actually enter the library, whether they came from
/// the share sheet, a file opened in Finder or the Dishes screen's importer.
enum RecipeImportCommitter {

    struct Result {
        var imported: Int = 0
        var variants: Int = 0
        var skipped: Int = 0
        /// Dishes created, in the order they were imported.
        var dishes: [Dish] = []

        var isEmpty: Bool { imported == 0 }

        /// A sentence for the alert / confirmation the user sees.
        var summary: String {
            switch (imported, variants, skipped) {
            case (0, _, let skipped) where skipped > 0:
                String(localized: "Everything in that file is already in your library.")
            case (0, _, _):
                String(localized: "No recipes to import.")
            case (let imported, 0, 0):
                String(localized: "Imported \(imported) recipes.")
            case (let imported, 0, let skipped):
                String(localized: "Imported \(imported) recipes, skipped \(skipped) duplicates.")
            case (let imported, let variants, 0):
                String(localized: "Imported \(imported) recipes, \(variants) of them as variants.")
            case (let imported, let variants, let skipped):
                String(localized: "Imported \(imported) recipes (\(variants) as variants), skipped \(skipped) duplicates.")
            }
        }
    }

    /// Imports everything the user left ticked. A recipe planned as a variant
    /// joins the matched dish's group, so a second Burger sits next to the
    /// first instead of replacing or being dropped for it.
    @MainActor
    @discardableResult
    static func commit(
        _ plan: [PlannedRecipeImport],
        household: Household?,
        createdByName: String?,
        context: ModelContext
    ) -> Result {
        var result = Result()
        var library = (try? context.fetch(FetchDescriptor<Dish>())) ?? []

        for item in plan {
            guard item.include else {
                result.skipped += 1
                continue
            }
            let dish = DishBuilder.makeDish(
                from: item.recipe,
                household: household,
                createdByName: createdByName,
                context: context
            )
            result.imported += 1
            result.dishes.append(dish)

            if case .variant(let reference) = item.outcome,
               let sibling = library.first(where: { $0.uuid == reference.uuid }) {
                DishVariants.join(dish, with: sibling)
                result.variants += 1
            }
            library.append(dish)
        }

        try? context.save()
        return result
    }

    /// Plan and commit in one step, for the callers that have no review UI
    /// (the share extension, a file opened from Finder).
    @MainActor
    @discardableResult
    static func importAll(
        _ recipes: [ImportedRecipe],
        household: Household?,
        createdByName: String?,
        context: ModelContext
    ) -> Result {
        let library = (try? context.fetch(FetchDescriptor<Dish>())) ?? []
        return commit(
            RecipeImportPlanner.plan(recipes, against: library),
            household: household,
            createdByName: createdByName,
            context: context
        )
    }

    /// Reads a recipe file the user picked or opened. Handles the security
    /// scope the file picker hands back for a document outside the sandbox.
    static func recipes(fromFileAt url: URL) throws -> [ImportedRecipe] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        if RecipeFileType.isMealPlanArchive(url) {
            return try MealPlanRecipeArchive.importedRecipes(from: data)
        }
        if RecipeFileType.isImportable(url) {
            return try PaprikaArchive.recipes(from: data)
        }
        // An unfamiliar extension is worth a try: AirDrop and mail attachments
        // routinely arrive as `.zip` or with no extension at all.
        if let recipes = try? MealPlanRecipeArchive.importedRecipes(from: data), !recipes.isEmpty {
            return recipes
        }
        return try PaprikaArchive.recipes(from: data)
    }
}
