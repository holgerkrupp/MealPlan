import Testing
import Foundation
@testable import MealPlan

/// `.sheet(item:)` keeps a sheet up only while its item's `id` stays the same.
/// The calendar builds its sheet items inside `Binding(get:)`, so the id has to
/// come from the value — not from the moment the wrapper was made.
struct SheetIdentityTests {

    @Test func theSameDateIsTheSameSheetEveryTimeItIsBuilt() {
        let week = Date(timeIntervalSince1970: 1_757_203_200)
        // Two reads of the same binding, as two redraws would make them.
        #expect(IdentifiableDate(date: week).id == IdentifiableDate(date: week).id)
    }

    @Test func aDifferentDateIsADifferentSheet() {
        let week = Date(timeIntervalSince1970: 1_757_203_200)
        #expect(IdentifiableDate(date: week).id != IdentifiableDate(date: week.adding(weeks: 1)).id)
    }
}
