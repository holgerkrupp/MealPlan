import Testing
import Foundation
@testable import MealPlan

/// The part of the watch link that can be pinned down without two devices:
/// what the snapshot says, and what survives the trip over WatchConnectivity.
/// The transport itself — sessions, reachability, queued transfers — is
/// exercised by hand on a real pair.
struct WatchSnapshotTests {

    // MARK: - Fixtures

    private func item(
        _ name: String,
        aisle: String,
        order: Int,
        sortIndex: Int = 0,
        checked: Bool = false,
        amount: String? = nil
    ) -> WatchShoppingItem {
        WatchShoppingItem(
            id: UUID(),
            name: name,
            amount: amount,
            aisle: aisle,
            aisleOrder: order,
            sortIndex: sortIndex,
            isChecked: checked
        )
    }

    private func meal(_ title: String, _ mealName: String = "Dinner") -> WatchMeal {
        WatchMeal(id: UUID(), mealName: mealName, mealSymbol: "fork.knife", title: title)
    }

    private var today: Date { Calendar.current.startOfDay(for: .now) }

    // MARK: - Aisles

    @Test func groupsTheListByAisleInShopOrder() {
        let list = [
            item("Brot", aisle: "Bakery", order: 5),
            item("Milch", aisle: "Dairy", order: 2),
            item("Käse", aisle: "Dairy", order: 2),
        ]
        #expect(list.aisles.map(\.name) == ["Dairy", "Bakery"])
        #expect(list.aisles.first?.items.count == 2)
    }

    @Test func keepsTheListsOwnOrderInsideAnAisle() {
        let list = [
            item("Käse", aisle: "Dairy", order: 2, sortIndex: 9),
            item("Milch", aisle: "Dairy", order: 2, sortIndex: 1),
        ]
        #expect(list.aisles.first?.items.map(\.name) == ["Milch", "Käse"])
    }

    /// A custom aisle name inherits the position of its earliest item, the way
    /// the phone's `ShoppingListGrouping` does — otherwise the two screens
    /// would walk the shop in different orders.
    @Test func aCustomAisleTakesThePositionOfItsEarliestItem() {
        let list = [
            item("Brot", aisle: "Backtheke", order: 5),
            item("Hefe", aisle: "Backtheke", order: 1),
            item("Milch", aisle: "Dairy", order: 2),
        ]
        #expect(list.aisles.map(\.name) == ["Backtheke", "Dairy"])
    }

    @Test func countsWhatIsLeftToBuy() {
        let list = [
            item("Brot", aisle: "Bakery", order: 5, checked: true),
            item("Milch", aisle: "Dairy", order: 2),
        ]
        #expect(list.remainingCount == 1)
    }

    // MARK: - Days

    @Test func showsOnlyDaysAheadThatHaveSomethingOnThem() {
        let snapshot = WatchPlanSnapshot(days: [
            WatchDay(date: today.adding(days: -1), meals: [meal("Gestern")]),
            WatchDay(date: today, meals: []),
            WatchDay(date: today.adding(days: 1), meals: [meal("Lasagne")]),
        ])
        #expect(snapshot.plannedDays().map(\.date) == [today.adding(days: 1)])
    }

    @Test func leadsWithTheNextMealStillAhead() {
        let snapshot = WatchPlanSnapshot(days: [
            WatchDay(date: today, meals: []),
            WatchDay(date: today.adding(days: 2), meals: [meal("Lasagne"), meal("Salat")]),
        ])
        #expect(snapshot.nextMeal()?.meal.title == "Lasagne")
        #expect(snapshot.nextMeal()?.day.date == today.adding(days: 2))
    }

    @Test func aSnapshotWithNothingPlannedAndNothingToBuyIsEmpty() {
        let snapshot = WatchPlanSnapshot(days: [WatchDay(date: today)])
        #expect(snapshot.isEmpty)
        #expect(!WatchPlanSnapshot(days: [], shopping: [item("Milch", aisle: "Dairy", order: 2)]).isEmpty)
    }

    // MARK: - Over the wire

