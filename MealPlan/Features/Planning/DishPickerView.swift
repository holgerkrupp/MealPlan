import SwiftUI
import SwiftData

/// What an empty meal slot offers when tapped: cook something (search the
/// library by name or by ingredient, add a new dish, paste a recipe link) —
/// or eat out.
///
/// The search field sits in the sheet's own header rather than in
/// `.searchable`, which on macOS hoists it into the window toolbar, far away
/// from the results it filters.
@MainActor
struct DishPickerView: View {
    let date: Date
    let mealKey: String
    let mealTitle: String
    var mealSymbol: String = "fork.knife"
    /// Called after a bare new dish is planned and the cook wants to fill in
    /// the recipe. The editor belongs to whoever presented this view: on macOS
    /// this is a popover, and a sheet raised from one dies with it.
    var onEditNewDish: (Dish) -> Void = { _ in }

    /// The two halves of the planning sheet.
    private enum Tab: String, CaseIterable, Identifiable {
        case cook, eatOut
        var id: String { rawValue }
        var title: String {
            switch self {
            case .cook: String(localized: "Cook")
            case .eatOut: String(localized: "Eat out")
            }
        }
        var symbol: String {
            switch self {
            case .cook: "frying.pan"
            case .eatOut: "storefront"
            }
        }
        var prompt: String {
            switch self {
            case .cook: String(localized: "Search your dishes, or paste a link")
            case .eatOut: String(localized: "Restaurant, café, bakery…")
            }
        }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Dish.name) private var allDishes: [Dish]

    @State private var tab: Tab = .cook
    @State private var text = ""
    @State private var placeQuery = ""
    @State private var isImporting = false
    @State private var importError: String?
    @FocusState private var isSearchFocused: Bool

    private let importer: RecipeImporter = RecipeSchemaParser()

    private var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Each half searches for something different, so each keeps its own text.
    private var searchText: Binding<String> {
        tab == .cook ? $text : $placeQuery
    }

    private var url: URL? {
        guard query.contains("."), !query.contains(" ") else { return nil }
        let candidate = query.hasPrefix("http") ? query : "https://\(query)"
        guard let u = URL(string: candidate), u.host() != nil else { return nil }
        return u
    }

    private var results: [DishSearch.Result] {
        DishSearch.rank(query.isEmpty ? suggestions : allDishes, query: query)
    }

    /// What the list shows before anything is typed: dishes tagged for this
    /// meal first, the longest-neglected at the top — a better opening offer
    /// than everything beginning with "A".
    private var suggestions: [Dish] {
        let tag = MealTypeTag(rawValue: mealKey)
        return allDishes.sorted { a, b in
            let aFits = tag.map(a.mealTypeTags.contains) ?? false
            let bFits = tag.map(b.mealTypeTags.contains) ?? false
            if aFits != bFits { return aFits }
            return (a.lastUsedDate ?? .distantPast) < (b.lastUsedDate ?? .distantPast)
        }
    }

