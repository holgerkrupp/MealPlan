import Foundation
import Testing
@testable import MealPlan

@MainActor
struct HouseholdCollaborationSessionTests {
    @Test func offlineLaunchRestoresPersistedViewOnlyRole() throws {
        let household = Household(name: "Family")
        let locator = HouseholdShareLocator(
            zoneName: "MealPlanHousehold-\(household.uuid.uuidString)",
            ownerName: "owner",
            shareRecordName: "share",
            isOwner: false,
            isReadOnly: true
        )
        household.cloudKitShareIdentifier = try HouseholdShareLocator.encode(locator)

        let session = HouseholdCollaborationSession()
        session.restore(for: household)

        #expect(session.role == .viewOnly)
        #expect(!session.canEdit)
    }

    @Test func locatorCannotBeRelaxedByStaleEditableCache() throws {
        let household = Household(name: "Family")
        let locator = HouseholdShareLocator(
            zoneName: "MealPlanHousehold-\(household.uuid.uuidString)",
            ownerName: "owner",
            shareRecordName: "share",
            isOwner: false,
            isReadOnly: true
        )
        household.cloudKitShareIdentifier = try HouseholdShareLocator.encode(locator)
        HouseholdCollaborationStore.store(.init(householdID: household.uuid, role: .editor, displayName: "Alex"))

        let session = HouseholdCollaborationSession()
        session.restore(for: household)

        #expect(session.role == .viewOnly)
        #expect(!session.canEdit)
    }

    @Test func migrationIsIdempotentAndOffline() {
        let suiteName = "de.holgerkrupp.mealplan.tests.migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(HouseholdCollaborationMigration.migrateIfNeeded(defaults: defaults))
        #expect(HouseholdCollaborationMigration.migrateIfNeeded(defaults: defaults))
    }

    @Test func storeGenerationMonotonicallyMarksExternalWrites() {
        let suiteName = "de.holgerkrupp.mealplan.tests.generation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = HouseholdStoreGeneration.value(defaults: defaults)
        HouseholdStoreGeneration.markDirty(defaults: defaults)
        HouseholdStoreGeneration.markDirty(defaults: defaults)
        #expect(HouseholdStoreGeneration.value(defaults: defaults) == initial + 2)
    }

    @Test func roleRefreshAndProfileEditMergeIndependently() {
        let start = Date(timeIntervalSince1970: 100)
        let profileEdit = Date(timeIntervalSince1970: 300)
        let roleRefresh = Date(timeIntervalSince1970: 400)
        let local = MemberPayload(
            name: "Alex",
            roleRaw: MemberRole.editor.rawValue,
            dateAdded: start,
            cloudKitParticipantID: "participant",
            isActive: true,
            allergies: ["peanut"],
            shareMetadataModifiedAt: start,
            profileModifiedAt: profileEdit
        )
        let remote = MemberPayload(
            name: "Alexandra",
            roleRaw: MemberRole.guest.rawValue,
            dateAdded: start,
            cloudKitParticipantID: "participant",
            isActive: true,
            allergies: [],
            shareMetadataModifiedAt: roleRefresh,
            profileModifiedAt: start
        )

        let merged = HouseholdRecordConflictResolver.merge(
            local,
            remote,
            localModifiedAt: profileEdit,
            serverModifiedAt: roleRefresh
        )

        #expect(merged.roleRaw == MemberRole.guest.rawValue)
        #expect(merged.name == "Alexandra")
        #expect(merged.allergies == ["peanut"])
    }
}
