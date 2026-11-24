import SwiftUI
import SwiftData

/// Lightweight reusable combinations of dishes. Menus are deliberately kept
/// beside planning rather than settings: they are a quick way to fill one
/// date, not a second kind of routine or week template.
@MainActor
struct MealMenusView: View {
    let initialDate: Date
    let householdID: UUID?

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Query private var menus: [MealMenu]

    @State private var editingMenu: MealMenu?
    @State private var editingIsNew = false
    @State private var applyingMenu: MealMenu?
    @State private var deletingMenu: MealMenu?
    @State private var notice: String?

    init(initialDate: Date, householdID: UUID?) {
        self.initialDate = initialDate
        self.householdID = householdID
        let scopedHouseholdID = householdID ?? UUID()
        _menus = Query(FetchDescriptor<MealMenu>(
            predicate: #Predicate { $0.household?.uuid == scopedHouseholdID },
            sortBy: [SortDescriptor(\MealMenu.name), SortDescriptor(\MealMenu.dateCreated)]
        ))
    }

    var body: some View {
        List {
            Section {
                if menus.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No menus yet"),
                        systemImage: "square.stack.3d.up",
                        description: Text("Save a planned day or build a menu from dishes in your library.")
                    )
                } else {
                    ForEach(menus) { menu in
                        menuRow(menu)
                            .contextMenu {
                                menuActions(menu)
                            }
                    }
                    .onDelete { offsets in
                        deletingMenu = offsets.map { menus[$0] }.first
                    }
                }
            } header: {
                Text("Reusable menus")
            } footer: {
                Text("Menus remember dishes and optional meal slots. Applying one never replaces an existing meal unless you choose to replace it.")
            }
        }
        .overlay {
            if let notice {
                Text(notice)
                    .font(.callout)
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .navigationTitle(String(localized: "Menus"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(String(localized: "New menu"), systemImage: "plus") {
                        createMenu()
                    }
                    Button(String(localized: "Save selected day as menu"), systemImage: "calendar.badge.plus") {
                        saveSelectedDay()
                    }
                    .disabled(appState.isGuest)
                } label: {
                    Label(String(localized: "Add menu"), systemImage: "plus")
                }
                .disabled(appState.isGuest)
            }
        }
        .sheet(item: $editingMenu) { menu in
            NavigationStack {
                MealMenuEditor(menu: menu, isNew: editingIsNew)
            }
            .dismissesOnOutsideClick()
        }
        .sheet(item: $applyingMenu) { menu in
            ApplyMealMenuSheet(menu: menu, initialDate: initialDate)
                .dismissesOnOutsideClick()
        }
        .confirmationDialog(
            String(localized: "Delete menu?"),
            isPresented: Binding(get: { deletingMenu != nil }, set: { if !$0 { deletingMenu = nil } }),
            presenting: deletingMenu
        ) { menu in
            Button(String(localized: "Delete"), role: .destructive) {
                context.delete(menu)
                try? context.save()
                deletingMenu = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) { deletingMenu = nil }
        } message: { menu in
            Text(String(localized: "\(menu.name) will be removed. The dishes and planned meals will stay."))
        }
    }

    private func menuRow(_ menu: MealMenu) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(menu.name.isEmpty ? String(localized: "Untitled menu") : menu.name)
                    .font(.headline)
                Text(menuSummary(menu))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(String(localized: "Apply"), systemImage: "arrow.down.to.line.compact") {
                applyingMenu = menu
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "Apply \(menu.name)"))
        }
        .contentShape(Rectangle())
        .onTapGesture { editingMenu = menu; editingIsNew = false }
        .accessibilityElement(children: .combine)
        .accessibilityHint(String(localized: "Opens the menu editor"))
    }

    @ViewBuilder
    private func menuActions(_ menu: MealMenu) -> some View {
        Button(String(localized: "Apply"), systemImage: "arrow.down.to.line.compact") { applyingMenu = menu }
        Button(String(localized: "Edit"), systemImage: "pencil") { editingMenu = menu; editingIsNew = false }
        Button(String(localized: "Duplicate"), systemImage: "plus.square.on.square") { duplicate(menu) }
        Divider()
        Button(String(localized: "Delete"), systemImage: "trash", role: .destructive) { deletingMenu = menu }
    }

    private func createMenu() {
        guard !appState.isGuest, let household = appState.currentHousehold else { return }
        let menu = MealMenu()
        menu.household = household
        menu.createdByName = appState.currentMemberName
        context.insert(menu)
        editingIsNew = true
        editingMenu = menu
    }

    private func duplicate(_ source: MealMenu) {
        guard !appState.isGuest, let household = appState.currentHousehold else { return }
        let copy = MealMenu(name: String(localized: "Copy of \(source.name)"))
        copy.household = household
        copy.createdByName = appState.currentMemberName
        context.insert(copy)
        for entry in source.sortedEntries {
            let copyEntry = MealMenuEntry(dish: entry.dish, mealKey: entry.mealKey, servingsOverride: entry.servingsOverride, sortIndex: entry.sortIndex)
            copyEntry.menu = copy
            context.insert(copyEntry)
        }
        try? context.save()
        editingIsNew = false
        editingMenu = copy
    }

    private func saveSelectedDay() {
        guard !appState.isGuest, let household = appState.currentHousehold else { return }
        do {
            guard let menu = try MealMenuPlanner.makeFromPlannedDate(
                appState.selectedDate,
                name: String(localized: "Menu for \(appState.selectedDate.formatted(date: .abbreviated, time: .omitted))"),
                household: household,
                createdBy: appState.currentMemberName,
                context: context
            ) else {
                notice = String(localized: "There are no planned dishes on this day to save.")
                return
            }
            editingIsNew = false
            editingMenu = menu
        } catch {
            notice = String(localized: "The menu could not be saved: \(error.localizedDescription)")
        }
    }

    private func menuSummary(_ menu: MealMenu) -> String {
        let count = menu.sortedEntries.count
        let dishes = count == 1 ? String(localized: "1 dish") : String(localized: "\(count) dishes")
        guard menu.missingDishCount > 0 else { return dishes }
        return String(localized: "\(dishes) · \(menu.missingDishCount) missing")
    }
}

