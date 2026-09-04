import Foundation

/// MealPlan's bundled reference values: roughly what 100 g of a generic
/// ingredient contains.
///
/// Bundled rather than fetched on purpose. The app is offline-first and syncs
/// through CloudKit, and the alternative — a product database keyed by barcode
/// — answers a different question: it knows what one brand of penne contains
/// and nothing at all about "Zwiebel". Recipes are written in generic
/// ingredients, so that is what this table holds. A household that cares about
/// a specific product can type its own values on the ingredient, which always
/// win (see `Ingredient.nutritionFacts`).
///
/// Values are rounded reference figures for the raw, as-bought ingredient, in
/// the spirit of USDA FoodData Central and the German BLS. They are averages
/// of things that genuinely vary — two onions differ, mince is 5 % or 20 % fat
/// — so everything downstream is labelled an estimate. See `NutritionFacts`.
///
/// Matching follows the same shape as `DensityTable`, but is stricter about
/// short names: "Reis" contains "ei", and rice is not eggs. An alias shorter
/// than four characters must match a whole word.
enum NutritionTable {

    struct Entry: Sendable {
        /// Every spelling that means this ingredient, German and English. The
        /// first is only for readability; all of them match.
        var names: [String]
        /// Per 100 g of the ingredient as bought.
        var facts: NutritionFacts

        init(_ names: [String], _ facts: NutritionFacts) {
            self.names = names
            self.facts = facts
        }
    }

