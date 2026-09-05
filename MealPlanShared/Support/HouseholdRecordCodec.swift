import CloudKit
import CryptoKit
import Foundation
import SwiftData

protocol HouseholdSyncModel: PersistentModel {
    var uuid: UUID { get set }
    var modifiedAt: Date { get set }
}

extension Household: HouseholdSyncModel {}
extension HouseholdMember: HouseholdSyncModel {}
extension MealType: HouseholdSyncModel {}
extension Dish: HouseholdSyncModel {}
extension DishImage: HouseholdSyncModel {}
extension Ingredient: HouseholdSyncModel {}
extension DishIngredient: HouseholdSyncModel {}
extension MealPlanEntry: HouseholdSyncModel {}
extension MealRoutine: HouseholdSyncModel {}
extension CookedLog: HouseholdSyncModel {}
extension ShoppingListItem: HouseholdSyncModel {}
extension WeekTemplate: HouseholdSyncModel {}
extension WeekTemplateEntry: HouseholdSyncModel {}
extension RecipeFeed: HouseholdSyncModel {}
extension RecipeFeedItem: HouseholdSyncModel {}
extension RecipeBookmark: HouseholdSyncModel {}

enum HouseholdRecordType: String, CaseIterable, Codable, Sendable {
    case household = "MPHousehold"
    case member = "MPHouseholdMember"
    case mealType = "MPMealType"
    case dish = "MPDish"
    case dishImage = "MPDishImage"
    case ingredient = "MPIngredient"
    case dishIngredient = "MPDishIngredient"
    case planEntry = "MPMealPlanEntry"
    case routine = "MPMealRoutine"
    case cookedLog = "MPCookedLog"
    case cookedLogImage = "MPCookedLogImage"
    case shoppingItem = "MPShoppingListItem"
    case weekTemplate = "MPWeekTemplate"
    case weekTemplateEntry = "MPWeekTemplateEntry"
    case recipeFeed = "MPRecipeFeed"
    case recipeFeedItem = "MPRecipeFeedItem"
    case recipeBookmark = "MPRecipeBookmark"
    case deletionMarker = "MPDeletionMarker"

    var applyPriority: Int {
        switch self {
        case .household: 0
        case .member, .mealType, .ingredient, .dish, .weekTemplate, .recipeFeed, .recipeBookmark: 1
        case .dishIngredient, .planEntry, .routine, .shoppingItem, .weekTemplateEntry, .recipeFeedItem, .cookedLog: 2
        case .dishImage, .cookedLogImage: 3
        case .deletionMarker: 4
        }
    }
}

struct HouseholdRecordIdentity: Codable, Hashable, Sendable {
    var type: HouseholdRecordType
    var uuid: UUID

    var recordName: String { "\(type.rawValue)-\(uuid.uuidString)" }

    init(type: HouseholdRecordType, uuid: UUID) {
        self.type = type
        self.uuid = uuid
    }

    init?(recordType: String, recordName: String) {
        guard let type = HouseholdRecordType(rawValue: recordType) else { return nil }
        let prefix = "\(type.rawValue)-"
        guard recordName.hasPrefix(prefix), let uuid = UUID(uuidString: String(recordName.dropFirst(prefix.count))) else { return nil }
        self.type = type
        self.uuid = uuid
    }
}

struct HouseholdPayload: Codable, Sendable {
    var name: String
    var unitSystemRaw: String
    var roundsDisplayedAmounts: Bool
    var standardServings: Int
    var showsNutritionEstimates: Bool
    var energyUnitRaw: String
    var localeIdentifier: String
    var dateCreated: Date
    var didSeedPantryStaples: Bool
    var bringListUuid: String?
    var bringListName: String?
    var bringShadowKeys: [String]
    var bringAutoSync: Bool
    var bringLastSyncedAt: Date?
}

struct MemberPayload: Codable, Sendable {
    var name: String
    var roleRaw: String
    var dateAdded: Date
    var cloudKitParticipantID: String?
    var isActive: Bool
}

struct DishImagePayload: Codable, Sendable {
    var dishID: UUID
    var sortIndex: Int
    var isPrimary: Bool
    var dateAdded: Date
}

