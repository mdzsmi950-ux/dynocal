import Foundation
import MapKit

@MainActor
final class TravelTimeService {
    static let shared = TravelTimeService()

    private var mapItemCache: [String: MKMapItem] = [:]
    private var routeCache: [RouteKey: Int] = [:]
    private var unresolvedQueries: [String: Date] = [:]
    private var failedRoutePairs: [RoutePair: Date] = [:]
    private let failureRetryDelay: TimeInterval = 15

    private init() {}

    func beginSchedulingAttempt() {
        unresolvedQueries.removeAll()
        failedRoutePairs.removeAll()
    }

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
            timeBucket: Int(departureDate.timeIntervalSince1970 / (30 * 60)),
            travelMode: PreferencesStore.shared.profile.effectiveTravelMode
        )
        if let cached = routeCache[key] {
            return cached
        }
        let pair = RoutePair(
            origin: key.origin,
            destination: key.destination,
            travelMode: key.travelMode
        )
        if let failedAt = failedRoutePairs[pair],
           Date().timeIntervalSince(failedAt) < failureRetryDelay {
            return nil
        }
        failedRoutePairs.removeValue(forKey: pair)

        let request = MKDirections.Request()
        request.source = source
        request.destination = target
        request.transportType = key.travelMode.mapKitTransportType
        request.departureDate = departureDate

        do {
            let response = try await MKDirections(request: request).calculateETA()
            let roundedMinutes = max(
                5,
                Int(ceil(response.expectedTravelTime / (5 * 60))) * 5
            )
            routeCache[key] = roundedMinutes
            failedRoutePairs.removeValue(forKey: pair)
            return roundedMinutes
        } catch {
            failedRoutePairs[pair] = Date()
            return nil
        }
    }

    private func mapItem(for query: String) async -> MKMapItem? {
        let key = PreferencesStore.normalized(query)
        if let cached = mapItemCache[key] {
            return cached
        }
        if let failedAt = unresolvedQueries[key],
           Date().timeIntervalSince(failedAt) < failureRetryDelay {
            return nil
        }
        unresolvedQueries.removeValue(forKey: key)

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
            unresolvedQueries[key] = Date()
            return nil
        }
        mapItemCache[key] = item
        unresolvedQueries.removeValue(forKey: key)
        return item
    }
}

private struct RouteKey: Hashable {
    let origin: String
    let destination: String
    let timeBucket: Int
    let travelMode: TravelMode
}

private struct RoutePair: Hashable {
    let origin: String
    let destination: String
    let travelMode: TravelMode
}

private extension TravelMode {
    var mapKitTransportType: MKDirectionsTransportType {
        switch self {
        case .driving: .automobile
        case .walking: .walking
        case .transit: .transit
        }
    }
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
