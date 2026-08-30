import SwiftUI
import SwiftData

/// What an empty meal slot offers when tapped: cook something (search the
/// library, add a new dish, paste a recipe link) — or eat out.
@MainActor
struct DishPickerView: View {
    let date: Date
    let mealKey: String
    let mealTitle: String

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
    }

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Dish.name) private var allDishes: [Dish]

    @State private var tab: Tab = .cook
    @State private var text = ""
    @State private var isImporting = false
    @State private var importError: String?
    @State private var dishToEdit: Dish?

    private let importer: RecipeImporter = RecipeSchemaParser()

    private var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var url: URL? {
        guard query.contains("."), !query.contains(" ") else { return nil }
        let candidate = query.hasPrefix("http") ? query : "https://\(query)"
        guard let u = URL(string: candidate), u.host() != nil else { return nil }
        return u
    }

    private var matches: [Dish] {
        guard !query.isEmpty else { return Array(allDishes.prefix(12)) }
        return allDishes
            .map { dish in
                let name = dish.name.fuzzyScore(query: query)
                let content = dish.searchableText.searchFolded
                return (dish: dish, score: max(name, content.contains(query.searchFolded) ? 0.7 : 0))
            }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(12)
            .map(\.dish)
    }

    private var hasExactMatch: Bool {
        allDishes.contains { $0.name.searchFolded == query.searchFolded }
    }

    var body: some View {
        Group {
            switch tab {
            case .cook: dishList
            case .eatOut: EatOutPickerView(date: date, mealKey: mealKey) { dismiss() }
            }
        }
        .safeAreaInset(edge: .top) {
            Picker(String(localized: "How are we eating?"), selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.bottom, 8)
            .background(.bar)
        }
        .navigationTitle(pickerTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
            }
        }
    }

    /// The "Cook" half: the library search, importer and new-dish shortcut.
    private var dishList: some View {
        List {
            if let url {
                Section {
                    Button {
                        Task { await importAndPlan(url) }
                    } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text(String(localized: "Import from \(url.host() ?? "link")"))
                                Text(url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        } icon: {
                            if isImporting { ProgressView() } else { Image(systemName: "link") }
                        }
                    }
                    .disabled(isImporting)
                }
            }

            if !query.isEmpty, !hasExactMatch, url == nil {
                Section {
                    Button {
                        addNewDishAndPlan(name: query, openEditor: true)
                    } label: {
                        Label(String(localized: "Add “\(query)” as a new dish"), systemImage: "plus.circle")
                    }
                }
            }

            Section(matches.isEmpty ? "" : String(localized: "Your dishes")) {
                ForEach(matches) { dish in
                    Button {
                        planExisting(dish)
                    } label: {
                        HStack(spacing: 12) {
                            DishThumbnail(dish: dish, size: 40, cornerRadius: 8)
                            Text(dish.name)
                            Spacer()
                            if let days = dish.daysSinceLastCooked(), days >= 30 {
                                Text(String(localized: "\(days) d"))
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                if matches.isEmpty && query.isEmpty {
                    Text(String(localized: "Start typing to search, or paste a recipe link."))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $text, prompt: String(localized: "Dish name or link"))
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
        .sheet(item: $dishToEdit) { dish in
            NavigationStack { DishEditorView(dish: dish, isNew: true) }
        }
    }

    private var pickerTitle: String {
        "\(mealTitle) · \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    // MARK: - Actions

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
        if openEditor {
            dishToEdit = dish
        } else {
            dismiss()
        }
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
