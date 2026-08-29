import Foundation
import SwiftData

/// One picture attached to a dish. Stored outside the main database file so
/// large photos don't bloat sync payloads.
@Model
final class DishImage {
    @Attribute(.externalStorage) var data: Data?
    var sortIndex: Int = 0
    var isPrimary: Bool = false
    var dateAdded: Date = Date.now

    var dish: Dish?

    init(data: Data?, sortIndex: Int = 0, isPrimary: Bool = false) {
        self.data = data
        self.sortIndex = sortIndex
        self.isPrimary = isPrimary
        self.dateAdded = .now
    }
}
