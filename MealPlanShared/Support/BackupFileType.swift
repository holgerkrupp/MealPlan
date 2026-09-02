import Foundation
import UniformTypeIdentifiers

/// The whole-store backup file MealPlan writes from Settings → Data.
///
/// Deliberately *not* one of `RecipeFileType`'s importable types and not listed
/// in `CFBundleDocumentTypes`: restoring a backup replaces everything in the
/// store, which is far too destructive to happen because a file was opened
/// from Finder. The only way in is the picker on the data-transfer screen.
enum BackupFileType {

    static let identifier = "de.holgerkrupp.mealplan.backup"
    static let fileExtension = "mealplanbackup"

    /// Content types offered by the restore picker. The declared type resolves
    /// once the app is installed; `.json` and `.data` keep a backup selectable
    /// when it arrived over AirDrop or e-mail and lost its extension.
    static var importableContentTypes: [UTType] {
        var types: [UTType] = []
        if let declared = UTType(identifier) { types.append(declared) }
        if let byExtension = UTType(filenameExtension: fileExtension) { types.append(byExtension) }
        types += [.json, .data]
        var seen = Set<String>()
        return types.filter { seen.insert($0.identifier).inserted }
    }

    /// The type a saved backup is written as. Falls back to JSON where the
    /// declared type isn't registered (the test bundle, an extension).
    static var contentType: UTType {
        UTType(identifier) ?? .json
    }

    static func isBackup(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == fileExtension
    }
}
