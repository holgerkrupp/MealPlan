import SwiftUI
import SwiftData

@MainActor
struct ShoppingListRow: View {
    @Bindable var item: ShoppingListItem
    var onToggle: () -> Void
    var onCategoryChange: (IngredientCategory) -> Void
    var onCustomAisle: () -> Void
    var onMarkStaple: () -> Void

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

            if item.isManual {
                Image(systemName: "hand.draw")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
                if !item.isManual, item.ingredient != nil {
                    Button(action: onMarkStaple) {
                        Label(String(localized: "Usually have this"), systemImage: "shippingbox")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    List {
        ShoppingListRow(
            item: PreviewData.shoppingItem,
            onToggle: {},
            onCategoryChange: { _ in },
            onCustomAisle: {},
            onMarkStaple: {}
        )
        ShoppingListRow(
            item: PreviewData.checkedShoppingItem,
            onToggle: {},
            onCategoryChange: { _ in },
            onCustomAisle: {},
            onMarkStaple: {}
        )
    }
    .modelContainer(PreviewData.container)
}
