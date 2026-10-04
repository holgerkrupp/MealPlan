import CloudKit
import Foundation
import SwiftData

enum HouseholdCloudDownloadProgress: Equatable, Sendable {
    case lookingForHousehold
    case connecting
    case downloading(Int)
    case importing(completed: Int, total: Int)
}

/// A deliberately explicit iCloud household choice. Unlike the launch-time
/// bootstrap heuristic, recovery never decides which household a person meant
/// to restore: every choice keeps its original zone and share locator.
enum HouseholdRecoverySource: String, Codable, Sendable {
    case privateZone
    case sharedZone
    case recentlyDeleted
}

enum HouseholdRecoveryRole: String, Codable, Sendable {
    case owner
    case editor
    case viewer
}

struct HouseholdRecoveryCandidate: Identifiable, Sendable {
    /// Stable across app launches and intentionally includes the database
    /// scope. A household UUID can occur in more than one old zone.
    var id: String {
        "\(source.rawValue)|\(locator.ownerName)|\(locator.zoneName)|\(locator.shareRecordName ?? "-")"
    }

    var householdID: UUID
    var name: String
    var locator: HouseholdShareLocator
    var source: HouseholdRecoverySource
    var role: HouseholdRecoveryRole
    var dishCount: Int
    var entryCount: Int
    var memberCount: Int
    var entryStart: Date?
    var entryEnd: Date?
    var dateCreated: Date
    var lastModifiedAt: Date
    var isShared: Bool
    var isActiveOnThisDevice: Bool
    /// A recovery entry lives in the owner's private database and retains the
    /// original zone; it does not duplicate family content into an index.
    var deletedAt: Date?
    var retentionUntil: Date?

    var isPurgeEligible: Bool {
        guard let retentionUntil else { return false }
        return retentionUntil <= .now
    }

    var diagnostics: String {
        "\(source.rawValue) · \(locator.isOwner ? "private" : "shared") · zone \(locator.zoneName) · share \(locator.shareRecordName ?? "none")"
    }
}

enum HouseholdRecoveryError: LocalizedError {
    case invalidSelection
    case missingHousehold
    case validationFailed
    case notOwner
    case retentionNotReached

    var errorDescription: String? {
        switch self {
        case .invalidSelection:
            "That iCloud household can no longer be identified. Refresh the list and try again."
        case .missingHousehold:
            "The selected household no longer has its root record in iCloud."
        case .validationFailed:
            "The downloaded household did not pass its safety check, so this device was not changed."
        case .notOwner:
            "Only the household owner can move a household to Recently Deleted or permanently delete it."
        case .retentionNotReached:
            "This household stays recoverable until its retention date."
        }
    }
}

/// Finds and restores the household that already belongs to the current
/// iCloud account. A second device using the owner's Apple Account must read
/// the owner's private database; CloudKit does not allow that account to
/// accept its own `CKShare` into the shared database.
@MainActor
enum HouseholdCloudBootstrapService {
    private struct Candidate {
        let zone: CKRecordZone
        let dateCreated: Date

        var isShared: Bool { zone.share != nil }
    }

    static func restoreOwnedHouseholdIfAvailable(
        replacing localHousehold: Household?,
        context: ModelContext,
        progress: @escaping @MainActor (HouseholdCloudDownloadProgress) -> Void
    ) async throws -> Household? {
        progress(.lookingForHousehold)
        let database = CKContainer(identifier: SharedStore.cloudKitContainerID).privateCloudDatabase
        let zones = try await database.allRecordZones()
        var candidates: [Candidate] = []

        for zone in zones {
            guard let householdID = HouseholdShareLocator.householdID(from: zone.zoneID) else { continue }
            let rootID = CKRecord.ID(
                recordName: HouseholdRecordIdentity(type: .household, uuid: householdID).recordName,
                zoneID: zone.zoneID
            )
            guard let record = try? await fetchRecord(rootID, from: database),
                  let data = record[HouseholdRecordCodec.payloadKey] as? Data,
                  case .household(let payload) = try? HouseholdRecordCodec.decode(data) else { continue }
            candidates.append(.init(zone: zone, dateCreated: payload.dateCreated))
        }

        // A zone with a CKShare is the household the user deliberately chose
        // to share. Otherwise the oldest household is the original one; newer
        // unshared zones are usually placeholders created by older app builds
        // on additional devices.
        guard let candidate = candidates.sorted(by: candidateComesFirst).first else { return nil }
        return try await restoreOwnedHousehold(
            in: candidate.zone.zoneID,
            shareRecordName: candidate.zone.share?.recordID.recordName,
            replacing: localHousehold,
            mergeRecipes: false,
            adoptingLocalContent: true,
            context: context,
            progress: progress
        )
    }