    /// Per 100 g: kcal, protein g, carbohydrate g, fat g.
    static let entries: [Entry] = [

        // MARK: Vegetables
        Entry(["Kartoffel", "Kartoffeln", "potato", "potatoes"], .init(77, 2.0, 17, 0.1)),
        Entry(["Süßkartoffel", "Suesskartoffel", "sweet potato"], .init(86, 1.6, 20, 0.1)),
        Entry(["Zwiebel", "Zwiebeln", "onion", "onions"], .init(40, 1.1, 9.3, 0.1)),
        Entry(["Frühlingszwiebel", "Fruehlingszwiebel", "Lauchzwiebel", "spring onion", "scallion"], .init(32, 1.8, 7.3, 0.2)),
        Entry(["Schalotte", "Schalotten", "shallot"], .init(72, 2.5, 17, 0.1)),
        Entry(["Knoblauch", "garlic"], .init(149, 6.4, 33, 0.5)),
        Entry(["Tomate", "Tomaten", "tomato", "tomatoes"], .init(18, 0.9, 3.9, 0.2)),
        Entry(["Tomatenmark", "tomato paste", "tomato purée", "tomato puree"], .init(82, 4.3, 19, 0.5)),
        Entry(["passierte Tomaten", "Passata", "Tomatenpassata"], .init(30, 1.3, 5.5, 0.2)),
        Entry(["Tomatensauce", "Tomatensoße", "tomato sauce"], .init(45, 1.6, 8.0, 0.8)),
        Entry(["Karotte", "Karotten", "Möhre", "Möhren", "Mohrrübe", "carrot", "carrots"], .init(41, 0.9, 9.6, 0.2)),
        Entry(["Paprika", "Paprikaschote", "bell pepper", "peppers"], .init(31, 1.0, 6.0, 0.3)),
        Entry(["Zucchini", "courgette"], .init(17, 1.2, 3.1, 0.3)),
        Entry(["Aubergine", "Auberginen", "eggplant"], .init(25, 1.0, 5.9, 0.2)),
        Entry(["Gurke", "Salatgurke", "cucumber"], .init(15, 0.7, 3.6, 0.1)),
        Entry(["Brokkoli", "Broccoli", "broccoli"], .init(34, 2.8, 6.6, 0.4)),
        Entry(["Blumenkohl", "cauliflower"], .init(25, 1.9, 5.0, 0.3)),
        Entry(["Spinat", "spinach"], .init(23, 2.9, 3.6, 0.4)),
        Entry(["Champignon", "Champignons", "Pilze", "Pilz", "mushroom", "mushrooms"], .init(22, 3.1, 3.3, 0.3)),
        Entry(["Lauch", "Porree", "leek"], .init(61, 1.5, 14, 0.3)),
        Entry(["Sellerie", "Staudensellerie", "celery"], .init(16, 0.7, 3.0, 0.2)),
        Entry(["Knollensellerie", "celeriac"], .init(42, 1.5, 9.2, 0.3)),
        Entry(["Kohlrabi"], .init(27, 1.7, 6.2, 0.1)),
        Entry(["Weißkohl", "Weisskohl", "Kohl", "Spitzkohl", "cabbage"], .init(25, 1.3, 5.8, 0.1)),
        Entry(["Rotkohl", "Blaukraut", "red cabbage"], .init(31, 1.4, 7.4, 0.2)),
        Entry(["Rosenkohl", "brussels sprouts"], .init(43, 3.4, 9.0, 0.3)),
        Entry(["Wirsing", "savoy"], .init(27, 2.0, 6.1, 0.1)),
        Entry(["Erbsen", "Erbse", "peas"], .init(81, 5.4, 14, 0.4)),
        Entry(["Mais", "Maiskörner", "sweetcorn", "corn"], .init(86, 3.3, 19, 1.2)),
        Entry(["grüne Bohnen", "Bohnen", "green beans"], .init(31, 1.8, 7.0, 0.1)),
        Entry(["Kidneybohnen", "kidney beans"], .init(127, 8.7, 23, 0.5)),
        Entry(["Kichererbsen", "chickpeas"], .init(164, 8.9, 27, 2.6)),
        Entry(["Linsen", "lentils"], .init(116, 9.0, 20, 0.4)),
        Entry(["Salat", "Kopfsalat", "Blattsalat", "lettuce"], .init(15, 1.4, 2.9, 0.2)),
        Entry(["Rucola", "rocket", "arugula"], .init(25, 2.6, 3.7, 0.7)),
        Entry(["Feldsalat", "lamb's lettuce"], .init(21, 2.0, 3.6, 0.4)),
        Entry(["Kürbis", "Kuerbis", "pumpkin", "squash"], .init(26, 1.0, 6.5, 0.1)),
        Entry(["Rote Bete", "Rote Beete", "beetroot"], .init(43, 1.6, 9.6, 0.2)),
        Entry(["Fenchel", "fennel"], .init(31, 1.2, 7.3, 0.2)),
        Entry(["Spargel", "asparagus"], .init(20, 2.2, 3.9, 0.1)),
        Entry(["Avocado"], .init(160, 2.0, 8.5, 15)),
        Entry(["Ingwer", "ginger"], .init(80, 1.8, 18, 0.8)),
        Entry(["Chili", "Chilischote", "Peperoni", "chilli", "chili pepper"], .init(40, 1.9, 8.8, 0.4)),
        Entry(["Oliven", "olives"], .init(145, 1.0, 3.8, 15)),
        Entry(["Sauerkraut"], .init(19, 0.9, 4.3, 0.1)),
        Entry(["Radieschen", "radish"], .init(16, 0.7, 3.4, 0.1)),

        // MARK: Fruit
        Entry(["Apfel", "Äpfel", "apple", "apples"], .init(52, 0.3, 14, 0.2)),
        Entry(["Banane", "Bananen", "banana"], .init(89, 1.1, 23, 0.3)),
        Entry(["Birne", "Birnen", "pear"], .init(57, 0.4, 15, 0.1)),
        Entry(["Orange", "Orangen", "orange"], .init(47, 0.9, 12, 0.1)),
        Entry(["Zitrone", "Zitronen", "lemon"], .init(29, 1.1, 9.3, 0.3)),
        Entry(["Limette", "lime"], .init(30, 0.7, 11, 0.2)),
        Entry(["Erdbeere", "Erdbeeren", "strawberry", "strawberries"], .init(32, 0.7, 7.7, 0.3)),
        Entry(["Himbeere", "Himbeeren", "raspberry", "raspberries"], .init(52, 1.2, 12, 0.7)),
        Entry(["Heidelbeere", "Heidelbeeren", "Blaubeeren", "blueberry", "blueberries"], .init(57, 0.7, 14, 0.3)),
        Entry(["Trauben", "Weintrauben", "grapes"], .init(69, 0.7, 18, 0.2)),
        Entry(["Mango"], .init(60, 0.8, 15, 0.4)),
        Entry(["Pfirsich", "peach"], .init(39, 0.9, 10, 0.3)),
        Entry(["Ananas", "pineapple"], .init(50, 0.5, 13, 0.1)),
        Entry(["Kiwi"], .init(61, 1.1, 15, 0.5)),
        Entry(["Rosinen", "raisins"], .init(299, 3.1, 79, 0.5)),
        Entry(["Datteln", "dates"], .init(282, 2.5, 75, 0.4)),
        Entry(["Aprikose", "Aprikosen", "apricot"], .init(48, 1.4, 11, 0.4)),
        Entry(["Wassermelone", "watermelon"], .init(30, 0.6, 7.6, 0.2)),

        // MARK: Grains, bread, pantry
        Entry(["Mehl", "Weizenmehl", "flour"], .init(364, 10, 76, 1.0)),
        Entry(["Vollkornmehl", "wholemeal flour", "whole wheat flour"], .init(340, 13, 72, 2.5)),
        Entry(["Reis", "rice"], .init(360, 7.0, 79, 0.7)),
        Entry(["Nudeln", "Pasta", "Spaghetti", "Penne", "Makkaroni", "pasta", "noodles"], .init(371, 13, 75, 1.5)),
        Entry(["Vollkornnudeln", "wholemeal pasta"], .init(348, 14, 71, 2.5)),
        Entry(["Couscous"], .init(376, 13, 77, 0.6)),
        Entry(["Bulgur"], .init(342, 12, 76, 1.3)),
        Entry(["Quinoa"], .init(368, 14, 64, 6.1)),
        Entry(["Haferflocken", "Hafer", "oats", "porridge oats"], .init(375, 13, 60, 7.0)),
        Entry(["Brot", "bread"], .init(265, 9.0, 49, 3.2)),
        Entry(["Vollkornbrot", "wholemeal bread"], .init(250, 8.4, 43, 3.4)),
        Entry(["Brötchen", "Broetchen", "Semmel", "bread roll"], .init(280, 9.0, 55, 2.5)),
        Entry(["Toast", "Toastbrot", "toast"], .init(280, 8.0, 50, 4.0)),
        Entry(["Semmelbrösel", "Paniermehl", "breadcrumbs"], .init(380, 13, 72, 5.0)),
        Entry(["Blätterteig", "Blaetterteig", "puff pastry"], .init(383, 5.2, 36, 24)),
        Entry(["Pizzateig", "pizza dough"], .init(270, 8.0, 50, 3.5)),
        Entry(["Tortilla", "Wrap", "tortillas"], .init(310, 8.0, 51, 8.0)),
        Entry(["Zucker", "sugar"], .init(400, 0, 100, 0)),
        Entry(["Puderzucker", "icing sugar"], .init(390, 0, 98, 0)),
        Entry(["Honig", "honey"], .init(304, 0.3, 82, 0)),
        Entry(["Ahornsirup", "maple syrup"], .init(260, 0, 67, 0.1)),
        Entry(["Speisestärke", "Stärke", "Maisstärke", "cornflour", "cornstarch"], .init(381, 0.3, 91, 0.1)),
        Entry(["Grieß", "Griess", "semolina"], .init(360, 12, 73, 1.1)),
        Entry(["Polenta", "Maisgrieß", "Maisgriess"], .init(362, 8.1, 79, 1.2)),
        Entry(["Hefe", "yeast"], .init(105, 12, 12, 2.0)),
        Entry(["Salz", "Meersalz", "salt"], .init(0, 0, 0, 0)),
        Entry(["Backpulver", "Natron", "baking powder", "baking soda"], .init(0, 0, 0, 0)),
        Entry(["Schokolade", "Zartbitterschokolade", "chocolate"], .init(546, 7.8, 46, 31)),
        Entry(["Kakao", "Kakaopulver", "cocoa"], .init(228, 20, 58, 14)),
        Entry(["Marmelade", "Konfitüre", "jam"], .init(250, 0.4, 60, 0.1)),
        Entry(["Nuss-Nougat-Creme", "Nutella", "chocolate spread"], .init(539, 6.3, 57, 31)),

        // MARK: Nuts and seeds
        Entry(["Mandeln", "Mandel", "almonds"], .init(579, 21, 22, 50)),
        Entry(["Walnüsse", "Walnuesse", "Walnuss", "walnuts"], .init(654, 15, 14, 65)),
        Entry(["Haselnüsse", "Haselnuesse", "hazelnuts"], .init(628, 15, 17, 61)),
        Entry(["Cashew", "Cashewkerne", "cashews"], .init(553, 18, 30, 44)),
        Entry(["Erdnüsse", "Erdnuesse", "peanuts"], .init(567, 26, 16, 49)),
        Entry(["Pinienkerne", "pine nuts"], .init(673, 14, 13, 68)),
        Entry(["Sonnenblumenkerne", "sunflower seeds"], .init(584, 21, 20, 51)),
        Entry(["Kürbiskerne", "Kuerbiskerne", "pumpkin seeds"], .init(559, 30, 11, 49)),
        Entry(["Sesam", "sesame"], .init(573, 18, 23, 50)),
        Entry(["Leinsamen", "linseed", "flaxseed"], .init(534, 18, 29, 42)),
        Entry(["Chiasamen", "chia"], .init(486, 17, 42, 31)),
        Entry(["Erdnussbutter", "peanut butter"], .init(588, 25, 20, 50)),

        // MARK: Dairy and eggs
        Entry(["Milch", "Vollmilch", "milk"], .init(64, 3.3, 4.8, 3.6)),
        Entry(["fettarme Milch", "Magermilch", "skimmed milk"], .init(47, 3.4, 4.8, 1.5)),
        Entry(["Hafermilch", "Haferdrink", "oat milk"], .init(45, 0.5, 7.0, 1.5)),
        Entry(["Mandelmilch", "almond milk"], .init(24, 0.5, 3.0, 1.1)),
        Entry(["Sahne", "Schlagsahne", "cream", "double cream"], .init(292, 2.1, 3.4, 30)),
        Entry(["Crème fraîche", "Creme fraiche"], .init(292, 2.4, 2.9, 30)),
        Entry(["Schmand"], .init(240, 3.0, 3.5, 24)),
        Entry(["saure Sahne", "sour cream"], .init(115, 3.0, 3.6, 10)),
        Entry(["Joghurt", "Naturjoghurt", "yoghurt", "yogurt"], .init(61, 3.5, 4.7, 3.3)),
        Entry(["griechischer Joghurt", "greek yoghurt", "greek yogurt"], .init(97, 9.0, 4.0, 5.0)),
        Entry(["Magerquark", "low fat quark"], .init(67, 12, 4.0, 0.3)),
        Entry(["Quark", "quark"], .init(109, 12, 3.2, 5.1)),
        Entry(["Hüttenkäse", "Huettenkaese", "cottage cheese"], .init(98, 11, 3.4, 4.3)),
        Entry(["Frischkäse", "Frischkaese", "cream cheese"], .init(253, 6.0, 4.0, 24)),
        Entry(["Butter", "butter"], .init(717, 0.9, 0.6, 81)),
        Entry(["Margarine"], .init(717, 0.2, 0.7, 80)),
        Entry(["Käse", "Kaese", "Gouda", "Emmentaler", "cheese"], .init(356, 25, 2.2, 27)),
        Entry(["Mozzarella"], .init(280, 22, 2.2, 20)),
        Entry(["Parmesan", "Grana Padano", "parmesan"], .init(402, 36, 3.2, 27)),
        Entry(["Feta", "Schafskäse", "feta"], .init(264, 14, 4.1, 21)),
        Entry(["Cheddar"], .init(403, 25, 1.3, 33)),
        Entry(["Ricotta"], .init(174, 11, 3.0, 13)),
        Entry(["Mascarpone"], .init(435, 4.6, 4.0, 44)),
        Entry(["Buttermilch", "buttermilk"], .init(40, 3.4, 4.7, 0.9)),
        Entry(["Ei", "Eier", "egg", "eggs"], .init(143, 13, 0.7, 9.5)),
        Entry(["Eigelb", "egg yolk"], .init(322, 16, 3.6, 27)),
        Entry(["Eiweiß", "Eiweiss", "egg white"], .init(52, 11, 0.7, 0.2)),

        // MARK: Meat and fish
        Entry(["Hähnchenbrust", "Haehnchenbrust", "Hühnerbrust", "chicken breast"], .init(165, 31, 0, 3.6)),
        Entry(["Hähnchen", "Haehnchen", "Huhn", "Hühnchen", "chicken"], .init(215, 25, 0, 13)),
        Entry(["Pute", "Putenbrust", "Truthahn", "turkey"], .init(157, 29, 0, 3.6)),
        Entry(["Hackfleisch", "Gehacktes", "Faschiertes", "mince", "ground beef", "ground meat"], .init(241, 19, 0, 18)),
        Entry(["Rindfleisch", "Rind", "Steak", "beef"], .init(217, 26, 0, 12)),
        Entry(["Schweinefleisch", "Schwein", "pork"], .init(242, 27, 0, 14)),
        Entry(["Lammfleisch", "Lamm", "lamb"], .init(294, 25, 0, 21)),
        Entry(["Speck", "Bacon", "bacon"], .init(541, 37, 1.4, 42)),
        Entry(["Schinken", "ham"], .init(145, 21, 1.5, 6.0)),
        Entry(["Salami"], .init(407, 22, 1.5, 34)),
        Entry(["Bratwurst", "Wurst", "sausage"], .init(297, 13, 2.5, 26)),
        Entry(["Lachs", "salmon"], .init(208, 20, 0, 13)),
        Entry(["Thunfisch", "tuna"], .init(116, 26, 0, 1.0)),
        Entry(["Kabeljau", "Dorsch", "Seelachs", "cod"], .init(82, 18, 0, 0.7)),
        Entry(["Forelle", "trout"], .init(148, 21, 0, 6.6)),
        Entry(["Garnelen", "Shrimps", "prawns", "shrimp"], .init(99, 24, 0.2, 0.3)),
        Entry(["Tofu"], .init(76, 8.0, 1.9, 4.8)),

        // MARK: Fats, liquids, condiments
        Entry(["Olivenöl", "Olivenoel", "olive oil"], .init(884, 0, 0, 100)),
        Entry(["Rapsöl", "Rapsoel", "rapeseed oil", "canola oil"], .init(884, 0, 0, 100)),
        Entry(["Sonnenblumenöl", "Sonnenblumenoel", "sunflower oil"], .init(884, 0, 0, 100)),
        Entry(["Kokosöl", "Kokosoel", "coconut oil"], .init(892, 0, 0, 99)),
        Entry(["Öl", "Oel", "Speiseöl", "oil", "cooking oil"], .init(884, 0, 0, 100)),
        Entry(["Kokosmilch", "coconut milk"], .init(197, 2.0, 3.3, 21)),
        Entry(["Essig", "vinegar"], .init(21, 0, 0.9, 0)),
        Entry(["Balsamico", "balsamic"], .init(88, 0.5, 17, 0)),
        Entry(["Sojasauce", "Sojasoße", "soy sauce"], .init(53, 8.1, 4.9, 0.6)),
        Entry(["Senf", "mustard"], .init(66, 4.4, 5.8, 3.3)),
        Entry(["Ketchup"], .init(101, 1.2, 24, 0.1)),
        Entry(["Mayonnaise", "Mayo"], .init(680, 1.0, 1.5, 75)),
        Entry(["Pesto"], .init(450, 5.0, 6.0, 45)),
        Entry(["Brühe", "Bruehe", "Gemüsebrühe", "Hühnerbrühe", "stock", "broth"], .init(4, 0.3, 0.4, 0.1)),
        Entry(["Weißwein", "Weisswein", "white wine"], .init(82, 0.1, 2.6, 0)),
        Entry(["Rotwein", "red wine"], .init(85, 0.1, 2.6, 0)),
        Entry(["Bier", "beer"], .init(43, 0.5, 3.6, 0)),
        Entry(["Wasser", "water"], .init(0, 0, 0, 0)),

        // MARK: Herbs and spices
        // Used in gram amounts that barely move a total, but having them here
        // keeps them out of "we couldn't work these out".
        Entry(["Petersilie", "parsley"], .init(36, 3.0, 6.3, 0.8)),
        Entry(["Basilikum", "basil"], .init(23, 3.2, 2.7, 0.6)),
        Entry(["Schnittlauch", "chives"], .init(30, 3.3, 4.4, 0.7)),
        Entry(["Dill"], .init(43, 3.5, 7.0, 1.1)),
        Entry(["Koriander", "coriander", "cilantro"], .init(23, 2.1, 3.7, 0.5)),
        Entry(["Thymian", "thyme"], .init(101, 5.6, 24, 1.7)),
        Entry(["Rosmarin", "rosemary"], .init(131, 3.3, 21, 5.9)),
        Entry(["Oregano"], .init(265, 9.0, 69, 4.3)),
        Entry(["Paprikapulver", "Paprikapulver edelsüß", "paprika powder"], .init(282, 14, 54, 13)),
        Entry(["Curry", "Currypulver", "curry powder"], .init(325, 14, 56, 14)),
        Entry(["Pfeffer", "pepper"], .init(251, 10, 64, 3.3)),
        Entry(["Zimt", "cinnamon"], .init(247, 4.0, 81, 1.2)),
        Entry(["Kreuzkümmel", "Kreuzkuemmel", "Kümmel", "cumin"], .init(375, 18, 44, 22)),
        Entry(["Muskat", "Muskatnuss", "nutmeg"], .init(525, 5.8, 49, 36)),
        Entry(["Lorbeer", "Lorbeerblatt", "bay leaf"], .init(313, 7.6, 75, 8.4)),
    ]

