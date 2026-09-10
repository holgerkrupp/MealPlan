import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// Stable values used to open one window per recipe, planned meal or
/// auxiliary screen.
///
/// Only `Codable` values live in here — never a SwiftData model. A window is
/// its own scene, restored by the system long after the object graph that
/// opened it is gone, so each case carries the identifier its window re-queries
/// on the way in.
enum DetailWindowRoute: Codable, Hashable, Identifiable {
    // Recipes
    case recipe(UUID)
    case newRecipe(UUID)
    case editRecipe(UUID)
    case cookRecipe(UUID)
    case findRecipe(UUID)
    case translateRecipe(UUID)
    case planRecipe(UUID)
    case groupVariants(UUID)

    // The plan
    case plannedMeal(UUID)
    case configureMeals
    case saveWeekTemplate(Date)
    case applyWeekTemplate(Date)
    case printPlan(Date)
    case printShoppingList

    // Discovery
    case discoverRecipes
    case subscribeToSite
    case addRecipeSite
    case browseSite(url: URL, title: String)
    case importRecipes(URL)

    // Household and settings
    case household
    case regularMeals
    case pantryStaples
    case dataTransfer
    case bringSettings
    case gettingStarted
    case unlock

    var id: Self { self }

    /// The smallest this window may be shrunk to. A window that opens onto a
    /// form wants a different floor from one that opens onto a web view.
    var minimumSize: CGSize {
        switch self {
        case .recipe, .newRecipe, .editRecipe, .cookRecipe, .discoverRecipes:
            CGSize(width: 640, height: 560)
        case .findRecipe, .browseSite, .importRecipes, .printPlan, .printShoppingList, .dataTransfer:
            CGSize(width: 720, height: 600)
        case .plannedMeal:
            // Wide enough for the fortnight of slots the planner strip draws.
            CGSize(width: 700, height: 640)
        case .household, .regularMeals, .pantryStaples, .configureMeals:
            CGSize(width: 560, height: 480)
        default:
            CGSize(width: 520, height: 440)
        }
    }
}

/// What this device can do with windows, and what it should do by default.
///
/// These are two different questions and the answer differs by platform:
///
/// * `canOpenWindows` — is a second window possible at all? The Mac always
///   can; an iPad can once `UIApplicationSupportsMultipleScenes` is set *and*
///   the model supports it; an iPhone never can. This gates the explicit
///   "Open in New Window" affordances.
/// * `prefersWindowsOverSheets` — should an ordinary "Edit", "Plan", "Print"
///   put up a window *instead of* a sheet? Only on the Mac, where a modal
///   sheet over the one window is the thing we are getting rid of. On an iPad
///   a new scene takes over the whole display, so a quick action there stays a
///   sheet and the second window is something the person asks for.
enum DetailWindowSupport {
    @MainActor
    static var canOpenWindows: Bool {
        #if os(macOS)
        return true
        #elseif os(iOS)
        return UIApplication.shared.supportsMultipleScenes
        #else
        return false
        #endif
    }

    @MainActor
    static var prefersWindowsOverSheets: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }
}

// MARK: - Presentation

extension View {
    /// Opens `route` in a window of its own where the platform has windows,
    /// and presents `sheet` where it doesn't.
    ///
    /// The binding is reset the moment a window opens: from then on the window
    /// owns the screen, and leaving the flag set would re-open it on the next
    /// state change.
    func detailPresentation<Sheet: View>(
        isPresented: Binding<Bool>,
        route: DetailWindowRoute,
        @ViewBuilder sheet: @escaping () -> Sheet
    ) -> some View {
        modifier(DetailPresentationModifier(isPresented: isPresented, route: { route }, sheet: sheet))
    }

    /// `item`-driven variant, for screens that are opened *for* something —
    /// a picked file, a dish, a week.
    func detailPresentation<Item: Identifiable, Sheet: View>(
        item: Binding<Item?>,
        route: @escaping (Item) -> DetailWindowRoute,
        @ViewBuilder sheet: @escaping (Item) -> Sheet
    ) -> some View {
        modifier(DetailItemPresentationModifier(item: item, route: route, sheet: sheet))
    }
}

