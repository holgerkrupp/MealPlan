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
    @State private var date = Date.now
    @State private var mealKey = ""
    @State private var meals: [(key: String, name: String, symbol: String)] = []
    /// Meal keys already planned (un-skipped) per day, keyed by `dayID` — feeds
    /// the plan stripe's ring / filled-square state.
    @State private var plannedByDay: [String: Set<String>] = [:]
    @State private var saveMessage = String(localized: "Saved to MealPlan")
    @State private var sharedURL: URL?
    @State private var siteCandidate: RecipeSiteCandidate?
    @State private var isSubscribing = false
    @State private var isSaving = false
    @State private var saveNotice: String?
    @State private var savedDishID: UUID?

    private let container = SharedStore.container(cloudKit: false)

    enum Phase: Equatable { case loading, ready, siteReady, ambiguous, saving, done, failed(String) }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView(String(localized: "Reading recipe…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView(String(localized: "Couldn’t import"), systemImage: "exclamationmark.triangle", description: Text(message))
                case .siteReady:
                    siteForm
                case .ambiguous:
                    ambiguousForm
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
            ForEach(recipes.indices, id: \.self) { index in
                Section {
                    HStack(spacing: 12) {
                        if let data = recipes[index].imageData, let image = Image(data: data) {
                            image.resizable().scaledToFill()
                                .frame(width: 54, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        VStack(alignment: .leading) {
                            Text(recipes[index].name).font(.headline)
                            Text(String(localized: "\(recipes[index].ingredientLines.count) ingredients"))
                                .font(.caption).foregroundStyle(.secondary)
                            if recipes[index].needsReview {
                                Text(String(localized: "Needs a quick check"))
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }

                    if case .text = payload {
                        TextField(String(localized: "Recipe name"), text: $recipes[index].name)
                        TextField(String(localized: "Ingredients, one per line"), text: ingredientTextBinding(at: index), axis: .vertical)
                            .lineLimit(4...10)
                        TextField(String(localized: "Method"), text: instructionTextBinding(at: index), axis: .vertical)
                            .lineLimit(4...10)
                    }
                }
            }

            Section(String(localized: "Plan")) {
                MealPlannerStripCore(
                    slots: stripSlots,
                    plannedKeys: { plannedByDay[$0.dayID] ?? [] },
                    selectedDate: $date,
                    selectedMealKey: $mealKey,
                    onSelect: { day, key in
                        date = day.startOfDay
                        mealKey = key
                    },
                    isDateLocked: {
                        !PlanningAccess.canPlan(on: $0, isUnlocked: PurchaseEntitlementCache.isUnlocked)
                    },
                    selectHint: String(localized: "Plans it here")
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                Text(String(localized: "Tap a slot to choose the day and meal. The bottom row plans it as an extra on that day."))
                    .font(.footnote).foregroundStyle(.secondary)
            }

            siteActionSection
            actionSection
        }
    }

    private var actionSection: some View {
        Section {
            Button(String(localized: "Save recipe"), systemImage: "bookmark") {
                Task { await save(planRecipe: false) }
            }
            .disabled(isSaving)
            Button(String(localized: "Save & plan"), systemImage: "calendar.badge.plus") {
                Task { await save(planRecipe: true) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSaving || !PlanningAccess.canPlan(on: date, isUnlocked: PurchaseEntitlementCache.isUnlocked))
            Button(String(localized: "Continue in MealPlan"), systemImage: "arrow.up.forward.app") {
                queueHandoff()
            }
            if let saveNotice {
                Text(saveNotice).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var siteActionSection: some View {
        if let siteCandidate {
            Section(String(localized: "Recipe site")) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(siteCandidate.title).font(.headline)
                        Text(siteCandidate.detail)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "globe") }
                Text(String(localized: "Subscribe to bring future recipes from this site into Discover."))
                    .font(.footnote).foregroundStyle(.secondary)
                Button(String(localized: "Subscribe to site"), systemImage: "dot.radiowaves.left.and.right") {
                    Task { await subscribeToSite(siteCandidate) }
                }
                .disabled(isSubscribing)
            }
        }
    }

    private func ingredientTextBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { recipes[index].ingredientLines.joined(separator: "\n") },
            set: { recipes[index].ingredientLines = $0.components(separatedBy: .newlines) }
        )
    }

    private func instructionTextBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { recipes[index].instructions ?? "" },
            set: { recipes[index].instructions = $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        )
    }

    private var siteForm: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(siteCandidate?.title ?? String(localized: "Recipe site")).font(.headline)
                        Text(siteCandidate?.detail ?? sharedURL?.host() ?? "")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "globe")
                        .foregroundStyle(.tint)
                }
            } footer: {
                Text(String(localized: "MealPlan found a public recipe feed or discovery page. Subscribe to bring future recipes into Discover."))
            }
            if siteCandidate != nil {
                Section(String(localized: "Continue in MealPlan")) {
                    Text(String(localized: "Open MealPlan to preview this site in Discover. Subscribing is optional."))
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(String(localized: "Continue in MealPlan"), systemImage: "arrow.up.forward.app") { queueHandoff() }
                }
            }
        }
    }

    private var ambiguousForm: some View {
        Form {
            Section {
                Text(String(localized: "This shared page could be a recipe or a recipe site."))
                    .foregroundStyle(.secondary)
            }
            Section(String(localized: "Recipe")) {
                Button(String(localized: "Import recipe"), systemImage: "fork.knife") {
                    Task { await importSharedURL() }
                }
            }
            if siteCandidate != nil {
                Section(String(localized: "Recipe site")) {
                    Button(String(localized: "Subscribe to site"), systemImage: "dot.radiowaves.left.and.right") {
                        Task { await subscribeToSite(siteCandidate ?? .manual(for: sharedURL ?? URL(string: "https://example.com")!)) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubscribing)
                    Button(String(localized: "Continue in MealPlan"), systemImage: "arrow.up.forward.app") { queueHandoff() }
                }
            }
        }
    }

    /// The household's meals and, below them, the extras row — the same
    /// complete set of slots the app's plan stripe offers, so a shared recipe
    /// can land on a day without using up one of the meals.
    private var stripSlots: [MealStripSlot] {
        meals.map { MealStripSlot(key: $0.key, name: $0.name, symbolName: $0.symbol) }
            + [MealStripSlot(
                key: MealType.extraKey,
                name: MealType.extraName,
                symbolName: MealType.extraSymbolName,
                countsTowardCompletion: false
            )]
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
            sharedURL = url
            switch await RecipeSiteDiscoveryService.classify(url) {
            case .recipe:
                await importSharedURL()
            case .recipeSite(let candidate):
                siteCandidate = candidate
                phase = .siteReady
            case .feed(let feed):
                siteCandidate = RecipeSiteCandidate(title: feed.title, siteURL: feed.siteURL, feedURL: feed.feedURL)
                phase = .siteReady
            case .ambiguous(let url):
                sharedURL = url
                siteCandidate = .manual(for: url)
                phase = .ambiguous
            case .unsupported(let url):
                sharedURL = url
                siteCandidate = .manual(for: url)
                await importSharedURL()
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
    private func importSharedURL() async {
        guard let url = sharedURL else { return }
        do {
            recipes = [try await RecipeSchemaParser().importRecipe(from: url)]
            phase = .ready
        } catch {
            recipes = [fallbackURLRecipe(url)]
            phase = .ready
        }
    }

    @MainActor
    private func subscribeToSite(_ candidate: RecipeSiteCandidate) async {
        isSubscribing = true
        defer { isSubscribing = false }
        do {
            let context = container.mainContext
            let household = try? context.fetch(FetchDescriptor<Household>()).first
            guard HouseholdMutationAuthorization.canMutate(household: household) else {
                phase = .failed(HouseholdSharingError.readOnlyHousehold.localizedDescription)
                return
            }
            _ = try await RecipeFeedService.subscribe(to: candidate, household: household, context: context)
            HouseholdStoreGeneration.markDirty()
            saveMessage = String(localized: "Subscribed to \(candidate.title)")
            phase = .done
        } catch {
            phase = .failed(error.localizedDescription)
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
    private func save(planRecipe: Bool) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let context = container.mainContext
        let household = try? context.fetch(FetchDescriptor<Household>()).first
        guard HouseholdMutationAuthorization.canMutate(household: household) else {
            phase = .failed(HouseholdSharingError.readOnlyHousehold.localizedDescription)
            return
        }
        let member = household.flatMap { household in
            HouseholdCollaborationStore.load(for: household.uuid).flatMap { snapshot in
                (snapshot.memberID != nil || snapshot.participantID != nil) ? snapshot.displayName : nil
            }
        } ?? DeviceOwnerName.value
        let result = RecipeImportCommitter.importAll(
            recipes, household: household, createdByName: member, context: context
        )
        guard !result.persistenceFailed else {
            saveNotice = result.summary
            return
        }
        if let dish = result.dishesForPlanning.first { savedDishID = dish.uuid }
        var planned = false
        if planRecipe {
            guard PlanningAccess.canPlan(on: date, isUnlocked: PurchaseEntitlementCache.isUnlocked) else {
                saveNotice = String(localized: "Recipe saved to Dishes. This date is locked, so it wasn’t planned.")
                HouseholdStoreGeneration.markDirty()
                return
            }
            var allPlanned = !result.dishesForPlanning.isEmpty
            for dish in result.dishesForPlanning {
                switch MealPlanner.planOnce(dish: dish, on: date, mealKey: mealKey, household: household, memberName: member, context: context) {
                case .saved, .alreadyPlanned: break
                case .failed: allPlanned = false
                }
            }
            planned = allPlanned
            guard planned else {
                saveNotice = String(localized: "Recipe saved to Dishes, but the plan couldn’t be saved. Try Save & plan again.")
                HouseholdStoreGeneration.markDirty()
                return
            }
        }
        saveMessage = planRecipe
            ? String(localized: "Recipe saved to Dishes and planned.")
            : (result.isEmpty ? String(localized: "Recipe already saved to Dishes.") : String(localized: "Recipe saved to Dishes."))
        HouseholdStoreGeneration.markDirty()
        phase = .done
    }

    @MainActor
    private func queueHandoff() {
        let destination: ShareHandoff.Destination
        if let savedDishID {
            destination = .dish(savedDishID)
        } else if let sharedURL {
            if siteCandidate != nil && recipes.isEmpty { destination = .site(sharedURL) }
            else { destination = .addDish(url: sharedURL, name: recipes.first?.name) }
        } else {
            destination = .addDish(url: nil, name: recipes.first?.name)
        }
        guard ShareHandoff.store(destination) else {
            saveNotice = String(localized: "MealPlan couldn’t prepare the handoff. Try again.")
            return
        }
        saveMessage = String(localized: "Handoff ready. Open MealPlan to continue.")
        phase = .done
    }

    /// Shared text is split into title, ingredients and method by the same
    /// heuristic the recipe scanner falls back to; whatever it can't place is
    /// kept as the method, so nothing the user shared is thrown away.
    private func textRecipe(_ text: String) -> ImportedRecipe {
        ScannedRecipeParser.importedRecipe(fromText: text)
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
