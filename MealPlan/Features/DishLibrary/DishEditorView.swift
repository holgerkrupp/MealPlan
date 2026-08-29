import SwiftUI
import SwiftData
import PhotosUI
import ImagePlayground

@MainActor
struct DishEditorView: View {
    @Bindable var dish: Dish
    let isNew: Bool

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Dish.name) private var allDishes: [Dish]

    @Environment(\.supportsImagePlayground) private var supportsImagePlayground

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showingCamera = false
    @State private var showingImagePlayground = false
    @State private var showingRecipeScanner = false
    @State private var newIngredientText = ""
    @State private var sourceURLText = ""
    @State private var collectionsText = ""
    @State private var duplicateDish: Dish?

    var body: some View {
        Form {
            identitySections
            detailsSection
            organizationSection

            tagsSections
            ingredientsSection
            recipeSection
            sourceSection
        }
        .formStyle(.grouped)
        .navigationTitle(isNew ? String(localized: "New dish") : String(localized: "Edit dish"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel"), role: .cancel) { cancel() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Save")) { save() }
                    .disabled(dish.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            sourceURLText = dish.sourceURLString ?? ""
            collectionsText = dish.collectionNames.joined(separator: ", ")
        }
        .onChange(of: photoItems) { _, items in Task { await loadPhotos(items) } }
        // While the placeholder is still the app's suggestion it follows what
        // the dish becomes; `refreshAutoGlyph` is a no-op once the user picks.
        .onChange(of: dish.name) { _, _ in dish.refreshAutoGlyph() }
        .onChange(of: dish.mealTypeTagsRaw) { _, _ in dish.refreshAutoGlyph() }
        #if os(iOS)
        .sheet(isPresented: $showingCamera) {
            CameraPicker { data in addImage(ImagePreparation.prepared(from: data)) }
                .ignoresSafeArea()
        }
        #endif
        .imagePlaygroundSheet(isPresented: $showingImagePlayground, concepts: imageConcepts) { url in
            guard let data = try? Data(contentsOf: url) else { return }
            addImage(ImagePreparation.prepared(from: data))
        }
        .sheet(isPresented: $showingRecipeScanner) {
            NavigationStack { RecipeScannerView(dish: dish) }
        }
        .alert(item: $duplicateDish) { duplicate in
            Alert(
                title: Text("Possible duplicate"),
                message: Text(verbatim: "“\(duplicate.name)” is already in your library."),
                primaryButton: .default(Text("Save anyway")) { save(checkDuplicates: false) },
                secondaryButton: .cancel(Text("Keep editing"))
            )
        }
    }

    // MARK: - Photos

    private var identitySections: some View {
        Group {
            Section(String(localized: "Name")) {
                TextField(String(localized: "e.g. Spaghetti Bolognese"), text: $dish.name)
                    .font(.headline)
            }
            Section(String(localized: "Photos")) {
                photoRow
            }
            Section {
                DishGlyphPicker(dish: dish, tint: DishGlyph.tint(forName: dish.name))
            } footer: {
                Text("Pick an emoji or a symbol to stand in for dishes you don\u{2019}t have a photo of.")
            }
        }
    }

    private var detailsSection: some View {
        Section(String(localized: "Details")) {
            Stepper(value: $dish.servings, in: 1...50) {
                Text(String(localized: "\(dish.servings) servings"))
            }
            minutePicker(String(localized: "Prep time"), value: $dish.prepTimeMinutes)
            minutePicker(String(localized: "Cook time"), value: $dish.cookTimeMinutes)
            Picker(String(localized: "Season"), selection: Binding(
                get: { dish.season },
                set: { dish.season = $0 }
            )) {
                Text(String(localized: "Any")).tag(Season?.none)
                ForEach(Season.allCases) { season in
                    Text(season.localizedName).tag(Season?.some(season))
                }
            }
        }
    }

    private var organizationSection: some View {
        Section(String(localized: "Organization")) {
            Toggle(String(localized: "Favorite"), isOn: $dish.isFavorite)
            Picker(String(localized: "Rating"), selection: ratingBinding) {
                ForEach(Array(0...5), id: \.self) { value in
                    Text(verbatim: ratingLabel(value)).tag(value)
                }
            }
            TextField(String(localized: "Collections, separated by commas"), text: $collectionsText)
        }
    }

    private var tagsSections: some View {
        Group {
            Section(String(localized: "Meal type")) {
                FlowLayout(spacing: 8) {
                    ForEach(MealTypeTag.allCases) { tag in
                        chip(tag.localizedName, on: dish.mealTypeTags.contains(tag)) { toggleMealType(tag) }
                    }
                }
            }
            Section(String(localized: "Diet")) {
                FlowLayout(spacing: 8) {
                    ForEach(DietaryTag.allCases) { tag in
                        chip(tag.localizedName, on: dish.dietaryTags.contains(tag)) { toggleDietary(tag) }
                    }
                }
            }
        }
    }

    private var ingredientsSection: some View {
        Section(String(localized: "Ingredients")) {
            ForEach(dish.sortedIngredients) { line in
                IngredientRowEditor(line: line)
            }
            .onDelete(perform: deleteIngredients)

            HStack {
                TextField(String(localized: "e.g. 200 g flour"), text: $newIngredientText)
                    .onSubmit(addIngredient)
                Button(String(localized: "Add"), action: addIngredient)
                    .disabled(newIngredientText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var recipeSection: some View {
        Section(String(localized: "Recipe")) {
            TextField(
                String(localized: "Steps, notes, anything…"),
                text: Binding(get: { dish.recipeText ?? "" }, set: { dish.recipeText = $0.isEmpty ? nil : $0 }),
                axis: .vertical
            )
            .lineLimit(4...12)
            Button { showingRecipeScanner = true } label: {
                Label(String(localized: "Scan from photo or PDF"), systemImage: "doc.viewfinder")
            }
        }
    }

    private var sourceSection: some View {
        Section(String(localized: "Source link")) {
            TextField("https://…", text: $sourceURLText)
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
        }
    }

    private func ratingLabel(_ value: Int) -> String {
        value == 0 ? "—" : String(repeating: "★", count: value)
    }

    private var ratingBinding: Binding<Int> {
        Binding(get: { dish.rating }, set: { dish.rating = $0 })
    }

    private var photoRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(dish.sortedImages) { image in
                    DishThumbnail(data: image.data, size: 88, cornerRadius: 12)
                        .overlay(alignment: .topTrailing) {
                            Button(role: .destructive) {
                                removeImage(image)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                            .padding(4)
                        }
                }

                PhotosPicker(selection: $photoItems, maxSelectionCount: 5, matching: .images) {
                    PlaceholderTile(system: "photo.on.rectangle")
                }
                .buttonStyle(.plain)

                #if os(iOS)
                Button { showingCamera = true } label: {
                    PlaceholderTile(system: "camera")
                }
                .buttonStyle(.plain)
                #endif

                if supportsImagePlayground {
                    Button { showingImagePlayground = true } label: {
                        PlaceholderTile(system: "sparkles")
                    }
                    .buttonStyle(.plain)
                    .disabled(imageConcepts.isEmpty)
                    .accessibilityLabel(String(localized: "Generate an image"))
                }
            }
        }
    }

    /// What Image Playground starts from: the dish's name, plus its main
    /// ingredients so the suggestion looks like the actual meal. Empty when
    /// the dish has no name yet — there'd be nothing to generate from.
    private var imageConcepts: [ImagePlaygroundConcept] {
        let name = dish.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }
        var concepts: [ImagePlaygroundConcept] = [.text(name)]
        let ingredients = dish.sortedIngredients.prefix(5).compactMap { $0.ingredient?.name }
        if !ingredients.isEmpty {
            concepts.append(.extracted(from: ingredients.joined(separator: ", "), title: name))
        }
        return concepts
    }


    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                addImage(ImagePreparation.prepared(from: data))
            }
        }
        photoItems.removeAll()
    }

    private func addImage(_ data: Data) {
        let count = dish.images?.count ?? 0
        let image = DishImage(data: data, sortIndex: count, isPrimary: count == 0)
        image.dish = dish
        context.insert(image)
    }

    private func removeImage(_ image: DishImage) {
        let wasPrimary = image.isPrimary
        context.delete(image)
        if wasPrimary, let next = dish.sortedImages.first(where: { $0 != image }) {
            next.isPrimary = true
        }
    }

    // MARK: - Tags

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(on ? Color.accentColor : Color.gray.opacity(0.18), in: Capsule())
                .foregroundStyle(on ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func toggleMealType(_ tag: MealTypeTag) {
        var set = dish.mealTypeTags
        if set.contains(tag) { set.remove(tag) } else { set.insert(tag) }
        dish.mealTypeTags = set
    }

    private func toggleDietary(_ tag: DietaryTag) {
        var set = dish.dietaryTags
        if set.contains(tag) { set.remove(tag) } else { set.insert(tag) }
        dish.dietaryTags = set
    }

    // MARK: - Ingredients

    private func addIngredient() {
        let text = newIngredientText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let parsed = GermanUnitParser.parse(text)
        let ingredient = upsertIngredient(named: parsed.name)
        let line = DishIngredient(
            canonicalValue: parsed.quantity?.value,
            dimension: parsed.quantity?.dimension,
            displayUnit: parsed.displayUnit,
            isApproximate: parsed.isApproximate,
            note: parsed.note,
            rawText: parsed.rawText,
            sortIndex: dish.ingredients?.count ?? 0
        )
        line.dish = dish
        line.ingredient = ingredient
        context.insert(line)
        newIngredientText = ""
    }

    private func deleteIngredients(_ offsets: IndexSet) {
        let lines = dish.sortedIngredients
        for index in offsets where lines.indices.contains(index) {
            context.delete(lines[index])
        }
    }

    private func upsertIngredient(named rawName: String) -> Ingredient {
        let normalized = Ingredient.normalize(rawName)
        if let existing = (appState.currentHousehold?.ingredients ?? [])
            .first(where: { $0.normalizedName == normalized }) {
            return existing
        }
        let ingredient = Ingredient(name: rawName.isEmpty ? String(localized: "Ingredient") : rawName)
        ingredient.household = appState.currentHousehold
        context.insert(ingredient)
        return ingredient
    }

    // MARK: - Save / cancel

    private func minutePicker(_ title: String, value: Binding<Int?>) -> some View {
        Picker(title, selection: value) {
            Text(String(localized: "—")).tag(Int?.none)
            ForEach([5, 10, 15, 20, 30, 45, 60, 90, 120], id: \.self) { m in
                Text("\(m) min").tag(Int?.some(m))
            }
        }
    }

    private func save(checkDuplicates: Bool = true) {
        dish.name = dish.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = sourceURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        dish.sourceURLString = trimmedURL.isEmpty ? nil : trimmedURL
        dish.collectionNames = Array(Set(collectionsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        if checkDuplicates, let duplicate = RecipeDuplicateDetector.match(
            name: dish.name, sourceURL: dish.sourceURL, in: allDishes, excluding: dish
        ) {
            duplicateDish = duplicate
            return
        }
        if dish.household == nil { dish.household = appState.currentHousehold }
        try? context.save()
        dismiss()
    }

    private func cancel() {
        if isNew {
            context.delete(dish)
        } else {
            context.rollback()
        }
        dismiss()
    }
}

private struct PlaceholderTile: View {
    let system: String
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.quaternary)
            .frame(width: 88, height: 88)
            .overlay(Image(systemName: system).font(.title2).foregroundStyle(.secondary))
    }
}

#Preview {
    NavigationStack {
        DishEditorView(dish: Dish(name: "Neues Gericht"), isNew: true)
    }
    .environment(AppState.preview)
    .modelContainer(PreviewData.container)
}
