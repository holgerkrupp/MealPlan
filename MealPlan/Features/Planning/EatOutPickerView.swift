import SwiftUI
import SwiftData
import MapKit

/// The "Eat out" half of the planning sheet: plan a meal nobody has to cook,
/// optionally pinned to a restaurant found on the map.
@MainActor
struct EatOutPickerView: View {
    let date: Date
    let mealKey: String
    /// Typed in the planning sheet's own header, so both halves of the sheet
    /// share one search field.
    var query: String = ""
    var onPlanned: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    /// Places the family has eaten at before, so the regulars are one tap away.
    @Query(sort: \MealPlanEntry.date, order: .reverse) private var pastEntries: [MealPlanEntry]

    @State private var model = RestaurantSearchModel()
    @State private var selectedPlaceID: String?
    @State private var mapPosition: MapCameraPosition = .automatic

    /// The search only runs from two characters on; below that the list keeps
    /// showing the places the family has been to.
    private var isSearchable: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    /// The most recent distinct restaurants from earlier plans.
    private var recentPlaces: [PlaceOption] {
        var seen = Set<String>()
        return pastEntries
            .filter { $0.isEatingOut && $0.placeName?.isEmpty == false }
            .filter { seen.insert($0.placeName ?? "").inserted }
            .prefix(5)
            .map(PlaceOption.init)
    }

    private var searchPlaces: [PlaceOption] {
        model.results.map(PlaceOption.init)
    }

    private var visiblePlaces: [PlaceOption] {
        isSearchable ? searchPlaces : recentPlaces
    }

    private var mappablePlaces: [PlaceOption] {
        visiblePlaces.filter { $0.coordinate != nil }
    }

    private var selectedPlace: PlaceOption? {
        visiblePlaces.first { $0.id == selectedPlaceID }
    }

    var body: some View {
        GeometryReader { geometry in
            if EatOutPickerLayoutPolicy.usesSideBySideLayout(in: geometry.size), !mappablePlaces.isEmpty {
                HStack(spacing: 0) {
                    placeList
                        .frame(minWidth: 300, maxWidth: geometry.size.width * 0.52)
                    Divider()
                    placeMap
                }
            } else {
                VStack(spacing: 0) {
                    if !mappablePlaces.isEmpty {
                        placeMap
                            .frame(height: min(max(geometry.size.height * 0.34, 170), 260))
                        Divider()
                    }
                    placeList
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let selectedPlace {
                selectedPlaceBar(selectedPlace)
            }
        }
        .onChange(of: query, initial: true) { _, _ in
            selectedPlaceID = nil
            model.query = query
            model.search()
        }
        .onChange(of: mappablePlaces.map(\.id)) { _, _ in
            mapPosition = .automatic
            if selectedPlace == nil { selectedPlaceID = nil }
        }
        .task { await model.locate() }
    }

    private var placeList: some View {
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

                    ForEach(searchPlaces) { place in
                        Button {
                            select(place)
                        } label: {
                            placeRow(
                                name: place.name,
                                detail: [place.category, place.address].compactMap { $0 }.joined(separator: " · "),
                                isSelected: selectedPlaceID == place.id
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(selectedPlaceID == place.id ? Color.accentColor.opacity(0.12) : Color.clear)
                    }
                }
            }

            if !isSearchable, !recentPlaces.isEmpty {
                Section(String(localized: "Places you’ve been")) {
                    ForEach(recentPlaces) { place in
                        Button {
                            select(place)
                        } label: {
                            placeRow(
                                name: place.name,
                                detail: place.address ?? "",
                                isSelected: selectedPlaceID == place.id
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(selectedPlaceID == place.id ? Color.accentColor.opacity(0.12) : Color.clear)
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
        #if os(macOS)
        .listStyle(.inset)
        #else
        .listStyle(.insetGrouped)
        #endif
    }

    private var placeMap: some View {
        Map(position: $mapPosition) {
            ForEach(mappablePlaces) { place in
                if let coordinate = place.coordinate {
                    Annotation(place.name, coordinate: coordinate, anchor: .bottom) {
                        Button {
                            select(place)
                        } label: {
                            Image(systemName: "storefront.fill")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(selectedPlaceID == place.id ? Color.white : Color.accentColor)
                                .frame(width: 38, height: 38)
                                .background {
                                    Circle().fill(
                                        selectedPlaceID == place.id
                                            ? Color.accentColor
                                            : Color.secondary.opacity(0.18)
                                    )
                                }
                                .overlay {
                                    Circle().stroke(.background, lineWidth: 2)
                                }
                                .shadow(radius: selectedPlaceID == place.id ? 5 : 2, y: 2)
                                .scaleEffect(selectedPlaceID == place.id ? 1.16 : 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(place.name)
                        .accessibilityAddTraits(selectedPlaceID == place.id ? .isSelected : [])
                    }
                }
            }
        }
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .accessibilityLabel(String(localized: "Restaurant map"))
    }

    private func placeRow(name: String, detail: String, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "storefront.fill" : "storefront")
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
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func selectedPlaceBar(_ place: PlaceOption) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                    .font(.headline)
                    .lineLimit(1)
                if let address = place.address, !address.isEmpty {
                    Text(address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button(String(localized: "Plan here"), systemImage: "checkmark") {
                plan(
                    name: place.name,
                    address: place.address,
                    latitude: place.latitude,
                    longitude: place.longitude
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.isGuest)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func select(_ place: PlaceOption) {
        selectedPlaceID = place.id
        guard let coordinate = place.coordinate else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            mapPosition = .region(MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 1_500,
                longitudinalMeters: 1_500
            ))
        }
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

private struct PlaceOption: Identifiable {
    let id: String
    let name: String
    let address: String?
    let category: String?
    let latitude: Double?
    let longitude: Double?

    init(_ result: RestaurantResult) {
        id = result.id
        name = result.name
        address = result.address
        category = result.category
        latitude = result.latitude
        longitude = result.longitude
    }

    init(_ entry: MealPlanEntry) {
        id = "recent-\(entry.uuid.uuidString)"
        name = entry.placeName ?? String(localized: "Restaurant")
        address = entry.placeAddress
        category = nil
        latitude = entry.placeLatitude
        longitude = entry.placeLongitude
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum EatOutPickerLayoutPolicy {
    static let minimumSideBySideWidth: Double = 620

    static func usesSideBySideLayout(in size: CGSize) -> Bool {
        size.width > size.height && size.width >= minimumSideBySideWidth
    }
}

#Preview {
    NavigationStack {
        EatOutPickerView(date: .now, mealKey: PreviewData.mealType.key, query: "", onPlanned: {})
    }
    .environment(AppState.preview)
    .modelContainer(PreviewData.container)
}
