import Foundation
import SwiftData

/// A recipe site the household returns to. It opens in RecipeFinderView, so a
/// useful page is still one tap away from becoming a dish.
@Model
final class RecipeBookmark {
    var uuid: UUID = UUID()
    var modifiedAt: Date = Date.now
    var title: String = ""
    var urlString: String = ""
    var dateAdded: Date = Date.now
    var household: Household?

    init(title: String, url: URL) {
        self.title = title
        urlString = url.absoluteString
    }

    var url: URL? { URL(string: urlString) }
}
