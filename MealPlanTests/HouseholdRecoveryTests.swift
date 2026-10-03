import Foundation
import Testing
@testable import MealPlan

@MainActor
struct HouseholdRecoveryTests {
    private func candidate(
        source: HouseholdRecoverySource = .privateZone,
        zoneName: String = "MealPlanHousehold-00000000-0000-0000-0000-000000000001",
        share: String? = nil,
        retentionUntil: Date? = nil
    ) -> HouseholdRecoveryCandidate {
        .init(
            householdID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Krupp",
            locator: .init(
                zoneName: zoneName,
                ownerName: "__defaultOwner__",
                shareRecordName: share,
                isOwner: true,
                isReadOnly: false
            ),
            source: source,
            role: .owner,
            dishCount: 12,
            entryCount: 8,
            memberCount: 2,
            entryStart: Date(timeIntervalSince1970: 100),
            entryEnd: Date(timeIntervalSince1970: 200),
            dateCreated: Date(timeIntervalSince1970: 10),
            lastModifiedAt: Date(timeIntervalSince1970: 300),
            isShared: share != nil,
            isActiveOnThisDevice: false,
            deletedAt: nil,
            retentionUntil: retentionUntil
        )
    }

    @Test func exactRecoveryIdentityIncludesScopeZoneAndShare() {
        let privateZone = candidate()
        let sharedZone = candidate(source: .sharedZone)
        let replacementShare = candidate(share: "share-two")
        let oldZone = candidate(zoneName: "MealPlanHousehold-00000000-0000-0000-0000-000000000001-old")

        #expect(privateZone.id != sharedZone.id)
        #expect(privateZone.id != replacementShare.id)
        #expect(privateZone.id != oldZone.id)
    }

    @Test func permanentDeletionCannotBeOfferedBeforeRetentionExpires() {
        let active = candidate(retentionUntil: Date.now.addingTimeInterval(60))
        let expired = candidate(retentionUntil: Date.now.addingTimeInterval(-60))
        let normal = candidate()

        #expect(!active.isPurgeEligible)
        #expect(expired.isPurgeEligible)
        #expect(!normal.isPurgeEligible)
    }

    @Test func recentlyDeletedEntryKeepsTheOriginalShareLocator() {
        let original = candidate(share: "share-record")
        var deleted = original
        deleted.source = .recentlyDeleted
        deleted.deletedAt = .now
        deleted.retentionUntil = Date.now.addingTimeInterval(HouseholdRecoveryIndex.retention)

        #expect(deleted.locator.zoneName == original.locator.zoneName)
        #expect(deleted.locator.ownerName == original.locator.ownerName)
        #expect(deleted.locator.shareRecordName == "share-record")
    }
}
