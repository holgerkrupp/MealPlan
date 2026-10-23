import Testing
import CloudKit
import Foundation
import SwiftData
import CollaborationCore
#if canImport(UIKit)
import UIKit
#endif
@testable import MealPlan

/// Host-owned routing still queues CloudKit invitations until the household
/// store and replacement preflight are ready. Share lifecycle itself belongs
/// to CloudKitCollaborationKit.
@MainActor
struct HouseholdCloudSharingServiceTests {

    @Test func coalescesDuplicateShareDeliveriesButAllowsRetry() {
        var gate = CloudShareDeliveryGate()

        let firstDelivery = gate.shouldDeliver("container|owner|zone|share")
        let duplicateDelivery = gate.shouldDeliver("container|owner|zone|share")
        #expect(firstDelivery)
        #expect(!duplicateDelivery)

        gate.allowRedelivery("container|owner|zone|share")
        let retryDelivery = gate.shouldDeliver("container|owner|zone|share")
        #expect(retryDelivery)
    }

    @Test func reusingExistingShareSkipsHouseholdSynchronization() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "MealPlanHousehold-test", ownerName: CKCurrentUserDefaultName)
        let existingShare = CKShare(recordZoneID: zoneID)
        var syncCount = 0

        try await MealPlanSharePreparation.run(
            existingShare: { existingShare },
            synchronize: { syncCount += 1 }
        )

        #expect(syncCount == 0)
    }

    @Test func firstInvitationSynchronizesLocalChangesBeforeCreatingShare() async throws {
        var syncCount = 0

        try await MealPlanSharePreparation.run(
            existingShare: { nil },
            synchronize: { syncCount += 1 }
        )

        #expect(syncCount == 1)
    }

    @Test func existingShareLookupFailureStopsBeforeSynchronization() async throws {
        var syncCount = 0
        let lookupError = CKError(.networkUnavailable)

        do {
            try await MealPlanSharePreparation.run(
                existingShare: { throw lookupError },
                synchronize: { syncCount += 1 }
            )
            Issue.record("Expected share lookup failure to be propagated.")
        } catch let error as CKError {
            #expect(error.code == .networkUnavailable)
        }

        #expect(syncCount == 0)
    }

    @Test @MainActor func sharedHouseholdFetchWaiterIsBoundedAndAcceptsEarlyCompletion() async throws {
        let completed = SharedHouseholdFetchWaiter()
        completed.complete(nil)
        try await completed.wait(timeout: .milliseconds(1))

        let timedOut = SharedHouseholdFetchWaiter()
        do {
            try await timedOut.wait(timeout: .milliseconds(1))
            Issue.record("Expected the shared-household fetch waiter to time out.")
        } catch HouseholdSharingError.sharedHouseholdFetchTimedOut {
            // Expected: a missing package callback must not hold up the join forever.
        } catch {
            Issue.record("Unexpected fetch waiter error: \(error)")
        }
    }

    @Test @MainActor func packageFetchFailureRetainsIncomingAndSourceHouseholdRoots() async throws {
        try await assertFailedJoinRetainsAllRoots(timeout: false)
    }

    @Test @MainActor func packageFetchTimeoutRetainsIncomingAndSourceHouseholdRoots() async throws {
        try await assertFailedJoinRetainsAllRoots(timeout: true)
    }

    @Test @MainActor func failedSourceTransportRestoreStopsTheStagedTransport() async throws {
        let (container, storeDirectory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let context = container.mainContext
        let source = Household(name: "Source")
        let incoming = Household(name: "Incoming")
        context.insert(source)
        context.insert(incoming)
        try context.save()

        var stoppedTransport = false
        do {
            try await HouseholdCloudSharingService.finishAcceptedHouseholdAfterSharedFetch(
                SharedHouseholdFetchWaiter(),
                incoming,
                sourceHousehold: source,
                mergeRecipes: false,
                context: context,
                timeout: .milliseconds(1),
                restoreTransport: { _, _ in throw HouseholdRecoveryError.requiredAssetUnavailable },
                stopTransport: { stoppedTransport = true }
            )
            Issue.record("Expected the missing fetch callback to fail the join.")
        } catch {
            // A failed rollback must stop the incoming observer before the
            // join error reaches the caller.
        }

        #expect(stoppedTransport)
        #expect(try context.fetch(FetchDescriptor<Household>()).count == 2)
    }

    @Test func bootstrapAssetReadsFailClosedForMissingEmptyAndUnreadableFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MealPlan-bootstrap-assets-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try HouseholdCloudBootstrapService.readAssetData(nil) == nil)

        let validURL = directory.appending(path: "valid.png")
        let validData = Data([0x89, 0x50, 0x4E, 0x47])
        try validData.write(to: validURL)
        #expect(try HouseholdCloudBootstrapService.readAssetData(CKAsset(fileURL: validURL)) == validData)

        let emptyURL = directory.appending(path: "empty.png")
        try Data().write(to: emptyURL)
        #expect(throws: HouseholdRecoveryError.self) {
            try HouseholdCloudBootstrapService.readAssetData(CKAsset(fileURL: emptyURL))
        }

        let missingURL = directory.appending(path: "missing.png")
        #expect(throws: HouseholdRecoveryError.self) {
            try HouseholdCloudBootstrapService.readAssetData(CKAsset(fileURL: missingURL))
        }

        #expect(throws: HouseholdRecoveryError.self) {
            try HouseholdCloudBootstrapService.readAssetData(CKAsset(fileURL: directory))
        }
    }

    private func assertFailedJoinRetainsAllRoots(timeout: Bool) async throws {
        let (container, storeDirectory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let context = container.mainContext
        let firstSource = Household(name: "First source")
        let secondSource = Household(name: "Second source")
        let incoming = Household(name: "Incoming")
        context.insert(firstSource)
        context.insert(secondSource)
        context.insert(incoming)
        try context.save()

        let waiter = SharedHouseholdFetchWaiter()
        if !timeout { waiter.complete(.offline) }
        var restoredSourceID: UUID?
        var stoppedTransport = false
        do {
            try await HouseholdCloudSharingService.finishAcceptedHouseholdAfterSharedFetch(
                waiter,
                incoming,
                sourceHousehold: firstSource,
                mergeRecipes: false,
                context: context,
                timeout: .milliseconds(1),
                restoreTransport: { source, _ in restoredSourceID = source.uuid },
                stopTransport: { stoppedTransport = true }
            )
            Issue.record("Expected the failed shared-zone fetch to keep source roots.")
        } catch {
            // A fetch failure or timeout must not reach the destructive finalize step.
        }

        let retainedIDs = Set(try context.fetch(FetchDescriptor<Household>()).map(\.uuid))
        #expect(retainedIDs == Set([firstSource.uuid, secondSource.uuid, incoming.uuid]))
        #expect(restoredSourceID == firstSource.uuid)
        #expect(!stoppedTransport)
    }

    @Test func preflightTreatsNonRecipeHouseholdDataAsAtRisk() {
        let household = Household(name: String(localized: "Family"))
        #expect(!HouseholdCloudSharingService.hasRecoverableUserContent(household))
        household.unlockedByPurchase = true
        #expect(!HouseholdCloudSharingService.hasRecoverableUserContent(household))
        household.unlockedByPurchase = false

        household.didSeedPantryStaples = true
        household.ingredients = PantryStaples.defaultSeeds.map { seed in
            let ingredient = Ingredient(name: seed.name, category: seed.category)
            ingredient.isPantryStaple = true
            ingredient.household = household
            return ingredient
        }
        household.mealTypes = MealType.defaultSeeds.enumerated().map { index, seed in
            let meal = MealType(key: seed.key, name: seed.name, symbolName: seed.symbol, sortOrder: index)
            meal.household = household
            return meal
        }
        #expect(!HouseholdCloudSharingService.hasRecoverableUserContent(household))

        household.ingredients?.first?.inventoryMode = .have
        #expect(HouseholdCloudSharingService.hasRecoverableUserContent(household))

        household.shoppingItems = [ShoppingListItem(name: "Offline item", isManual: true)]
        #expect(HouseholdCloudSharingService.hasRecoverableUserContent(household))

        household.shoppingItems = []
        household.mealRoutines = [MealRoutine()]
        #expect(HouseholdCloudSharingService.hasRecoverableUserContent(household))
    }

    /// Losing access turns the household into a new one on that device, so a
    /// passing network or server hiccup must never be read as removal.
    @Test func onlyAMissingShareOrZoneMeansAccessWasLost() {
        #expect(HouseholdCloudSharingService.indicatesLostAccess(CKError(.zoneNotFound)))
        #expect(HouseholdCloudSharingService.indicatesLostAccess(CKError(.unknownItem)))
        #expect(HouseholdCloudSharingService.indicatesLostAccess(CKError(.userDeletedZone)))

        #expect(!HouseholdCloudSharingService.indicatesLostAccess(CKError(.networkUnavailable)))
        #expect(!HouseholdCloudSharingService.indicatesLostAccess(CKError(.networkFailure)))
        #expect(!HouseholdCloudSharingService.indicatesLostAccess(CKError(.serviceUnavailable)))
        #expect(!HouseholdCloudSharingService.indicatesLostAccess(CKError(.notAuthenticated)))
        #expect(!HouseholdCloudSharingService.indicatesLostAccess(HouseholdSharingError.cloudKitDidNotReturnRecord))
    }

    @Test func partialFailureMeansLostAccessOnlyWhenEveryItemSaysSo() {
        let share = CKRecord.ID(recordName: "share")
        let root = CKRecord.ID(recordName: "root")
        let allGone = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [share: CKError(.zoneNotFound), root: CKError(.unknownItem)]])
        let mixed = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [share: CKError(.zoneNotFound), root: CKError(.networkFailure)]])
        #expect(HouseholdCloudSharingService.indicatesLostAccess(allGone))
        #expect(!HouseholdCloudSharingService.indicatesLostAccess(mixed))
    }

    @Test func backgroundRefreshOnlySilencesTemporaryCloudFailures() {
        let share = CKRecord.ID(recordName: "share")
        let root = CKRecord.ID(recordName: "root")
        let temporary = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [
                share: CKError(.networkFailure),
                root: CKError(.serviceUnavailable),
            ]
        ])
        let actionable = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [
                share: CKError(.networkFailure),
                root: CKError(.notAuthenticated),
            ]
        ])
        #expect(HouseholdCloudSharingService.isTemporarySyncFailure(temporary))
        #expect(!HouseholdCloudSharingService.isTemporarySyncFailure(actionable))
        #expect(!HouseholdCloudSharingService.isTemporarySyncFailure(CKError(.notAuthenticated)))
        #expect(!HouseholdCloudSharingService.isTemporarySyncFailure(CKError(.quotaExceeded)))
    }

    #if canImport(UIKit)
    @Test func windowScenesUseCloudSharingDelegate() {
        let configuration = AppDelegate.sceneConfiguration(for: .windowApplication)
        #expect(configuration.delegateClass == MealPlanSceneDelegate.self)
    }
    #endif
}
