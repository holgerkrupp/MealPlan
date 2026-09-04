import Foundation
import SwiftData

/// A complete, portable snapshot of one household's store — every dish, plan,
/// routine, shopping line, template and setting — in a single JSON file.
///
/// This exists because CloudKit's Development and Production environments hold
/// *separate* record stores. Deploying the schema to Production does not carry
/// any data with it, and there is no API that copies private-database records
/// between environments. So the only way to take the library built up in an
/// Xcode build over to a TestFlight build is to carry it out through a file:
/// export here, restore there, and let the production container mirror the
/// restored rows up on its own. See `MealPlanRecipeArchive` for the smaller,
/// shareable recipes-only format.
struct MealPlanBackup: Codable, Sendable {
    static let currentVersion = 1
    static let formatName = "MealPlan Backup"

    var format: String = formatName
    var version: Int = currentVersion
    var exportedAt: Date = .now
    /// True when dish photos and cooked-meal snapshots are included. A backup
    /// written without them is a fraction of the size and still restores the
    /// whole plan — worth having when the point is to move the *data*.
    var includesPhotos: Bool = true
    /// Where this file came from, so the restore screen can say "exported from
    /// the Development build" rather than leaving the user to guess.
    var origin: Origin?
    /// How many `Household` rows the exported store held. Optional so files
    /// written before this was recorded still decode.
    var householdCount: Int?

    var household: PortableHousehold
    var mealTypes: [PortableMealType] = []
    var members: [PortableMember] = []
    /// The household's ingredient catalogue, keyed by `normalizedName`. Dish
    /// lines and shopping items refer to entries here by that key.
    var ingredients: [PortableIngredient] = []
    var dishes: [PortableDish] = []
    var entries: [PortableEntry] = []
    var routines: [PortableRoutine] = []
    var cookedLogs: [PortableCookedLog] = []
    var shoppingItems: [PortableShoppingItem] = []
    var weekTemplates: [PortableWeekTemplate] = []
    /// Optional so backups from before recipe discovery still decode. Article
    /// bodies never appear here; only the synced feed metadata does.
    var recipeFeeds: [PortableRecipeFeed]? = nil
    var recipeBookmarks: [PortableRecipeBookmark]? = nil

    // MARK: - Portable shapes

    struct Origin: Codable, Sendable {
        var appVersion: String?
        var build: String?
        /// "Development", "Production" or "Unknown" — see `BuildEnvironment`.
        var cloudEnvironment: String?
        var deviceName: String?
    }

    struct PortableHousehold: Codable, Sendable {
        var uuid: UUID
        var name: String
        var unitSystemRaw: String
        var roundsDisplayedAmounts: Bool
        var calendarStyleRaw: String
        var localeIdentifier: String
        var dateCreated: Date
        /// Whether this household had already been given the default pantry
        /// staples. Optional so files written before staples became a
        /// household setting still decode.
        var didSeedPantryStaples: Bool? = nil
        /// Optional so backups written before the household had a standard
        /// portion count still decode; `nil` reads back as the default 2.
        var standardServings: Int? = nil
        /// Nutrition display preferences. Optional for the same reason;
        /// `nil` reads back as "shown, in kcal".
        var showsNutritionEstimates: Bool? = nil
        var energyUnitRaw: String? = nil
    }

    struct PortableMealType: Codable, Sendable {
        var uuid: UUID
        var key: String
        var name: String
        var symbolName: String
        var sortOrder: Int
    }

    struct PortableMember: Codable, Sendable {
        var name: String
        var roleRaw: String
        var isCurrentUser: Bool
        var dateAdded: Date
    }

    struct PortableIngredient: Codable, Sendable {
        var name: String
        var normalizedName: String
        var categoryRaw: String
        var customAisleName: String?
        var isPantryStaple: Bool
        // Nutrition values somebody entered or imported for this ingredient.
        // Optional so files written before nutrition existed still decode,
        // which is why the format version doesn't move.
        var nutritionEnergyKcal: Double? = nil
        var nutritionProteinGrams: Double? = nil
        var nutritionCarbGrams: Double? = nil
        var nutritionFatGrams: Double? = nil
        var nutritionReferenceRaw: String? = nil
        var nutritionSourceRaw: String? = nil
    }

