import Foundation
import SwiftData

/// Gives a placeholder to dishes that don't have one yet — those created
/// before placeholders existed, or imported from a page with no usable image.
/// Only touches dishes the user hasn't decided about themselves.
enum DishGlyphMaintenance {

    @MainActor
    static func run(context: ModelContext) {
        let predicate = #Predicate<Dish> { $0.glyphRaw == nil && $0.glyphIsAuto }
        guard let dishes = try? context.fetch(FetchDescriptor<Dish>(predicate: predicate)),
              !dishes.isEmpty else { return }
        for dish in dishes {
            dish.refreshAutoGlyph()
        }
        try? context.save()
    }
}
