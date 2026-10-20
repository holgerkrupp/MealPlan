import Foundation
import Testing
@testable import MealPlan

struct LegacyHouseholdRecoveryTests {
    private let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let third = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    @Test func populatedSameAccountHouseholdsRequireMergeBeforeSwitch() {
        let plan = LegacyHouseholdRecoveryPlan.make(
            local: .init(householdID: second, contentRecordCount: 12),
            owned: [
                candidate(first, shared: true, created: 1, content: 30),
                candidate(second, shared: false, created: 2, content: 12),
            ]
        )

        #expect(plan == .reviewRequired(canonicalHouseholdID: first, competingHouseholdIDs: [second]))
    }

    @Test func emptyLocalPlaceholderCanAdoptTheCanonicalSharedHousehold() {
        let plan = LegacyHouseholdRecoveryPlan.make(
            local: .init(householdID: second, contentRecordCount: 0),
            owned: [
                candidate(first, shared: true, created: 2, content: 8),
                candidate(second, shared: false, created: 3, content: 0),
            ]
        )

        #expect(plan == .adoptRemote(first))
    }

    @Test func anEmptyCompetingZoneDoesNotReplaceTheCanonicalLocalHousehold() {
        let plan = LegacyHouseholdRecoveryPlan.make(
            local: .init(householdID: first, contentRecordCount: 4),
            owned: [
                candidate(first, shared: false, created: 1, content: 4),
                candidate(second, shared: false, created: 2, content: 0),
            ]
        )

        #expect(plan == .noAction)
    }

    @Test func emptyDeviceCopiesOtherPopulatedZonesBeforeAdoptingCanonical() {
        let plan = LegacyHouseholdRecoveryPlan.make(
            local: .init(householdID: third, contentRecordCount: 0),
            owned: [
                candidate(first, shared: true, created: 1, content: 8),
                candidate(second, shared: false, created: 2, content: 5),
                candidate(third, shared: false, created: 3, content: 0),
            ]
        )

        #expect(plan == .reviewRequired(canonicalHouseholdID: first, competingHouseholdIDs: [second, third]))
    }

    @Test func populatedCompetingZoneStillRequiresReviewWhenCanonicalLocalIsEmpty() {
        let plan = LegacyHouseholdRecoveryPlan.make(
            local: .init(householdID: first, contentRecordCount: 0),
            owned: [
                candidate(first, shared: true, created: 1, content: 0),
                candidate(second, shared: false, created: 2, content: 6),
            ]
        )

        #expect(plan == .reviewRequired(canonicalHouseholdID: first, competingHouseholdIDs: [second]))
    }

    @Test func sharedCandidateWinsButPopulatedOtherZoneNeedsReview() {
        let plan = LegacyHouseholdRecoveryPlan.make(
            local: .init(householdID: second, contentRecordCount: 0),
            owned: [
                candidate(first, shared: false, created: 1, content: 8),
                candidate(second, shared: true, created: 3, content: 8),
            ]
        )

        #expect(plan == .reviewRequired(canonicalHouseholdID: second, competingHouseholdIDs: [first]))
    }

    @Test func completedReconciliationStaysCompleteUntilCompetingZoneChanges() {
        let canonical = candidate(first, shared: true, created: 1, content: 12)
        let old = LegacyOwnedHouseholdSummary(
            householdID: second,
            zoneName: "MealPlanHousehold-\(second.uuidString)",
            isShared: false,
            dateCreated: Date(timeIntervalSince1970: 2),
            contentRecordCount: 3,
            lastContentModification: Date(timeIntervalSince1970: 10)
        )
        let receipt = LegacyHouseholdReconciliationReceipt(canonicalHouseholdID: first, sources: [old])

        #expect(receipt.covers(localHouseholdID: first, owned: [canonical, old]))
        #expect(!receipt.covers(localHouseholdID: second, owned: [canonical, old]))
        let changed = LegacyOwnedHouseholdSummary(
            householdID: second,
            zoneName: old.zoneName,
            isShared: false,
            dateCreated: old.dateCreated,
            contentRecordCount: old.contentRecordCount,
            lastContentModification: Date(timeIntervalSince1970: 11)
        )
        #expect(!receipt.covers(localHouseholdID: first, owned: [canonical, changed]))
    }

    private func candidate(_ id: UUID, shared: Bool, created: TimeInterval, content: Int) -> LegacyOwnedHouseholdSummary {
        .init(
            householdID: id,
            zoneName: "MealPlanHousehold-\(id.uuidString)",
            isShared: shared,
            dateCreated: Date(timeIntervalSince1970: created),
            contentRecordCount: content
        )
    }
}
