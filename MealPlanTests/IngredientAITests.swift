import Foundation
import SwiftData
import Testing
@testable import MealPlan

@MainActor
struct IngredientAITests {
    private struct StubClassifier: IngredientClassifier {
        let result: IngredientAIResult?

        func classify(_ request: IngredientMatchRequest) async -> IngredientAIResult? {
            result
        }
    }

    @Test func exactDeterministicMatchDoesNotNeedAI() async {
        let candidate = IngredientMatchCandidate(name: "Joghurt", category: .dairy)
        let result = await IngredientMatchResolver.resolve(
            rawName: "Joghurt",
            candidates: [candidate],
            classifier: StubClassifier(result: IngredientAIResult(sameIngredient: false, confidence: .low))
        )

        #expect(result == .deterministic(candidate))
    }

    @Test func unresolvedPairGetsAStructuredSuggestion() async {
        let candidate = IngredientMatchCandidate(name: "Joghurt", category: .dairy)
        let expected = IngredientAIResult(
            sameIngredient: true,
            confidence: .high,
            rationale: "The spelling differs only by a common German variant."
        )
        let result = await IngredientMatchResolver.resolve(
            rawName: "Greek yogurt",
            candidates: [candidate],
            requestContext: .init(localeIdentifier: "en_US", note: "for the sauce", dimension: .mass),
            classifier: StubClassifier(result: expected)
        )

        guard case let .aiSuggestion(suggestion) = result else {
            Issue.record("Expected an AI suggestion")
            return
        }
        #expect(suggestion.candidate == candidate)
        #expect(suggestion.result == expected)
        #expect(suggestion.request.localeIdentifier == "en_US")
        #expect(suggestion.request.note == "for the sauce")
    }

    @Test func keepSeparateRuleWinsOverDeterministicMatchingAndAI() async {
        let candidate = IngredientMatchCandidate(name: "Zwiebel", category: .produce)
        let rule = IngredientMatchRule(leftName: "rote Zwiebel", rightName: "Zwiebel", kind: .keepSeparate)
        let result = await IngredientMatchResolver.resolve(
            rawName: "rote Zwiebel",
            candidates: [candidate],
            rules: [rule],
            classifier: StubClassifier(result: IngredientAIResult(sameIngredient: true, confidence: .high))
        )

        #expect(result == .keepSeparate)
    }

    @Test func learningPersistsAHouseholdDecision() throws {
        let container = SharedStore.make(cloudKit: false, inMemory: true)
        let context = container.mainContext
        let household = Household(name: "Test")
        context.insert(household)

        let rule = IngredientMatchLearning.learnKeepSeparate(
            "gehackte Tomaten", and: "Tomaten", in: household, context: context
        )

        let stored = try context.fetch(FetchDescriptor<IngredientMatchRule>())
        #expect(stored.count == 1)
        #expect(stored.first?.uuid == rule.uuid)
        #expect(stored.first?.kind == .keepSeparate)
        #expect(stored.first?.applies(
            to: IngredientMatching.key(for: "gehackte Tomaten"),
            and: IngredientMatching.key(for: "Tomaten")
        ) == true)
    }
}
