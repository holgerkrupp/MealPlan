import SwiftUI
import SwiftData

/// Type what's on the package for one ingredient.
///
/// Values live on the `Ingredient`, not on the recipe line, so filling in
/// "Dinkelmehl" once fixes every dish in the library that uses it — the same
/// reason pantry staples hang off the catalogue.
@MainActor
struct IngredientNutritionEditor: View {
    @Bindable var ingredient: Ingredient

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var energy = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var reference: NutritionReference = .per100Grams
    @State private var loaded = false

    /// What MealPlan would use if this screen were left empty.
    private var builtIn: NutritionFacts? { NutritionTable.facts(for: ingredient.name) }

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Values are"), selection: $reference) {
                    ForEach(NutritionReference.allCases) { option in
                        Text(option.localizedName).tag(option)
                    }
                }
                field(String(localized: "Energy"), text: $energy, suffix: "kcal")
                field(String(localized: "Protein"), text: $protein, suffix: "g")
                field(String(localized: "Carbs"), text: $carbs, suffix: "g")
                field(String(localized: "Fat"), text: $fat, suffix: "g")
            } header: {
                Text(ingredient.name)
            } footer: {
                Text("Energy is the only value MealPlan needs. Anything you leave blank counts as zero for this ingredient.")
            }

            if let builtIn {
                Section {
                    LabeledContent(
                        String(localized: "MealPlan's value"),
                        value: String(
                            localized: "\(NutritionFormatting.energy(builtIn, unit: .kilocalories, approximate: false)) per 100 g"
                        )
                    )
                    Button(String(localized: "Use this instead")) { fill(with: builtIn) }
                } footer: {
                    Text("A generic reference value for this ingredient, not a particular product.")
                }
            }

            if ingredient.nutritionFacts != nil {
                Section {
                    Button(String(localized: "Remove these values"), role: .destructive) {
                        ingredient.setNutrition(nil)
                        try? context.save()
                        dismiss()
                    }
                } footer: {
                    Text(ingredient.nutritionSource.localizedName)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Nutrition values"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Save"), action: save)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel")) { dismiss() }
            }
        }
        .onAppear(perform: load)
    }

    private func field(_ label: String, text: Binding<String>, suffix: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField("", text: text, prompt: Text(verbatim: "0"))
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                Text(verbatim: suffix).foregroundStyle(.secondary)
            }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        reference = ingredient.nutritionReference
        guard let facts = ingredient.nutritionFacts else { return }
        fill(with: facts)
    }

    private func fill(with facts: NutritionFacts) {
        energy = string(facts.energyKcal)
        protein = string(facts.proteinGrams)
        carbs = string(facts.carbGrams)
        fat = string(facts.fatGrams)
    }

    private func save() {
        guard let energyValue = double(energy), energyValue >= 0 else {
            // No energy means nothing to estimate with, so treat an empty form
            // as "forget what I typed" rather than storing a row of zeros.
            ingredient.setNutrition(nil)
            try? context.save()
            dismiss()
            return
        }
        ingredient.setNutrition(
            NutritionFacts(
                energyKcal: energyValue,
                proteinGrams: double(protein) ?? 0,
                carbGrams: double(carbs) ?? 0,
                fatGrams: double(fat) ?? 0
            ),
            reference: reference,
            source: .user
        )
        try? context.save()
        dismiss()
    }

    /// Accepts both decimal separators: a German keyboard offers a comma and
    /// `Double("12,5")` is nil.
    private func double(_ text: String) -> Double? {
        let cleaned = text
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty else { return nil }
        return Double(cleaned)
    }

    private func string(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.1f", value)
    }
}

#Preview {
    NavigationStack {
        IngredientNutritionEditor(ingredient: PreviewData.ingredient("Mehl"))
    }
    .modelContainer(PreviewData.container)
}
