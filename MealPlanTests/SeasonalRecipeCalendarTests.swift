import Foundation
import Testing
@testable import MealPlan

struct SeasonalRecipeCalendarTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func context(_ region: String?, _ language: String? = "en") -> RecipeDiscoveryMarketContext {
        RecipeDiscoveryMarketContext(regionCode: region, languageCode: language, unitSystem: .metric)
    }

    private func activeIDs(_ date: Date, _ context: RecipeDiscoveryMarketContext) -> [String] {
        SeasonalRecipeCalendar.activeMoments(on: date, context: context, calendar: calendar)
            .map(\.id)
    }

    @Test func halloweenPlanningWindowUsesMarketAndLocalizedKeywords() {
        let german = context("DE", "de")
        let unitedStates = context("US", "en")
        let germanMoments = SeasonalRecipeCalendar.activeMoments(on: date(2026, 10, 15), context: german, calendar: calendar)
        let usMoments = SeasonalRecipeCalendar.activeMoments(on: date(2026, 10, 15), context: unitedStates, calendar: calendar)
        let germanHalloween = germanMoments.first { $0.id == "halloween" }
        let usHalloween = usMoments.first { $0.id == "halloween" }

        #expect(germanHalloween != nil)
        #expect(usHalloween != nil)
        #expect(germanHalloween?.keywords(for: "de-DE").contains("kürbis") == true)
        #expect(usHalloween?.keywords(for: "en-US").contains("pumpkin") == true)
        #expect(germanHalloween?.keywords(for: "de") != usHalloween?.keywords(for: "en"))
        #expect(!activeIDs(date(2026, 8, 1), german).contains("halloween"))
    }

    @Test func thanksgivingIsLimitedToItsMarket() {
        #expect(activeIDs(date(2026, 11, 26), context("US")).contains("thanksgiving-us"))
        #expect(activeIDs(date(2026, 10, 12), context("CA")).contains("thanksgiving-canada"))
        #expect(!activeIDs(date(2026, 11, 26), context("DE", "de")).contains { $0.hasPrefix("thanksgiving-") })
    }

    @Test func nthWeekdayThanksgivingDatesAreCorrectAcrossYears() {
        let us = context("US")
        for (year, day) in [(2024, 28), (2025, 27), (2026, 26)] {
            #expect(activeIDs(date(year, 11, day), us).contains("thanksgiving-us"))
        }

        let canada = context("CA")
        for (year, day) in [(2024, 14), (2025, 13), (2026, 12)] {
            #expect(activeIDs(date(year, 10, day), canada).contains("thanksgiving-canada"))
        }
    }

    @Test func easterRelativeMomentsFollowGregorianEaster() {
        let europe = context("DE", "de")
        for (year, month, day) in [(2024, 3, 31), (2025, 4, 20), (2026, 4, 5)] {
            #expect(activeIDs(date(year, month, day), europe).contains("spring-easter-cooking"))
        }
    }

    @Test func seasonWindowsRespectHemisphereAndYearBoundary() {
        let north = context("DE", "de")
        let south = context("AU", "en")

        #expect(activeIDs(date(2026, 1, 15), north).contains("winter-comfort-food"))
        #expect(activeIDs(date(2026, 7, 15), south).contains("winter-comfort-food"))
        #expect(activeIDs(date(2026, 10, 15), north).contains("autumn-harvest"))
        #expect(activeIDs(date(2026, 4, 15), south).contains("autumn-harvest"))
        #expect(activeIDs(date(2027, 1, 3), north).contains("winter-holiday-baking"))
    }

    @Test func explicitDateTableFailsClosedOutsideKnownYears() {
        let context = context("CN", "en")
        #expect(activeIDs(date(2030, 2, 3), context).contains("lunar-new-year-cooking"))
        #expect(!activeIDs(date(2031, 1, 23), context).contains("lunar-new-year-cooking"))
    }

    @Test func unknownRegionOnlyReturnsGlobalMoments() {
        let moments = SeasonalRecipeCalendar.activeMoments(
            on: date(2026, 10, 15),
            context: context(nil, "de"),
            calendar: calendar
        )

        #expect(moments.contains { $0.id == "autumn-harvest" })
        #expect(moments.allSatisfy {
            if case .global = $0.applicability { return true }
            return false
        })
    }

    @Test func resultsAndTransitionsAreDeterministicWithInjectedTimeZone() {
        var berlinCalendar = calendar
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        berlinCalendar.timeZone = berlin
        let context = context("DE", "de")
        let instant = date(2026, 10, 15).addingTimeInterval(12 * 60 * 60)
        let first = SeasonalRecipeCalendar.activeMoments(
            on: instant, context: context, calendar: calendar, timeZone: berlin
        )
        let second = SeasonalRecipeCalendar.activeMoments(
            on: instant, context: context, calendar: calendar, timeZone: berlin
        )

        #expect(first.map(\.id) == second.map(\.id))
        #expect(SeasonalRecipeCalendar.nextTransition(
            after: instant, context: context, calendar: calendar, timeZone: berlin
        ) == SeasonalRecipeCalendar.nextTransition(
            after: instant, context: context, calendar: calendar, timeZone: berlin
        ))
        #expect(berlinCalendar.timeZone.identifier == berlin.identifier)
    }
}
