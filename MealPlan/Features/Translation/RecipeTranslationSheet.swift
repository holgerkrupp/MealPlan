import SwiftUI
import SwiftData

/// Translates one recipe into the language the cook reads, and offers to keep
/// the translation on the dish.
///
/// Everything happens on the device through Apple Intelligence, so a recipe
/// stays private and a translated recipe is still there in a kitchen with no
/// signal. Saving never overwrites the recipe: the original wording stays put
/// and the detail view can switch between the two.
@MainActor
struct RecipeTranslationSheet: View {
    @Bindable var dish: Dish

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var targetCode = RecipeLanguage.canonical(RecipeLanguage.readerCode)
    @State private var model = RecipeTranslationModel()

    private let availability = RecipeTranslator.availability

    private var translation: RecipeTranslation? { model.translation }

    var body: some View {
        Form {
            if let explanation = availability.explanation {
                Section {
                    Label(explanation, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
            }

            languageSection
            if model.isTranslating { progressSection }
            if let translation { previewSection(translation) }
            if dish.hasSavedTranslation { savedSection }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Translate recipe"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Close"), role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Save"), action: save)
                    .disabled(translation == nil || appState.isGuest)
            }
        }
        .alert(
            String(localized: "Couldn’t translate recipe"),
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear { dish.rememberRecipeLanguage() }
    }

    // MARK: - Sections

    private var languageSection: some View {
        Section {
            Picker(String(localized: "Translate into"), selection: $targetCode) {
                ForEach(RecipeLanguage.offered(), id: \.self) { code in
                    Text(RecipeLanguage.displayName(for: code)).tag(code)
                }
            }
            Button {
                Task { await model.translate(dish.translationRequest, into: targetCode) }
            } label: {
                Label(
                    translation == nil
                        ? String(localized: "Translate")
                        : String(localized: "Translate again"),
                    systemImage: "translate"
                )
            }
            .disabled(!availability.isReady || model.isTranslating || nothingToTranslate)
        } header: {
            Text("Language")
        } footer: {
            Text(footerText)
        }
    }

    private var progressSection: some View {
        Section {
            ProgressView(value: model.progress) {
                Text("Translating on this device…")
            }
        }
    }

    private func previewSection(_ translation: RecipeTranslation) -> some View {
        Group {
            Section(String(localized: "Name")) {
                comparison(original: dish.name, translated: translation.name)
            }
            if !dish.sortedIngredients.isEmpty {
                Section(String(localized: "Ingredients")) {
                    ForEach(dish.sortedIngredients) { line in
                        comparison(
                            original: line.ingredient?.name ?? line.rawText ?? "—",
                            translated: translation.line(line.uuid)?.name
                        )
                        if let note = line.note, !note.isEmpty {
                            comparison(original: note, translated: translation.line(line.uuid)?.note)
                                .font(.caption)
                        }
                    }
                }
            }
            if let directions = translation.directionsText, !directions.isEmpty {
                Section(String(localized: "How to make it")) {
                    Text(directions)
                }
            }
        }
    }

    private var savedSection: some View {
        Section {
            Button(role: .destructive) {
                dish.clearTranslation()
                try? context.save()
                model.translation = nil
            } label: {
                Label(String(localized: "Remove saved translation"), systemImage: "trash")
            }
            .disabled(appState.isGuest)
        } footer: {
            Text("The recipe keeps its own wording either way.")
        }
    }

    /// The original above, the translation below — enough to spot a line the
    /// model got wrong before it is saved.
    private func comparison(original: String, translated: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(translated ?? original)
            if let translated, translated != original {
                Text(original).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Wording

    private var nothingToTranslate: Bool { !dish.hasTranslatableText }

    private var footerText: String {
        if nothingToTranslate {
            return String(localized: "Add ingredients or steps first — there is nothing to translate yet.")
        }
        let target = RecipeLanguage.displayName(for: targetCode)
        if let source = dish.recipeLanguageCode {
            if RecipeLanguage.matches(source, targetCode) {
                return String(localized: "This recipe already reads as \(target).")
            }
            let sourceName = RecipeLanguage.displayName(for: source)
            return String(localized: "Translates the ingredients and steps from \(sourceName) to \(target) on this device. The recipe keeps its original wording.")
        }
        return String(localized: "Translates the ingredients and steps into \(target) on this device. The recipe keeps its original wording.")
    }

    // MARK: - Actions

    private func save() {
        guard let translation else { return }
        dish.apply(translation)
        try? context.save()
        SharedStore.reloadWidgets()
        dismiss()
    }
}

/// Runs one translation and reports how far along it is. A model of its own
/// rather than view state: the work outlives a redraw, and the progress
/// callback comes back from off the main actor.
@MainActor
@Observable
final class RecipeTranslationModel {
    private(set) var isTranslating = false
    private(set) var progress: Double = 0
    var translation: RecipeTranslation?
    var errorMessage: String?

    func translate(_ request: RecipeTranslationRequest, into languageCode: String) async {
        guard !isTranslating else { return }
        isTranslating = true
        progress = 0
        translation = nil
        defer { isTranslating = false }
        do {
            translation = try await RecipeTranslator.translate(request, into: languageCode) { [weak self] value in
                Task { @MainActor in self?.progress = value }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        RecipeTranslationSheet(dish: PreviewData.household.dishes?.first ?? Dish(name: "Test"))
    }
    .environment(AppState.preview)
    .modelContainer(PreviewData.container)
}
