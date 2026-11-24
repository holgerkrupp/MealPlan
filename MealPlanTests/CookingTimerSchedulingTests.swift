import Foundation
import Testing
@testable import MealPlan

private struct FixedCookingTimerClock: CookingTimerClock {
    let now: Date
}

private actor RecordingCookingTimerScheduler: CookingTimerScheduling {
    private(set) var scheduled: [(UUID, Date)] = []
    private(set) var cancelled: [UUID] = []
    private(set) var reconciled: [[UUID]] = []
    var scheduleStatus: CookingTimerDeliveryStatus = .localNotification

    func authorizationStatus() async -> CookingTimerAlertAuthorization { .authorized }

    func schedule(_ timer: CookingTimerState, at date: Date) async -> CookingTimerDeliveryStatus {
        scheduled.append((timer.id, date))
        return scheduleStatus
    }

    func cancel(_ id: UUID) async {
        cancelled.append(id)
    }

    func cancel(_ ids: [UUID]) async {
        cancelled.append(contentsOf: ids)
    }

    func reconcile(_ timers: [CookingTimerState], at _: Date) async -> [UUID: CookingTimerDeliveryStatus] {
        reconciled.append(timers.map(\.id))
        return Dictionary(uniqueKeysWithValues: timers.map { ($0.id, scheduleStatus) })
    }

    func snapshot() -> (scheduled: [UUID], cancelled: [UUID], reconciled: [[UUID]]) {
        (scheduled.map(\.0), cancelled, reconciled)
    }
}

struct CookingTimerSchedulingTests {
    @Test func timerIdentityRemainsIndependentForOverlappingAndDuplicateTimers() {
        let dishID = UUID()
        let start = Date(timeIntervalSince1970: 10_000)
        var session = CookingSessionState(
            dishID: dishID,
            dishName: "Dough",
            servings: 2,
            now: start
        )

        let first = CookingTimerState(
            dishID: dishID,
            dishName: "Dough",
            stepNumber: 1,
            stepText: "Proof",
            label: "Kitchen timer",
            duration: 3_600,
            endDate: start.addingTimeInterval(3_600)
        )
        let second = CookingTimerState(
            dishID: dishID,
            dishName: "Dough",
            stepNumber: 1,
            stepText: "Proof",
            label: "Kitchen timer",
            duration: 1_500,
            endDate: start.addingTimeInterval(1_500)
        )

        session.addTimer(first, at: start)
        session.addTimer(second, at: start)
        #expect(first.id != second.id)
        #expect(session.timers.map(\.id) == [first.id, second.id])

        _ = session.pauseOrResumeTimer(first.id, at: start.addingTimeInterval(300))
        #expect(session.timers.first { $0.id == first.id }?.pausedRemaining == 3_300)
        #expect(session.timers.first { $0.id == second.id }?.pausedRemaining == nil)
        #expect(session.timers.first { $0.id == second.id }?.remaining(at: start.addingTimeInterval(300)) == 1_200)
    }

    @Test @MainActor func storeUsesInjectedClockAndSchedulesEachTimerByUUID() async throws {
        let suiteName = "CookingTimerSchedulingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let start = Date(timeIntervalSince1970: 20_000)
        let dishID = UUID()
        let state = CookingSessionState(dishID: dishID, dishName: "Soup", servings: 2, now: start)
        defaults.set(try JSONEncoder().encode(state), forKey: "CookingSession.active.v1")

        let scheduler = RecordingCookingTimerScheduler()
        let store = CookingSessionStore(
            defaults: defaults,
            clock: FixedCookingTimerClock(now: start),
            scheduler: scheduler
        )
        let firstID = try #require(store.startTimer(
            dishID: dishID,
            dishName: "Soup",
            stepNumber: 1,
            stepText: "Simmer",
            label: "Sauce",
            duration: 1_500
        ))
        let secondID = try #require(store.startTimer(
            dishID: dishID,
            dishName: "Soup",
            stepNumber: 1,
            stepText: "Simmer",
            label: "Sauce",
            duration: 1_500
        ))

        for _ in 0..<10 { await Task.yield() }
        let snapshot = await scheduler.snapshot()
        #expect(Set(snapshot.scheduled) == Set([firstID, secondID]))
        #expect(store.session?.timers.map(\.id) == [firstID, secondID])

        store.pauseOrResumeTimer(firstID, at: start.addingTimeInterval(60))
        for _ in 0..<10 { await Task.yield() }
        let afterPause = await scheduler.snapshot()
        #expect(afterPause.cancelled.contains(firstID))
        #expect(store.session?.timers.first { $0.id == firstID }?.pausedRemaining == 1_440)
        #expect(store.session?.timers.first { $0.id == secondID }?.pausedRemaining == nil)
    }

    @Test func persistedTimerStateRestoresWithStableIdentity() throws {
        let dishID = UUID()
        let timerID = UUID()
        let date = Date(timeIntervalSince1970: 30_000)
        var state = CookingSessionState(dishID: dishID, dishName: "Bread", servings: 2, now: date)
        state.addTimer(CookingTimerState(
            id: timerID,
            dishID: dishID,
            dishName: "Bread",
            stepNumber: 2,
            stepText: "Bake",
            label: "Oven",
            duration: 900,
            endDate: date.addingTimeInterval(900),
            pausedRemaining: nil
        ), at: date)

        let restored = try JSONDecoder().decode(
            CookingSessionState.self,
            from: JSONEncoder().encode(state)
        )
        #expect(restored.timers.count == 1)
        #expect(restored.timers[0].id == timerID)
        #expect(restored.timers[0].remaining(at: date.addingTimeInterval(120)) == 780)
    }

    @Test func extendAndRepeatKeepTimerIdentityIndependent() {
        let dishID = UUID()
        let date = Date(timeIntervalSince1970: 40_000)
        var session = CookingSessionState(dishID: dishID, dishName: "Soup", servings: 2, now: date)
        let original = CookingTimerState(
            dishID: dishID, dishName: "Soup", stepNumber: 1, stepText: "Simmer",
            label: "Sauce", duration: 60, endDate: date.addingTimeInterval(60)
        )
        session.addTimer(original, at: date)

        let extended = session.extendTimer(original.id, by: 60, at: date)
        #expect(extended?.id == original.id)
        #expect(extended?.remaining(at: date) == 120)

        let repeated = session.repeatTimer(original.id, at: date)
        #expect(repeated?.id != original.id)
        #expect(session.timers.map(\.id) == [original.id, repeated?.id].compactMap { $0 })
    }
}
