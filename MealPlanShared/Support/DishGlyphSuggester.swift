import Foundation

/// Picks a fitting placeholder for a dish from its name (and, failing that,
/// its ingredients and meal-type tags), so a new dish never starts out as a
/// generic fork-and-knife.
///
/// Matching is keyword-based over a folded, punctuation-free form of the text,
/// in German and English because dishes get typed in either. Rules are tried
/// in order and the first hit wins, so "Kürbissuppe" lands on the soup rule
/// rather than the pumpkin one — order encodes priority.
///
/// Keywords of four characters or more may match inside a word, because German
/// glues compounds together ("Kürbissuppe", "Nudelauflauf"). Shorter ones must
/// be whole words, or "Fleisch" would read as ice cream ("Eis").
enum DishGlyphSuggester {

    /// One keyword → glyph rule.
    struct Rule {
        let keywords: [String]
        let glyph: DishGlyph
    }

    // MARK: - Rules

    /// Order is priority: whole-dish rules first, then main components, then
    /// bare ingredients. "Kartoffelsuppe" is a soup before it is a potato.
    static let rules: [Rule] = [
        // Whole dishes
        Rule(keywords: ["spaghetti", "pasta", "nudel", "noodle", "bolognese", "carbonara",
                        "lasagne", "lasagna", "penne", "tagliatelle", "linguine", "makkaroni",
                        "maccheroni", "spaetzle", "spatzle"], glyph: .emoji("🍝")),
        Rule(keywords: ["pizza", "flammkuchen"], glyph: .emoji("🍕")),
        Rule(keywords: ["burger", "hamburger", "cheeseburger", "frikadelle", "bulette"], glyph: .emoji("🍔")),
        Rule(keywords: ["taco", "burrito", "quesadilla", "fajita", "enchilada"], glyph: .emoji("🌮")),
        Rule(keywords: ["wrap", "duerum", "durum", "doener", "doner", "kebab", "gyros"], glyph: .emoji("🥙")),
        Rule(keywords: ["sandwich", "toast", "panini", "stulle", "baguette"], glyph: .emoji("🥪")),
        Rule(keywords: ["hotdog", "wuerstchen", "wurstchen", "bratwurst", "currywurst", "wurst"], glyph: .emoji("🌭")),
        Rule(keywords: ["salat", "salad", "bowl", "caesar"], glyph: .emoji("🥗")),
        Rule(keywords: ["suppe", "soup", "bruehe", "bruhe", "broth", "eintopf", "stew",
                        "ramen", "pho", "chowder", "gulasch", "goulash", "chili"], glyph: .emoji("🍲")),
        Rule(keywords: ["curry", "korma", "masala", "dal", "tikka"], glyph: .emoji("🍛")),
        Rule(keywords: ["sushi", "maki", "nigiri"], glyph: .emoji("🍣")),
        Rule(keywords: ["risotto", "paella", "pilaw", "pilaf"], glyph: .emoji("🍚")),
        Rule(keywords: ["auflauf", "gratin", "casserole", "moussaka", "quiche", "tarte"], glyph: .emoji("🥘")),
        Rule(keywords: ["pfannkuchen", "pancake", "crepe", "eierkuchen", "waffel", "waffle"], glyph: .emoji("🥞")),
        Rule(keywords: ["ruehrei", "ruhrei", "omelett", "omelette", "spiegelei", "scrambled"], glyph: .emoji("🍳")),
        Rule(keywords: ["porridge", "haferbrei", "oatmeal", "muesli", "musli", "granola",
                        "cereal", "haferflocken"], glyph: .emoji("🥣")),
        Rule(keywords: ["pommes", "fries", "kartoffelgratin", "bratkartoffel", "kartoffelsalat",
                        "roesti", "rosti"], glyph: .emoji("🥔")),
        Rule(keywords: ["knoedel", "knodel", "kloesse", "klosse", "dumpling", "gnocchi",
                        "maultasche", "ravioli", "tortellini"], glyph: .emoji("🥟")),
        Rule(keywords: ["braten", "roast", "schnitzel", "steak", "rouladen", "fleisch",
                        "hackfleisch", "rind", "beef", "schwein", "pork", "lamm", "lamb"], glyph: .emoji("🥩")),

        // Mains by main component
        Rule(keywords: ["haehnchen", "hahnchen", "hendl", "chicken", "pute", "turkey",
                        "gefluegel", "geflugel", "haehnchenbrust"], glyph: .emoji("🍗")),
        Rule(keywords: ["fisch", "fish", "lachs", "salmon", "thunfisch", "tuna", "kabeljau",
                        "dorsch", "forelle", "trout"], glyph: .emoji("🐟")),
        Rule(keywords: ["garnele", "shrimp", "prawn", "scampi", "meeresfruechte", "meeresfruchte"], glyph: .emoji("🍤")),
        Rule(keywords: ["speck", "bacon", "schinken", "ham"], glyph: .emoji("🥓")),
        Rule(keywords: ["kaese", "kase", "cheese", "kaesespaetzle", "raclette", "fondue"], glyph: .emoji("🧀")),
        Rule(keywords: ["eier", "egg", "eggs"], glyph: .emoji("🥚")),

        // Sides. Below the proteins on purpose: "Lachsfilet mit Reis" is a
        // fish dish, and only a plain "Reis" is a rice one.
        Rule(keywords: ["reis", "rice"], glyph: .emoji("🍚")),

        // Baking and sweets
        Rule(keywords: ["kuchen", "cake", "torte", "gugelhupf"], glyph: .emoji("🍰")),
        Rule(keywords: ["muffin", "cupcake"], glyph: .emoji("🧁")),
        Rule(keywords: ["keks", "cookie", "plaetzchen", "platzchen", "biscuit"], glyph: .emoji("🍪")),
        Rule(keywords: ["schokolade", "chocolate", "brownie"], glyph: .emoji("🍫")),
        Rule(keywords: ["eis", "icecream", "gelato", "sorbet"], glyph: .emoji("🍦")),
        Rule(keywords: ["pudding", "creme", "mousse", "flan"], glyph: .emoji("🍮")),
        Rule(keywords: ["brot", "bread", "sauerteig", "krustenbrot"], glyph: .emoji("🍞")),
        Rule(keywords: ["broetchen", "brotchen", "semmel", "bun", "roll"], glyph: .emoji("🥐")),
        Rule(keywords: ["croissant", "hoernchen", "hornchen"], glyph: .emoji("🥐")),

        // Vegetables and fruit
        Rule(keywords: ["kuerbis", "kurbis", "pumpkin", "karotte", "moehre", "mohre", "carrot"], glyph: .emoji("🥕")),
        Rule(keywords: ["brokkoli", "broccoli", "spinat", "spinach", "gruenkohl", "grunkohl",
                        "kale", "bohnen", "beans", "erbsen", "peas", "gemuese", "gemuse",
                        "vegetable", "veggie"], glyph: .emoji("🥦")),
        Rule(keywords: ["tomate", "tomato", "sugo", "passata", "marinara"], glyph: .emoji("🍅")),
        Rule(keywords: ["pilz", "champignon", "mushroom", "steinpilz", "pfifferling"], glyph: .emoji("🍄")),
        Rule(keywords: ["mais", "corn", "polenta"], glyph: .emoji("🌽")),
        Rule(keywords: ["aubergine", "eggplant"], glyph: .emoji("🍆")),
        Rule(keywords: ["avocado", "guacamole"], glyph: .emoji("🥑")),
        Rule(keywords: ["apfel", "apple", "bratapfel"], glyph: .emoji("🍎")),
        Rule(keywords: ["banane", "banana"], glyph: .emoji("🍌")),
        Rule(keywords: ["erdbeer", "strawberry"], glyph: .emoji("🍓")),
        Rule(keywords: ["beere", "berry", "blaubeer", "heidelbeer", "blueberry",
                        "himbeer", "raspberry"], glyph: .emoji("🫐")),
        Rule(keywords: ["zitrone", "lemon", "limette", "lime"], glyph: .emoji("🍋")),

        // Drinks
        Rule(keywords: ["kaffee", "coffee", "cappuccino", "espresso", "latte"], glyph: .emoji("☕️")),
        Rule(keywords: ["tee", "tea", "chai"], glyph: .emoji("🍵")),
        Rule(keywords: ["smoothie", "shake", "saft", "juice"], glyph: .emoji("🥤")),
    ]

