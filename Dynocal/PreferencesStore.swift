import Combine
import Foundation
import SwiftUI

enum PlaceOrigin: String, Codable, CaseIterable, Identifiable {
    case home = "Home"
    case work = "Work"
    case either = "Anywhere"

    var id: Self { self }
}

enum TravelMode: String, Codable, CaseIterable, Identifiable {
    case driving = "Driving"
    case walking = "Walking"
    case transit = "Transit"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .driving: "car.fill"
        case .walking: "figure.walk"
        case .transit: "bus.fill"
        }
    }
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
    var id: UUID
    var weekday: Int
    var opensAtMinutes: Int
    var closesAtMinutes: Int
    var isOpen24Hours: Bool

    init(
        id: UUID = UUID(),
        weekday: Int,
        opensAtMinutes: Int,
        closesAtMinutes: Int,
        isOpen24Hours: Bool = false
    ) {
        self.id = id
        self.weekday = weekday
        self.opensAtMinutes = opensAtMinutes
        self.closesAtMinutes = closesAtMinutes
        self.isOpen24Hours = isOpen24Hours
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case weekday
        case opensAtMinutes
        case closesAtMinutes
        case isOpen24Hours
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        weekday = try container.decode(Int.self, forKey: .weekday)
        opensAtMinutes = try container.decode(Int.self, forKey: .opensAtMinutes)
        closesAtMinutes = try container.decode(Int.self, forKey: .closesAtMinutes)
        isOpen24Hours = try container.decodeIfPresent(
            Bool.self,
            forKey: .isOpen24Hours
        ) ?? false
    }

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
        let startDay = calendar.startOfDay(for: start)
        let previousDay = calendar.date(byAdding: .day, value: -1, to: startDay)
            ?? startDay
        let openingDay: Date

        if calendar.component(.weekday, from: startDay) == weekday {
            openingDay = startDay
        } else if calendar.component(.weekday, from: previousDay) == weekday {
            openingDay = previousDay
        } else {
            return false
        }

        guard let opening = calendar.date(
            byAdding: .minute,
            value: isOpen24Hours ? 0 : opensAtMinutes,
            to: openingDay
        ) else {
            return false
        }

        let closing: Date?
        if isOpen24Hours {
            closing = calendar.date(byAdding: .day, value: 1, to: opening)
        } else {
            let closingDay = closesAtMinutes <= opensAtMinutes
                ? calendar.date(byAdding: .day, value: 1, to: openingDay) ?? openingDay
                : openingDay
            closing = calendar.date(
                byAdding: .minute,
                value: closesAtMinutes,
                to: closingDay
            )
        }

        guard let closing else { return false }
        return start >= opening && end <= closing
    }

    nonisolated static func contains(
        _ hours: [PlaceDayHours],
        start: Date,
        end: Date,
        calendar: Calendar = .current
    ) -> Bool {
        hours.contains { $0.contains(start: start, end: end, calendar: calendar) }
    }

    nonisolated static func nextOpening(
        after date: Date,
        in hours: [PlaceDayHours],
        calendar: Calendar = .current
    ) -> Date? {
        let startDay = calendar.startOfDay(for: date)
        var openings: [Date] = []

        for dayOffset in 0...7 {
            guard let day = calendar.date(
                byAdding: .day,
                value: dayOffset,
                to: startDay
            ) else {
                continue
            }
            let weekday = calendar.component(.weekday, from: day)
            for interval in hours where interval.weekday == weekday {
                guard let opening = calendar.date(
                    byAdding: .minute,
                    value: interval.isOpen24Hours ? 0 : interval.opensAtMinutes,
                    to: day
                ), opening > date else {
                    continue
                }
                openings.append(opening)
            }
        }

        return openings.min()
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
    var travelMode: TravelMode? = .driving
    var placePreferences: [PlacePreference] = []

    var effectiveTravelMode: TravelMode {
        travelMode ?? .driving
    }

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