    /// Lists every legacy household zone owned by this Apple Account, even
    /// when the local SwiftData household already contains data. The old
    /// bootstrap only performed this discovery for an empty placeholder, which
    /// let two populated installations remain split forever.
    ///
    /// This is inventory only. Calling it never changes the active household,
    /// uploads records, or deletes a CloudKit zone.
    static func ownedHouseholdInventory() async throws -> [LegacyOwnedHouseholdSummary] {
        let database = CKContainer(identifier: SharedStore.cloudKitContainerID).privateCloudDatabase
        let zones = try await database.allRecordZones()
        var summaries: [LegacyOwnedHouseholdSummary] = []

        for zone in zones {
            guard let householdID = HouseholdShareLocator.householdID(from: zone.zoneID) else { continue }
            let rootID = CKRecord.ID(
                recordName: HouseholdRecordIdentity(type: .household, uuid: householdID).recordName,
                zoneID: zone.zoneID
            )
            let record: CKRecord
            do {
                record = try await fetchRecord(rootID, from: database)
            } catch let error as CKError where error.code == .unknownItem {
                // A partially-created legacy zone without its root cannot be
                // a household candidate. Other failures must abort inventory
                // rather than causing a populated zone to look empty.
                continue
            }

            guard let data = record[HouseholdRecordCodec.payloadKey] as? Data,
                  case .household(let payload) = try? HouseholdRecordCodec.decode(data)
            else { continue }

            summaries.append(.init(
                householdID: householdID,
                zoneName: zone.zoneID.zoneName,
                shareRecordName: zone.share?.recordID.recordName,
                isShared: zone.share != nil,
                dateCreated: payload.dateCreated,
                contentRecordCount: try await userContentRecordCount(in: zone.zoneID, database: database)
            ))
        }
        return summaries
    }

    /// Confirmation-gated recovery for two independently populated legacy
    /// zones. It selects the same deterministic canonical zone used by the
    /// inventory, preserves the current household while moving it to that
    /// zone, and copies records that only exist in the other zones. Source
    /// zones are deliberately never deleted: they remain a recoverable
    /// CloudKit backup until the managed-store migration replaces this stack.
    static func reconcileOwnedHouseholds(
        canonical: LegacyOwnedHouseholdSummary,
        owned: [LegacyOwnedHouseholdSummary],
        preserving localHousehold: Household,
        context: ModelContext,
        progress: @escaping @MainActor (HouseholdCloudDownloadProgress) -> Void
    ) async throws -> Household {
        let canonicalLocator = HouseholdShareLocator(
            zoneName: canonical.zoneName,
            ownerName: CKCurrentUserDefaultName,
            shareRecordName: canonical.shareRecordName,
            isOwner: true,
            isReadOnly: false
        )
        let database = CKContainer(identifier: SharedStore.cloudKitContainerID).privateCloudDatabase

        // Complete all fallible reads before replacing the active local
        // household. A lost connection therefore leaves the device exactly as
        // it was, rather than switching it halfway through recovery.
        var known = Set(try HouseholdRecordCodec.records(for: localHousehold, context: context).map(\.identity))
        let canonicalRecords = try await fetchAllRecords(in: canonicalLocator.zoneID, from: database, progress: progress)
        known.formUnion(canonicalRecords.compactMap {
            HouseholdRecordIdentity(recordType: $0.recordType, recordName: $0.recordID.recordName)
        })
        var competingRecords: [(LegacyOwnedHouseholdSummary, [CKRecord])] = []
        for candidate in owned where candidate.householdID != canonical.householdID {
            let zoneID = CKRecordZone.ID(zoneName: candidate.zoneName, ownerName: CKCurrentUserDefaultName)
            competingRecords.append((candidate, try await fetchAllRecords(in: zoneID, from: database, progress: progress)))
        }

        // If this device is already on the canonical zone, preserve its local
        // version as authoritative. It may contain offline edits that have not
        // reached CloudKit yet; the importer below only adds missing records.
        let household: Household
        if localHousehold.uuid == canonical.householdID {
            household = localHousehold
        } else {
            household = try await restoreOwnedHousehold(
                in: canonicalLocator.zoneID,
                shareRecordName: canonical.shareRecordName,
                replacing: localHousehold,
                mergeRecipes: false,
                adoptingLocalContent: true,
                context: context,
                progress: progress
            )
        }

        for (_, records) in competingRecords {
            let imported = try applyMissingUserContent(
                records,
                known: known,
                to: household,
                context: context,
                progress: progress
            )
            known.formUnion(imported)
        }

        household.cloudKitShareIdentifier = try HouseholdShareLocator.encode(canonicalLocator)
        try context.save()
        NotificationCenter.default.post(name: .mealPlanDataDidChange, object: nil)
        return household
    }

