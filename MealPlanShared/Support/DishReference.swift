import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// A lightweight, transferable reference to a dish (and optionally the
/// planned entry it came from). Used for drag-and-drop meal planning and for
/// passing a selection between views. Resolved back to model objects via
/// `uuid` on the receiving side.
struct DishReference: Codable, Transferable, Hashable, Sendable {
    var dishUUID: UUID
    var name: String
    /// Set when the drag started from an already-planned meal.
    var sourceEntryUUID: UUID?

    init(dishUUID: UUID, name: String, sourceEntryUUID: UUID? = nil) {
        self.dishUUID = dishUUID
        self.name = name
        self.sourceEntryUUID = sourceEntryUUID
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
        ProxyRepresentation(exporting: \.name)
    }
}
