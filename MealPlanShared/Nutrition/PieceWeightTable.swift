import Foundation

/// Roughly what one of something weighs.
///
/// Recipes count things far more often than they weigh them — "2 Zwiebeln",
/// "1 Zehe Knoblauch", "1 Dose Tomaten" — and `DishIngredient` stores those
/// faithfully as `.count`. Without this table every counted line would
/// contribute nothing to a nutrition estimate, which is worse than useless:
/// it would silently make dishes look lighter than they are, and the dishes it
/// understated most would be the ones built on onions, eggs and tins.
///
/// The unit matters as much as the name. A clove of garlic is 3 g and a whole
/// bulb is 60; a slice of bread is 40 g and a loaf is not. So a lookup takes
/// both, prefers a rule that names the unit, and falls back to a plain
/// per-piece weight for the ingredient — and only then to a generic weight for
/// the unit itself.
///
/// Every value here is an average of something that varies by a factor of two
/// in a real kitchen, so anything that goes through this table is reported as
/// `NutritionConfidence.converted`. Sibling of `DensityTable`, which does the
/// same job for volumes.
enum PieceWeightTable {

    struct Rule: Sendable {
        /// Ingredient spellings this rule applies to. Empty means "any
        /// ingredient", which is only ever used together with a unit.
        var names: [String]
        /// The unit label as `GermanUnitParser` hands it back ("Zehe",
        /// "Scheibe", "Dose"). `nil` matches any unit, including none.
        var unit: String?
        var grams: Double

        init(_ names: [String], unit: String? = nil, grams: Double) {
            self.names = names
            self.unit = unit
            self.grams = grams
        }
    }

    /// Unit-specific rules first: they are consulted before the plain
    /// per-ingredient weights below.
    static let unitRules: [Rule] = [
        Rule(["Knoblauch", "garlic"], unit: "Zehe", grams: 3),
        Rule([], unit: "Zehe", grams: 3),

        Rule(["Brot", "Vollkornbrot", "bread"], unit: "Scheibe", grams: 40),
        Rule(["Toast", "Toastbrot"], unit: "Scheibe", grams: 25),
        Rule(["Käse", "Kaese", "Gouda", "cheese"], unit: "Scheibe", grams: 25),
        Rule(["Schinken", "Salami", "ham"], unit: "Scheibe", grams: 15),
        Rule([], unit: "Scheibe", grams: 30),

        Rule(["Tomaten", "tomatoes"], unit: "Dose", grams: 400),
        Rule(["Kichererbsen", "Kidneybohnen", "Mais", "Bohnen", "chickpeas", "beans"], unit: "Dose", grams: 250),
        Rule(["Thunfisch", "tuna"], unit: "Dose", grams: 150),
        Rule([], unit: "Dose", grams: 400),

        Rule(["Petersilie", "Basilikum", "Schnittlauch", "Dill", "Koriander", "parsley", "basil"], unit: "Bund", grams: 25),
        Rule(["Frühlingszwiebel", "Lauchzwiebel", "spring onion"], unit: "Bund", grams: 100),
        Rule(["Suppengrün", "Suppengruen"], unit: "Bund", grams: 300),
        Rule([], unit: "Bund", grams: 40),

        Rule(["Knoblauch", "garlic"], unit: "Knolle", grams: 50),
        Rule(["Sellerie", "celeriac"], unit: "Knolle", grams: 600),
        Rule([], unit: "Knolle", grams: 200),

        Rule(["Salat", "Kopfsalat", "lettuce"], unit: "Kopf", grams: 300),
        Rule(["Blumenkohl", "cauliflower"], unit: "Kopf", grams: 700),
        Rule(["Brokkoli", "broccoli"], unit: "Kopf", grams: 400),
        Rule(["Weißkohl", "Weisskohl", "Rotkohl", "cabbage"], unit: "Kopf", grams: 1000),
        Rule([], unit: "Kopf", grams: 400),

        Rule([], unit: "Handvoll", grams: 30),
        Rule([], unit: "Packung", grams: 250),
        Rule([], unit: "Flasche", grams: 700),
    ]

