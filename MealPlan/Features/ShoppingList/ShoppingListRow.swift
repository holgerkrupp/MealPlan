import SwiftUI
import SwiftData

@MainActor
struct ShoppingListRow: View {
    @Bindable var item: ShoppingListItem
    var onToggle: () -> Void
    var onCategoryChange: (IngredientCategory) -> Void
    var onCustomAisle: () -> Void
    /// Make this line's ingredient a household staple, or stop it being one.
    var onSetStaple: (Bool) -> Void

    private var isStaple: Bool { item.ingredient?.isPantryStaple == true }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(item.isChecked ? .green : .secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .strikethrough(item.isChecked)
                            .foregroundStyle(item.isChecked ? .secondary : .primary)
                        if let amount = item.displayText, !amount.isEmpty {
                            Text(amount)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !item.sourceDishNames.isEmpty {
                            Text(item.sourceDishNames.joined(separator: ", "))
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
            .accessibilityValue(item.isChecked
                ? String(localized: "Checked off")
                : String(localized: "Not checked off"))
            .accessibilityAddTraits(item.isChecked ? .isSelected : [])
            .accessibilityHint(String(localized: "Double tap to check off"))

            if isStaple {
                Image(systemName: "shippingbox")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(String(localized: "Pantry staple"))
            } else if item.isManual {
                Image(systemName: "hand.draw")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(String(localized: "Added by hand"))
            }
            Menu {
                Picker(String(localized: "Aisle"), selection: Binding(
                    get: { item.category }, set: { onCategoryChange($0) }
                )) {
                    ForEach(IngredientCategory.allCases) { category in
                        Label(category.localizedName, systemImage: category.symbolName).tag(category)
                    }
                }
                Button(action: onCustomAisle) {
                    Label(String(localized: "Custom aisle…"), systemImage: "text.badge.plus")
                }
                Divider()
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
            .accessibilityLabel(String(localized: "Options for \(item.name)"))
        }
    }

    private var accessibilityLabel: String {
        var parts = [item.name]
        if let amount = item.displayText, !amount.isEmpty { parts.append(amount) }
        if isStaple { parts.append(String(localized: "Pantry staple")) }
        return parts.joined(separator: ", ")
    }
}

#Preview {
    List {
        ShoppingListRow(
            item: PreviewData.shoppingItem,
            onToggle: {},
            onCategoryChange: { _ in },
            onCustomAisle: {},
            onSetStaple: { _ in }
        )
        ShoppingListRow(
            item: PreviewData.checkedShoppingItem,
            onToggle: {},
            onCategoryChange: { _ in },
            onCustomAisle: {},
            onSetStaple: { _ in }
        )
    }
    .modelContainer(PreviewData.container)
}
