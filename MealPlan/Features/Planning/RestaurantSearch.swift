import Foundation
import MapKit
import CoreLocation

/// One place from the map search, flattened into the bits a planned meal needs.
struct RestaurantResult: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let address: String?
    let category: String?
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Looks up restaurants with `MKLocalSearch`, biased towards where the user is
/// when they allow it. Location is entirely optional: without it the search
/// still works, it just isn't centred on the neighbourhood.
@MainActor
@Observable
final class RestaurantSearchModel {
    var query = ""
    var results: [RestaurantResult] = []
    var isSearching = false
    var errorMessage: String?
    /// Nil until the user's position is known (or they declined).
    private(set) var center: CLLocationCoordinate2D?

    private var searchTask: Task<Void, Never>?

    /// Ask for the current position once, so results are nearby ones. Silently
    /// gives up if the user says no — the search just stays unbiased.
    func locate() async {
        guard center == nil else { return }
        do {
            for try await update in CLLocationUpdate.liveUpdates(.default) {
                if let location = update.location {
                    center = location.coordinate
                    break
                }
                if update.authorizationDenied || update.authorizationDeniedGlobally { break }
            }
        } catch {
            // No location is a perfectly fine state; keep searching without it.
        }
    }

    /// Debounced search, so typing doesn't fire a request per keystroke.
    func search() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else {
            results = []
            isSearching = false
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self?.performSearch(text)
        }
    }

    private func performSearch(_ text: String) async {
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = .pointOfInterest
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [
            .restaurant, .cafe, .bakery, .brewery, .winery, .nightlife, .foodMarket,
        ])
        if let center {
            request.region = MKCoordinateRegion(
                center: center,
                latitudinalMeters: 20_000,
                longitudinalMeters: 20_000
            )
        }

        do {
            let response = try await MKLocalSearch(request: request).start()
            guard !Task.isCancelled else { return }
            results = response.mapItems.compactMap(Self.result(from:))
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            errorMessage = error.localizedDescription
        }
    }

    private static func result(from item: MKMapItem) -> RestaurantResult? {
        let coordinate = item.location.coordinate
        let name = item.name ?? String(localized: "Restaurant")
        return RestaurantResult(
            id: "\(name)-\(coordinate.latitude)-\(coordinate.longitude)",
            name: name,
            address: item.address?.fullAddress ?? item.address?.shortAddress,
            category: item.pointOfInterestCategory?.friendlyName,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }
}

extension MKPointOfInterestCategory {
    /// A short, human label for the few categories the food search returns.
    var friendlyName: String? {
        switch self {
        case .restaurant: String(localized: "Restaurant")
        case .cafe: String(localized: "Café")
        case .bakery: String(localized: "Bakery")
        case .brewery: String(localized: "Brewery")
        case .winery: String(localized: "Winery")
        case .nightlife: String(localized: "Bar")
        case .foodMarket: String(localized: "Food market")
        default: nil
        }
    }
}
