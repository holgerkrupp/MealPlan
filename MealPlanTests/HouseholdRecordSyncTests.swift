import CloudKit
import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import MealPlan

@MainActor
struct HouseholdRecordSyncTests {
    @Test func smallRemoteDeletionKeepsUnrelatedPlanEntries() throws {
        let container = SharedStore.make(cloudKit: false, inMemory: true)
        let context = container.mainContext
        let household = Household(name: "Test")
        let dish = Dish(name: "Soup")
        dish.household = household
        let removed = MealPlanEntry(date: .now, slot: .dinner, dish: dish)
        removed.household = household
        let retained = MealPlanEntry(date: .now.addingTimeInterval(86_400), slot: .dinner, dish: dish)
        retained.household = household
        context.insert(household)
        context.insert(dish)
        context.insert(removed)
        context.insert(retained)
        try context.save()

        HouseholdRecordApplier.withBatchLookup(in: context, expectedRecordCount: 1) {
            HouseholdRecordApplier.delete(type: .planEntry, uuid: removed.uuid, context: context)
            // CloudKit can deliver a marker and its raw deletion together.
            HouseholdRecordApplier.delete(type: .planEntry, uuid: removed.uuid, context: context)
        }
        try context.save()

        let entries = try context.fetch(FetchDescriptor<MealPlanEntry>())
        #expect(entries.map(\.uuid) == [retained.uuid])
        #expect(entries.first?.dish?.uuid == dish.uuid)
    }

    @Test func unsavedPhotoStaysInItsOwningContext() {
        let container = SharedStore.make(cloudKit: false, inMemory: true)
        let image = DishImage(data: Data([1, 2, 3]))
        container.mainContext.insert(image)

        #expect(image.persistentModelID.storeIdentifier == nil)
        #expect(DishPhotoLoading.persistentID(for: image) == nil)
    }

    @Test func fingerprintUsesStableLowercaseHex() {
        let record = LocalHouseholdRecord(
            identity: .init(type: .dish, uuid: UUID()),
            householdID: UUID(),
            modifiedAt: .now,
            payloadData: Data("abc".utf8)
        )

        #expect(record.fingerprint == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func unchangedSyncedRecordsDoNotQueueAnotherUpload() {
        var metadata = HouseholdSyncMetadata()
        let name = "MPDish-example"
        let server = "server-version"
        let edit = "local-edit"
        metadata.serverFingerprints[name] = server

        #expect(!metadata.shouldQueue(name, fingerprint: server))
        #expect(metadata.shouldQueue(name, fingerprint: edit))

        metadata.pendingFingerprints[name] = edit
        #expect(!metadata.shouldQueue(name, fingerprint: edit))
        // A revert must replace the pending edit before it reaches CloudKit.
        #expect(metadata.shouldQueue(name, fingerprint: server))

        metadata.pendingFingerprints.removeValue(forKey: name)
        metadata.needsFullUpload = true
        #expect(metadata.shouldQueue(name, fingerprint: server))
    }

    @Test func pendingUploadIsNotRetouchedOnEveryScan() {
        var metadata = HouseholdSyncMetadata()
        let name = "MPDish-example"
        metadata.serverFingerprints[name] = "server"

        #expect(metadata.shouldTouch(name, fingerprint: "first-edit"))
        metadata.pendingFingerprints[name] = "first-edit"
        #expect(!metadata.shouldTouch(name, fingerprint: "first-edit"))
        #expect(metadata.shouldTouch(name, fingerprint: "second-edit"))
        #expect(!metadata.shouldTouch(name, fingerprint: "server"))
        #expect(!metadata.shouldTouch("unknown", fingerprint: "new-record"))
    }

    @Test func localScanUsesOneCanonicalRecordPerCloudIdentity() {
        let householdID = UUID()
        let duplicateID = UUID()
        let old = LocalHouseholdRecord(
            identity: .init(type: .ingredient, uuid: duplicateID), householdID: householdID,
            modifiedAt: Date(timeIntervalSince1970: 1), payloadData: Data("old".utf8)
        )
        let newer = LocalHouseholdRecord(
            identity: old.identity, householdID: householdID,
            modifiedAt: Date(timeIntervalSince1970: 2), payloadData: Data("new".utf8)
        )
        let other = LocalHouseholdRecord(
            identity: .init(type: .dish, uuid: UUID()), householdID: householdID,
            modifiedAt: .now, payloadData: Data("other".utf8)
        )

        let canonical = HouseholdRecordSyncService.canonicalSnapshots([old, other, newer])
        #expect(canonical.count == 2)
        #expect(canonical[0].payloadData == newer.payloadData)
        #expect(canonical[1].payloadData == other.payloadData)
    }

