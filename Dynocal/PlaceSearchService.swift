import Combine
import MapKit

struct PlaceCandidate: Identifiable, Hashable {
    let id: String
    let name: String
    let address: String
}

@MainActor
final class PlaceSearchService: ObservableObject {
    @Published private(set) var results: [PlaceCandidate] = []
    @Published private(set) var isSearching = false
    @Published private(set) var message: String?

    func search(_ query: String, near origin: String) async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }

        isSearching = true
        message = nil

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = origin.isEmpty
            ? trimmedQuery
            : "\(trimmedQuery) near \(origin)"
        request.resultTypes = .pointOfInterest

        do {
            let response = try await MKLocalSearch(request: request).start()
            var seen = Set<String>()

            results = response.mapItems.compactMap { item in
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
}