struct DishIngredientPayload: Codable, Sendable {
    var dishID: UUID
    var ingredientID: UUID?
    var canonicalValue: Double?
    var canonicalDimensionRaw: String?
    var displayUnit: String?
    var isApproximate: Bool
    var note: String?
    var rawText: String?
    var sortIndex: Int
    /// This line in the dish's translation language. Optional so records
    /// written by a device that predates translation still decode.
    var translatedName: String? = nil
    var translatedNote: String? = nil
}

struct PlanEntryPayload: Codable, Sendable {
    var value: MealPlanBackup.PortableEntry
    var placementModifiedAt: Date
    var contentModifiedAt: Date
}

struct ShoppingItemPayload: Codable, Sendable {
    var value: MealPlanBackup.PortableShoppingItem
    var ingredientID: UUID?
    var contentModifiedAt: Date
    var checkStateModifiedAt: Date
}

struct WeekTemplateEntryPayload: Codable, Sendable {
    var templateID: UUID
    var weekday: Int
    var mealKey: String
    var dishID: UUID?
    var servingsOverride: Int?
    var sortIndex: Int
}

struct RecipeFeedItemPayload: Codable, Sendable {
    var feedID: UUID
    var value: MealPlanBackup.PortableRecipeFeedItem
}

struct CookedLogImagePayload: Codable, Sendable {
    var cookedLogID: UUID
}

struct DeletionMarkerPayload: Codable, Sendable {
    var deletedType: HouseholdRecordType
    var deletedUUID: UUID
    var deletedAt: Date
}

enum HouseholdRecordPayload: Codable, Sendable {
    case household(HouseholdPayload)
    case member(MemberPayload)
    case mealType(MealPlanBackup.PortableMealType)
    case dish(MealPlanBackup.PortableDish)
    case dishImage(DishImagePayload)
    case ingredient(MealPlanBackup.PortableIngredient)
    case dishIngredient(DishIngredientPayload)
    case planEntry(PlanEntryPayload)
    case routine(MealPlanBackup.PortableRoutine)
    case cookedLog(MealPlanBackup.PortableCookedLog)
    case cookedLogImage(CookedLogImagePayload)
    case shoppingItem(ShoppingItemPayload)
    case weekTemplate(MealPlanBackup.PortableWeekTemplate)
    case weekTemplateEntry(WeekTemplateEntryPayload)
    case recipeFeed(MealPlanBackup.PortableRecipeFeed)
    case recipeFeedItem(RecipeFeedItemPayload)
    case recipeBookmark(MealPlanBackup.PortableRecipeBookmark)
    case deletionMarker(DeletionMarkerPayload)
}

struct LocalHouseholdRecord: Sendable {
    var identity: HouseholdRecordIdentity
    var householdID: UUID
    var modifiedAt: Date
    var payloadData: Data
    var assetData: Data?
    /// Independent field-family hashes used to advance just the applicable
    /// conflict clock when a plan or shopping item changes locally.
    var groupFingerprints: [String: String] = [:]

