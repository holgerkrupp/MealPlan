import SwiftUI
import SwiftData
import UniformTypeIdentifiers

@MainActor
struct DishLibraryView: View {
    @Environment(AppState.self) private var appState
    @State private var pageCount = 1

    fileprivate static let pageSize = 120

    var body: some View {
        DishLibraryContent(
            householdID: appState.currentHousehold?.uuid,
            sort: appState.dishFilter.sort,
            pageCount: pageCount,
            loadMore: { pageIndex in
                guard pageIndex == pageCount - 1 else { return }
                pageCount += 1
            }
        )
        .id("\(appState.currentHousehold?.uuid.uuidString ?? "none")-\(appState.dishFilter.sort.rawValue)")
        .onChange(of: appState.dishFilter) {
            pageCount = 1
        }
    }
}

@MainActor
private struct DishLibraryContent: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Query private var allDishes: [Dish]

    private let householdID: UUID?
    private let sort: DishFilter.Sort
    private let pageCount: Int
    private let loadMore: @MainActor (Int) -> Void
    @State private var hasAnyFilteredResults = false
    @State private var hasMorePages = true

    /// The freshly created dish whose editor is open. Setting it is what
    /// opens the editor — in a window where the platform has them, else a sheet.
    @State private var newDish: Dish?
    @State private var exportedArchive: ExportedRecipeArchive?
    @State private var exportError: String?
    @State private var showingFilePicker = false
    @State private var showingRecipeScanner = false
    @State private var importingFile: ImportableRecipeFile?
    @State private var importError: String?
    @State private var requestedDish: Dish?
    /// Driven by the menu bar's Find command so ⌘F lands in the search field.
    @State private var isSearchPresented = false
    @State private var availableTags: [String] = []
    @State private var popularTags: [String] = []
    @State private var debouncedSearchText = ""

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 16)]

    init(
        householdID: UUID?,
        sort: DishFilter.Sort,
        pageCount: Int,
        loadMore: @escaping @MainActor (Int) -> Void
    ) {
        self.householdID = householdID
        self.sort = sort
        // A normal library view must never fall back to observing every
        // household's recipes. With no active household, this sentinel can
        // match no real dish.
        let scopedHouseholdID = householdID ?? UUID()
        var descriptor = FetchDescriptor<Dish>(
            predicate: #Predicate { $0.household?.uuid == scopedHouseholdID },
            sortBy: DishLibrarySort.descriptors(for: sort)
        )
        descriptor.fetchLimit = DishLibraryView.pageSize
        _allDishes = Query(descriptor)
        self.pageCount = pageCount
        self.loadMore = loadMore
    }

    private struct LibraryRevision: Equatable {
        var count: Int
        var latestModification: Date?
    }

    private var libraryRevision: LibraryRevision {
        LibraryRevision(
            count: allDishes.count,
            latestModification: allDishes.lazy.map(\.modifiedAt).max()
        )
    }

    private var visibleFilter: DishFilter {
        var filter = appState.dishFilter
        filter.searchText = debouncedSearchText
        return filter
    }

    /// What the grid actually draws. A variant group collapses into one cell
    /// so five takes on a burger don't push everything else off the screen;
    /// the group's own screen lists them.
    private func libraryItems(from filteredDishes: [Dish]) -> [LibraryItem] {
        guard filteredDishes.contains(where: { $0.variantGroupID != nil }) else {
            return filteredDishes.map(LibraryItem.dish)
        }

        let groups = DishVariants.groups(in: filteredDishes)
        var seenGroups: Set<UUID> = []
        var items: [LibraryItem] = []
        for dish in filteredDishes {
            guard let groupID = dish.variantGroupID, let members = groups[groupID] else {
                items.append(.dish(dish))
                continue
            }
            guard seenGroups.insert(groupID).inserted else { continue }
            items.append(.group(
                DishVariantGroupRef(id: groupID, name: dish.variantGroupDisplayName),
                lead: members[0],
                count: members.count
            ))
        }
        return items
    }

    /// One cell in the grid: a plain dish, or a group of variants standing in
    /// for its members.
    private enum LibraryItem: Identifiable {
        case dish(Dish)
        case group(DishVariantGroupRef, lead: Dish, count: Int)

        var id: String {
            switch self {
            case .dish(let dish): "dish-\(dish.uuid)"
            case .group(let ref, _, _): "group-\(ref.id)"
            }
        }
    }

    var body: some View {
        @Bindable var appState = appState
        let filteredDishes = visibleFilter.apply(
            to: allDishes,
            sourceIsAlphabeticallySorted: true
        )
        let items = libraryItems(from: filteredDishes)
        let canLoadMore = householdID != nil && allDishes.count == DishLibraryView.pageSize

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                #if os(iOS)
                FullPageScreenshotBridge()
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                #endif

                TagFilterStrip(
                    filter: $appState.dishFilter,
                    tags: popularTags,
                    horizontalPadding: MacLayout.gutter
                )
                .padding(.top, 8)

                SeasonalSuggestionsStrip(dishes: allDishes)

                if !appState.isGuest {
                    InlineTip(
                        tip: DishVariantsTip(),
                        padding: EdgeInsets(top: 8, leading: MacLayout.gutter, bottom: 0, trailing: MacLayout.gutter)
                    )
                }

                if !filteredDishes.isEmpty {
                    grid(items, acceptsDrops: !appState.isGuest)
                }

                if canLoadMore && pageCount == 1 {
                    pageProgress { loadMore(0) }
                }

                ForEach(1..<pageCount, id: \.self) { pageIndex in
                    DishLibraryResultPage(
                        householdID: householdID,
                        pageIndex: pageIndex,
                        filter: visibleFilter,
                        isLastPage: pageIndex == pageCount - 1,
                        acceptsDrops: !appState.isGuest,
                        hasAnyFilteredResults: $hasAnyFilteredResults,
                        hasMorePages: $hasMorePages,
                        loadMore: loadMore
                    )
                }

                if filteredDishes.isEmpty && !hasAnyFilteredResults && !hasMorePages {
                    emptyState
                        .frame(maxWidth: .infinity, minHeight: 320)
                }
            }
        }
        .onAppear { updatePageState(filteredDishes: filteredDishes) }
        .onChange(of: allDishes.count) { updatePageState(filteredDishes: filteredDishes) }
        .onChange(of: appState.dishFilter) {
            hasAnyFilteredResults = false
            hasMorePages = allDishes.count == DishLibraryView.pageSize
            updatePageState(filteredDishes: filteredDishes)
        }
        .task(id: allDishes.count) {
            MealPlanTips.updateLibrary(allDishes)
        }
        .task(id: appState.dishFilter.searchText) {
            let requestedText = appState.dishFilter.searchText
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            debouncedSearchText = requestedText
        }
        .onChange(of: debouncedSearchText) {
            hasAnyFilteredResults = false
            hasMorePages = householdID != nil && allDishes.count == DishLibraryView.pageSize
            updatePageState(filteredDishes: visibleFilter.apply(
                to: allDishes,
                sourceIsAlphabeticallySorted: true
            ))
        }
        .task(id: libraryRevision) {
            await refreshTags()
        }
        .navigationTitle(AppSection.dishes.title)
        .navigationDestination(for: Dish.self) { DishDetailView(dish: $0) }
        .navigationDestination(for: DishVariantGroupRef.self) { DishVariantGroupView(group: $0) }
        .searchable(
            text: $appState.dishFilter.searchText,
            isPresented: $isSearchPresented,
            prompt: String(localized: "Search dishes")
        )
        .focusedSceneValue(\.dishLibraryCommands, libraryCommands)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                DiscoverRecipesButton()
            }
            if !appState.isGuest {
                ToolbarItem(placement: .primaryAction) {
                    Button(String(localized: "New dish"), systemImage: "plus") {
                        addDish()
                    }
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                DishFilterMenu(
                    filter: $appState.dishFilter,
                    availableTags: availableTags
                )

                Menu {
                    if !appState.isGuest {
                        Button(String(localized: "Scan a recipe"), systemImage: "camera.viewfinder") {
                            showingRecipeScanner = true
                        }
                        Button(String(localized: "Import recipes"), systemImage: "square.and.arrow.down") {
                            showingFilePicker = true
                        }
                    }
                    Button(String(localized: "Export all recipes"), systemImage: "square.and.arrow.up") {
                        exportAllRecipes()
                    }
                    .disabled(allDishes.isEmpty)
                } label: {
                    Label(String(localized: "More"), systemImage: "ellipsis")
                }
            }
        }
        .detailPresentation(item: $newDish, route: { .newRecipe($0.uuid) }) { dish in
            NavigationStack {
                DishEditorView(dish: dish, isNew: true)
            }
            .dismissesOnOutsideClick()
        }
        .detailPresentation(item: $requestedDish, route: { .recipe($0.uuid) }) { dish in
            NavigationStack { DishDetailView(dish: dish) }
        }
        .sheet(item: $exportedArchive) { RecipeArchiveShareSheet(archive: $0).dismissesOnOutsideClick() }
        .detailPresentation(item: $importingFile, route: { .importRecipes($0.url) }) {
            ImportRecipesSheet(fileURL: $0.url).dismissesOnOutsideClick()
        }
        .sheet(isPresented: $showingRecipeScanner) {
            ScanRecipeSheet { dish in
                newDish = dish
            }
            .dismissesOnOutsideClick()
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: RecipeFileType.importableContentTypes
        ) { result in
            switch result {
            case .success(let url): importingFile = ImportableRecipeFile(url: url)
            case .failure(let error): importError = error.localizedDescription
            }
        }
        .alert(
            String(localized: "Couldn’t import recipes"),
            isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .alert(
            String(localized: "Couldn’t export recipes"),
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .task(id: appState.pendingAddDish?.id) {
            guard let request = appState.pendingAddDish else { return }
            appState.pendingAddDish = nil
            await handleAddRequest(request)
        }
        .task(id: appState.requestedDishID) {
            guard let id = appState.requestedDishID else { return }
            appState.requestedDishID = nil
            guard let householdID else { return }
            requestedDish = try? context.fetch(FetchDescriptor<Dish>(
                predicate: #Predicate { $0.uuid == id && $0.household?.uuid == householdID }
            )).first
        }
    }

    private func refreshTags() async {
        // Let the tab and its first page become interactive before deriving
        // secondary navigation from the complete library. The full scan uses
        // its own SwiftData executor so it cannot stall scrolling or the tab
        // transition on the main actor.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let metadata = await DishLibraryMetadataActor(
            modelContainer: context.container
        ).tagMetadata(householdID: householdID)
        guard !Task.isCancelled else { return }
        availableTags = metadata.available
        popularTags = metadata.popular
    }

    private func updatePageState(filteredDishes: [Dish]) {
        hasMorePages = householdID != nil && allDishes.count == DishLibraryView.pageSize
        if !filteredDishes.isEmpty { hasAnyFilteredResults = true }
    }

    private func grid(_ items: [LibraryItem], acceptsDrops: Bool) -> some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(items) { item in
                switch item {
                case .dish(let dish):
                    DishLibraryCell(dish: dish, acceptsDrops: acceptsDrops, householdID: householdID)
                        .equatable()
                case .group(let ref, let lead, let count):
                    DishLibraryCell(
                        dish: lead,
                        group: ref,
                        variantCount: count,
                        acceptsDrops: acceptsDrops,
                        householdID: householdID
                    )
                    .equatable()
                }
            }
        }
        .padding(MacLayout.gutter)
    }

    private func pageProgress(action: @escaping () -> Void) -> some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding()
            .onAppear(perform: action)
    }

    private func handleAddRequest(_ request: AppState.PendingAddDish) async {
        if let url = request.url {
            let recipe = (try? await RecipeSchemaParser().importRecipe(from: url))
                ?? ImportedRecipe(name: request.name ?? url.host() ?? String(localized: "New dish"), sourceURL: url)
            let dish = DishBuilder.makeDish(
                from: recipe, household: appState.currentHousehold,
                createdByName: appState.currentMemberName, context: context
            )
            newDish = dish
        } else {
            let dish = Dish(name: request.name ?? "")
            dish.household = appState.currentHousehold
            dish.createdByName = appState.currentMemberName
            dish.refreshAutoGlyph()
            context.insert(dish)
            newDish = dish
        }
    }

    /// An empty library and an empty result look nothing alike: one wants a
    /// first recipe, the other wants the filter turned off again.
    @ViewBuilder
    private var emptyState: some View {
        if allDishes.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "No dishes yet"), systemImage: "fork.knife")
            } description: {
                Text("Add the meals your family likes. A name is enough to start — you can add a recipe and a photo later.")
            } actions: {
                Button(String(localized: "New dish")) { addDish() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            let hasFilters = appState.dishFilter.isActive
            ContentUnavailableView {
                Label(String(localized: "No dishes match"), systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(noMatchDescription)
            } actions: {
                Button(hasFilters
                       ? String(localized: "Clear filters")
                       : String(localized: "Clear search")) {
                    appState.dishFilter = DishFilter(sort: appState.dishFilter.sort)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    /// Built with `String(localized:)` rather than two `Text` literals in a
    /// branch: those don’t make it into the string catalog.
    private var noMatchDescription: String {
        appState.dishFilter.isActive
            ? String(localized: "Nothing in your library fits the tags and filters you picked.")
            : String(localized: "Nothing in your library matches that search.")
    }

    /// What the menu bar can do to the library right now. Guests get no
    /// import, an empty library has nothing to export, and "Clear filters" is
    /// offered only when the grid is actually showing less than everything.
    private var libraryCommands: DishLibraryCommands {
        let narrowed = appState.dishFilter.isActive
            || !appState.dishFilter.searchText.trimmingCharacters(in: .whitespaces).isEmpty
        var commands = DishLibraryCommands(
            sort: appState.dishFilter.sort,
            search: { isSearchPresented = true },
            setSort: { appState.dishFilter.sort = $0 }
        )
        if !appState.isGuest {
            commands.importRecipes = { showingFilePicker = true }
        }
        if !allDishes.isEmpty {
            commands.exportAll = { exportAllRecipes() }
        }
        if narrowed {
            commands.clearFilters = { appState.dishFilter = DishFilter(sort: appState.dishFilter.sort) }
        }
        return commands
    }

    private func exportAllRecipes() {
        do {
            // The normal library query is deliberately paged. Export is an
            // explicit whole-library operation, so fetch everything only when
            // the cook actually requests it.
            guard let householdID else { return }
            let dishes = try context.fetch(FetchDescriptor<Dish>(
                predicate: #Predicate { $0.household?.uuid == householdID },
                sortBy: [SortDescriptor(\Dish.name)]
            ))
            exportedArchive = ExportedRecipeArchive(
                url: try MealPlanRecipeArchive.temporaryFile(for: dishes)
            )
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func addDish() {
        let dish = Dish(name: "")
        dish.household = appState.currentHousehold
        dish.createdByName = appState.currentMemberName
        dish.refreshAutoGlyph()
        context.insert(dish)
        newDish = dish
    }
}

private struct DishLibraryTagMetadata: Sendable {
    var available: [String]
    var popular: [String]

    static let empty = DishLibraryTagMetadata(available: [], popular: [])
}

/// Each scrolling window owns a fixed-size query. Reaching its footer mounts
/// the next window, so loading page 20 does not keep 2,400 SwiftData models in
/// the library view's active query or rerun filtering over all earlier pages.
@MainActor
private struct DishLibraryResultPage: View {
    @Query private var dishes: [Dish]

    private let householdID: UUID?
    private let pageIndex: Int
    private let filter: DishFilter
    private let isLastPage: Bool
    private let acceptsDrops: Bool
    @Binding private var hasAnyFilteredResults: Bool
    @Binding private var hasMorePages: Bool
    private let loadMore: @MainActor (Int) -> Void
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 16)]

    private enum Item: Identifiable {
        case dish(Dish)
        case group(DishVariantGroupRef, lead: Dish, count: Int)

        var id: String {
            switch self {
            case .dish(let dish): "dish-\(dish.uuid)"
            case .group(let group, _, _): "group-\(group.id)"
            }
        }
    }

    init(
        householdID: UUID?,
        pageIndex: Int,
        filter: DishFilter,
        isLastPage: Bool,
        acceptsDrops: Bool,
        hasAnyFilteredResults: Binding<Bool>,
        hasMorePages: Binding<Bool>,
        loadMore: @escaping @MainActor (Int) -> Void
    ) {
        self.householdID = householdID
        self.pageIndex = pageIndex
        self.filter = filter
        self.isLastPage = isLastPage
        self.acceptsDrops = acceptsDrops
        self._hasAnyFilteredResults = hasAnyFilteredResults
        self._hasMorePages = hasMorePages
        self.loadMore = loadMore

        let scopedHouseholdID = householdID ?? UUID()
        var descriptor = FetchDescriptor<Dish>(
            predicate: #Predicate { $0.household?.uuid == scopedHouseholdID },
            sortBy: DishLibrarySort.descriptors(for: filter.sort)
        )
        descriptor.fetchLimit = DishLibraryView.pageSize
        descriptor.fetchOffset = pageIndex * DishLibraryView.pageSize
        _dishes = Query(descriptor)
    }

    var body: some View {
        let filtered = filter.apply(
            to: dishes,
            now: .now,
            sourceIsAlphabeticallySorted: filter.sort == .alphabetical
        )
        let items = libraryItems(from: filtered)

        Group {
            if !items.isEmpty {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(items) { item in
                        switch item {
                        case .dish(let dish):
                            DishLibraryCell(
                                dish: dish,
                                acceptsDrops: acceptsDrops,
                                householdID: householdID
                            )
                            .equatable()
                        case .group(let ref, let lead, let count):
                            DishLibraryCell(
                                dish: lead,
                                group: ref,
                                variantCount: count,
                                acceptsDrops: acceptsDrops,
                                householdID: householdID
                            )
                            .equatable()
                        }
                    }
                }
                .padding(MacLayout.gutter)
            }

            if isLastPage && dishes.count == DishLibraryView.pageSize {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
                    .onAppear { loadMore(pageIndex) }
            }
        }
        .onAppear { updateState(filtered: filtered) }
        .onChange(of: dishes.count) { updateState(filtered: filtered) }
    }

    private func updateState(filtered: [Dish]) {
        if isLastPage {
            hasMorePages = householdID != nil && dishes.count == DishLibraryView.pageSize
        }
        if !filtered.isEmpty { hasAnyFilteredResults = true }
    }

    private func libraryItems(from filtered: [Dish]) -> [Item] {
        let groups = DishVariants.groups(in: filtered)
        var seenGroups: Set<UUID> = []
        var items: [Item] = []
        for dish in filtered {
            guard let groupID = dish.variantGroupID, let members = groups[groupID] else {
                items.append(.dish(dish))
                continue
            }
            guard seenGroups.insert(groupID).inserted else { continue }
            items.append(.group(
                DishVariantGroupRef(id: groupID, name: dish.variantGroupDisplayName),
                lead: members[0],
                count: members.count
            ))
        }
        return items
    }

}

private enum DishLibrarySort {
    static func descriptors(for sort: DishFilter.Sort) -> [SortDescriptor<Dish>] {
        switch sort {
        case .alphabetical, .neverCooked:
            [SortDescriptor(\Dish.name), SortDescriptor(\Dish.uuid)]
        case .recentlyAdded:
            [SortDescriptor(\Dish.dateCreated, order: .reverse), SortDescriptor(\Dish.uuid)]
        case .mostCooked:
            [SortDescriptor(\Dish.usageCount, order: .reverse), SortDescriptor(\Dish.uuid)]
        case .leastRecentlyCooked:
            [SortDescriptor(\Dish.lastUsedDate), SortDescriptor(\Dish.uuid)]
        }
    }
}

@ModelActor
private actor DishLibraryMetadataActor {
    func tagMetadata(householdID: UUID?) -> DishLibraryTagMetadata {
        guard !Task.isCancelled, let householdID,
              let dishes = try? modelContext.fetch(FetchDescriptor<Dish>(
                predicate: #Predicate { $0.household?.uuid == householdID }
              ))
        else { return .empty }

        let usage = DishTag.usage(fromTagLists: dishes.map(\.tagNames))
        guard !Task.isCancelled else { return .empty }
        return DishLibraryTagMetadata(
            available: DishTag.sorted(usage.map(\.tag)),
            popular: Array(usage.prefix(12).map(\.tag))
        )
    }
}

/// Wraps the picked file so `.sheet(item:)` can drive the review sheet.
struct ImportableRecipeFile: Identifiable {
    let id = UUID()
    let url: URL
}

#Preview {
    NavigationStack { DishLibraryView() }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}

/// Opens the reading list of subscribed sites. It is a place of its own, not a
/// step inside the library, so on the Mac and on a multi-window iPad it gets a
/// window; elsewhere it pushes onto the library's stack.
@MainActor
struct DiscoverRecipesButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if DetailWindowSupport.prefersWindowsOverSheets {
            Button(String(localized: "Discover recipes"), systemImage: "newspaper") {
                openWindow(value: DetailWindowRoute.discoverRecipes)
            }
        } else {
            NavigationLink {
                RecipeDiscoveryView()
            } label: {
                Label(String(localized: "Discover recipes"), systemImage: "newspaper")
            }
        }
    }
}
