import Foundation
import Testing
@testable import MealPlan

@Suite(.serialized)
@MainActor
struct ReviewEligibilityPolicyTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        value.minimumDaysInFirstWeek = 4
        return value
    }

    private func date(_ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 12))!
    }

    private func store(
        state: ReviewEngagementState = .empty,
        persistence: InMemoryReviewEngagementPersistence? = nil
    ) -> (ReviewEngagementStore, InMemoryReviewEngagementPersistence) {
        let persistence = persistence ?? InMemoryReviewEngagementPersistence(state: state)
        let store = ReviewEngagementStore(
            persistence: persistence,
            now: { self.date(15) },
            calendar: { self.calendar }
        )
        return (store, persistence)
    }

    private func record(
        _ store: ReviewEngagementStore,
        days: [Int],
        source: ReviewPlacementSource = .direct
    ) {
        for day in days {
            _ = store.recordSuccessfulPlacement(
                id: UUID(),
                source: source,
                at: date(day)
            )
        }
    }

    @Test func ninePlacementsNeverQualify() {
        let (store, _) = store()
        record(store, days: Array(repeating: 1, count: 9))
        #expect(store.snapshot().successfulPlacementCount == 9)
        #expect(!ReviewEligibilityPolicy.standard.isEligible(store.snapshot()))
    }

    @Test func duplicateSaveAndRetryCountOnce() {
        let (store, _) = store()
        let id = UUID()
        #expect(store.recordSuccessfulPlacement(id: id, at: date(1)))
        #expect(!store.recordSuccessfulPlacement(id: id, at: date(15)))
        let state = store.snapshot()
        #expect(state.successfulPlacementCount == 1)
        #expect(state.firstQualifyingActionAt == date(1))
        #expect(state.latestQualifyingActionAt == date(1))
    }

    @Test func copiedRecurringAndImportedOperationsDoNotCreateEngagementEvents() {
        let (store, _) = store()
        record(store, days: Array(repeating: 1, count: 10), source: .bulk)
        record(store, days: Array(repeating: 1, count: 10), source: .imported)
        #expect(store.snapshot().successfulPlacementCount == 0)
    }

    @Test func threeWeeksButLessThanFourteenDaysDoesNotQualify() {
        let (store, _) = store()
        record(store, days: [1, 3, 8, 9, 10, 11, 12, 13, 14, 14])
        let state = store.snapshot()
        #expect(state.activeWeekKeys.count == 3)
        #expect(state.latestQualifyingActionAt!.timeIntervalSince(state.firstQualifyingActionAt!) < 14 * 24 * 60 * 60)
        #expect(!ReviewEligibilityPolicy.standard.isEligible(state))
    }

    @Test func tenDirectPlacementsAcrossThreeWeeksAndFourteenDaysQualify() {
        let (store, _) = store()
        record(store, days: [1, 2, 3, 4, 5, 6, 7, 8, 10, 15])
        let state = store.snapshot()
        #expect(state.successfulPlacementCount == 10)
        #expect(state.activeWeekKeys.count == 3)
        #expect(ReviewEligibilityPolicy.standard.isEligible(state))
        #expect(state.pendingRequest)
    }

    @Test func calendarWeekRulesAreUsedInsteadOfPlannedMealDates() {
        let policy = ReviewEligibilityPolicy.standard
        var usCalendar = calendar
        usCalendar.firstWeekday = 1
        usCalendar.minimumDaysInFirstWeek = 1
        let sunday = date(1)
        #expect(policy.weekKey(for: sunday, calendar: calendar) != policy.weekKey(for: sunday, calendar: usCalendar))
    }

    @Test func stateSurvivesAStoreRestartAndFailedWritesDoNotCount() {
        let persistence = InMemoryReviewEngagementPersistence()
        let first = store(persistence: persistence).0
        #expect(first.recordSuccessfulPlacement(id: UUID(), at: date(1)))
        let restarted = store(persistence: persistence).0
        #expect(restarted.snapshot().successfulPlacementCount == 1)

        let failing = InMemoryReviewEngagementPersistence()
        failing.updateError = TestError.expected
        let failedStore = store(persistence: failing).0
        #expect(!failedStore.recordSuccessfulPlacement(id: UUID(), at: date(1)))
        #expect(failedStore.snapshot() == .empty)
    }

    @Test func promptAttemptsAreOncePerVersionAndCooldownBounded() {
        let (store, _) = store()
        record(store, days: [1, 2, 3, 4, 5, 6, 7, 8, 10, 15])
        let state = store.snapshot()
        let now = date(15)
        #expect(ReviewEligibilityPolicy.standard.canAttempt(
            state, at: now, appVersion: "1", cooldown: .zero
        ))
        #expect(store.recordPromptAttempt(at: now, appVersion: "1"))
        let attempted = store.snapshot()
        #expect(!ReviewEligibilityPolicy.standard.canAttempt(
            attempted, at: now, appVersion: "1", cooldown: .zero
        ))
        #expect(!ReviewEligibilityPolicy.standard.canAttempt(
            attempted, at: now.addingTimeInterval(30 * 24 * 60 * 60), appVersion: "2", cooldown: 365 * 24 * 60 * 60
        ))
    }

    @Test func coordinatorRecordsAttemptBeforeCallingNativeAction() async {
        let (store, _) = store()
        record(store, days: [1, 2, 3, 4, 5, 6, 7, 8, 10, 15])
        var requestCount = 0
        let coordinator = AppReviewPromptCoordinator(
            store: store,
            appVersion: "test",
            now: { self.date(15) },
            cooldown: .zero,
            presentationDelay: .zero
        )
        coordinator.install(requestReview: { requestCount += 1 }, isBusy: { false })
        let sceneID = UUID()
        coordinator.sceneBecameActive(sceneID)
        await Task.yield()
        await Task.yield()
        #expect(requestCount == 1)
        #expect(store.snapshot().lastPromptAttemptVersion == "test")
        coordinator.sceneBecameInactive(sceneID)
    }

    private enum TestError: Error { case expected }
}
