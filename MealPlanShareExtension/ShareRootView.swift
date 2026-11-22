import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// Share sheets need a deterministic, bounded response. Apple Intelligence
/// and image downloads are still available in the full app, but neither is a
/// prerequisite for showing the extracted recipe and its save actions here.
private struct ShareExtensionDeterministicAIExtractor: RecipeAIExtractor {
    var availability: RecipeAIAvailability { .unavailable }

    func extract(from _: RecipeWebPageRepresentation) async -> RecipeAIExtraction? {
        nil
    }
}

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
    @State private var classification: SharedRecipeURLKind?
    @State private var isSubscribing = false
    @State private var isSaving = false
    @State private var saveNotice: String?
    @State private var subscriptionNotice: String?
    @State private var subscriptionSucceeded = false
    @State private var savedDishID: UUID?
    @State private var discoveryGeneration = UUID()

    private let container = SharedStore.container(cloudKit: false)

    enum Phase: Equatable {
        case loading
        case extracting
        case ready
        case siteReady
        case ambiguous
        case saving
        case done
        case handoffReady
        case failed(String)
    }

    private enum FailureRecovery: Equatable {
        case none
        case reload
    }

    @State private var failureRecovery: FailureRecovery = .none

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView(String(localized: "Reading recipe…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .extracting:
                    ProgressView(String(localized: "Extracting recipe…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    VStack(spacing: 16) {
                        ContentUnavailableView(
                            String(localized: "Couldn’t import"),
                            systemImage: "exclamationmark.triangle",
                            description: Text(message)
                        )
                        if failureRecovery == .reload {
                            Button(String(localized: "Try again"), systemImage: "arrow.clockwise") {
                                Task { await retryLoad() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .siteReady:
                    siteForm
                case .ambiguous:
                    ambiguousForm
                case .saving:
                    ProgressView(String(localized: "Saving…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .done:
                    ContentUnavailableView(saveMessage, systemImage: "checkmark.circle.fill")
                case .handoffReady:
                    handoffReadyView
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
                                Label(String(localized: "Needs review"), systemImage: "exclamationmark.circle")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }

                    if recipes[index].needsReview || isTextPayload {
                        if recipes[index].needsReview {
                            Text(String(localized: "Check the extracted details before saving. MealPlan will keep this recipe marked for review until it is complete."))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
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
                    onSelectLockedDate: { lockedDate in
                        saveNotice = String(localized: "\(lockedDate.formatted(.dateTime.month(.wide).day())) is locked. Unlock planning in MealPlan to use this date.")
                    },
                    selectHint: String(localized: "Plans it here")
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                Text(String(localized: "Tap a slot to choose the day and meal. The bottom row plans it as an extra on that day."))
                    .font(.footnote).foregroundStyle(.secondary)
            }

            actionSection
            siteActionSection
        }
    }

    private var handoffReadyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.up.forward.app.fill")
                .font(.system(size: 42))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(String(localized: "Handoff ready"))
                .font(.headline)
            Text(String(localized: "Open MealPlan to continue. The shared recipe or site preview is queued for the next time MealPlan opens."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(String(localized: "Done")) { onComplete() }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var actionSection: some View {
        Section {
            Button(String(localized: "Save recipe"), systemImage: "bookmark") {
                Task { await save(planRecipe: false) }
            }
            .disabled(isSaving || !canSaveRecipes)
            Button(String(localized: "Save & plan"), systemImage: "calendar.badge.plus") {
                Task { await save(planRecipe: true) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSaving || !canSaveRecipes || !PlanningAccess.canPlan(on: date, isUnlocked: PurchaseEntitlementCache.isUnlocked))
            Button(String(localized: "Continue in MealPlan"), systemImage: "arrow.up.forward.app") {
                queueHandoff()
            }
            if !canSaveRecipes {
                Label(
                    String(localized: "Add ingredients or preparation steps before saving this recipe. You can continue in MealPlan to finish the review."),
                    systemImage: "pencil.and.list.clipboard"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if let saveNotice {
                Label(saveNotice, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var siteActionSection: some View {
        if let siteCandidate {
            siteSubscriptionSection(siteCandidate)
        }
    }

    private func siteSubscriptionSection(_ siteCandidate: RecipeSiteCandidate) -> some View {
        Section {
                HStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Subscribe to site"))
                            .font(.subheadline)
                        Text(siteCandidate.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(String(localized: "Subscribe")) {
                        Task { await subscribeToSite(siteCandidate) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isSubscribing)
                }
                if isSubscribing {
                    ProgressView(String(localized: "Subscribing…"))
                        .font(.caption)
                }
                if let subscriptionNotice {
                    Text(subscriptionNotice)
                        .font(.caption)
                        .foregroundStyle(subscriptionSucceeded ? Color.secondary : Color.red)
                }
            } footer: {
                Text(String(localized: "Optional: future recipes from this site will appear in Discover."))
                    .font(.caption)
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
                Label(String(localized: "No recipe found"), systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Text(String(localized: "MealPlan could not find enough recipe details to show a saving and planning form. You can retry extraction or continue in MealPlan for a fuller review."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let saveNotice {
                    Text(saveNotice)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text(siteCandidate?.detail ?? sharedURL?.host() ?? "")
            }
            Section {
                Button(String(localized: "Try extracting recipe"), systemImage: "arrow.clockwise") {
                    Task { await importSharedURL(classification: classification) }
                }
                .disabled(isSubscribing)
                Button(String(localized: "Continue in MealPlan"), systemImage: "arrow.up.forward.app") {
                    queueHandoff()
                }
            }
            if let siteCandidate {
                siteSubscriptionSection(siteCandidate)
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
                .disabled(isSubscribing)
            }
            if siteCandidate != nil {
                Section(String(localized: "Recipe site")) {
                    Button(String(localized: "Subscribe to site"), systemImage: "dot.radiowaves.left.and.right") {
                        Task { await subscribeToSite(siteCandidate ?? .manual(for: sharedURL ?? URL(string: "https://example.com")!)) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubscribing)
                    if let saveNotice {
                        Label(saveNotice, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
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

    private var isTextPayload: Bool {
        if case .text = payload { return true }
        return false
    }

    private var canSaveRecipes: Bool {
        !recipes.isEmpty && recipes.allSatisfy { recipe in
            let hasName = !recipe.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasIngredients = recipe.ingredientLines.contains {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let hasInstructions = !(recipe.instructions ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            return hasName && (hasIngredients || hasInstructions)
        }
    }

    @MainActor
    private func load() async {
        let loadID = UUID()
        discoveryGeneration = loadID
        failureRecovery = .none
        saveNotice = nil
        subscriptionNotice = nil
        classification = nil
        siteCandidate = nil
        loadMeals()
        loadPlannedDays()
        switch payload {
        case .empty:
            failureRecovery = .none
            phase = .failed(String(localized: "Nothing to import here."))
        case .text(let text):
            recipes = [textRecipe(text)]
            phase = .ready
        case .url(let url):
            sharedURL = url
            phase = .extracting
            // Site discovery and recipe extraction used to run serially. A
            // slow feed endpoint could therefore add another full network
            // timeout before the recipe UI appeared. They are independent:
            // extraction drives the primary UI and discovery only supplies the
            // optional footer/fallback classification.
            let discoveryTask = Task.detached(priority: .utility) {
                await RecipeSiteDiscoveryService.classify(url)
            }
            await importSharedURL()
            // Do not make the optional discovery request part of the visible
            // extraction latency. It can finish after the recipe preview is
            // already usable and then add the compact subscription footer.
            Task { @MainActor in
                let kind = await discoveryTask.value
                guard discoveryGeneration == loadID else { return }
                applyClassification(kind)
            }
        case .paprika(let data):
            do {
                recipes = try PaprikaArchive.recipes(from: data)
                if recipes.isEmpty {
                    failureRecovery = .reload
                    phase = .failed(String(localized: "No recipes in that file."))
                } else {
                    phase = .ready
                }
            } catch {
                failureRecovery = .reload
                phase = .failed(error.localizedDescription)
            }
        case .mealPlan(let data):
            do {
                recipes = try MealPlanRecipeArchive.importedRecipes(from: data)
                if recipes.isEmpty {
                    failureRecovery = .reload
                    phase = .failed(String(localized: "No recipes in that file."))
                } else {
                    phase = .ready
                }
            } catch {
                failureRecovery = .reload
                phase = .failed(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func retryLoad() async {
        phase = .loading
        await load()
    }

    @MainActor
    private func applyClassification(_ kind: SharedRecipeURLKind) {
        classification = kind
        switch kind {
        case .recipe(let candidate):
            siteCandidate = candidate.subscriptionCandidate
        case .recipeSite(let candidate):
            siteCandidate = candidate
        case .feed(let feed):
            siteCandidate = RecipeSiteCandidate(title: feed.title, siteURL: feed.siteURL, feedURL: feed.feedURL)
        case .ambiguous(let url):
            sharedURL = url
            siteCandidate = .manual(for: url)
        case .unsupported(let url):
            sharedURL = url
        }

        // A feed must never leave behind a parser-generated title-only
        // placeholder that could be mistaken for a recipe. Never replace a
        // save result that has already been accepted while discovery finishes.
        guard phase != .saving, phase != .done else { return }
        if case .feed = kind {
            recipes = []
            phase = .siteReady
        } else if let recipe = recipes.first, ShareRecipeImportPolicy.accepts(recipe, classification: kind) {
            phase = .ready
        } else if !recipes.isEmpty {
            saveNotice = String(localized: "MealPlan found no complete recipe on this page. You can continue in MealPlan to review it, but nothing will be saved until it has ingredients or preparation steps.")
            phase = .siteReady
        } else {
            phase = .siteReady
        }
    }

    @MainActor
    private func importSharedURL(classification requestedClassification: SharedRecipeURLKind? = nil) async {
        guard let url = sharedURL else { return }
        saveNotice = nil
        phase = .extracting
        do {
            let recipe = try await RecipeSchemaParser(
                aiExtractor: ShareExtensionDeterministicAIExtractor(),
                loadImage: false
            ).importRecipe(from: url)
            recipes = [recipe]
            let kind = requestedClassification ?? classification
            if ShareRecipeImportPolicy.accepts(recipe, classification: kind) {
                phase = .ready
            } else {
                saveNotice = String(localized: "MealPlan found no complete recipe on this page. You can continue in MealPlan to review it, but nothing will be saved until it has ingredients or preparation steps.")
                phase = .siteReady
            }
        } catch {
            recipes = [fallbackURLRecipe(url)]
            saveNotice = String(localized: "MealPlan could not fully extract this page. Review the fields before saving, or continue in MealPlan to finish it.")
            phase = .siteReady
        }
    }

    @MainActor
    private func subscribeToSite(_ candidate: RecipeSiteCandidate) async {
        isSubscribing = true
        subscriptionNotice = nil
        subscriptionSucceeded = false
        defer { isSubscribing = false }
        do {
            let context = container.mainContext
            let household = try? context.fetch(FetchDescriptor<Household>()).first
            guard HouseholdMutationAuthorization.canMutate(household: household) else {
                subscriptionNotice = HouseholdSharingError.readOnlyHousehold.localizedDescription
                return
            }
            _ = try await RecipeFeedService.subscribe(to: candidate, household: household, context: context)
            HouseholdStoreGeneration.markDirty()
            subscriptionSucceeded = true
            subscriptionNotice = String(localized: "Subscribed to \(candidate.title)")
        } catch {
            subscriptionNotice = error.localizedDescription
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
        guard canSaveRecipes else {
            saveNotice = String(localized: "Add ingredients or preparation steps before saving this recipe.")
            return
        }
        isSaving = true
        saveNotice = nil
        phase = .saving
        await Task.yield()
        defer { isSaving = false }
        let context = container.mainContext
        let household = try? context.fetch(FetchDescriptor<Household>()).first
        guard HouseholdMutationAuthorization.canMutate(household: household) else {
            saveNotice = HouseholdSharingError.readOnlyHousehold.localizedDescription
            phase = .ready
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
            phase = .ready
            return
        }
        if let dish = result.dishesForPlanning.first { savedDishID = dish.uuid }
        var planned = false
        if planRecipe {
            guard PlanningAccess.canPlan(on: date, isUnlocked: PurchaseEntitlementCache.isUnlocked) else {
                saveNotice = String(localized: "Recipe saved to Dishes. This date is locked, so it wasn’t planned.")
                HouseholdStoreGeneration.markDirty()
                phase = .ready
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
                phase = .ready
                return
            }
        }
        saveMessage = planRecipe
            ? String(localized: "Recipe saved to Dishes and planned.")
            : (result.isEmpty ? String(localized: "Recipe already saved to Dishes.") : String(localized: "Recipe saved to Dishes."))
        HouseholdStoreGeneration.markDirty()
        phase = .handoffReady
    }

    @MainActor
    private func queueHandoff() {
        let destination: ShareHandoff.Destination
        if let savedDishID {
            destination = .dish(savedDishID)
        } else if let sharedURL {
            if siteCandidate != nil && !canSaveRecipes { destination = .site(sharedURL) }
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
