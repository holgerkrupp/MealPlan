import SwiftUI

@MainActor
struct ShoppingListRow: View {
    @Bindable var item: ShoppingListItem
    var onToggle: () -> Void

    var body: some View {
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
                }

                Spacer()

                if item.isManual {
                    Image(systemName: "hand.draw")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
