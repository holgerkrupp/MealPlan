import Foundation
import UniformTypeIdentifiers

/// The file types MealPlan can read recipes from.
///
/// Paprika's real exported identifiers are `com.hindsightlabs.paprika.files.*`
/// — the vendor prefix is the company, not the app. MealPlan used to declare a
/// made-up `com.paprika.recipes` instead, which no Paprika item ever registers,
/// so neither the share sheet nor "Open with" ever offered MealPlan. The wrong
/// identifier is kept only as a legacy alias for archives already on disk.
enum RecipeFileType {

    static let paprikaMultipleIdentifier = "com.hindsightlabs.paprika.files.recipes"
    static let paprikaSingleIdentifier = "com.hindsightlabs.paprika.files.recipe"
    /// Historical MealPlan-invented identifier. Matched, never advertised.
    static let paprikaLegacyIdentifier = "com.paprika.recipes"
    static let mealPlanIdentifier = "de.holgerkrupp.mealplan.recipes"

    static let paprikaIdentifiers = [
        paprikaMultipleIdentifier, paprikaSingleIdentifier, paprikaLegacyIdentifier
    ]

    static let paprikaExtensions = ["paprikarecipes", "paprikarecipe"]
    static let mealPlanExtension = "mealplanrecipes"

    static var allExtensions: [String] { paprikaExtensions + [mealPlanExtension] }

    /// Content types offered by the in-app file picker. Falls back to the
    /// filename extension whenever Paprika isn't installed to declare the type
    /// for us, and always includes `.data` so a `.paprikarecipes` file that
    /// arrived over AirDrop or e-mail is still selectable.
    static var importableContentTypes: [UTType] {
        var types = paprikaIdentifiers.compactMap { UTType($0) }
        types += paprikaExtensions.compactMap { UTType(filenameExtension: $0) }
        if let mealPlan = UTType(mealPlanIdentifier) { types.append(mealPlan) }
        types.append(.data)
        var seen = Set<String>()
        return types.filter { seen.insert($0.identifier).inserted }
    }

    /// True when a file at this URL is one MealPlan knows how to import.
    static func isImportable(_ url: URL) -> Bool {
        allExtensions.contains(url.pathExtension.lowercased())
    }

    static func isMealPlanArchive(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == mealPlanExtension
    }
}
