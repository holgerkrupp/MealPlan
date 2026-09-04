import Foundation
import SwiftData

/// A thing the family can cook. Can be as light as a name, or carry a full
/// recipe, ingredients, images and a source URL.
@Model
final class Dish {
    var uuid: UUID = UUID()
    var modifiedAt: Date = Date.now
    var name: String = ""
    var recipeText: String?
    var sourceURLString: String?
    /// Optional custom-scheme or universal link to the recipe in its source app.
    var deepLinkURLString: String?
    /// Identifier of the app a recipe was imported from, e.g. "Paprika".
    var importedSourceApp: String?
    /// The source app's own identifier for this recipe (Paprika's `uid`). The
    /// strongest duplicate signal there is: re-importing the same export twice
    /// matches on this even when the cook has since renamed the dish.
    var importedSourceID: String?
    /// Set on every dish in a variant group, so "Burger" can hold a smashed
    /// one, a halloumi one and Grandma's one without any of them being a
    /// duplicate of the others. `nil` for a dish that stands on its own.
    ///
    /// Deliberately a plain identifier rather than a relationship: the group
    /// has no state of its own beyond its name, and a value can't leave
    /// dangling records behind when a variant is deleted or fails to sync.
    var variantGroupID: UUID?
    /// The group's display name ("Burger"), copied onto each member so the
    /// grid can label a group without loading its siblings. Renaming a group
    /// rewrites it on every member; see `DishVariants.rename`.
    var variantGroupName: String?
    /// Lightweight personal organization that stays useful even when a
    /// household does not want to maintain a deep category hierarchy.
    var isFavorite: Bool = false
    /// Zero means unrated; 1...5 is the cook's personal rating.
    var rating: Int = 0
    /// User-defined collections such as "Weeknight" or "Christmas".
    var collectionNames: [String] = []
    /// Free-form labels the household invents as it goes ("vegan", "pork",
    /// "short prepwork"). A handful is suggested automatically on import and
    /// for new dishes; see `DishTagSuggester`. Stored as the words that were
    /// typed and compared through `DishTag`.
    var tagNames: [String] = []
    var servings: Int = 2
    var prepTimeMinutes: Int?
    var cookTimeMinutes: Int?
    var mealTypeTagsRaw: [String] = []
    var dietaryTagsRaw: [String] = []
    var seasonRaw: String?
    var createdByName: String?
    var dateCreated: Date = Date.now
    /// Denormalised for fast "not cooked in a while" queries.
    var lastUsedDate: Date?
    var usageCount: Int = 0
    /// Set when a recipe was imported with best-effort heuristics and the
    /// user should double-check it.
    var needsReview: Bool = false

    // MARK: Nutrition
    //
    // Values the recipe itself states, per serving of `servings`. A recipe
    // that came with its own figures beats anything we can add up from the
    // ingredient list, so these win outright when present — see
    // `NutritionEstimator.perServing(for:)`. Written by the schema.org
    // importer and by hand; `nil` everywhere else, which is the normal case.
    var statedEnergyKcalPerServing: Double?
    var statedProteinGramsPerServing: Double?
    var statedCarbGramsPerServing: Double?
    var statedFatGramsPerServing: Double?
    /// An emoji or SF Symbol shown wherever the dish has no photo. See `DishGlyph`.
    var glyphRaw: String?
    /// True while the placeholder is the app's own suggestion, so it can keep
    /// following the dish's name. Set to false the moment the user picks (or
    /// deliberately clears) one, and never re-derived after that.
    var glyphIsAuto: Bool = true

    @Relationship(deleteRule: .cascade, inverse: \DishIngredient.dish)
    var ingredients: [DishIngredient]? = []

    @Relationship(deleteRule: .cascade, inverse: \DishImage.dish)
    var images: [DishImage]? = []

    @Relationship(deleteRule: .nullify, inverse: \MealPlanEntry.dish)
    var entries: [MealPlanEntry]? = []

    @Relationship(deleteRule: .nullify, inverse: \CookedLog.dish)
    var cookedLogs: [CookedLog]? = []

    @Relationship(deleteRule: .nullify, inverse: \WeekTemplateEntry.dish)
    var templateEntries: [WeekTemplateEntry]? = []

    /// Standing arrangements that repeat this dish (Taco Tuesday and friends).
    /// Cascaded: a routine without its dish has nothing left to plan.
    @Relationship(deleteRule: .cascade, inverse: \MealRoutine.dish)
    var routines: [MealRoutine]? = []

    var household: Household?

    init(name: String = "") {
        self.uuid = UUID()
        self.name = name
        self.dateCreated = .now
    }

    // MARK: - Typed accessors

    var sourceURL: URL? {
        get { sourceURLString.flatMap(URL.init(string:)) }
        set { sourceURLString = newValue?.absoluteString }
    }

