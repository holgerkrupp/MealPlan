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
    @Query(sort: \Dish.name) private var allDishes: [Dish]

    @State private var planningDish: Dish?
    @State private var detailDish: Dish?

    private var filteredDishes: [Dish] {
        appState.planDishFilter.apply(to: allDishes)
    }

    private var collections: [String] {
        Array(Set(allDishes.flatMap(\.collectionNames))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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
        .sheet(item: $planningDish) { dish in
            NavigationStack {
                PlanDishSheet(dish: dish, defaultDate: appState.selectedDate)
            }
        }
        .sheet(item: $detailDish) { dish in
            NavigationStack {
                DishDetailView(dish: dish)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "Done")) { detailDish = nil }
                        }
                    }
            }
        }
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
                DishFilterMenu(filter: filter, availableCollections: collections)
                    .labelStyle(.iconOnly)
                    .menuIndicator(.hidden)
                    .fixedSize()
            }

            searchField(text: filter.searchText)
            mealTypeChips(filter: filter)
        }
        .padding(10)
    }

    private func searchField(text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(String(localized: "Search dishes"), text: text)
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

    private var dishList: some View {
        List {
            ForEach(filteredDishes) { dish in
                Button {
                    if appState.isGuest { detailDish = dish } else { planningDish = dish }
                } label: {
                    row(dish)
                }
                .buttonStyle(.plain)
                .draggable(DishReference(dishUUID: dish.uuid, name: dish.name))
                .contextMenu {
                    if !appState.isGuest {
                        Button(String(localized: "Plan meal…"), systemImage: "calendar.badge.plus") {
                            planningDish = dish
                        }
                    }
                    Button(String(localized: "Show details"), systemImage: "info.circle") {
                        detailDish = dish
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
                    ForEach(Array(dish.dietaryTags).sorted(by: { $0.rawValue < $1.rawValue }).prefix(3)) { tag in
                        Image(systemName: tag.symbolName)
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
