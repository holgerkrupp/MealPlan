import AppIntents
import Foundation
import SwiftData

/// Ticks a shopping line off from the widget.
///
/// This lives in the shared folder because the widget extension has to be able
/// to run it: an interactive widget's button performs its intent in the
/// extension's own process, not the app's.
///
/// Writing to the store from an extension is the same thing the Share
/// Extension does when it saves an imported recipe — the App Group store is
/// shared on purpose. What it does *not* do is notify a running app: SwiftData
/// has no cross-process change notification, so an app that is open on the
/// shopping list at that moment will not redraw until it next fetches. The tick
/// itself is safe either way, because the phone's own list is rebuilt from the
/// store, and `checkStateModifiedAt` is what CloudKit sync merges on.
///
/// Deliberately not discoverable: this is the widget's button, not a Shortcuts
/// action. Ticking things off by voice belongs to a properly designed intent
/// with an entity to resolve, not to one that takes a raw UUID.
struct ToggleShoppingItemIntent: AppIntent {

    static var title: LocalizedStringResource { "Tick Off a Shopping Item" }
    static var description: IntentDescription {
        IntentDescription("Ticks a line off the MealPlan shopping list, or puts it back.")
    }
    static var isDiscoverable: Bool { false }

    /// The line's `uuid`. A raw string because App Intents parameters can't be
    /// `UUID`, and an entity would put this in the Shortcuts UI.
    @Parameter(title: "Item")
    var itemID: String

    init() {}

    init(id: UUID) {
        self.itemID = id.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let uuid = UUID(uuidString: itemID) else { return .result() }
        ShoppingListWidgetStore.toggle(uuid)
        return .result()
    }
}

/// The store the widget's intent writes through.
///
/// One container per process, opened lazily and kept: a widget can be tapped
/// several times in a row, and reopening the same SQLite file each time is
/// both slower and needless.
@MainActor
enum ShoppingListWidgetStore {

    private static var container: ModelContainer?

    private static var context: ModelContext? {
        if container == nil { container = SharedStore.containerIfAvailable() }
        return container.map(ModelContext.init)
    }

    /// Flips one line's tick. A no-op when the line has been deleted in the
    /// meantime — a widget can be a few minutes out of date, and a stale tap
    /// should do nothing rather than fail.
    static func toggle(_ uuid: UUID) {
        guard let context else { return }
        let descriptor = FetchDescriptor<ShoppingListItem>(
            predicate: #Predicate { $0.uuid == uuid }
        )
        guard let item = try? context.fetch(descriptor).first else { return }
        item.isChecked.toggle()
        // The same three stamps the app writes, so a tick made here merges
        // against one made on another device exactly as one made in the app.
        let now = Date.now
        item.checkStateModifiedAt = now
        item.modifiedAt = now
        try? context.save()
        SharedStore.reloadWidgets()
    }
}
