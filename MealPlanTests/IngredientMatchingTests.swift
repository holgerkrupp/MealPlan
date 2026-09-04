import Testing
import Foundation
@testable import MealPlan

/// What counts as the same thing to buy — and, just as important, what
/// doesn't: over-merging silently drops an ingredient from the list, which is
/// worse than showing two rows.
@MainActor
struct IngredientMatchingTests {

    // MARK: - Keys

    @Test func footnotesAndPunctuationDropOut() {
        #expect(IngredientMatching.isSame("Salz", "Salz*"))
        #expect(IngredientMatching.isSame("Joghurt,", "Joghurt"))
        #expect(IngredientMatching.isSame("Salz (nach Geschmack)", "Salz"))
        #expect(IngredientMatching.isSame("Mehl [Type 405]", "Mehl"))
    }

    @Test func wordOrderAndFillerDontMatter() {
        #expect(IngredientMatching.isSame("Tomaten, gehackt", "gehackt Tomaten"))
        #expect(IngredientMatching.isSame("Bio Zitrone", "Zitrone"))
    }

    @Test func spellingSlipsAndPluralsMatch() {
        #expect(IngredientMatching.isSame("Joghurt", "Jogurt"))
        #expect(IngredientMatching.isSame("Zwiebel", "Zwiebeln"))
        #expect(IngredientMatching.isSame("Kartoffeln", "Kartoffel"))
        #expect(IngredientMatching.isSame("egg", "eggs"))
    }

    @Test func differentIngredientsStayApart() {
        // One letter apart, and four letters long: far too short to forgive.
        #expect(!IngredientMatching.isSame("Salz", "Malz"))
        #expect(!IngredientMatching.isSame("Reis", "Eis"))
        // A qualifier that changes what you put in the trolley.
        #expect(!IngredientMatching.isSame("Gehackte Tomaten", "Tomaten"))
        #expect(!IngredientMatching.isSame("Rote Zwiebel", "Zwiebel"))
        #expect(!IngredientMatching.isSame("Mehl", "Milch"))
    }

    // MARK: - Compounds

    @Test func compoundsSplitIntoTheirParts() {
        #expect(IngredientMatching.components(of: "Salz und Pfeffer") == ["Salz", "Pfeffer"])
        #expect(IngredientMatching.components(of: "Salz & Pfeffer") == ["Salz", "Pfeffer"])
        #expect(IngredientMatching.components(of: "Salz und schwarzer Pfeffer")
                == ["Salz", "schwarzer Pfeffer"])
    }

    @Test func onlyTimidSplitsAreMade() {
        #expect(IngredientMatching.components(of: "Joghurt") == ["Joghurt"])
        // Too many words on one side to tell where the split belongs.
        #expect(IngredientMatching.components(of: "Öl und Essig für das Dressing")
                == ["Öl und Essig für das Dressing"])
        // An amount can't be split along with the name.
        #expect(IngredientMatching.components(of: "2 Dosen Tomaten und Bohnen")
                == ["2 Dosen Tomaten und Bohnen"])
    }

    // MARK: - Naming the merged row

    @Test func theCleanestSpellingNamesTheRow() {
        #expect(IngredientMatching.preferredName("Salz*", "Salz") == "Salz")
        #expect(IngredientMatching.preferredName("Joghurt", "Joghurt (griechisch)") == "Joghurt")
    }

    // MARK: - Catalogue lookup

    @Test func exactMatchesWinOverNearOnes() {
        let plural = Ingredient(name: "Zwiebeln")
        let exact = Ingredient(name: "Zwiebel")
        #expect(IngredientMatching.match("Zwiebel", in: [plural, exact]) === exact)
        #expect(IngredientMatching.match("Zwiebel", in: [plural]) === plural)
        #expect(IngredientMatching.match("Lauch", in: [plural, exact]) == nil)
    }
}
