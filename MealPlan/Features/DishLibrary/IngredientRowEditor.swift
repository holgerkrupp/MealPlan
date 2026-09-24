import SwiftUI
import SwiftData

/// One editable ingredient line. The cook edits it as free text
/// ("200 g Mehl"); it's re-parsed on commit so quantities stay canonical.
@MainActor
struct IngredientRowEditor: View {
    @Bindable var line: DishIngredient
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    @State private var text = ""
    @State private var pendingMatch: IngredientMatchResult?
    @State private var pendingRawName = ""
    @State private var pendingNewIngredient: Ingredient?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(String(localized: "Ingredient"), text: $text)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }

            HStack(spacing: 8) {
                if let amount = amountPreview {
                    Text(amount)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("", selection: categoryBinding) {
                    ForEach(IngredientCategory.allCases) { Text($0.localizedName).tag($0) }
                }
                .labelsHidden()
                .font(.caption)
                Toggle(isOn: pantryBinding) {
                    Label(String(localized: "Usually have"), systemImage: "shippingbox")
                        .font(.caption)
                }
                .toggleStyle(.button)
            }
            TextField(String(localized: "Custom aisle (optional)"), text: customAisleBinding)
                .font(.caption)
        }
        .onAppear { if text.isEmpty { text = composedText } }
        .confirmationDialog(
            String(localized: "Use an existing ingredient?"),
            isPresented: Binding(
                get: { pendingMatch != nil },
                set: { if !$0 { pendingMatch = nil } }
            ),
            titleVisibility: .visible
        ) {
            ForEach(Array((pendingMatch?.candidates ?? []).enumerated()), id: \.offset) { _, candidate in
                Button(String(localized: "Use (candidate.name)")) {
                    confirm(candidate)
                }
            }
            Button(String(localized: "Keep separate"), role: .cancel) {
                rejectPendingMatch()
            }
        } message: {
            if let pendingMatch {
                Text(String(localized: "The spelling “(pendingRawName)” is close to an existing ingredient. Your recipe wording will remain unchanged."))
                    .fixedSize(horizontal: false, vertical: true)
                if pendingMatch.candidates.count > 1 {
                    Text(String(localized: "Choose which ingredient it means."))
                }
            }
        }
    }

    private var composedText: String {
        if let raw = line.rawText, !raw.isEmpty { return raw }
        var parts: [String] = []
        if let q = line.quantity {
            parts.append(UnitConversion.format(q.value, locale: .current))
            if let unit = line.displayUnit { parts.append(unit) }
        }
        if let name = line.ingredient?.name { parts.append(name) }
        if let note = line.note, !note.isEmpty { parts.append("(\(note))") }
        return parts.joined(separator: " ")
    }

    private var amountPreview: String? {
        guard let q = line.quantity else { return line.note }
        let s = UnitConversion.string(
            for: q,
            system: appState.unitSystem,
            preferredUnit: line.displayUnit,
            approximate: line.isApproximate,
            ingredientName: line.ingredient?.name,
            roundsAmounts: appState.roundsDisplayedAmounts
        )
        return (s.isApproximate ? "≈ " : "") + s.text
    }

    private var categoryBinding: Binding<IngredientCategory> {
        Binding(
            get: { line.ingredient?.category ?? .other },
            set: { line.ingredient?.category = $0; try? context.save() }
        )
    }

    private var pantryBinding: Binding<Bool> {
        Binding(
            get: { line.ingredient?.isPantryStaple ?? false },
            set: { line.ingredient?.isPantryStaple = $0; try? context.save() }
        )
    }

    private var customAisleBinding: Binding<String> {
        Binding(
            get: { line.ingredient?.customAisleName ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                line.ingredient?.customAisleName = trimmed.isEmpty ? nil : value
                try? context.save()
            }
        )
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != line.rawText else { return }
        let parsed = GermanUnitParser.parse(trimmed)
        line.canonicalValue = parsed.quantity?.value
        line.dimension = parsed.quantity?.dimension
        line.displayUnit = parsed.displayUnit
        line.isApproximate = parsed.isApproximate
        line.note = parsed.note
        line.rawText = parsed.rawText

        let household = line.dish?.household
        let result = IngredientIdentity.matchResult(named: parsed.name, in: household?.ingredients ?? [])
        if let match = result.candidate, result.isSafeForSilentReuse {
            line.ingredient = match
            IngredientIdentity.addAlias(
                named: parsed.name,
                to: match,
                source: .userConfirmed,
                confidence: 1,
                context: context
            )
        } else if let household {
            // An uncertain candidate is deliberately kept as a new catalogue
            // row until the person chooses “same” or “separate”.
            let newIngredient = IngredientIdentity.upsert(
                named: parsed.name,
                household: household,
                context: context,
                source: .userConfirmed,
                confidence: 1
            )
            line.ingredient = newIngredient
            if result.matchClass == .needsConfirmation, !result.candidates.isEmpty {
                pendingNewIngredient = newIngredient
                pendingRawName = parsed.name
                pendingMatch = result
            }
        }
        try? context.save()
    }

    private func confirm(_ candidate: Ingredient) {
        guard let newIngredient = pendingNewIngredient else { return }
        try? IngredientIdentity.confirmMatch(
            newIngredient: newIngredient,
            canonical: candidate,
            context: context
        )
        clearPendingMatch()
        try? context.save()
    }

    private func rejectPendingMatch() {
        guard let candidates = pendingMatch?.candidates,
              let newIngredient = pendingNewIngredient else {
            clearPendingMatch()
            return
        }
        for candidate in candidates {
            IngredientIdentity.rejectMatch(named: pendingRawName, for: candidate, on: newIngredient)
        }
        clearPendingMatch()
        try? context.save()
    }

    private func clearPendingMatch() {
        pendingMatch = nil
        pendingNewIngredient = nil
        pendingRawName = ""
    }
}

#Preview {
    Form {
        ForEach(PreviewData.richDish.sortedIngredients) { line in
            IngredientRowEditor(line: line)
        }
    }
    .environment(AppState.preview)
    .modelContainer(PreviewData.container)
}
