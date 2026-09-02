import SwiftUI

/// The sort / filter menu for a dish list. Shared by the dish library and the
/// dish sidebar next to the plan, each of which keeps its own `DishFilter`.
@MainActor
struct DishFilterMenu: View {
    @Binding var filter: DishFilter
    var availableCollections: [String] = []
    var availableTags: [String] = []

    var body: some View {
        Menu {
            Picker(String(localized: "Sort by"), selection: $filter.sort) {
                ForEach(DishFilter.Sort.allCases) { Text($0.localizedName).tag($0) }
            }

            Divider()

            Toggle(String(localized: "Favorites only"), isOn: $filter.favoritesOnly)

            Menu(String(localized: "Rating")) {
                Button(String(localized: "Any")) { filter.minimumRating = nil }
                ForEach(1...5, id: \.self) { rating in
                    Button(String(repeating: "★", count: rating)) { filter.minimumRating = rating }
                }
            }

            if !availableCollections.isEmpty {
                Menu(String(localized: "Collection")) {
                    Button(String(localized: "Any")) { filter.collection = nil }
                    ForEach(availableCollections, id: \.self) { name in
                        Button(name) { filter.collection = name }
                    }
                }
            }

            if !availableTags.isEmpty {
                Menu(String(localized: "Tags")) {
                    if !filter.tags.isEmpty {
                        Button(String(localized: "Any tag")) { filter.tags = [] }
                        Divider()
                    }
                    ForEach(availableTags, id: \.self) { tag in
                        Toggle(isOn: Binding(
                            get: { filter.isSelected(tag: tag) },
                            set: { _ in filter.toggle(tag: tag) }
                        )) {
                            // Verbatim: a tag is whatever the household typed,
                            // not a localization key.
                            Text(verbatim: tag)
                        }
                    }
                }
            }

            Menu(String(localized: "Meal type")) {
                Button(String(localized: "Any")) { filter.mealType = nil }
                ForEach(MealTypeTag.allCases) { tag in
                    Toggle(tag.localizedName, isOn: Binding(
                        get: { filter.mealType == tag },
                        set: { filter.mealType = $0 ? tag : nil }
                    ))
                }
            }

            Menu(String(localized: "Diet")) {
                ForEach(DietaryTag.allCases) { tag in
                    Toggle(tag.localizedName, isOn: Binding(
                        get: { filter.dietary.contains(tag) },
                        set: { isOn in
                            if isOn { filter.dietary.insert(tag) }
                            else { filter.dietary.remove(tag) }
                        }
                    ))
                }
            }

            Menu(String(localized: "Max. time")) {
                Button(String(localized: "Any")) { filter.maxMinutes = nil }
                ForEach([15, 30, 45, 60], id: \.self) { minutes in
                    Button("≤ \(minutes) min") { filter.maxMinutes = minutes }
                }
            }

            Menu(String(localized: "Not cooked in")) {
                Button(String(localized: "Any")) { filter.notCookedWithinDays = nil }
                ForEach([30, 60, 90], id: \.self) { days in
                    Button(String(localized: "\(days) days or more")) {
                        filter.notCookedWithinDays = days
                    }
                }
            }

            if filter.isActive {
                Divider()
                Button(String(localized: "Clear filters"), role: .destructive) {
                    let sort = filter.sort
                    let search = filter.searchText
                    filter = DishFilter()
                    filter.sort = sort
                    filter.searchText = search
                }
            }
        } label: {
            Label(
                String(localized: "Filter"),
                systemImage: filter.isActive
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
    }
}

#Preview {
    @Previewable @State var filter = DishFilter()
    NavigationStack {
        List {
            LabeledContent(String(localized: "Sort by"), value: filter.sort.localizedName)
            LabeledContent(String(localized: "Tags"), value: DishTag.sorted(Array(filter.tags)).joined(separator: ", "))
        }
        .toolbar {
            DishFilterMenu(
                filter: $filter,
                availableCollections: ["Weeknight", "Weihnachten"],
                availableTags: ["vegan", "schnell", "Ofen"]
            )
        }
    }
}
