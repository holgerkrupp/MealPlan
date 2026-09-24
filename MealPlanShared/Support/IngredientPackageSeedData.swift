import Foundation

/// Modest, explicitly described examples of common retail sizes.
///
/// These are not legal or universal standards. The source note is kept with
/// every definition so the settings screen can make that distinction clear.
enum IngredientPackageSeedData {
    static let sourceVersion = "2026-09"
    static let sourceNote = "Bundled typical retail size; not an official standard"

    static let all: [PackageSizeDefinition] = {
        let markets = ["DE", "AT", "CH", "UK", "US"]
        var result: [PackageSizeDefinition] = []

        func add(
            _ id: String, _ name: String, _ quantity: Quantity,
            _ container: PackageContainerType, markets marketCodes: [String] = markets,
            priority: PackageSizePriority = .common, preferredIn: Set<String> = []
        ) {
            for market in marketCodes {
                result.append(PackageSizeDefinition(
                    id: "\(market)-\(id)", ingredientName: name, countryCode: market,
                    quantity: quantity, containerType: container, priority: priority,
                    sourceNote: sourceNote, sourceVersion: sourceVersion,
                    isPreferred: preferredIn.contains(market)
                ))
            }
        }

        add("tomatoes-400g", "Tomaten, gehackt", .grams(400), .can, preferredIn: ["DE", "AT", "CH", "UK"])
        add("tomatoes-800g", "Tomaten, gehackt", .grams(800), .can, priority: .alternative)
        add("tomatoes-400g-us", "Tomatoes, chopped", .grams(400), .can, markets: ["US"])
        add("tomato-paste-70g", "Tomatenmark", .grams(70), .tube, markets: ["DE", "AT", "CH"])
        add("tomato-paste-140g", "Tomatenmark", .grams(140), .tube, markets: ["DE", "AT", "CH"], priority: .alternative)
        add("coconut-milk-400ml", "Kokosmilch", .millilitres(400), .can, preferredIn: ["DE", "AT", "CH", "UK"])
        add("beans-400g", "Bohnen", .grams(400), .can, priority: .common)
        add("chickpeas-400g", "Kichererbsen", .grams(400), .can)
        add("lentils-400g", "Linsen", .grams(400), .can)
        add("cream-200ml", "Sahne", .millilitres(200), .carton, preferredIn: ["DE", "AT", "CH"])
        add("creme-fraiche-200g", "Crème fraîche", .grams(200), .tub, markets: ["DE", "AT", "CH", "UK"])
        add("sour-cream-200g", "Sour cream", .grams(200), .tub, markets: ["US"])
        add("yoghurt-500g", "Joghurt", .grams(500), .tub, preferredIn: ["DE", "AT", "CH"])
        add("butter-250g", "Butter", .grams(250), .pack, preferredIn: ["DE", "AT", "CH", "UK"])
        add("butter-454g", "Butter", .grams(454), .pack, markets: ["US"], priority: .common)
        add("mozzarella-125g", "Mozzarella", .grams(125), .pack)
        add("feta-200g", "Feta", .grams(200), .pack)
        add("pasta-500g", "Nudeln", .grams(500), .bag, preferredIn: ["DE", "AT", "CH", "UK"])
        add("rice-500g", "Reis", .grams(500), .bag)
        add("stock-1l", "Brühe", .millilitres(1000), .carton)
        add("tortillas-8", "Tortillas", .pieces(8), .bag)
        return result
    }()
}
