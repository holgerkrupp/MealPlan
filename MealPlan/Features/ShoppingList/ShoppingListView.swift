import SwiftUI
import SwiftData
import CollaborationCore

@MainActor
struct ShoppingListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Query(sort: \ShoppingListItem.sortIndex) private var items: [ShoppingListItem]
    @Query(
        filter: #Predicate<Ingredient> { $0.isPantryStaple },
        sort: \Ingredient.name
    ) private var pantryIngredients: [Ingredient]

    @State private var newItemName = ""
    @State private var exportMessage: String?
    @State private var isExporting = false
    @State private var bringMessage: String?
    @State private var showingBringSetup = false
    @State private var showingPantryStaples = false
    @State private var confirmingClearAll = false
    @State private var showingPrint = false
    @State private var customAisleItemID: UUID?
    @State private var customAisleName = ""
    @State private var managedShoppingList: ManagedShoppingListSnapshot?
    @State private var managedError: String?
    @AppStorage("shoppingList.hideCheckedItems") private var hideCheckedItems = false
    /// Lets the menu bar's "New Shopping Item" drop the caret straight into
    /// the add field.
    @FocusState private var addItemFocused: Bool

    private var range: DayRange {
        appState.shoppingRange.dayRange(
            customStart: appState.shoppingCustomStart,
            customEnd: appState.shoppingCustomEnd
        )
    }

    private var visibleItems: [ShoppingListItem] {
        hideCheckedItems ? items.filter { !$0.isChecked } : items
    }

    private var managedMode: Bool {
        guard let householdID = appState.currentHousehold?.uuid else { return false }
        return ManagedHouseholdRolloutAuthority.shared.usesManagedWriter(for: householdID)
    }

    private var visibleRowSnapshots: [ShoppingListRowSnapshot] {
        if managedMode {
            let values = managedShoppingList?.items ?? []
            return values.filter { !hideCheckedItems || !$0.isChecked }.map(ShoppingListRowSnapshot.init)
        }
        return visibleItems.map(ShoppingListRowSnapshot.init)
    }

    private var rowSnapshots: [ShoppingListRowSnapshot] {
        if managedMode { return (managedShoppingList?.items ?? []).map(ShoppingListRowSnapshot.init) }
        return items.map(ShoppingListRowSnapshot.init)
    }

    private var hasShoppingItems: Bool { managedMode ? !(managedShoppingList?.items.isEmpty ?? true) : !items.isEmpty }
    private var hasVisibleShoppingItems: Bool { !visibleRowSnapshots.isEmpty }
    private var hasCheckedShoppingItems: Bool { rowSnapshots.contains(where: \.isChecked) }

    private var managedCanEdit: Bool {
        guard managedMode, let householdID = appState.currentHousehold?.uuid,
              let collaboration = appState.managedCollaboration else { return false }
        let access = collaboration.effectiveAccess(for: householdID)
        return access == .owner || access == .editor
    }

    private var canEditList: Bool { managedMode ? managedCanEdit : !appState.isGuest }

    private var bringService: BringSyncService { .shared }

    /// Whether this family has a Bring! list to send to at all. The account
    /// itself is per device, so both have to be there.
    private var isConnectedToBring: Bool {
        !managedMode && appState.currentHousehold?.isConnectedToBring == true && bringService.hasAccount
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

    private var managedStapleSuggestions: [ManagedPantryIngredientSummary] {
        let onList = Set((managedShoppingList?.items ?? []).map { IngredientMatching.key(for: $0.name) })
        return (managedShoppingList?.pantryStaples ?? []).filter {
            !onList.contains(IngredientMatching.key(for: $0.name))
        }
    }

    /// Convert the live query into value snapshots before building rows. A
    /// rebuild may delete a model while SwiftUI still has an old row in its
    /// render tree; rows must never read that invalidated model again.
    private var groupedSnapshots: [ShoppingListRowGroup] {
        let snapshots = visibleRowSnapshots
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
                .disabled(!canEditList)
            }

            if managedMode {
                if let names = managedShoppingList?.missingIngredientDishNames, !names.isEmpty {
                    missingIngredientWarning(names)
                }
            } else {
                MissingIngredientWarningView(householdID: appState.currentHousehold?.uuid, range: range)
            }

            if managedError != nil && managedShoppingList == nil {
                managedUnavailableMessage
            } else if managedMode && managedShoppingList == nil {
                ProgressView(String(localized: "Loading shopping list"))
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if !hasShoppingItems {
                ContentUnavailableView(
                    String(localized: "Nothing to buy yet"),
                    systemImage: "cart",
                    description: Text("Plan some meals, then rebuild the list — or add items yourself below.")
                )
            } else if !hasVisibleShoppingItems {
                ContentUnavailableView(
                    String(localized: "All items are checked"),
                    systemImage: "checkmark.circle",
                    description: Text("Turn off “Hide checked items” to show them again.")
                )
            }

            ForEach(groupedSnapshots) { group in
                rowGroup(group)
            }

            Section {
                HStack {
                    TextField(String(localized: "Add an item"), text: $newItemName)
                        .focused($addItemFocused)
                        .onSubmit(addManualItem)
                    Button(String(localized: "Add"), action: addManualItem)
                        .disabled(newItemName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if managedMode, !managedStapleSuggestions.isEmpty {
                    Menu {
                        ForEach(managedStapleSuggestions) { ingredient in
                            Button(ingredient.name) { addManagedStaple(ingredient) }
                        }
                    } label: {
                        Label(String(localized: "Add a staple"), systemImage: "shippingbox")
                    }
                } else if !managedMode, !stapleSuggestions.isEmpty {
                    Menu {
                        ForEach(stapleSuggestions) { ingredient in
                            Button(ingredient.name) { addStaple(ingredient) }
                        }
                    } label: {
                        Label(String(localized: "Add a staple"), systemImage: "shippingbox")
                    }
                }
            } footer: {
                Text("Pantry staples never come out of the plan onto the list. Run out of one? Add it here — it stays put when the list is rebuilt.")
            }
            .disabled(!canEditList)
        }
        .navigationTitle(AppSection.shopping.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: shareText) {
                    Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
                }
                .disabled(!hasShoppingItems)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
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
                    .disabled(!hasShoppingItems)
                    #if os(iOS)
                    Button {
                        Task { await exportToReminders() }
                    } label: {
                        Label(String(localized: "Add to Reminders"), systemImage: "list.bullet")
                    }
                    .disabled(isExporting || !hasShoppingItems)
                    #endif
                    Toggle(isOn: $hideCheckedItems) {
                        Label(String(localized: "Hide checked items"), systemImage: "eye.slash")
                    }

                    Divider()

                    Button(String(localized: "Clear ticked items"), role: .destructive) {
                        clearChecked()
                    }
                    .disabled(!canEditList || !hasCheckedShoppingItems)
                    Button(String(localized: "Clear the whole list"), role: .destructive) {
                        confirmingClearAll = true
                    }
                    .disabled(!canEditList || !hasShoppingItems)

                    Divider()

                    if isConnectedToBring {
                        Button {
                            Task { await sendToBring() }
                        } label: {
                            Label(String(localized: "Send to Bring!"), systemImage: "arrow.up.doc")
                        }
                        .disabled(!hasShoppingItems || bringService.isSyncing)
                        Button {
                            Task { await syncWithBring() }
                        } label: {
                            Label(String(localized: "Sync with Bring!"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(bringService.isSyncing)
                    }
                    if !managedMode {
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
        .onChange(of: appState.shoppingRange) { _, _ in regenerate() }
        .task(id: "\(appState.currentHousehold?.uuid.uuidString ?? "none")-\(managedMode)-\(appState.managedCollaboration != nil)-\(range.start.timeIntervalSinceReferenceDate)-\(range.end.timeIntervalSinceReferenceDate)") {
            reloadManagedShoppingList()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mealPlanManagedStoreDidChange)) { _ in
            reloadManagedShoppingList()
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
            PrintPlanSheet(
                referenceWeek: .now,
                initialContent: .shoppingList,
                managedShoppingItems: managedMode ? (managedShoppingList?.items ?? []) : nil
            )
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
            bringAlertMessage
        }
        .alert(
            String(localized: "Shopping list update failed"),
            isPresented: Binding(get: { managedError != nil }, set: { if !$0 { managedError = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) { managedError = nil }
        } message: {
            Text(managedError ?? String(localized: "Please try again."))
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
        if hasShoppingItems {
            commands.printList = { showingPrint = true }
        }
        #if os(iOS)
        if !isExporting, hasShoppingItems {
            commands.addToReminders = { Task { await exportToReminders() } }
        }
        #endif
        if hasCheckedShoppingItems {
            commands.clearTicked = { clearChecked() }
        }
        if hasShoppingItems {
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
        var lines: [String] = [String(localized: "Shopping list")]
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

    private var bringAlertMessage: Text { Text(verbatim: bringMessage ?? "") }

    private var managedUnavailableMessage: some View {
        VStack(spacing: 8) {
            ContentUnavailableView(
                String(localized: "Shopping list unavailable"),
                systemImage: "externaldrive.badge.exclamationmark",
                description: Text(managedError ?? String(localized: "Please try again."))
            )
            Button(String(localized: "Try again")) { reloadManagedShoppingList() }
        }
    }

    // MARK: - Actions

    private func regenerate() {
        if managedMode {
            guard let householdID = appState.currentHousehold?.uuid,
                  let collaboration = appState.managedCollaboration else { return }
            do {
                try collaboration.regenerateShoppingList(
                    for: householdID,
                    range: range,
                    system: appState.unitSystem,
                    roundsAmounts: appState.roundsDisplayedAmounts
                )
                reloadManagedShoppingList()
            } catch { managedError = error.localizedDescription }
            return
        }
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

    private func reloadManagedShoppingList() {
        guard managedMode else {
            managedShoppingList = nil
            managedError = nil
            return
        }
        guard let householdID = appState.currentHousehold?.uuid,
              let collaboration = appState.managedCollaboration else {
            managedShoppingList = nil
            return
        }
        do {
            managedShoppingList = try collaboration.shoppingListSnapshot(for: householdID, range: range)
            managedError = nil
        } catch {
            managedShoppingList = nil
            managedError = error.localizedDescription
        }
    }

    private func rowGroup(_ group: ShoppingListRowGroup) -> some View {
        Section(group.name) {
            ForEach(group.items) { item in
                ShoppingListRow(
                    snapshot: item,
                    isEditable: canEditList,
                    onToggle: { toggle(item.id) },
                    onCategoryChange: { changeCategory(item.id, to: $0) },
                    onCustomAisle: { beginCustomAisle(for: item.id) },
                    onSetStaple: { setStaple(item.id, $0) },
                    onMarkOwned: { markOwned(item.id) }
                )
            }
            .onDelete(perform: canEditList ? { offsets in delete(offsets, in: group.items) } : nil)
        }
    }

    @ViewBuilder
    private func missingIngredientWarning(_ names: [String]) -> some View {
        Section {
            Label(String(localized: "Some planned recipes are missing ingredients"), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(String(localized: "Ingredients could not be imported for \(names.joined(separator: ", ")). Add them to the recipe before shopping."))
                .font(.footnote)
        }
    }

    private func currentItem(_ id: UUID) -> ShoppingListItem? {
        items.first { $0.uuid == id }
    }

    private func toggle(_ id: UUID) {
        if managedMode {
            guard let householdID = appState.currentHousehold?.uuid,
                  let collaboration = appState.managedCollaboration,
                  let item = managedShoppingList?.items.first(where: { $0.id == id }) else { return }
            do {
                try collaboration.setShoppingItemChecked(!item.isChecked, itemID: id, in: householdID)
                reloadManagedShoppingList()
            } catch { managedError = error.localizedDescription }
            return
        }
        guard let item = currentItem(id) else { return }
        withAnimation {
            ShoppingListMutationService.setChecked(item, checked: !item.isChecked, context: context)
        }
    }

    private func markOwned(_ id: UUID) {
        if managedMode {
            guard let householdID = appState.currentHousehold?.uuid,
                  let collaboration = appState.managedCollaboration else { return }
            do {
                try collaboration.markShoppingItemOwned(
                    id, in: householdID, range: range,
                    system: appState.unitSystem,
                    roundsAmounts: appState.roundsDisplayedAmounts
                )
                reloadManagedShoppingList()
            } catch { managedError = error.localizedDescription }
            return
        }
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

    private func addManualItem() {
        if managedMode {
            guard let householdID = appState.currentHousehold?.uuid,
                  let collaboration = appState.managedCollaboration else { return }
            do {
                try collaboration.addManagedShoppingItem(
                    named: newItemName,
                    householdID: householdID,
                    system: appState.unitSystem,
                    roundsAmounts: appState.roundsDisplayedAmounts
                )
                newItemName = ""
                reloadManagedShoppingList()
            } catch { managedError = error.localizedDescription }
            return
        }
        guard let household = appState.currentHousehold else { return }
        ShoppingListBuilder.addManualItem(
            named: newItemName,
            household: household,
            system: appState.unitSystem,
            roundsAmounts: appState.roundsDisplayedAmounts,
            context: context
        )
        newItemName = ""
    }

    /// Put a staple on the list by hand — "we've run out of salt".
    private func addStaple(_ ingredient: Ingredient) {
        guard let household = appState.currentHousehold else { return }
        ShoppingListBuilder.addManualItem(for: ingredient, household: household, context: context)
    }

    private func addManagedStaple(_ ingredient: ManagedPantryIngredientSummary) {
        guard let householdID = appState.currentHousehold?.uuid,
              let collaboration = appState.managedCollaboration else { return }
        do {
            try collaboration.addPantryStapleToShoppingList(ingredientID: ingredient.id, in: householdID)
            reloadManagedShoppingList()
        } catch { managedError = error.localizedDescription }
    }

    private func delete(_ offsets: IndexSet, in list: [ShoppingListRowSnapshot]) {
        let ids = offsets.compactMap { list.indices.contains($0) ? list[$0].id : nil }
        if managedMode {
            guard let householdID = appState.currentHousehold?.uuid else { return }
            do {
                try appState.managedCollaboration?.deleteShoppingItems(ids, in: householdID)
                reloadManagedShoppingList()
            } catch { managedError = error.localizedDescription }
            return
        }
        withoutUndoRegistration(in: context) {
            ShoppingListMutationService.delete(ids: ids, context: context)
        }
    }

    private func clearChecked() {
        if managedMode {
            guard let householdID = appState.currentHousehold?.uuid else { return }
            do {
                try appState.managedCollaboration?.deleteShoppingItems(
                    (managedShoppingList?.items ?? []).filter(\.isChecked).map(\.id),
                    in: householdID
                )
                reloadManagedShoppingList()
            } catch { managedError = error.localizedDescription }
            return
        }
        withoutUndoRegistration(in: context) {
            ShoppingListMutationService.clearCompleted(from: items, context: context)
        }
        Task { await autoSyncWithBring() }
    }

    /// Empty the list outright — the "we've been shopping, start again" button.
    /// Generated lines come back with the next rebuild; manual ones don't, so
    /// this asks first.
    private func clearAll() {
        if managedMode {
            guard let householdID = appState.currentHousehold?.uuid else { return }
            do {
                try appState.managedCollaboration?.deleteShoppingItems(
                    (managedShoppingList?.items ?? []).map(\.id),
                    in: householdID
                )
                reloadManagedShoppingList()
            } catch { managedError = error.localizedDescription }
            return
        }
        let ids = items.map(\.uuid)
        withoutUndoRegistration(in: context) {
            ShoppingListMutationService.delete(ids: ids, context: context)
        }
        Task { await autoSyncWithBring() }
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
        guard !managedMode else { return }
        guard let household = appState.currentHousehold else { return }
        await bringService.syncQuietly(household: household, context: context)
    }

    private func changeCategory(_ id: UUID, to category: IngredientCategory) {
        if managedMode {
            guard let householdID = appState.currentHousehold?.uuid,
                  let collaboration = appState.managedCollaboration else { return }
            do {
                try collaboration.changeShoppingItemCategory(category, itemID: id, in: householdID)
                reloadManagedShoppingList()
            } catch { managedError = error.localizedDescription }
            return
        }
        guard let item = currentItem(id) else { return }
        item.category = category
        item.customAisleName = nil
        item.ingredient?.category = category
        item.ingredient?.customAisleName = nil
        item.sortIndex = category.sortOrder * 1000 + item.sortIndex % 1000
        try? context.save()
    }

    private func beginCustomAisle(for id: UUID) {
        if managedMode {
            guard let item = managedShoppingList?.items.first(where: { $0.id == id }) else { return }
            customAisleName = item.customAisleName ?? ""
            customAisleItemID = id
            return
        }
        guard let item = currentItem(id) else { return }
        customAisleName = item.customAisleName ?? ""
        customAisleItemID = id
    }

    private func saveCustomAisle() {
        if managedMode {
            guard let id = customAisleItemID,
                  let householdID = appState.currentHousehold?.uuid,
                  let collaboration = appState.managedCollaboration else { return }
            do {
                try collaboration.setShoppingItemAisle(customAisleName, itemID: id, in: householdID)
                customAisleItemID = nil
                reloadManagedShoppingList()
            } catch { managedError = error.localizedDescription }
            return
        }
        guard let id = customAisleItemID, let item = currentItem(id) else { return }
        let trimmed = customAisleName.trimmingCharacters(in: .whitespacesAndNewlines)
        item.customAisleName = trimmed.isEmpty ? nil : trimmed
        item.ingredient?.customAisleName = item.customAisleName
        try? context.save()
        customAisleItemID = nil
    }

    private func clearCustomAisle() {
        if managedMode {
            guard let id = customAisleItemID,
                  let householdID = appState.currentHousehold?.uuid,
                  let collaboration = appState.managedCollaboration else { return }
            do {
                try collaboration.setShoppingItemAisle(nil, itemID: id, in: householdID)
                customAisleItemID = nil
                reloadManagedShoppingList()
            } catch { managedError = error.localizedDescription }
            return
        }
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
        if managedMode {
            guard let householdID = appState.currentHousehold?.uuid,
                  let collaboration = appState.managedCollaboration else { return }
            do {
                try collaboration.setShoppingItemStaple(isStaple, itemID: id, in: householdID)
                reloadManagedShoppingList()
            } catch { managedError = error.localizedDescription }
            return
        }
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
            let exportItems: [ShoppingListItem]
            if managedMode {
                exportItems = (managedShoppingList?.items ?? []).map { summary in
                    let item = ShoppingListItem(name: summary.name, category: summary.category, isManual: summary.isManual)
                    item.uuid = summary.id
                    item.displayText = summary.displayText
                    item.isChecked = summary.isChecked
                    return item
                }
            } else {
                exportItems = items
            }
            let count = try await RemindersExporter.export(exportItems)
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