    struct PortableDish: Codable, Sendable {
        var uuid: UUID
        var name: String
        var recipeText: String?
        var sourceURLString: String?
        var deepLinkURLString: String?
        var importedSourceApp: String?
        var importedSourceID: String?
        var variantGroupID: UUID?
        var variantGroupName: String?
        var isFavorite: Bool
        var rating: Int
        var collectionNames: [String]
        var tagNames: [String]
        var servings: Int
        var prepTimeMinutes: Int?
        var cookTimeMinutes: Int?
        var mealTypeTagsRaw: [String]
        var dietaryTagsRaw: [String]
        var seasonRaw: String?
        var createdByName: String?
        var dateCreated: Date
        var lastUsedDate: Date?
        var usageCount: Int
        var needsReview: Bool
        var glyphRaw: String?
        var glyphIsAuto: Bool
        /// Figures the recipe itself stated, per serving. Optional for the
        /// same backwards-compatibility reason as the ingredient values.
        var statedEnergyKcalPerServing: Double? = nil
        var statedProteinGramsPerServing: Double? = nil
        var statedCarbGramsPerServing: Double? = nil
        var statedFatGramsPerServing: Double? = nil
        var images: [PortableImage]
        var ingredients: [PortableDishIngredient]
    }

    struct PortableImage: Codable, Sendable, Equatable {
        var data: Data?
        var sortIndex: Int
        var isPrimary: Bool
        var dateAdded: Date
    }

    struct PortableDishIngredient: Codable, Sendable, Equatable {
        /// Key into `ingredients`; `nil` for a line that was never resolved to
        /// a catalogue entry (a free-text "a pinch of something").
        var ingredientKey: String?
        var canonicalValue: Double?
        var canonicalDimensionRaw: String?
        var displayUnit: String?
        var isApproximate: Bool
        var note: String?
        var rawText: String?
        var sortIndex: Int
    }

    struct PortableEntry: Codable, Sendable {
        var uuid: UUID
        var date: Date
        var mealKey: String
        var dishUUID: UUID?
        var servingsOverride: Int?
        var note: String?
        var sortIndex: Int
        var reactionRaw: String?
        var skipped: Bool
        var prepReminder: Bool
        var plannedByName: String?
        var lastEditedByName: String?
        var lastEditedDate: Date?
        var isEatingOut: Bool
        var placeName: String?
        var placeAddress: String?
        var placeLatitude: Double?
        var placeLongitude: Double?
        var routineUUID: UUID?
    }

    struct PortableRoutine: Codable, Sendable {
        var uuid: UUID
        var dishUUID: UUID?
        var mealKey: String
        var weekday: Int
        var intervalWeeks: Int
        var startDate: Date
        var isActive: Bool
        var plannedThrough: Date?
        var dateCreated: Date
    }

    struct PortableCookedLog: Codable, Sendable {
        /// Optional so backups written before this was tracked still decode;
        /// falls back to a fresh identity on restore.
        var uuid: UUID?
        var date: Date
        var dishName: String?
        var servings: Int?
        var photoData: Data?
        var dishUUID: UUID?
        var entryUUID: UUID?
    }

    struct PortableShoppingItem: Codable, Sendable {
        /// Optional so backups written before this was tracked still decode;
        /// falls back to a fresh identity on restore.
        var uuid: UUID?
        var name: String
        var normalizedName: String
        var categoryRaw: String
        var customAisleName: String?
        var canonicalValue: Double?
        var canonicalDimensionRaw: String?
        var displayText: String?
        var displayUnit: String?
        var isChecked: Bool
        var isManual: Bool
        var isApproximate: Bool
        var sortIndex: Int
        var rangeStart: Date?
        var rangeEnd: Date?
        var sourceDishNames: [String]
        var dateCreated: Date
        var ingredientKey: String?
        /// The merged line's other amounts and how many of its recipe lines
        /// gave none. Optional so files written before shopping lines were
        /// merged still decode.
        var additionalAmountsRaw: [String]? = nil
        var unmeasuredCount: Int? = nil
    }

    struct PortableWeekTemplate: Codable, Sendable {
        var uuid: UUID
        var name: String
        var createdByName: String?
        var dateCreated: Date
        var entries: [PortableWeekTemplateEntry]
    }

    struct PortableWeekTemplateEntry: Codable, Sendable, Equatable {
        var weekday: Int
        var mealKey: String
        var dishUUID: UUID?
        var servingsOverride: Int?
        var sortIndex: Int
    }

