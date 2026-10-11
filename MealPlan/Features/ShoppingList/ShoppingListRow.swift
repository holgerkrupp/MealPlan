import SwiftUI
import SwiftData

struct ShoppingListRowSnapshot: Identifiable, Equatable {
    let id: UUID
    let name: String
    let displayText: String?
    let sourceDishNames: [String]
    let isChecked: Bool
    let isManual: Bool
    let isStaple: Bool
    let category: IngredientCategory
    let aisleName: String
    let sortIndex: Int

    @MainActor
    init(_ item: ShoppingListItem) {
        id = item.uuid
        name = item.name
        displayText = item.displayText
        sourceDishNames = item.sourceDishNames
        isChecked = item.isChecked
        isManual = item.isManual
        isStaple = item.ingredient?.isPantryStaple == true
        category = item.category
        aisleName = item.aisleName
        sortIndex = item.sortIndex
    }
}

struct ShoppingListRowGroup: Identifiable {
    let name: String
    let sortOrder: Int
    let items: [ShoppingListRowSnapshot]

    var id: String { name }
}

@MainActor
struct ShoppingListRow: View {
    let snapshot: ShoppingListRowSnapshot
    var onToggle: () -> Void
    var onCategoryChange: (IngredientCategory) -> Void
    var onCustomAisle: () -> Void
    /// Make this line's ingredient a household staple, or stop it being one.
    var onSetStaple: (Bool) -> Void
    var onMarkOwned: () -> Void

    private var isStaple: Bool { snapshot.isStaple }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    Image(systemName: snapshot.isChecked ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(snapshot.isChecked ? .green : .secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.name)
                            .strikethrough(snapshot.isChecked)
                            .foregroundStyle(snapshot.isChecked ? .secondary : .primary)
                        if let amount = snapshot.displayText, !amount.isEmpty {
                            Text(amount)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !snapshot.sourceDishNames.isEmpty {
                            Text(snapshot.sourceDishNames.joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(snapshot.isChecked
                ? String(localized: "Checked off")
                : String(localized: "Not checked off"))
            .accessibilityAddTraits(snapshot.isChecked ? .isSelected : [])
            .accessibilityHint(InteractionWording.checkOffHint)

            if isStaple {
                Image(systemName: "shippingbox")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(String(localized: "Pantry staple"))
            } else if snapshot.isManual {
                Image(systemName: "hand.draw")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(String(localized: "Added by hand"))
            }
            Menu {
                Picker(String(localized: "Aisle"), selection: Binding(
                    get: { snapshot.category }, set: { onCategoryChange($0) }
                )) {
                    ForEach(IngredientCategory.allCases) { category in
                        Label(category.localizedName, systemImage: category.symbolName).tag(category)
                    }
                }
                Button(action: onCustomAisle) {
                    Label(String(localized: "Custom aisle…"), systemImage: "text.badge.plus")
                }
                Divider()
                Button(action: onMarkOwned) {
                    Label(String(localized: "Already have this"), systemImage: "checkmark.seal")
                }
                if isStaple {
                    Button {
                        onSetStaple(false)
                    } label: {
                        Label(String(localized: "Not a staple"), systemImage: "minus.circle")
                    }
                } else {
                    Button {
                        onSetStaple(true)
                    } label: {
                        Label(String(localized: "Usually have this"), systemImage: "shippingbox")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Change the aisle, or mark as a pantry staple"))
            .accessibilityLabel(String(localized: "Options for \(snapshot.name)"))
        }
    }

    private var accessibilityLabel: String {
        var parts = [snapshot.name]
        if let amount = snapshot.displayText, !amount.isEmpty { parts.append(amount) }
        if isStaple { parts.append(String(localized: "Pantry staple")) }
        return parts.joined(separator: ", ")
    }
}

#Preview {
    List {
        ShoppingListRow(
            snapshot: ShoppingListRowSnapshot(PreviewData.shoppingItem),
            onToggle: {},
            onCategoryChange: { _ in },
            onCustomAisle: {},
            onSetStaple: { _ in },
            onMarkOwned: {}
        )
        ShoppingListRow(
            snapshot: ShoppingListRowSnapshot(PreviewData.checkedShoppingItem),
            onToggle: {},
            onCategoryChange: { _ in },
            onCustomAisle: {},
            onSetStaple: { _ in },
            onMarkOwned: {}
        )
    }
    .modelContainer(PreviewData.container)
}