@MainActor
private struct MealMenuEditor: View {
    @Bindable var menu: MealMenu
    let isNew: Bool

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var dishes: [Dish]
    @Query private var mealTypes: [MealType]
    @State private var showingDishPicker = false
    @State private var errorMessage: String?

    init(menu: MealMenu, isNew: Bool) {
        self.menu = menu
        self.isNew = isNew
        let householdID = menu.household?.uuid ?? UUID()
        _dishes = Query(FetchDescriptor<Dish>(
            predicate: #Predicate { $0.household?.uuid == householdID },
            sortBy: [SortDescriptor(\Dish.name)]
        ))
        _mealTypes = Query(FetchDescriptor<MealType>(
            predicate: #Predicate { $0.household?.uuid == householdID },
            sortBy: [SortDescriptor(\MealType.sortOrder), SortDescriptor(\MealType.name)]
        ))
    }

    var body: some View {
        Form {
            Section(String(localized: "Menu name")) {
                TextField(String(localized: "e.g. Taco night"), text: $menu.name)
                    .accessibilityLabel(String(localized: "Menu name"))
            }

            Section {
                if menu.sortedEntries.isEmpty {
                    Text(String(localized: "Add dishes from your library."))
                        .foregroundStyle(.secondary)
                }
                ForEach(menu.sortedEntries) { entry in
                    menuEntryRow(entry)
                }
                .onDelete { offsets in
                    let ids = offsets.map { menu.sortedEntries[$0].uuid }
                    menu.entries?.removeAll { ids.contains($0.uuid) }
                }
                Button(String(localized: "Add dish"), systemImage: "plus.circle") {
                    showingDishPicker = true
                }
            } header: {
                Text("Dishes")
            } footer: {
                Text("Meal slots are optional. When a slot is not saved, the slot selected during application is used.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: isNew ? "New menu" : "Edit menu"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel")) {
                    if isNew { context.delete(menu) }
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Done")) { save() }
                    .disabled(menu.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || menu.sortedEntries.isEmpty)
            }
        }
        .sheet(isPresented: $showingDishPicker) {
            DishSelectionSheet(dishes: dishes) { dish in
                let nextIndex = (menu.entries ?? []).map(\.sortIndex).max().map { $0 + 1 } ?? 0
                let entry = MealMenuEntry(dish: dish, sortIndex: nextIndex)
                entry.menu = menu
                context.insert(entry)
            }
            .dismissesOnOutsideClick()
        }
        .alert(String(localized: "Menu could not be saved"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(String(localized: "OK"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .disabled(appState.isGuest)
    }

    private func menuEntryRow(_ entry: MealMenuEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.dish?.name ?? String(localized: "Missing dish"))
                    .foregroundStyle(entry.dish == nil ? .secondary : .primary)
                Spacer()
                if entry.dish == nil {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityLabel(String(localized: "Recipe missing"))
                }
            }
            HStack {
                Picker(String(localized: "Meal slot"), selection: Binding<String?>(
                    get: { entry.mealKey },
                    set: { entry.mealKey = $0 }
                )) {
                    Text(String(localized: "Use selected slot")).tag(Optional<String>.none)
                    ForEach(mealTypes) { meal in
                        Text(meal.name).tag(Optional(meal.key))
                    }
                }
                .labelsHidden()
                .accessibilityLabel(String(localized: "Meal slot"))
                Stepper(value: Binding(
                    get: { entry.servingsOverride ?? 0 },
                    set: { entry.servingsOverride = $0 == 0 ? nil : $0 }
                ), in: 0...99) {
                    Text(entry.servingsOverride.map { String(localized: "\($0) servings") } ?? String(localized: "Household servings"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(String(localized: "Servings"))
            }
        }
    }

    private func save() {
        menu.name = menu.name.trimmingCharacters(in: .whitespacesAndNewlines)
        menu.modifiedAt = .now
        do {
            try context.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
private struct DishSelectionSheet: View {
    let dishes: [Dish]
    let onSelect: (Dish) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredDishes: [Dish] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return dishes }
        return dishes.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(filteredDishes) { dish in
                Button {
                    onSelect(dish)
                    dismiss()
                } label: {
                    HStack {
                        DishThumbnail(dish: dish, size: 40, cornerRadius: 8)
                        Text(dish.name)
                        Spacer()
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.tint)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Add \(dish.name)"))
            }
            .searchable(text: $searchText, prompt: String(localized: "Search dishes"))
            .navigationTitle(String(localized: "Choose a dish"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
        }
    }
}

@MainActor
private struct ApplyMealMenuSheet: View {
    let menu: MealMenu
    @State private var targetDate: Date
    @State private var selectedMealKey: String?
    @State private var replaceExisting = false
    @State private var showingPaywall = false
    @State private var errorMessage: String?

    @Environment(AppState.self) private var appState
    @Environment(PurchaseManager.self) private var purchaseManager
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var mealTypes: [MealType]

    init(menu: MealMenu, initialDate: Date) {
        self.menu = menu
        _targetDate = State(initialValue: initialDate.startOfDay)
        let householdID = menu.household?.uuid ?? UUID()
        _mealTypes = Query(FetchDescriptor<MealType>(
            predicate: #Predicate { $0.household?.uuid == householdID },
            sortBy: [SortDescriptor(\MealType.sortOrder), SortDescriptor(\MealType.name)]
        ))
    }

    private var preview: MealMenuPlanner.Preview {
        MealMenuPlanner.preview(menu, on: targetDate, mealKey: selectedMealKey, replaceExisting: replaceExisting, household: appState.currentHousehold, context: context)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Where")) {
                    DatePicker(String(localized: "Date"), selection: $targetDate, displayedComponents: .date)
                    Picker(String(localized: "Default meal slot"), selection: $selectedMealKey) {
                        Text(String(localized: "Use saved slots")).tag(Optional<String>.none)
                        ForEach(mealTypes) { meal in
                            Label(meal.name, systemImage: meal.symbolName).tag(Optional(meal.key))
                        }
                    }
                }

                Section(String(localized: "Review")) {
                    Toggle(String(localized: "Replace existing meals in affected slots"), isOn: $replaceExisting)
                    if preview.itemsToReplace > 0 {
                        Label(String(localized: "\(preview.itemsToReplace) existing meals will be removed"), systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.orange)
                    }
                    if preview.itemsToAdd > 0 {
                        Label(String(localized: "\(preview.itemsToAdd) dishes will be added"), systemImage: "plus.circle")
                    }
                    if preview.duplicateItems > 0 {
                        Label(String(localized: "\(preview.duplicateItems) duplicate dishes will be skipped"), systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(preview.missingDishNames, id: \.self) { name in
                        Label(String(localized: "\(name) is unavailable and will be skipped"), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if preview.isEmpty {
                        Text(String(localized: "Nothing new will be planned."))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Apply \(menu.name)"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Apply")) { apply() }
                        .disabled(preview.isEmpty || appState.isGuest)
                }
            }
            .detailPresentation(isPresented: $showingPaywall, route: .unlock) {
                PaywallView()
                    .dismissesOnOutsideClick()
            }
            .alert(String(localized: "Menu could not be applied"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button(String(localized: "OK"), role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func apply() {
        guard purchaseManager.canPlan(on: targetDate) else {
            showingPaywall = true
            return
        }
        do {
            let result = try MealMenuPlanner.apply(
                menu,
                on: targetDate,
                mealKey: selectedMealKey,
                replaceExisting: replaceExisting,
                household: appState.currentHousehold,
                memberName: appState.currentMemberName,
                context: context
            )
            dismiss()
            guard result.changedCount > 0 else { return }
            let title = menu.name
            appState.offerUndo(String(localized: "Applied \(title)")) {
                try? MealMenuPlanner.undo(result, in: context)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