    /// Fallbacks by meal type, used when nothing in the name matched.
    static func fallback(for tags: Set<MealTypeTag>) -> DishGlyph {
        if tags.contains(.breakfast) { return .emoji("🥐") }
        if tags.contains(.snack) { return .emoji("🍎") }
        if tags.contains(.lunch) { return .emoji("🥗") }
        if tags.contains(.dinner) { return .emoji("🍽️") }
        return .symbol("fork.knife")
    }

    // MARK: - Suggestion

    /// The best glyph for a name, or `nil` when nothing matched — callers that
    /// want a guaranteed glyph use `suggestion(for:ingredientNames:mealTypeTags:)`.
    static func match(name: String) -> DishGlyph? {
        let haystack = tokenized(name)
        guard !haystack.isEmpty else { return nil }
        return rules.first { rule in
            rule.keywords.contains { contains(haystack, $0) }
        }?.glyph
    }

    /// A glyph for a dish: its name first, then its ingredients, then a
    /// fallback for its meal type. Always returns something.
    static func suggestion(
        for name: String,
        ingredientNames: [String] = [],
        mealTypeTags: Set<MealTypeTag> = []
    ) -> DishGlyph {
        if let fromName = match(name: name) { return fromName }
        for ingredient in ingredientNames {
            if let fromIngredient = match(name: ingredient) { return fromIngredient }
        }
        return fallback(for: mealTypeTags)
    }

    // MARK: - Matching

    /// Folded, punctuation-free, space-delimited form: " spaghetti bolognese ".
    /// The bracketing spaces let `contains` test word boundaries cheaply.
    static func tokenized(_ text: String) -> String {
        // Folded inline rather than via `String.searchFolded`, which lives in
        // the app target — this type also runs in the Share Extension.
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let cleaned = folded.map { $0.isLetter || $0.isNumber ? $0 : " " }
        let words = String(cleaned).split(separator: " ")
        guard !words.isEmpty else { return "" }
        return " " + words.joined(separator: " ") + " "
    }

    /// Short keywords must appear as whole words; from four characters up they
    /// may sit inside a compound. Without that split, three-letter keywords
    /// match half the language: "Fleisch" contains "eis", "Reis" contains "eis".
    static func contains(_ haystack: String, _ keyword: String) -> Bool {
        guard keyword.count >= 3 else { return false }
        if keyword.count <= 3 { return haystack.contains(" \(keyword) ") }
        return haystack.contains(keyword)
    }
}