    struct PortableRecipeFeed: Codable, Sendable {
        var uuid: UUID
        var title: String
        var siteURLString: String
        var feedURLString: String
        var etag: String?
        var lastModified: String?
        var lastFetchedAt: Date?
        var firstFailureAt: Date?
        var consecutiveFailures: Int
        var nextRetryAt: Date?
        var lastHTTPStatus: Int?
        var lastErrorMessage: String?
        var dateAdded: Date
        var items: [PortableRecipeFeedItem]
    }

    struct PortableRecipeFeedItem: Codable, Sendable {
        var uuid: UUID
        var stableID: String
        var title: String
        var urlString: String
        var author: String?
        var summary: String?
        var publishedAt: Date?
        var fetchedAt: Date
    }

    struct PortableRecipeBookmark: Codable, Sendable {
        var uuid: UUID
        var title: String
        var urlString: String
        var dateAdded: Date
    }

    /// What a backup holds, for the "this is what you're about to write /
    /// restore" summary. Counting is cheap and needs no store access.
    struct Contents: Sendable, Equatable {
        /// How many `Household` rows the store held. More than one means two
        /// devices each seeded their own before the first CloudKit sync;
        /// restoring folds them back into a single family.
        var households = 0
        var dishes = 0
        var plannedMeals = 0
        var routines = 0
        var cookedMeals = 0
        var shoppingItems = 0
        var weekTemplates = 0
        var photos = 0
    }

    var contents: Contents {
        Contents(
            households: householdCount ?? 1,
            dishes: dishes.count,
            plannedMeals: entries.count,
            routines: routines.count,
            cookedMeals: cookedLogs.count,
            shoppingItems: shoppingItems.count,
            weekTemplates: weekTemplates.count,
            photos: dishes.reduce(0) { $0 + $1.images.count }
                + cookedLogs.filter { $0.photoData != nil }.count
        )
    }
}

// MARK: - Writing

extension MealPlanBackup {

    /// Every row a backup covers, gathered in one place.
    ///
    /// Exists as its own type so the mapping below can be exercised without a
    /// `ModelContainer` — standing one up inside the app test host crashes it,
    /// so the tests build these arrays out of transient model objects instead.
    struct StoreRows {
        var households: [Household] = []
        var mealTypes: [MealType] = []
        var members: [HouseholdMember] = []
        var ingredients: [Ingredient] = []
        var dishes: [Dish] = []
        var entries: [MealPlanEntry] = []
        var routines: [MealRoutine] = []
        var cookedLogs: [CookedLog] = []
        var shoppingItems: [ShoppingListItem] = []
        var weekTemplates: [WeekTemplate] = []
        var recipeFeeds: [RecipeFeed] = []
        var recipeBookmarks: [RecipeBookmark] = []

        init() {}

        /// Fetches every model type directly.
        ///
        /// Deliberately not walked from a `Household`'s relationships. The app
        /// reads dishes, ingredients and the rest through `@Query` /
        /// `context.fetch` everywhere, so a row whose `household`
        /// back-reference was never set — or that hangs off a second
        /// `Household` created by another device before the first CloudKit
        /// sync — is perfectly visible in the app while being invisible from
        /// the household. A backup that walked the household would silently
        /// drop exactly those rows.
        @MainActor
        init(fetchedFrom context: ModelContext) throws {
            households = try context.fetch(FetchDescriptor<Household>())
            mealTypes = try context.fetch(FetchDescriptor<MealType>())
            members = try context.fetch(FetchDescriptor<HouseholdMember>())
            ingredients = try context.fetch(FetchDescriptor<Ingredient>())
            dishes = try context.fetch(FetchDescriptor<Dish>())
            entries = try context.fetch(FetchDescriptor<MealPlanEntry>())
            routines = try context.fetch(FetchDescriptor<MealRoutine>())
            cookedLogs = try context.fetch(FetchDescriptor<CookedLog>())
            shoppingItems = try context.fetch(FetchDescriptor<ShoppingListItem>())
            weekTemplates = try context.fetch(FetchDescriptor<WeekTemplate>())
            recipeFeeds = try context.fetch(FetchDescriptor<RecipeFeed>())
            recipeBookmarks = try context.fetch(FetchDescriptor<RecipeBookmark>())
        }
    }

