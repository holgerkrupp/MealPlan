import SwiftUI

/// The shopping list, to be walked a shop with.
///
/// Grouped by aisle in the same order as the phone, so the two read as one
/// list. Ticking a line is instant — it is applied here and travels to the
/// phone afterwards, over a queue that survives being out of range.
struct WatchShoppingListView: View {

    @Environment(WatchDataStore.self) private var store
    @AppStorage("watch.shoppingList.hideChecked") private var hideChecked = false

    private var items: [WatchShoppingItem] { store.snapshot.shopping }

    private var visible: [WatchShoppingItem] {
        hideChecked ? items.filter { !$0.isChecked } : items
    }

    var body: some View {
        Group {
            if items.isEmpty {
                WatchEmptyState(
                    symbol: "cart",
                    title: String(localized: "Nothing to buy"),
                    message: String(localized: "Build your list on iPhone and it shows up here.")
                )
            } else {
                List {
                    Section {
                        WatchShoppingSummary(
                            remaining: items.remainingCount,
                            total: items.count,
                            rangeName: store.snapshot.shoppingRangeName
                        )
                    }

                    ForEach(visible.aisles) { aisle in
                        Section(aisle.name) {
                            ForEach(aisle.items) { item in
                                WatchShoppingRow(item: item) { store.toggle(item) }
                            }
                        }
                    }

                    if items.contains(where: \.isChecked) {
                        Section {
                            Toggle(String(localized: "Hide ticked items"), isOn: $hideChecked)
                                .font(.footnote)
                        }
                    }

                    WatchSyncFooter()
                }
            }
        }
        .navigationTitle(String(localized: "Shopping"))
    }
}

/// The line above the list: how much is left, and which days it was built for.
struct WatchShoppingSummary: View {

    var remaining: Int
    var total: Int
    var rangeName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(remaining == 0
                 ? String(localized: "All ticked off")
                 : String(localized: "\(remaining) of \(total) left"))
                .font(.headline)
            if let rangeName {
                Text(rangeName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
    }
}

/// One line. The whole row is the hit target — on a watch, aiming at a
/// checkbox is not a thing anyone can do while holding a basket.
struct WatchShoppingRow: View {

    var item: WatchShoppingItem
    var toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isChecked ? .green : .secondary)
                    .imageScale(.medium)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .strikethrough(item.isChecked)
                        .foregroundStyle(item.isChecked ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let amount = item.amount {
                        Text(amount)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.amount.map { "\(item.name), \($0)" } ?? item.name)
        .accessibilityValue(item.isChecked
                            ? String(localized: "Ticked off")
                            : String(localized: "Still to buy"))
        .accessibilityHint(String(localized: "Double tap to tick off"))
        .accessibilityAddTraits(item.isChecked ? .isSelected : [])
    }
}
