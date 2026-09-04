import Foundation
import SwiftData
import OSLog
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The one SwiftData store, shared between the app, the Share Extension and
/// the widgets through an App Group container. The app mirrors it to CloudKit;
/// the extensions open it read/write without CloudKit and let the app sync
/// their changes on its next run.
enum SharedStore {

    static let appGroupID = "group.de.holgerkrupp.mealplan"
    static let cloudKitContainerID = "iCloud.de.holgerkrupp.mealplan"

    static let logger = Logger(subsystem: "de.holgerkrupp.mealplan", category: "persistence")

    /// Whether the store that was opened is actually mirroring to CloudKit, or
    /// quietly fell back to the local App-Group file because the container
    /// couldn't be reached (an unprovisioned entitlement, no iCloud account).
    /// Written once while the container is built and only read afterwards.
    nonisolated(unsafe) private(set) static var isMirroringToCloudKit = false

    static var models: [any PersistentModel.Type] {
        [
            Household.self,
            HouseholdMember.self,
            MealType.self,
            Dish.self,
            DishImage.self,
            Ingredient.self,
            DishIngredient.self,
            MealPlanEntry.self,
            MealRoutine.self,
            CookedLog.self,
            ShoppingListItem.self,
            WeekTemplate.self,
            WeekTemplateEntry.self,
            RecipeFeed.self,
            RecipeFeedItem.self,
            RecipeBookmark.self,
        ]
    }

    static func makeSchema() -> Schema { Schema(models) }

    /// URL of the shared SQLite store inside the App Group container. Falls
    /// back to the app's own Application Support directory if the group isn't
    /// available (e.g. entitlement not yet provisioned).
    static var storeURL: URL {
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return group.appending(path: "MealPlan.sqlite")
        }
        let support = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appending(path: "MealPlan.sqlite")
    }

    /// Build the container. `cloudKit` is true only for the main app.
    /// Safe to call from any thread — no `mainContext` access here.
    static func container(cloudKit: Bool, inMemory: Bool = false) -> ModelContainer {
        // Must happen before the store is opened: it replaces the shared
        // transformer Core Data uses for every `[String]` attribute.
        LenientSecureUnarchiveTransformer.register()

        let schema = makeSchema()

        if inMemory {
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: [config])
        }

        if cloudKit {
            let cloud = ModelConfiguration(
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .private(cloudKitContainerID)
            )
            if let c = try? ModelContainer(for: schema, configurations: [cloud]) {
                isMirroringToCloudKit = true
                return c
            }
            logger.error("CloudKit store unavailable, using on-device storage")
        }

        isMirroringToCloudKit = false
        let local = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: [local])
        } catch {
            fatalError("Could not open the MealPlan store: \(error)")
        }
    }

    /// Open the shared store without CloudKit and without trapping. The
    /// widgets use this: a timeline provider that crashes takes the whole
    /// widget down on every refresh, where an empty view merely looks empty.
    static func containerIfAvailable() -> ModelContainer? {
        LenientSecureUnarchiveTransformer.register()
        let schema = makeSchema()
        let local = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: [local])
        } catch {
            logger.error("Could not open the MealPlan store: \(error.localizedDescription)")
            return nil
        }
    }

    /// Main-app entry point: container with an undo manager on the main context.
    @MainActor
    static func make(cloudKit: Bool, inMemory: Bool = false) -> ModelContainer {
        let c = container(cloudKit: cloudKit, inMemory: inMemory)
        c.mainContext.undoManager = UndoManager()
        c.mainContext.undoManager?.levelsOfUndo = 20
        return c
    }

    /// Ask the system to refresh all widget timelines. No-op where WidgetKit
    /// isn't available (macOS build without the widget target loaded, etc.).
    static func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
        NotificationCenter.default.post(name: .mealPlanDataDidChange, object: nil)
    }
}

extension Notification.Name {
    /// Posted after app data that can appear in widgets, Spotlight, or Siri
    /// changes. The main app debounces it before refreshing its semantic index.
    static let mealPlanDataDidChange = Notification.Name("de.holgerkrupp.mealplan.dataDidChange")
}