    // MARK: - Lookup

    /// Exact normalized alias → facts. Covers the overwhelming majority of
    /// lookups without any scanning.
    private static let exactIndex: [String: NutritionFacts] = {
        var index: [String: NutritionFacts] = [:]
        for entry in entries {
            for name in entry.names {
                let key = Ingredient.normalize(name)
                guard !key.isEmpty else { continue }
                // First entry wins, so a later generic alias ("Öl") can never
                // take a key a specific one ("Olivenöl") already claimed.
                if index[key] == nil { index[key] = entry.facts }
            }
        }
        return index
    }()

    /// Aliases long enough to be safe as substrings, longest first so
    /// "olivenöl" is tried before "öl" and "hähnchenbrust" before "hähnchen".
    private static let substringAliases: [(key: String, facts: NutritionFacts)] = {
        var pairs: [(String, NutritionFacts)] = []
        var seen: Set<String> = []
        for entry in entries {
            for name in entry.names {
                let key = Ingredient.normalize(name)
                guard key.count >= 4, seen.insert(key).inserted else { continue }
                pairs.append((key, entry.facts))
            }
        }
        return pairs.sorted { $0.0.count > $1.0.count }
    }()

    /// Facts per 100 g for an ingredient name, or `nil` when the table has
    /// nothing that means the same thing.
    ///
    /// Three passes, narrowing: the whole normalized name, then any single word
    /// in it ("Gehackte Tomaten" → "tomaten"), then a substring for aliases of
    /// four characters or more. Short aliases never match as substrings,
    /// because "Reis" contains "ei" and "Zwiebel" contains "ie" — a rule worth
    /// stating out loud, since the obvious `contains` version silently makes
    /// rice into eggs.
    static func facts(for rawName: String) -> NutritionFacts? {
        let normalized = Ingredient.normalize(rawName)
        guard !normalized.isEmpty else { return nil }

        if let hit = cached(normalized) { return hit.facts }
        return nil
    }

