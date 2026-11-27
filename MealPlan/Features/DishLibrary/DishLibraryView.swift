import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import os

enum DishLibraryPerformanceSignposts {
    static let signposter = OSSignposter(
        subsystem: "de.holgerkrupp.mealplan",
        category: "dish library"
    )
}

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
        .id("\(appState.currentHousehold?.uuid.uuidString ?? "none")-\(appState.dishFilter.sort.rawValue)-\(!appState.dishFilter.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)")
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
    @State private var confirmingAddRequest: AppState.PendingAddDish?
    @State private var addRequestError: String?
    @State private var showingFilePicker = false
    @State private var showingRecipeScanner = false
    @State private var showingPasteRecipe = false
    @State private var importingFile: ImportableRecipeFile?
    @State private var importError: String?
    @State private var requestedDish: Dish?
    @State private var handoffSitePreview: SharedSitePreview?
    /// Driven by the menu bar's Find command so ⌘F lands in the search field.
    @State private var isSearchPresented = false
    @State private var availableTags: [String] = []
    @State private var popularTags: [String] = []
    @State private var availableCollections: [DishCollectionSummary] = []
    /// Bumped after a label edit that may touch dishes outside the first
    /// page, so the tag and collection lists are derived again.
    @State private var metadataToken = 0
    @State private var debouncedSearchText = ""
    @State private var searchSnapshotActor: DishSearchSnapshotActor?
    @State private var searchScores: [UUID: Double] = [:]
    @State private var searchResultIDs: [UUID] = []
    @State private var rankedSearchRequest: DishLibraryQueryRequest?
    @State private var searchGeneration = 0

    // Multi-select for bulk tagging and collections.
    @State private var isSelecting = false
    @State private var selection: [UUID: Dish] = [:]
    /// A collection named in the collection browser (or the one being
    /// browsed) that is waiting for the dishes picked now.
    @State private var pendingCollection: String?
    @State private var showingCollections = false
    @State private var lastLabelEdit: LabelEditUndo?
    @State private var labelEditError: String?
    @State private var namingLabel: NewLabelKind?
    @State private var newLabelName = ""
    @State private var renamingActiveCollection = false
    @State private var deletingActiveCollection = false

    private enum NewLabelKind { case tag, collection }

    /// The most recent bulk change, kept just long enough to offer Undo.
    private struct LabelEditUndo: Identifiable {
        let id = UUID()
        var snapshot: DishLabelEdit.Snapshot
        var dishes: [Dish]
        var message: String
    }

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
        // This is always a bounded first page. Non-store filters and sorts
        // are evaluated from shared background value snapshots below.
        descriptor.fetchLimit = DishLibraryView.pageSize
        _allDishes = Query(descriptor)
        self.pageCount = pageCount
        self.loadMore = loadMore
    }

    private var libraryRevision: DishLibraryMetadataRevision {
        DishLibraryMetadataRevision(count: 0, latestModification: nil, token: metadataToken)
    }

    /// Handed to the later pages while dishes are being picked.
    private var pageSelection: Binding<[UUID: Dish]>? {
        isSelecting ? $selection : nil
    }

    /// True while the first page came back full, i.e. there may be more.
    private var firstPageIsFull: Bool {
        householdID != nil && !usesBackgroundQuery && allDishes.count == DishLibraryView.pageSize
    }

    private var visibleFilter: DishFilter {
        var filter = appState.dishFilter
        filter.searchText = debouncedSearchText
        return filter
    }

    private var usesBackgroundQuery: Bool {
        !visibleFilter.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || visibleFilter.isActive || visibleFilter.sort == .neverCooked || !visibleFilter.sort.isStoreOrderable
    }

    private var libraryQueryRequest: DishLibraryQueryRequest? {
        guard usesBackgroundQuery, let householdID else { return nil }
        return DishLibraryQueryRequest(
            householdID: householdID,
            filter: visibleFilter,
            generation: searchGeneration
        )
    }

    private var searchScoresForFilter: [UUID: Double]? {
        guard !visibleFilter.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return rankedSearchRequest == libraryQueryRequest ? searchScores : [:]
    }

    /// What the grid actually draws. A variant group collapses into one cell
    /// so five takes on a burger don't push everything else off the screen;
    /// the group's own screen lists them.
    private func libraryItems(
        from filteredDishes: [Dish],
        crossPageGroups: [UUID: DishLibraryVariantGroup]? = nil
    ) -> [LibraryItem] {
        if let crossPageGroups {
            var items: [LibraryItem] = []
            for dish in filteredDishes {
                guard let groupID = dish.variantGroupID,
                      let group = crossPageGroups[groupID],
                      group.members.count > 1 else {
                    items.append(.dish(dish))
                    continue
                }
                // Only the page containing the first matching member owns the
                // group card. Later pages suppress the other member rows.
                guard group.firstMatchingUUID == dish.uuid else { continue }
                items.append(.group(
                    DishVariantGroupRef(id: groupID, name: dish.variantGroupDisplayName, householdID: householdID),
                    members: group.members
                ))
            }
            return items
        }
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
                DishVariantGroupRef(id: groupID, name: dish.variantGroupDisplayName, householdID: householdID),
                members: members
            ))
        }
        return items
    }

    /// One cell in the grid: a plain dish, or a group of variants standing in
    /// for its members.
    private enum LibraryItem: Identifiable {
        case dish(Dish)
        case group(DishVariantGroupRef, members: [Dish])

        var id: String {
            switch self {
            case .dish(let dish): "dish-\(dish.uuid)"
            case .group(let ref, _): "group-\(ref.id)"
            }
        }
    }

    var body: some View {
        labelEditingPresentations(library)
    }

    @ViewBuilder
    private var library: some View {
        @Bindable var appState = appState
        let projection = DishLibraryPerformanceSignposts.signposter.beginInterval("library filter and grouping")
        let now = Date.now
        let filteredDishes = visibleFilter.apply(
            to: allDishes,
            now: now,
            sourceIsAlphabeticallySorted: true,
            searchScores: searchScoresForFilter
        )
        let crossPageGroups = firstPageIsFull
            ? DishLibraryVariantGrouping.load(
                filteredDishes: filteredDishes,
                householdID: householdID,
                filter: visibleFilter,
                searchScores: searchScoresForFilter,
                context: context,
                now: now
            )
            : nil
        let items = libraryItems(from: filteredDishes, crossPageGroups: crossPageGroups)
        let _ = DishLibraryPerformanceSignposts.signposter.endInterval("library filter and grouping", projection)
        let canLoadMore = firstPageIsFull

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

                activeCollectionHeader

                if !isSelecting {
                    SeasonalSuggestionsStrip(
                        householdID: householdID,
                        dataRevision: metadataToken
                    )
                }

                if !appState.isGuest {
                    InlineTip(
                        tip: DishVariantsTip(),
                        padding: EdgeInsets(top: 8, leading: MacLayout.gutter, bottom: 0, trailing: MacLayout.gutter)
                    )
                }

                if libraryQueryRequest != nil {
                    if rankedSearchRequest != libraryQueryRequest {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 160)
                    } else if searchResultIDs.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        let totalPages = (searchResultIDs.count + DishLibraryView.pageSize - 1) / DishLibraryView.pageSize
                        let loadedPages = min(pageCount, totalPages)
                        ForEach(0..<loadedPages, id: \.self) { pageIndex in
                            DishLibraryResultPage(
                                householdID: householdID,
                                pageIndex: pageIndex,
                                filter: visibleFilter,
                                isLastPage: pageIndex == loadedPages - 1,
                                acceptsDrops: !appState.isGuest,
                                selection: pageSelection,
                                searchScores: searchScoresForFilter,
                                orderedSearchIDs: searchResultIDs,
                                hasAnyFilteredResults: $hasAnyFilteredResults,
                                hasMorePages: $hasMorePages,
                                loadMore: loadMore
                            )
                        }
                        if !hasAnyFilteredResults && !hasMorePages {
                            emptyState
                                .frame(maxWidth: .infinity, minHeight: 320)
                        }
                    }
                } else {
                    if !filteredDishes.isEmpty {
                        grid(items, acceptsDrops: !appState.isGuest)
                    }

                    if canLoadMore && pageCount == 1 {
                        if filteredDishes.isEmpty {
                            loadMoreButton { loadMore(0) }
                        } else {
                            pageProgress { loadMore(0) }
                        }
                    }

                    ForEach(1..<pageCount, id: \.self) { pageIndex in
                        DishLibraryResultPage(
                            householdID: householdID,
                            pageIndex: pageIndex,
                            filter: visibleFilter,
                            isLastPage: pageIndex == pageCount - 1,
                            acceptsDrops: !appState.isGuest,
                            selection: pageSelection,
                            searchScores: searchScoresForFilter,
                            orderedSearchIDs: nil,
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
        }
        .onAppear { updatePageState(filteredDishes: filteredDishes) }
        .onChange(of: allDishes.count) { updatePageState(filteredDishes: filteredDishes) }
        .onChange(of: appState.dishFilter) {
            hasAnyFilteredResults = false
            hasMorePages = firstPageIsFull
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
            hasMorePages = firstPageIsFull
            updatePageState(filteredDishes: visibleFilter.apply(
                to: allDishes,
                sourceIsAlphabeticallySorted: true,
                searchScores: searchScoresForFilter
            ))
        }
        .onChange(of: searchScores) {
            updatePageState(filteredDishes: visibleFilter.apply(
                to: allDishes,
                sourceIsAlphabeticallySorted: true,
                searchScores: searchScoresForFilter
            ))
        }
        .onChange(of: rankedSearchRequest) {
            updatePageState(filteredDishes: visibleFilter.apply(
                to: allDishes,
                sourceIsAlphabeticallySorted: true,
                searchScores: searchScoresForFilter
            ))
        }
        .task(id: libraryRevision) {
            await refreshTags()
        }
        .task(id: libraryQueryRequest) {
            await refreshBackgroundQuery()
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave, object: context)) { _ in
            searchGeneration &+= 1
            metadataToken &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .mealPlanDataDidChange)) { _ in
            searchGeneration &+= 1
            metadataToken &+= 1
        }
        .navigationTitle(AppSection.dishes.title)
        .navigationDestination(for: Dish.self) { DishDetailView(dish: $0) }
        .navigationDestination(for: DishLibraryRecipeRoute.self) { route in
            DishLibraryRecipeDestination(route: route)
        }
        .navigationDestination(for: DishVariantGroupRef.self) { DishVariantGroupView(group: $0) }
        .searchable(
            text: $appState.dishFilter.searchText,
            isPresented: $isSearchPresented,
            prompt: String(localized: "Search dishes")
        )
        .focusedSceneValue(\.dishLibraryCommands, libraryCommands)
        .toolbar { libraryToolbar }
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
        .sheet(item: $handoffSitePreview) { preview in
            NavigationStack { SharedSitePreviewView(url: preview.url) }
                .presentationDetents([.medium, .large])
        }
        .detailPresentation(item: $importingFile, route: { .importRecipes($0.url) }) {
            ImportRecipesSheet(fileURL: $0.url).dismissesOnOutsideClick()
        }
        .sheet(isPresented: $showingRecipeScanner) {
            ScanRecipeSheet { dish in
                newDish = dish
            }
            .dismissesOnOutsideClick()
        }
        .sheet(isPresented: $showingPasteRecipe) {
            PasteRecipeSheet { dish in
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
            // These arrive as links any app or web page can open, so nothing is
            // fetched or added until the person here says so.
            guard HouseholdMutationAuthorization.canMutate(household: appState.currentHousehold) else {
                addRequestError = HouseholdSharingError.readOnlyHousehold.localizedDescription
                return
            }
            confirmingAddRequest = request
        }
        .confirmationDialog(
            String(localized: "Add this recipe?"),
            isPresented: Binding(get: { confirmingAddRequest != nil }, set: { if !$0 { confirmingAddRequest = nil } }),
            titleVisibility: .visible,
            presenting: confirmingAddRequest
        ) { request in
            Button(String(localized: "Add")) {
                Task { await handleAddRequest(request) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { request in
            Text(request.url?.host() ?? request.name ?? "")
        }
        .alert(
            String(localized: "Couldn’t add the recipe"),
            isPresented: Binding(get: { addRequestError != nil }, set: { if !$0 { addRequestError = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(addRequestError ?? "")
        }
        .task(id: appState.requestedDishID) {
            guard let id = appState.requestedDishID else { return }
            appState.requestedDishID = nil
            guard let householdID else { return }
            requestedDish = try? context.fetch(FetchDescriptor<Dish>(
                predicate: #Predicate { $0.uuid == id && $0.household?.uuid == householdID }
            )).first
        }
        .task(id: appState.pendingSharedSiteURL) {
            guard let url = appState.pendingSharedSiteURL else { return }
            handoffSitePreview = SharedSitePreview(url: url)
            appState.pendingSharedSiteURL = nil
        }
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            DiscoverRecipesButton()
        }
        if isSelecting {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Done")) { endSelecting() }
            }
        } else if !appState.isGuest {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "New dish"), systemImage: "plus") {
                    addDish()
                }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button(String(localized: "Collections"), systemImage: "books.vertical") {
                showingCollections = true
            }

            DishFilterMenu(
                filter: Bindable(appState).dishFilter,
                availableTags: availableTags,
                availableCollections: availableCollections.map(\.name)
            )

            Menu {
                if !appState.isGuest && !isSelecting {
                    Button(String(localized: "Select dishes"), systemImage: "checkmark.circle") {
                        startSelecting()
                    }
                }
                if !appState.isGuest {
                    Button(String(localized: "Scan a recipe"), systemImage: "camera.viewfinder") {
                        showingRecipeScanner = true
                    }
                    Button(String(localized: "Paste a recipe"), systemImage: "doc.on.clipboard") {
                        showingPasteRecipe = true
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

    /// The Undo banner after a bulk change, and the bar of bulk actions while
    /// selecting.
    private var bottomAccessory: some View {
        VStack(spacing: 0) {
            if let lastLabelEdit {
                undoBanner(lastLabelEdit)
            }
            if isSelecting {
                selectionBar
            }
        }
    }

    /// The collection browser and the prompts behind bulk tagging. Kept out
    /// of `library` so the type checker gets the modifier chain in two parts.
    private func labelEditingPresentations(_ content: some View) -> some View {
        content
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomAccessory }
        .task(id: lastLabelEdit?.id) {
            guard lastLabelEdit != nil else { return }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            withAnimation { lastLabelEdit = nil }
        }
        .sheet(isPresented: $showingCollections) {
            NavigationStack {
                DishCollectionsView(
                    collections: availableCollections,
                    selected: appState.dishFilter.collection,
                    canEdit: !appState.isGuest,
                    onSelect: { appState.dishFilter.collection = $0 },
                    onCreate: { name in startSelecting(for: name) },
                    onRename: { renameCollection($0, to: $1) },
                    onDelete: { deleteCollection($0) }
                )
            }
            .dismissesOnOutsideClick()
        }
        .alert(
            namingLabel == .collection ? String(localized: "New collection") : String(localized: "New tag"),
            isPresented: Binding(get: { namingLabel != nil }, set: { if !$0 { namingLabel = nil } })
        ) {
            TextField(String(localized: "Name"), text: $newLabelName)
            Button(String(localized: "Add")) {
                let name = DishTag.clean(newLabelName)
                if !name.isEmpty {
                    applyLabelEdit(namingLabel == .collection ? .addToCollection(name) : .addTag(name))
                }
                namingLabel = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
        .alert(String(localized: "Rename collection"), isPresented: $renamingActiveCollection) {
            TextField(String(localized: "Name"), text: $newLabelName)
            Button(String(localized: "Rename")) {
                if let current = appState.dishFilter.collection {
                    renameCollection(current, to: newLabelName)
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            String(localized: "Delete this collection?"),
            isPresented: $deletingActiveCollection,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete collection"), role: .destructive) {
                if let current = appState.dishFilter.collection {
                    deleteCollection(current)
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("The dishes stay in your library; only the collection is removed.")
        }
        .alert(
            String(localized: "Couldn’t save the change"),
            isPresented: Binding(get: { labelEditError != nil }, set: { if !$0 { labelEditError = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(labelEditError ?? "")
        }
    }

    // MARK: - Collections and bulk labels

    /// Shown while one collection is being browsed: its name, and what can be
    /// done to it as a whole.
    @ViewBuilder
    private var activeCollectionHeader: some View {
        if let collection = appState.dishFilter.collection, !isSelecting {
            HStack(spacing: 12) {
                Label {
                    Text(verbatim: collection)
                } icon: {
                    Image(systemName: "books.vertical")
                }
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                Spacer(minLength: 0)
                if !appState.isGuest {
                    Menu {
                        Button(String(localized: "Add dishes…"), systemImage: "plus") {
                            startSelecting(for: collection)
                        }
                        Button(String(localized: "Rename…"), systemImage: "pencil") {
                            newLabelName = collection
                            renamingActiveCollection = true
                        }
                        Button(String(localized: "Delete collection…"), systemImage: "trash", role: .destructive) {
                            deletingActiveCollection = true
                        }
                    } label: {
                        Label(String(localized: "Collection options"), systemImage: "ellipsis.circle")
                            .labelStyle(.iconOnly)
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                Button {
                    appState.dishFilter.collection = nil
                } label: {
                    Label(String(localized: "Show all dishes"), systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, MacLayout.gutter)
            .padding(.top, 12)
        }
    }

    /// The tags and collections the selected dishes carry, for "Remove…".
    private var selectedTags: [String] {
        DishTag.merge(selection.values.flatMap(\.tagNames))
    }

    private var selectedCollections: [String] {
        DishTag.merge(selection.values.flatMap(\.collectionNames))
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let pendingCollection {
                    Text(String(localized: "Pick dishes for “\(pendingCollection)”"))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                Text(String(localized: "\(selection.count) selected"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)

            if let pendingCollection {
                Button(String(localized: "Add")) {
                    applyLabelEdit(.addToCollection(pendingCollection))
                    let shown = pendingCollection
                    endSelecting()
                    appState.dishFilter.collection = shown
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty)
            } else {
                Menu {
                    Section(String(localized: "Add to collection")) {
                        ForEach(availableCollections) { collection in
                            Button {
                                applyLabelEdit(.addToCollection(collection.name))
                            } label: {
                                Text(verbatim: collection.name)
                            }
                        }
                        Button(String(localized: "New collection…"), systemImage: "plus") {
                            newLabelName = ""
                            namingLabel = .collection
                        }
                    }
                    if !selectedCollections.isEmpty {
                        Section(String(localized: "Remove from collection")) {
                            ForEach(selectedCollections, id: \.self) { name in
                                Button(role: .destructive) {
                                    applyLabelEdit(.removeFromCollection(name))
                                } label: {
                                    Text(verbatim: name)
                                }
                            }
                        }
                    }
                } label: {
                    Label(String(localized: "Collection"), systemImage: "books.vertical")
                }
                .disabled(selection.isEmpty)

                Menu {
                    Section(String(localized: "Add tag")) {
                        ForEach(availableTags, id: \.self) { tag in
                            Button {
                                applyLabelEdit(.addTag(tag))
                            } label: {
                                Text(verbatim: tag)
                            }
                        }
                        Button(String(localized: "New tag…"), systemImage: "plus") {
                            newLabelName = ""
                            namingLabel = .tag
                        }
                    }
                    if !selectedTags.isEmpty {
                        Section(String(localized: "Remove tag")) {
                            ForEach(selectedTags, id: \.self) { tag in
                                Button(role: .destructive) {
                                    applyLabelEdit(.removeTag(tag))
                                } label: {
                                    Text(verbatim: tag)
                                }
                            }
                        }
                    }
                } label: {
                    Label(String(localized: "Tags"), systemImage: "tag")
                }
                .disabled(selection.isEmpty)
            }
        }
        .padding(.horizontal, MacLayout.gutter)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func undoBanner(_ edit: LabelEditUndo) -> some View {
        HStack(spacing: 12) {
            Text(edit.message)
                .font(.subheadline)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(String(localized: "Undo")) { undo(edit) }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, MacLayout.gutter)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Enters multi-select. With a collection name, the selection is for
    /// that collection only, and the whole library is shown to pick from.
    private func startSelecting(for collection: String? = nil) {
        selection = [:]
        pendingCollection = collection
        if collection != nil { appState.dishFilter.collection = nil }
        isSelecting = true
    }

    private func endSelecting() {
        isSelecting = false
        selection = [:]
        pendingCollection = nil
    }

    private func applyLabelEdit(_ edit: DishLabelEdit) {
        let dishes = Array(selection.values)
        guard !dishes.isEmpty else { return }
        let snapshot = edit.apply(to: dishes)
        guard !snapshot.labels.isEmpty else { return }
        guard saveLabelChanges() else { return }
        let count = snapshot.labels.count
        let message = switch edit {
        case .addTag(let tag): String(localized: "Tagged \(count) dishes “\(tag)”")
        case .removeTag(let tag): String(localized: "Removed “\(tag)” from \(count) dishes")
        case .addToCollection(let name): String(localized: "Added \(count) dishes to “\(name)”")
        case .removeFromCollection(let name): String(localized: "Removed \(count) dishes from “\(name)”")
        }
        withAnimation {
            lastLabelEdit = LabelEditUndo(snapshot: snapshot, dishes: dishes, message: message)
        }
    }

    private func undo(_ edit: LabelEditUndo) {
        DishLabelEdit.restore(edit.snapshot, on: edit.dishes.filter { !$0.isDeleted })
        _ = saveLabelChanges()
        withAnimation { lastLabelEdit = nil }
    }

    private func renameCollection(_ name: String, to newName: String) {
        let changed = DishCollection.rename(name, to: newName, in: householdDishes())
        guard !changed.isEmpty, saveLabelChanges() else { return }
        // Follow the rename (or merge) with whatever spelling the dishes now use.
        let renamed = changed[0].collectionNames.first { DishTag.areSame($0, newName) } ?? DishTag.clean(newName)
        if appState.dishFilter.isSelected(collection: name) { appState.dishFilter.collection = renamed }
        if appState.planDishFilter.isSelected(collection: name) { appState.planDishFilter.collection = renamed }
    }

    private func deleteCollection(_ name: String) {
        let changed = DishCollection.delete(name, from: householdDishes())
        if appState.dishFilter.isSelected(collection: name) { appState.dishFilter.collection = nil }
        if appState.planDishFilter.isSelected(collection: name) { appState.planDishFilter.collection = nil }
        guard !changed.isEmpty else { return }
        _ = saveLabelChanges()
    }

    /// Renaming or deleting a collection reaches past the loaded pages.
    private func householdDishes() -> [Dish] {
        guard let householdID else { return [] }
        return (try? context.fetch(FetchDescriptor<Dish>(
            predicate: #Predicate { $0.household?.uuid == householdID }
        ))) ?? []
    }

    /// Saves a label change and refreshes the tag and collection lists. A
    /// failed save is reported; the edit stays in the context to be retried
    /// by the next save rather than silently dropped.
    private func saveLabelChanges() -> Bool {
        defer { metadataToken += 1 }
        do {
            try context.save()
            return true
        } catch {
            labelEditError = error.localizedDescription
            return false
        }
    }

    private func refreshTags() async {
        // Let the tab and its first page become interactive before deriving
        // secondary navigation from the complete library. The full scan uses
        // its own SwiftData executor so it cannot stall scrolling or the tab
        // transition on the main actor.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled, let householdID else {
            availableTags = []
            popularTags = []
            availableCollections = []
            return
        }
        let loader = DishLibraryMetadataLoaderPool.loader(for: context.container)
        let metadata = await loader.tagMetadata(
            householdID: householdID,
            revision: libraryRevision
        )
        guard !Task.isCancelled else { return }
        availableTags = metadata.available
        popularTags = metadata.popular
        availableCollections = metadata.collections
    }

    private func refreshBackgroundQuery() async {
        let request = libraryQueryRequest
        guard let request else {
            searchScores = [:]
            searchResultIDs = []
            rankedSearchRequest = nil
            return
        }
        searchScores = [:]
        rankedSearchRequest = nil
        guard !Task.isCancelled, libraryQueryRequest == request else { return }
        let actor: DishSearchSnapshotActor
        if let searchSnapshotActor {
            actor = searchSnapshotActor
        } else {
            actor = DishSearchSnapshotActor(modelContainer: context.container)
            searchSnapshotActor = actor
        }
        let results = await actor.filterAndSort(
            householdID: request.householdID,
            revision: request.revision,
            filter: request.filter
        )
        guard !Task.isCancelled, libraryQueryRequest == request else { return }
        searchScores = Dictionary(results.map { ($0.id, $0.score) }, uniquingKeysWith: { first, _ in first })
        searchResultIDs = results.map(\.id)
        rankedSearchRequest = request
    }

    private func updatePageState(filteredDishes: [Dish]) {
        hasMorePages = firstPageIsFull
        if !filteredDishes.isEmpty { hasAnyFilteredResults = true }
    }

    private func grid(_ items: [LibraryItem], acceptsDrops: Bool) -> some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(items) { item in
                switch item {
                case .dish(let dish):
                    if isSelecting {
                        DishSelectionCell(
                            dish: dish,
                            isSelected: DishSelection.isSelected([dish], in: selection),
                            toggle: { DishSelection.toggle([dish], in: &selection) }
                        )
                    } else {
                        DishLibraryCell(snapshot: DishLibraryCardSnapshot(dish), acceptsDrops: acceptsDrops, householdID: householdID)
                            .equatable()
                    }
                case .group(let ref, let members):
                    if isSelecting {
                        DishSelectionCell(
                            dish: members[0],
                            variantGroupName: ref.name,
                            isSelected: DishSelection.isSelected(members, in: selection),
                            toggle: { DishSelection.toggle(members, in: &selection) }
                        )
                    } else {
                        DishLibraryCell(
                            snapshot: DishLibraryCardSnapshot(members[0]),
                            group: ref,
                            variantCount: members.count,
                            acceptsDrops: acceptsDrops,
                            householdID: householdID
                        )
                        .equatable()
                    }
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

    /// When a restrictive filter hides an entire page, an on-appear footer
    /// would immediately mount the next page and repeat until a match appears
    /// (or the whole library is scanned) while the tab is otherwise idle.
    /// Keep the continuation explicit for empty pages; matching pages retain
    /// the usual scroll-to-load behavior.
    private func loadMoreButton(action: @escaping () -> Void) -> some View {
        Button(String(localized: "Load more recipes"), action: action)
            .frame(maxWidth: .infinity)
            .padding()
            .buttonStyle(.plain)
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
                // Or start from someone else's recipe.
                DiscoverRecipesButton()
                    .buttonStyle(.bordered)
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

private struct SharedSitePreview: Identifiable {
    let id = UUID()
    let url: URL
}

private struct SharedSitePreviewView: View {
    let url: URL

    var body: some View {
        Form {
            Section {
                Label(url.host() ?? url.absoluteString, systemImage: "globe")
                    .font(.headline)
                Text(String(localized: "This site was shared with MealPlan. Subscribe from Discover when you want future recipes to appear here."))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                Link(String(localized: "Open website"), destination: url)
            }
        }
        .navigationTitle(String(localized: "Discover recipes"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// Each scrolling window owns a fixed-size query. Reaching its footer mounts
/// the next window, so loading page 20 does not keep 2,400 SwiftData models in
/// the library view's active query or rerun filtering over all earlier pages.
@MainActor
private struct DishLibraryResultPage: View {
    @Environment(\.modelContext) private var context
    @Query private var dishes: [Dish]

    private let householdID: UUID?
    private let pageIndex: Int
    private let filter: DishFilter
    private let isLastPage: Bool
    private let acceptsDrops: Bool
    private let searchScores: [UUID: Double]?
    private let orderedSearchIDs: [UUID]?
    /// Set while the library is picking dishes for a bulk change.
    private let selection: Binding<[UUID: Dish]>?
    @Binding private var hasAnyFilteredResults: Bool
    @Binding private var hasMorePages: Bool
    private let loadMore: @MainActor (Int) -> Void
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 16)]

    private enum Item: Identifiable {
        case dish(Dish)
        case group(DishVariantGroupRef, members: [Dish])

        var id: String {
            switch self {
            case .dish(let dish): "dish-\(dish.uuid)"
            case .group(let group, _): "group-\(group.id)"
            }
        }
    }

    init(
        householdID: UUID?,
        pageIndex: Int,
        filter: DishFilter,
        isLastPage: Bool,
        acceptsDrops: Bool,
        selection: Binding<[UUID: Dish]>?,
        searchScores: [UUID: Double]?,
        orderedSearchIDs: [UUID]?,
        hasAnyFilteredResults: Binding<Bool>,
        hasMorePages: Binding<Bool>,
        loadMore: @escaping @MainActor (Int) -> Void
    ) {
        self.householdID = householdID
        self.pageIndex = pageIndex
        self.filter = filter
        self.isLastPage = isLastPage
        self.acceptsDrops = acceptsDrops
        self.searchScores = searchScores
        self.orderedSearchIDs = orderedSearchIDs
        self.selection = selection
        self._hasAnyFilteredResults = hasAnyFilteredResults
        self._hasMorePages = hasMorePages
        self.loadMore = loadMore

        let scopedHouseholdID = householdID ?? UUID()
        var descriptor: FetchDescriptor<Dish>
        if let orderedSearchIDs {
            let pageIDs = DishSearch.pageIDs(
                orderedSearchIDs,
                pageIndex: pageIndex,
                pageSize: DishLibraryView.pageSize
            )
            descriptor = FetchDescriptor<Dish>(
                predicate: #Predicate { dish in
                    dish.household?.uuid == scopedHouseholdID && pageIDs.contains(dish.uuid)
                },
                sortBy: DishLibrarySort.descriptors(for: filter.sort)
            )
            descriptor.fetchLimit = pageIDs.count
        } else {
            descriptor = FetchDescriptor<Dish>(
                predicate: #Predicate { $0.household?.uuid == scopedHouseholdID },
                sortBy: DishLibrarySort.descriptors(for: filter.sort)
            )
            descriptor.fetchLimit = DishLibraryView.pageSize
            descriptor.fetchOffset = pageIndex * DishLibraryView.pageSize
        }
        _dishes = Query(descriptor)
    }

    private var searchScoresForFilter: [UUID: Double]? {
        guard !filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return searchScores ?? [:]
    }

    private var pageDishes: [Dish] {
        guard let orderedSearchIDs else { return dishes }
        let byID = Dictionary(dishes.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        return DishSearch.pageIDs(
            orderedSearchIDs,
            pageIndex: pageIndex,
            pageSize: DishLibraryView.pageSize
        ).compactMap { byID[$0] }
    }

    var body: some View {
        let projection = DishLibraryPerformanceSignposts.signposter.beginInterval("paged filter and grouping")
        let now = Date.now
        let filtered = filter.apply(
            to: pageDishes,
            now: now,
            sourceIsAlphabeticallySorted: filter.sort == .alphabetical,
            searchScores: searchScoresForFilter
        )
        let crossPageGroups = DishLibraryVariantGrouping.load(
            filteredDishes: filtered,
            householdID: householdID,
            filter: filter,
            searchScores: searchScoresForFilter,
            context: context,
            now: now
        )
        let items = libraryItems(from: filtered, crossPageGroups: crossPageGroups)
        let _ = DishLibraryPerformanceSignposts.signposter.endInterval("paged filter and grouping", projection)

        Group {
            if !items.isEmpty {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(items) { item in
                        switch item {
                        case .dish(let dish):
                            if let selection {
                                DishSelectionCell(
                                    dish: dish,
                                    isSelected: DishSelection.isSelected([dish], in: selection.wrappedValue),
                                    toggle: { DishSelection.toggle([dish], in: &selection.wrappedValue) }
                                )
                            } else {
                                DishLibraryCell(
                                    snapshot: DishLibraryCardSnapshot(dish),
                                    acceptsDrops: acceptsDrops,
                                    householdID: householdID
                                )
                                .equatable()
                            }
                        case .group(let ref, let members):
                            if let selection {
                                DishSelectionCell(
                                    dish: members[0],
                                    variantGroupName: ref.name,
                                    isSelected: DishSelection.isSelected(members, in: selection.wrappedValue),
                                    toggle: { DishSelection.toggle(members, in: &selection.wrappedValue) }
                                )
                            } else {
                                DishLibraryCell(
                                    snapshot: DishLibraryCardSnapshot(members[0]),
                                    group: ref,
                                    variantCount: members.count,
                                    acceptsDrops: acceptsDrops,
                                    householdID: householdID
                                )
                                .equatable()
                            }
                        }
                    }
                }
                .padding(MacLayout.gutter)
            }

            let hasNextSearchPage = orderedSearchIDs.map {
                (pageIndex + 1) * DishLibraryView.pageSize < $0.count
            }
            let canLoadMore = orderedSearchIDs == nil
                ? dishes.count == DishLibraryView.pageSize
                : hasNextSearchPage == true
            if isLastPage && canLoadMore {
                if items.isEmpty {
                    loadMoreButton { loadMore(pageIndex) }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding()
                        .onAppear { loadMore(pageIndex) }
                }
            }
        }
        .onAppear { updateState(filtered: filtered) }
        .onChange(of: dishes.count) { updateState(filtered: filtered) }
        .onChange(of: searchScores) {
            updateState(filtered: filter.apply(
                to: dishes,
                sourceIsAlphabeticallySorted: filter.sort == .alphabetical,
                searchScores: searchScoresForFilter
            ))
        }
    }

    private func updateState(filtered: [Dish]) {
        if isLastPage {
            if let orderedSearchIDs {
                hasMorePages = (pageIndex + 1) * DishLibraryView.pageSize < orderedSearchIDs.count
            } else {
                hasMorePages = householdID != nil && dishes.count == DishLibraryView.pageSize
            }
        }
        if !filtered.isEmpty { hasAnyFilteredResults = true }
    }

    private func loadMoreButton(action: @escaping () -> Void) -> some View {
        Button(String(localized: "Load more recipes"), action: action)
            .frame(maxWidth: .infinity)
            .padding()
            .buttonStyle(.plain)
    }

    private func libraryItems(
        from filtered: [Dish],
        crossPageGroups: [UUID: DishLibraryVariantGroup]
    ) -> [Item] {
        var items: [Item] = []
        for dish in filtered {
            guard let groupID = dish.variantGroupID,
                  let group = crossPageGroups[groupID],
                  group.members.count > 1 else {
                items.append(.dish(dish))
                continue
            }
            // The first matching member in the store's stable order decides
            // which page emits the card; later pages omit the group entirely.
            guard group.firstMatchingUUID == dish.uuid else { continue }
            items.append(.group(
                DishVariantGroupRef(id: groupID, name: dish.variantGroupDisplayName, householdID: householdID),
                members: group.members
            ))
        }
        return items
    }

}

private struct DishLibraryVariantGroup {
    var firstMatchingUUID: UUID
    var members: [Dish]
}

/// Resolves only the other members of groups present on the current page.
/// That keeps group counts and multi-selection correct across page boundaries
/// without fetching the whole recipe library for each page.
@MainActor
private enum DishLibraryVariantGrouping {
    static func load(
        filteredDishes: [Dish],
        householdID: UUID?,
        filter: DishFilter,
        searchScores: [UUID: Double]?,
        context: ModelContext,
        now: Date
    ) -> [UUID: DishLibraryVariantGroup] {
        guard let householdID else { return [:] }
        let groupIDs = Array(Set(filteredDishes.compactMap(\.variantGroupID)))
        guard !groupIDs.isEmpty else { return [:] }

        let missingGroupID = UUID()
        let descriptor = FetchDescriptor<Dish>(
            predicate: #Predicate {
                groupIDs.contains($0.variantGroupID ?? missingGroupID)
                    && $0.household?.uuid == householdID
            },
            sortBy: DishLibrarySort.descriptors(for: filter.sort)
        )
        guard let orderedMembers = try? context.fetch(descriptor) else { return [:] }

        // Apply the same filters to the complete set of each visible group.
        // Re-filtering only a single page used to split groups and misstate
        // their size when their members landed in different offsets.
        let matchingIDs = Set(filter.apply(
            to: orderedMembers,
            now: now,
            sourceIsAlphabeticallySorted: filter.sort == .alphabetical,
            searchScores: searchScores
        ).map(\.uuid))
        let matchingMembers = orderedMembers.filter { matchingIDs.contains($0.uuid) }
        let grouped = Dictionary(grouping: matchingMembers.compactMap { dish -> (UUID, Dish)? in
            guard let groupID = dish.variantGroupID else { return nil }
            return (groupID, dish)
        }, by: \.0)

        return grouped.reduce(into: [:]) { result, pair in
            let membersInStoreOrder = pair.value.map(\.1)
            guard let first = membersInStoreOrder.first else { return }
            result[pair.key] = DishLibraryVariantGroup(
                firstMatchingUUID: first.uuid,
                members: DishVariants.sorted(membersInStoreOrder)
            )
        }
    }
}

enum DishLibrarySort {
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
        case .fewestServings:
            [SortDescriptor(\Dish.servings), SortDescriptor(\Dish.name), SortDescriptor(\Dish.uuid)]
        case .mostServings:
            [SortDescriptor(\Dish.servings, order: .reverse), SortDescriptor(\Dish.name), SortDescriptor(\Dish.uuid)]
        case .shortestTotalTime, .longestTotalTime, .shortestPrepTime, .longestPrepTime,
             .shortestCookTime, .longestCookTime:
            // These values are sorted by the background snapshot query; the
            // page fetch only needs a deterministic fallback order.
            [SortDescriptor(\Dish.name), SortDescriptor(\Dish.uuid)]
        }
    }
}

@ModelActor
actor DishLibraryMetadataActor {
    /// Selects and resolves seasonal suggestions away from the UI context.
    /// Ingredient traversal is limited to the same 120 least-recently-used
    /// candidates as before, and every row is scoped to the active household.
    func seasonalSuggestionIDs(
        householdID: UUID,
        season: Season
    ) -> [UUID] {
        guard !Task.isCancelled,
              let dishes = try? modelContext.fetch(FetchDescriptor<Dish>(
                predicate: #Predicate { $0.household?.uuid == householdID }
              ))
        else { return [] }

        func suggestionOrder(_ lhs: Dish, _ rhs: Dish) -> Bool {
            let left = lhs.lastUsedDate ?? .distantPast
            let right = rhs.lastUsedDate ?? .distantPast
            if left != right { return left < right }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        var selected = dishes
            .filter { $0.season == season }
            .sorted(by: suggestionOrder)
        if selected.count >= 10 {
            return Array(selected.prefix(10).map(\.uuid))
        }

        let candidates = dishes
            .filter { $0.season != season }
            .sorted(by: suggestionOrder)
            .prefix(120)
        for dish in candidates {
            guard !Task.isCancelled else { return [] }
            if dish.sortedIngredients.contains(where: { line in
                guard let name = line.ingredient?.name else { return false }
                return SeasonalProduce.seasons(forIngredientNamed: name).contains(season)
            }) {
                selected.append(dish)
                if selected.count == 10 { break }
            }
        }
        return Array(selected.sorted(by: suggestionOrder).prefix(10).map(\.uuid))
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
