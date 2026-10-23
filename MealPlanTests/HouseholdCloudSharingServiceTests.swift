import Testing
import CloudKit
import Foundation
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

    @Test func existingShareSkipsFullHouseholdPreparationSync() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "MealPlanHousehold-test", ownerName: CKCurrentUserDefaultName)
        let existingShare = CKShare(recordZoneID: zoneID)
        var syncCount = 0

        try await MealPlanSharePreparation.run(
            existingShare: { existingShare },
            synchronize: { syncCount += 1 }
        )

        #expect(syncCount == 0)
    }

    @Test func newShareRunsPreparationSyncBeforeCreation() async throws {
        var syncCount = 0

        try await MealPlanSharePreparation.run(
            existingShare: { nil },
            synchronize: { syncCount += 1 }
        )

        #expect(syncCount == 1)
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
