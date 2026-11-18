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
struct DishLibraryCell: View, Equatable {
    /// Scalar-only card content. Mutations and navigation re-resolve the dish
    /// by UUID in the active household's context.
    let snapshot: DishLibraryCardSnapshot
    /// Set when the cell represents a whole variant group.
    var group: DishVariantGroupRef? = nil
    var variantCount: Int = 0
    /// Guests can rearrange nothing, so they get no drop target.
    var acceptsDrops: Bool = true
    /// Used only if a recipe is dropped on this cell. Keeping the complete
    /// library out of every cell avoids invalidating every visible cell when
    /// another page is loaded.
    let householdID: UUID?

    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    @State private var isTargeted = false

    init(
        snapshot: DishLibraryCardSnapshot,
        group: DishVariantGroupRef? = nil,
        variantCount: Int = 0,
        acceptsDrops: Bool = true,
        householdID: UUID?
    ) {
        self.snapshot = snapshot
        self.group = group
        self.variantCount = variantCount
        self.acceptsDrops = acceptsDrops
        self.householdID = householdID
    }

    static func == (lhs: DishLibraryCell, rhs: DishLibraryCell) -> Bool {
        lhs.snapshot == rhs.snapshot
            && lhs.group == rhs.group
            && lhs.variantCount == rhs.variantCount
            && lhs.acceptsDrops == rhs.acceptsDrops
            && lhs.householdID == rhs.householdID
    }

    var body: some View {
        content
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .scaleEffect(isTargeted && !reduceMotion ? 1.04 : 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isTargeted)
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
                DishGridCell(snapshot: snapshot, variantGroupName: group.name)
            }
            .buttonStyle(.plain)
        } else {
            #if os(macOS)
            DishGridCell(snapshot: snapshot)
                .onTapGesture {
                    openWindow(value: DetailWindowRoute.recipe(snapshot.id))
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    openWindow(value: DetailWindowRoute.recipe(snapshot.id))
                }
                .draggable(DishReference(dishUUID: snapshot.id, name: snapshot.name))
            #else
            NavigationLink(value: DishLibraryRecipeRoute(householdID: householdID, dishID: snapshot.id)) {
                DishGridCell(snapshot: snapshot)
            }
            .buttonStyle(.plain)
            .draggable(DishReference(dishUUID: snapshot.id, name: snapshot.name))
            // An iPad in Stage Manager can hold the recipe beside the
            // library; on iPhone this modifier adds nothing at all.
            .openInNewWindowContextMenu(.recipe(snapshot.id))
            #endif
        }
    }

    private var accessibilityLabel: String {
        if let group {
            return String(localized: "\(group.name), \(variantCount) variants")
        }
        return snapshot.name
    }

    /// Adds every dropped recipe to this cell's group, creating the group from
    /// this cell's own dish when there isn't one yet.
    private func joinVariants(_ references: [DishReference]) -> Bool {
        guard let householdID,
              let target = fetchDish(snapshot.id, householdID: householdID)
        else { return false }

        var affected: [UUID: Dish] = [target.uuid: target]
        if let targetGroupID = target.variantGroupID {
            for member in fetchGroup(targetGroupID, householdID: householdID) {
                affected[member.uuid] = member
            }
        }

        let dropped = references.compactMap { fetchDish($0.dishUUID, householdID: householdID) }
        for candidate in dropped where candidate.variantGroupID != target.variantGroupID {
            affected[candidate.uuid] = candidate
            if let sourceGroupID = candidate.variantGroupID {
                for member in fetchGroup(sourceGroupID, householdID: householdID) {
                    affected[member.uuid] = member
                }
            }
        }

        let library = Array(affected.values)
        var joined = false
        for candidate in dropped {
            // Dropping a recipe on itself, or back onto the group it is
            // already in, is a no-op rather than an error.
            guard candidate.persistentModelID != target.persistentModelID,
                  candidate.variantGroupID == nil || candidate.variantGroupID != target.variantGroupID
            else { continue }
            DishVariants.join(candidate, with: target, in: library)
            joined = true
        }
        guard joined else { return false }
        try? context.save()
        SharedStore.reloadWidgets()
        MealPlanTips.recordVariantsJoined()
        return true
    }

    private func fetchDish(_ uuid: UUID, householdID: UUID) -> Dish? {
        var descriptor = FetchDescriptor<Dish>(
            predicate: #Predicate { $0.uuid == uuid && $0.household?.uuid == householdID }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func fetchGroup(_ groupID: UUID, householdID: UUID) -> [Dish] {
        (try? context.fetch(FetchDescriptor<Dish>(
            predicate: #Predicate { $0.variantGroupID == groupID && $0.household?.uuid == householdID }
        ))) ?? []
    }
}

/// Navigation values carry only stable identity. The destination re-fetches
/// the model in the same household when it is opened.
struct DishLibraryRecipeRoute: Hashable {
    let householdID: UUID?
    let dishID: UUID
}

@MainActor
struct DishLibraryRecipeDestination: View {
    private let route: DishLibraryRecipeRoute
    @Query private var dishes: [Dish]

    init(route: DishLibraryRecipeRoute) {
        self.route = route
        let householdID = route.householdID ?? UUID()
        let dishID = route.dishID
        _dishes = Query(FetchDescriptor<Dish>(
            predicate: #Predicate { $0.uuid == dishID && $0.household?.uuid == householdID }
        ))
    }

    var body: some View {
        if let dish = dishes.first {
            DishDetailView(dish: dish)
        } else {
            ContentUnavailableView(
                String(localized: "Recipe unavailable"),
                systemImage: "fork.knife",
                description: Text("This recipe may have been removed or moved to another household.")
            )
        }
    }
}
