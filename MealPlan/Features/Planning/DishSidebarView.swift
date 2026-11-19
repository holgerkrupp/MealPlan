import SwiftUI
import SwiftData

/// The dish list shown beside the plan on iPad, Mac and landscape phones.
///
/// Dishes are searchable and filterable here without disturbing the Dishes
/// tab (the sidebar keeps its own `DishFilter` on `AppState`), and every row
/// is `.draggable` so it can be dropped straight onto a `MealCard`. Tapping a
/// row opens the plan sheet — the same thing, for people who don't drag.
@MainActor
struct DishSidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    private let householdID: UUID?
    private static let pageSize = 120

    @State private var planningDish: Dish?
    @State private var detailDish: Dish?
    /// Lets ⌘F from the menu bar land in the sidebar's own search field.
    @FocusState private var searchFocused: Bool
    @State private var availableTags: [String] = []
    @State private var popularTags: [String] = []
    @State private var availableCollections: [String] = []
    @State private var totalDishCount = 0
    @State private var pageCount = 1
    @State private var metadataToken = 0
    @State private var searchSnapshotActor: DishSearchSnapshotActor?
    @State private var searchScores: [UUID: Double] = [:]
    @State private var searchResultIDs: [UUID] = []
    @State private var rankedSearchRequest: DishLibraryQueryRequest?
    @State private var searchGeneration = 0

    init(householdID: UUID?) {
        self.householdID = householdID
    }

    private var usesBackgroundQuery: Bool {
        let filter = appState.planDishFilter
        return !filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || filter.isActive || filter.sort != .alphabetical
    }

    private var libraryRevision: DishLibraryMetadataRevision {
        DishLibraryMetadataRevision(count: 0, latestModification: nil, token: metadataToken)
    }

    private var libraryQueryRequest: DishLibraryQueryRequest? {
        guard usesBackgroundQuery, let householdID else { return nil }
        return DishLibraryQueryRequest(
            householdID: householdID,
            filter: appState.planDishFilter,
            generation: searchGeneration
        )
    }

    private var displayedCount: Int {
        if usesBackgroundQuery {
            return rankedSearchRequest == libraryQueryRequest ? searchResultIDs.count : 0
        }
        return totalDishCount
    }

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            header(filter: $appState.planDishFilter)
            Divider()

            if usesBackgroundQuery && rankedSearchRequest != libraryQueryRequest {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if usesBackgroundQuery ? searchResultIDs.isEmpty : totalDishCount == 0 {
                emptyState
            } else {
                if !appState.isGuest {
                    InlineTip(
                        tip: DragToPlanTip(),
                        padding: EdgeInsets(top: 10, leading: 10, bottom: 0, trailing: 10)
                    )
                }
                dishList
            }
        }
        .background(.background.secondary)
        .task(id: libraryRevision) {
            await refreshMetadata()
        }
        .task(id: libraryQueryRequest) {
            await refreshSearchResults()
        }
        .onChange(of: libraryQueryRequest) { pageCount = 1 }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave, object: context)) { _ in
            searchGeneration &+= 1
            metadataToken &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .mealPlanDataDidChange)) { _ in
            searchGeneration &+= 1
            metadataToken &+= 1
        }
        // The sidebar is the dish list while you're on the plan, so it takes
        // over the library's menu items — filtering its own `planDishFilter`,
        // and offering neither import nor export, which belong to the Dishes
        // section proper.
        .focusedSceneValue(\.dishLibraryCommands, sidebarCommands)
        .detailPresentation(item: $planningDish, route: { .planRecipe($0.uuid) }) { dish in
            NavigationStack {
                PlanDishSheet(dish: dish, defaultDate: appState.selectedDate)
            }
            .dismissesOnOutsideClick()
        }
        .detailPresentation(item: $detailDish, route: { .recipe($0.uuid) }) { dish in
            NavigationStack {
                DishDetailView(dish: dish)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "Done")) { detailDish = nil }
                        }
                    }
            }
            .dismissesOnOutsideClick()
        }
    }

    private var sidebarCommands: DishLibraryCommands {
        let narrowed = appState.planDishFilter.isActive
            || !appState.planDishFilter.searchText.trimmingCharacters(in: .whitespaces).isEmpty
        var commands = DishLibraryCommands(
            sort: appState.planDishFilter.sort,
            search: { searchFocused = true },
            setSort: { appState.planDishFilter.sort = $0 }
        )
        if narrowed {
            commands.clearFilters = {
                appState.planDishFilter = DishFilter(sort: appState.planDishFilter.sort)
            }
        }
        return commands
    }

    // MARK: - Header

    private func header(filter: Binding<DishFilter>) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(AppSection.dishes.title)
                    .font(.headline)
                Text("\(displayedCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                DishFilterMenu(
                    filter: filter,
                    availableTags: availableTags,
                    availableCollections: availableCollections
                )
                    .labelStyle(.iconOnly)
                    .menuIndicator(.hidden)
                    .fixedSize()
            }

            searchField(text: filter.searchText)
            mealTypeChips(filter: filter)
            TagFilterStrip(filter: filter, tags: popularTags, horizontalPadding: 0)
        }
        .padding(10)
    }

    private func refreshSearchResults() async {
        let request = libraryQueryRequest
        guard let request else {
            searchScores = [:]
            searchResultIDs = []
            rankedSearchRequest = nil
            return
        }
        searchScores = [:]
        searchResultIDs = []
        rankedSearchRequest = nil
        if !request.filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do { try await Task.sleep(for: .milliseconds(180)) }
            catch { return }
        }
        guard !Task.isCancelled, libraryQueryRequest == request else { return }
        let actor: DishSearchSnapshotActor
        if let existing = searchSnapshotActor {
            actor = existing
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

    private func refreshMetadata() async {
        guard let householdID = appState.currentHousehold?.uuid else {
            availableTags = []
            popularTags = []
            availableCollections = []
            return
        }
        guard !Task.isCancelled else { return }
        let loader = DishLibraryMetadataLoaderPool.loader(for: context.container)
        let metadata = await loader.tagMetadata(
            householdID: householdID,
            revision: libraryRevision
        )
        guard !Task.isCancelled, appState.currentHousehold?.uuid == householdID else { return }
        availableTags = metadata.available
        popularTags = metadata.popular
        availableCollections = metadata.collections.map(\.name)
        totalDishCount = metadata.dishCount
    }

    private func searchField(text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(String(localized: "Search dishes"), text: text)
                .focused($searchFocused)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .font(.subheadline)

            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Clear search"))
                .accessibilityLabel(String(localized: "Clear search"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Quick one-tap narrowing to the meal you're planning right now.
    private func mealTypeChips(filter: Binding<DishFilter>) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(String(localized: "All"), isOn: filter.wrappedValue.mealType == nil) {
                    filter.wrappedValue.mealType = nil
                }
                ForEach(MealTypeTag.allCases) { tag in
                    chip(tag.localizedName, isOn: filter.wrappedValue.mealType == tag) {
                        filter.wrappedValue.mealType = filter.wrappedValue.mealType == tag ? nil : tag
                    }
                }
            }
        }
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(isOn ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary.opacity(0.6)), in: Capsule())
                .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(Color.primary))
        }
        .buttonStyle(.plain)
    }

    // MARK: - List

    /// What tapping a row does: guests can only look, everyone else plans.
    private func open(_ dish: Dish) {
        if appState.isGuest { showDetails(for: dish) } else { planningDish = dish }
    }

    private var dishList: some View {
        List {
            if let request = libraryQueryRequest, rankedSearchRequest == request {
                let totalPages = (searchResultIDs.count + Self.pageSize - 1) / Self.pageSize
                let loadedPages = min(pageCount, totalPages)
                ForEach(0..<loadedPages, id: \.self) { pageIndex in
                    DishSidebarRows(
                        householdID: request.householdID,
                        sort: appState.planDishFilter.sort,
                        pageIndex: pageIndex,
                        pageSize: Self.pageSize,
                        orderedIDs: searchResultIDs,
                        isLastPage: pageIndex == loadedPages - 1,
                        loadMore: { loadMore(after: pageIndex) },
                        rowContent: sidebarListRow
                    )
                }
            } else if let householdID {
                ForEach(0..<pageCount, id: \.self) { pageIndex in
                    DishSidebarRows(
                        householdID: householdID,
                        sort: .alphabetical,
                        pageIndex: pageIndex,
                        pageSize: Self.pageSize,
                        orderedIDs: nil,
                        isLastPage: pageIndex == pageCount - 1,
                        loadMore: { loadMore(after: pageIndex) },
                        rowContent: sidebarListRow
                    )
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func loadMore(after pageIndex: Int) {
        guard pageIndex == pageCount - 1 else { return }
        pageCount += 1
    }

    private func sidebarListRow(_ dish: Dish) -> some View {
        // Deliberately a tappable row rather than a Button: macOS must let
        // `.draggable` receive the mouse-down. Accessibility retains button
        // traits and an activation action.
        row(dish)
            .onTapGesture { open(dish) }
            .draggable(DishReference(dishUUID: dish.uuid, name: dish.name))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open(dish) }
            .contextMenu {
                if !appState.isGuest {
                    Button(String(localized: "Plan meal…"), systemImage: "calendar.badge.plus") {
                        planningDish = dish
                    }
                }
                Button(String(localized: "Show details"), systemImage: "info.circle") {
                    showDetails(for: dish)
                }
                OpenInNewWindowButton(route: .recipe(dish.uuid))
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
            .listRowBackground(Color.clear)
    }

    private func showDetails(for dish: Dish) {
        detailDish = dish
    }

    private func row(_ dish: Dish) -> some View {
        HStack(spacing: 10) {
            DishThumbnail(dish: dish, size: 44, cornerRadius: 8)

            VStack(alignment: .leading, spacing: 3) {
                Text(dish.name.isEmpty ? String(localized: "Untitled dish") : dish.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    if let tag = dish.sortedTagNames.first {
                        Text(verbatim: tag)
                    }
                    if let minutes = dish.totalTimeMinutes {
                        Label("\(minutes) min", systemImage: "clock")
                            .labelStyle(.titleAndIcon)
                    }
                    if dish.usageCount == 0 && dish.lastUsedDate == nil {
                        Text(String(localized: "Never cooked"))
                            .foregroundStyle(.blue)
                    } else if let days = dish.daysSinceLastCooked(), days >= 30 {
                        Text(String(localized: "\(days) d"))
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 0)

            if dish.needsReview {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "fork.knife")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(appState.planDishFilter.searchText.isEmpty && !appState.planDishFilter.isActive
                 ? String(localized: "No dishes yet")
                 : String(localized: "No dishes match"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if appState.planDishFilter.isActive || !appState.planDishFilter.searchText.isEmpty {
                Button(String(localized: "Clear filters")) {
                    appState.planDishFilter = DishFilter(sort: appState.planDishFilter.sort)
                }
                .font(.caption)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

@MainActor
private struct DishSidebarRows<RowContent: View>: View {
    @Query private var dishes: [Dish]

    private let pageIndex: Int
    private let pageSize: Int
    private let orderedIDs: [UUID]?
    private let isLastPage: Bool
    private let loadMore: () -> Void
    private let rowContent: (Dish) -> RowContent

    init(
        householdID: UUID,
        sort: DishFilter.Sort,
        pageIndex: Int,
        pageSize: Int,
        orderedIDs: [UUID]?,
        isLastPage: Bool,
        loadMore: @escaping () -> Void,
        @ViewBuilder rowContent: @escaping (Dish) -> RowContent
    ) {
        self.pageIndex = pageIndex
        self.pageSize = pageSize
        self.orderedIDs = orderedIDs
        self.isLastPage = isLastPage
        self.loadMore = loadMore
        self.rowContent = rowContent

        if let orderedIDs {
            let pageIDs = DishSearch.pageIDs(orderedIDs, pageIndex: pageIndex, pageSize: pageSize)
            var descriptor = FetchDescriptor<Dish>(
                predicate: #Predicate { $0.household?.uuid == householdID && pageIDs.contains($0.uuid) },
                sortBy: DishLibrarySort.descriptors(for: sort)
            )
            descriptor.fetchLimit = pageIDs.count
            _dishes = Query(descriptor)
        } else {
            var descriptor = FetchDescriptor<Dish>(
                predicate: #Predicate { $0.household?.uuid == householdID },
                sortBy: DishLibrarySort.descriptors(for: sort)
            )
            descriptor.fetchLimit = pageSize
            descriptor.fetchOffset = pageIndex * pageSize
            _dishes = Query(descriptor)
        }
    }

    var body: some View {
        Section {
            ForEach(dishes) { dish in rowContent(dish) }
            if isLastPage && canLoadMore {
                Button(String(localized: "Load more recipes"), action: loadMore)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
        }
    }

    private var canLoadMore: Bool {
        if let orderedIDs {
            return (pageIndex + 1) * pageSize < orderedIDs.count
        }
        return dishes.count == pageSize
    }
}

#Preview {
    DishSidebarView(householdID: AppState.preview.currentHousehold?.uuid)
        .frame(width: 300, height: 600)
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
