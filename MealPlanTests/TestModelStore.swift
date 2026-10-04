import Foundation
import SwiftData
@testable import MealPlan

/// SwiftData's in-memory store has no reliable secondary connection in an app
/// test host. Tests that save relationship graphs use a disposable SQLite
/// store so they exercise the same connection topology as the real app.
@MainActor
func makeTestModelContainer() throws -> (container: ModelContainer, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "MealPlan-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let schema = SharedStore.makeSchema()
    let configuration = ModelConfiguration(
        schema: schema,
        url: directory.appending(path: "test.sqlite"),
        cloudKitDatabase: .none
    )
    return (try ModelContainer(for: schema, configurations: [configuration]), directory)
}
