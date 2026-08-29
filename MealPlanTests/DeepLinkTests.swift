import Testing
import Foundation
@testable import MealPlan

struct DeepLinkTests {

    private func link(_ s: String) -> DeepLink? {
        URL(string: s).flatMap(DeepLink.init(url:))
    }

    @Test func today() {
        #expect(link("mealplan://today") == .today)
        #expect(link("mealplan://") == .today)
    }

    @Test func shoppingList() {
        #expect(link("mealplan://shopping") == .shoppingList)
        #expect(link("mealplan://einkaufsliste") == .shoppingList)
    }

    @Test func dateRoute() {
        if case .date(let d)? = link("mealplan://date/2026-08-28") {
            #expect(Calendar.current.component(.month, from: d) == 8)
            #expect(Calendar.current.component(.day, from: d) == 28)
        } else {
            Issue.record("expected .date")
        }
    }

    @Test func addDish() {
        if case .addDish(let url, let name)? = link("mealplan://add-dish?url=https%3A%2F%2Fx.de%2Fr&name=Suppe") {
            #expect(url?.absoluteString == "https://x.de/r")
            #expect(name == "Suppe")
        } else {
            Issue.record("expected .addDish")
        }
    }

    @Test func planRoute() {
        if case .plan(let dishName, _, let date, let slot)? = link("mealplan://plan?dish=Bolognese&date=2026-09-01&slot=dinner") {
            #expect(dishName == "Bolognese")
            #expect(slot == .dinner)
            #expect(date != nil)
        } else {
            Issue.record("expected .plan")
        }
    }

    @Test func rejectsOtherSchemes() {
        #expect(link("https://example.com") == nil)
        #expect(link("mealplan://bogus") == nil)
    }

    @Test func dateKeywords() {
        #expect(DeepLink.parseDate("today") == Date.now.startOfDay)
        #expect(DeepLink.parseDate("tomorrow") == Date.now.adding(days: 1).startOfDay)
        #expect(DeepLink.parseDate("01.09.2026") != nil)
    }
}
