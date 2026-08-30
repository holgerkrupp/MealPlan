import Foundation

/// Proposes a handful of tags for a dish from its name, ingredients and
/// timings, so an imported or freshly typed recipe arrives already sorted
/// into "vegetarian", "pork", "pasta", "quick" and friends.
///
/// Matching reuses `DishGlyphSuggester`'s folded, keyword-based approach in
/// German and English — recipes get typed in either, and German glues its
/// compounds together ("Schweinebraten", "Nudelauflauf").
///
/// The suggestions are a starting point, never the last word: they are only
/// ever added to a dish that has no tags yet, or offered for the cook to tap.
enum DishTagSuggester {

    /// A tag the app knows how to propose. The raw value is the stable
    /// identifier; `localizedName` is what actually gets stored on the dish,
    /// and `aliases` let a suggestion recognise the same tag in a household
    /// whose vocabulary was built in another language.
    enum Kind: String, CaseIterable, Sendable {
        case vegan, vegetarian
        case pork, beef, poultry, lamb, fish, seafood
        case pasta, soup, salad, pizza, curry, casserole, grill, dessert, baking
        case spicy, quick, slowCooked, onePot

        var localizedName: String {
            switch self {
            case .vegan: String(localized: "Vegan")
            case .vegetarian: String(localized: "Vegetarian")
            case .pork: String(localized: "Pork")
            case .beef: String(localized: "Beef")
            case .poultry: String(localized: "Poultry")
            case .lamb: String(localized: "Lamb")
            case .fish: String(localized: "Fish")
            case .seafood: String(localized: "Seafood")
            case .pasta: String(localized: "Pasta")
            case .soup: String(localized: "Soup")
            case .salad: String(localized: "Salad")
            case .pizza: String(localized: "Pizza")
            case .curry: String(localized: "Curry")
            case .casserole: String(localized: "Casserole")
            case .grill: String(localized: "Grill")
            case .dessert: String(localized: "Dessert")
            case .baking: String(localized: "Baking")
            case .spicy: String(localized: "Spicy")
            case .quick: String(localized: "Short prepwork")
            case .slowCooked: String(localized: "Takes a while")
            case .onePot: String(localized: "One pot")
            }
        }

        /// Spellings this tag may already exist under in the household's
        /// vocabulary, so switching the app's language doesn't create twins.
        var aliases: [String] {
            switch self {
            case .vegan: ["Vegan"]
            case .vegetarian: ["Vegetarian", "Vegetarisch"]
            case .pork: ["Pork", "Schwein", "Schweinefleisch"]
            case .beef: ["Beef", "Rind", "Rindfleisch"]
            case .poultry: ["Poultry", "Chicken", "Geflügel", "Hähnchen"]
            case .lamb: ["Lamb", "Lamm"]
            case .fish: ["Fish", "Fisch"]
            case .seafood: ["Seafood", "Meeresfrüchte"]
            case .pasta: ["Pasta", "Nudeln"]
            case .soup: ["Soup", "Suppe"]
            case .salad: ["Salad", "Salat"]
            case .pizza: ["Pizza"]
            case .curry: ["Curry"]
            case .casserole: ["Casserole", "Auflauf"]
            case .grill: ["Grill", "Grillen", "BBQ"]
            case .dessert: ["Dessert", "Nachtisch"]
            case .baking: ["Baking", "Backen"]
            case .spicy: ["Spicy", "Scharf"]
            case .quick: ["Short prepwork", "Quick", "Schnell"]
            case .slowCooked: ["Takes a while", "Slow", "Dauert länger"]
            case .onePot: ["One pot", "Eintopf"]
            }
        }
    }

    // MARK: - Keyword tables

