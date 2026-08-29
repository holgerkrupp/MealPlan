import Foundation
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// App-wide UI state that isn't part of the synced model: which household is
/// active, the calendar's focused date, and the current library / shopping
/// filters.
@Observable
@MainActor
final class AppState {
    var currentHousehold: Household?
    var selectedDate: Date = Date.now.startOfDay
    var dishFilter = DishFilter()
    /// The dish sidebar shown next to the plan filters independently of
    /// the Dishes section, so searching there doesn't disturb the library.
    var planDishFilter = DishFilter()
    var shoppingRange: ShoppingRangeOption = .thisWeek
    var shoppingCustomStart: Date = Date.now.startOfDay
    var shoppingCustomEnd: Date = Date.now.startOfDay.adding(days: 6)

    /// True when this device joined a household as a view-only guest.
    var isGuest: Bool = false

    /// The section a deep link / App Intent wants shown.
    var requestedSection: AppSection?
    /// A pending "add dish" request from a deep link (the picker consumes it).
    var pendingAddDish: PendingAddDish?
    var importNotice: String?

    struct PendingAddDish: Identifiable, Equatable {
        let id = UUID()
        var url: URL?
        var name: String?
    }

    /// A transient "undo" offer shown after a forgiving destructive action.
    var undoOffer: UndoOffer?

    struct UndoOffer: Identifiable {
        let id = UUID()
        var message: String
        var action: () -> Void
    }

    func offerUndo(_ message: String, action: @escaping () -> Void) {
        undoOffer = UndoOffer(message: message, action: action)
    }

    /// The name to attribute new plans / edits to. Filled from the CloudKit
    /// share participant when sharing is set up, otherwise the device owner.
    var currentMemberName: String = DeviceOwner.name

    var unitSystem: UnitSystem {
        currentHousehold?.unitSystem ?? .metric
    }

    #if DEBUG
    /// An `AppState` wired to the seeded in-memory store, for previews.
    static var preview: AppState {
        let state = AppState()
        state.bootstrap(context: PreviewData.container.mainContext)
        return state
    }
    #endif

    /// Fetch the single household (creating it on first launch) and run
    /// housekeeping that turns past plans into cooked-history.
    func bootstrap(context: ModelContext) {
        if let existing = try? context.fetch(FetchDescriptor<Household>()).first {
            currentHousehold = existing
        } else {
            let household = Household(name: String(localized: "Family"))
            context.insert(household)
            try? context.save()
            currentHousehold = household
        }
        if let household = currentHousehold {
            MealType.ensure(for: household, context: context)
            CookedLogMaintenance.run(for: household, context: context)
        }
        DishGlyphMaintenance.run(context: context)
    }

    /// Route a `mealplan://` deep link (or an App Intent hand-off).
    func handle(_ link: DeepLink) {
        switch link {
        case .today:
            selectedDate = Date.now.startOfDay
            requestedSection = .plan
        case .date(let date):
            selectedDate = date.startOfDay
            requestedSection = .plan
        case .shoppingList:
            requestedSection = .shopping
        case .addDish(let url, let name):
            pendingAddDish = PendingAddDish(url: url, name: name)
            requestedSection = .dishes
        case .plan(let dishName, _, let date, _):
            if let date { selectedDate = date.startOfDay }
            if dishName != nil { pendingAddDish = PendingAddDish(url: nil, name: dishName) }
            requestedSection = .plan
        }
    }

    func handle(url: URL) {
        if let link = DeepLink(url: url) { handle(link) }
    }

    /// Handles recipe archives opened from Files/Finder as well as the app's
    /// normal deep links. Existing exact-name/source matches are skipped so
    /// re-opening the same backup is safe.
    func handle(openedURL url: URL, context: ModelContext) {
        let ext = url.pathExtension.lowercased()
        guard ["mealplanrecipes", "paprikarecipes", "paprikarecipe"].contains(ext) else {
            handle(url: url)
            return
        }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let recipes = ext == "mealplanrecipes"
                ? try MealPlanRecipeArchive.importedRecipes(from: data)
                : try PaprikaArchive.recipes(from: data)
            var existing = (try? context.fetch(FetchDescriptor<Dish>())) ?? []
            var imported = 0
            for recipe in recipes {
                guard RecipeDuplicateDetector.match(recipe, in: existing) == nil else { continue }
                let dish = DishBuilder.makeDish(
                    from: recipe,
                    household: currentHousehold,
                    createdByName: currentMemberName,
                    context: context
                )
                existing.append(dish)
                imported += 1
            }
            requestedSection = .dishes
            importNotice = String(localized: "Imported \(imported) recipes; skipped \(recipes.count - imported) duplicates.")
        } catch {
            importNotice = String(localized: "Couldn’t import that recipe archive: \(error.localizedDescription)")
        }
    }
}

/// Best-effort human name for the person using this device.
enum DeviceOwner {
    @MainActor
    static var name: String {
        #if os(macOS)
        let full = Host.current().localizedName ?? ""
        if !full.isEmpty { return full }
        return NSFullUserName().isEmpty ? String(localized: "Me") : NSFullUserName()
        #else
        let device = UIDevice.current.name
        return device.isEmpty ? String(localized: "Me") : device
        #endif
    }
}
