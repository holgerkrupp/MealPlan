import SwiftUI

/// The sort / filter menu for a dish list. Shared by the dish library and the
/// dish sidebar next to the plan, each of which keeps its own `DishFilter`.
/// Saved searches are shared between the two (they are the device's, see
/// `DishFilterPreset`).
@MainActor
struct DishFilterMenu: View {
    @Binding var filter: DishFilter
    var availableTags: [String] = []
    var availableCollections: [String] = []

    @AppStorage(DishFilterPresetStore.defaultsKey) private var presetData = Data()
    @State private var namingPreset = false
    @State private var presetName = ""
    @State private var managingPresets = false

    private var presets: [DishFilterPreset] {
        DishFilterPresetStore.sorted(DishFilterPresetStore.decode(presetData))
    }

    /// Worth saving once anything narrows the list or the order isn't the default.
    private var canSavePreset: Bool {
        filter.isActive
            || filter.sort != .alphabetical
            || !filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Menu {
            savedSearchesMenu

            Picker(String(localized: "Sort by"), selection: $filter.sort) {
                Section {
                    ForEach(DishFilter.Sort.allCases.filter { !$0.isRecipeMetric }) { Text($0.localizedName).tag($0) }
                }
                Section {
                    ForEach(DishFilter.Sort.allCases.filter(\.isRecipeMetric)) { Text($0.localizedName).tag($0) }
                }
            }

            Divider()

            Toggle(String(localized: "Favorites only"), isOn: $filter.favoritesOnly)

            Menu(String(localized: "Rating")) {
                Button(String(localized: "Any")) { filter.minimumRating = nil }
                ForEach(1...5, id: \.self) { rating in
                    Button(String(repeating: "★", count: rating)) { filter.minimumRating = rating }
                }
            }

            if !availableCollections.isEmpty || filter.collection != nil {
                Menu(String(localized: "Collection")) {
                    Button(String(localized: "Any")) { filter.collection = nil }
                    Divider()
                    ForEach(availableCollections, id: \.self) { name in
                        Toggle(isOn: Binding(
                            get: { filter.isSelected(collection: name) },
                            set: { filter.collection = $0 ? name : nil }
                        )) {
                            Text(verbatim: name)
                        }
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
        .alert(String(localized: "Save search"), isPresented: $namingPreset) {
            TextField(String(localized: "Name"), text: $presetName)
            Button(String(localized: "Save")) { savePreset() }
                .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("Keeps the current search, filters and sort order on this device so you can apply them again with one tap.")
        }
        .sheet(isPresented: $managingPresets) {
            NavigationStack {
                DishFilterPresetsView(presetData: $presetData)
            }
            .dismissesOnOutsideClick()
        }
    }

    @ViewBuilder
    private var savedSearchesMenu: some View {
        Menu {
            ForEach(presets) { preset in
                Toggle(isOn: Binding(
                    get: { filter == preset.filter },
                    set: { _ in filter = preset.filter }
                )) {
                    Text(verbatim: preset.name)
                }
            }
            if !presets.isEmpty { Divider() }
            Button(String(localized: "Save current search…"), systemImage: "plus") {
                presetName = ""
                namingPreset = true
            }
            .disabled(!canSavePreset)
            if !presets.isEmpty {
                Button(String(localized: "Edit saved searches…"), systemImage: "pencil") {
                    managingPresets = true
                }
            }
        } label: {
            Label(String(localized: "Saved searches"), systemImage: "bookmark")
        }
        Divider()
    }

    private func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var all = DishFilterPresetStore.decode(presetData)
        // Saving under a name that already exists updates that search rather
        // than adding a second one nobody can tell apart.
        if let index = all.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            all[index].filter = filter
        } else {
            all.append(DishFilterPreset(name: name, filter: filter))
        }
        presetData = DishFilterPresetStore.encode(all)
    }
}

/// Renames and deletes the device's saved searches.
@MainActor
struct DishFilterPresetsView: View {
    @Binding var presetData: Data
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: DishFilterPreset?
    @State private var newName = ""

    private var presets: [DishFilterPreset] {
        DishFilterPresetStore.sorted(DishFilterPresetStore.decode(presetData))
    }

    var body: some View {
        List {
            if presets.isEmpty {
                ContentUnavailableView(
                    String(localized: "No saved searches"),
                    systemImage: "bookmark",
                    description: Text("Save a search from the filter menu to find it here.")
                )
            }
            ForEach(presets) { preset in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: preset.name)
                        Text(preset.filter.sort.localizedName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(String(localized: "Rename"), systemImage: "pencil") {
                        newName = preset.name
                        renaming = preset
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    Button(String(localized: "Delete"), systemImage: "trash", role: .destructive) {
                        delete(preset)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }
            .onDelete { offsets in
                let current = presets
                offsets.map { current[$0] }.forEach(delete)
            }
        }
        .navigationTitle(String(localized: "Saved searches"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 280)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Done")) { dismiss() }
            }
        }
        .alert(
            String(localized: "Rename saved search"),
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
        ) {
            TextField(String(localized: "Name"), text: $newName)
            Button(String(localized: "Rename")) { rename() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
    }

    private func delete(_ preset: DishFilterPreset) {
        presetData = DishFilterPresetStore.encode(
            DishFilterPresetStore.decode(presetData).filter { $0.id != preset.id }
        )
    }

    private func rename() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let preset = renaming, !name.isEmpty else { return }
        var all = DishFilterPresetStore.decode(presetData)
        if let index = all.firstIndex(where: { $0.id == preset.id }) {
            all[index].name = name
            presetData = DishFilterPresetStore.encode(all)
        }
        renaming = nil
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
                availableTags: ["vegan", "schnell", "Ofen"],
                availableCollections: ["Weeknight", "Christmas"]
            )
        }
    }
}
