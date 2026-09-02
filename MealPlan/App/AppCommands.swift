import SwiftUI

/// The menu bar (macOS, and iPadOS 26's menu bar / ⌘-hold shortcut sheet).
///
/// Menu items never reach into a view directly. Each screen publishes the
/// actions it can perform as a focused scene value, and the commands below
/// read those values: a section that isn't on screen publishes nothing, so its
/// items are automatically greyed out. That keeps "is this available right
/// now?" in one place — the view that owns the state — instead of duplicating
/// every guard (`isGuest`, "library is empty", "this dish has no recipe") in
/// the menu.
struct MealPlanCommands: Commands {
    @FocusedValue(\.appNavigation) private var navigation
    @FocusedValue(\.planCommands) private var plan
    @FocusedValue(\.planSidebarCommands) private var planSidebar
    @FocusedValue(\.dishLibraryCommands) private var library
    @FocusedValue(\.dishCommands) private var dish
    @FocusedValue(\.shoppingCommands) private var shopping

    var body: some Commands {
        newItemCommands
        importExportCommands
        printCommands
        undoCommands
        findCommands
        viewCommands
        planMenu
        dishMenu
        shoppingMenu
        helpCommands
    }

    // MARK: - File

    /// Replaces "New" / "New Window": a second window onto the same plan isn't
    /// worth ⌘N here, and a new dish is what people actually reach for.
    private var newItemCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button {
                navigation?.newDish()
            } label: {
                Label(String(localized: "New dish"), systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(navigation == nil || navigation?.isGuest == true)

            Button {
                shopping?.addItem()
            } label: {
                Label(String(localized: "New shopping item"), systemImage: "cart.badge.plus")
            }
            .keyboardShortcut("n", modifiers: [.shift, .command])
            .disabled(shopping == nil)
        }
    }