    /// What one of the thing weighs when nothing but its name is known.
    static let pieceWeights: [Rule] = [
        // Dairy and eggs
        Rule(["Ei", "Eier", "egg", "eggs"], grams: 58),
        Rule(["Eigelb", "egg yolk"], grams: 18),
        Rule(["Eiweiß", "Eiweiss", "egg white"], grams: 33),

        // Vegetables
        Rule(["Zwiebel", "Zwiebeln", "onion", "onions"], grams: 110),
        Rule(["Schalotte", "shallot"], grams: 35),
        Rule(["Frühlingszwiebel", "Lauchzwiebel", "spring onion", "scallion"], grams: 25),
        Rule(["Knoblauchzehe", "garlic clove"], grams: 3),
        Rule(["Knoblauch", "garlic"], grams: 3),
        Rule(["Tomate", "Tomaten", "tomato", "tomatoes"], grams: 120),
        Rule(["Cocktailtomate", "Kirschtomate", "cherry tomato"], grams: 15),
        Rule(["Paprika", "bell pepper"], grams: 150),
        Rule(["Karotte", "Karotten", "Möhre", "Möhren", "carrot", "carrots"], grams: 70),
        Rule(["Kartoffel", "Kartoffeln", "potato", "potatoes"], grams: 150),
        Rule(["Süßkartoffel", "Suesskartoffel", "sweet potato"], grams: 200),
        Rule(["Zucchini", "courgette"], grams: 200),
        Rule(["Aubergine", "eggplant"], grams: 250),
        Rule(["Gurke", "cucumber"], grams: 400),
        Rule(["Lauch", "Porree", "leek"], grams: 200),
        Rule(["Sellerie", "celery"], grams: 60),
        Rule(["Kohlrabi"], grams: 250),
        Rule(["Fenchel", "fennel"], grams: 250),
        Rule(["Rote Bete", "Rote Beete", "beetroot"], grams: 150),
        Rule(["Champignon", "Champignons", "mushroom", "mushrooms"], grams: 20),
        Rule(["Chili", "Chilischote", "Peperoni", "chilli"], grams: 15),
        Rule(["Avocado"], grams: 170),
        Rule(["Blumenkohl", "cauliflower"], grams: 700),
        Rule(["Brokkoli", "broccoli"], grams: 400),
        Rule(["Kürbis", "Kuerbis", "pumpkin"], grams: 1000),

        // Fruit
        Rule(["Apfel", "Äpfel", "apple", "apples"], grams: 180),
        Rule(["Banane", "Bananen", "banana"], grams: 120),
        Rule(["Birne", "pear"], grams: 170),
        Rule(["Orange", "orange"], grams: 180),
        Rule(["Zitrone", "lemon"], grams: 100),
        Rule(["Limette", "lime"], grams: 65),
        Rule(["Mango"], grams: 200),
        Rule(["Pfirsich", "peach"], grams: 150),
        Rule(["Kiwi"], grams: 75),
        Rule(["Erdbeere", "Erdbeeren", "strawberry"], grams: 12),
        Rule(["Datteln", "dates"], grams: 8),

        // Bakery and prepared
        Rule(["Brötchen", "Broetchen", "Semmel", "bread roll"], grams: 50),
        Rule(["Scheibe Brot", "Toast", "Toastbrot"], grams: 25),
        Rule(["Tortilla", "Wrap"], grams: 60),

        // Meat and fish, sold by the piece
        Rule(["Hähnchenbrust", "Haehnchenbrust", "chicken breast"], grams: 150),
        Rule(["Hähnchenschenkel", "chicken thigh"], grams: 130),
        Rule(["Bratwurst", "Wurst", "sausage"], grams: 100),
        Rule(["Lachsfilet", "salmon fillet"], grams: 150),
    ]

    /// Grams for one piece of `ingredientName` measured in `unitLabel`, or
    /// `nil` when we have no idea what one of them weighs.
    ///
    /// `unitLabel` is `DishIngredient.displayUnit` — "Zehe", "Scheibe",
    /// "Stück", or nil for a bare "2 Zwiebeln".
    static func grams(forIngredient ingredientName: String?, unitLabel: String? = nil) -> Double? {
        let name = Ingredient.normalize(ingredientName ?? "")
        let unit = Ingredient.normalize(unitLabel ?? "")

        // "Stück" and "×" say nothing beyond "counted", so they must not beat
        // the ingredient's own weight.
        let genericUnits: Set<String> = ["stuck", "stück", "x", "×", ""]
        if !genericUnits.contains(unit) {
            // Rules naming both the unit and the ingredient, then the unit's
            // own fallback.
            for rule in normalizedUnitRules where rule.unit == unit && !rule.names.isEmpty {
                if matches(rule.names, name) { return rule.grams }
            }
            for rule in normalizedUnitRules where rule.unit == unit && rule.names.isEmpty {
                return rule.grams
            }
        }

        guard !name.isEmpty else { return nil }
        // Longest name first: "knoblauchzehe" must win over "knoblauch".
        for rule in normalizedPieceWeights where matches(rule.names, name) {
            return rule.grams
        }
        return nil
    }

    private struct NormalizedRule {
        var names: [String]
        var unit: String
        var grams: Double
    }

    private static let normalizedUnitRules: [NormalizedRule] = unitRules.map {
        NormalizedRule(
            names: $0.names.map(Ingredient.normalize),
            unit: Ingredient.normalize($0.unit ?? ""),
            grams: $0.grams
        )
    }

    private static let normalizedPieceWeights: [NormalizedRule] = pieceWeights
        .map {
            NormalizedRule(
                names: $0.names.map(Ingredient.normalize),
                unit: "",
                grams: $0.grams
            )
        }
        .sorted {
            ($0.names.map(\.count).max() ?? 0) > ($1.names.map(\.count).max() ?? 0)
        }

    /// Same short-name caution as `NutritionTable`: an alias under four
    /// characters ("Ei") has to be a whole word, or "Reis" becomes eggs.
    private static func matches(_ names: [String], _ normalizedName: String) -> Bool {
        guard !normalizedName.isEmpty else { return false }
        let words = Set(
            normalizedName
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        )
        for key in names {
            guard !key.isEmpty else { continue }
            if normalizedName == key { return true }
            if key.contains(" ") {
                if normalizedName.contains(key) { return true }
            } else if key.count >= 4 {
                if normalizedName.contains(key) { return true }
            } else if words.contains(key) {
                return true
            }
        }
        return false
    }
}
