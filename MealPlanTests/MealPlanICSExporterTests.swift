import Testing
import Foundation
@testable import MealPlan

/// Covers `MealPlanICSExporter` on transient, unsaved model objects — the
/// same approach `MealPlanBackupTests` uses, since standing up a real
/// `ModelContainer` in the test host isn't reliable here.
@MainActor
struct MealPlanICSExporterTests {

    private func dinner() -> MealType {
        MealType(key: "dinner", name: "Dinner", sortOrder: 0)
    }

    private func mealsByKey(_ types: MealType...) -> [String: MealType] {
        Dictionary(uniqueKeysWithValues: types.map { ($0.key, $0) })
    }

    private func entry(
        day: Int = 1,
        mealKey: String = "dinner",
        dishName: String = "Spaghetti Bolognese",
        note: String? = nil,
        uuid: UUID = UUID()
    ) -> MealPlanEntry {
        let dish = Dish(name: dishName)
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: day)) ?? .now
        let entry = MealPlanEntry(date: date, mealKey: mealKey, dish: dish)
        entry.uuid = uuid
        entry.note = note
        return entry
    }

    // MARK: - Structure

    @Test
    func wrapsEventsInAValidCalendar() {
        let ics = MealPlanICSExporter.makeICS(
            calendarName: "Krupp Meal Plan",
            entries: [entry()],
            mealTypesByKey: mealsByKey(dinner())
        )
        #expect(ics.hasPrefix("BEGIN:VCALENDAR\r\n"))
        #expect(ics.hasSuffix("END:VCALENDAR\r\n"))
        #expect(ics.contains("VERSION:2.0"))
        #expect(ics.contains("METHOD:PUBLISH"))
        #expect(ics.contains("X-WR-CALNAME:Krupp Meal Plan"))
        #expect(ics.contains("BEGIN:VEVENT"))
        #expect(ics.contains("END:VEVENT"))
    }

    @Test
    func oneEventPerEntry() {
        let ics = MealPlanICSExporter.makeICS(
            calendarName: "Plan",
            entries: [entry(day: 1), entry(day: 2), entry(day: 3)],
            mealTypesByKey: mealsByKey(dinner())
        )
        #expect(ics.components(separatedBy: "BEGIN:VEVENT").count - 1 == 3)
    }

    // MARK: - Content

    @Test
    func summaryNamesTheMealAndTheDish() {
        let ics = MealPlanICSExporter.makeICS(
            calendarName: "Plan",
            entries: [entry(dishName: "Chili")],
            mealTypesByKey: mealsByKey(dinner())
        )
        #expect(ics.contains("SUMMARY:Dinner: Chili"))
    }

    @Test
    func extraIsNamedByTheDishAlone() {
        let ics = MealPlanICSExporter.makeICS(
            calendarName: "Plan",
            entries: [entry(mealKey: MealType.extraKey, dishName: "Birthday cake")],
            mealTypesByKey: mealsByKey(dinner())
        )
        #expect(ics.contains("SUMMARY:Birthday cake"))
        #expect(!ics.contains("Extra: Birthday cake"))
    }

    @Test
    func noteBecomesTheDescription() {
        let ics = MealPlanICSExporter.makeICS(
            calendarName: "Plan",
            entries: [entry(note: "Defrost the mince the night before")],
            mealTypesByKey: mealsByKey(dinner())
        )
        #expect(ics.contains("DESCRIPTION:Defrost the mince the night before"))
    }

    @Test
    func eventsAreAllDayAndUnbusy() {
        let ics = MealPlanICSExporter.makeICS(
            calendarName: "Plan",
            entries: [entry(day: 15)],
            mealTypesByKey: mealsByKey(dinner())
        )
        #expect(ics.contains("DTSTART;VALUE=DATE:20260915"))
        #expect(ics.contains("DTEND;VALUE=DATE:20260916"))
        #expect(ics.contains("TRANSP:TRANSPARENT"))
    }

    // MARK: - Stability across republishing

    @Test
    func uidIsStableAcrossRepublishing() {
        let id = UUID()
        let first = MealPlanICSExporter.makeICS(
            calendarName: "Plan", entries: [entry(uuid: id)], mealTypesByKey: mealsByKey(dinner())
        )
        let second = MealPlanICSExporter.makeICS(
            calendarName: "Plan", entries: [entry(uuid: id)], mealTypesByKey: mealsByKey(dinner())
        )
        let uidLine = "UID:\(id.uuidString)@mealplan.app"
        #expect(first.contains(uidLine))
        #expect(second.contains(uidLine))
    }

    // MARK: - Escaping and folding

    @Test
    func commasSemicolonsAndBackslashesAreEscaped() {
        let ics = MealPlanICSExporter.makeICS(
            calendarName: "Plan",
            entries: [entry(dishName: "Mac & Cheese; Family, Style \\ v2")],
            mealTypesByKey: mealsByKey(dinner())
        )
        #expect(ics.contains("Mac & Cheese\\; Family\\, Style \\\\ v2"))
    }

    @Test
    func newlinesInNotesAreEscapedNotLiteral() {
        let ics = MealPlanICSExporter.makeICS(
            calendarName: "Plan",
            entries: [entry(note: "Step one\nStep two")],
            mealTypesByKey: mealsByKey(dinner())
        )
        #expect(ics.contains("DESCRIPTION:Step one\\nStep two"))
        // The escaped "\n" must not have become a real line break in the file.
        #expect(!ics.contains("DESCRIPTION:Step one\r\n"))
    }

    @Test
    func longLinesAreFoldedAt75OctetsWithASpaceContinuation() {
        let longName = String(repeating: "Grandma's Sunday Roast Chicken with Potatoes ", count: 3)
        let ics = MealPlanICSExporter.makeICS(
            calendarName: "Plan",
            entries: [entry(dishName: longName)],
            mealTypesByKey: mealsByKey(dinner())
        )
        let rawLines = ics.components(separatedBy: "\r\n")
        for line in rawLines {
            #expect(Array(line.utf8).count <= 75)
        }
        // A folded continuation line starts with a single space.
        #expect(rawLines.contains { $0.hasPrefix(" ") })
    }

    @Test
    func entriesAreSortedByDateThenSortIndex() {
        let later = entry(day: 5, dishName: "Later")
        let earlier = entry(day: 1, dishName: "Earlier")
        let ics = MealPlanICSExporter.makeICS(
            calendarName: "Plan",
            entries: [later, earlier],
            mealTypesByKey: mealsByKey(dinner())
        )
        let earlierRange = ics.range(of: "Earlier")
        let laterRange = ics.range(of: "Later")
        #expect(earlierRange != nil && laterRange != nil)
        if let earlierRange, let laterRange {
            #expect(earlierRange.lowerBound < laterRange.lowerBound)
        }
    }
}
