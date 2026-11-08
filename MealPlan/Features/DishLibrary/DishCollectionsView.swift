import SwiftUI

/// A collection and how many dishes are in it, for the browser below.
struct DishCollectionSummary: Hashable, Identifiable, Sendable {
    var name: String
    var count: Int
    var id: String { DishTag.normalize(name) }
}

/// The household's collections ("cookbooks"): pick one to browse it in the
/// library, or rename, delete and start new ones.
///
/// A collection exists while a dish is in it (see `DishCollection`), so a new
/// one is started by naming it and then picking its dishes in the library.
@MainActor
struct DishCollectionsView: View {
    var collections: [DishCollectionSummary]
    var selected: String?
    var canEdit: Bool
    var onSelect: (String?) -> Void
    var onCreate: (String) -> Void
    var onRename: (String, String) -> Void
    var onDelete: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var naming = false
    @State private var newName = ""
    @State private var renaming: DishCollectionSummary?
    @State private var deleting: DishCollectionSummary?

    var body: some View {
        List {
            if collections.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No collections yet"), systemImage: "books.vertical")
                } description: {
                    Text("Collections gather dishes like a cookbook — “Weeknight”, “Christmas baking”, “From Grandma”. A dish can be in several.")
                } actions: {
                    if canEdit {
                        Button(String(localized: "New collection")) { startNaming() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                Section {
                    Button {
                        onSelect(nil)
                        dismiss()
                    } label: {
                        row(String(localized: "All dishes"), count: nil, isOn: selected == nil, systemImage: "square.grid.2x2")
                    }
                    .buttonStyle(.plain)
                }
                Section {
                    ForEach(collections) { collection in
                        Button {
                            onSelect(collection.name)
                            dismiss()
                        } label: {
                            row(
                                collection.name,
                                count: collection.count,
                                isOn: selected.map { DishTag.areSame($0, collection.name) } ?? false,
                                systemImage: "books.vertical"
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu { if canEdit { editActions(collection) } }
                        .swipeActions(edge: .trailing) { if canEdit { editActions(collection) } }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Collections"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 360)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Done")) { dismiss() }
            }
            if canEdit && !collections.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(String(localized: "New collection"), systemImage: "plus") { startNaming() }
                }
            }
        }
        .alert(String(localized: "New collection"), isPresented: $naming) {
            TextField(String(localized: "Name"), text: $newName)
            Button(String(localized: "Choose dishes")) {
                let name = DishTag.clean(newName)
                guard !name.isEmpty else { return }
                onCreate(name)
                dismiss()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("Next, pick the dishes that belong in it.")
        }
        .alert(
            String(localized: "Rename collection"),
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
        ) {
            TextField(String(localized: "Name"), text: $newName)
            Button(String(localized: "Rename")) {
                if let renaming, !DishTag.clean(newName).isEmpty {
                    onRename(renaming.name, newName)
                }
                renaming = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            String(localized: "Delete this collection?"),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { collection in
            Button(String(localized: "Delete collection"), role: .destructive) {
                onDelete(collection.name)
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { _ in
            Text("The dishes stay in your library; only the collection is removed.")
        }
    }

    @ViewBuilder
    private func editActions(_ collection: DishCollectionSummary) -> some View {
        Button(String(localized: "Delete"), systemImage: "trash", role: .destructive) {
            deleting = collection
        }
        Button(String(localized: "Rename"), systemImage: "pencil") {
            newName = collection.name
            renaming = collection
        }
    }

    private func row(_ title: String, count: Int?, isOn: Bool, systemImage: String) -> some View {
        HStack {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: systemImage)
            }
            Spacer()
            if let count {
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if isOn {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private func startNaming() {
        newName = ""
        naming = true
    }
}

/// A library cell while dishes are being picked for a bulk change: tapping
/// selects instead of opening the recipe.
@MainActor
struct DishSelectionCell: View {
    let dish: Dish
    var variantGroupName: String?
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            DishGridCell(dish: dish, variantGroupName: variantGroupName)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary),
                                         isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.regularMaterial))
                        .padding(10)
                }
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(variantGroupName ?? dish.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The library's multi-selection: dishes keyed by UUID so a selection can
/// span pages. A variant group's cell selects (or deselects) all its members.
enum DishSelection {
    static func isSelected(_ dishes: [Dish], in selection: [UUID: Dish]) -> Bool {
        !dishes.isEmpty && dishes.allSatisfy { selection[$0.uuid] != nil }
    }

    static func toggle(_ dishes: [Dish], in selection: inout [UUID: Dish]) {
        if isSelected(dishes, in: selection) {
            for dish in dishes { selection[dish.uuid] = nil }
        } else {
            for dish in dishes { selection[dish.uuid] = dish }
        }
    }
}
