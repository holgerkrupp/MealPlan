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
}