    @Test func aSnapshotSurvivesTheTripToTheWatch() throws {
        let snapshot = WatchPlanSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            days: [WatchDay(date: today, meals: [meal("Lasagne", "Abendessen")])],
            shopping: [item("Milch", aisle: "Dairy", order: 2, amount: "500 ml")],
            shoppingRangeName: "This week"
        )
        let message = try #require(WatchSyncPayload.message(for: snapshot))
        #expect(WatchSyncPayload.snapshot(in: message) == snapshot)
    }

    @Test func ticksSurviveTheTripBack() throws {
        let checks = [
            WatchShoppingCheck(id: UUID(), isChecked: true, changedAt: Date(timeIntervalSince1970: 1_800_000_000)),
            WatchShoppingCheck(id: UUID(), isChecked: false, changedAt: Date(timeIntervalSince1970: 1_800_000_060)),
        ]
        let message = try #require(WatchSyncPayload.message(for: checks))
        #expect(WatchSyncPayload.checks(in: message) == checks)
    }

    /// Both directions share one dictionary, so each side has to be able to
    /// tell what it is looking at without decoding the other's payload.
    @Test func theTwoDirectionsAreNeverConfusedForEachOther() throws {
        let snapshotMessage = try #require(WatchSyncPayload.message(for: WatchPlanSnapshot()))
        #expect(WatchSyncPayload.checks(in: snapshotMessage).isEmpty)
        #expect(!WatchSyncPayload.isRefreshRequest(snapshotMessage))
        #expect(WatchSyncPayload.snapshot(in: WatchSyncPayload.refreshRequest) == nil)
        #expect(WatchSyncPayload.isRefreshRequest(WatchSyncPayload.refreshRequest))
    }

    @Test func nothingIsSentForAnEmptyBatchOfTicks() {
        #expect(WatchSyncPayload.message(for: []) == nil)
    }

    // MARK: - Cooking timers

    @Test func cookingTimerCountsDownLocallyAndKeepsPausedTimeStable() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let running = WatchCookingTimer(
            id: UUID(),
            dishName: "Dough",
            stepNumber: 1,
            stepText: "Proof",
            label: "Dough",
            duration: 3_600,
            endDate: start.addingTimeInterval(3_600),
            pausedRemaining: nil
        )
        let paused = WatchCookingTimer(
            id: UUID(),
            dishName: "Sauce",
            stepNumber: 2,
            stepText: "Simmer",
            label: "Sauce",
            duration: 1_500,
            endDate: start.addingTimeInterval(1_500),
            pausedRemaining: 900
        )
        let completed = WatchCookingTimer(
            id: UUID(),
            dishName: "Oven",
            stepNumber: 3,
            stepText: "Bake",
            label: "Oven",
            duration: 900,
            endDate: start.addingTimeInterval(900),
            pausedRemaining: nil
        )

        #expect(running.remaining(at: start.addingTimeInterval(600)) == 3_000)
        #expect(running.state(at: start.addingTimeInterval(600)) == .running)
        #expect(paused.remaining(at: start.addingTimeInterval(2_000)) == 900)
        #expect(paused.state(at: start.addingTimeInterval(2_000)) == .paused)
        #expect(completed.remaining(at: start.addingTimeInterval(901)) == 0)
        #expect(completed.state(at: start.addingTimeInterval(901)) == .completed)
    }

    @Test func cookingTimerCommandsRoundTripWithStableIdentityAndRevision() throws {
        let timerID = UUID()
        let command = WatchCookingTimerCommand(
            id: UUID(),
            timerID: timerID,
            action: .pauseOrResume,
            baseRevision: Date(timeIntervalSince1970: 1_800_000_000),
            issuedAt: Date(timeIntervalSince1970: 1_800_000_010)
        )
        let message = try #require(WatchSyncPayload.message(for: command))
        #expect(WatchSyncPayload.command(in: message) == command)

        let acknowledgement = WatchCookingTimerCommandAcknowledgement(
            commandID: command.id,
            timerID: timerID,
            accepted: true,
            message: nil,
            revision: Date(timeIntervalSince1970: 1_800_000_020)
        )
        let acknowledgementMessage = try #require(
            WatchSyncPayload.message(for: acknowledgement)
        )
        #expect(
            WatchSyncPayload.acknowledgement(in: acknowledgementMessage) == acknowledgement
        )
    }

    @Test func timerSnapshotSurvivesInsideAnOlderPlanSnapshot() throws {
        let revision = Date(timeIntervalSince1970: 1_800_000_000)
        let timer = WatchCookingTimer(
            id: UUID(),
            dishName: "Dough",
            stepNumber: 1,
            stepText: "Proof",
            label: "Dough",
            duration: 3_600,
            endDate: revision.addingTimeInterval(3_600),
            pausedRemaining: nil
        )
        let snapshot = WatchPlanSnapshot(
            generatedAt: revision,
            cookingTimers: WatchCookingTimersSnapshot(
                sessionID: UUID(),
                revision: revision,
                timers: [timer]
            )
        )
        let message = try #require(WatchSyncPayload.message(for: snapshot))
        #expect(WatchSyncPayload.snapshot(in: message)?.cookingTimers?.timers == [timer])
        #expect(WatchSyncPayload.snapshot(in: message)?.cookingTimers?.revision == revision)
    }

    @Test func cookingSessionHandoffRoundTripsRecipeStateAndCheckoffs() throws {
        let revision = Date(timeIntervalSince1970: 1_800_000_100)
        let dishID = UUID()
        let ingredient = WatchCookingIngredient(
            id: UUID(),
            index: 0,
            name: "Onion",
            amount: "1",
            note: "chopped",
            isChecked: true
        )
        let dish = WatchCookingDish(
            id: dishID,
            name: "Pasta",
            targetServings: 2,
            currentStep: 1,
            steps: [
                WatchCookingStep(id: 0, text: "Boil water"),
                WatchCookingStep(id: 1, text: "Add the onion")
            ],
            ingredients: [ingredient]
        )
        let session = WatchCookingSessionSnapshot(
            sessionID: UUID(),
            revision: revision,
            selectedDishID: dishID,
            dishes: [dish],
            timers: []
        )
        let command = WatchCookingSessionCommand(
            sessionID: session.sessionID,
            action: .toggleIngredient(dishID: dishID, ingredientIndex: 0),
            baseRevision: revision,
            issuedAt: revision.addingTimeInterval(1)
        )
        let snapshot = WatchPlanSnapshot(cookingSession: session)
        let snapshotMessage = try #require(WatchSyncPayload.message(for: snapshot))
        let commandMessage = try #require(WatchSyncPayload.message(for: command))

        #expect(WatchSyncPayload.snapshot(in: snapshotMessage)?.cookingSession == session)
        #expect(WatchSyncPayload.sessionCommand(in: commandMessage) == command)
        #expect(session.selectedDish?.currentStepText == "Add the onion")
    }

    @Test func olderCookingHandoffCannotOverwriteRestoredState() {
        let sessionID = UUID()
        let dishID = UUID()
        func session(revision: TimeInterval, step: Int, checked: Bool) -> WatchCookingSessionSnapshot {
            WatchCookingSessionSnapshot(
                sessionID: sessionID,
                revision: Date(timeIntervalSince1970: revision),
                selectedDishID: dishID,
                dishes: [
                    WatchCookingDish(
                        id: dishID,
                        name: "Soup",
                        targetServings: 2,
                        currentStep: step,
                        steps: [WatchCookingStep(id: 0, text: "Stir")],
                        ingredients: [
                            WatchCookingIngredient(
                                id: UUID(),
                                index: 0,
                                name: "Salt",
                                amount: nil,
                                note: nil,
                                isChecked: checked
                            )
                        ]
                    )
                ],
                timers: []
            )
        }

        let restored = session(revision: 200, step: 0, checked: true)
        let delayed = session(revision: 100, step: 0, checked: false)
        let current = session(revision: 200, step: 0, checked: true)
        #expect(!WatchCookingSessionReconciler.shouldApply(incoming: delayed, over: current))
        #expect(WatchCookingSessionReconciler.shouldApply(incoming: restored, over: nil))
        #expect(WatchCookingSessionReconciler.shouldApply(
            incoming: session(revision: 300, step: 0, checked: true),
            over: current
        ))
    }

    @Test func cookingSessionCommandsKeepDistinctOrderingAndAcknowledgements() throws {
        let revision = Date(timeIntervalSince1970: 1_800_000_000)
        let sessionID = UUID()
        let first = WatchCookingSessionCommand(
            sessionID: sessionID,
            action: .setStep(dishID: UUID(), step: 0),
            baseRevision: revision,
            issuedAt: revision.addingTimeInterval(1)
        )
        let second = WatchCookingSessionCommand(
            sessionID: sessionID,
            action: .handoff,
            baseRevision: revision,
            issuedAt: revision.addingTimeInterval(2)
        )
        let acknowledgement = WatchCookingSessionCommandAcknowledgement(
            commandID: first.id,
            sessionID: sessionID,
            accepted: false,
            message: "Stale",
            revision: revision.addingTimeInterval(3)
        )
        let message = try #require(WatchSyncPayload.message(for: acknowledgement))

        #expect(first.id != second.id)
        #expect(WatchSyncPayload.sessionAcknowledgement(in: message) == acknowledgement)
        #expect(first.baseRevision < acknowledgement.revision!)
    }
}
