import Foundation
import SwiftData
import WidgetKit

// MARK: - Flattened list

/// One shopping line, flattened out of SwiftData. Timeline entries are
/// archived by the system, so — as with `WidgetMeal` — nothing here may hold
/// on to a `ModelContext` or a model.
struct WidgetShoppingItem: Identifiable, Hashable {
    var id: UUID
    var name: String
    /// Ready-to-read amount, e.g. "500 g". `nil` when the line has none.
    var amount: String?
    var isChecked: Bool
}

/// One aisle's worth of the list, in the order the shop is walked.
struct WidgetShoppingAisle: Identifiable, Hashable {
    var name: String
    var items: [WidgetShoppingItem]

    var id: String { name }
    var remaining: [WidgetShoppingItem] { items.filter { !$0.isChecked } }
    var isDone: Bool { remaining.isEmpty }
}

extension Array where Element == WidgetShoppingAisle {

    /// Every line across every aisle, in aisle order.
    var allItems: [WidgetShoppingItem] { flatMap(\.items) }

    /// Just what is still to buy — what the compact families show.
    var remaining: [WidgetShoppingItem] { flatMap(\.remaining) }

    /// Trims the grouped list to what will fit: an aisle costs one row for its
    /// heading plus one per line, and an aisle is only kept whole — half an
    /// aisle under its own name reads as a complete aisle, which is worse than
    /// stopping one aisle earlier. Mirrors `[WidgetDay].trimmed(toRows:)`.
    func trimmed(toRows budget: Int) -> [WidgetShoppingAisle] {
        var used = 0
        var kept: [WidgetShoppingAisle] = []
        for aisle in self {
            let cost = 1 + aisle.items.count
            guard used + cost <= budget || kept.isEmpty else { break }
            used += cost
            kept.append(aisle)
        }
        return kept
    }
}

// MARK: - Timeline entry

struct ShoppingWidgetEntry: TimelineEntry {
    var date: Date
    var aisles: [WidgetShoppingAisle] = []
    var link: URL = WidgetLink.shopping

    var allItems: [WidgetShoppingItem] { aisles.allItems }
    var remaining: [WidgetShoppingItem] { aisles.remaining }
    var isEmpty: Bool { aisles.isEmpty }
    /// Everything on the list has been ticked — a different state from an
    /// empty list, and worth saying so.
    var isDone: Bool { !isEmpty && remaining.isEmpty }
}

// MARK: - Loading

/// Reads the shared store for the shopping widget. Read-only and synchronous,
/// like `WidgetPlanLoader` and for the same reason: a timeline provider gets a
/// few hundred milliseconds and no business writing to a store the app may
/// have open at the same time. The one write in this widget is the tick, and
/// that goes through `ToggleShoppingItemIntent` on an explicit tap.
enum ShoppingWidgetLoader {

    /// A ceiling on what one entry carries. Nothing in a widget can show a
    /// hundred lines, and every one of them costs archiving.
    static let defaultLimit = 60

    private nonisolated(unsafe) static var cachedContainer: ModelContainer?
    private static let containerLock = NSLock()

    private static func makeContext() -> ModelContext? {
        containerLock.lock()
        defer { containerLock.unlock() }
        if cachedContainer == nil { cachedContainer = SharedStore.containerIfAvailable() }
        return cachedContainer.map(ModelContext.init)
    }

    /// The list, grouped into aisles.
    ///
    /// The grouping and the order come from `ShoppingListGrouping` — the same
    /// call the app's list and the printed list make — so all three walk the
    /// shop the same way.
    static func aisles(limit: Int = defaultLimit) -> [WidgetShoppingAisle] {
        guard let context = makeContext() else { return [] }
        let descriptor = FetchDescriptor<ShoppingListItem>(sortBy: [SortDescriptor(\.sortIndex)])
        guard let items = try? context.fetch(descriptor), !items.isEmpty else { return [] }

        var budget = max(limit, 1)
        var result: [WidgetShoppingAisle] = []
        for aisle in ShoppingListGrouping.aisles(items) {
            guard budget > 0 else { break }
            let taken = aisle.items.prefix(budget)
            budget -= taken.count
            result.append(WidgetShoppingAisle(
                name: aisle.name,
                items: taken.map {
                    WidgetShoppingItem(
                        id: $0.uuid,
                        name: $0.name,
                        amount: $0.displayText.flatMap { $0.isEmpty ? nil : $0 },
                        isChecked: $0.isChecked
                    )
                }
            ))
        }
        return result
    }

    static func entry(at date: Date = .now) -> ShoppingWidgetEntry {
        ShoppingWidgetEntry(date: date, aisles: aisles())
    }
}

// MARK: - Gallery samples

/// What the widget gallery and the redacted placeholder show. Deliberately not
/// read from the store: the gallery has to look right before a list exists.
extension ShoppingWidgetEntry {

    private static func sampleItem(_ name: String, _ amount: String?, checked: Bool = false) -> WidgetShoppingItem {
        WidgetShoppingItem(id: UUID(), name: name, amount: amount, isChecked: checked)
    }

    static var sample: ShoppingWidgetEntry {
        ShoppingWidgetEntry(date: .now, aisles: [
            WidgetShoppingAisle(name: String(localized: "Fruit & vegetables"), items: [
                sampleItem(String(localized: "Pumpkin"), "1 ×"),
                sampleItem(String(localized: "Ginger"), "30 g", checked: true),
                sampleItem(String(localized: "Red cabbage"), "1 kg"),
            ]),
            WidgetShoppingAisle(name: String(localized: "Dairy"), items: [
                sampleItem(String(localized: "Feta"), "200 g"),
                sampleItem(String(localized: "Parmesan"), "150 g", checked: true),
            ]),
            WidgetShoppingAisle(name: String(localized: "Pantry"), items: [
                sampleItem(String(localized: "Lasagne sheets"), "1 ×"),
                sampleItem(String(localized: "Lentils"), "250 g"),
            ]),
        ])
    }

    /// Nothing to buy — the state every family sees before their first rebuild.
    static var sampleEmpty: ShoppingWidgetEntry { ShoppingWidgetEntry(date: .now) }

    /// Everything ticked — the moment worth showing off.
    static var sampleDone: ShoppingWidgetEntry {
        ShoppingWidgetEntry(date: .now, aisles: sample.aisles.map {
            WidgetShoppingAisle(name: $0.name, items: $0.items.map {
                WidgetShoppingItem(id: $0.id, name: $0.name, amount: $0.amount, isChecked: true)
            })
        })
    }
}
