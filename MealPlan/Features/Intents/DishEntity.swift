import AppIntents
import CoreSpotlight
import SwiftData

/// A dish from the recipe library that Siri and Shortcuts can resolve by name.
struct DishEntity: IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Dish" }
    static var defaultQuery: DishEntityQuery { DishEntityQuery() }

    let id: UUID

    @Property(title: "Name", indexingKey: \.displayName)
    var name: String

    @Property(title: "Recipe details", indexingKey: \.contentDescription)
    var details: String

    init(id: UUID, name: String, details: String = "") {
        self.id = id
        self.name = name
        self.details = details
    }

    init(dish: Dish) {
        id = dish.uuid
        name = dish.name
        details = ([dish.recipeText ?? ""]
            + dish.sortedIngredients.compactMap { $0.ingredient?.name ?? $0.rawText }
            + dish.collectionNames
            + dish.tagNames)
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: details.isEmpty ? nil : "\(details)",
            image: .init(systemName: "fork.knife")
        )
    }
}

struct DishEntityQuery: EnumerableEntityQuery, EntityStringQuery, IndexedEntityQuery {
    @MainActor
    func allEntities() async throws -> [DishEntity] {
        try dishes().map(DishEntity.init)
    }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [DishEntity] {
        try dishes()
            .filter { identifiers.contains($0.uuid) }
            .map(DishEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [DishEntity] {
        try Array(dishes().prefix(30)).map(DishEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [DishEntity] {
        try dishes()
            .compactMap { dish -> (Dish, Double)? in
                let score = dish.searchableText.fuzzyScore(query: string)
                return score > 0 ? (dish, score) : nil
            }
            .sorted { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0.name < rhs.0.name : lhs.1 > rhs.1
            }
            .map { DishEntity(dish: $0.0) }
    }

    func reindexEntities(
        for identifiers: [DishEntity.ID],
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        let entities = try await entities(for: identifiers)
        try await MealPlanSpotlightIndexer.indexEntities(entities)
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        let entities = try await allEntities()
        try await MealPlanSpotlightIndexer.indexEntities(entities)
    }

    @MainActor
    private func dishes() throws -> [Dish] {
        try MealPlanIntentStore.context.fetch(
            FetchDescriptor<Dish>(sortBy: [SortDescriptor(\.name)])
        )
    }
}
