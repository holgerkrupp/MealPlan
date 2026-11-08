import SwiftUI
import SwiftData

/// Type one serving's values off a package or a cookbook page.
///
/// Values typed here replace the estimate for this dish and are labelled
/// "Entered by hand". A field left blank stays unknown — it is never stored as
/// zero — and clearing the values hands the dish back to the estimate.
@MainActor
struct DishNutritionEditor: View {
    @Bindable var dish: Dish

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var values: [NutritionLabel.Nutrient: String] = [:]
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                ForEach(NutritionLabel.Nutrient.allCases, id: \.self) { nutrient in
                    field(nutrient)
                }
            } header: {
                Text(String(localized: "Per serving"))
            } footer: {
                Text("Energy is required. Anything you leave blank is shown as unknown.")
            }

            if dish.statedEnergyKcalPerServing != nil {
                Section {
                    Button(String(localized: "Remove these values"), role: .destructive) {
                        dish.setStatedNutritionPerServing(nil)
                        dish.modifiedAt = .now
                        try? context.save()
                        dismiss()
                    }
                } footer: {
                    Text("MealPlan goes back to estimating this dish from its ingredients.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Nutrition per serving"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Save"), action: save)
                    .disabled(Self.number(values[.energy] ?? "") == nil)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel")) { dismiss() }
            }
        }
        .onAppear(perform: load)
    }

    private func field(_ nutrient: NutritionLabel.Nutrient) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField("", text: Binding(
                    get: { values[nutrient] ?? "" },
                    set: { values[nutrient] = $0 }
                ), prompt: Text(verbatim: "—"))
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                Text(verbatim: suffix(for: nutrient)).foregroundStyle(.secondary)
            }
        } label: {
            Text(nutrient.localizedName)
                .padding(.leading, nutrient.isSubRow ? 16 : 0)
        }
    }

    private func suffix(for nutrient: NutritionLabel.Nutrient) -> String {
        if nutrient == .energy { return EnergyUnit.kilocalories.symbol }
        return nutrient.isMilligrams ? "mg" : "g"
    }

    private var stored: [NutritionLabel.Nutrient: Double?] {
        [
            .energy: dish.statedEnergyKcalPerServing,
            .fat: dish.statedFatGramsPerServing,
            .saturatedFat: dish.statedSaturatedFatGramsPerServing,
            .cholesterol: dish.statedCholesterolMilligramsPerServing,
            .sodium: dish.statedSodiumMilligramsPerServing,
            .carbs: dish.statedCarbGramsPerServing,
            .fiber: dish.statedFiberGramsPerServing,
            .sugar: dish.statedSugarGramsPerServing,
            .protein: dish.statedProteinGramsPerServing,
        ]
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        for (nutrient, value) in stored {
            if let value { values[nutrient] = Self.text(value) }
        }
    }

    private func save() {
        let parsed = Dictionary(uniqueKeysWithValues: NutritionLabel.Nutrient.allCases.map {
            ($0, Self.number(values[$0] ?? ""))
        })
        guard let energy = parsed[.energy] ?? nil else { return }

        // Saving the imported figures untouched keeps them "from the recipe".
        let unchanged = NutritionLabel.Nutrient.allCases.allSatisfy { parsed[$0] == stored[$0] }
        guard !unchanged else {
            dismiss()
            return
        }

        dish.statedEnergyKcalPerServing = energy
        dish.statedFatGramsPerServing = parsed[.fat] ?? nil
        dish.statedSaturatedFatGramsPerServing = parsed[.saturatedFat] ?? nil
        dish.statedCholesterolMilligramsPerServing = parsed[.cholesterol] ?? nil
        dish.statedSodiumMilligramsPerServing = parsed[.sodium] ?? nil
        dish.statedCarbGramsPerServing = parsed[.carbs] ?? nil
        dish.statedFiberGramsPerServing = parsed[.fiber] ?? nil
        dish.statedSugarGramsPerServing = parsed[.sugar] ?? nil
        dish.statedProteinGramsPerServing = parsed[.protein] ?? nil
        dish.statedNutritionProvenanceRaw = RecipeNutritionProvenance.manuallyEntered.rawValue
        dish.modifiedAt = .now
        try? context.save()
        dismiss()
    }

    /// Accepts both decimal separators: a German keyboard offers a comma and
    /// `Double("12,5")` is nil. Negative numbers are refused.
    static func number(_ text: String) -> Double? {
        let cleaned = text
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, let value = Double(cleaned), value >= 0, value.isFinite else { return nil }
        return value
    }

    private static func text(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

#Preview {
    NavigationStack {
        DishNutritionEditor(dish: PreviewData.richDish)
    }
    .modelContainer(PreviewData.container)
}