    /// - Parameter adoptingLocalContent: The launch-time lookup runs behind an
    ///   ordinary, usable household, so by the time it replaces that
    ///   household the person may have started filling it. When set,
    ///   everything in it moves into the restored household first — see
    ///   `adoptContent(of:into:)` — instead of going down with it.
    static func restoreOwnedHousehold(
        in zoneID: CKRecordZone.ID,
        shareRecordName: String?,
        replacing localHousehold: Household?,
        mergeRecipes: Bool,
        adoptingLocalContent: Bool = false,
        context: ModelContext,
        progress: @escaping @MainActor (HouseholdCloudDownloadProgress) -> Void
    ) async throws -> Household {
        guard let householdID = HouseholdShareLocator.householdID(from: zoneID) else {
            throw HouseholdSharingError.missingRootRecord
        }

        progress(.connecting)
        let database = CKContainer(identifier: SharedStore.cloudKitContainerID).privateCloudDatabase
        let records = try await fetchAllRecords(in: zoneID, from: database, progress: progress)
        guard records.contains(where: {
            HouseholdRecordIdentity(recordType: $0.recordType, recordName: $0.recordID.recordName)?.type == .household
        }) else {
            throw HouseholdSharingError.missingRootRecord
        }

        // Stop an engine that may currently be attached to a placeholder zone
        // before changing the active household underneath it.
        await HouseholdRecordSyncService.shared.stop()

        let households = (try? context.fetch(FetchDescriptor<Household>())) ?? []
        let existing = households.first { $0.uuid == householdID }
        let household = existing ?? Household()
        if existing == nil {
            household.uuid = householdID
            context.insert(household)
        }

        let applicable = records.compactMap { record -> (CKRecord, HouseholdRecordIdentity)? in
            guard let identity = HouseholdRecordIdentity(recordType: record.recordType, recordName: record.recordID.recordName),
                  record[HouseholdRecordCodec.payloadKey] is Data else { return nil }
            return (record, identity)
        }.sorted {
            ($0.1.type.applyPriority, $0.1.recordName) < ($1.1.type.applyPriority, $1.1.recordName)
        }

        for (offset, item) in applicable.enumerated() {
            let (record, identity) = item
            let data = record[HouseholdRecordCodec.payloadKey] as! Data
            let asset = (record[HouseholdRecordCodec.assetKey] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) }
            try HouseholdRecordApplier.apply(
                payloadData: data,
                identity: identity,
                modifiedAt: HouseholdRecordCodec.modifiedAt(of: record),
                assetData: asset,
                household: household,
                context: context
            )
            progress(.importing(completed: offset + 1, total: applicable.count))
        }

