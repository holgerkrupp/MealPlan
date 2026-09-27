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

// MARK: - Optional grocery handoff

struct GroceryShoppingLine: Codable, Equatable, Sendable {
    var name: String
    var quantity: Double?
    var dimension: QuantityDimension?
    var additionalQuantities: [Quantity]
    var sourceDishNames: [String]
}

struct ShoppingListSnapshot: Codable, Equatable, Sendable {
    var createdAt: Date
    var lines: [GroceryShoppingLine]

    init(items: [ShoppingListItem], includeChecked: Bool = false) {
        createdAt = .now
        lines = items
            .filter { includeChecked || !$0.isChecked }
            .filter { !$0.isManual || !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map {
                GroceryShoppingLine(
                    name: $0.name,
                    quantity: $0.canonicalValue,
                    dimension: $0.dimension,
                    additionalQuantities: $0.additionalQuantities,
                    sourceDishNames: $0.sourceDishNames
                )
            }
    }
}

enum GroceryShoppingError: LocalizedError {
    case notConfigured
    case invalidResponse
    case providerFailure(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: String(localized: "This grocery service is not configured.")
        case .invalidResponse: String(localized: "The grocery service returned an invalid link.")
        case .providerFailure(let message): message
        }
    }
}

/// Provider abstraction for opt-in retailer handoff. The app does not embed a
/// privileged Instacart key: production deployments supply a small token
/// broker endpoint, while tests and previews can inject a mock provider.
protocol GroceryShoppingProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func createShoppingDestination(for list: ShoppingListSnapshot) async throws -> URL
}

struct InstacartShoppingProvider: GroceryShoppingProvider {
    let endpoint: URL?
    let session: URLSession

    init(endpoint: URL? = nil, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    var id: String { "instacart" }
    var displayName: String { "Instacart" }

    func createShoppingDestination(for list: ShoppingListSnapshot) async throws -> URL {
        guard let endpoint else { throw GroceryShoppingError.notConfigured }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(list)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GroceryShoppingError.providerFailure(String(localized: "The grocery service could not create a shopping list."))
        }
        struct Reply: Decodable { var url: URL }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw GroceryShoppingError.invalidResponse
        }
        return reply.url
    }
}