    var deepLinkURL: URL? {
        get { deepLinkURLString.flatMap(URL.init(string:)) }
        set { deepLinkURLString = newValue?.absoluteString }
    }

    /// Tags in display order.
    var sortedTagNames: [String] { DishTag.sorted(tagNames) }

    func hasTag(_ tag: String) -> Bool { DishTag.contains(tagNames, tag) }

    /// Adds a tag unless the dish already carries it under any spelling.
    func addTag(_ tag: String) {
        let merged = DishTag.merge(tagNames, adding: [tag])
        if merged != tagNames { tagNames = merged }
    }

    func removeTag(_ tag: String) {
        tagNames = DishTag.removing(tag, from: tagNames)
    }

    var mealTypeTags: Set<MealTypeTag> {
        get { Set(mealTypeTagsRaw.compactMap(MealTypeTag.init(rawValue:))) }
        set { mealTypeTagsRaw = newValue.map(\.rawValue).sorted() }
    }

    var dietaryTags: Set<DietaryTag> {
        get { Set(dietaryTagsRaw.compactMap(DietaryTag.init(rawValue:))) }
        set { dietaryTagsRaw = newValue.map(\.rawValue).sorted() }
    }

    var season: Season? {
        get { seasonRaw.flatMap(Season.init(rawValue:)) }
        set { seasonRaw = newValue?.rawValue }
    }

    var glyph: DishGlyph? {
        get { glyphRaw.flatMap(DishGlyph.init(rawValue:)) }
        set { glyphRaw = newValue?.rawValue }
    }

    /// The user's own choice, which stops the automatic suggestion from
    /// overwriting it. Passing `nil` means "no placeholder at all".
    func setGlyphManually(_ newGlyph: DishGlyph?) {
        glyph = newGlyph
        glyphIsAuto = false
    }

    /// Re-derives the placeholder from the dish's name, ingredients and meal
    /// tags. Does nothing once the user has chosen for themselves.
    func refreshAutoGlyph() {
        guard glyphIsAuto else { return }
        glyph = DishGlyphSuggester.suggestion(
            for: name,
            ingredientNames: sortedIngredients.compactMap { $0.ingredient?.name },
            mealTypeTags: mealTypeTags
        )
    }

    /// What the recipe says one serving contains, if it says anything.
    var statedNutritionPerServing: NutritionFacts? {
        guard let statedEnergyKcalPerServing else { return nil }
        return NutritionFacts(
            energyKcal: statedEnergyKcalPerServing,
            proteinGrams: statedProteinGramsPerServing ?? 0,
            carbGrams: statedCarbGramsPerServing ?? 0,
            fatGrams: statedFatGramsPerServing ?? 0
        )
    }

    func setStatedNutritionPerServing(_ facts: NutritionFacts?) {
        statedEnergyKcalPerServing = facts?.energyKcal
        statedProteinGramsPerServing = facts?.proteinGrams
        statedCarbGramsPerServing = facts?.carbGrams
        statedFatGramsPerServing = facts?.fatGrams
    }

    var sortedIngredients: [DishIngredient] {
        (ingredients ?? []).sorted { $0.sortIndex < $1.sortIndex }
    }

    var sortedImages: [DishImage] {
        (images ?? []).sorted { ($0.isPrimary ? 0 : 1, $0.sortIndex) < ($1.isPrimary ? 0 : 1, $1.sortIndex) }
    }

    var primaryImageData: Data? {
        sortedImages.first?.data
    }

    var totalTimeMinutes: Int? {
        switch (prepTimeMinutes, cookTimeMinutes) {
        case let (p?, c?): p + c
        case let (p?, nil): p
        case let (nil, c?): c
        case (nil, nil): nil
        }
    }

    /// Text searched by the recipe library. Keeping this as a computed value
    /// avoids a migration-prone denormalized search index.
    var searchableText: String {
        ([name, recipeText ?? ""]
            + sortedIngredients.compactMap { $0.ingredient?.name ?? $0.rawText }
            + collectionNames
            + tagNames)
            .joined(separator: " ")
    }

    /// True when this dish is one of several takes on the same thing.
    var isVariant: Bool { variantGroupID != nil }

    /// What to call the group this dish belongs to, falling back to the dish's
    /// own name for a group whose name was never set.
    var variantGroupDisplayName: String {
        let stored = variantGroupName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? name : stored
    }

    /// Whole days since the dish was last cooked, or `nil` if never cooked.
    func daysSinceLastCooked(reference: Date = .now, calendar: Calendar = .current) -> Int? {
        guard let lastUsedDate else { return nil }
        return calendar.dateComponents([.day], from: lastUsedDate, to: reference).day
    }
}
