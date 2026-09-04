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
    let cookingSession = CookingSessionStore()
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

    /// Day cards the user collapsed on the plan, stored as `dayID` strings so
    /// the state survives the calendar's lazy scrolling and app launches.
    private(set) var collapsedDays: Set<String> = AppState.loadCollapsedDays()

    private static let collapsedDaysKey = "collapsedDayIDs"

    func isDayCollapsed(_ day: Date) -> Bool {
        collapsedDays.contains(day.dayID)
    }

    func setDayCollapsed(_ collapsed: Bool, for day: Date) {
        if collapsed {
            collapsedDays.insert(day.dayID)
        } else {
            collapsedDays.remove(day.dayID)
        }
        // Days that scrolled far into the past are never looked at again, so
        // drop them instead of growing the stored set forever.
        let cutoff = Date.now.adding(days: -60).dayID
        collapsedDays = collapsedDays.filter { $0 >= cutoff }
        UserDefaults.standard.set(Array(collapsedDays), forKey: Self.collapsedDaysKey)
    }

    private static func loadCollapsedDays() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: collapsedDaysKey) ?? [])
    }

    /// Day cards currently on screen in the plan, as `dayID`s. The week strip
    /// draws its glass pill over exactly these days, so the strip shows where
    /// in the week the plan is scrolled to.
    private(set) var visibleDayIDs: Set<String> = []

    func setDayVisible(_ visible: Bool, id: String) {
        // Only write on a real change: this fires continuously while scrolling.
        if visible {
            if !visibleDayIDs.contains(id) { visibleDayIDs.insert(id) }
        } else if visibleDayIDs.contains(id) {
            visibleDayIDs.remove(id)
        }
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

    var roundsDisplayedAmounts: Bool {
        currentHousehold?.roundsDisplayedAmounts ?? true
    }

    /// The portions this family cooks by default. Dish amounts are shown
    /// scaled to it unless the cook picks another head-count.
    var standardServings: Int {
        currentHousehold?.scalingServings ?? Household.defaultStandardServings
    }

    /// Whether estimated energy and macros appear anywhere in the app. A
    /// household can switch the whole thing off in Settings ▸ Nutrition.
    var showsNutritionEstimates: Bool {
        currentHousehold?.showsNutritionEstimates ?? true
    }

    var energyUnit: EnergyUnit {
        currentHousehold?.energyUnit ?? .kilocalories
    }

    /// An `AppState` wired to the seeded in-memory store, for previews.
    /// Deliberately not `#if DEBUG`: `#Preview` bodies compile in Release too,
    /// and `PreviewData` — which this is useless without — isn't gated either.
    static var preview: AppState {
        let state = AppState()
        state.bootstrap(context: PreviewData.container.mainContext)
        return state
    }

    /// Fetch the single household (creating it on first launch, with the
    /// default pantry staples) and run housekeeping that turns past plans into
    /// cooked-history.
    func bootstrap(context: ModelContext, planningThrough latestPlanningDate: Date? = nil) {
        var isNewHousehold = false
        if let existing = try? context.fetch(FetchDescriptor<Household>()).first {
            currentHousehold = existing
        } else {
            let household = Household(name: String(localized: "Family"))
            context.insert(household)
            try? context.save()
            currentHousehold = household
            isNewHousehold = true
        }
        if let household = currentHousehold {
            // Only a household this device just created: a family that has been
            // planning for a while must not have ingredients disappear off its
            // shopping list because of an update.
            if isNewHousehold {
                PantryStaples.seedDefaults(for: household, context: context)
            }
            MealType.ensure(for: household, context: context)
            CookedLogMaintenance.run(for: household, context: context)
            MealRoutineScheduler.apply(
                for: household,
                context: context,
                through: latestPlanningDate,
                memberName: currentMemberName
            )
            // Collections and dietary flags used to duplicate the tag system.
            // This is lossless, backed up first, and guarded per household.
            try? DishLabelConsolidation.migrateIfNeeded(household: household, context: context)
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
    /// normal deep links. Recipes already in the library are skipped, and a
    /// second take on a dish you already have is imported as a variant rather
    /// than dropped, so re-opening the same backup is safe either way.
    func handle(openedURL url: URL, context: ModelContext) {
        guard RecipeFileType.isImportable(url) else {
            handle(url: url)
            return
        }
        do {
            let recipes = try RecipeImportCommitter.recipes(fromFileAt: url)
            let result = RecipeImportCommitter.importAll(
                recipes,
                household: currentHousehold,
                createdByName: currentMemberName,
                context: context
            )
            requestedSection = .dishes
            importNotice = result.summary
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
