import SwiftUI
import SwiftData

/// The "Eat out" half of the planning sheet: plan a meal nobody has to cook,
/// optionally pinned to a restaurant found on the map.
@MainActor
struct EatOutPickerView: View {
    let date: Date
    let mealKey: String
    var onPlanned: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    /// Places the family has eaten at before, so the regulars are one tap away.
    @Query(sort: \MealPlanEntry.date, order: .reverse) private var pastEntries: [MealPlanEntry]

    @State private var model = RestaurantSearchModel()

    /// The search only runs from two characters on; below that the list keeps
    /// showing the places the family has been to.
    private var isSearchable: Bool {
        model.query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    /// The most recent distinct restaurants from earlier plans.
    private var recentPlaces: [MealPlanEntry] {
        var seen = Set<String>()
        return pastEntries
            .filter { $0.isEatingOut && $0.placeName?.isEmpty == false }
            .filter { seen.insert($0.placeName ?? "").inserted }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        List {
            Section {
                Button {
                    plan(name: nil, address: nil, latitude: nil, longitude: nil)
                } label: {
                    Label(String(localized: "Eat out — decide the place later"), systemImage: "fork.knife")
                }
                .disabled(appState.isGuest)
            }

            if isSearchable {
                Section(String(localized: "Places")) {
                    if model.isSearching {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(String(localized: "Searching…")).foregroundStyle(.secondary)
                        }
                    } else if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    } else if model.results.isEmpty {
                        Text(String(localized: "No places found."))
                            .foregroundStyle(.secondary)
                    }

                    ForEach(model.results) { place in
                        Button {
                            plan(
                                name: place.name,
                                address: place.address,
                                latitude: place.latitude,
                                longitude: place.longitude
                            )
                        } label: {
                            placeRow(
                                name: place.name,
                                detail: [place.category, place.address].compactMap { $0 }.joined(separator: " · ")
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(appState.isGuest)
                    }
                }
            }

            if !isSearchable, !recentPlaces.isEmpty {
                Section(String(localized: "Places you’ve been")) {
                    ForEach(recentPlaces) { entry in
                        Button {
                            plan(
                                name: entry.placeName,
                                address: entry.placeAddress,
                                latitude: entry.placeLatitude,
                                longitude: entry.placeLongitude
                            )
                        } label: {
                            placeRow(name: entry.placeName ?? "", detail: entry.placeAddress ?? "")
                        }
                        .buttonStyle(.plain)
                        .disabled(appState.isGuest)
                    }
                }
            }
/*
            if !isSearchable, recentPlaces.isEmpty {
                Section {
                    Text(String(localized: "Search for a restaurant, café or bakery nearby."))
                        .foregroundStyle(.secondary)
                }
            */
        }
        .searchable(
            text: $model.query,
            placement: .automatic,
            prompt: String(localized: "Restaurant, café, bakery…")
        )
        .onChange(of: model.query) { _, _ in model.search() }
        .task { await model.locate() }
    }

    private func placeRow(name: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "storefront")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func plan(name: String?, address: String?, latitude: Double?, longitude: Double?) {
        MealPlanner.planEatingOut(
            on: date,
            mealKey: mealKey,
            placeName: name,
            placeAddress: address,
            latitude: latitude,
            longitude: longitude,
            household: appState.currentHousehold,
            memberName: appState.currentMemberName,
            context: context
        )
        onPlanned()
    }
}
