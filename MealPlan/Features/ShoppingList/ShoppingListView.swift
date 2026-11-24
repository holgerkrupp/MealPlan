import SwiftUI
import SwiftData

@MainActor
struct ShoppingListView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let householdID = appState.currentHousehold?.uuid
        ShoppingListContentView(householdID: householdID)
            .id(householdID)
    }
}

@MainActor
private struct ShoppingListContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Query private var storedItems: [ShoppingListItem]
    @Query private var lists: [ShoppingList]
    @Query private var pantryIngredients: [Ingredient]

    let householdID: UUID?

    @State private var newItemName = ""
    @State private var exportMessage: String?
    @State private var isExporting = false
    @State private var bringMessage: String?
    @State private var showingBringSetup = false
    @State private var showingPantryStaples = false
    @State private var showingPasteSheet = false
    @State private var showingBarcodeScanner = false
    @State private var confirmingClearAll = false
    @State private var showingPrint = false
    @State private var customAisleItemID: UUID?
    @State private var customAisleName = ""
    @State private var listNameDraft = ""
    @State private var listNameAction: ListNameAction?
    @State private var confirmingDeleteList = false
    @AppStorage("shoppingList.hideCheckedItems") private var hideCheckedItems = false
    /// Lets the menu bar's "New Shopping Item" drop the caret straight into
    /// the add field.
    @FocusState private var addItemFocused: Bool

    private enum ListNameAction {
        case create
        case rename
        case duplicate
    }

    init(householdID: UUID?) {
        self.householdID = householdID
        let scopedHouseholdID = householdID ?? UUID()
        _storedItems = Query(FetchDescriptor<ShoppingListItem>(
            predicate: #Predicate { $0.household?.uuid == scopedHouseholdID },
            sortBy: [SortDescriptor(\ShoppingListItem.sortIndex)]
        ))
        _lists = Query(FetchDescriptor<ShoppingList>(
            predicate: #Predicate { $0.household?.uuid == scopedHouseholdID },
            sortBy: [SortDescriptor(\ShoppingList.sortIndex), SortDescriptor(\ShoppingList.name)]
        ))
        _pantryIngredients = Query(FetchDescriptor<Ingredient>(
            predicate: #Predicate { $0.isPantryStaple && $0.household?.uuid == scopedHouseholdID },
            sortBy: [SortDescriptor(\Ingredient.name)]
        ))
    }

    private var range: DayRange {
        appState.shoppingRange.dayRange(
            customStart: appState.shoppingCustomStart,
            customEnd: appState.shoppingCustomEnd
        )
    }

    private var generatedList: ShoppingList? {
        guard let householdID else { return lists.first(where: \ShoppingList.isGenerated) }
        return lists.first { $0.uuid == ShoppingList.generatedID(for: householdID) }
            ?? lists.first(where: \ShoppingList.isGenerated)
    }

    private var activeList: ShoppingList? {
        let selectedID = selectedListID ?? generatedList?.uuid
        return lists.first { $0.uuid == selectedID } ?? generatedList
    }

    private var activeListID: UUID { activeList?.uuid ?? UUID() }

    @State private var selectedListID: UUID?

    private var items: [ShoppingListItem] {
        guard let activeList else { return [] }
        return storedItems.filter { item in
            item.list?.uuid == activeList.uuid || (activeList.isGenerated && item.list == nil)
        }
    }

    private var visibleItems: [ShoppingListItem] {
        hideCheckedItems ? items.filter { !$0.isChecked } : items
    }

    private var bringService: BringSyncService { .shared }

    /// Whether this family has a Bring! list to send to at all. The account
    /// itself is per device, so both have to be there.
    private var isConnectedToBring: Bool {
        appState.currentHousehold?.isConnectedToBring == true && bringService.hasAccount
    }

    /// The household's pantry staples that aren't on the list already. These
    /// are never planned onto it — see `PantryStaples` — so this menu is how
    /// one gets there on the day the family runs out.
    private var stapleSuggestions: [Ingredient] {
        let onList = Set(items.map { IngredientMatching.key(for: $0.name) })
        return pantryIngredients.filter {
            !onList.contains(IngredientMatching.key(for: $0.name))
        }
    }

    /// Convert the live query into value snapshots before building rows. A
    /// rebuild may delete a model while SwiftUI still has an old row in its
    /// render tree; rows must never read that invalidated model again.
    private var groupedSnapshots: [ShoppingListRowGroup] {
        let snapshots = visibleItems.map { ShoppingListRowSnapshot($0) }
        return Dictionary(grouping: snapshots, by: \.aisleName)
            .map { name, values in
                ShoppingListRowGroup(
                    name: name,
                    sortOrder: values.map { $0.category.sortOrder }.min()
                        ?? IngredientCategory.other.sortOrder,
                    items: values.sorted { $0.sortIndex < $1.sortIndex }
                )
            }
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
    }

    var body: some View {
        @Bindable var appState = appState

        List {
            #if os(iOS)
            FullPageScreenshotBridge()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            #endif

            Section {
                Picker(String(localized: "List"), selection: Binding(
                    get: { activeListID },
                    set: { selectedListID = $0 }
                )) {
                    ForEach(lists) { list in
                        Label(list.name, systemImage: list.isGenerated ? "calendar" : "list.bullet")
                            .tag(list.uuid)
                    }
                }
                .accessibilityHint(String(localized: "Choose which household shopping list to view and edit."))

                if activeList?.isGenerated == true {
                Picker(String(localized: "For"), selection: $appState.shoppingRange) {
                    ForEach(ShoppingRangeOption.allCases) { Text($0.localizedName).tag($0) }
                }
                if appState.shoppingRange == .custom {
                    DatePicker(String(localized: "From"), selection: $appState.shoppingCustomStart, displayedComponents: .date)
                    DatePicker(String(localized: "To"), selection: $appState.shoppingCustomEnd, displayedComponents: .date)
                }
                Button {
                    regenerate()
                } label: {
                    Label(String(localized: "Rebuild from plan"), systemImage: "arrow.triangle.2.circlepath")
                }
                } else {
                    Label(String(localized: "This list is independent of the meal plan."), systemImage: "checklist")
                        .foregroundStyle(.secondary)
                }
            }

            MissingIngredientWarningView(householdID: householdID, range: range)

            if items.isEmpty {
                ContentUnavailableView(
                    String(localized: "Nothing to buy yet"),
                    systemImage: "cart",
                    description: Text("Plan some meals, then rebuild the list — or add items yourself below.")
                )
            } else if visibleItems.isEmpty {
                ContentUnavailableView(
                    String(localized: "All items are checked"),
                    systemImage: "checkmark.circle",
                    description: Text("Turn off “Hide checked items” to show them again.")
                )
            }

            ForEach(groupedSnapshots) { group in
                Section(group.name) {
                    ForEach(group.items) { item in
                        ShoppingListRow(
                            snapshot: item,
                            otherLists: lists.filter { $0.uuid != activeList?.uuid },
                            onToggle: { toggle(item.id) },
                            onCategoryChange: { changeCategory(item.id, to: $0) },
                            onCustomAisle: { beginCustomAisle(for: item.id) },
                            onSetStaple: { setStaple(item.id, $0) },
                            onMarkOwned: { markOwned(item.id) },
                            onMoveTo: { move(item.id, to: $0) },
                            onCopyTo: { copy(item.id, to: $0) }
                        )
                    }
                    .onDelete { offsets in delete(offsets, in: group.items) }
                }
            }

            Section {
                HStack {
                    TextField(String(localized: "Add an item"), text: $newItemName)
                        .focused($addItemFocused)
                        .onSubmit(addManualItem)
                    Button(String(localized: "Add"), action: addManualItem)
                        .disabled(newItemName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button {
                    showingPasteSheet = true
                } label: {
                    Label(String(localized: "Add several items…"), systemImage: "list.bullet.clipboard")
                }
                if !appState.isGuest, BarcodeScanAvailability.isAvailable {
                    Button {
                        showingBarcodeScanner = true
                    } label: {
                        Label(String(localized: "Scan barcode…"), systemImage: "barcode.viewfinder")
                    }
                }
                if !stapleSuggestions.isEmpty {
                    Menu {
                        ForEach(stapleSuggestions) { ingredient in
                            Button(ingredient.name) { addStaple(ingredient) }
                        }
                    } label: {
                        Label(String(localized: "Add a staple"), systemImage: "shippingbox")
                    }
                }
            } footer: {
                Text(activeList?.isGenerated == true
                     ? "Pantry staples never come out of the plan onto this list. Run out of one? Add it here — it stays put when the list is rebuilt."
                     : "This list is independent from the meal plan. Items stay here until you move, check off, or remove them.")
            }
        }
        .navigationTitle(activeList?.name ?? AppSection.shopping.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: shareText) {
                    Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
                }
                .disabled(items.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        beginListNameEdit(.create)
                    } label: {
                        Label(String(localized: "New shopping list…"), systemImage: "plus")
                    }
                    if activeList?.isGenerated == false {
                        Button {
                            beginListNameEdit(.rename)
                        } label: {
                            Label(String(localized: "Rename list…"), systemImage: "pencil")
                        }
                        Button {
                            beginListNameEdit(.duplicate)
                        } label: {
                            Label(String(localized: "Duplicate list…"), systemImage: "plus.square.on.square")
                        }
                        Button(role: .destructive) {
                            confirmingDeleteList = true
                        } label: {
                            Label(String(localized: "Delete list"), systemImage: "trash")
                        }
                    }
                    Divider()
                    Button {
                        showingPantryStaples = true
                    } label: {
                        Label(String(localized: "Pantry staples…"), systemImage: "shippingbox")
                    }
                    Button {
                        showingPrint = true
                    } label: {
                        Label(String(localized: "Print list…"), systemImage: "printer")
                    }
                    .disabled(items.isEmpty)
                    #if os(iOS)
                    Button {
                        Task { await exportToReminders() }
                    } label: {
                        Label(String(localized: "Add to Reminders"), systemImage: "list.bullet")
                    }
                    .disabled(isExporting || items.isEmpty)
                    #endif
                    Toggle(isOn: $hideCheckedItems) {
                        Label(String(localized: "Hide checked items"), systemImage: "eye.slash")
                    }

                    Divider()

                    Button(String(localized: "Clear ticked items"), role: .destructive) {
                        clearChecked()
                    }
                    .disabled(!items.contains(where: \.isChecked))
                    Button(String(localized: "Clear the whole list"), role: .destructive) {
                        confirmingClearAll = true
                    }
                    .disabled(items.isEmpty)

                    Divider()

                    if isConnectedToBring, activeList?.isGenerated == true {
                        Button {
                            Task { await sendToBring() }
                        } label: {
                            Label(String(localized: "Send to Bring!"), systemImage: "arrow.up.doc")
                        }
                        .disabled(items.isEmpty || bringService.isSyncing)
                        Button {
                            Task { await syncWithBring() }
                        } label: {
                            Label(String(localized: "Sync with Bring!"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(bringService.isSyncing)
                    }
                    Button {
                        showingBringSetup = true
                    } label: {
                        Label(
                            isConnectedToBring
                                ? String(localized: "Bring! settings…")
                                : String(localized: "Connect to Bring!…"),
                            systemImage: "cart.badge.plus"
                        )
                    }
                } label: {
                    Label(String(localized: "More"), systemImage: "ellipsis")
                }
            }
        }
        // An empty list is a valid result. Rebuilding it synchronously every
        // time this tab appears can walk a large plan and block the tab
        // transition; the explicit Rebuild button remains directly above.
        .task(priority: .utility) {
            // Let the tab transition finish before optional network work.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await autoSyncWithBring()
        }
        .macWindowMargins()
        .focusedSceneValue(\.shoppingCommands, shoppingCommands)
        .onChange(of: appState.shoppingRange) { _, _ in
            if activeList?.isGenerated == true { regenerate() }
        }
        .detailPresentation(isPresented: $showingBringSetup, route: .bringSettings) {
            NavigationStack {
                BringSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "Done")) { showingBringSetup = false }
                        }
                    }
            }
        }
        .detailPresentation(isPresented: $showingPrint, route: .printShoppingList) {
            PrintPlanSheet(referenceWeek: .now, initialContent: .shoppingList, shoppingListID: activeList?.uuid)
                .dismissesOnOutsideClick()
        }
        .detailPresentation(isPresented: $showingPantryStaples, route: .pantryStaples) {
            NavigationStack {
                PantryStaplesView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "Done")) { showingPantryStaples = false }
                        }
                    }
            }
            .dismissesOnOutsideClick()
        }
        .sheet(isPresented: $showingPasteSheet) {
            ShoppingListPasteSheet { lines in addManualItems(lines) }
        }
        .sheet(isPresented: $showingBarcodeScanner) {
            BarcodeAddSheet(defaultDestination: .shoppingList)
        }
        .confirmationDialog(
            String(localized: "Clear the whole list?"),
            isPresented: $confirmingClearAll,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Clear everything"), role: .destructive) { clearAll() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(isConnectedToBring
                 ? String(localized: "Every line goes, ticked or not, here and — at the next sync — in Bring! too. Rebuild from the plan to get the planned ones back.")
                 : String(localized: "Every line goes, ticked or not. Rebuild from the plan to get the planned ones back."))
        }
        .alert(
            String(localized: "Bring!"),
            isPresented: Binding(get: { bringMessage != nil }, set: { if !$0 { bringMessage = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(bringMessage ?? "")
        }
        .alert(
            String(localized: "Reminders"),
            isPresented: Binding(get: { exportMessage != nil }, set: { if !$0 { exportMessage = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(exportMessage ?? "")
        }
        .alert(
            String(localized: "Custom aisle"),
            isPresented: Binding(get: { customAisleItemID != nil }, set: { if !$0 { customAisleItemID = nil } })
        ) {
            TextField(String(localized: "Aisle name"), text: $customAisleName)
            Button(String(localized: "Save")) { saveCustomAisle() }
            Button(String(localized: "Use standard aisle")) { clearCustomAisle() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("This aisle name will be remembered for the ingredient.")
        }
        .alert(
            String(localized: "Shopping list"),
            isPresented: Binding(
                get: { listNameAction != nil },
                set: { if !$0 { listNameAction = nil } }
            )
        ) {
            TextField(String(localized: "List name"), text: $listNameDraft)
            Button(String(localized: "Save")) { saveListName() }
            Button(String(localized: "Cancel"), role: .cancel) { listNameAction = nil }
        } message: {
            Text(String(localized: "Named lists are shared with your household and are independent of the meal plan."))
        }
        .confirmationDialog(
            String(localized: "Delete this shopping list?"),
            isPresented: $confirmingDeleteList,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete list"), role: .destructive) { deleteActiveList() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Its items will also be removed from this household list. The plan groceries list is not affected."))
        }
    }

    /// What the Shopping menu can do right now. Reminders export exists only
    /// on iOS, and only the two list-emptying actions care whether the list
    /// has anything in it.
    private var shoppingCommands: ShoppingCommands {
        var commands = ShoppingCommands(
            range: appState.shoppingRange,
            rebuild: { regenerate() },
            addItem: { addItemFocused = true },
            setRange: { appState.shoppingRange = $0 }
        )
        if !items.isEmpty {
            commands.printList = { showingPrint = true }
        }
        #if os(iOS)
        if !isExporting, !items.isEmpty {
            commands.addToReminders = { Task { await exportToReminders() } }
        }
        #endif
        if items.contains(where: \.isChecked) {
            commands.clearTicked = { clearChecked() }
        }
        if !items.isEmpty {
            commands.clearAll = { confirmingClearAll = true }
        }
        if isConnectedToBring, !bringService.isSyncing {
            commands.sendToBring = { Task { await sendToBring() } }
            commands.syncWithBring = { Task { await syncWithBring() } }
        }
        return commands
    }

    // MARK: - Text for sharing

    private var shareText: String {
        var lines: [String] = [activeList?.name ?? String(localized: "Shopping list")]
        for group in groupedSnapshots {
            lines.append("")
            lines.append(group.name.uppercased())
            for item in group.items where !item.isChecked {
                if let amount = item.displayText, !amount.isEmpty {
                    lines.append("• \(item.name) — \(amount)")
                } else {
                    lines.append("• \(item.name)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Actions

    private func regenerate() {
        guard let household = appState.currentHousehold else { return }
        ShoppingListBuilder.regenerate(
            range: range,
            household: household,
            system: appState.unitSystem,
            roundsAmounts: appState.roundsDisplayedAmounts,
            context: context
        )
        Task { await autoSyncWithBring() }
    }

    private func beginListNameEdit(_ action: ListNameAction) {
        listNameAction = action
        switch action {
        case .create: listNameDraft = ""
        case .rename: listNameDraft = activeList?.name ?? ""
        case .duplicate:
            listNameDraft = String(localized: "Copy of \(activeList?.name ?? String(localized: "Shopping list"))")
        }
    }

    private func saveListName() {
        guard let household = appState.currentHousehold else { return }
        let action = listNameAction
        listNameAction = nil
        switch action {
        case .create:
            if let created = ShoppingListMutationService.createList(named: listNameDraft, household: household, context: context) {
                selectedListID = created.uuid
            }
        case .rename:
            if let activeList { _ = ShoppingListMutationService.rename(activeList, to: listNameDraft, context: context) }
        case .duplicate:
            if let activeList, let copy = ShoppingListMutationService.duplicate(activeList, named: listNameDraft, context: context) {
                selectedListID = copy.uuid
            }
        case nil:
            break
        }
    }

    private func deleteActiveList() {
        guard let activeList, ShoppingListMutationService.deleteList(activeList, context: context) else { return }
        selectedListID = generatedList?.uuid
    }

    private func currentItem(_ id: UUID) -> ShoppingListItem? {
        items.first { $0.uuid == id }
    }

    private func toggle(_ id: UUID) {
        guard let item = currentItem(id) else { return }
        withAnimation {
            ShoppingListMutationService.setChecked(item, checked: !item.isChecked, context: context)
        }
    }

    private func markOwned(_ id: UUID) {
        guard let item = currentItem(id) else { return }
        guard let household = appState.currentHousehold else { return }
        let ingredient = item.ingredient ?? {
            let created = Ingredient(name: item.name, category: item.category)
            created.household = household
            context.insert(created)
            item.ingredient = created
            return created
        }()
        household.inventoryEnabled = true
        let quantity = item.canonicalValue.flatMap { value in
            item.dimension.map { Quantity(value: value, dimension: $0) }
        }
        ingredient.markInventory(.have, quantity: quantity)
        regenerate()
    }

    /// A paste of several lines into the add field becomes several items.
    private func addManualItem() {
        let lines = ShoppingListPaste.isMultiLine(newItemName)
            ? ShoppingListPaste.lines(from: newItemName)
            : [newItemName]
        addManualItems(lines)
        newItemName = ""
    }

    private func addManualItems(_ lines: [String]) {
        guard let household = appState.currentHousehold else { return }
        for line in lines {
            ShoppingListBuilder.addManualItem(
                named: line,
                household: household,
                system: appState.unitSystem,
                roundsAmounts: appState.roundsDisplayedAmounts,
                list: activeList,
                context: context
            )
        }
    }

    /// Put a staple on the list by hand — "we've run out of salt".
    private func addStaple(_ ingredient: Ingredient) {
        guard let household = appState.currentHousehold else { return }
        ShoppingListBuilder.addManualItem(for: ingredient, household: household, list: activeList, context: context)
    }

    private func delete(_ offsets: IndexSet, in list: [ShoppingListRowSnapshot]) {
        let ids = offsets.compactMap { list.indices.contains($0) ? list[$0].id : nil }
        withoutUndoRegistration(in: context) {
            ShoppingListMutationService.delete(ids: ids, context: context)
        }
    }

    private func clearChecked() {
        withoutUndoRegistration(in: context) {
            ShoppingListMutationService.clearCompleted(from: items, context: context)
        }
        Task { await autoSyncWithBring() }
    }

    /// Empty the list outright — the "we've been shopping, start again" button.
    /// Generated lines come back with the next rebuild; manual ones don't, so
    /// this asks first.
    private func clearAll() {
        let ids = items.map(\.uuid)
        withoutUndoRegistration(in: context) {
            ShoppingListMutationService.delete(ids: ids, context: context)
        }
        Task { await autoSyncWithBring() }
    }

    private func move(_ id: UUID, to list: ShoppingList) {
        guard let item = currentItem(id) else { return }
        ShoppingListMutationService.move(item, to: list, context: context)
    }

    private func copy(_ id: UUID, to list: ShoppingList) {
        guard let item = currentItem(id) else { return }
        _ = ShoppingListMutationService.copy(item, to: list, context: context)
    }

    // MARK: - Bring!

    private func sendToBring() async {
        guard let household = appState.currentHousehold else { return }
        do {
            let outcome = try await bringService.push(household: household, context: context)
            bringMessage = outcome.summary
        } catch {
            bringMessage = error.localizedDescription
        }
    }

    private func syncWithBring() async {
        guard let household = appState.currentHousehold else { return }
        do {
            let outcome = try await bringService.sync(household: household, context: context)
            bringMessage = outcome.summary
        } catch {
            bringMessage = error.localizedDescription
        }
    }

    /// The sync nobody asked for: on opening the list, and after it changes.
    /// Says nothing either way — a Bring! that can't be reached is not a
    /// reason to interrupt someone reading their shopping list.
    private func autoSyncWithBring() async {
        guard let household = appState.currentHousehold else { return }
        await bringService.syncQuietly(household: household, context: context)
    }

    private func changeCategory(_ id: UUID, to category: IngredientCategory) {
        guard let item = currentItem(id) else { return }
        item.category = category
        item.customAisleName = nil
        item.ingredient?.category = category
        item.ingredient?.customAisleName = nil
        item.sortIndex = category.sortOrder * 1000 + item.sortIndex % 1000
        try? context.save()
    }

    private func beginCustomAisle(for id: UUID) {
        guard let item = currentItem(id) else { return }
        customAisleName = item.customAisleName ?? ""
        customAisleItemID = id
    }

    private func saveCustomAisle() {
        guard let id = customAisleItemID, let item = currentItem(id) else { return }
        let trimmed = customAisleName.trimmingCharacters(in: .whitespacesAndNewlines)
        item.customAisleName = trimmed.isEmpty ? nil : trimmed
        item.ingredient?.customAisleName = item.customAisleName
        try? context.save()
        customAisleItemID = nil
    }

    private func clearCustomAisle() {
        guard let id = customAisleItemID, let item = currentItem(id) else { return }
        item.customAisleName = nil
        item.ingredient?.customAisleName = nil
        try? context.save()
        customAisleItemID = nil
    }

    /// Promote a line to a household staple (or take it back off the list of
    /// them). A line that was planned onto the list is dropped along the way —
    /// the point of a staple is that it isn't bought week by week — while a
    /// line the family added by hand stays, because they asked for it.
    private func setStaple(_ id: UUID, _ isStaple: Bool) {
        guard let item = currentItem(id) else { return }
        guard let household = appState.currentHousehold else { return }
        withoutUndoRegistration(in: context) {
            if let ingredient = item.ingredient {
                ingredient.isPantryStaple = isStaple
            } else if isStaple {
                item.ingredient = PantryStaples.add(
                    named: item.name,
                    category: item.category,
                    to: household,
                    context: context
                )
            }
            if isStaple, !item.isManual {
                context.delete(item)
            }
            try? context.save()
        }
    }

    #if os(iOS)
    private func exportToReminders() async {
        isExporting = true
        defer { isExporting = false }
        do {
            let count = try await RemindersExporter.export(items)
            exportMessage = String(localized: "Added \(count) items to your “MealPlan” list in Reminders.")
        } catch {
            exportMessage = error.localizedDescription
        }
    }
    #endif
}

/// Owns a date- and household-scoped query so calculating the warning never
/// faults the household's complete entries relationship.
@MainActor
private struct MissingIngredientWarningView: View {
    @Query private var entries: [MealPlanEntry]

    init(householdID: UUID?, range: DayRange) {
        let start = range.start
        let end = range.end
        if let householdID {
            let predicate = #Predicate<MealPlanEntry> {
                $0.date >= start && $0.date < end && $0.household?.uuid == householdID
            }
            _entries = Query(FetchDescriptor(predicate: predicate))
        } else {
            _entries = Query(FetchDescriptor<MealPlanEntry>(predicate: #Predicate { _ in false }))
        }
    }

    var body: some View {
        let names = ShoppingListBuilder.missingIngredientDishNames(entries)
        if names.isEmpty {
            EmptyView()
        } else {
            Section {
                Label(String(localized: "Some planned recipes are missing ingredients"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(String(localized: "Ingredients could not be imported for \(names.joined(separator: ", ")). Add them to the recipe before shopping."))
                    .font(.footnote)
            }
        }
    }
}

#Preview {
    NavigationStack { ShoppingListView() }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
