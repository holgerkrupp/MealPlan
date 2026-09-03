import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

/// Scans a printed recipe into a brand-new dish.
///
/// The cook points the camera at a recipe book (or picks a screenshot or a
/// PDF), text recognition runs on this device, and the name, ingredients and
/// method are pulled apart into an editable review. Saving creates the dish and
/// opens it for a final check — imports are guesswork, so it lands flagged for
/// review.
@MainActor
struct ScanRecipeSheet: View {
    /// Handed the freshly created dish so the caller can open its editor.
    var onCreate: (Dish) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showingDocumentScanner = false
    @State private var showingPDFPicker = false
    @State private var isScanning = false
    @State private var hasScanned = false
    @State private var name = ""
    @State private var ingredients = ""
    @State private var instructions = ""
    @State private var errorMessage: String?

    private var hasContent: Bool {
        !name.isEmpty || !ingredients.isEmpty || !instructions.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                sourceSection

                if isScanning {
                    Section { ProgressView(String(localized: "Recognizing recipe…")) }
                }

                if hasContent {
                    reviewSection
                } else if hasScanned && !isScanning {
                    Section {
                        Text("No readable text was found. Try again with more light or a straighter angle.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(String(localized: "Scan a recipe"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save"), action: save)
                        .disabled(isScanning || !hasContent)
                }
            }
            .onChange(of: photoItems) { _, items in
                Task { await scanPhotos(items) }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showingDocumentScanner) {
                DocumentScanner { pages in Task { await scan(pages) } }
                    .ignoresSafeArea()
            }
            #endif
            .fileImporter(isPresented: $showingPDFPicker, allowedContentTypes: [.pdf]) { result in
                guard case .success(let url) = result else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    errorMessage = String(localized: "That PDF couldn’t be read.")
                    return
                }
                Task { await scan(RecipeTextScanner.images(fromPDF: data)) }
            }
            .alert(
                String(localized: "Couldn’t scan recipe"),
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var sourceSection: some View {
        Section {
            #if os(iOS)
            Button { showingDocumentScanner = true } label: {
                Label(String(localized: "Scan with camera"), systemImage: "camera.viewfinder")
            }
            #endif
            PhotosPicker(selection: $photoItems, maxSelectionCount: 10, matching: .images) {
                Label(String(localized: "Choose photos or screenshots"), systemImage: "photo.on.rectangle")
            }
            Button { showingPDFPicker = true } label: {
                Label(String(localized: "Choose a PDF"), systemImage: "doc.richtext")
            }
        } footer: {
            Text("Point the camera at a recipe book, or pick screenshots. Text recognition runs on this device. Printed recipes work best; handwriting may need more corrections.")
        }
    }

    @ViewBuilder
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

    private func scanPhotos(_ items: [PhotosPickerItem]) async {
        var data: [Data] = []
        for item in items {
            if let value = try? await item.loadTransferable(type: Data.self) { data.append(value) }
        }
        photoItems.removeAll()
        await scan(data)
    }

    private func scan(_ images: [Data]) async {
        guard !images.isEmpty else { return }
        isScanning = true
        defer { isScanning = false; hasScanned = true }
        do {
            var pages: [String] = []
            for image in images {
                let text = try await RecipeTextScanner.recognize(imageData: image)
                if !text.isEmpty { pages.append(text) }
            }
            guard !pages.isEmpty else { return }
            let draft = await RecipeExtractor.extract(from: pages.joined(separator: "\n\n"))
            if name.isEmpty { name = draft.name }
            ingredients = [ingredients, draft.ingredientLines.joined(separator: "\n")]
                .filter { !$0.isEmpty }.joined(separator: "\n")
            instructions = [instructions, draft.instructions]
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        var recipe = ImportedRecipe(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        recipe.ingredientLines = ingredients.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        recipe.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
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
    ScanRecipeSheet { _ in }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
