import AppIntents
import SwiftData

/// App Intents representation of a `Dish`, so Shortcuts/Siri can pick one.
struct DishEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Dish" }
    static var defaultQuery: DishEntityQuery { DishEntityQuery() }

    let id: UUID
    @Property(title: "Name") var name: String

    init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct DishEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [DishEntity] {
        try fetch { dishes in dishes.filter { identifiers.contains($0.uuid) } }
    }

    @MainActor
    func suggestedEntities() async throws -> [DishEntity] {
        try fetch { Array($0.prefix(30)) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [DishEntity] {
        try fetch { dishes in
            dishes.filter { $0.name.fuzzyScore(query: string) > 0 }
        }
    }

    @MainActor
    private func fetch(_ transform: ([Dish]) -> [Dish]) throws -> [DishEntity] {
        let context = ModelContext(SharedStore.container(cloudKit: false))
        let all = try context.fetch(FetchDescriptor<Dish>(sortBy: [SortDescriptor(\.name)]))
        return transform(all).map { DishEntity(id: $0.uuid, name: $0.name) }
    }
}
