import Foundation
import Testing
@testable import MealPlan

struct CookingTimerPresentationTests {
    @Test func timerStylesHaveStablePersistedValuesAndNativeDefault() {
        #expect(CookingTimerStylePreferences.defaultStyle == .native)
        #expect(CookingTimerStylePreferences.style(for: "native") == .native)
        #expect(CookingTimerStylePreferences.style(for: "segmented") == .segmented)
        #expect(CookingTimerStylePreferences.style(for: "circular") == .circular)
        #expect(CookingTimerStylePreferences.style(for: "unknown") == .native)
    }

    @Test func clockFormattingKeepsHoursAndLeadingZeroesGlanceable() {
        #expect(CookingTimerFormatting.clockText(65) == "01:05")
        #expect(CookingTimerFormatting.clockText(3_665) == "1:01:05")
        #expect(CookingTimerFormatting.clockText(-1) == "00:00")
    }

    @Test func timerStatusUsesCanonicalPausedAndCompletionState() {
        let start = Date(timeIntervalSince1970: 1_000)
        let timer = CookingTimerState(
            dishID: UUID(),
            dishName: "Soup",
            stepNumber: 1,
            stepText: "Simmer",
            label: "Simmer",
            duration: 600,
            endDate: start.addingTimeInterval(600),
            pausedRemaining: nil
        )
        #expect(CookingTimerFormatting.status(for: timer, at: start) == "Running")

        var paused = timer
        paused.pausedRemaining = 300
        #expect(CookingTimerFormatting.status(for: paused, at: start) == "Paused")
        #expect(CookingTimerFormatting.status(for: timer, at: start.addingTimeInterval(600)) == "Completed")
    }
}
