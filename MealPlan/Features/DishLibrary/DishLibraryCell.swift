import SwiftUI
import SwiftData

/// One cell of the dish library grid, and the drop target that turns two
/// recipes into a group of variants.
///
/// Dropping a recipe onto another makes a group of the two; dropping one onto
/// a group that already exists adds it to that group. Each cell owns its own
/// `isTargeted` flag, which is why this is a view of its own rather than a
/// branch inside the grid's `ForEach`.
@MainActor
struct DishLibraryCell: View {
    /// The dish this cell shows, and — for a group — the one standing in for
    /// its members.
    let dish: Dish
    /// Set when the cell represents a whole variant group.
    var group: DishVariantGroupRef? = nil
    var variantCount: Int = 0
    /// Guests can rearrange nothing, so they get no drop target.
    var acceptsDrops: Bool = true
    /// The library, passed down rather than re-queried: a `@Query` here would
    /// run once per cell in the grid.
    let library: [Dish]

    @Environment(\.modelContext) private var context

    @State private var isTargeted = false

    var body: some View {
        content
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .scaleEffect(isTargeted ? 1.04 : 1)
            .animation(.snappy(duration: 0.18), value: isTargeted)
            .dropDestination(for: DishReference.self) { references, _ in
                guard acceptsDrops else { return false }
                return joinVariants(references)
            } isTargeted: { targeted in
                isTargeted = targeted && acceptsDrops
            }
            .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var content: some View {
        if let group {
            NavigationLink(value: group) {
                DishGridCell(dish: dish, variantGroupName: group.name, variantCount: variantCount)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: dish) {
                DishGridCell(dish: dish)
            }
            .buttonStyle(.plain)
            .draggable(DishReference(dishUUID: dish.uuid, name: dish.name))
        }
    }

    private var accessibilityLabel: String {
        if let group {
            return String(localized: "\(group.name), \(variantCount) variants")
        }
        return dish.name
    }

    /// Adds every dropped recipe to this cell's group, creating the group from
    /// this cell's own dish when there isn't one yet.
    private func joinVariants(_ references: [DishReference]) -> Bool {
        let dropped = references.compactMap { reference in
            library.first { $0.uuid == reference.dishUUID }
        }
        var joined = false
        for candidate in dropped {
            // Dropping a recipe on itself, or back onto the group it is
            // already in, is a no-op rather than an error.
            guard candidate !== dish,
                  candidate.variantGroupID == nil || candidate.variantGroupID != dish.variantGroupID
            else { continue }
            DishVariants.join(candidate, with: dish, in: library)
            joined = true
        }
        guard joined else { return false }
        try? context.save()
        SharedStore.reloadWidgets()
        return true
    }
}
