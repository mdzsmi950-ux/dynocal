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

    func rememberPlace(query: String, name: String, address: String, origin: PlaceOrigin) {
        let key = Self.normalized(query)
        profile.placePreferences.removeAll {
            Self.normalized($0.query) == key && $0.origin == origin
        }
        profile.placePreferences.append(
            PlacePreference(query: query, name: name, address: address, origin: origin)
        )
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
