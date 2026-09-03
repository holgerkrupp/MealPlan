import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

struct ShareRootView: View {
    let payload: SharePayload
    var onComplete: () -> Void

    @State private var phase: Phase = .loading
    @State private var recipes: [ImportedRecipe] = []
    @State private var plan = false
    @State private var date = Date.now
    @State private var mealKey = ""
    @State private var meals: [(key: String, name: String, symbol: String)] = []
    /// Meal keys already planned (un-skipped) per day, keyed by `dayID` — feeds
    /// the plan stripe's ring / filled-square state.
    @State private var plannedByDay: [String: Set<String>] = [:]
    @State private var saveMessage = String(localized: "Saved to MealPlan")

    private let container = SharedStore.container(cloudKit: false)

    enum Phase: Equatable { case loading, ready, saving, done, failed(String) }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView(String(localized: "Reading recipe…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView(String(localized: "Couldn’t import"), systemImage: "exclamationmark.triangle", description: Text(message))
                case .saving:
                    ProgressView(String(localized: "Saving…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .done:
                    ContentUnavailableView(saveMessage, systemImage: "checkmark.circle.fill")
                case .ready:
                    form
                }
            }
            .navigationTitle(String(localized: "Add to MealPlan"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { onComplete() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if phase == .ready {
                        Button(String(localized: "Save")) { Task { await save() } }
                    }
                }
            }
        }
        .task { await load() }
        .onChange(of: phase) { _, new in
            if new == .done {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { onComplete() }
            }
        }
    }

    private var form: some View {
        Form {
            ForEach(Array(recipes.enumerated()), id: \.offset) { _, recipe in
                Section {
                    HStack(spacing: 12) {
                        if let data = recipe.imageData, let image = Image(data: data) {
                            image.resizable().scaledToFill()
                                .frame(width: 54, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        VStack(alignment: .leading) {
                            Text(recipe.name).font(.headline)
                            Text(String(localized: "\(recipe.ingredientLines.count) ingredients"))
                                .font(.caption).foregroundStyle(.secondary)
                            if recipe.needsReview {
                                Text(String(localized: "Needs a quick check"))
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }

            Section {
                Toggle(String(localized: "Also plan it"), isOn: $plan.animation(.snappy))
                if plan {
                    MealPlannerStripCore(
                        slots: meals.map { MealStripSlot(key: $0.key, name: $0.name, symbolName: $0.symbol) },
                        plannedKeys: { plannedByDay[$0.dayID] ?? [] },
                        selectedDate: $date,
                        selectedMealKey: $mealKey,
                        onSelect: { day, key in
                            date = day.startOfDay
                            mealKey = key
                        },
                        selectHint: String(localized: "Plans it here")
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                }
            } footer: {
                if plan {
                    Text(String(localized: "Tap a slot to choose the day and meal."))
                }
            }
        }
    }

    // MARK: - Work

    @MainActor
    private func load() async {
        loadMeals()
        loadPlannedDays()
        switch payload {
        case .empty:
            phase = .failed(String(localized: "Nothing to import here."))
        case .text(let text):
            recipes = [textRecipe(text)]
            phase = .ready
        case .url(let url):
            do {
                recipes = [try await RecipeSchemaParser().importRecipe(from: url)]
                phase = .ready
            } catch {
                recipes = [fallbackURLRecipe(url)]
                phase = .ready
            }
        case .paprika(let data):
            do {
                recipes = try PaprikaArchive.recipes(from: data)
                phase = recipes.isEmpty ? .failed(String(localized: "No recipes in that file.")) : .ready
            } catch {
                phase = .failed(error.localizedDescription)
            }
        case .mealPlan(let data):
            do {
                recipes = try MealPlanRecipeArchive.importedRecipes(from: data)
                phase = recipes.isEmpty ? .failed(String(localized: "No recipes in that file.")) : .ready
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func loadMeals() {
        let context = container.mainContext
        let fetched = (try? context.fetch(FetchDescriptor<MealType>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        ))) ?? []
        meals = fetched.map { (key: $0.key, name: $0.name, symbol: $0.symbolName) }
        if meals.isEmpty {
            meals = MealType.defaultSeeds.map { (key: $0.key, name: $0.name, symbol: $0.symbol) }
        }
        if mealKey.isEmpty || !meals.contains(where: { $0.key == mealKey }) {
            mealKey = meals.first(where: { $0.key == "dinner" })?.key ?? meals.first?.key ?? "dinner"
        }
    }

    /// Read the existing plan so the stripe can show which days are already
    /// full. A fortnight back is plenty of context for choosing a slot.
    @MainActor
    private func loadPlannedDays() {
        let context = container.mainContext
        let floor = Date.now.startOfDay.adding(days: -14)
        let fetched = (try? context.fetch(FetchDescriptor<MealPlanEntry>(
            predicate: #Predicate { $0.date >= floor }
        ))) ?? []
        var map: [String: Set<String>] = [:]
        for entry in fetched where !entry.skipped {
            map[entry.date.dayID, default: []].insert(entry.mealKey)
        }
        plannedByDay = map
    }

    @MainActor
    private func save() async {
        phase = .saving
        let context = container.mainContext
        let household = try? context.fetch(FetchDescriptor<Household>()).first
        let member = DeviceOwnerName.value
        let result = RecipeImportCommitter.importAll(
            recipes, household: household, createdByName: member, context: context
        )
        if plan {
            for dish in result.dishes {
                MealPlanner.plan(dish: dish, on: date, mealKey: mealKey, household: household, memberName: member, context: context)
            }
        }
        saveMessage = result.isEmpty
            ? String(localized: "Already in MealPlan")
            : String(localized: "Saved \(result.imported) recipes to MealPlan")
        phase = .done
    }

    private func textRecipe(_ text: String) -> ImportedRecipe {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var recipe = ImportedRecipe(name: lines.first ?? String(localized: "New dish"))
        recipe.ingredientLines = Array(lines.dropFirst())
        recipe.needsReview = true
        return recipe
    }

    private func fallbackURLRecipe(_ url: URL) -> ImportedRecipe {
        var recipe = ImportedRecipe(
            name: url.host()?.replacingOccurrences(of: "www.", with: "").capitalized ?? String(localized: "New dish"),
            sourceURL: url
        )
        recipe.needsReview = true
        return recipe
    }
}

/// Device owner name, duplicated here so the extension needn't import app code.
enum DeviceOwnerName {
    @MainActor
    static var value: String {
        #if canImport(UIKit)
        let name = UIDevice.current.name
        return name.isEmpty ? String(localized: "Me") : name
        #else
        return String(localized: "Me")
        #endif
    }
}

extension Image {
    init?(data: Data) {
        #if canImport(UIKit)
        guard let ui = UIImage(data: data) else { return nil }
        self.init(uiImage: ui)
        #else
        return nil
        #endif
    }
}

#Preview("Shared link") {
    ShareRootView(payload: .text("https://example.com/rezepte/pfannkuchen"), onComplete: {})
}

#Preview("Nothing usable") {
    ShareRootView(payload: .empty, onComplete: {})
}
