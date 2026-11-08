import SwiftUI
import SwiftData

/// Everything the household tracks about one ingredient at home: have/low/
/// out, how much, best before, where it's kept, and a free-text note.
/// Edits are saved as they're made.
@MainActor
struct PantryItemEditor: View {
    let ingredient: Ingredient

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ShoppingListItem.sortIndex) private var allShoppingItems: [ShoppingListItem]

    @State private var amountText = ""
    /// What the amount field last showed from the store, so only a real
    /// edit is parsed back.
    @State private var syncedAmountText = ""
    @State private var noteText = ""
    @State private var customLocationText = ""
    @FocusState private var amountFocused: Bool

    private var household: Household? { appState.currentHousehold }
    private var canEdit: Bool { PantryActions.canEdit(household, isGuest: appState.isGuest) }

    private var isOnShoppingList: Bool {
        PantryActions.isOnShoppingList(
            ingredient,
            items: allShoppingItems.filter { $0.household?.uuid == household?.uuid }
        )
    }

    /// `nil` stands for "no location" in the picker.
    private var locationOptions: [InventoryStorageLocation?] {
        [nil] + InventoryStorageLocation.allCases.map { Optional($0) }
    }

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Status"), selection: binding(
                    { ingredient.inventoryMode },
                    { PantryInventory.setMode($0, for: ingredient); syncAmountText() }
                )) {
                    ForEach([InventoryMode.have, .low, .out, .none]) { Text($0.localizedName).tag($0) }
                }
                #if os(iOS)
                .pickerStyle(.segmented)
                #endif

                HStack {
                    TextField(String(localized: "Amount, e.g. 500 g or 3"), text: $amountText)
                        .focused($amountFocused)
                        .onSubmit(commitAmount)
                    if ingredient.inventoryQuantity?.dimension == .count {
                        Button {
                            PantryInventory.useOne(ingredient)
                            save()
                            syncAmountText()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(String(localized: "Used one"))
                        Button {
                            let current = ingredient.inventoryQuantity?.value ?? 0
                            ingredient.inventoryQuantity = .pieces(current + 1)
                            if ingredient.inventoryMode != .have, ingredient.inventoryMode != .low {
                                ingredient.inventoryMode = .have
                            }
                            save()
                            syncAmountText()
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(String(localized: "Add one"))
                    }
                }
            } header: {
                Text("At home")
            } footer: {
                Text("An amount is optional. With one, rebuilding the shopping list buys only what's missing; “Have” without an amount leaves the item off.")
            }

            Section {
                Toggle(String(localized: "Best before"), isOn: binding(
                    { ingredient.inventoryBestBefore != nil },
                    { ingredient.inventoryBestBefore = $0 ? Calendar.current.date(byAdding: .day, value: 7, to: .now.startOfDay) : nil }
                ))
                if ingredient.inventoryBestBefore != nil {
                    DatePicker(
                        String(localized: "Date"),
                        selection: binding({ ingredient.inventoryBestBefore ?? .now }, { ingredient.inventoryBestBefore = $0 }),
                        displayedComponents: .date
                    )
                }

                Picker(String(localized: "Storage location"), selection: binding(
                    { ingredient.storageLocation },
                    { ingredient.storageLocation = $0 }
                )) {
                    ForEach(locationOptions, id: \.self) { location in
                        Text(location?.localizedName ?? String(localized: "None")).tag(location)
                    }
                }
                if ingredient.storageLocation == .custom {
                    TextField(String(localized: "Location name, e.g. Cellar"), text: $customLocationText)
                        .onSubmit(commitCustomLocation)
                }
            }

            Section {
                TextField(String(localized: "Note, e.g. opened jar, top shelf"), text: $noteText, axis: .vertical)
                    .lineLimit(1...4)
                    .onSubmit(commitNote)
            } header: {
                Text("Note")
            }

            Section {
                Toggle(String(localized: "Pantry staple"), isOn: binding(
                    { ingredient.isPantryStaple },
                    { ingredient.isPantryStaple = $0 }
                ))
            } footer: {
                Text("Staples are always at home and left off the shopping list when it's rebuilt.")
            }

            Section {
                if isOnShoppingList {
                    Label(String(localized: "On the shopping list"), systemImage: "cart.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        guard let household else { return }
                        ShoppingListBuilder.addManualItem(for: ingredient, household: household, context: context)
                    } label: {
                        Label(String(localized: "Add to shopping list"), systemImage: "cart.badge.plus")
                    }
                    .disabled(!canEdit)
                }
                Button(String(localized: "Stop tracking"), role: .destructive) {
                    stopTracking()
                }
                .disabled(!canEdit)
            }
        }
        .formStyle(.grouped)
        .disabled(!canEdit)
        .navigationTitle(ingredient.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            syncAmountText()
            noteText = ingredient.inventoryNote ?? ""
            customLocationText = ingredient.inventoryCustomStorageLocation ?? ""
        }
        .onChange(of: amountFocused) { _, focused in
            if !focused { commitAmount() }
        }
        .onDisappear {
            commitAmount()
            commitNote()
            commitCustomLocation()
        }
    }

    // MARK: - Editing

    /// A binding that writes straight to the ingredient and saves.
    private func binding<Value>(_ get: @escaping () -> Value, _ set: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(get: get, set: { value in
            guard canEdit else { return }
            set(value)
            save()
        })
    }

    private func save() {
        PantryActions.commit(ingredient, household: household, context: context)
    }

    private func syncAmountText() {
        amountText = PantryRowLabel.amountText(for: ingredient, system: appState.unitSystem) ?? ""
        syncedAmountText = amountText
    }

    private func commitAmount() {
        guard canEdit, amountText != syncedAmountText else { return }
        let trimmed = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            ingredient.inventoryQuantity = nil
        } else if let quantity = PantryInventory.parseAmount(trimmed) {
            ingredient.inventoryQuantity = quantity
            if ingredient.inventoryMode == .none || ingredient.inventoryMode == .out {
                ingredient.inventoryMode = .have
            }
        } else {
            // Not an amount — keep what was stored rather than guess.
            syncAmountText()
            return
        }
        save()
        syncAmountText()
    }

    private func commitNote() {
        guard canEdit else { return }
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = trimmed.isEmpty ? nil : trimmed
        guard value != ingredient.inventoryNote else { return }
        ingredient.inventoryNote = value
        save()
    }

    private func commitCustomLocation() {
        guard canEdit, ingredient.storageLocation == .custom else { return }
        let trimmed = customLocationText.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = trimmed.isEmpty ? nil : trimmed
        guard value != ingredient.inventoryCustomStorageLocation else { return }
        ingredient.inventoryCustomStorageLocation = value
        save()
    }

    private func stopTracking() {
        guard canEdit else { return }
        ingredient.markInventory(.none, quantity: nil, bestBefore: nil)
        ingredient.storageLocation = nil
        ingredient.inventoryNote = nil
        noteText = ""
        customLocationText = ""
        amountText = ""
        syncedAmountText = ""
        save()
        dismiss()
    }
}
