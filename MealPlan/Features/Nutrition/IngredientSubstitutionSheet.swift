import SwiftUI
import SwiftData

/// "What could I use instead?" for one recipe line, answered on the device by
/// Apple Intelligence.
///
/// The suggestions are for review only. The recipe is left alone unless the
/// cook taps "Add to recipe" on one of them, which appends it to that line's
/// note ("or: oat milk (same amount)") — the ingredient, its amount and the
/// shopping list stay exactly as they were.
@MainActor
struct IngredientSubstitutionSheet: View {
    let line: DishIngredient

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var suggestions: [IngredientSubstitution]?
    @State private var failed = false
    @State private var applied: Set<String> = []

    private var ingredientName: String {
        line.ingredient?.name ?? line.rawText ?? String(localized: "Ingredient")
    }

    var body: some View {
        Form {
            Section {
                if let suggestions {
                    if suggestions.isEmpty {
                        Text("No sensible substitute came up for this ingredient.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(suggestions) { suggestion in
                        row(suggestion)
                    }
                } else if failed {
                    Text("Suggestions aren’t available right now. Please try again later.")
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Thinking of substitutes…")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(String(localized: "Instead of \(ingredientName)"))
            } footer: {
                Text("Suggested on this device by Apple Intelligence. Check allergies and dietary needs yourself — suggestions can be wrong. Nothing changes in the recipe unless you add it.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Substitutes"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Done")) { dismiss() }
            }
        }
        .task { await load() }
    }

    private func row(_ suggestion: IngredientSubstitution) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(suggestion.name).font(.headline)
                Spacer()
                if applied.contains(suggestion.id) {
                    Label(String(localized: "Added"), systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(String(localized: "Add to recipe")) { apply(suggestion) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            if !suggestion.amountHint.isEmpty {
                Text(suggestion.amountHint).font(.subheadline).foregroundStyle(.secondary)
            }
            if !suggestion.note.isEmpty {
                Text(suggestion.note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        guard suggestions == nil else { return }
        let dish = line.dish
        let others = (dish?.sortedIngredients ?? [])
            .filter { $0 !== line }
            .compactMap { $0.ingredient?.name ?? $0.rawText }
        // The line as the cook wrote it carries the amount in its own unit.
        let result = await IngredientSubstitutionSuggester.suggestions(
            for: ingredientName,
            amount: line.rawText,
            dishName: dish?.name ?? "",
            otherIngredients: others
        )
        if let result {
            suggestions = result
        } else {
            failed = true
        }
    }

    /// The only write on this screen, and only on an explicit tap.
    private func apply(_ suggestion: IngredientSubstitution) {
        let existing = (line.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        line.note = existing.isEmpty ? suggestion.noteText : "\(existing); \(suggestion.noteText)"
        line.modifiedAt = .now
        line.dish?.modifiedAt = .now
        try? context.save()
        applied.insert(suggestion.id)
    }
}