private struct DetailPresentationModifier<Sheet: View>: ViewModifier {
    @Binding var isPresented: Bool
    let route: () -> DetailWindowRoute
    @ViewBuilder let sheet: () -> Sheet

    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        // The branch is decided by the device, not by state, so the view
        // identity underneath it never changes at runtime.
        if DetailWindowSupport.prefersWindowsOverSheets {
            content.onChange(of: isPresented) { _, wanted in
                guard wanted else { return }
                isPresented = false
                openWindow(value: route())
            }
        } else {
            content.sheet(isPresented: $isPresented) { sheet() }
        }
    }
}

private struct DetailItemPresentationModifier<Item: Identifiable, Sheet: View>: ViewModifier {
    @Binding var item: Item?
    let route: (Item) -> DetailWindowRoute
    @ViewBuilder let sheet: (Item) -> Sheet

    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        if DetailWindowSupport.prefersWindowsOverSheets {
            content.onChange(of: item?.id) { _, _ in
                guard let item else { return }
                self.item = nil
                openWindow(value: route(item))
            }
        } else {
            content.sheet(item: $item) { sheet($0) }
        }
    }
}

// MARK: - Window content

@MainActor
struct DetailWindow: View {
    let route: DetailWindowRoute

    @Environment(AppState.self) private var appState

    var body: some View {
        content
            .frame(
                minWidth: route.minimumSize.width,
                minHeight: route.minimumSize.height
            )
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .recipe(let id):
            DishWindow(dishID: id, route: route) { dish, close in
                NavigationStack { DishDetailView(dish: dish, onClose: close) }
            }
        case .newRecipe(let id):
            DishWindow(dishID: id, route: route) { dish, _ in
                NavigationStack { DishEditorView(dish: dish, isNew: true) }
            }
        case .editRecipe(let id):
            DishWindow(dishID: id, route: route) { dish, _ in
                NavigationStack { DishEditorView(dish: dish, isNew: false) }
            }
        case .cookRecipe(let id):
            DishWindow(dishID: id, route: route) { dish, _ in
                NavigationStack { CookingModeView(dish: dish) }
            }
        case .findRecipe(let id):
            DishWindow(dishID: id, route: route) { dish, _ in
                NavigationStack { RecipeFinderView(dish: dish) }
            }
        case .translateRecipe(let id):
            DishWindow(dishID: id, route: route) { dish, _ in
                NavigationStack { RecipeTranslationSheet(dish: dish) }
            }
        case .planRecipe(let id):
            DishWindow(dishID: id, route: route) { dish, _ in
                NavigationStack { PlanDishSheet(dish: dish, defaultDate: appState.selectedDate) }
            }
        case .groupVariants(let id):
            DishWindow(dishID: id, route: route) { dish, _ in
                NavigationStack { DishVariantPickerView(dish: dish) }
            }

        case .plannedMeal(let id):
            PlannedMealWindow(entryID: id, route: route)

        case .configureMeals:
            windowStack { MealsSettingsView() }
        case .saveWeekTemplate(let week):
            windowStack { SaveTemplateSheet(weekStart: week) }
        case .applyWeekTemplate(let week):
            windowStack { ApplyTemplateSheet(targetWeekStart: week) }
        case .printPlan(let week):
            PrintPlanSheet(referenceWeek: week)
        case .printShoppingList:
            PrintPlanSheet(referenceWeek: .now, initialContent: .shoppingList)

        case .discoverRecipes:
            windowStack { RecipeDiscoveryView() }
        case .subscribeToSite:
            FeedSubscriptionSheet()
        case .addRecipeSite:
            RecipeBookmarkSheet()
        case .browseSite(let url, let title):
            BrowseSiteWindow(url: url, title: title)
        case .importRecipes(let url):
            ImportRecipesSheet(fileURL: url)

        case .household:
            windowStack { HouseholdSettingsView() }
        case .regularMeals:
            windowStack { MealRoutinesView() }
        case .pantryStaples:
            windowStack { PantryStaplesView() }
        case .dataTransfer:
            windowStack { DataTransferView() }
        case .bringSettings:
            windowStack { BringSettingsView() }
        case .gettingStarted:
            OnboardingView()
        case .unlock:
            PaywallView()
        }
    }

    /// Auxiliary screens were written as the detail of a `NavigationStack` —
    /// they set a `navigationTitle` and push their own sub-screens — so each
    /// window gives them one. On the Mac the stack's title becomes the window
    /// title, which is exactly what a document-style window wants.
    private func windowStack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack { content() }
    }
}