    @Test func olderCloudAcknowledgementCannotMarkANewerEditAsUploaded() {
        var metadata = HouseholdSyncMetadata()
        let name = "MPDish-example"
        metadata.serverFingerprints[name] = "original"
        metadata.pendingFingerprints[name] = "newer-edit"
        metadata.pendingGroupFingerprints[name] = ["recipe": "newer-group"]

        let needsRetry = metadata.acknowledgeSavedRecord(name, fingerprint: "older-edit")
        #expect(needsRetry)
        #expect(metadata.serverFingerprints[name] == "older-edit")
        #expect(metadata.pendingFingerprints[name] == nil)
        #expect(metadata.shouldQueue(name, fingerprint: "newer-edit"))

        metadata.pendingFingerprints[name] = "newer-edit"
        metadata.pendingGroupFingerprints[name] = ["recipe": "newer-group"]
        let acknowledged = metadata.acknowledgeSavedRecord(name, fingerprint: "newer-edit")
        #expect(!acknowledged)
        #expect(metadata.serverFingerprints[name] == "newer-edit")
        #expect(metadata.serverGroupFingerprints[name]?["recipe"] == "newer-group")
        #expect(!metadata.shouldQueue(name, fingerprint: "newer-edit"))
    }

    @Test func resolvedCloudConflictsDoNotBecomeForegroundSendAlerts() {
        let id = CKRecord.ID(recordName: "MPDish-\(UUID().uuidString)", zoneID: CKRecordZone.ID(zoneName: "test"))
        let server = CKRecord(recordType: HouseholdRecordType.dish.rawValue, recordID: id)
        let conflict = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [id: conflict]])

        #expect(HouseholdRecordSyncService.isResolvedConflictSendError(conflict))
        #expect(HouseholdRecordSyncService.isResolvedConflictSendError(partial))
        #expect(!HouseholdRecordSyncService.isResolvedConflictSendError(
            CKError(.networkFailure)
        ))
        #expect(!HouseholdRecordSyncService.isResolvedConflictSendError(
            CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [id: CKError(.permissionFailure)]])
        ))
    }

    @Test func journalReconciliationClearsOnlyOrphanedPendingMarkers() {
        var metadata = HouseholdSyncMetadata()
        metadata.serverFingerprints = ["sent": "old", "stillQueued": "old"]
        metadata.pendingFingerprints = ["sent": "latest", "stillQueued": "latest"]
        metadata.pendingGroupFingerprints = ["sent": ["recipe": "a"], "stillQueued": ["recipe": "b"]]

        #expect(metadata.prunePendingMissingFromJournal(["stillQueued"]) == 1)
        #expect(metadata.pendingFingerprints["sent"] == nil)
        #expect(metadata.pendingGroupFingerprints["sent"] == nil)
        #expect(metadata.shouldQueue("sent", fingerprint: "latest"))
        #expect(metadata.pendingFingerprints["stillQueued"] == "latest")
        #expect(!metadata.shouldQueue("stillQueued", fingerprint: "latest"))
    }

    @Test func planEntryFromBeforeParticipantSelectionStillDecodes() throws {
        let data = Data("""
        {"uuid":"00000000-0000-0000-0000-000000000001",\
        "date":"2026-10-15T00:00:00Z","mealKey":"dinner",\
        "sortIndex":0,"skipped":false,"prepReminder":false,"isEatingOut":false}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let entry = try decoder.decode(MealPlanBackup.PortableEntry.self, from: data)
        #expect(entry.participatingMemberUUIDs.isEmpty)
        #expect(entry.mealKey == "dinner")
    }

    @Test func recipeFeedHTTPStateDoesNotChangeSharedRecord() throws {
        let container = SharedStore.make(cloudKit: false, inMemory: true)
        let context = container.mainContext
        let household = Household(name: "Home")
        let feed = RecipeFeed(title: "Family recipes", siteURL: URL(string: "https://example.com")!, sourceKind: .builtInCollection, sourceID: "family", contentURL: URL(string: "https://example.com/family")!)
        feed.household = household
        context.insert(household)
        context.insert(feed)
        try context.save()

        func sharedRecord() throws -> LocalHouseholdRecord {
            try #require(HouseholdRecordCodec.records(for: household, context: context).first {
                $0.identity.type == .recipeFeed
            })
        }
        let before = try sharedRecord()
        feed.etag = "new-etag"
        feed.lastFetchedAt = .now
        feed.firstFailureAt = .now
        feed.consecutiveFailures = 2
        feed.nextRetryAt = .now
        feed.lastHTTPStatus = 503
        feed.lastErrorMessage = "Temporary error"
        let after = try sharedRecord()
        #expect(after.fingerprint == before.fingerprint)

        guard case .recipeFeed(let portable) = try HouseholdRecordCodec.decode(after.payloadData) else {
            Issue.record("Expected a recipe feed payload")
            return
        }
        #expect(portable.sourceKindRaw == RecipeSiteSourceKind.builtInCollection.rawValue)
        #expect(portable.sourceID == "family")
        #expect(portable.contentURLString == "https://example.com/family")
    }

    @Test func snapshotFindsLegacyMealTypesWithoutHouseholdRelationship() throws {
        let container = SharedStore.make(cloudKit: false, inMemory: true)
        let context = container.mainContext
        let household = Household(name: "Home")
        let meal = MealType(key: "supper", name: "Supper", sortOrder: 3)
        context.insert(household)
        context.insert(meal)
        try context.save()

        let records = try HouseholdRecordCodec.records(for: household, context: context)
        #expect(records.contains {
            $0.identity.type == .mealType && $0.identity.uuid == meal.uuid
        })
    }

    @Test func olderRecipeFeedRecordsDecodeWithoutSourceAndArticleFields() throws {
        let data = Data("""
        {"uuid":"00000000-0000-0000-0000-000000000001","title":"Recipes",\
        "siteURLString":"https://example.com","feedURLString":"https://example.com/feed",\
        "consecutiveFailures":0,"dateAdded":"2026-10-15T00:00:00Z",\
        "items":[{"uuid":"00000000-0000-0000-0000-000000000002",\
        "stableID":"article","title":"Soup","urlString":"https://example.com/soup",\
        "fetchedAt":"2026-10-15T00:00:00Z"}]}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let feed = try decoder.decode(MealPlanBackup.PortableRecipeFeed.self, from: data)
        #expect(feed.sourceKindRaw == nil)
        #expect(feed.items.first?.imageURLString == nil)
        #expect(feed.items.first?.archivedAt == nil)
    }

    @Test func replacingPhotoCannotChangeBytesOfAnInFlightCloudAsset() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MealPlan-asset-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = HouseholdRecordIdentity(type: .dishImage, uuid: UUID())
        let householdID = UUID()
        let payload = try HouseholdRecordCodec.encode(
            HouseholdRecordPayload.dishImage(.init(
                dishID: UUID(), sortIndex: 0, isPrimary: true, dateAdded: .now
            ))
        )
        let zoneID = CKRecordZone.ID(zoneName: "test-\(UUID().uuidString)")
        let older = try HouseholdRecordCodec.makeRecord(from: .init(
            identity: identity, householdID: householdID, modifiedAt: .now,
            payloadData: payload, assetData: Data([1, 2, 3])
        ), zoneID: zoneID, assetDirectory: root)
        let newer = try HouseholdRecordCodec.makeRecord(from: .init(
            identity: identity, householdID: householdID, modifiedAt: .now,
            payloadData: payload, assetData: Data([4, 5, 6])
        ), zoneID: zoneID, assetDirectory: root)
        let olderURL = try #require((older[HouseholdRecordCodec.assetKey] as? CKAsset)?.fileURL)
        let newerURL = try #require((newer[HouseholdRecordCodec.assetKey] as? CKAsset)?.fileURL)
        #expect(olderURL != newerURL)
        #expect(try Data(contentsOf: olderURL) == Data([1, 2, 3]))
        #expect(try Data(contentsOf: newerURL) == Data([4, 5, 6]))
    }

    @Test func olderSaveCannotAcknowledgeANewerJournalEntry() throws {
        let id = CKRecord.ID(recordName: "MPDish-\(UUID().uuidString)", zoneID: CKRecordZone.ID(zoneName: "test"))
        let date = Date(timeIntervalSince1970: 123)
        let pending = CKRecord(recordType: HouseholdRecordType.dish.rawValue, recordID: id)
        pending[HouseholdRecordCodec.payloadKey] = Data("newer".utf8) as CKRecordValue
        pending[HouseholdRecordCodec.modifiedAtKey] = date as CKRecordValue
        let saved = CKRecord(recordType: HouseholdRecordType.dish.rawValue, recordID: id)
        saved[HouseholdRecordCodec.payloadKey] = Data("older".utf8) as CKRecordValue
        saved[HouseholdRecordCodec.modifiedAtKey] = date as CKRecordValue

        let journalEntry = try MealPlanCloudKitStateStore.ArchivedChange(record: pending)
        #expect(!journalEntry.matchesSavedRecord(saved))
        saved[HouseholdRecordCodec.payloadKey] = Data("newer".utf8) as CKRecordValue
        #expect(journalEntry.matchesSavedRecord(saved))
    }

    @Test func photoLoaderDistinguishesLegacyDuplicateUUIDs() async throws {
        // A separate ModelActor needs a real SQLite connection. SwiftData's
        // in-memory configuration has no eligible background connection on
        // macOS, so mirror the production topology in a disposable store.
        let storeDirectory = FileManager.default.temporaryDirectory
            .appending(path: "MealPlan-photo-loader-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeDirectory) }

        let schema = SharedStore.makeSchema()
        let configuration = ModelConfiguration(
            schema: schema,
            url: storeDirectory.appending(path: "test.sqlite"),
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let duplicateUUID = UUID()
        let first = DishImage(data: Data([1, 2, 3]))
        let second = DishImage(data: Data([7, 8, 9]))
        first.uuid = duplicateUUID
        second.uuid = duplicateUUID
        context.insert(first)
        context.insert(second)
        try context.save()

        let firstID = first.persistentModelID
        let secondID = second.persistentModelID
        let loader = DishPhotoDataActor(modelContainer: container)

        #expect(await loader.data(for: firstID, uuid: duplicateUUID) == Data([1, 2, 3]))
        #expect(await loader.data(for: secondID, uuid: duplicateUUID) == Data([7, 8, 9]))
    }

    @Test func syncPhotoBytesMatchTheSelectedDuplicateSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MealPlan-sync-photo-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = SharedStore.makeSchema()
        let configuration = ModelConfiguration(
            schema: schema, url: directory.appending(path: "test.sqlite"), cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let household = Household(name: "Test")
        let dish = Dish(name: "Soup")
        dish.household = household
        let first = DishImage(data: Data([1, 2, 3]))
        let second = DishImage(data: Data([7, 8, 9]))
        second.uuid = first.uuid
        second.modifiedAt = first.modifiedAt
        first.dish = dish
        second.dish = dish
        context.insert(household)
        context.insert(dish)
        context.insert(first)
        context.insert(second)
        try context.save()

        let actor = HouseholdSnapshotActor(modelContainer: container)
        let snapshots = try await actor.records(for: household.uuid)
            .filter { $0.identity.type == .dishImage }
        #expect(snapshots.count == 2)
        let digests = snapshots.compactMap(\.assetDigest)
        #expect(Set(digests).count == 2)
        for snapshot in snapshots {
            let bytes = try await actor.imageData(for: first.uuid, matching: snapshot.assetDigest)
            let loaded = try #require(bytes)
            #expect(Data(SHA256.hash(data: loaded)) == snapshot.assetDigest)
        }
    }

    @Test func photoLoaderFindsPrimaryImageWithoutMainContextRelationshipFault() async throws {
        let storeDirectory = FileManager.default.temporaryDirectory
            .appending(path: "MealPlan-primary-photo-loader-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeDirectory) }

        let schema = SharedStore.makeSchema()
        let configuration = ModelConfiguration(
            schema: schema,
            url: storeDirectory.appending(path: "test.sqlite"),
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let dish = Dish(name: "Soup")
        let secondary = DishImage(data: Data([1, 2, 3]), sortIndex: 0)
        let primary = DishImage(data: Data([7, 8, 9]), sortIndex: 1, isPrimary: true)
        secondary.dish = dish
        primary.dish = dish
        context.insert(dish)
        context.insert(secondary)
        context.insert(primary)
        try context.save()

        let loader = DishPhotoDataActor(modelContainer: container)
        let data = await loader.primaryImageData(for: dish.persistentModelID, uuid: dish.uuid)

        #expect(data == Data([7, 8, 9]))
    }

    @Test func stableIdentityRoundTripsFromCloudKitName() throws {
        let uuid = UUID()
        let identity = HouseholdRecordIdentity(type: .dish, uuid: uuid)
        let decoded = try #require(HouseholdRecordIdentity(recordType: HouseholdRecordType.dish.rawValue, recordName: identity.recordName))

        #expect(decoded == identity)
        #expect(decoded.recordName == "MPDish-\(uuid.uuidString)")
    }

    @Test func shareLocatorRoundTripsWithoutLosingPermission() throws {
        let source = HouseholdShareLocator(
            zoneName: "MealPlanHousehold-test",
            ownerName: "owner",
            shareRecordName: "share",
            isOwner: false,
            isReadOnly: true
        )

        #expect(HouseholdShareLocator.decode(try HouseholdShareLocator.encode(source)) == source)
    }

    @Test func householdZoneRoundTripsItsIdentity() {
        let householdID = UUID()
        let locator = HouseholdShareLocator.solo(householdID: householdID)

        #expect(HouseholdShareLocator.householdID(from: locator.zoneID) == householdID)
        #expect(HouseholdShareLocator.householdID(from: CKRecordZone.ID(zoneName: "Unrelated")) == nil)
    }

    @Test func legacyShareResolvesRootDirectlyFromZone() {
        let householdID = UUID()
        let zoneID = HouseholdShareLocator.solo(householdID: householdID).zoneID

        #expect(HouseholdCloudSharingService.resolvedHouseholdID(shareValue: nil, zoneID: zoneID) == householdID)
        #expect(HouseholdCloudSharingService.resolvedHouseholdID(shareValue: "invalid", zoneID: zoneID) == householdID)
    }

    @Test func cloudBootstrapPrefersSharedThenOldestHousehold() {
        let oldUnshared = CandidateSummary(zoneName: "old", isShared: false, dateCreated: Date(timeIntervalSince1970: 100))
        let newShared = CandidateSummary(zoneName: "shared", isShared: true, dateCreated: Date(timeIntervalSince1970: 300))
        let oldShared = CandidateSummary(zoneName: "original", isShared: true, dateCreated: Date(timeIntervalSince1970: 200))

        let ordered = [oldUnshared, newShared, oldShared].sorted(by: HouseholdCloudBootstrapService.candidateComesFirst)

        #expect(ordered == [oldShared, newShared, oldUnshared])
    }

    @Test func syncStateIsNamespacedByCloudKitEnvironment() {
        let locator = HouseholdShareLocator(
            zoneName: "MealPlanHousehold-test",
            ownerName: CKCurrentUserDefaultName,
            shareRecordName: CKRecordNameZoneWideShare,
            isOwner: true,
            isReadOnly: false
        )

        let development = HouseholdRecordSyncService.storageSuffix(for: locator, environment: .development)
        let production = HouseholdRecordSyncService.storageSuffix(for: locator, environment: .production)

        #expect(development != production)
    }

    @Test func interruptedEngineStateRetirementRequiresIdenticalCopies() throws {
        let committed = Data([0x01, 0x02, 0x03, 0x04])
        try MealPlanCloudKitStateStore.verifyInterruptedStateRetirement(
            fileData: committed,
            defaultsData: committed
        )

        let possiblyNewerDefaultsCopy = Data([0x01, 0x02, 0x03, 0x05])
        do {
            try MealPlanCloudKitStateStore.verifyInterruptedStateRetirement(
                fileData: committed,
                defaultsData: possiblyNewerDefaultsCopy
            )
            Issue.record("Expected divergent engine-state copies to fail closed.")
        } catch MealPlanCloudKitStateStoreError.stateCopiesDiverged {
            // Both source copies remain available for recovery.
        }
        #expect(committed != possiblyNewerDefaultsCopy)
    }

    @Test func planMoveAndContentEditMergeIndependently() {
        let earlier = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 200)
        let localValue = planValue(date: earlier, meal: "lunch", note: "local note")
        var serverValue = localValue
        serverValue.date = later
        serverValue.mealKey = "dinner"
        serverValue.note = "old note"

        let merged = HouseholdRecordConflictResolver.merge(
            .init(value: localValue, placementModifiedAt: earlier, contentModifiedAt: later),
            .init(value: serverValue, placementModifiedAt: later, contentModifiedAt: earlier)
        )

        #expect(merged.value.date == later)
        #expect(merged.value.mealKey == "dinner")
        #expect(merged.value.note == "local note")
        #expect(merged.placementModifiedAt == later)
        #expect(merged.contentModifiedAt == later)
    }

    @Test func legacyPlanMoveWithEqualPlacementClocksUsesNewerRecord() {
        let clock = Date(timeIntervalSince1970: 100)
        let localValue = planValue(date: clock, meal: "lunch", note: nil)
        var serverValue = localValue
        serverValue.date = clock.addingTimeInterval(86_400)
        serverValue.mealKey = "dinner"
        let local = PlanEntryPayload(value: localValue, placementModifiedAt: clock, contentModifiedAt: clock)
        let server = PlanEntryPayload(value: serverValue, placementModifiedAt: clock, contentModifiedAt: clock)

        let merged = HouseholdRecordConflictResolver.merge(
            local, server,
            localModifiedAt: clock,
            serverModifiedAt: clock.addingTimeInterval(10)
        )
        #expect(merged.value.date == serverValue.date)
        #expect(merged.value.mealKey == "dinner")
        #expect(HouseholdRecordConflictResolver.merge(local, server).value.date == serverValue.date)
    }

    @Test func movingPlanEntryAdvancesPlacementClock() throws {
        let container = SharedStore.make(cloudKit: false, inMemory: true)
        let context = container.mainContext
        let household = Household(name: "Home")
        let dish = Dish(name: "Soup")
        dish.household = household
        let entry = MealPlanEntry(date: .now, slot: .lunch, dish: dish)
        entry.household = household
        let oldDate = Date(timeIntervalSince1970: 100)
        entry.modifiedAt = oldDate
        entry.placementModifiedAt = oldDate
        entry.contentModifiedAt = oldDate
        context.insert(household)
        context.insert(dish)
        context.insert(entry)
        try context.save()

        #expect(MealPlanner.move(entry, to: entry.date.addingTimeInterval(86_400), mealKey: "dinner", memberName: "Tester", context: context))
        #expect(entry.placementModifiedAt > oldDate)
        #expect(entry.modifiedAt == entry.placementModifiedAt)
        #expect(entry.contentModifiedAt == oldDate)
    }

    @Test func snapshotReaderSeesMealMoveSavedByAnotherContext() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MealPlan-snapshot-refresh-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = SharedStore.makeSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(
            schema: schema,
            url: directory.appending(path: "test.sqlite"),
            cloudKitDatabase: .none
        )])
        let context = container.mainContext
        let household = Household(name: "Home")
        let dish = Dish(name: "Soup")
        dish.household = household
        let entry = MealPlanEntry(date: .now, slot: .lunch, dish: dish)
        entry.household = household
        context.insert(household)
        context.insert(dish)
        context.insert(entry)
        try context.save()

        let reader = HouseholdSnapshotActor(modelContainer: container)
        let before = try await reader.records(for: household.uuid)
            .first { $0.identity.type == .planEntry && $0.identity.uuid == entry.uuid }
        #expect(before != nil)

        let destination = entry.date.addingTimeInterval(86_400)
        #expect(MealPlanner.move(entry, to: destination, mealKey: "dinner", memberName: "Tester", context: context))

        let after = try await reader.records(for: household.uuid)
            .first { $0.identity.type == .planEntry && $0.identity.uuid == entry.uuid }
        #expect(after != nil)
        #expect(after?.fingerprint != before?.fingerprint)
        if let after, case .planEntry(let payload) = try HouseholdRecordCodec.decode(after.payloadData) {
            #expect(payload.value.date == destination)
            #expect(payload.value.mealKey == "dinner")
        } else {
            Issue.record("The updated plan entry was missing from the second snapshot")
        }
    }

    @Test func shoppingCheckAndQuantityEditMergeIndependently() {
        let earlier = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 200)
        let content = shoppingValue(amount: 2, checked: false)
        var checked = content
        checked.canonicalValue = 1
        checked.isChecked = true

        let merged = HouseholdRecordConflictResolver.merge(
            .init(value: content, ingredientID: nil, contentModifiedAt: later, checkStateModifiedAt: earlier),
            .init(value: checked, ingredientID: nil, contentModifiedAt: earlier, checkStateModifiedAt: later)
        )

        #expect(merged.value.canonicalValue == 2)
        #expect(merged.value.isChecked)
    }

    @Test func equalShoppingCheckClockPrefersChecked() {
        let clock = Date(timeIntervalSince1970: 100)
        let unchecked = ShoppingItemPayload(value: shoppingValue(amount: 1, checked: false), ingredientID: nil, contentModifiedAt: clock, checkStateModifiedAt: clock)
        let checked = ShoppingItemPayload(value: shoppingValue(amount: 1, checked: true), ingredientID: nil, contentModifiedAt: clock, checkStateModifiedAt: clock)

        #expect(HouseholdRecordConflictResolver.merge(unchecked, checked).value.isChecked)
    }

    @Test func equalShoppingContentClockUsesNewerRecord() {
        let clock = Date(timeIntervalSince1970: 100)
        let local = ShoppingItemPayload(
            value: shoppingValue(amount: 1, checked: false), ingredientID: nil,
            contentModifiedAt: clock, checkStateModifiedAt: clock
        )
        let server = ShoppingItemPayload(
            value: shoppingValue(amount: 2, checked: false), ingredientID: nil,
            contentModifiedAt: clock, checkStateModifiedAt: clock
        )
        let merged = HouseholdRecordConflictResolver.merge(
            local, server,
            localModifiedAt: clock,
            serverModifiedAt: clock.addingTimeInterval(10)
        )
        #expect(merged.value.canonicalValue == 2)
        #expect(HouseholdRecordConflictResolver.merge(local, server).value.canonicalValue == 2)
    }

    @Test func newerLocalRecordWinsAndIsResubmitted() throws {
        let uuid = UUID()
        let localDate = Date(timeIntervalSince1970: 200)
        let serverDate = Date(timeIntervalSince1970: 100)
        let localPayload = HouseholdRecordPayload.recipeBookmark(.init(uuid: uuid, title: "Local", urlString: "https://example.com/local", dateAdded: localDate))
        let serverPayload = HouseholdRecordPayload.recipeBookmark(.init(uuid: uuid, title: "Server", urlString: "https://example.com/server", dateAdded: serverDate))
        let local = LocalHouseholdRecord(
            identity: .init(type: .recipeBookmark, uuid: uuid),
            householdID: UUID(),
            modifiedAt: localDate,
            payloadData: try HouseholdRecordCodec.encode(localPayload)
        )
        let record = CKRecord(recordType: HouseholdRecordType.recipeBookmark.rawValue)
        record[HouseholdRecordCodec.payloadKey] = try HouseholdRecordCodec.encode(serverPayload) as CKRecordValue
        record[HouseholdRecordCodec.modifiedAtKey] = serverDate as CKRecordValue

        let resolution = try HouseholdRecordConflictResolver.resolve(local: local, server: record)
        #expect(resolution.payloadData == local.payloadData)
        #expect(resolution.shouldUpload)
    }

    @Test func staleDeletionCannotRemoveNewerLocalRecord() throws {
        let localDate = Date(timeIntervalSince1970: 200)
        let local = LocalHouseholdRecord(
            identity: .init(type: .recipeBookmark, uuid: UUID()),
            householdID: UUID(),
            modifiedAt: localDate,
            payloadData: Data("local".utf8)
        )

        #expect(HouseholdRecordConflictResolver.shouldPreserveLocalForDeletion(
            local: local, deletedAt: Date(timeIntervalSince1970: 100)
        ))
        #expect(!HouseholdRecordConflictResolver.shouldPreserveLocalForDeletion(
            local: local, deletedAt: Date(timeIntervalSince1970: 300)
        ))
    }

    @Test func rawDeletionPreservesPendingLocalRecord() {
        let local = LocalHouseholdRecord(
            identity: .init(type: .dish, uuid: UUID()),
            householdID: UUID(),
            modifiedAt: .now,
            payloadData: Data("local".utf8)
        )

        #expect(HouseholdRecordConflictResolver.shouldPreserveLocalForRawDeletion(
            local: local, acknowledgedFingerprint: local.fingerprint, isPending: true
        ))
        #expect(!HouseholdRecordConflictResolver.shouldPreserveLocalForRawDeletion(
            local: local, acknowledgedFingerprint: local.fingerprint, isPending: false
        ))
        #expect(!HouseholdRecordConflictResolver.shouldPreserveLocalForRawDeletion(
            local: nil, acknowledgedFingerprint: nil, isPending: false
        ))
    }

    @Test func newerLocalPhotoKeepsItsOwnAssetDuringConflict() throws {
        let imageID = UUID()
        let dishID = UUID()
        let localDate = Date(timeIntervalSince1970: 200)
        let serverDate = Date(timeIntervalSince1970: 100)
        let payload = HouseholdRecordPayload.dishImage(.init(
            dishID: dishID, sortIndex: 0, isPrimary: true, dateAdded: serverDate
        ))
        let localBytes = Data([1, 2, 3])
        let local = LocalHouseholdRecord(
            identity: .init(type: .dishImage, uuid: imageID),
            householdID: UUID(),
            modifiedAt: localDate,
            payloadData: try HouseholdRecordCodec.encode(payload),
            assetData: localBytes
        )
        let record = CKRecord(recordType: HouseholdRecordType.dishImage.rawValue)
        record[HouseholdRecordCodec.payloadKey] = try HouseholdRecordCodec.encode(payload) as CKRecordValue
        record[HouseholdRecordCodec.modifiedAtKey] = serverDate as CKRecordValue

        let resolution = try HouseholdRecordConflictResolver.resolve(
            local: local,
            server: record,
            serverAssetData: Data([9, 9, 9])
        )

        #expect(resolution.assetData == localBytes)
        #expect(resolution.shouldUpload)
    }

    @Test func missingServerPhotoDoesNotEraseLocalAssetAndIsRepaired() throws {
        let imageID = UUID()
        let dishID = UUID()
        let localDate = Date(timeIntervalSince1970: 100)
        let serverDate = Date(timeIntervalSince1970: 200)
        let payload = HouseholdRecordPayload.dishImage(.init(
            dishID: dishID, sortIndex: 0, isPrimary: true, dateAdded: localDate
        ))
        let localBytes = Data([4, 5, 6])
        let local = LocalHouseholdRecord(
            identity: .init(type: .dishImage, uuid: imageID),
            householdID: UUID(),
            modifiedAt: localDate,
            payloadData: try HouseholdRecordCodec.encode(payload),
            assetData: localBytes
        )
        let record = CKRecord(recordType: HouseholdRecordType.dishImage.rawValue)
        record[HouseholdRecordCodec.payloadKey] = try HouseholdRecordCodec.encode(payload) as CKRecordValue
        record[HouseholdRecordCodec.modifiedAtKey] = serverDate as CKRecordValue

        let resolution = try HouseholdRecordConflictResolver.resolve(
            local: local,
            server: record,
            serverAssetData: nil
        )

        #expect(resolution.assetData == localBytes)
        #expect(resolution.shouldUpload)
    }

    @Test func temporarilyUnreadableServerPhotoDoesNotOverwriteCloudAsset() throws {
        let imageID = UUID()
        let localDate = Date(timeIntervalSince1970: 100)
        let serverDate = Date(timeIntervalSince1970: 200)
        let payload = HouseholdRecordPayload.dishImage(.init(
            dishID: UUID(), sortIndex: 0, isPrimary: true, dateAdded: localDate
        ))
        let localBytes = Data([4, 5, 6])
        let local = LocalHouseholdRecord(
            identity: .init(type: .dishImage, uuid: imageID),
            householdID: UUID(),
            modifiedAt: localDate,
            payloadData: try HouseholdRecordCodec.encode(payload),
            assetData: localBytes
        )
        let record = CKRecord(recordType: HouseholdRecordType.dishImage.rawValue)
        record[HouseholdRecordCodec.payloadKey] = try HouseholdRecordCodec.encode(payload) as CKRecordValue
        record[HouseholdRecordCodec.modifiedAtKey] = serverDate as CKRecordValue

        let resolution = try HouseholdRecordConflictResolver.resolve(
            local: local,
            server: record,
            serverAssetData: nil,
            serverHasAsset: true
        )

        #expect(resolution.assetData == localBytes)
        #expect(!resolution.shouldUpload)
    }

    @Test func applyingMissingPhotoAssetPreservesStoredBytes() throws {
        // External-storage attributes need a real SQLite connection on macOS;
        // the in-memory store can report "No eligible connection available".
        let storeDirectory = FileManager.default.temporaryDirectory
            .appending(path: "MealPlan-photo-apply-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let schema = SharedStore.makeSchema()
        let configuration = ModelConfiguration(
            schema: schema,
            url: storeDirectory.appending(path: "test.sqlite"),
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let household = Household(name: "Test")
        let dish = Dish(name: "Soup")
        let image = DishImage(data: Data([7, 8, 9]), isPrimary: true)
        dish.household = household
        image.dish = dish
        context.insert(household)
        context.insert(dish)
        context.insert(image)
        try context.save()

        let payload = HouseholdRecordPayload.dishImage(.init(
            dishID: dish.uuid,
            sortIndex: 2,
            isPrimary: false,
            dateAdded: image.dateAdded
        ))
        try HouseholdRecordApplier.apply(
            payloadData: HouseholdRecordCodec.encode(payload),
            identity: .init(type: .dishImage, uuid: image.uuid),
            modifiedAt: .now,
            assetData: nil,
            household: household,
            context: context
        )

        #expect(image.data == Data([7, 8, 9]))
        #expect(image.sortIndex == 2)
        #expect(!image.isPrimary)
    }

    @Test func assetBackedRecordCannotUploadWithoutBytes() throws {
        let identity = HouseholdRecordIdentity(type: .dishImage, uuid: UUID())
        let payload = HouseholdRecordPayload.dishImage(.init(
            dishID: UUID(), sortIndex: 0, isPrimary: true, dateAdded: .now
        ))
        let snapshot = LocalHouseholdRecord(
            identity: identity,
            householdID: UUID(),
            modifiedAt: .now,
            payloadData: try HouseholdRecordCodec.encode(payload),
            assetData: nil
        )

        #expect(throws: HouseholdRecordCodecError.self) {
            try HouseholdRecordCodec.makeRecord(
                from: snapshot,
                zoneID: CKRecordZone.ID(zoneName: "test")
            )
        }
    }

    private func planValue(date: Date, meal: String, note: String?) -> MealPlanBackup.PortableEntry {
        .init(
            uuid: UUID(), date: date, mealKey: meal, dishUUID: nil, servingsOverride: nil,
            note: note, sortIndex: 0, reactionRaw: nil, skipped: false, prepReminder: false,
            plannedByName: nil, lastEditedByName: nil, lastEditedDate: nil,
            isEatingOut: false, placeName: nil, placeAddress: nil,
            placeLatitude: nil, placeLongitude: nil, routineUUID: nil
        )
    }

    private func shoppingValue(amount: Double, checked: Bool) -> MealPlanBackup.PortableShoppingItem {
        .init(
            uuid: UUID(), name: "Milk", normalizedName: "milk", categoryRaw: IngredientCategory.dairy.rawValue,
            customAisleName: nil, canonicalValue: amount, canonicalDimensionRaw: QuantityDimension.volume.rawValue,
            displayText: nil, displayUnit: "l", isChecked: checked, isManual: true,
            isApproximate: false, sortIndex: 0, rangeStart: nil, rangeEnd: nil,
            sourceDishNames: [], dateCreated: .now, ingredientKey: nil
        )
    }
}