    private var importExportCommands: some Commands {
        CommandGroup(after: .importExport) {
            Button {
                library?.importRecipes?()
            } label: {
                Label(String(localized: "Import recipes"), systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("i", modifiers: [.shift, .command])
            .disabled(library?.importRecipes == nil)

            Button {
                dish?.exportRecipe()
            } label: {
                Label(String(localized: "Export recipe"), systemImage: "square.and.arrow.up")
            }
            .keyboardShortcut("e", modifiers: [.option, .command])
            .disabled(dish == nil)

            Button {
                library?.exportAll?()
            } label: {
                Label(String(localized: "Export all recipes"), systemImage: "square.and.arrow.up.on.square")
            }
            .keyboardShortcut("e", modifiers: [.shift, .command])
            .disabled(library?.exportAll == nil)

            Divider()

            Button {
                navigation?.showDataTransfer()
            } label: {
                Label(String(localized: "Back up or restore…"), systemImage: "externaldrive")
            }
            .disabled(navigation == nil)
        }
    }

    /// The week PDF is this app's "print": ⌘P produces the sheet you'd pin to
    /// the fridge.
    private var printCommands: some Commands {
        CommandGroup(replacing: .printItem) {
            Button {
                plan?.exportWeekPDF()
            } label: {
                Label(String(localized: "Export week as PDF"), systemImage: "doc.richtext")
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(plan == nil)
        }
    }

    // MARK: - Edit

    /// The app's own forgiving undo (the banner after a destructive tap). It
    /// deliberately has no ⌘Z: that key belongs to the text field you might be
    /// typing in.
    private var undoCommands: some Commands {
        CommandGroup(after: .undoRedo) {
            Button {
                navigation?.undo?()
            } label: {
                Label(String(localized: "Undo last change"), systemImage: "arrow.uturn.backward")
            }
            .disabled(navigation?.undo == nil)
        }
    }

    private var findCommands: some Commands {
        CommandGroup(after: .textEditing) {
            Button {
                library?.search()
            } label: {
                Label(String(localized: "Find a dish"), systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(library == nil)
        }
    }

    // MARK: - View

    private var viewCommands: some Commands {
        CommandGroup(after: .sidebar) {
            ForEach(Array(AppSection.navigationCases.enumerated()), id: \.element) { index, section in
                Button {
                    navigation?.select(section)
                } label: {
                    Label(section.title, systemImage: section.symbol)
                }
                .keyboardShortcut(shortcutKey(for: index), modifiers: .command)
                .disabled(navigation == nil)
            }

            Divider()

            Button {
                planSidebar?.toggle()
            } label: {
                Label(
                    planSidebar?.isShown == true
                        ? String(localized: "Hide dish list")
                        : String(localized: "Show dish list"),
                    systemImage: "sidebar.trailing"
                )
            }
            // Not ⌃⌘S: that is the split view's own Toggle Sidebar.
            .keyboardShortcut("s", modifiers: [.option, .command])
            .disabled(planSidebar == nil)

            // The pickers stay in place and grey out rather than vanishing:
            // a menu whose items come and go is hard to aim at.
            Picker(String(localized: "Calendar layout"), selection: calendarStyleBinding) {
                ForEach(CalendarStyle.allCases) { style in
                    Text(style.localizedName).tag(style)
                }
            }
            .disabled(plan == nil)

            Picker(String(localized: "Sort dishes by"), selection: dishSortBinding) {
                ForEach(DishFilter.Sort.allCases) { sort in
                    Text(sort.localizedName).tag(sort)
                }
            }
            .disabled(library == nil)

            Button {
                library?.clearFilters?()
            } label: {
                Label(String(localized: "Clear filters"), systemImage: "line.3.horizontal.decrease.circle")
            }
            .disabled(library?.clearFilters == nil)
        }
    }

    private func shortcutKey(for index: Int) -> KeyEquivalent {
        KeyEquivalent(Character("\(index + 1)"))
    }

    private var calendarStyleBinding: Binding<CalendarStyle> {
        Binding(get: { plan?.calendarStyle ?? .week }, set: { plan?.setCalendarStyle($0) })
    }

    private var dishSortBinding: Binding<DishFilter.Sort> {
        Binding(get: { library?.sort ?? .alphabetical }, set: { library?.setSort($0) })
    }

    private var shoppingRangeBinding: Binding<ShoppingRangeOption> {
        Binding(get: { shopping?.range ?? .thisWeek }, set: { shopping?.setRange($0) })
    }

    // MARK: - Plan

    private var planMenu: some Commands {
        CommandMenu(AppSection.plan.title) {
            Button {
                plan?.goToToday()
            } label: {
                Label(String(localized: "Today"), systemImage: "calendar.badge.clock")
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(plan == nil)

            Button {
                plan?.jumpToDate()
            } label: {
                Label(String(localized: "Jump to date…"), systemImage: "calendar")
            }
            .keyboardShortcut("t", modifiers: [.shift, .command])
            .disabled(plan == nil)

            Divider()

            Button {
                plan?.goToPreviousWeek()
            } label: {
                Label(String(localized: "Previous week"), systemImage: "chevron.left")
            }
            .keyboardShortcut(.leftArrow, modifiers: [.option, .command])
            .disabled(plan == nil)

            Button {
                plan?.goToNextWeek()
            } label: {
                Label(String(localized: "Next week"), systemImage: "chevron.right")
            }
            .keyboardShortcut(.rightArrow, modifiers: [.option, .command])
            .disabled(plan == nil)

            Divider()

            Button {
                plan?.saveWeekAsTemplate()
            } label: {
                Label(String(localized: "Save week as template"), systemImage: "square.and.arrow.down")
            }
            .disabled(plan == nil)

            Button {
                plan?.applyTemplate()
            } label: {
                Label(String(localized: "Apply a template…"), systemImage: "square.on.square.dashed")
            }
            .disabled(plan == nil)

            Divider()

            Button {
                navigation?.showRegularMeals()
            } label: {
                Label(String(localized: "Regular meals"), systemImage: "repeat")
            }
            .disabled(navigation == nil)
        }
    }

    // MARK: - Dish

    /// Everything here needs a dish on screen, so the whole menu greys out
    /// unless a dish's detail view is showing.
    private var dishMenu: some Commands {
        CommandMenu(AppSection.dishes.title) {
            Button {
                dish?.cook?()
            } label: {
                Label(String(localized: "Cook"), systemImage: "frying.pan")
            }
            .keyboardShortcut("r", modifiers: [.shift, .command])
            .disabled(dish?.cook == nil)

            Button {
                dish?.plan()
            } label: {
                Label(String(localized: "Plan this dish…"), systemImage: "calendar.badge.plus")
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(dish == nil)

            Divider()

            Button {
                dish?.edit()
            } label: {
                Label(String(localized: "Edit"), systemImage: "pencil")
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(dish == nil)

            Button {
                dish?.findRecipe?()
            } label: {
                Label(String(localized: "Find a recipe"), systemImage: "text.magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: [.option, .command])
            .disabled(dish?.findRecipe == nil)

            Divider()

            Button {
                dish?.saveAsVariant?()
            } label: {
                Label(String(localized: "Save as new variant"), systemImage: "square.on.square")
            }
            .keyboardShortcut("d", modifiers: [.shift, .command])
            .disabled(dish?.saveAsVariant == nil)

            Button {
                dish?.groupWithDish?()
            } label: {
                Label(String(localized: "Group with another dish"), systemImage: "link")
            }
            .disabled(dish?.groupWithDish == nil)

            Divider()

            Button(role: .destructive) {
                dish?.delete()
            } label: {
                Label(String(localized: "Delete recipe"), systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(dish == nil)
        }
    }

    // MARK: - Shopping

    private var shoppingMenu: some Commands {
        CommandMenu(AppSection.shopping.title) {
            Button {
                shopping?.rebuild()
            } label: {
                Label(String(localized: "Rebuild from plan"), systemImage: "arrow.triangle.2.circlepath")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(shopping == nil)

            Picker(String(localized: "Shop for"), selection: shoppingRangeBinding) {
                ForEach(ShoppingRangeOption.allCases) { option in
                    Text(option.localizedName).tag(option)
                }
            }
            .disabled(shopping == nil)

            Divider()

            Button {
                shopping?.addToReminders?()
            } label: {
                Label(String(localized: "Add to Reminders"), systemImage: "list.bullet")
            }
            .disabled(shopping?.addToReminders == nil)

            Button(role: .destructive) {
                shopping?.clearTicked?()
            } label: {
                Label(String(localized: "Clear ticked items"), systemImage: "xmark.circle")
            }
            .disabled(shopping?.clearTicked == nil)

            Divider()

            Button {
                navigation?.showPantryStaples()
            } label: {
                Label(String(localized: "Pantry staples"), systemImage: "shippingbox")
            }
            .disabled(navigation == nil)
        }
    }

    // MARK: - Help

    private var helpCommands: some Commands {
        CommandGroup(replacing: .help) {
            Button {
                navigation?.showGettingStarted()
            } label: {
                Label(String(localized: "Getting started"), systemImage: "sparkles")
            }
            .disabled(navigation == nil)
        }
    }
}

// MARK: - Focused values

/// The app shell's own actions: which section is showing, how to switch, and
/// the few things reachable from anywhere.
struct AppNavigationCommands {
    var section: AppSection
    var isGuest: Bool
    var select: @MainActor (AppSection) -> Void
    var newDish: @MainActor () -> Void
    var showGettingStarted: @MainActor () -> Void
    var showRegularMeals: @MainActor () -> Void
    var showPantryStaples: @MainActor () -> Void
    var showDataTransfer: @MainActor () -> Void
    /// Nil unless the undo banner is offering something.
    var undo: (@MainActor () -> Void)?
}

/// What the calendar can do for the menu bar.
struct PlanCommands {
    var calendarStyle: CalendarStyle
    var goToToday: @MainActor () -> Void
    var jumpToDate: @MainActor () -> Void
    var goToPreviousWeek: @MainActor () -> Void
    var goToNextWeek: @MainActor () -> Void
    var saveWeekAsTemplate: @MainActor () -> Void
    var applyTemplate: @MainActor () -> Void
    var exportWeekPDF: @MainActor () -> Void
    var setCalendarStyle: @MainActor (CalendarStyle) -> Void
}

/// Published only when the plan is actually wide enough to show the dish list
/// beside the calendar, so the toggle greys out on a narrow window.
struct PlanSidebarCommands {
    var isShown: Bool
    var toggle: @MainActor () -> Void
}

struct DishLibraryCommands {
    var sort: DishFilter.Sort
    var search: @MainActor () -> Void
    var setSort: @MainActor (DishFilter.Sort) -> Void
    /// Nil for guests, who can look but not add or import.
    var importRecipes: (@MainActor () -> Void)?
    /// Nil while the library is empty — there'd be nothing in the archive.
    var exportAll: (@MainActor () -> Void)?
    /// Nil when no search text or filter is set.
    var clearFilters: (@MainActor () -> Void)?
}

/// Published by the dish detail view, so the Dish menu tracks the recipe the
/// user is actually looking at.
struct DishCommands {
    var plan: @MainActor () -> Void
    var edit: @MainActor () -> Void
    var exportRecipe: @MainActor () -> Void
    var delete: @MainActor () -> Void
    /// Nil when there's nothing to cook from yet.
    var cook: (@MainActor () -> Void)?
    /// Nil once the dish has a recipe, or while it is still unnamed.
    var findRecipe: (@MainActor () -> Void)?
    var saveAsVariant: (@MainActor () -> Void)?
    var groupWithDish: (@MainActor () -> Void)?
}

struct ShoppingCommands {
    var range: ShoppingRangeOption
    var rebuild: @MainActor () -> Void
    var addItem: @MainActor () -> Void
    var setRange: @MainActor (ShoppingRangeOption) -> Void
    /// Nil on platforms without Reminders export, or while the list is empty.
    var addToReminders: (@MainActor () -> Void)?
    /// Nil when nothing is ticked.
    var clearTicked: (@MainActor () -> Void)?
}

private struct AppNavigationCommandsKey: FocusedValueKey { typealias Value = AppNavigationCommands }
private struct PlanCommandsKey: FocusedValueKey { typealias Value = PlanCommands }
private struct PlanSidebarCommandsKey: FocusedValueKey { typealias Value = PlanSidebarCommands }
private struct DishLibraryCommandsKey: FocusedValueKey { typealias Value = DishLibraryCommands }
private struct DishCommandsKey: FocusedValueKey { typealias Value = DishCommands }
private struct ShoppingCommandsKey: FocusedValueKey { typealias Value = ShoppingCommands }

extension FocusedValues {
    var appNavigation: AppNavigationCommands? {
        get { self[AppNavigationCommandsKey.self] }
        set { self[AppNavigationCommandsKey.self] = newValue }
    }

    var planCommands: PlanCommands? {
        get { self[PlanCommandsKey.self] }
        set { self[PlanCommandsKey.self] = newValue }
    }

    var planSidebarCommands: PlanSidebarCommands? {
        get { self[PlanSidebarCommandsKey.self] }
        set { self[PlanSidebarCommandsKey.self] = newValue }
    }

    var dishLibraryCommands: DishLibraryCommands? {
        get { self[DishLibraryCommandsKey.self] }
        set { self[DishLibraryCommandsKey.self] = newValue }
    }

    var dishCommands: DishCommands? {
        get { self[DishCommandsKey.self] }
        set { self[DishCommandsKey.self] = newValue }
    }

    var shoppingCommands: ShoppingCommands? {
        get { self[ShoppingCommandsKey.self] }
        set { self[ShoppingCommandsKey.self] = newValue }
    }
}
