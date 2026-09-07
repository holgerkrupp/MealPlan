import Testing
import Foundation
@testable import MealPlan

/// Covers the create/update/remove logic a `CalendarEventWriting`
/// implementation must get right, exercised against `MockCalendarWriter`
/// the same way `EventKitCalendarWriter` would be driven in the app.
@MainActor
struct PublishedCalendarSyncTests {

    private let familyCalendar = MealCalendarInfo(id: "family", title: "Family", sourceTitle: "iCloud")

    private func payload(_ title: String, day: Int = 1, uuid: UUID = UUID()) -> MealPlanPublishPayload {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: day)) ?? .now
        return MealPlanPublishPayload(uuid: uuid, date: date, title: title, notes: nil)
    }

    @Test
    func firstSyncCreatesOneEventPerPayload() async throws {
        let writer = MockCalendarWriter(calendars: [familyCalendar])
        let payloads = [payload("Dinner: Chili"), payload("Dinner: Tacos", day: 2)]

        let map = try await writer.sync(payloads: payloads, calendarIdentifier: "family", knownEventIDs: [:])

        #expect(map.count == 2)
        let mirrored = await writer.mirroredPayloads(in: "family")
        #expect(Set(mirrored.map(\.title)) == ["Dinner: Chili", "Dinner: Tacos"])
    }

    @Test
    func republishingTheSameEntryReusesItsEvent() async throws {
        let writer = MockCalendarWriter(calendars: [familyCalendar])
        let id = UUID()
        let first = try await writer.sync(payloads: [payload("Dinner: Chili", uuid: id)], calendarIdentifier: "family", knownEventIDs: [:])

        let second = try await writer.sync(
            payloads: [payload("Dinner: Chili", uuid: id)], calendarIdentifier: "family", knownEventIDs: first
        )

        #expect(first[id] == second[id])
        let count = await writer.events.count
        #expect(count == 1)
    }

    @Test
    func editingAnEntryUpdatesItsMirroredEvent() async throws {
        let writer = MockCalendarWriter(calendars: [familyCalendar])
        let id = UUID()
        let map = try await writer.sync(payloads: [payload("Dinner: Chili", uuid: id)], calendarIdentifier: "family", knownEventIDs: [:])

        _ = try await writer.sync(payloads: [payload("Dinner: Vegetarian Chili", uuid: id)], calendarIdentifier: "family", knownEventIDs: map)

        let mirrored = await writer.mirroredPayloads(in: "family")
        #expect(mirrored.map(\.title) == ["Dinner: Vegetarian Chili"])
    }

    @Test
    func entryDroppingOutOfTheWindowRemovesItsEvent() async throws {
        let writer = MockCalendarWriter(calendars: [familyCalendar])
        let staysID = UUID()
        let leavesID = UUID()
        let map = try await writer.sync(
            payloads: [payload("Dinner: Chili", uuid: staysID), payload("Dinner: Tacos", day: 2, uuid: leavesID)],
            calendarIdentifier: "family",
            knownEventIDs: [:]
        )
        #expect(map.count == 2)

        let updated = try await writer.sync(
            payloads: [payload("Dinner: Chili", uuid: staysID)], calendarIdentifier: "family", knownEventIDs: map
        )

        #expect(updated.count == 1)
        #expect(updated[staysID] != nil)
        #expect(updated[leavesID] == nil)
        let mirrored = await writer.mirroredPayloads(in: "family")
        #expect(mirrored.map(\.title) == ["Dinner: Chili"])
    }

    @Test
    func stoppingRemovesEveryMirroredEvent() async throws {
        let writer = MockCalendarWriter(calendars: [familyCalendar])
        let map = try await writer.sync(
            payloads: [payload("Dinner: Chili"), payload("Dinner: Tacos", day: 2)],
            calendarIdentifier: "family",
            knownEventIDs: [:]
        )

        await writer.removeEvents(identifiers: Array(map.values))

        let count = await writer.events.count
        #expect(count == 0)
    }

    @Test
    func syncingWithoutAuthorizationThrows() async throws {
        let writer = MockCalendarWriter(status: .denied, calendars: [familyCalendar])
        do {
            _ = try await writer.sync(payloads: [payload("Dinner: Chili")], calendarIdentifier: "family", knownEventIDs: [:])
            Issue.record("Expected CalendarWriteError.notAuthorized")
        } catch let error as CalendarWriteError {
            #expect(error == .notAuthorized)
        }
    }

    @Test
    func syncingIntoAnUnknownCalendarThrows() async throws {
        let writer = MockCalendarWriter(calendars: [familyCalendar])
        do {
            _ = try await writer.sync(payloads: [payload("Dinner: Chili")], calendarIdentifier: "gone", knownEventIDs: [:])
            Issue.record("Expected CalendarWriteError.calendarNotFound")
        } catch let error as CalendarWriteError {
            #expect(error == .calendarNotFound)
        }
    }
}
