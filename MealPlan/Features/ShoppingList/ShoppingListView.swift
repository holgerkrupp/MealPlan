import SwiftUI
import SwiftData

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
    @State private var customAisleItem: ShoppingListItem?
    @State private var customAisleName = ""
    @AppStorage("shoppingList.hideCheckedItems") private var hideCheckedItems = false
    /// Lets the menu bar's "New Shopping Item" drop the caret straight into
    /// the add field.
    @FocusState private var addItemFocused: Bool

    private struct AisleGroup {
        var name: String
        var sortOrder: Int
        var items: [ShoppingListItem]
    }

    private var range: DayRange {
        appState.shoppingRange.dayRange(
            customStart: appState.shoppingCustomStart,
            customEnd: appState.shoppingCustomEnd
        )
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

    private var grouped: [AisleGroup] {
        Dictionary(grouping: visibleItems, by: \.aisleName)
            .map { name, values in
                AisleGroup(
                    name: name,
                    sortOrder: values.map { $0.category.sortOrder }.min() ?? IngredientCategory.other.sortOrder,
                    items: values.sorted { $0.sortIndex < $1.sortIndex }
                )
            }
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
    }

    var body: some View {
        @Bindable var appState = appState

        List {
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
            }

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

            ForEach(grouped, id: \.name) { group in
                Section(group.name) {
                    ForEach(group.items) { item in
                        ShoppingListRow(
                            item: item,
                            onToggle: { toggle(item) },
                            onCategoryChange: { changeCategory(item, to: $0) },
                            onCustomAisle: { beginCustomAisle(for: item) },
                            onSetStaple: { setStaple(item, $0) }
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
                Text("Pantry staples never come out of the plan onto the list. Run out of one? Add it here — it stays put when the list is rebuilt.")
            }
        }
        .navigationTitle(AppSection.shopping.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: shareText) {
                    Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
                }
                .disabled(items.isEmpty)
            }
            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    Button {
                        showingPantryStaples = true
                    } label: {
                        Label(String(localized: "Pantry staples…"), systemImage: "shippingbox")
                    }
                    Divider()
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

                    if isConnectedToBring {
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
                    Label(String(localized: "More"), systemImage: "ellipsis.circle")
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
        .focusedSceneValue(\.shoppingCommands, shoppingCommands)
        .onChange(of: appState.shoppingRange) { _, _ in regenerate() }
        .sheet(isPresented: $showingBringSetup) {
            NavigationStack {
                BringSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "Done")) { showingBringSetup = false }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 460)
            #endif
        }
        .sheet(isPresented: $showingPantryStaples) {
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
            isPresented: Binding(get: { customAisleItem != nil }, set: { if !$0 { customAisleItem = nil } })
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
        var lines: [String] = [String(localized: "Shopping list")]
        for group in grouped {
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

    private func toggle(_ item: ShoppingListItem) {
        withAnimation {
            item.isChecked.toggle()
        }
        try? context.save()
    }

    private func addManualItem() {
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

    private func delete(_ offsets: IndexSet, in list: [ShoppingListItem]) {
        for index in offsets where list.indices.contains(index) {
            context.delete(list[index])
        }
        try? context.save()
    }

    private func clearChecked() {
        for item in items where item.isChecked {
            context.delete(item)
        }
        try? context.save()
        Task { await autoSyncWithBring() }
    }

    /// Empty the list outright — the "we've been shopping, start again" button.
    /// Generated lines come back with the next rebuild; manual ones don't, so
    /// this asks first.
    private func clearAll() {
        for item in items {
            context.delete(item)
        }
        try? context.save()
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
        guard let household = appState.currentHousehold else { return }
        await bringService.syncQuietly(household: household, context: context)
    }

    private func changeCategory(_ item: ShoppingListItem, to category: IngredientCategory) {
        item.category = category
        item.customAisleName = nil
        item.ingredient?.category = category
        item.ingredient?.customAisleName = nil
        item.sortIndex = category.sortOrder * 1000 + item.sortIndex % 1000
        try? context.save()
    }

    private func beginCustomAisle(for item: ShoppingListItem) {
        customAisleName = item.customAisleName ?? ""
        customAisleItem = item
    }

    private func saveCustomAisle() {
        guard let item = customAisleItem else { return }
        let trimmed = customAisleName.trimmingCharacters(in: .whitespacesAndNewlines)
        item.customAisleName = trimmed.isEmpty ? nil : trimmed
        item.ingredient?.customAisleName = item.customAisleName
        try? context.save()
        customAisleItem = nil
    }

    private func clearCustomAisle() {
        guard let item = customAisleItem else { return }
        item.customAisleName = nil
        item.ingredient?.customAisleName = nil
        try? context.save()
        customAisleItem = nil
    }

    /// Promote a line to a household staple (or take it back off the list of
    /// them). A line that was planned onto the list is dropped along the way —
    /// the point of a staple is that it isn't bought week by week — while a
    /// line the family added by hand stays, because they asked for it.
    private func setStaple(_ item: ShoppingListItem, _ isStaple: Bool) {
        guard let household = appState.currentHousehold else { return }
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

#Preview {
    NavigationStack { ShoppingListView() }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