    @MainActor
    static func make(from context: ModelContext, includePhotos: Bool = true) throws -> MealPlanBackup {
        make(from: try StoreRows(fetchedFrom: context), includePhotos: includePhotos)
    }

    /// Snapshot the whole store.
    ///
    /// Household *settings* come from the oldest household; everything else is
    /// re-attached to it on restore, which folds a split store back into the
    /// one family this app is designed around.
    @MainActor
    static func make(from rows: StoreRows, includePhotos: Bool = true) -> MealPlanBackup {
        let households = rows.households
            .sorted { ($0.dateCreated, $0.uuid.uuidString) < ($1.dateCreated, $1.uuid.uuidString) }
        let primary = households.first

        // One catalogue entry per normalized name. CloudKit has no unique
        // constraints, so a synced store can hold two `Ingredient` rows for
        // "Salz"; keying on the normalized name folds them back into one,
        // which is what the shopping list already treats them as.
        var catalogue: [String: PortableIngredient] = [:]
        func remember(_ ingredient: Ingredient) {
            let key = ingredient.normalizedName
            if catalogue[key] == nil {
                catalogue[key] = PortableIngredient(
                    name: ingredient.name,
                    normalizedName: key,
                    categoryRaw: ingredient.categoryRaw,
                    customAisleName: ingredient.customAisleName,
                    isPantryStaple: ingredient.isPantryStaple,
                    nutritionEnergyKcal: ingredient.nutritionEnergyKcal,
                    nutritionProteinGrams: ingredient.nutritionProteinGrams,
                    nutritionCarbGrams: ingredient.nutritionCarbGrams,
                    nutritionFatGrams: ingredient.nutritionFatGrams,
                    nutritionReferenceRaw: ingredient.nutritionReferenceRaw,
                    nutritionSourceRaw: ingredient.nutritionSourceRaw
                )
            } else if ingredient.isPantryStaple {
                // Merging duplicates: a pantry staple stays a pantry staple.
                catalogue[key]?.isPantryStaple = true
            }
        }
        func key(for ingredient: Ingredient?) -> String? {
            guard let ingredient else { return nil }
            remember(ingredient)
            return ingredient.normalizedName
        }
        for ingredient in rows.ingredients { remember(ingredient) }

        var backup = MealPlanBackup(
            household: PortableHousehold(
                uuid: primary?.uuid ?? UUID(),
                name: primary?.name ?? String(localized: "Family"),
                unitSystemRaw: primary?.unitSystemRaw ?? UnitSystem.metric.rawValue,
                roundsDisplayedAmounts: primary?.roundsDisplayedAmounts ?? true,
                calendarStyleRaw: CalendarStyle.week.rawValue,
                localeIdentifier: primary?.localeIdentifier ?? Locale.current.identifier,
                dateCreated: primary?.dateCreated ?? .now,
                didSeedPantryStaples: primary?.didSeedPantryStaples,
                standardServings: primary?.scalingServings ?? Household.defaultStandardServings,
                showsNutritionEstimates: primary?.showsNutritionEstimates,
                energyUnitRaw: primary?.energyUnitRaw
            )
        )
        backup.includesPhotos = includePhotos
        backup.householdCount = households.count
        backup.origin = Origin(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
            cloudEnvironment: BuildEnvironment.cloudKit.rawValue,
            deviceName: nil
        )

        // Meal types are de-duplicated by key the same way `MealType.ensure`
        // does, so a split store doesn't restore two "dinner" meals.
        var seenMealKeys = Set<String>()
        backup.mealTypes = rows.mealTypes
            .sorted { ($0.sortOrder, $0.uuid.uuidString) < ($1.sortOrder, $1.uuid.uuidString) }
            .filter { seenMealKeys.insert($0.key).inserted }
            .map {
                PortableMealType(
                    uuid: $0.uuid,
                    key: $0.key,
                    name: $0.name,
                    symbolName: $0.symbolName,
                    sortOrder: $0.sortOrder
                )
            }

        backup.members = rows.members.map {
            PortableMember(
                name: $0.name,
                roleRaw: $0.roleRaw,
                isCurrentUser: $0.isCurrentUser,
                dateAdded: $0.dateAdded
            )
        }

        backup.dishes = rows.dishes.map { dish in
            PortableDish(
                uuid: dish.uuid,
                name: dish.name,
                recipeText: dish.recipeText,
                sourceURLString: dish.sourceURLString,
                deepLinkURLString: dish.deepLinkURLString,
                importedSourceApp: dish.importedSourceApp,
                importedSourceID: dish.importedSourceID,
                variantGroupID: dish.variantGroupID,
                variantGroupName: dish.variantGroupName,
                isFavorite: dish.isFavorite,
                rating: dish.rating,
                collectionNames: dish.collectionNames,
                tagNames: dish.tagNames,
                servings: dish.servings,
                prepTimeMinutes: dish.prepTimeMinutes,
                cookTimeMinutes: dish.cookTimeMinutes,
                mealTypeTagsRaw: dish.mealTypeTagsRaw,
                dietaryTagsRaw: dish.dietaryTagsRaw,
                seasonRaw: dish.seasonRaw,
                createdByName: dish.createdByName,
                dateCreated: dish.dateCreated,
                lastUsedDate: dish.lastUsedDate,
                usageCount: dish.usageCount,
                needsReview: dish.needsReview,
                glyphRaw: dish.glyphRaw,
                glyphIsAuto: dish.glyphIsAuto,
                statedEnergyKcalPerServing: dish.statedEnergyKcalPerServing,
                statedProteinGramsPerServing: dish.statedProteinGramsPerServing,
                statedCarbGramsPerServing: dish.statedCarbGramsPerServing,
                statedFatGramsPerServing: dish.statedFatGramsPerServing,
                images: includePhotos ? dish.sortedImages.map {
                    PortableImage(
                        data: $0.data,
                        sortIndex: $0.sortIndex,
                        isPrimary: $0.isPrimary,
                        dateAdded: $0.dateAdded
                    )
                } : [],
                ingredients: dish.sortedIngredients.map { line in
                    PortableDishIngredient(
                        ingredientKey: key(for: line.ingredient),
                        canonicalValue: line.canonicalValue,
                        canonicalDimensionRaw: line.canonicalDimensionRaw,
                        displayUnit: line.displayUnit,
                        isApproximate: line.isApproximate,
                        note: line.note,
                        rawText: line.rawText,
                        sortIndex: line.sortIndex
                    )
                }
            )
        }

        backup.entries = rows.entries.map { entry in
            PortableEntry(
                uuid: entry.uuid,
                date: entry.date,
                mealKey: entry.mealSlotRaw,
                dishUUID: entry.dish?.uuid,
                servingsOverride: entry.servingsOverride,
                note: entry.note,
                sortIndex: entry.sortIndex,
                reactionRaw: entry.reactionRaw,
                skipped: entry.skipped,
                prepReminder: entry.prepReminder,
                plannedByName: entry.plannedByName,
                lastEditedByName: entry.lastEditedByName,
                lastEditedDate: entry.lastEditedDate,
                isEatingOut: entry.isEatingOut,
                placeName: entry.placeName,
                placeAddress: entry.placeAddress,
                placeLatitude: entry.placeLatitude,
                placeLongitude: entry.placeLongitude,
                routineUUID: entry.routineUUID
            )
        }

        backup.routines = rows.routines.map { routine in
            PortableRoutine(
                uuid: routine.uuid,
                dishUUID: routine.dish?.uuid,
                mealKey: routine.mealKey,
                weekday: routine.weekday,
                intervalWeeks: routine.intervalWeeks,
                startDate: routine.startDate,
                isActive: routine.isActive,
                plannedThrough: routine.plannedThrough,
                dateCreated: routine.dateCreated
            )
        }

        backup.cookedLogs = rows.cookedLogs.map { log in
            PortableCookedLog(
                uuid: log.uuid,
                date: log.date,
                dishName: log.dishName,
                servings: log.servings,
                photoData: includePhotos ? log.photoData : nil,
                dishUUID: log.dish?.uuid,
                entryUUID: log.entry?.uuid
            )
        }

        backup.shoppingItems = rows.shoppingItems.map { item in
            PortableShoppingItem(
                uuid: item.uuid,
                name: item.name,
                normalizedName: item.normalizedName,
                categoryRaw: item.categoryRaw,
                customAisleName: item.customAisleName,
                canonicalValue: item.canonicalValue,
                canonicalDimensionRaw: item.canonicalDimensionRaw,
                displayText: item.displayText,
                displayUnit: item.displayUnit,
                isChecked: item.isChecked,
                isManual: item.isManual,
                isApproximate: item.isApproximate,
                sortIndex: item.sortIndex,
                rangeStart: item.rangeStart,
                rangeEnd: item.rangeEnd,
                sourceDishNames: item.sourceDishNames,
                dateCreated: item.dateCreated,
                ingredientKey: key(for: item.ingredient),
                additionalAmountsRaw: item.additionalAmountsRaw,
                unmeasuredCount: item.unmeasuredCount
            )
        }

        backup.weekTemplates = rows.weekTemplates.map { template in
            PortableWeekTemplate(
                uuid: template.uuid,
                name: template.name,
                createdByName: template.createdByName,
                dateCreated: template.dateCreated,
                entries: template.sortedEntries.map {
                    PortableWeekTemplateEntry(
                        weekday: $0.weekday,
                        mealKey: $0.mealSlotRaw,
                        dishUUID: $0.dish?.uuid,
                        servingsOverride: $0.servingsOverride,
                        sortIndex: $0.sortIndex
                    )
                }
            )
        }

        backup.recipeFeeds = rows.recipeFeeds.map { feed in
            PortableRecipeFeed(
                uuid: feed.uuid,
                title: feed.title,
                siteURLString: feed.siteURLString,
                feedURLString: feed.feedURLString,
                etag: feed.etag,
                lastModified: feed.lastModified,
                lastFetchedAt: feed.lastFetchedAt,
                firstFailureAt: feed.firstFailureAt,
                consecutiveFailures: feed.consecutiveFailures,
                nextRetryAt: feed.nextRetryAt,
                lastHTTPStatus: feed.lastHTTPStatus,
                lastErrorMessage: feed.lastErrorMessage,
                dateAdded: feed.dateAdded,
                items: feed.sortedItems.map {
                    PortableRecipeFeedItem(
                        uuid: $0.uuid,
                        stableID: $0.stableID,
                        title: $0.title,
                        urlString: $0.urlString,
                        author: $0.author,
                        summary: $0.summary,
                        publishedAt: $0.publishedAt,
                        fetchedAt: $0.fetchedAt
                    )
                }
            )
        }
        backup.recipeBookmarks = rows.recipeBookmarks.map {
            PortableRecipeBookmark(
                uuid: $0.uuid,
                title: $0.title,
                urlString: $0.urlString,
                dateAdded: $0.dateAdded
            )
        }

        // Assigned last: `key(for:)` keeps filling the catalogue while the
        // dishes and shopping items above are being mapped.
        backup.ingredients = catalogue.values.sorted { $0.normalizedName < $1.normalizedName }
        return backup
    }