    /// Anything with an animal in it. Also disqualifies a dish from
    /// "vegetarian", which is why fish and stock live here too.
    static let meatKeywords: [Kind?: [String]] = [
        .pork: ["schwein", "schweine", "pork", "speck", "bacon", "schinken", "ham",
                "wurst", "bratwurst", "salami", "chorizo", "kassler", "leberkaese",
                "pancetta", "prosciutto", "mettwurst", "bockwurst", "eisbein"],
        .beef: ["rind", "rinder", "beef", "steak", "hackfleisch", "gulasch", "goulash",
                "rouladen", "tafelspitz", "corned", "brisket", "ochse"],
        .poultry: ["haehnchen", "hahnchen", "hendl", "chicken", "haehnchenbrust", "pute",
                   "turkey", "gefluegel", "geflugel", "ente", "duck", "gans", "goose",
                   "poulet", "haehnchenschenkel"],
        .lamb: ["lamm", "lamb", "hammel", "mutton"],
        .fish: ["fisch", "fish", "lachs", "salmon", "thunfisch", "tuna", "kabeljau",
                "dorsch", "forelle", "trout", "seelachs", "hering", "makrele", "anchovis",
                "sardelle", "sardine"],
        .seafood: ["garnele", "shrimp", "prawn", "scampi", "meeresfruechte", "meeresfruchte",
                   "seafood", "muschel", "mussel", "tintenfisch", "calamari", "hummer",
                   "lobster", "krabbe", "crab"],
        // Animal ingredients with no tag of their own; they only rule out
        // "vegetarian".
        nil: ["fleisch", "meat", "wild", "reh", "hirsch", "venison", "kalb", "veal",
              "leber", "liver", "niere", "kidney", "gelatine", "gelatin", "fleischbruehe",
              "fleischbruhe", "huehnerbruehe", "huhnerbruhe", "rinderbruehe", "rinderbruhe",
              "beefbroth", "chickenbroth"]
    ]

    /// Products that come from an animal without being one. They keep a dish
    /// from being vegan while leaving "vegetarian" intact.
    static let animalProductKeywords = [
        "milch", "milk", "butter", "sahne", "cream", "rahm", "schmand", "creme fraiche",
        "kaese", "kase", "cheese", "parmesan", "mozzarella", "feta", "gouda", "quark",
        "joghurt", "yoghurt", "yogurt", "ei", "eier", "egg", "eggs", "eigelb", "eiweiss",
        "honig", "honey", "mascarpone", "ricotta", "creme", "buttermilch", "kondensmilch",
        "frischkaese", "frischkase", "ghee"
    ]

    /// Course and technique tags, tried in order — a "Kürbissuppe" is a soup
    /// before it is anything else. A dish can pick up several.
    static let styleKeywords: [(Kind, [String])] = [
        (.soup, ["suppe", "soup", "eintopf", "stew", "bruehe", "bruhe", "broth", "ramen",
                 "chowder", "gulaschsuppe"]),
        (.pasta, ["spaghetti", "pasta", "nudel", "noodle", "bolognese", "carbonara",
                  "lasagne", "lasagna", "penne", "tagliatelle", "linguine", "makkaroni",
                  "maccheroni", "spaetzle", "spatzle", "tortellini", "ravioli", "gnocchi"]),
        (.pizza, ["pizza", "flammkuchen", "focaccia"]),
        (.salad, ["salat", "salad", "coleslaw", "bowl"]),
        (.curry, ["curry", "korma", "masala", "tikka", "dal", "dhal"]),
        (.casserole, ["auflauf", "gratin", "casserole", "moussaka", "ofengericht",
                      "ueberbacken", "uberbacken", "quiche"]),
        (.grill, ["grill", "gegrillt", "grilled", "barbecue", "bbq", "spiess", "skewer",
                  "steaks vom grill"]),
        (.dessert, ["dessert", "nachtisch", "nachspeise", "pudding", "mousse", "tiramisu",
                    "eis", "icecream", "sorbet", "kompott", "creme brulee", "panna cotta"]),
        (.baking, ["kuchen", "cake", "torte", "keks", "cookie", "plaetzchen", "platzchen",
                   "muffin", "cupcake", "brot", "bread", "broetchen", "brotchen", "hefeteig",
                   "backen", "gebaeck", "geback", "brownie", "waffel", "waffle", "streusel"]),
        (.onePot, ["eintopf", "one pot", "onepot", "onepan", "one pan", "pfannengericht",
                   "alles in einem topf"]),
        (.spicy, ["scharf", "spicy", "chili", "chilli", "sriracha", "harissa", "jalapeno",
                  "sambal", "cayenne", "peperoni", "curry scharf"])
    ]

    /// Total time at or below this counts as little prep work.
    static let quickMinutes = 25
    /// Total time at or above this is worth warning about.
    static let slowMinutes = 90

    // MARK: - Suggestion

