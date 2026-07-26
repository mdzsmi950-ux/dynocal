import SwiftUI

struct PlaceHoursEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var preferences: PreferencesStore
    @State private var draft: PlacePreference

    init(place: PlacePreference) {
        _draft = State(initialValue: place)
    }

    var body: some View {
        Form {
            Section {
                Text(draft.address)
                    .foregroundStyle(.secondary)

                if let lastChecked = draft.hoursLastVerified {
                    LabeledContent(
                        "Last checked",
                        value: lastChecked.formatted(date: .abbreviated, time: .omitted)
                    )
                }
            }

            Section {
                ForEach(1...7, id: \.self) { weekday in
                    dayRow(weekday)
                }
            } header: {
                Text("Weekly Hours")
            } footer: {
                Text("MapKit does not provide structured store hours. Review these against the business listing, then save them for future tasks.")
            }

            Section {
                Button {
                    openListingInMaps()
                } label: {
                    Label("Recheck Hours in Apple Maps", systemImage: "map")
                }

                if draft.weeklyHours.isEmpty {
                    Button("Use 9 AM–8 PM as a Starting Point") {
                        draft.weeklyHours = PlaceDayHours.standardWeek
                    }
                }
            } footer: {
                Text("Apple Maps is the reference. Dynocal saves only the hours you confirm here.")
            }
        }
        .navigationTitle(draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    draft.weeklyHours.sort { $0.weekday < $1.weekday }
                    draft.hoursLastVerified = Date()
                    preferences.updatePlace(draft)
                    dismiss()
                }
                .fontWeight(.semibold)
            }
        }
    }

    @ViewBuilder
    private func dayRow(_ weekday: Int) -> some View {
        let isOpen = draft.weeklyHours.contains { $0.weekday == weekday }

        DisclosureGroup {
            if isOpen {
                DatePicker(
                    "Opens",
                    selection: hoursBinding(for: weekday, keyPath: \.opensAtMinutes),
                    displayedComponents: .hourAndMinute
                )
                DatePicker(
                    "Closes",
                    selection: hoursBinding(for: weekday, keyPath: \.closesAtMinutes),
                    displayedComponents: .hourAndMinute
                )
            }
        } label: {
            Toggle(
                Calendar.current.weekdaySymbols[weekday - 1],
                isOn: openBinding(for: weekday)
            )
        }
    }

    private func openBinding(for weekday: Int) -> Binding<Bool> {
        Binding(
            get: {
                draft.weeklyHours.contains { $0.weekday == weekday }
            },
            set: { isOpen in
                if isOpen {
                    guard !draft.weeklyHours.contains(where: { $0.weekday == weekday }) else {
                        return
                    }
                    draft.weeklyHours.append(
                        PlaceDayHours(
                            weekday: weekday,
                            opensAtMinutes: 9 * 60,
                            closesAtMinutes: 20 * 60
                        )
                    )
                } else {
                    draft.weeklyHours.removeAll { $0.weekday == weekday }
                }
            }
        )
    }

    private func hoursBinding(
        for weekday: Int,
        keyPath: WritableKeyPath<PlaceDayHours, Int>
    ) -> Binding<Date> {
        Binding(
            get: {
                let minutes = draft.weeklyHours
                    .first(where: { $0.weekday == weekday })?[keyPath: keyPath]
                    ?? 9 * 60
                return Calendar.current.date(
                    bySettingHour: minutes / 60,
                    minute: minutes % 60,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { date in
                guard let index = draft.weeklyHours.firstIndex(where: {
                    $0.weekday == weekday
                }) else {
                    return
                }
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                draft.weeklyHours[index][keyPath: keyPath] =
                    (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        )
    }

    private func openListingInMaps() {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "q", value: "\(draft.name), \(draft.address)")
        ]
        if let url = components?.url {
            openURL(url)
        }
    }
}
