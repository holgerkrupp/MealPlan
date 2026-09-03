import SwiftUI
import SwiftData
import AppIntents
import ESADesignKit

@MainActor
struct DishDetailView: View {
    @Bindable var dish: Dish
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Dish.name) private var allDishes: [Dish]

    @State private var targetServings: Int = 0
    @State private var showingEditor = false
    @State private var showingPlanSheet = false
    @State private var showingRecipeFinder = false
    @State private var showingCookingMode = false
    @State private var exportedArchive: ExportedRecipeArchive?
    @State private var exportError: String?
    @State private var confirmingDelete = false
    @State private var showingVariantPicker = false
    @State private var editingVariant: Dish?

    private var scaler: ServingScaler {
        ServingScaler(
            baseServings: dish.servings,
            targetServings: max(1, targetServings),
            system: appState.unitSystem,
            roundsAmounts: appState.roundsDisplayedAmounts
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !usesCoverHero {
                    imageStrip
                }

                if dish.needsReview {
                    Label(String(localized: "Imported automatically — please check the details."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }

                tagRow
                timeRow
                Divider()
                ingredientsSection

                if let recipe = dish.recipeText, !recipe.isEmpty {
                    section(String(localized: "How to make it")) {
                        Text(recipe)
                    }
                } else if !appState.isGuest {
                    findRecipePrompt
                }

                if let url = dish.sourceURL {
                    Link(destination: url) {
                        Label(url.host() ?? url.absoluteString, systemImage: "safari")
                    }
                }
                if let deepLink = dish.deepLinkURL {
                    Link(destination: deepLink) {
                        Label(appLinkLabel, systemImage: "arrow.up.forward.app")
                    }
                }

                variantsSection
                statsSection
            }
            .padding()
        }
        .navigationTitle(dish.name.isEmpty ? String(localized: "Untitled dish") : dish.name)
        .appEntityIdentifier(EntityIdentifier(for: DishEntity.self, identifier: dish.uuid))
        #if os(iOS)
        .navigationBarTitleDisplayMode(usesCoverHero ? .inline : .large)
        #endif
        .coverHero(
            imageData: dish.primaryImageData,
            title: dish.name.isEmpty ? String(localized: "Untitled dish") : dish.name,
            enabled: usesCoverHero
        )
        .ignoresSafeArea(.all, edges: usesCoverHero ? .top : [])
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack {
                    if !dish.sortedIngredients.isEmpty || !(dish.recipeText ?? "").isEmpty {
                        Button(String(localized: "Cook"), systemImage: "frying.pan") {
                            showingCookingMode = true
                        }
                    }
                    Button(String(localized: "Plan"), systemImage: "calendar.badge.plus") {
                        showingPlanSheet = true
                    }
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button(String(localized: "Edit"), systemImage: "pencil") { showingEditor = true }
            }
            if !appState.isGuest {
                ToolbarItem(placement: .secondaryAction) {
                    Button(String(localized: "Save as new variant"), systemImage: "square.on.square") {
                        addVariant()
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button(String(localized: "Group with another dish"), systemImage: "link") {
                        showingVariantPicker = true
                    }
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button(String(localized: "Export recipe"), systemImage: "square.and.arrow.up") {
                    exportRecipe()
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button(String(localized: "Delete recipe"), systemImage: "trash", role: .destructive) {
                    confirmingDelete = true
                }
            }
        }
        .onAppear { if targetServings == 0 { targetServings = max(1, dish.servings) } }
        // Backs the Dish menu. It is the only publisher of this value, so the
        // whole menu greys out as soon as no recipe is open.
        .focusedSceneValue(\.dishCommands, dishCommands)
        .sheet(isPresented: $showingEditor) {
            NavigationStack { DishEditorView(dish: dish, isNew: false) }
        }
        .sheet(isPresented: $showingPlanSheet) {
            NavigationStack {
                PlanDishSheet(dish: dish, defaultDate: appState.selectedDate)
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showingRecipeFinder) {
            NavigationStack { RecipeFinderView(dish: dish) }
        }
        .sheet(isPresented: $showingCookingMode) {
            NavigationStack { CookingModeView(dish: dish) }
                .environment(appState)
        }
        .sheet(item: $exportedArchive) { RecipeArchiveShareSheet(archive: $0) }
        .sheet(isPresented: $showingVariantPicker) {
            NavigationStack {
                DishVariantPickerView(dish: dish)
            }
        }
        .sheet(item: $editingVariant) { variant in
            NavigationStack { DishEditorView(dish: variant, isNew: true) }
        }
        .alert(
            String(localized: "Couldn’t export recipe"),
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .confirmationDialog(
            String(localized: "Delete “\(dish.name)”?"),
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete recipe"), role: .destructive) {
                deleteRecipe()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
    }

    /// What the Dish menu offers for this recipe. The optional actions mirror
    /// the toolbar's own conditions, so a menu item is grey exactly when the
    /// matching button is missing.
    private var dishCommands: DishCommands {
        var commands = DishCommands(
            plan: { showingPlanSheet = true },
            edit: { showingEditor = true },
            exportRecipe: { exportRecipe() },
            delete: { confirmingDelete = true }
        )
        if !dish.sortedIngredients.isEmpty || !(dish.recipeText ?? "").isEmpty {
            commands.cook = { showingCookingMode = true }
        }
        // "Find a recipe" only makes sense while there isn't one yet, and only
        // with a name to search for.
        if !appState.isGuest,
           (dish.recipeText ?? "").isEmpty,
           !dish.name.trimmingCharacters(in: .whitespaces).isEmpty {
            commands.findRecipe = { showingRecipeFinder = true }
        }
        if !appState.isGuest {
            commands.saveAsVariant = { addVariant() }
            commands.groupWithDish = { showingVariantPicker = true }
        }
        return commands
    }

    private var appLinkLabel: String {
        guard let app = dish.importedSourceApp?.trimmingCharacters(in: .whitespacesAndNewlines),
              !app.isEmpty else { return String(localized: "Open in app") }
        return String(localized: "Open in \(app)")
    }

    /// Mirrors the compact detail presentation in Game Collector: a recipe's
    /// primary photo becomes the zooming backdrop, while wider layouts retain
    /// the existing photo strip.
    private var usesCoverHero: Bool {
        dish.primaryImageData != nil && horizontalSizeClass == .compact
    }

    /// Shown in place of the recipe when there isn't one yet.
    private var findRecipePrompt: some View {
        section(String(localized: "How to make it")) {
            VStack(alignment: .leading, spacing: 10) {
                Text("No recipe yet. Search the web and save one straight onto this dish.")
                    .foregroundStyle(.secondary)
                Button(String(localized: "Find a recipe"), systemImage: "magnifyingglass") {
                    showingRecipeFinder = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(dish.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var imageStrip: some View {
        let images = dish.sortedImages
        if images.isEmpty {
            DishThumbnail(dish: dish, size: 160, cornerRadius: 20)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(images) { image in
                        DishThumbnail(data: image.data, size: 200, cornerRadius: 20)
                    }
                }
            }
        }
    }

    private var tagRow: some View {
        WrapHStack(spacing: 8) {
            if dish.isFavorite {
                badge(String(localized: "Favorite"), system: "heart.fill", tint: .pink)
            }
            if dish.rating > 0 {
                badge(String(repeating: "★", count: dish.rating), system: "star.fill", tint: .yellow)
            }
            ForEach(dish.collectionNames, id: \.self) { collection in
                badge(collection, system: "folder", tint: .indigo)
            }
            ForEach(dish.sortedTagNames, id: \.self) { tag in
                badge(tag, system: "tag", tint: .teal)
            }
            ForEach(Array(dish.mealTypeTags).sorted(by: { $0.rawValue < $1.rawValue })) { tag in
                badge(tag.localizedName, system: "circle.fill", tint: .accentColor)
            }
            ForEach(Array(dish.dietaryTags).sorted(by: { $0.rawValue < $1.rawValue })) { tag in
                badge(tag.localizedName, system: tag.symbolName, tint: .green)
            }
            if let season = dish.season {
                badge(season.localizedName, system: "leaf", tint: .brown)
            }
        }
    }

    @ViewBuilder
    private var timeRow: some View {
        HStack(spacing: 20) {
            if let prep = dish.prepTimeMinutes {
                metric(String(localized: "Prep"), "\(prep) min")
            }
            if let cook = dish.cookTimeMinutes {
                metric(String(localized: "Cook"), "\(cook) min")
            }
            metric(String(localized: "Default"), String(localized: "\(dish.servings) servings"))
        }
    }

    private var ingredientsSection: some View {
        section(String(localized: "Ingredients")) {
            HStack {
                Text(String(localized: "For"))
                Stepper(value: $targetServings, in: 1...50) {
                    Text(String(localized: "\(max(1, targetServings)) servings"))
                        .monospacedDigit()
                }
            }
            .padding(.bottom, 4)

            if dish.sortedIngredients.isEmpty {
                Text(String(localized: "No ingredients added yet."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(dish.sortedIngredients) { line in
                    HStack(alignment: .firstTextBaseline) {
                        Text(line.ingredient?.name ?? line.rawText ?? "—")
                        Spacer()
                        if let amount = scaler.amountText(for: line) {
                            Text(amount)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.vertical, 2)
                    if let note = line.note, !note.isEmpty, line.quantity != nil {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Other takes on the same dish. Present only once there is a group —
    /// until then the toolbar's "Save as new variant" is the way in.
    @ViewBuilder
    private var variantsSection: some View {
        let siblings = DishVariants.siblings(of: dish, in: allDishes)
        if !siblings.isEmpty {
            section(String(localized: "Other variants of \(dish.variantGroupDisplayName)")) {
                ForEach(siblings) { sibling in
                    NavigationLink(value: sibling) {
                        HStack(spacing: 12) {
                            DishThumbnail(dish: sibling, size: 44, cornerRadius: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sibling.name)
                                if let minutes = sibling.totalTimeMinutes {
                                    Text(String(localized: "\(minutes) min"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
                if !appState.isGuest {
                    Button(String(localized: "Remove from group"), systemImage: "minus.circle") {
                        DishVariants.leaveGroup(dish, in: allDishes)
                        try? context.save()
                    }
                    .font(.subheadline)
                    .padding(.top, 4)
                }
            }
        }
    }

    private var statsSection: some View {
        section(String(localized: "History")) {
            LabeledContent(String(localized: "Times cooked"), value: "\(dish.usageCount)")
            if let last = dish.lastUsedDate {
                LabeledContent(String(localized: "Last cooked"),
                               value: last.formatted(date: .abbreviated, time: .omitted))
            } else {
                LabeledContent(String(localized: "Last cooked"), value: String(localized: "Never"))
            }
            LabeledContent(String(localized: "Added"),
                           value: dish.dateCreated.formatted(date: .abbreviated, time: .omitted))
        }
    }

    // MARK: - Building blocks

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func badge(_ text: String, system: String, tint: Color) -> some View {
        Label(text, systemImage: system)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.weight(.medium))
        }
    }

    private func exportRecipe() {
        do {
            exportedArchive = ExportedRecipeArchive(url: try MealPlanRecipeArchive.temporaryFile(for: [dish]))
        } catch {
            exportError = error.localizedDescription
        }
    }

    /// Copies this dish so the cook can change the copy freely. Both end up in
    /// the same variant group.
    private func addVariant() {
        editingVariant = DishBuilder.duplicateAsVariant(of: dish, context: context)
    }

    private func deleteRecipe() {
        context.delete(dish)
        try? context.save()
        SharedStore.reloadWidgets()
        dismiss()
    }
}

/// A very small flow layout for badges.
@MainActor
struct WrapHStack<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        FlowLayout(spacing: spacing) { content }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview {
    NavigationStack {
        DishDetailView(dish: PreviewData.household.dishes?.first(where: { $0.name.contains("Pfann") }) ?? Dish(name: "Test"))
    }
    .environment(AppState.preview)
    .modelContainer(PreviewData.container)
}

#Preview("Badge wrap") {
    WrapHStack {
        ForEach(DietaryTag.allCases) { tag in
            Label(tag.localizedName, systemImage: tag.symbolName)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
        }
    }
    .padding()
}