    private var hasExactMatch: Bool {
        DishSearch.hasExactMatch(allDishes, name: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch tab {
            case .cook: dishList
            case .eatOut: EatOutPickerView(
                date: date, mealKey: mealKey, query: placeQuery
            ) { dismiss() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 520, idealHeight: 620)
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
        .task { isSearchFocused = true }
        .alert(
            String(localized: "Couldn’t import that link"),
            isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
        ) {
            Button(String(localized: "Save link only")) {
                if let url { addNewDishAndPlan(name: url.host() ?? query, sourceURL: url, needsReview: true, openEditor: false) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: mealSymbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(.tint.opacity(0.15)))

                VStack(alignment: .leading, spacing: 1) {
                    Text(mealTitle)
                        .font(.headline)
                    Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
            }

            Picker(String(localized: "How are we eating?"), selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            searchField
        }
        .padding(16)
        .background(.bar)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(tab.prompt, text: searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onSubmit { commitTypedName() }
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                #endif
            if !searchText.wrappedValue.isEmpty {
                Button {
                    searchText.wrappedValue = ""
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary)
        )
    }

    // MARK: - Cook

    /// The "Cook" half: the library search, the importer and the new-dish
    /// shortcut.
    private var dishList: some View {
        List {
            if let url {
                Section {
                    Button {
                        Task { await importAndPlan(url) }
                    } label: {
                        HStack(spacing: 12) {
                            leadingBadge(symbol: "link", filled: true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "Import from \(url.host() ?? "link")"))
                                Text(url.absoluteString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if isImporting { ProgressView().controlSize(.small) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isImporting)
                }
            }

            if !query.isEmpty, !hasExactMatch, url == nil {
                Section {
                    Button {
                        addNewDishAndPlan(name: query, openEditor: false)
                    } label: {
                        HStack(spacing: 12) {
                            leadingBadge(symbol: "plus", filled: true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "Add “\(query)”"))
                                Text(String(localized: "A new dish, planned for this meal"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        addNewDishAndPlan(name: query, openEditor: true)
                    } label: {
                        HStack(spacing: 12) {
                            leadingBadge(symbol: "square.and.pencil", filled: false)
                            Text(String(localized: "Add it and fill in the recipe"))
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if !results.isEmpty {
                Section(query.isEmpty ? String(localized: "Suggestions") : String(localized: "Your dishes")) {
                    ForEach(results) { result in
                        Button {
                            planExisting(result.dish)
                        } label: {
                            dishRow(result)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if query.isEmpty {
                Section {
                    emptyLibraryHint
                }
            } else if url == nil {
                Section {
                    Text(String(localized: "Nothing in your library matches that — yet."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #else
        .listStyle(.insetGrouped)
        #endif
    }

    private func dishRow(_ result: DishSearch.Result) -> some View {
        HStack(spacing: 12) {
            DishThumbnail(dish: result.dish, size: 44, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.dish.name)
                    .lineLimit(2)
                if let detail = detail(for: result) {
                    Text(detail.text)
                        .font(.caption)
                        .foregroundStyle(detail.isStale ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "plus.circle")
                .font(.title3)
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// The caption under a dish: why it surfaced, or — when the name itself
    /// matched — how long it has been since anyone cooked it.
    private func detail(for result: DishSearch.Result) -> (text: String, isStale: Bool)? {
        if let reason = result.reason { return (reason, false) }
        guard let last = result.dish.lastUsedDate else {
            return (String(localized: "Never cooked"), false)
        }
        let days = result.dish.daysSinceLastCooked() ?? 0
        return (
            String(localized: "Cooked \(last.formatted(.relative(presentation: .named)))"),
            days >= 30
        )
    }

    private var emptyLibraryHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.book.closed")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(String(localized: "Your library is empty"))
                .font(.headline)
            Text(String(localized: "Type a name to add a dish, or paste a recipe link."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowBackground(Color.clear)
    }

    /// The square icon that opens the import and new-dish rows, sized to match
    /// a dish thumbnail so the whole list shares one left edge.
    private func leadingBadge(symbol: String, filled: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(filled ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
            .frame(width: 44, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(filled ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
            )
    }

    // MARK: - Actions

    /// Return in the search field: plan the dish that already carries this
    /// name, or make one on the spot. Typing the name is the whole gesture —
    /// nothing should have to be picked out of the list first.
    private func commitTypedName() {
        guard tab == .cook, !query.isEmpty, url == nil else { return }
        if let existing = DishSearch.exactMatch(allDishes, name: query) {
            planExisting(existing)
        } else {
            addNewDishAndPlan(name: query, openEditor: false)
        }
    }

    private func planExisting(_ dish: Dish) {
        MealPlanner.plan(
            dish: dish, on: date, mealKey: mealKey,
            household: appState.currentHousehold,
            memberName: appState.currentMemberName,
            context: context
        )
        dismiss()
    }

    private func addNewDishAndPlan(name: String, sourceURL: URL? = nil, needsReview: Bool = false, openEditor: Bool) {
        let dish = Dish(name: name)
        dish.household = appState.currentHousehold
        dish.createdByName = appState.currentMemberName
        dish.sourceURL = sourceURL
        dish.needsReview = needsReview
        if let tag = MealTypeTag(rawValue: mealKey) { dish.mealTypeTags = [tag] }
        dish.refreshAutoGlyph()
        context.insert(dish)
        // Quick-added dishes never pass through the editor, so this is their
        // only chance at a starting set of tags.
        DishBuilder.addSuggestedTags(to: dish, household: appState.currentHousehold)
        MealPlanner.plan(
            dish: dish, on: date, mealKey: mealKey,
            household: appState.currentHousehold,
            memberName: appState.currentMemberName,
            context: context
        )
        if openEditor { onEditNewDish(dish) }
        dismiss()
    }

    private func importAndPlan(_ url: URL) async {
        isImporting = true
        defer { isImporting = false }
        do {
            var recipe = try await importer.importRecipe(from: url)
            if let existing = RecipeDuplicateDetector.match(recipe, in: allDishes) {
                planExisting(existing)
                return
            }
            if let tag = MealTypeTag(rawValue: mealKey), recipe.categories.isEmpty {
                recipe.categories = [tag.rawValue]
            }
            let dish = DishBuilder.makeDish(
                from: recipe,
                household: appState.currentHousehold,
                createdByName: appState.currentMemberName,
                context: context
            )
            if let tag = MealTypeTag(rawValue: mealKey) { dish.mealTypeTags = [tag] }
            MealPlanner.plan(
                dish: dish, on: date, mealKey: mealKey,
                household: appState.currentHousehold,
                memberName: appState.currentMemberName,
                context: context
            )
            dismiss()
        } catch {
            importError = error.localizedDescription
        }
    }
}

#Preview {
    DishPickerView(
        date: .now,
        mealKey: PreviewData.mealType.key,
        mealTitle: PreviewData.mealType.name,
        mealSymbol: PreviewData.mealType.symbolName
    )
    .environment(AppState.preview)
    .environment(PurchaseManager.shared)
    .modelContainer(PreviewData.container)
}
