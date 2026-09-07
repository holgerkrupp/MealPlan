import Foundation

/// A recipe site that is known to publish a discoverable RSS or Atom feed,
/// offered as a starting point on the subscribe sheet.
struct RecipeFeedSuggestion: Identifiable, Hashable, Sendable {
    /// The site's own name. Never translated — it is a proper noun.
    let name: String
    /// One line about the site, written in the language of the list it belongs
    /// to rather than pulled from the string catalog: every list is already
    /// region-specific, so a German reader only ever sees the German sites and
    /// a blurb in English next to "Küchengötter" would be the odd one out.
    let detail: String
    /// The site's home page, or a direct feed URL for the handful of sites
    /// whose first advertised `<link rel="alternate">` is not the recipe feed.
    let urlString: String

    var id: String { urlString }
    var url: URL? { URL(string: urlString) }

    /// The bare host, for a subdued second line under the name.
    var displayHost: String {
        guard let host = URL(string: urlString)?.host() else { return urlString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Region-specific starting points for `RecipeFeedService.subscribe(to:…)`.
///
/// The device *region* is asked first and the language only second: someone
/// living in Germany with an English-language phone still shops, cooks and
/// measures in Germany, so `chefkoch`-shaped sites serve them better than
/// American ones. Language is the fallback for the reverse case — a Spanish
/// speaker in a region we have no list for.
enum RecipeFeedSuggestions {
    static func suggestions(for locale: Locale = .current) -> [RecipeFeedSuggestion] {
        if let region = locale.region?.identifier.uppercased(), let list = byRegion[region] {
            return list
        }
        if let language = locale.language.languageCode?.identifier.lowercased(), let list = byLanguage[language] {
            return list
        }
        return unitedStates
    }

    private static let byRegion: [String: [RecipeFeedSuggestion]] = [
        "US": unitedStates,
        "CA": unitedStates,
        "AU": unitedKingdom,
        "NZ": unitedKingdom,
        "GB": unitedKingdom,
        "IE": unitedKingdom,
        "DE": germanSpeaking,
        "AT": germanSpeaking,
        "CH": germanSpeaking,
        "LI": germanSpeaking,
        "FR": france,
        "IT": italy,
        "ES": spain,
        "NL": netherlands,
    ]

    private static let byLanguage: [String: [RecipeFeedSuggestion]] = [
        "de": germanSpeaking,
        "fr": france,
        "it": italy,
        "es": spain,
        "nl": netherlands,
        "en": unitedStates,
    ]

    private static let unitedStates: [RecipeFeedSuggestion] = [
        .init(
            name: "Smitten Kitchen",
            detail: "Deb Perelman’s small-kitchen classics.",
            urlString: "https://smittenkitchen.com"
        ),
        .init(
            name: "Budget Bytes",
            detail: "Weeknight dinners with the cost per serving worked out.",
            urlString: "https://www.budgetbytes.com"
        ),
        .init(
            name: "Cookie and Kate",
            detail: "Vegetarian cooking built around whole ingredients.",
            urlString: "https://cookieandkate.com"
        ),
        .init(
            name: "Love and Lemons",
            detail: "Seasonal, produce-first vegetarian recipes.",
            urlString: "https://www.loveandlemons.com/feed/"
        ),
        .init(
            name: "The Mediterranean Dish",
            detail: "Olive-oil-forward Mediterranean home cooking.",
            urlString: "https://www.themediterraneandish.com"
        ),
        .init(
            name: "101 Cookbooks",
            detail: "Heidi Swanson’s natural-foods recipe journal.",
            urlString: "https://www.101cookbooks.com"
        ),
        .init(
            name: "Bon Appétit",
            detail: "Recipes and food writing from the magazine.",
            urlString: "https://www.bonappetit.com"
        ),
        .init(
            name: "Epicurious",
            detail: "A deep, long-running recipe archive.",
            urlString: "https://www.epicurious.com"
        ),
    ]

    private static let unitedKingdom: [RecipeFeedSuggestion] = [
        .init(
            name: "Good Food",
            detail: "Tested everyday recipes from the BBC Good Food team.",
            urlString: "https://www.bbcgoodfood.com"
        ),
        .init(
            name: "olive Magazine",
            detail: "Modern British cooking, travel and drinks.",
            urlString: "https://www.olivemagazine.com"
        ),
        .init(
            name: "GoodTo",
            detail: "Family meals, batch cooking and budget dinners.",
            urlString: "https://www.goodto.com"
        ),
        .init(
            name: "Smitten Kitchen",
            detail: "Deb Perelman’s small-kitchen classics.",
            urlString: "https://smittenkitchen.com"
        ),
        .init(
            name: "Budget Bytes",
            detail: "Weeknight dinners with the cost per serving worked out.",
            urlString: "https://www.budgetbytes.com"
        ),
        .init(
            name: "Bon Appétit",
            detail: "Recipes and food writing from the magazine.",
            urlString: "https://www.bonappetit.com"
        ),
    ]

    private static let germanSpeaking: [RecipeFeedSuggestion] = [
        .init(
            name: "Küchengötter",
            detail: "Erprobte Rezepte aus der Redaktion, täglich neu.",
            urlString: "https://www.kuechengoetter.de"
        ),
        .init(
            name: "essen & trinken",
            detail: "Rezepte, Warenkunde und Küchentechnik aus dem Magazin.",
            urlString: "https://www.essen-und-trinken.de"
        ),
        .init(
            name: "Kochkarussell",
            detail: "Schnelle Feierabendküche für jeden Tag.",
            urlString: "https://kochkarussell.com"
        ),
        .init(
            name: "Eat this!",
            detail: "Vegane Küche mit viel Gemüse und Wochenplan-Ideen.",
            urlString: "https://www.eat-this.org"
        ),
        .init(
            name: "EAT SMARTER",
            detail: "Das Rezept des Tages, gesund und nährwertberechnet.",
            urlString: "https://eatsmarter.de/rezepte-des-tages/feed"
        ),
        .init(
            name: "Bianca Zapatka",
            detail: "Vegane Rezepte und Backideen mit vielen Fotos.",
            urlString: "https://biancazapatka.com/de/feed/"
        ),
        .init(
            name: "Backen macht glücklich",
            detail: "Kuchen, Brot und Plätzchen, Schritt für Schritt erklärt.",
            urlString: "https://www.backenmachtgluecklich.de"
        ),
        .init(
            name: "Zucker, Zimt und Liebe",
            detail: "Saisonale Küche und Backrezepte aus Hamburg.",
            urlString: "https://www.zuckerzimtundliebe.de"
        ),
        .init(
            name: "KochTrotz",
            detail: "Rezepte mit Tauschzutaten bei Unverträglichkeiten.",
            urlString: "https://www.kochtrotz.de"
        ),
    ]

    private static let france: [RecipeFeedSuggestion] = [
        .init(
            name: "Ptitchef",
            detail: "De nouvelles recettes de cuisine tous les jours.",
            urlString: "https://www.ptitchef.com"
        ),
        .init(
            name: "Amandine Cooking",
            detail: "Cuisine de saison, légère et expliquée pas à pas.",
            urlString: "https://www.amandinecooking.com"
        ),
        .init(
            name: "La Cuisine d’Annie",
            detail: "Des recettes familiales simples et testées.",
            urlString: "https://www.lacuisinedannie.com"
        ),
        .init(
            name: "Empreinte Sucrée",
            detail: "Pâtisserie maison, des bases aux entremets.",
            urlString: "https://empreintesucree.fr"
        ),
        .init(
            name: "Chocolate & Zucchini",
            detail: "La cuisine parisienne de Clotilde Dusoulier (en anglais).",
            urlString: "https://cnz.to"
        ),
    ]

    private static let italy: [RecipeFeedSuggestion] = [
        .init(
            name: "GialloZafferano",
            detail: "Le ricette più cercate d’Italia, provate in redazione.",
            urlString: "https://www.giallozafferano.it"
        ),
        .init(
            name: "Misya",
            detail: "Ricette di casa spiegate passo passo.",
            urlString: "https://www.misya.info"
        ),
        .init(
            name: "Cookaround",
            detail: "Ricette e tecniche dalla community di cucina.",
            urlString: "https://www.cookaround.com"
        ),
        .init(
            name: "La Cucina Italiana",
            detail: "Ricette e cultura gastronomica dalla rivista.",
            urlString: "https://www.lacucinaitaliana.it"
        ),
        .init(
            name: "Ricette della Nonna",
            detail: "Piatti della tradizione, dolci e conserve.",
            urlString: "https://www.ricettedellanonna.net"
        ),
    ]

    private static let spain: [RecipeFeedSuggestion] = [
        .init(
            name: "Cocina Casera y Fácil",
            detail: "Recetas sencillas para el día a día.",
            urlString: "https://www.cocinacaserayfacil.net"
        ),
        .init(
            name: "Cocinillas",
            detail: "Recetas y actualidad gastronómica de El Español.",
            urlString: "https://www.elespanol.com/rss/cocinillas/"
        ),
        .init(
            name: "La Cocina de Frabisa",
            detail: "Cocina gallega y de temporada, muy explicada.",
            urlString: "https://lacocinadefrabisa.lavozdegalicia.es"
        ),
        .init(
            name: "Pepekitchen",
            detail: "Recetas mediterráneas y repostería casera.",
            urlString: "https://pepekitchen.com"
        ),
    ]

    private static let netherlands: [RecipeFeedSuggestion] = [
        .init(
            name: "Lekker en Simpel",
            detail: "Simpele recepten voor doordeweekse dagen.",
            urlString: "https://www.lekkerensimpel.com"
        ),
        .init(
            name: "Leuke Recepten",
            detail: "Alledaagse gezinsrecepten met stap-voor-stap foto’s.",
            urlString: "https://www.leukerecepten.nl/feed/"
        ),
        .init(
            name: "Francesca Kookt",
            detail: "Seizoensgebonden koken en bakken.",
            urlString: "https://www.francescakookt.nl"
        ),
        .init(
            name: "Ohmydish",
            detail: "Een grote verzameling recepten uit de hele wereld.",
            urlString: "https://ohmydish.com/feed"
        ),
        .init(
            name: "Laura’s Bakery",
            detail: "Bakrecepten, van basisdeeg tot taart.",
            urlString: "https://www.laurasbakery.nl"
        ),
    ]
}
