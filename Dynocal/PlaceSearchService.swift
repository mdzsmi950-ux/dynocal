import Combine
import MapKit

struct PlaceCandidate: Identifiable, Hashable {
    let id: String
    let name: String
    let address: String
}

@MainActor
final class PlaceSearchService: ObservableObject {
    private let searchRadiusMeters: CLLocationDistance = 20 * 1_609.344

    @Published private(set) var results: [PlaceCandidate] = []
    @Published private(set) var isSearching = false
    @Published private(set) var message: String?

    func search(_ query: String, near origin: String) async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }

        isSearching = true
        message = nil

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmedQuery
        request.resultTypes = .pointOfInterest

        do {
            if let originCoordinate = await coordinate(for: origin) {
                request.region = MKCoordinateRegion(
                    center: originCoordinate,
                    latitudinalMeters: searchRadiusMeters * 2,
                    longitudinalMeters: searchRadiusMeters * 2
                )
            }

            let response = try await MKLocalSearch(request: request).start()
            var seen = Set<String>()

            results = response.mapItems.compactMap { item in
                if let originCoordinate = request.region.center.nonZeroCoordinate {
                    let originLocation = CLLocation(
                        latitude: originCoordinate.latitude,
                        longitude: originCoordinate.longitude
                    )
                    let resultLocation = CLLocation(
                        latitude: item.location.coordinate.latitude,
                        longitude: item.location.coordinate.longitude
                    )
                    guard resultLocation.distance(from: originLocation) <= searchRadiusMeters else {
                        return nil
                    }
                }

                let name = item.name ?? trimmedQuery
                let address = item.address?.fullAddress
                    ?? ""
                let key = "\(name)|\(address)"
                guard seen.insert(key).inserted else { return nil }
                return PlaceCandidate(id: key, name: name, address: address)
            }
            .prefix(5)
            .map { $0 }

            if results.isEmpty {
                message = "No nearby matches found. Enter a location manually."
            }
        } catch {
            results = []
            message = "Couldn’t search locations: \(error.localizedDescription)"
        }

        isSearching = false
    }

    private func coordinate(for address: String) async -> CLLocationCoordinate2D? {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else { return nil }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmedAddress
        request.resultTypes = [.address, .pointOfInterest]

        return try? await MKLocalSearch(request: request)
            .start()
            .mapItems
            .first?
            .location
            .coordinate
    }
}

private extension CLLocationCoordinate2D {
    var nonZeroCoordinate: CLLocationCoordinate2D? {
        latitude == 0 && longitude == 0 ? nil : self
    }
}
