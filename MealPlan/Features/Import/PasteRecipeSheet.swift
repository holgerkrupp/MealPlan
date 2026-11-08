import SwiftUI
import SwiftData

/// Turns recipe text the cook copied elsewhere — a website, a message, a
/// note — into a brand-new dish.
///
/// The clipboard is only ever read through an explicit action: the system
/// Paste button, or the cook pasting into the text box themselves. The text
/// then goes through the same extraction as a scanned page (the on-device
/// model where available, the layout heuristic otherwise) into the same
/// editable review. If nothing can be told apart, the original text is kept
/// as the method, so a save never loses what was pasted.
@MainActor
struct PasteRecipeSheet: View {
    /// Handed the freshly created dish so the caller can open its editor.
    var onCreate: (Dish) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var pastedText = ""
    @State private var isRecognizing = false
    @State private var hasRecognized = false
    @State private var name = ""
    @State private var ingredients = ""
    @State private var instructions = ""

    private var hasText: Bool {
        !pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                textSection

                if isRecognizing {
                    Section { ProgressView(String(localized: "Recognizing recipe…")) }
                }

                if hasRecognized {
                    reviewSection
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Paste a recipe"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save"), action: save)
                        .disabled(isRecognizing || !hasText)
                }
            }
        }
    }

    // MARK: - Sections

    private var textSection: some View {
        Section {
            TextEditor(text: $pastedText)
                .frame(minHeight: 160)
                .accessibilityLabel(String(localized: "Recipe text"))
            HStack {
                PasteButton(payloadType: String.self) { strings in
                    let text = strings.joined(separator: "\n")
                    Task { @MainActor in
                        pastedText = text
                        await recognize()
                    }
                }
                .labelStyle(.titleAndIcon)
                Spacer()
                Button(String(localized: "Recognize recipe"), systemImage: "text.viewfinder") {
                    Task { await recognize() }
                }
                .disabled(isRecognizing || !hasText)
            }
        } header: {
            Text(String(localized: "Recipe text"))
        } footer: {
            Text("Paste a recipe copied from a website, a message or a note. It is split into name, ingredients and method on this device. Anything that can't be sorted is kept as the method.")
        }
    }

    private var reviewSection: some View {
        Section {
            TextField(String(localized: "Recipe name"), text: $name)
            TextField(String(localized: "Ingredients, one per line"), text: $ingredients, axis: .vertical)
                .lineLimit(5...14)
            TextField(String(localized: "Method"), text: $instructions, axis: .vertical)
                .lineLimit(5...14)
        } header: {
            Text(String(localized: "Review"))
        } footer: {
            Text("Check the split is right, then save. The dish opens for editing and is marked to review.")
        }
    }

    // MARK: - Work

    private func recognize() async {
        let text = pastedText
        guard hasText, !isRecognizing else { return }
        isRecognizing = true
        defer { isRecognizing = false }
        let draft = await RecipeExtractor.extract(from: text, source: .pastedText).preservingOriginal(text)
        name = draft.name
        ingredients = draft.ingredientLines.joined(separator: "\n")
        instructions = draft.instructions
        hasRecognized = true
    }

    private func save() {
        var recipe: ImportedRecipe
        if hasRecognized {
            recipe = ImportedRecipe(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
            recipe.ingredientLines = ingredients.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let method = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            // The review was emptied by hand: keep the pasted text rather than
            // saving a dish with nothing in it.
            recipe.instructions = method.isEmpty && recipe.ingredientLines.isEmpty
                ? pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
                : method
            if recipe.name.isEmpty { recipe.name = String(localized: "New dish") }
        } else {
            recipe = ScannedRecipeParser.importedRecipe(fromText: pastedText)
        }
        recipe.needsReview = true

        let dish = DishBuilder.makeDish(
            from: recipe,
            household: appState.currentHousehold,
            createdByName: appState.currentMemberName,
            context: context
        )
        SharedStore.reloadWidgets()
        dismiss()
        onCreate(dish)
    }
}

#Preview {
    PasteRecipeSheet { _ in }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
