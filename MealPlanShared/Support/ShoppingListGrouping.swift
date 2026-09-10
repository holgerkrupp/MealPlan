import Foundation

/// One aisle's worth of the shopping list.
struct ShoppingAisle: Identifiable {
    var name: String
    /// Where the aisle falls in the walk through the shop — the smallest
    /// category order among its items, so a custom aisle name inherits a
    /// sensible position instead of landing alphabetically.
    var sortOrder: Int
    var items: [ShoppingListItem]

    var id: String { name }
}

/// Groups the shopping list by aisle.
///
/// Pulled out of `ShoppingListView` when printing arrived: a printed list that
/// grouped or ordered its items differently from the one on screen would be a
/// bug nobody would think to look for, and the only way to be sure is for both
/// to call this. It moved into the shared folder when the shopping widget
/// arrived, for the same reason — the widget walks the shop in the order the
/// app does because it walks it with this.
enum ShoppingListGrouping {

    static func aisles(_ items: [ShoppingListItem]) -> [ShoppingAisle] {
        Dictionary(grouping: items, by: \.aisleName)
            .map { name, values in
                ShoppingAisle(
                    name: name,
                    sortOrder: values.map { $0.category.sortOrder }.min()
                        ?? IngredientCategory.other.sortOrder,
                    items: values.sorted { $0.sortIndex < $1.sortIndex }
                )
            }
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
    }
}