    /// Up to `limit` tags for a dish, most characteristic first. Returns the
    /// display names to store: an entry the household already uses when one
    /// matches, otherwise the app's own localized name.
    static func suggestions(
        for name: String,
        ingredientNames: [String] = [],
        instructions: String? = nil,
        totalMinutes: Int? = nil,
        existingVocabulary: [String] = [],
        limit: Int = 6
    ) -> [String] {
        var kinds: [Kind] = []
        func add(_ kind: Kind) {
            if !kinds.contains(kind) { kinds.append(kind) }
        }

        let title = DishGlyphSuggester.tokenized(name)
        let ingredients = DishGlyphSuggester.tokenized(ingredientNames.joined(separator: " "))
        // Instructions are noisy — a garnish gets mentioned there — so they
        // only ever contribute technique words, never the diet decision.
        let steps = DishGlyphSuggester.tokenized(instructions ?? "")
        let subject = title + ingredients

        // Diet first: it is what people filter on.
        switch diet(title: title, ingredients: ingredients, ingredientCount: ingredientNames.count) {
        case .vegan: add(.vegan); add(.vegetarian)
        case .vegetarian: add(.vegetarian)
        case .none: break
        }

        // Then what's in it, so "pork" beats "casserole" for Schweinebraten.
        for (kind, keywords) in meatKeywords.sorted(by: { ($0.key?.rawValue ?? "") < ($1.key?.rawValue ?? "") }) {
            guard let kind, matches(subject, keywords) else { continue }
            add(kind)
        }

        for (kind, keywords) in styleKeywords where matches(subject, keywords) || matches(steps, keywords) {
            add(kind)
        }

        if let totalMinutes {
            if totalMinutes > 0, totalMinutes <= quickMinutes { add(.quick) }
            if totalMinutes >= slowMinutes { add(.slowCooked) }
        }

        return Array(kinds.prefix(limit)).map { kind in
            resolve(kind, in: existingVocabulary)
        }
    }

    /// Convenience for a dish that already exists.
    @MainActor
    static func suggestions(for dish: Dish, existingVocabulary: [String] = [], limit: Int = 6) -> [String] {
        suggestions(
            for: dish.name,
            ingredientNames: dish.sortedIngredients.compactMap { $0.ingredient?.name ?? $0.rawText },
            instructions: dish.recipeText,
            totalMinutes: dish.totalTimeMinutes,
            existingVocabulary: existingVocabulary,
            limit: limit
        )
    }

    // MARK: - Diet

    enum Diet { case vegan, vegetarian, none }

    /// What the ingredient list says about the diet.
    ///
    /// A claim in the title is taken at face value. Otherwise the absence of
    /// animal keywords only counts as evidence once there are enough
    /// ingredients to have mentioned one — a dish recorded as a bare name
    /// isn't vegetarian just because nothing says otherwise.
    static func diet(title: String, ingredients: String, ingredientCount: Int) -> Diet {
        if matches(title, ["vegan"]) { return .vegan }
        if matches(title, ["vegetarisch", "vegetarian", "veggie"]) { return .vegetarian }

        guard ingredientCount >= 3 else { return .none }
        let subject = title + ingredients
        let hasMeat = meatKeywords.values.contains { matches(subject, $0) }
        guard !hasMeat else { return .none }
        return matches(subject, animalProductKeywords) ? .vegetarian : .vegan
    }

    // MARK: - Matching

    /// Keywords of four letters or more may sit inside a German compound
    /// ("Schweinebraten", "Nudelauflauf"); shorter ones and whole phrases must
    /// stand as words of their own. Without that split "Ei" would match
    /// "Eintopf" and "Reis" would match "Fleisch".
    static func matches(_ haystack: String, _ keywords: [String]) -> Bool {
        guard !haystack.isEmpty else { return false }
        return keywords.contains { keyword in
            let needle = DishGlyphSuggester.tokenized(keyword).trimmingCharacters(in: .whitespaces)
            guard !needle.isEmpty else { return false }
            if needle.count <= 3 || needle.contains(" ") {
                return haystack.contains(" \(needle) ")
            }
            return haystack.contains(needle)
        }
    }

    /// The household's own word for this tag if they have one, else ours.
    static func resolve(_ kind: Kind, in vocabulary: [String]) -> String {
        for alias in [kind.localizedName] + kind.aliases {
            let key = DishTag.normalize(alias)
            if let existing = vocabulary.first(where: { DishTag.normalize($0) == key }) {
                return existing
            }
        }
        return kind.localizedName
    }
}
