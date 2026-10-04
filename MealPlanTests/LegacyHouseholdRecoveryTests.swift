import Foundation
import Testing
@testable import MealPlan

struct LegacyHouseholdRecoveryTests {
    private let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test func populatedSameAccountHouseholdsRequireReviewInsteadOfSilentReplacement() {
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

    @Test func sharedCandidateWinsDeterministicallyBeforeAge() {
        let plan = LegacyHouseholdRecoveryPlan.make(
            local: .init(householdID: second, contentRecordCount: 0),
            owned: [
                candidate(first, shared: false, created: 1, content: 8),
                candidate(second, shared: true, created: 3, content: 8),
            ]
        )

        #expect(plan == .noAction)
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
