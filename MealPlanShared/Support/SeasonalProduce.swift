import Foundation

/// Rough "what's in season in Germany" table, used to surface seasonally
/// relevant dishes in the library.
enum SeasonalProduce {
    /// normalized produce name → seasons it's typically available.
    static let table: [String: Set<Season>] = [
        "spargel": [.spring],
        "barlauch": [.spring], "baerlauch": [.spring],
        "rhabarber": [.spring],
        "radieschen": [.spring, .summer],
        "erdbeeren": [.summer], "erdbeere": [.summer],
        "tomaten": [.summer], "tomate": [.summer],
        "zucchini": [.summer],
        "paprika": [.summer],
        "gurke": [.summer], "gurken": [.summer],
        "kirschen": [.summer],
        "beeren": [.summer], "heidelbeeren": [.summer], "himbeeren": [.summer],
        "mais": [.summer, .autumn],
        "kuerbis": [.autumn], "kürbis": [.autumn],
        "kohl": [.autumn, .winter], "rotkohl": [.autumn, .winter], "weisskohl": [.autumn, .winter],
        "wirsing": [.autumn, .winter],
        "rosenkohl": [.autumn, .winter],
        "grunkohl": [.winter], "grünkohl": [.winter],
        "pilze": [.autumn], "pfifferlinge": [.summer, .autumn], "steinpilze": [.autumn],
        "apfel": [.autumn], "äpfel": [.autumn], "birnen": [.autumn],
        "pflaumen": [.autumn], "zwetschgen": [.autumn],
        "rote bete": [.autumn, .winter], "rote beete": [.autumn, .winter],
        "pastinake": [.autumn, .winter], "pastinaken": [.autumn, .winter],
        "feldsalat": [.autumn, .winter],
        "lauch": [.autumn, .winter], "porree": [.autumn, .winter],
        "sellerie": [.autumn, .winter],
        "maroni": [.winter], "esskastanien": [.winter],
    ]

    static func seasons(forIngredientNamed name: String) -> Set<Season> {
        let key = Ingredient.normalize(name)
        for (produce, seasons) in table where key.contains(produce) {
            return seasons
        }
        return []
    }

    static func isInSeason(ingredientNamed name: String, on date: Date = .now) -> Bool {
        seasons(forIngredientNamed: name).contains(Season.current(for: date))
    }
}
