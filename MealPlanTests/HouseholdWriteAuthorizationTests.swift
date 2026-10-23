import Foundation
import SwiftData
import Testing
@testable import MealPlan

@MainActor
struct HouseholdWriteAuthorizationTests {
    #if os(iOS)
    @Test func watchChecksAreRejectedForPersistedViewOnlyShare() throws {
        let household = Household(name: "Family")
        let locator = HouseholdShareLocator(
            zoneName: "MealPlanHousehold-\(household.uuid.uuidString)",
            ownerName: "owner",
            shareRecordName: "share",
            isOwner: false,
            isReadOnly: true
        )
        household.cloudKitShareIdentifier = try HouseholdShareLocator.encode(locator)
        let item = ShoppingListItem(name: "Milk")
        item.household = household

        #expect(!WatchShoppingCheckAuthorization.canApply(item))
    }
    #endif

    @Test func shoppingMutationBoundaryRejectsViewOnlyShare() throws {
        let (container, directory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let household = Household(name: "Family")
        let locator = HouseholdShareLocator(
            zoneName: "MealPlanHousehold-\(household.uuid.uuidString)",
            ownerName: "owner",
            shareRecordName: "share",
            isOwner: false,
            isReadOnly: true
        )
        household.cloudKitShareIdentifier = try HouseholdShareLocator.encode(locator)
        let item = ShoppingListItem(name: "Milk")
        item.household = household
        let context = container.mainContext
        context.insert(household)
        context.insert(item)

        ShoppingListMutationService.setChecked(item, checked: true, context: context)
        #expect(!item.isChecked)
    }

    @Test func cachedSharePermissionIsNotOverriddenByMemberRoleProjection() throws {
        let household = Household(name: "Family")
        let locator = HouseholdShareLocator(
            zoneName: "MealPlanHousehold-\(household.uuid.uuidString)",
            ownerName: "owner",
            shareRecordName: "share",
            isOwner: false,
            isReadOnly: false
        )
        household.cloudKitShareIdentifier = try HouseholdShareLocator.encode(locator)
        let member = HouseholdMember(name: "Alex", role: .guest, isCurrentUser: true)
        member.household = household
        household.members = [member]
        HouseholdCollaborationStore.store(.init(householdID: household.uuid, role: .editor))

        #expect(HouseholdMutationAuthorization.canMutate(household: household))
    }

    @Test func missingPermissionSnapshotFailsClosedForSharedParticipant() throws {
        let suiteName = "de.holgerkrupp.mealplan.tests.write-auth.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let participantHousehold = Household(name: "Shared")
        participantHousehold.cloudKitShareIdentifier = try HouseholdShareLocator.encode(
            HouseholdShareLocator(
                zoneName: "MealPlanHousehold-\(participantHousehold.uuid.uuidString)",
                ownerName: "owner",
                shareRecordName: "share",
                isOwner: false,
                isReadOnly: false
            )
        )
        #expect(!HouseholdCollaborationStore.canMutate(participantHousehold, defaults: defaults))

        let ownerHousehold = Household(name: "Owned")
        ownerHousehold.cloudKitShareIdentifier = try HouseholdShareLocator.encode(
            HouseholdShareLocator(
                zoneName: "MealPlanHousehold-\(ownerHousehold.uuid.uuidString)",
                ownerName: "owner",
                shareRecordName: "share",
                isOwner: true,
                isReadOnly: false
            )
        )
        #expect(HouseholdCollaborationStore.canMutate(ownerHousehold, defaults: defaults))
        #expect(HouseholdCollaborationStore.canMutate(Household(name: "Solo"), defaults: defaults))
    }
}
