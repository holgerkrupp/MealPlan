import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

@MainActor
struct RecipeScannerView: View {
    @Bindable var dish: Dish

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showingDocumentScanner = false
    @State private var showingPDFPicker = false
    @State private var isScanning = false
    @State private var name = ""
    @State private var ingredients = ""
    @State private var instructions = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                PhotosPicker(selection: $photoItems, maxSelectionCount: 10, matching: .images) {
                    Label(String(localized: "Choose recipe photos"), systemImage: "photo.on.rectangle")
                }
                #if os(iOS)
                Button { showingDocumentScanner = true } label: {
                    Label(String(localized: "Scan with camera"), systemImage: "camera.viewfinder")
                }
                #endif
                Button { showingPDFPicker = true } label: {
                    Label(String(localized: "Choose a PDF"), systemImage: "doc.richtext")
                }
            } footer: {
                Text("Text recognition runs on this device. Printed recipes work best; handwriting may need more corrections.")
            }

            if isScanning {
                Section { ProgressView(String(localized: "Recognizing recipe…")) }
            }

            if !name.isEmpty || !ingredients.isEmpty || !instructions.isEmpty {
                Section(String(localized: "Review")) {
                    TextField(String(localized: "Recipe name"), text: $name)
                    TextField(String(localized: "Ingredients, one per line"), text: $ingredients, axis: .vertical)
                        .lineLimit(5...14)
                    TextField(String(localized: "Method"), text: $instructions, axis: .vertical)
                        .lineLimit(5...14)
                }
            }
        }
        .navigationTitle(String(localized: "Scan recipe"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Use scan"), action: apply)
                    .disabled(isScanning || (name.isEmpty && ingredients.isEmpty && instructions.isEmpty))
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
        defer { isScanning = false }
        do {
            var pages: [String] = []
            for image in images {
                let text = try await RecipeTextScanner.recognize(imageData: image)
                if !text.isEmpty { pages.append(text) }
            }
            guard !pages.isEmpty else {
                errorMessage = String(localized: "No readable text was found.")
                return
            }
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

    private func apply() {
        if dish.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dish.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var recipe = ImportedRecipe(name: name)
        recipe.ingredientLines = ingredients.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        recipe.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        recipe.needsReview = true
        DishBuilder.apply(recipe, to: dish, context: context)
        dismiss()
    }
}

#Preview {
    NavigationStack { RecipeScannerView(dish: Dish(name: "")) }
        .modelContainer(PreviewData.container)
}
