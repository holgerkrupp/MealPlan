import Foundation
import SwiftData

/// A thing the family can cook. Can be as light as a name, or carry a full
/// recipe, ingredients, images and a source URL.
@Model
final class Dish {
    var uuid: UUID = UUID()
    var name: String = ""
    var recipeText: String?
    var sourceURLString: String?
    /// Identifier of the app a recipe was imported from, e.g. "Paprika".
    var importedSourceApp: String?
    /// Lightweight personal organization that stays useful even when a
    /// household does not want to maintain a deep category hierarchy.
    var isFavorite: Bool = false
    /// Zero means unrated; 1...5 is the cook's personal rating.
    var rating: Int = 0
    /// User-defined collections such as "Weeknight" or "Christmas".
    var collectionNames: [String] = []
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
            + collectionNames)
            .joined(separator: " ")
    }

    /// Whole days since the dish was last cooked, or `nil` if never cooked.
    func daysSinceLastCooked(reference: Date = .now, calendar: Calendar = .current) -> Int? {
        guard let lastUsedDate else { return nil }
        return calendar.dateComponents([.day], from: lastUsedDate, to: reference).day
    }
}
