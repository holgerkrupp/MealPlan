import Foundation
import SwiftData

/// A cheap invalidation key for value metadata derived from a household's
/// dishes. The live models are inspected only for scalar revision fields in
/// the view; tag and collection relationships are traversed by the loader.
struct DishLibraryMetadataRevision: Equatable, Sendable {
    var count: Int
    var latestModification: Date?
    var token: Int = 0
}

/// Immutable navigation metadata shared by library surfaces. Counts and tag
/// popularity are derived off the UI context and cached per household/revision.
struct DishLibraryMetadata: Sendable {
    var available: [String]
    var popular: [String]
    var collections: [DishCollectionSummary]

    static let empty = DishLibraryMetadata(available: [], popular: [], collections: [])
}

@ModelActor
actor DishLibraryMetadataLoader {
    private struct CacheEntry {
        var revision: DishLibraryMetadataRevision
        var metadata: DishLibraryMetadata
    }

    private var cache: [UUID: CacheEntry] = [:]

    func tagMetadata(
        householdID: UUID,
        revision: DishLibraryMetadataRevision
    ) -> DishLibraryMetadata {
        if let entry = cache[householdID], entry.revision == revision {
            return entry.metadata
        }
        guard !Task.isCancelled,
              let dishes = try? modelContext.fetch(FetchDescriptor<Dish>(
                predicate: #Predicate { $0.household?.uuid == householdID }
              ))
        else { return .empty }

        let usage = DishTag.usage(fromTagLists: dishes.map(\.tagNames))
        guard !Task.isCancelled else { return .empty }
        let collections = DishCollection.usage(fromCollectionLists: dishes.map(\.collectionNames))
        let metadata = DishLibraryMetadata(
            available: DishTag.sorted(usage.map(\.tag)),
            popular: Array(usage.prefix(12).map(\.tag)),
            collections: collections.map { DishCollectionSummary(name: $0.name, count: $0.count) }
        )
        cache[householdID] = CacheEntry(revision: revision, metadata: metadata)
        return metadata
    }
}
