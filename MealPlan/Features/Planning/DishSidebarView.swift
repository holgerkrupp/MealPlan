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
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @Query(sort: \Dish.name) private var allDishes: [Dish]

    @State private var planningDish: Dish?
    @State private var detailDish: Dish?
    /// Lets ⌘F from the menu bar land in the sidebar's own search field.
    @FocusState private var searchFocused: Bool

    private var filteredDishes: [Dish] {
        appState.planDishFilter.apply(to: allDishes)
    }

    private var tags: [String] {
        DishTag.vocabulary(from: allDishes)
    }

    private var popularTags: [String] {
        DishTag.mostUsed(from: allDishes)
    }

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            header(filter: $appState.planDishFilter)
            Divider()

            if filteredDishes.isEmpty {
                emptyState
            } else {
                dishList
            }
        }
        .background(.background.secondary)
        // The sidebar is the dish list while you're on the plan, so it takes
        // over the library's menu items — filtering its own `planDishFilter`,
        // and offering neither import nor export, which belong to the Dishes
        // section proper.
        .focusedSceneValue(\.dishLibraryCommands, sidebarCommands)
        .sheet(item: $planningDish) { dish in
            NavigationStack {
                PlanDishSheet(dish: dish, defaultDate: appState.selectedDate)
            }
            .dismissesOnOutsideClick()
        }
        #if !os(macOS)
        .sheet(item: $detailDish) { dish in
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
        #endif
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
                Text("\(filteredDishes.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                DishFilterMenu(
                    filter: filter,
                    availableTags: tags
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
            ForEach(filteredDishes) { dish in
                // Deliberately a tappable row rather than a `Button`: on macOS
                // a button claims the mouse-down, so `.draggable` never sees
                // the drag begin and the dish can't be pulled onto a meal
                // card. (The library grid gets away with `.draggable` because
                // its rows are `NavigationLink`s.) The accessibility traits
                // below keep the row a button to VoiceOver and the keyboard.
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
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func showDetails(for dish: Dish) {
        #if os(macOS)
        openWindow(value: MacDetailWindowRoute.recipe(dish.uuid))
        #else
        detailDish = dish
        #endif
    }

    private func row(_ dish: Dish) -> some View {
        HStack(spacing: 10) {
            DishThumbnail(dish: dish, size: 44, cornerRadius: 8)

            VStack(alignment: .leading, spacing: 3) {
                Text(dish.name.isEmpty ? String(localized: "Untitled dish") : dish.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
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

#Preview {
    DishSidebarView()
        .frame(width: 300, height: 600)
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
