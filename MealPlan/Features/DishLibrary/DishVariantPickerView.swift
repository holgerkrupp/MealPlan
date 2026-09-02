import SwiftUI
import SwiftData

/// Picks a dish to group with this one as variants — for the burgers and
/// bolognese that were already in the library separately before variants
/// existed, or that arrived under names too different to match automatically.
@MainActor
struct DishVariantPickerView: View {
    let dish: Dish

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Dish.name) private var allDishes: [Dish]

    @State private var searchText = ""

    private var candidates: [Dish] {
        let existingGroup = dish.variantGroupID
        let available = allDishes.filter { candidate in
            candidate !== dish
                && (existingGroup == nil || candidate.variantGroupID != existingGroup)
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return suggestionsFirst(available) }
        return available.filter { $0.searchableText.localizedStandardContains(query) }
    }

    /// Dishes whose names share a trailing word with this one lead the list:
    /// "Halloumi Burger" is what you're looking for when you opened this from
    /// "Smash Burger".
    private func suggestionsFirst(_ dishes: [Dish]) -> [Dish] {
        let mine = DishVariants.sharedName(dish.name, dish.name)
        return dishes.sorted { lhs, rhs in
            let left = DishVariants.sharedName(dish.name, lhs.name)
            let right = DishVariants.sharedName(dish.name, rhs.name)
            let leftScore = left == mine ? 0 : left.count
            let rightScore = right == mine ? 0 : right.count
            if leftScore != rightScore { return leftScore > rightScore }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(candidates) { candidate in
                    Button {
                        group(with: candidate)
                    } label: {
                        HStack(spacing: 12) {
                            DishThumbnail(dish: candidate, size: 44, cornerRadius: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.name)
                                if let group = candidate.variantGroupName, candidate.isVariant {
                                    Text(String(localized: "In the “\(group)” group"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("Both recipes stay separate — they're only shown together, so you can pick the one you feel like cooking.")
            }
        }
        .searchable(text: $searchText, prompt: String(localized: "Search dishes"))
        .navigationTitle(String(localized: "Group as variants"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay {
            if candidates.isEmpty {
                ContentUnavailableView(
                    String(localized: "No other dishes"),
                    systemImage: "square.on.square.dashed",
                    description: Text("Add another recipe first, then group the two as variants.")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel")) { dismiss() }
            }
        }
    }

    private func group(with other: Dish) {
        DishVariants.join(dish, with: other, in: allDishes)
        try? context.save()
        dismiss()
    }
}

#Preview {
    DishVariantPickerView(dish: PreviewData.richDish)
        .modelContainer(PreviewData.container)
}
