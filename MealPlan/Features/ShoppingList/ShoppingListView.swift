import SwiftUI
import SwiftData

@MainActor
struct ShoppingListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Query(sort: \ShoppingListItem.sortIndex) private var items: [ShoppingListItem]
    @Query(sort: \Ingredient.name) private var ingredients: [Ingredient]

    @State private var newItemName = ""
    @State private var exportMessage: String?
    @State private var isExporting = false
    @State private var customAisleItem: ShoppingListItem?
    @State private var customAisleName = ""
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

    /// The household's pantry staples that aren't on the list already. These
    /// are never planned onto it — see `PantryStaples` — so this menu is how
    /// one gets there on the day the family runs out.
    private var stapleSuggestions: [Ingredient] {
        let onList = Set(items.map(\.normalizedName))
        return ingredients.filter { $0.isPantryStaple && !onList.contains($0.normalizedName) }
    }

    private var grouped: [AisleGroup] {
        Dictionary(grouping: items, by: \.aisleName)
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
                    #if os(iOS)
                    Button {
                        Task { await exportToReminders() }
                    } label: {
                        Label(String(localized: "Add to Reminders"), systemImage: "list.bullet")
                    }
                    .disabled(isExporting || items.isEmpty)
                    #endif
                    Button(String(localized: "Clear ticked items"), role: .destructive) {
                        clearChecked()
                    }
                    .disabled(!items.contains(where: \.isChecked))
                } label: {
                    Label(String(localized: "More"), systemImage: "ellipsis.circle")
                }
            }
        }
        .onAppear { if items.isEmpty { regenerate() } }
        .focusedSceneValue(\.shoppingCommands, shoppingCommands)
        .onChange(of: appState.shoppingRange) { _, _ in regenerate() }
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
    }

    private func toggle(_ item: ShoppingListItem) {
        item.isChecked.toggle()
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