        let fetchedShareName = records.compactMap { ($0 as? CKShare)?.recordID.recordName }.first
        let locator = HouseholdShareLocator(
            zoneName: zoneID.zoneName,
            ownerName: zoneID.ownerName,
            shareRecordName: shareRecordName ?? fetchedShareName,
            isOwner: true,
            isReadOnly: false
        )
        household.cloudKitShareIdentifier = try HouseholdShareLocator.encode(locator)

        if let localHousehold, localHousehold.uuid != household.uuid {
            if adoptingLocalContent {
                adoptContent(of: localHousehold, into: household)
            } else if mergeRecipes {
                HouseholdCloudSharingService.mergeDishes(from: localHousehold, into: household)
            }
            context.delete(localHousehold)
        }
        try context.save()
        NotificationCenter.default.post(name: .mealPlanDataDidChange, object: nil)
        return household
    }

    // MARK: - Explicit household recovery

    /// Lists every recoverable legacy household zone visible to this Apple
    /// Account. This intentionally has no ranking step: launch bootstrap may
    /// make a best effort for a brand-new device, but recovery must always ask
    /// the person to pick the exact private zone or accepted share.
    static func recoverableHouseholds(activeHouseholdID: UUID?) async throws -> [HouseholdRecoveryCandidate] {
        let container = CKContainer(identifier: SharedStore.cloudKitContainerID)
        async let owned = recoveryCandidates(
            in: container.privateCloudDatabase,
            source: .privateZone,
            isOwner: true,
            activeHouseholdID: activeHouseholdID
        )
        async let shared = recoveryCandidates(
            in: container.sharedCloudDatabase,
            source: .sharedZone,
            isOwner: false,
            activeHouseholdID: activeHouseholdID
        )
        return try await (owned + shared).sorted { lhs, rhs in
            let names = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if names != .orderedSame { return names == .orderedAscending }
            if lhs.dateCreated != rhs.dateCreated { return lhs.dateCreated < rhs.dateCreated }
            return lhs.id < rhs.id
        }
    }

    /// Resolves one known locator without looking at or ranking any other
    /// zone. Used before a destructive owner action so an unrelated stale
    /// zone cannot change which household is protected.
    static func recoverableHousehold(
        at locator: HouseholdShareLocator,
        activeHouseholdID: UUID?
    ) async throws -> HouseholdRecoveryCandidate {
        guard let householdID = HouseholdShareLocator.householdID(from: locator.zoneID) else {
            throw HouseholdRecoveryError.invalidSelection
        }
        let database = database(for: locator)
        let zone = try await database.recordZone(for: locator.zoneID)
        let records = try await fetchAllRecords(in: locator.zoneID, from: database, progress: { _ in })
        let shareID = zone.share?.recordID
        let share: CKShare?
        if let shareID {
            share = try? await fetchRecord(shareID, from: database) as? CKShare
        } else {
            share = nil
        }
        guard let candidate = recoveryCandidate(
            records: records,
            zone: zone,
            share: share,
            shareRecordID: shareID,
            householdID: householdID,
            source: locator.isOwner ? .privateZone : .sharedZone,
            isOwner: locator.isOwner,
            activeHouseholdID: activeHouseholdID
        ) else {
            throw HouseholdRecoveryError.missingHousehold
        }
        return candidate
    }

    /// Downloads an exact selection into an in-memory store and turns that
    /// verified store into the existing portable backup format. The caller can
    /// therefore replace a device only after the remote data has been fully
    /// decoded and its root/counts have been checked.
    static func preparedBackup(
        for candidate: HouseholdRecoveryCandidate,
        progress: @escaping @MainActor (HouseholdCloudDownloadProgress) -> Void = { _ in }
    ) async throws -> MealPlanBackup {
        let database = database(for: candidate)
        progress(.connecting)
        let records = try await fetchAllRecords(in: candidate.locator.zoneID, from: database, progress: progress)
        let staging = SharedStore.make(cloudKit: false, inMemory: true)
        let context = staging.mainContext
        let household = try applyRecoveredRecords(
            records,
            candidate: candidate,
            context: context,
            progress: progress
        )
        try validate(household: household, candidate: candidate, context: context)
        return try MealPlanBackup.make(from: context)
    }

    /// Rebuilds a chosen zone in a fresh context. It is shared by preflight
    /// recovery and the older direct bootstrap path, but does not stop or
    /// start a sync engine itself; engine lifetime belongs to the caller that
    /// swaps an active local household.
    private static func applyRecoveredRecords(
        _ records: [CKRecord],
        candidate: HouseholdRecoveryCandidate,
        context: ModelContext,
        progress: @escaping @MainActor (HouseholdCloudDownloadProgress) -> Void
    ) throws -> Household {
        guard records.contains(where: {
            HouseholdRecordIdentity(recordType: $0.recordType, recordName: $0.recordID.recordName)?.type == .household
        }) else {
            throw HouseholdRecoveryError.missingHousehold
        }

        let household = Household()
        household.uuid = candidate.householdID
        context.insert(household)

        let applicable = records.compactMap { record -> (CKRecord, HouseholdRecordIdentity)? in
            guard let identity = HouseholdRecordIdentity(recordType: record.recordType, recordName: record.recordID.recordName),
                  record[HouseholdRecordCodec.payloadKey] is Data else { return nil }
            return (record, identity)
        }.sorted {
            ($0.1.type.applyPriority, $0.1.recordName) < ($1.1.type.applyPriority, $1.1.recordName)
        }

        for (offset, item) in applicable.enumerated() {
            let (record, identity) = item
            let data = record[HouseholdRecordCodec.payloadKey] as! Data
            let asset = (record[HouseholdRecordCodec.assetKey] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) }
            try HouseholdRecordApplier.apply(
                payloadData: data,
                identity: identity,
                modifiedAt: HouseholdRecordCodec.modifiedAt(of: record),
                assetData: asset,
                household: household,
                context: context
            )
            progress(.importing(completed: offset + 1, total: applicable.count))
        }

        household.cloudKitShareIdentifier = try HouseholdShareLocator.encode(candidate.locator)
        try context.save()
        return household
    }

    private static func validate(
        household: Household,
        candidate: HouseholdRecoveryCandidate,
        context: ModelContext
    ) throws {
        guard household.uuid == candidate.householdID,
              household.name == candidate.name,
              (try context.fetchCount(FetchDescriptor<Dish>())) == candidate.dishCount,
              (try context.fetchCount(FetchDescriptor<MealPlanEntry>())) == candidate.entryCount else {
            throw HouseholdRecoveryError.validationFailed
        }
    }

    private static func recoveryCandidates(
        in database: CKDatabase,
        source: HouseholdRecoverySource,
        isOwner: Bool,
        activeHouseholdID: UUID?
    ) async throws -> [HouseholdRecoveryCandidate] {
        let zones = try await database.allRecordZones()
        var candidates: [HouseholdRecoveryCandidate] = []
        for zone in zones {
            guard let householdID = HouseholdShareLocator.householdID(from: zone.zoneID) else { continue }
            let records = try await fetchAllRecords(in: zone.zoneID, from: database, progress: { _ in })
            let shareID = zone.share?.recordID
            let share: CKShare?
            if let shareID {
                share = try? await fetchRecord(shareID, from: database) as? CKShare
            } else {
                share = nil
            }
            guard let candidate = recoveryCandidate(
                records: records,
                zone: zone,
                share: share,
                shareRecordID: shareID,
                householdID: householdID,
                source: source,
                isOwner: isOwner,
                activeHouseholdID: activeHouseholdID
            ) else { continue }
            candidates.append(candidate)
        }
        return candidates
    }

    private static func recoveryCandidate(
        records: [CKRecord],
        zone: CKRecordZone,
        share: CKShare?,
        shareRecordID: CKRecord.ID?,
        householdID: UUID,
        source: HouseholdRecoverySource,
        isOwner: Bool,
        activeHouseholdID: UUID?
    ) -> HouseholdRecoveryCandidate? {
        let rootName = HouseholdRecordIdentity(type: .household, uuid: householdID).recordName
        guard let root = records.first(where: { $0.recordID.recordName == rootName }),
              let data = root[HouseholdRecordCodec.payloadKey] as? Data,
              case .household(let payload) = try? HouseholdRecordCodec.decode(data) else { return nil }

        var dishes = 0
        var entries: [Date] = []
        var activeMembers = 0
        for record in records {
            guard let identity = HouseholdRecordIdentity(recordType: record.recordType, recordName: record.recordID.recordName) else { continue }
            switch identity.type {
            case .dish:
                dishes += 1
            case .planEntry:
                if let data = record[HouseholdRecordCodec.payloadKey] as? Data,
                   case .planEntry(let value) = try? HouseholdRecordCodec.decode(data) {
                    entries.append(value.value.date)
                }
            case .member:
                if let data = record[HouseholdRecordCodec.payloadKey] as? Data,
                   case .member(let member) = try? HouseholdRecordCodec.decode(data), member.isActive {
                    activeMembers += 1
                }
            default:
                break
            }
        }

        let isReadOnly = !isOwner && share?.currentUserParticipant?.permission == .readOnly
        let locator = HouseholdShareLocator(
            zoneName: zone.zoneID.zoneName,
            ownerName: zone.zoneID.ownerName,
            shareRecordName: share?.recordID.recordName ?? shareRecordID?.recordName,
            isOwner: isOwner,
            isReadOnly: isReadOnly
        )
        let lastModified = records.compactMap(\.modificationDate).max() ?? payload.dateCreated
        let memberCount = max(activeMembers, share?.participants.filter {
            $0.acceptanceStatus == .accepted || $0.role == .owner
        }.count ?? 0)
        return HouseholdRecoveryCandidate(
            householdID: householdID,
            name: payload.name,
            locator: locator,
            source: source,
            role: isOwner ? .owner : (isReadOnly ? .viewer : .editor),
            dishCount: dishes,
            entryCount: entries.count,
            memberCount: memberCount,
            entryStart: entries.min(),
            entryEnd: entries.max(),
            dateCreated: payload.dateCreated,
            lastModifiedAt: lastModified,
            isShared: shareRecordID != nil,
            isActiveOnThisDevice: activeHouseholdID == householdID,
            deletedAt: nil,
            retentionUntil: nil
        )
    }

    private static func database(for candidate: HouseholdRecoveryCandidate) -> CKDatabase {
        database(for: candidate.locator)
    }

    private static func database(for locator: HouseholdShareLocator) -> CKDatabase {
        let container = CKContainer(identifier: SharedStore.cloudKitContainerID)
        return locator.isOwner ? container.privateCloudDatabase : container.sharedCloudDatabase
    }

    /// Moves what someone created in the placeholder household — dishes and
    /// their ingredients, planned meals, the shopping list, history, routines,
    /// templates, feeds and bookmarks — into the restored one. Only what the
    /// placeholder was seeded with and nobody used (its default meals, unused
    /// pantry staples) is left to be deleted with it; the restored household
    /// has its own.
    static func adoptContent(of placeholder: Household, into household: Household) {
        HouseholdCloudSharingService.mergeDishes(from: placeholder, into: household)

        // Same rule `mergeDishes` applies to a dish's ingredients: join the
        // restored household's ingredient of that name, or move over. Preserve
        // every standalone ingredient too; the old implementation only moved
        // ingredients reached through shopping items and then deleted the rest.
        var ingredientsByName = [String: Ingredient](
            (household.ingredients ?? []).map { ($0.normalizedName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for item in placeholder.shoppingItems ?? [] {
            item.household = household
            guard let ingredient = item.ingredient, ingredient.household === placeholder else { continue }
            if let match = ingredientsByName[ingredient.normalizedName] {
                item.ingredient = match
            } else {
                ingredient.household = household
                ingredientsByName[ingredient.normalizedName] = ingredient
            }
        }

        for ingredient in placeholder.ingredients ?? [] where ingredient.household === placeholder {
            if let match = ingredientsByName[ingredient.normalizedName], match !== ingredient {
                // Preserve references and independently synced aliases before
                // the placeholder household is cascade-deleted.
                for line in ingredient.dishIngredients ?? [] { line.ingredient = match }
                for item in ingredient.shoppingItems ?? [] { item.ingredient = match }
                for alias in ingredient.aliases ?? [] { alias.ingredient = match }

                // If the local standalone row is newer, its inventory/nutrition
                // settings are the best representation of the user's offline
                // edits. Copy those scalar settings onto the canonical row.
                if ingredient.modifiedAt > match.modifiedAt {
                    match.name = ingredient.name
                    match.normalizedName = ingredient.normalizedName
                    match.categoryRaw = ingredient.categoryRaw
                    match.customAisleName = ingredient.customAisleName
                    match.isPantryStaple = ingredient.isPantryStaple
                    match.inventoryModeRaw = ingredient.inventoryModeRaw
                    match.inventoryCanonicalValue = ingredient.inventoryCanonicalValue
                    match.inventoryDimensionRaw = ingredient.inventoryDimensionRaw
                    match.inventoryBestBefore = ingredient.inventoryBestBefore
                    match.inventoryStorageLocationRaw = ingredient.inventoryStorageLocationRaw
                    match.inventoryCustomStorageLocation = ingredient.inventoryCustomStorageLocation
                    match.inventoryUpdatedAt = ingredient.inventoryUpdatedAt
                    match.rejectedMatchKeys = ingredient.rejectedMatchKeys
                    match.pendingMergeSuggestionsData = ingredient.pendingMergeSuggestionsData
                    match.nutritionEnergyKcal = ingredient.nutritionEnergyKcal
                    match.nutritionProteinGrams = ingredient.nutritionProteinGrams
                    match.nutritionCarbGrams = ingredient.nutritionCarbGrams
                    match.nutritionFatGrams = ingredient.nutritionFatGrams
                    match.nutritionReferenceRaw = ingredient.nutritionReferenceRaw
                    match.nutritionSourceRaw = ingredient.nutritionSourceRaw
                    match.modifiedAt = ingredient.modifiedAt
                }
            } else {
                ingredient.household = household
                ingredientsByName[ingredient.normalizedName] = ingredient
            }
        }

        // These household-owned rows were previously omitted entirely and were
        // cascade-deleted with the old household during reconciliation.
        for rule in placeholder.matchRules ?? [] { rule.household = household }
        for package in placeholder.packageSizeOverrides ?? [] { package.household = household }

        for entry in placeholder.entries ?? [] { entry.household = household }
        for log in placeholder.cookedLogs ?? [] { log.household = household }
        for routine in placeholder.mealRoutines ?? [] { routine.household = household }
        for template in placeholder.weekTemplates ?? [] { template.household = household }
        for feed in placeholder.recipeFeeds ?? [] { feed.household = household }
        for bookmark in placeholder.recipeBookmarks ?? [] { bookmark.household = household }
    }

    static func candidateComesFirst(_ lhs: CandidateSummary, _ rhs: CandidateSummary) -> Bool {
        if lhs.isShared != rhs.isShared { return lhs.isShared }
        if lhs.dateCreated != rhs.dateCreated { return lhs.dateCreated < rhs.dateCreated }
        return lhs.zoneName < rhs.zoneName
    }

    private static func candidateComesFirst(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        candidateComesFirst(
            .init(zoneName: lhs.zone.zoneID.zoneName, isShared: lhs.isShared, dateCreated: lhs.dateCreated),
            .init(zoneName: rhs.zone.zoneID.zoneName, isShared: rhs.isShared, dateCreated: rhs.dateCreated)
        )
    }

    private static func fetchAllRecords(
        in zoneID: CKRecordZone.ID,
        from database: CKDatabase,
        progress: @escaping @MainActor (HouseholdCloudDownloadProgress) -> Void
    ) async throws -> [CKRecord] {
        var token: CKServerChangeToken?
        var records: [CKRecord] = []
        var moreComing = true
        while moreComing {
            let page = try await database.recordZoneChanges(
                inZoneWith: zoneID,
                since: token,
                desiredKeys: nil,
                resultsLimit: 100
            )
            for result in page.modificationResultsByID.values {
                records.append(try result.get().record)
            }
            token = page.changeToken
            moreComing = page.moreComing
            progress(.downloading(records.count))
        }
        return records
    }

    private static func fetchRecord(_ id: CKRecord.ID, from database: CKDatabase) async throws -> CKRecord {
        let records = try await database.records(for: [id])
        guard let result = records[id] else { throw HouseholdSharingError.cloudKitDidNotReturnRecord }
        return try result.get()
    }

    /// Applies records that do not already exist in the active household.
    /// Never applying a same-identity record is intentional: that is the
    /// conservative conflict rule for this temporary legacy recovery path.
    /// It preserves offline/local edits and leaves both source zones intact
    /// for a person to inspect if two independently-created UUIDs ever clash.
    private static func applyMissingUserContent(
        _ records: [CKRecord],
        known: Set<HouseholdRecordIdentity>,
        to household: Household,
        context: ModelContext,
        progress: @escaping @MainActor (HouseholdCloudDownloadProgress) -> Void
    ) throws -> Set<HouseholdRecordIdentity> {
        let applicable = records.compactMap { record -> (CKRecord, HouseholdRecordIdentity)? in
            guard let identity = HouseholdRecordIdentity(recordType: record.recordType, recordName: record.recordID.recordName),
                  !known.contains(identity),
                  record[HouseholdRecordCodec.payloadKey] is Data
            else { return nil }
            switch identity.type {
            case .household, .member, .mealType, .deletionMarker:
                return nil
            default:
                return (record, identity)
            }
        }.sorted {
            ($0.1.type.applyPriority, $0.1.recordName) < ($1.1.type.applyPriority, $1.1.recordName)
        }

        var imported = Set<HouseholdRecordIdentity>()
        for (offset, item) in applicable.enumerated() {
            let (record, identity) = item
            let payload = record[HouseholdRecordCodec.payloadKey] as! Data
            let asset = (record[HouseholdRecordCodec.assetKey] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) }
            do {
                try HouseholdRecordApplier.apply(
                    payloadData: payload,
                    identity: identity,
                    modifiedAt: HouseholdRecordCodec.modifiedAt(of: record),
                    assetData: asset,
                    household: household,
                    context: context
                )
                imported.insert(identity)
            } catch {
                // A corrupt individual record cannot make recovery discard
                // the rest of a household. The untouched source zone remains
                // available for later export/support recovery.
                LegacyHouseholdDiagnostics.record(event: "legacyRecoveryRecordSkipped", error: error)
            }
            progress(.importing(completed: offset + 1, total: applicable.count))
        }
        return imported
    }

    /// Counts only records that represent actual user content. Requesting no
    /// fields keeps the discovery pass from downloading recipe bodies/photos;
    /// record type and ID are enough for a safe recovery decision.
    private static func userContentRecordCount(in zoneID: CKRecordZone.ID, database: CKDatabase) async throws -> Int {
        var token: CKServerChangeToken?
        var count = 0
        var moreComing = true
        while moreComing {
            let page = try await database.recordZoneChanges(
                inZoneWith: zoneID,
                since: token,
                desiredKeys: [],
                resultsLimit: 200
            )
            for result in page.modificationResultsByID.values {
                let record = try result.get().record
                guard let type = HouseholdRecordType(rawValue: record.recordType) else { continue }
                switch type {
                case .household, .member, .mealType, .deletionMarker:
                    break
                default:
                    count += 1
                }
            }
            token = page.changeToken
            moreComing = page.moreComing
        }
        return count
    }
}

/// Small, CloudKit-free projection used to test deterministic candidate
/// selection without manufacturing `CKRecordZone` server objects.
struct CandidateSummary: Equatable, Sendable {
    let zoneName: String
    let isShared: Bool
    let dateCreated: Date
}