    var fingerprint: String {
        var data = payloadData
        if let assetData { data.append(contentsOf: SHA256.hash(data: assetData)) }
        // Avoid Foundation's variadic formatter here. Besides being much
        // slower across hundreds of records, passing UInt8 through C varargs
        // has crashed in concurrent scans on iOS 27 beta.
        let digits = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(SHA256.Digest.byteCount * 2)
        for byte in SHA256.hash(data: data) {
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

enum HouseholdRecordCodec {
    static let payloadKey = "payload"
    static let householdIDKey = "householdID"
    static let modifiedAtKey = "modifiedAt"
    static let schemaVersionKey = "schemaVersion"
    static let assetKey = "asset"
    static let schemaVersion = 1

    static func records(for household: Household, context: ModelContext) throws -> [LocalHouseholdRecord] {
        var result: [LocalHouseholdRecord] = []
        func append(_ identity: HouseholdRecordIdentity, _ modifiedAt: Date, _ payload: HouseholdRecordPayload, asset: Data? = nil, groups: [String: String] = [:]) throws {
            result.append(LocalHouseholdRecord(
                identity: identity,
                householdID: household.uuid,
                modifiedAt: modifiedAt,
                payloadData: try encode(payload),
                assetData: asset,
                groupFingerprints: groups
            ))
        }

        try append(.init(type: .household, uuid: household.uuid), household.modifiedAt, .household(HouseholdPayload(
            name: household.name,
            unitSystemRaw: household.unitSystemRaw,
            roundsDisplayedAmounts: household.roundsDisplayedAmounts,
            standardServings: household.standardServings,
            showsNutritionEstimates: household.showsNutritionEstimates,
            energyUnitRaw: household.energyUnitRaw,
            localeIdentifier: household.localeIdentifier,
            dateCreated: household.dateCreated,
            didSeedPantryStaples: household.didSeedPantryStaples,
            bringListUuid: household.bringListUuid,
            bringListName: household.bringListName,
            bringShadowKeys: household.bringShadowKeys,
            bringAutoSync: household.bringAutoSync,
            bringLastSyncedAt: household.bringLastSyncedAt
        )))

        for member in household.members ?? [] {
            try append(.init(type: .member, uuid: member.uuid), member.modifiedAt, .member(MemberPayload(
                name: member.name, roleRaw: member.roleRaw, dateAdded: member.dateAdded,
                cloudKitParticipantID: member.cloudKitParticipantID, isActive: member.isActive
            )))
        }
        for meal in household.mealTypes ?? [] {
            try append(.init(type: .mealType, uuid: meal.uuid), meal.modifiedAt, .mealType(.init(
                uuid: meal.uuid, key: meal.key, name: meal.name, symbolName: meal.symbolName, sortOrder: meal.sortOrder
            )))
        }
        for ingredient in household.ingredients ?? [] {
            try append(.init(type: .ingredient, uuid: ingredient.uuid), ingredient.modifiedAt, .ingredient(.init(
                name: ingredient.name, normalizedName: ingredient.normalizedName, categoryRaw: ingredient.categoryRaw,
                customAisleName: ingredient.customAisleName, isPantryStaple: ingredient.isPantryStaple,
                nutritionEnergyKcal: ingredient.nutritionEnergyKcal, nutritionProteinGrams: ingredient.nutritionProteinGrams,
                nutritionCarbGrams: ingredient.nutritionCarbGrams, nutritionFatGrams: ingredient.nutritionFatGrams,
                nutritionReferenceRaw: ingredient.nutritionReferenceRaw, nutritionSourceRaw: ingredient.nutritionSourceRaw
            )))
        }
        for dish in household.dishes ?? [] {
            try append(.init(type: .dish, uuid: dish.uuid), dish.modifiedAt, .dish(portableDish(dish)))
            for image in dish.images ?? [] {
                try append(.init(type: .dishImage, uuid: image.uuid), image.modifiedAt, .dishImage(.init(
                    dishID: dish.uuid, sortIndex: image.sortIndex, isPrimary: image.isPrimary, dateAdded: image.dateAdded
                )), asset: image.data)
            }
            for line in dish.ingredients ?? [] {
                try append(.init(type: .dishIngredient, uuid: line.uuid), line.modifiedAt, .dishIngredient(.init(
                    dishID: dish.uuid, ingredientID: line.ingredient?.uuid, canonicalValue: line.canonicalValue,
                    canonicalDimensionRaw: line.canonicalDimensionRaw, displayUnit: line.displayUnit,
                    isApproximate: line.isApproximate, note: line.note, rawText: line.rawText,
                    sortIndex: line.sortIndex, translatedName: line.translatedName,
                    translatedNote: line.translatedNote
                )))
            }
        }
        for entry in household.entries ?? [] {
            let value = portableEntry(entry)
            let placement = try hash(encode([entry.date.timeIntervalSinceReferenceDate.description, entry.mealSlotRaw, entry.sortIndex.description]))
            var contentValue = value
            contentValue.date = .distantPast
            contentValue.mealKey = ""
            contentValue.sortIndex = 0
            let content = try hash(encode(contentValue))
            try append(.init(type: .planEntry, uuid: entry.uuid), entry.modifiedAt, .planEntry(.init(
                value: value, placementModifiedAt: entry.placementModifiedAt, contentModifiedAt: entry.contentModifiedAt
            )), groups: ["placement": placement, "content": content])
        }
        for routine in household.mealRoutines ?? [] {
            try append(.init(type: .routine, uuid: routine.uuid), routine.modifiedAt, .routine(.init(
                uuid: routine.uuid, dishUUID: routine.dish?.uuid, mealKey: routine.mealKey, weekday: routine.weekday,
                intervalWeeks: routine.intervalWeeks, startDate: routine.startDate, isActive: routine.isActive,
                plannedThrough: routine.plannedThrough, dateCreated: routine.dateCreated
            )))
        }
        for log in household.cookedLogs ?? [] {
            try append(.init(type: .cookedLog, uuid: log.uuid), log.modifiedAt, .cookedLog(.init(
                uuid: log.uuid, date: log.date, dishName: log.dishName, servings: log.servings, photoData: nil,
                dishUUID: log.dish?.uuid, entryUUID: log.entry?.uuid
            )))
            if let photo = log.photoData {
                try append(.init(type: .cookedLogImage, uuid: log.uuid), log.modifiedAt, .cookedLogImage(.init(cookedLogID: log.uuid)), asset: photo)
            }
        }
        for item in household.shoppingItems ?? [] {
            let value = portableShoppingItem(item)
            var contentValue = value
            contentValue.isChecked = false
            let content = try hash(encode(["value": try hash(encode(contentValue)), "ingredient": item.ingredient?.uuid.uuidString ?? ""]))
            let check = item.isChecked ? "1" : "0"
            try append(.init(type: .shoppingItem, uuid: item.uuid), item.modifiedAt, .shoppingItem(.init(
                value: value, ingredientID: item.ingredient?.uuid,
                contentModifiedAt: item.contentModifiedAt, checkStateModifiedAt: item.checkStateModifiedAt
            )), groups: ["content": content, "check": check])
        }
        for template in household.weekTemplates ?? [] {
            try append(.init(type: .weekTemplate, uuid: template.uuid), template.modifiedAt, .weekTemplate(.init(
                uuid: template.uuid, name: template.name, createdByName: template.createdByName,
                dateCreated: template.dateCreated, entries: []
            )))
            for entry in template.entries ?? [] {
                try append(.init(type: .weekTemplateEntry, uuid: entry.uuid), entry.modifiedAt, .weekTemplateEntry(.init(
                    templateID: template.uuid, weekday: entry.weekday, mealKey: entry.mealSlotRaw,
                    dishID: entry.dish?.uuid, servingsOverride: entry.servingsOverride, sortIndex: entry.sortIndex
                )))
            }
        }
        for feed in household.recipeFeeds ?? [] {
            try append(.init(type: .recipeFeed, uuid: feed.uuid), feed.modifiedAt, .recipeFeed(.init(
                uuid: feed.uuid, title: feed.title, siteURLString: feed.siteURLString, feedURLString: feed.feedURLString,
                etag: feed.etag, lastModified: feed.lastModified, lastFetchedAt: feed.lastFetchedAt,
                firstFailureAt: feed.firstFailureAt, consecutiveFailures: feed.consecutiveFailures,
                nextRetryAt: feed.nextRetryAt, lastHTTPStatus: feed.lastHTTPStatus,
                lastErrorMessage: feed.lastErrorMessage, dateAdded: feed.dateAdded, items: []
            )))
            for item in feed.items ?? [] {
                try append(.init(type: .recipeFeedItem, uuid: item.uuid), item.modifiedAt, .recipeFeedItem(.init(
                    feedID: feed.uuid, value: .init(uuid: item.uuid, stableID: item.stableID, title: item.title,
                        urlString: item.urlString, author: item.author, summary: item.summary,
                        publishedAt: item.publishedAt, fetchedAt: item.fetchedAt)
                )))
            }
        }
        for bookmark in household.recipeBookmarks ?? [] {
            try append(.init(type: .recipeBookmark, uuid: bookmark.uuid), bookmark.modifiedAt, .recipeBookmark(.init(
                uuid: bookmark.uuid, title: bookmark.title, urlString: bookmark.urlString, dateAdded: bookmark.dateAdded
            )))
        }
        return result
    }

    static func makeRecord(from snapshot: LocalHouseholdRecord, zoneID: CKRecordZone.ID, systemRecord: CKRecord? = nil) throws -> CKRecord {
        let record = systemRecord ?? CKRecord(
            recordType: snapshot.identity.type.rawValue,
            recordID: CKRecord.ID(recordName: snapshot.identity.recordName, zoneID: zoneID)
        )
        record[payloadKey] = snapshot.payloadData as CKRecordValue
        record[householdIDKey] = snapshot.householdID.uuidString as CKRecordValue
        record[modifiedAtKey] = snapshot.modifiedAt as CKRecordValue
        record[schemaVersionKey] = schemaVersion as CKRecordValue
        if let data = snapshot.assetData {
            let file = try assetFile(for: snapshot.identity, data: data)
            record[assetKey] = CKAsset(fileURL: file)
        } else {
            record[assetKey] = nil
        }
        return record
    }

    static func payload(from record: CKRecord) throws -> HouseholdRecordPayload {
        guard let data = record[payloadKey] as? Data else { throw HouseholdRecordCodecError.missingPayload }
        return try decode(data)
    }

    static func modifiedAt(of record: CKRecord) -> Date {
        record[modifiedAtKey] as? Date ?? record.modificationDate ?? .distantPast
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func decode(_ data: Data) throws -> HouseholdRecordPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HouseholdRecordPayload.self, from: data)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func assetFile(for identity: HouseholdRecordIdentity, data: Data) throws -> URL {
        let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStore.appGroupID)
            ?? URL.cachesDirectory
        let directory = root.appending(path: "CloudSyncAssets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: identity.recordName)
        if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
        return url
    }

    private static func portableDish(_ dish: Dish) -> MealPlanBackup.PortableDish {
        .init(
            uuid: dish.uuid, name: dish.name, recipeText: dish.recipeText, sourceURLString: dish.sourceURLString,
            deepLinkURLString: dish.deepLinkURLString, importedSourceApp: dish.importedSourceApp,
            importedSourceID: dish.importedSourceID, variantGroupID: dish.variantGroupID,
            variantGroupName: dish.variantGroupName, isFavorite: dish.isFavorite, rating: dish.rating,
            collectionNames: dish.collectionNames, tagNames: dish.tagNames, servings: dish.servings,
            prepTimeMinutes: dish.prepTimeMinutes, cookTimeMinutes: dish.cookTimeMinutes,
            mealTypeTagsRaw: dish.mealTypeTagsRaw, dietaryTagsRaw: dish.dietaryTagsRaw, seasonRaw: dish.seasonRaw,
            createdByName: dish.createdByName, dateCreated: dish.dateCreated, lastUsedDate: dish.lastUsedDate,
            usageCount: dish.usageCount, needsReview: dish.needsReview, glyphRaw: dish.glyphRaw,
            glyphIsAuto: dish.glyphIsAuto, statedEnergyKcalPerServing: dish.statedEnergyKcalPerServing,
            statedProteinGramsPerServing: dish.statedProteinGramsPerServing,
            statedCarbGramsPerServing: dish.statedCarbGramsPerServing,
            statedFatGramsPerServing: dish.statedFatGramsPerServing,
            recipeLanguageCode: dish.recipeLanguageCode,
            translationLanguageCode: dish.translationLanguageCode,
            translatedName: dish.translatedName, translatedRecipeText: dish.translatedRecipeText,
            images: [], ingredients: []
        )
    }

    private static func portableEntry(_ entry: MealPlanEntry) -> MealPlanBackup.PortableEntry {
        .init(
            uuid: entry.uuid, date: entry.date, mealKey: entry.mealSlotRaw, dishUUID: entry.dish?.uuid,
            servingsOverride: entry.servingsOverride, note: entry.note, sortIndex: entry.sortIndex,
            reactionRaw: entry.reactionRaw, skipped: entry.skipped, prepReminder: entry.prepReminder,
            plannedByName: entry.plannedByName, lastEditedByName: entry.lastEditedByName,
            lastEditedDate: entry.lastEditedDate, isEatingOut: entry.isEatingOut, placeName: entry.placeName,
            placeAddress: entry.placeAddress, placeLatitude: entry.placeLatitude,
            placeLongitude: entry.placeLongitude, routineUUID: entry.routineUUID
        )
    }

    private static func portableShoppingItem(_ item: ShoppingListItem) -> MealPlanBackup.PortableShoppingItem {
        .init(
            uuid: item.uuid, name: item.name, normalizedName: item.normalizedName, categoryRaw: item.categoryRaw,
            customAisleName: item.customAisleName, canonicalValue: item.canonicalValue,
            canonicalDimensionRaw: item.canonicalDimensionRaw, displayText: item.displayText,
            displayUnit: item.displayUnit, isChecked: item.isChecked, isManual: item.isManual,
            isApproximate: item.isApproximate, sortIndex: item.sortIndex, rangeStart: item.rangeStart,
            rangeEnd: item.rangeEnd, sourceDishNames: item.sourceDishNames, dateCreated: item.dateCreated,
            ingredientKey: item.ingredient?.normalizedName, additionalAmountsRaw: item.additionalAmountsRaw,
            unmeasuredCount: item.unmeasuredCount
        )
    }
}

/// Reads and serializes the shared store on a dedicated SwiftData executor.
/// The resulting snapshots are value types, so CloudKit can compare and hash
/// a large household without monopolizing the app's main actor.
@ModelActor
actor HouseholdSnapshotActor {
    func records(for householdID: UUID) throws -> [LocalHouseholdRecord] {
        let households = try modelContext.fetch(FetchDescriptor<Household>())
        guard let household = households.first(where: { $0.uuid == householdID }) else { return [] }
        return try HouseholdRecordCodec.records(for: household, context: modelContext)
    }

    func touch(
        _ changes: [(identity: HouseholdRecordIdentity, changedGroups: Set<String>)],
        at date: Date,
        householdID: UUID
    ) throws {
        let households = try modelContext.fetch(FetchDescriptor<Household>())
        guard let household = households.first(where: { $0.uuid == householdID }) else { return }
        touch(changes, at: date, household: household)
        try modelContext.save()
    }

    /// Advance local conflict clocks without issuing one whole-table SwiftData
    /// fetch per changed record. All models are already reachable from the
    /// household because the scan just serialized them, so update that object
    /// graph on this model actor's executor in a handful of linear passes.
    private func touch(
        _ changes: [(identity: HouseholdRecordIdentity, changedGroups: Set<String>)],
        at date: Date,
        household: Household
    ) {
        let grouped = Dictionary(grouping: changes, by: { $0.identity.type })

        func ids(for type: HouseholdRecordType) -> Set<UUID> {
            Set((grouped[type] ?? []).map(\.identity.uuid))
        }

        func touchModels<T: HouseholdSyncModel>(_ models: [T], type: HouseholdRecordType) {
            let changedIDs = ids(for: type)
            guard !changedIDs.isEmpty else { return }
            for model in models where changedIDs.contains(model.uuid) {
                model.modifiedAt = date
            }
        }

        if ids(for: .household).contains(household.uuid) {
            household.modifiedAt = date
        }
        touchModels(household.members ?? [], type: .member)
        touchModels(household.mealTypes ?? [], type: .mealType)
        touchModels(household.ingredients ?? [], type: .ingredient)
        touchModels(household.dishes ?? [], type: .dish)
        touchModels((household.dishes ?? []).flatMap { $0.images ?? [] }, type: .dishImage)
        touchModels((household.dishes ?? []).flatMap { $0.ingredients ?? [] }, type: .dishIngredient)
        touchModels(household.mealRoutines ?? [], type: .routine)
        touchModels(household.cookedLogs ?? [], type: .cookedLog)
        touchModels(household.cookedLogs ?? [], type: .cookedLogImage)
        touchModels(household.weekTemplates ?? [], type: .weekTemplate)
        touchModels((household.weekTemplates ?? []).flatMap { $0.entries ?? [] }, type: .weekTemplateEntry)
        touchModels(household.recipeFeeds ?? [], type: .recipeFeed)
        touchModels((household.recipeFeeds ?? []).flatMap { $0.items ?? [] }, type: .recipeFeedItem)
        touchModels(household.recipeBookmarks ?? [], type: .recipeBookmark)

        let planChanges = Dictionary(
            (grouped[.planEntry] ?? []).map { ($0.identity.uuid, $0.changedGroups) },
            uniquingKeysWith: { $0.union($1) }
        )
        for model in household.entries ?? [] {
            guard let changedGroups = planChanges[model.uuid] else { continue }
            if changedGroups.contains("placement") { model.placementModifiedAt = date }
            if changedGroups.contains("content") { model.contentModifiedAt = date }
            model.modifiedAt = date
        }

        let shoppingChanges = Dictionary(
            (grouped[.shoppingItem] ?? []).map { ($0.identity.uuid, $0.changedGroups) },
            uniquingKeysWith: { $0.union($1) }
        )
        for model in household.shoppingItems ?? [] {
            guard let changedGroups = shoppingChanges[model.uuid] else { continue }
            if changedGroups.contains("content") { model.contentModifiedAt = date }
            if changedGroups.contains("check") { model.checkStateModifiedAt = date }
            model.modifiedAt = date
        }
    }
}

enum HouseholdRecordCodecError: Error {
    case missingPayload
    case missingRelationship
}