    // MARK: - Resolution

    private struct Hit: Sendable { var facts: NutritionFacts }

    /// Resolved names, so a week of meal cards doesn't rescan the alias list
    /// for the same twenty ingredients on every redraw. `NSCache` would be
    /// overkill: the working set is a household's catalogue.
    nonisolated(unsafe) private static var resolutionCache: [String: Hit?] = [:]
    private static let cacheLock = NSLock()

    private static func cached(_ normalized: String) -> Hit? {
        cacheLock.lock()
        if let memo = resolutionCache[normalized] {
            cacheLock.unlock()
            return memo
        }
        cacheLock.unlock()

        let resolved = resolve(normalized)

        cacheLock.lock()
        // Bounded: a household that somehow types 5 000 distinct ingredient
        // names gets a fresh cache rather than an ever-growing one.
        if resolutionCache.count > 5_000 { resolutionCache.removeAll(keepingCapacity: true) }
        resolutionCache[normalized] = resolved
        cacheLock.unlock()
        return resolved
    }

    private static func resolve(_ normalized: String) -> Hit? {
        if let facts = exactIndex[normalized] { return Hit(facts: facts) }

        let words = normalized
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)

        // A whole word that is itself an alias. Longest word first, so
        // "rote bete" prefers "bete"-style specifics over a stray short word.
        for word in words.sorted(by: { $0.count > $1.count }) {
            if let facts = exactIndex[word] { return Hit(facts: facts) }
        }

        // Multi-word aliases ("passierte tomaten", "grune bohnen") that the
        // name contains, plus compounds ("Bio-Olivenöl", "Hähnchenbrustfilet").
        for alias in substringAliases where normalized.contains(alias.key) {
            return Hit(facts: alias.facts)
        }

        return nil
    }
}
