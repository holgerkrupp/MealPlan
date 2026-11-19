import SwiftUI
import SwiftData

/// Horizontal strip of dishes that fit the current season — either tagged
/// with the season or containing a seasonal ingredient.
@MainActor
struct SeasonalSuggestionsStrip: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    let householdID: UUID?
    let dataRevision: Int

    @State private var planning: Dish?
    @State private var suggestions: [Dish] = []
    @State private var cachedSuggestionIDs: (revision: Revision, ids: [UUID])?
    @State private var notificationRevision = 0

    private var season: Season { Season.current() }

    private struct Revision: Hashable {
        var householdID: UUID?
        var season: Season
        var dataRevision: Int
        var notificationRevision: Int
    }

    private var revision: Revision {
        return Revision(
            householdID: householdID,
            season: season,
            dataRevision: dataRevision,
            notificationRevision: notificationRevision
        )
    }

    var body: some View {
        Group {
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(String(localized: "In season now"), systemImage: "leaf")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, MacLayout.gutter)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(suggestions) { dish in
                                Button {
                                    planning = dish
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        DishThumbnail(dish: dish, size: 96, cornerRadius: 12)
                                        Text(dish.name)
                                            .font(.caption)
                                            // A fixed caption box: two lines that
                                            // shrink to fit, so a long name shows
                                            // in full without making the strip
                                            // taller than its neighbours.
                                            .lineLimit(2)
                                            .minimumScaleFactor(0.7)
                                            .frame(width: 96, height: 28, alignment: .topLeading)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, MacLayout.gutter)
                    }
                }
                .padding(.top, 8)
                .detailPresentation(item: $planning, route: { .planRecipe($0.uuid) }) { dish in
                    NavigationStack { PlanDishSheet(dish: dish, defaultDate: appState.selectedDate) }
                        .presentationDetents([.medium])
                        .dismissesOnOutsideClick()
                }
            }
        }
        .task(id: revision) {
            await refreshSuggestions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mealPlanDataDidChange)) { _ in
            notificationRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave, object: modelContext)) { _ in
            notificationRevision &+= 1
        }
    }

    /// Candidate selection and ingredient relationship scans run on the
    /// dedicated SwiftData actor. The view revision stays constant-time.
    private func refreshSuggestions() async {
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }

        let requestRevision = revision
        guard let householdID else {
            suggestions = []
            return
        }

        let suggestionIDs: [UUID]
        if let cached = cachedSuggestionIDs, cached.revision == requestRevision {
            suggestionIDs = cached.ids
        } else {
            suggestionIDs = await DishLibraryMetadataActor(
                modelContainer: modelContext.container
            ).seasonalSuggestionIDs(
                householdID: householdID,
                season: season
            )
            guard !Task.isCancelled else { return }
            cachedSuggestionIDs = (requestRevision, suggestionIDs)
        }

        guard !Task.isCancelled, !suggestionIDs.isEmpty else {
            suggestions = []
            return
        }
        let fetched = (try? modelContext.fetch(FetchDescriptor<Dish>(
            predicate: #Predicate {
                suggestionIDs.contains($0.uuid) && $0.household?.uuid == householdID
            }
        ))) ?? []
        guard !Task.isCancelled else { return }
        let dishesByID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.uuid, $0) })
        suggestions = suggestionIDs.compactMap { dishesByID[$0] }
    }
}

#Preview {
    SeasonalSuggestionsStrip(householdID: PreviewData.household.uuid, dataRevision: 0)
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
