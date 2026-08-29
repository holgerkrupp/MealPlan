import Testing
@testable import MealPlan

struct ScannedRecipeParserTests {
    @Test func parsesGermanHeadings() {
        let draft = ScannedRecipeParser.parse("""
        Kartoffelsuppe
        Zutaten
        500 g Kartoffeln
        1 Zwiebel
        Zubereitung
        Alles schneiden.
        20 min kochen.
        """)
        #expect(draft.name == "Kartoffelsuppe")
        #expect(draft.ingredientLines == ["500 g Kartoffeln", "1 Zwiebel"])
        #expect(draft.instructions == "Alles schneiden.\n20 min kochen.")
    }
}
