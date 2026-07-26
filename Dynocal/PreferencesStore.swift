import Combine
import Foundation
import SwiftUI

enum PlaceOrigin: String, Codable, CaseIterable, Identifiable {
    case home = "Home"
    case work = "Work"
    case either = "Anywhere"

    var id: Self { self }
}

struct PlacePreference: Codable, Identifiable, Hashable {
    var id = UUID()
    var query: String
    var name: String
    var address: String
    var origin: PlaceOrigin
    var placeID: String?
    var latitude: Double?
    var longitude: Double?
    var weeklyHours: [PlaceDayHours]
    var hoursLastVerified: Date?

    init(
        id: UUID = UUID(),
        query: String,
        name: String,
        address: String,
        origin: PlaceOrigin,
        placeID: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        weeklyHours: [PlaceDayHours] = []
    ) {
        self.id = id
        self.query = query
        self.name = name
        self.address = address
        self.origin = origin
        self.placeID = placeID
        self.latitude = latitude
        self.longitude = longitude
        self.weeklyHours = weeklyHours
        hoursLastVerified = weeklyHours.isEmpty ? nil : Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case query
        case name
        case address
        case origin
        case placeID
        case latitude
        case longitude
        case weeklyHours
        case hoursLastVerified
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        query = try container.decode(String.self, forKey: .query)
        name = try container.decode(String.self, forKey: .name)
        address = try container.decode(String.self, forKey: .address)
        origin = try container.decode(PlaceOrigin.self, forKey: .origin)
        placeID = try container.decodeIfPresent(String.self, forKey: .placeID)
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
        weeklyHours = try container.decodeIfPresent(
            [PlaceDayHours].self,
            forKey: .weeklyHours
        ) ?? []
        hoursLastVerified = try container.decodeIfPresent(
            Date.self,
            forKey: .hoursLastVerified
        )
    }
}

struct PlaceDayHours: Codable, Identifiable, Hashable {
    var weekday: Int
    var opensAtMinutes: Int
    var closesAtMinutes: Int

    var id: Int { weekday }

    static var standardWeek: [PlaceDayHours] {
        (1...7).map {
            PlaceDayHours(
                weekday: $0,
                opensAtMinutes: 9 * 60,
                closesAtMinutes: 20 * 60
            )
        }
    }

    nonisolated func contains(
        start: Date,
        end: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard calendar.component(.weekday, from: start) == weekday,
              calendar.isDate(start, inSameDayAs: end) else {
            return false
        }

        let startComponents = calendar.dateComponents([.hour, .minute], from: start)
        let endComponents = calendar.dateComponents([.hour, .minute], from: end)
        let startMinutes = (startComponents.hour ?? 0) * 60 + (startComponents.minute ?? 0)
        let endMinutes = (endComponents.hour ?? 0) * 60 + (endComponents.minute ?? 0)
        return startMinutes >= opensAtMinutes && endMinutes <= closesAtMinutes
    }
}

struct LifestyleProfile: Codable, Equatable {
    var completedOnboarding = false
    var lifestyleDescription = ""
    var homeAddress = ""
    var workAddress = ""
    var workDays = [2, 3, 4, 5, 6]
    var workStartMinutes = 9 * 60
    var workEndMinutes = 17 * 60
    var sleepStartMinutes = 23 * 60
    var sleepEndMinutes = 7 * 60
    var protectWorkHours = true
    var protectSleep = true
    var usesHealthSleep = false
    var placePreferences: [PlacePreference] = []

    nonisolated func expectedOrigin(
        at date: Date,
        calendar: Calendar = .current,
        afterWorkDepartureWindowMinutes: Int = 90
    ) -> PlaceOrigin {
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = components.weekday,
              let hour = components.hour,
              let minute = components.minute,
              protectWorkHours,
              workDays.contains(weekday) else {
            return .home
        }

        let minutes = hour * 60 + minute
        let latestWorkDeparture = min(
            workEndMinutes + afterWorkDepartureWindowMinutes,
            24 * 60 - 1
        )

        return (workStartMinutes...latestWorkDeparture).contains(minutes)
            ? .work
            : .home
    }
}

@MainActor
final class PreferencesStore: ObservableObject {
    static let shared = PreferencesStore()

    @Published var profile: LifestyleProfile {
        didSet { save() }
    }

    private let defaults: UserDefaults
    private let storageKey = "dynocal.lifestyleProfile.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: storageKey),
           let profile = try? JSONDecoder().decode(LifestyleProfile.self, from: data) {
            self.profile = profile
        } else {
            profile = LifestyleProfile()
        }
    }

    func preferredPlace(for query: String, origin: PlaceOrigin) -> PlacePreference? {
        let key = Self.normalized(query)
        return profile.placePreferences.first {
            Self.normalized($0.query) == key && ($0.origin == origin || $0.origin == .either)
        }
    }

    func rememberPlace(
        query: String,
        name: String,
        address: String,
        origin: PlaceOrigin,
        placeID: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        let key = Self.normalized(query)
        let addressKey = Self.normalized(address)
        let existing = profile.placePreferences.first {
            (Self.normalized($0.query) == key && $0.origin == origin)
                || (placeID != nil && $0.placeID == placeID)
                || Self.normalized($0.address) == addressKey
        }
        profile.placePreferences.removeAll {
            Self.normalized($0.query) == key && $0.origin == origin
        }
        profile.placePreferences.append(
            PlacePreference(
                query: query,
                name: name,
                address: address,
                origin: origin,
                placeID: placeID,
                latitude: latitude,
                longitude: longitude,
                weeklyHours: existing?.weeklyHours ?? []
            )
        )
    }

    func place(matching destination: String) -> PlacePreference? {
        let key = Self.normalized(destination)
        return profile.placePreferences.first {
            Self.normalized($0.address) == key
                || Self.normalized("\($0.name), \($0.address)") == key
        }
    }

    func updatePlace(_ place: PlacePreference) {
        let addressKey = Self.normalized(place.address)
        var updated = profile
        for index in updated.placePreferences.indices {
            let candidate = updated.placePreferences[index]
            let isSamePlace = candidate.id == place.id
                || (place.placeID != nil && candidate.placeID == place.placeID)
                || Self.normalized(candidate.address) == addressKey
            guard isSamePlace else { continue }

            updated.placePreferences[index].weeklyHours = place.weeklyHours
            updated.placePreferences[index].hoursLastVerified = place.hoursLastVerified
        }
        profile = updated
    }

    func removePlaces(at offsets: IndexSet) {
        profile.placePreferences.remove(atOffsets: offsets)
    }

    nonisolated static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
