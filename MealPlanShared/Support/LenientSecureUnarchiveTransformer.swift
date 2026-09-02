import Foundation
import OSLog

/// SwiftData stores every `[String]` attribute (`Dish.collectionNames`,
/// `Dish.tagNames`, `ShoppingListItem.sourceDishNames`, …) as a Core Data
/// *transformable* column, archived through the shared
/// `NSSecureUnarchiveFromData` transformer.
///
/// That transformer raises an Objective-C exception — `NSInvalidUnarchive`
/// `OperationException`, "The data couldn't be read because it isn't in the
/// correct format" — whenever the column holds bytes it can't decode, and a
/// **zero-length blob is one of those cases**. Core Data writes exactly that
/// for a non-optional transformable attribute when a CloudKit record arrives
/// without the field (a record written by an older schema, or by a device that
/// never set the value). The exception is thrown from Objective-C, so Swift
/// cannot catch it: every read of the property is a hard crash, and it takes
/// the CloudKit mirroring delegate down with it (`NSCocoaErrorDomain` 134420).
///
/// Registering this subclass under the *same* name replaces the shared
/// transformer everywhere Core Data looks one up — model accessors, the change
/// snapshots it takes before a save, and the CloudKit importer alike — so that
/// a value it cannot read comes back as an empty array instead of raising.
final class LenientSecureUnarchiveTransformer: NSSecureUnarchiveFromDataTransformer {

    /// The name the system transformer is registered under, and the one
    /// SwiftData asks for. Registering over it is the whole point.
    static let name = NSValueTransformerName.secureUnarchiveFromDataTransformerName

    /// Installs the lenient transformer. Idempotent, and must run before any
    /// `ModelContainer` is built — see `SharedStore.container(cloudKit:)`.
    static func register() {
        ValueTransformer.setValueTransformer(LenientSecureUnarchiveTransformer(), forName: name)
    }

    override func transformedValue(_ value: Any?) -> Any? {
        guard let data = value as? Data else { return nil }

        // The case this class exists for. A zero-length blob is Core Data's
        // stand-in for "this non-optional attribute was never written", which
        // for every transformable in this schema is an array — so hand back an
        // empty one. Returning nil instead is not enough: the attribute is
        // required, so Core Data then fails validation with error 1570 and the
        // CloudKit importer gives up on the whole zone.
        guard !data.isEmpty else { return NSArray() }

        do {
            return try NSKeyedUnarchiver.unarchivedObject(
                ofClasses: Self.allowedTopLevelClasses,
                from: data
            )
        } catch {
            // Genuinely corrupt bytes rather than a missing value. Nothing to
            // recover, but it should not be silent: Core Data will fall back
            // to the attribute's default and the old value is gone.
            SharedStore.logger.error(
                "Dropping \(data.count) undecodable bytes from a transformable attribute: \(error.localizedDescription)"
            )
            return nil
        }
    }
}