    // MARK: - Encoding

    /// Compact rather than pretty-printed: a library with photos runs to tens
    /// of megabytes of base64 and nobody reads that by hand.
    static func encode(_ backup: MealPlanBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    static func decode(_ data: Data) throws -> MealPlanBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(MealPlanBackup.self, from: data)
        guard backup.format == formatName, backup.version <= currentVersion else {
            throw MealPlanBackupError.unreadableFile
        }
        return backup
    }

    /// Reads a backup the user picked in a file importer, taking the security
    /// scope the picker hands back for a document outside the sandbox.
    static func read(fromFileAt url: URL) throws -> MealPlanBackup {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try decode(try Data(contentsOf: url))
    }

    /// `MealPlan-2026-09-02-1514` — the name a saved backup is offered under,
    /// without the extension so `fileExporter` can append its own.
    static func baseFilename(for date: Date) -> String {
        "MealPlan-\(DateFormatter.backupStamp.string(from: date))"
    }

    /// Stages the encoded backup in the temporary directory so `ShareLink` has
    /// a real file with a real name to hand to AirDrop.
    ///
    /// Deliberately not main-actor bound: encoding a library with photos runs
    /// to tens of megabytes and has no business blocking the UI. Snapshot on
    /// the main actor with `make(from:)`, then encode and write from a
    /// background task.
    static func writeTemporaryFile(_ data: Data, exportedAt: Date) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(baseFilename(for: exportedAt)).\(BackupFileType.fileExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }
}

enum MealPlanBackupError: LocalizedError {
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            String(localized: "That isn’t a MealPlan backup, or it was written by a newer version.")
        }
    }
}

private extension DateFormatter {
    /// `2026-09-01-1432` — sortable, and legal in a filename everywhere.
    static let backupStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()
}