/// Resolves the dish a window was opened for, and tells the person plainly
/// when it is no longer there — a window can outlive the recipe it shows.
@MainActor
private struct DishWindow<Content: View>: View {
    let dishID: UUID
    let route: DetailWindowRoute
    @ViewBuilder let content: (Dish, @escaping () -> Void) -> Content

    @Query private var dishes: [Dish]
    @Environment(\.dismissWindow) private var dismissWindow

    init(
        dishID: UUID,
        route: DetailWindowRoute,
        @ViewBuilder content: @escaping (Dish, @escaping () -> Void) -> Content
    ) {
        self.dishID = dishID
        self.route = route
        self.content = content
        _dishes = Query(filter: #Predicate<Dish> { $0.uuid == dishID })
    }

    var body: some View {
        if let dish = dishes.first {
            content(dish) { dismissWindow(value: route) }
        } else {
            ContentUnavailableView(
                String(localized: "Recipe unavailable"),
                systemImage: "fork.knife",
                description: Text("This recipe may have been deleted.")
            )
        }
    }
}

@MainActor
private struct PlannedMealWindow: View {
    let entryID: UUID
    let route: DetailWindowRoute

    @Query private var entries: [MealPlanEntry]
    @Environment(\.dismissWindow) private var dismissWindow

    init(entryID: UUID, route: DetailWindowRoute) {
        self.entryID = entryID
        self.route = route
        _entries = Query(filter: #Predicate<MealPlanEntry> { $0.uuid == entryID })
    }

    var body: some View {
        if let entry = entries.first {
            EntryQuickActionsSheet(entry: entry) { dismissWindow(value: route) }
        } else {
            ContentUnavailableView(
                String(localized: "Planned meal unavailable"),
                systemImage: "calendar.badge.exclamationmark",
                description: Text("This planned meal may have been removed.")
            )
        }
    }
}

// MARK: - Menu items

/// The Mac's "Open in New Window", offered wherever a row already opens
/// something in place. On an iPad it appears only once the system actually
/// offers more than one scene; on iPhone it is never built at all.
@MainActor
struct OpenInNewWindowButton: View {
    let route: DetailWindowRoute

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if DetailWindowSupport.canOpenWindows {
            Button(String(localized: "Open in New Window"), systemImage: "macwindow.badge.plus") {
                openWindow(value: route)
            }
        }
    }
}


/// A bookmarked site, opened in its own browser window. The dish it would
/// become is made here and stays out of the store until "Use this recipe"
/// saves it — see `RecipeFinderView.createsDish`.
@MainActor
private struct BrowseSiteWindow: View {
    let url: URL
    let title: String

    @Environment(AppState.self) private var appState
    @State private var dish: Dish?

    var body: some View {
        Group {
            if let dish {
                NavigationStack {
                    RecipeFinderView(dish: dish, initialURL: url, createsDish: true)
                }
            } else {
                ProgressView()
            }
        }
        .onAppear {
            guard dish == nil else { return }
            let candidate = Dish(name: title)
            candidate.household = appState.currentHousehold
            candidate.createdByName = appState.currentMemberName
            dish = candidate
        }
    }
}

extension View {
    /// Adds a one-item context menu offering this row in a window of its own.
    /// On a device with a single scene it adds nothing — rather than an empty
    /// menu that opens on every long press.
    @ViewBuilder
    func openInNewWindowContextMenu(_ route: DetailWindowRoute) -> some View {
        if DetailWindowSupport.canOpenWindows {
            contextMenu { OpenInNewWindowButton(route: route) }
        } else {
            self
        }
    }
}
