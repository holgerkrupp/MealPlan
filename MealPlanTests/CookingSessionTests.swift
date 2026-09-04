import Foundation
import Testing
@testable import MealPlan

struct CookingSessionTests {
    @Test func keepsProgressIndependentForEachDish() {
        let pasta = UUID()
        let sauce = UUID()
        var session = CookingSessionState(dishID: pasta, dishName: "Pasta", servings: 2)

        session.setCurrentStep(2, for: pasta, stepCount: 4)
        session.toggleIngredient(0, for: pasta)
        session.addDish(id: sauce, name: "Sauce", servings: 4)
        session.setCurrentStep(1, for: sauce, stepCount: 3)

        #expect(session.dishes.first { $0.id == pasta }?.currentStep == 2)
        #expect(session.dishes.first { $0.id == pasta }?.checkedIngredientIndexes == [0])
        #expect(session.dishes.first { $0.id == pasta }?.targetServings == 2)
        #expect(session.dishes.first { $0.id == sauce }?.currentStep == 1)
        #expect(session.dishes.first { $0.id == sauce }?.checkedIngredientIndexes.isEmpty == true)
        #expect(session.dishes.first { $0.id == sauce }?.targetServings == 4)
    }

    @Test func pausedTimerResumesFromStoredRemainingTime() {
        let dishID = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        var session = CookingSessionState(dishID: dishID, dishName: "Soup", servings: 2)
        let timer = CookingTimerState(
            dishID: dishID,
            dishName: "Soup",
            stepNumber: 2,
            stepText: "Simmer",
            label: "10 minutes",
            duration: 600,
            endDate: start.addingTimeInterval(600)
        )
        session.addTimer(timer)

        let paused = session.pauseOrResumeTimer(timer.id, at: start.addingTimeInterval(125))
        #expect(paused?.pausedRemaining == 475)
        let resumed = session.pauseOrResumeTimer(timer.id, at: start.addingTimeInterval(200))
        #expect(resumed?.pausedRemaining == nil)
        #expect(resumed?.endDate == start.addingTimeInterval(675))
    }

    @Test func interruptedSessionRoundTripsWithoutLosingState() throws {
        let dishID = UUID()
        var session = CookingSessionState(dishID: dishID, dishName: "Curry", servings: 3)
        session.toggleIngredient(1, for: dishID)
        session.setCurrentStep(3, for: dishID, stepCount: 5)

        let data = try JSONEncoder().encode(session)
        let restored = try JSONDecoder().decode(CookingSessionState.self, from: data)

        #expect(restored == session)
    }
}
