import SwiftUI
import SwiftData

/// Household controls for the optional, regional package-size catalogue.
@MainActor
struct TypicalPackageSizesView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Query(sort: \Ingredient.name) private var ingredients: [Ingredient]
    @Query(sort: \IngredientPackageSize.ingredientName) private var overrides: [IngredientPackageSize]

    @State private var searchText = ""
    @State private var showingAdd = false
    @State private var selectedIngredient: Ingredient?

    private let supportedRegions = ["DE", "AT", "CH", "UK", "US"]

    private var household: Household? { appState.currentHousehold }

    private var visibleIngredients: [Ingredient] {
        let query = Ingredient.normalize(searchText)
        return ingredients.filter { query.isEmpty || IngredientMatching.keysMatch(IngredientMatching.key(for: $0.name), query) || $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        Form {
            if let household {
                Section {
                    Toggle("Suggest ways to use likely leftovers", isOn: enabled(household))
                    Picker("Package-size market", selection: country(household)) {
                        ForEach(supportedRegions, id: \.self) { code in
                            Text(Locale(identifier: "und_\(code)").localizedString(forRegionCode: code) ?? code)
                                .tag(code)
                        }
                    }
                } header: {
                    Text("Leftover suggestions")
                } footer: {
                    Text("Package sizes are typical retail examples, not official standards. The market is independent of the app language; no precise location is used.")
                }

                Section {
                    TextField("Search ingredients", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                    ForEach(visibleIngredients) { ingredient in
                        ingredientRow(ingredient, household: household)
                    }
                    if visibleIngredients.isEmpty {
                        Text("No matching ingredients")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Typical package sizes")
                } footer: {
                    Text("Bundled values are read-only defaults. Disable one locally or add a household value; bundled updates never overwrite those choices.")
                }

                Section {
                    Button("Reset all package sizes", role: .destructive) {
                        IngredientPackageCatalogue.resetAll(in: household)
                        try? context.save()
                    }
                }
            } else {
                ContentUnavailableView("No household", systemImage: "person.2")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Typical package sizes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add size", systemImage: "plus") { showingAdd = true }
                    .disabled(household == nil)
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddPackageSizeView(household: household, initialIngredient: selectedIngredient)
        }
        .searchable(text: $searchText, prompt: "Search ingredients")
    }

    @ViewBuilder
    private func ingredientRow(_ ingredient: Ingredient, household: Household) -> some View {
        let key = IngredientMatching.key(for: ingredient.name)
        let bundled = IngredientPackageSeedData.all.filter {
            $0.countryCode == household.packageSizeCountryCode && IngredientMatching.keysMatch($0.ingredientKey, key)
        }
        let local = overrides.filter {
            $0.countryCode == household.packageSizeCountryCode && IngredientMatching.keysMatch($0.ingredientKey, key)
        }
        let effective = IngredientPackageCatalogue.effectiveSizes(
            for: key, countryCode: household.packageSizeCountryCode,
            userOverrides: local
        )

        DisclosureGroup {
            ForEach(bundled) { size in
                let isDisabled = local.first { ($0.overridesBundledID ?? $0.stableBundledID) == size.id }?.isEnabled == false
                HStack {
                    Text(sizeLabel(size))
                    Spacer()
                    if isDisabled { Text("Disabled").foregroundStyle(.secondary) }
                    else if size.isPreferred { Text("Preferred").foregroundStyle(.tint) }
                    Button(isDisabled ? "Enable" : "Disable") {
                        setEnabled(!isDisabled, for: size, ingredient: ingredient, household: household)
                    }
                    .buttonStyle(.borderless)
                }
                .font(.subheadline)
            }
            ForEach(local.filter { $0.overridesBundledID == nil && !$0.overridesProfile }) { size in
                HStack {
                    Text(sizeLabel(PackageSizeDefinition(size)))
                    Text("Household").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete", role: .destructive) { context.delete(size); try? context.save() }
                        .buttonStyle(.borderless)
                }
            }
            if effective.isEmpty {
                Text("No enabled sizes for this ingredient")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Add size") {
                    selectedIngredient = ingredient
                    showingAdd = true
                }
                Button("Reset") {
                    IngredientPackageCatalogue.resetIngredient(key, in: household)
                    try? context.save()
                }
            }
            .buttonStyle(.borderless)
        } label: {
            HStack {
                Text(ingredient.name)
                Spacer()
                Text("\(effective.count)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    private func enabled(_ household: Household) -> Binding<Bool> {
        Binding(get: { household.leftoverSuggestionsEnabled }, set: { household.leftoverSuggestionsEnabled = $0; try? context.save() })
    }

    private func country(_ household: Household) -> Binding<String> {
        Binding(get: { household.packageSizeCountryCode }, set: { household.packageSizeCountryCode = $0; try? context.save() })
    }

    private func setEnabled(_ enabled: Bool, for bundled: PackageSizeDefinition, ingredient: Ingredient, household: Household) {
        let key = IngredientMatching.key(for: ingredient.name)
        if let existing = overrides.first(where: { $0.overridesBundledID == bundled.id && $0.countryCode == household.packageSizeCountryCode }) {
            existing.isEnabled = enabled
            existing.modifiedAt = .now
        } else {
            let row = IngredientPackageSize(
                ingredientKey: key, ingredientName: ingredient.name,
                countryCode: household.packageSizeCountryCode, quantity: bundled.quantity,
                containerType: bundled.containerType, priority: bundled.priority, provenance: .user
            )
            row.stableBundledID = bundled.id
            row.overridesBundledID = bundled.id
            row.isEnabled = enabled
            row.isPreferred = bundled.isPreferred
            row.household = household
            context.insert(row)
        }
        try? context.save()
    }

    private func sizeLabel(_ size: PackageSizeDefinition) -> String {
        let value = size.quantity.value.rounded() == size.quantity.value ? String(Int(size.quantity.value)) : String(size.quantity.value)
        let unit = size.quantity.dimension == .mass ? "g" : size.quantity.dimension == .volume ? "ml" : "×"
        return "\(value) \(unit) · \(size.containerType.rawValue)"
    }
}

@MainActor
private struct AddPackageSizeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let household: Household?
    let initialIngredient: Ingredient?

    @State private var ingredientName = ""
    @State private var value = 400.0
    @State private var dimension: QuantityDimension = .mass
    @State private var container: PackageContainerType = .can
    @State private var country = "DE"

    var body: some View {
        NavigationStack {
            Form {
                TextField("Ingredient", text: $ingredientName)
                Picker("Dimension", selection: $dimension) {
                    Text("Mass (g)").tag(QuantityDimension.mass)
                    Text("Volume (ml)").tag(QuantityDimension.volume)
                    Text("Count").tag(QuantityDimension.count)
                }
                TextField("Amount", value: $value, format: .number)
                Picker("Container", selection: $container) {
                    ForEach(PackageContainerType.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                Picker("Market", selection: $country) {
                    ForEach(["DE", "AT", "CH", "UK", "US"], id: \.self) { Text($0).tag($0) }
                }
            }
            .navigationTitle("Add package size")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(household == nil || ingredientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value <= 0)
                }
            }
            .onAppear {
                if let initialIngredient { ingredientName = initialIngredient.name }
                if let household { country = household.packageSizeCountryCode }
            }
        }
        .frame(minWidth: 360, minHeight: 300)
    }

    private func save() {
        guard let household else { return }
        let trimmed = ingredientName.trimmingCharacters(in: .whitespacesAndNewlines)
        let row = IngredientPackageSize(
            ingredientKey: IngredientMatching.key(for: trimmed), ingredientName: trimmed,
            countryCode: country, quantity: Quantity(value: value, dimension: dimension),
            containerType: container, provenance: .user
        )
        row.household = household
        context.insert(row)
        try? context.save()
        dismiss()
    }
}
