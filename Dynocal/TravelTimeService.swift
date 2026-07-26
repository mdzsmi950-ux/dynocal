import Foundation
import MapKit

@MainActor
final class TravelTimeService {
    static let shared = TravelTimeService()

    private var mapItemCache: [String: MKMapItem] = [:]
    private var routeCache: [RouteKey: Int] = [:]
    private var unresolvedQueries: Set<String> = []
    private var failedRoutePairs: Set<RoutePair> = []

    private init() {}

    func estimatedMinutes(
        from origin: SchedulingOrigin,
        to destination: String,
        departureDate: Date
    ) async -> Int? {
        guard let originText = origin.address,
              !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let source = await mapItem(for: originText),
              let target = await mapItem(for: destination) else {
            return nil
        }

        let key = RouteKey(
            origin: PreferencesStore.normalized(originText),
            destination: PreferencesStore.normalized(destination),
            timeBucket: Int(departureDate.timeIntervalSince1970 / (30 * 60))
        )
        if let cached = routeCache[key] {
            return cached
        }
        let pair = RoutePair(origin: key.origin, destination: key.destination)
        if failedRoutePairs.contains(pair) {
            return nil
        }

        let request = MKDirections.Request()
        request.source = source
        request.destination = target
        request.transportType = .automobile
        request.departureDate = departureDate

        do {
            let response = try await MKDirections(request: request).calculateETA()
            let roundedMinutes = max(
                5,
                Int(ceil(response.expectedTravelTime / (5 * 60))) * 5
            )
            routeCache[key] = roundedMinutes
            return roundedMinutes
        } catch {
            failedRoutePairs.insert(pair)
            return nil
        }
    }

    private func mapItem(for query: String) async -> MKMapItem? {
        let key = PreferencesStore.normalized(query)
        if let cached = mapItemCache[key] {
            return cached
        }
        if unresolvedQueries.contains(key) {
            return nil
        }

        if let savedPlace = PreferencesStore.shared.place(matching: query),
           let latitude = savedPlace.latitude,
           let longitude = savedPlace.longitude {
            let item = MKMapItem(
                location: CLLocation(latitude: latitude, longitude: longitude),
                address: nil
            )
            item.name = savedPlace.name
            mapItemCache[key] = item
            return item
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]

        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else {
            unresolvedQueries.insert(key)
            return nil
        }
        mapItemCache[key] = item
        return item
    }
}

private struct RouteKey: Hashable {
    let origin: String
    let destination: String
    let timeBucket: Int
}

private struct RoutePair: Hashable {
    let origin: String
    let destination: String
}

private extension SchedulingOrigin {
    var address: String? {
        switch self {
        case .calendarEvent(let address):
            address
        case .lifestyle(_, let address):
            address
        case .unknown:
            nil
        }
    }
}
