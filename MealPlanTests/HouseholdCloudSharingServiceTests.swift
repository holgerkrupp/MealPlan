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

    @Test func preflightTreatsNonRecipeHouseholdDataAsAtRisk() {
        let household = Household(name: String(localized: "Family"))
        #expect(!HouseholdCloudSharingService.hasRecoverableUserContent(household))

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
