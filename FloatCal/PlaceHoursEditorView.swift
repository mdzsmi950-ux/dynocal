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
                Text("Add split hours separately. A closing time earlier than opening means the place closes after midnight. MapKit does not provide structured store hours, so review these against the business listing.")
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
                Text("Apple Maps is the reference. FloatCal saves only the hours you confirm here.")
            }
        }
        .navigationTitle(draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    draft.weeklyHours.sort {
                        $0.weekday == $1.weekday
                            ? $0.opensAtMinutes < $1.opensAtMinutes
                            : $0.weekday < $1.weekday
                    }
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
        let intervals = draft.weeklyHours.filter { $0.weekday == weekday }

        DisclosureGroup {
            ForEach(intervals) { interval in
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        "Open 24 Hours",
                        isOn: intervalBinding(
                            id: interval.id,
                            keyPath: \.isOpen24Hours
                        )
                    )

                    if !interval.isOpen24Hours {
                        DatePicker(
                            "Opens",
                            selection: hoursBinding(
                                id: interval.id,
                                keyPath: \.opensAtMinutes
                            ),
                            displayedComponents: .hourAndMinute
                        )
                        DatePicker(
                            "Closes",
                            selection: hoursBinding(
                                id: interval.id,
                                keyPath: \.closesAtMinutes
                            ),
                            displayedComponents: .hourAndMinute
                        )
                    }

                    if intervals.count > 1 {
                        Button("Remove These Hours", role: .destructive) {
                            draft.weeklyHours.removeAll { $0.id == interval.id }
                        }
                    }
                }
            }

            if !intervals.isEmpty {
                Button {
                    draft.weeklyHours.append(
                        PlaceDayHours(
                            weekday: weekday,
                            opensAtMinutes: 17 * 60,
                            closesAtMinutes: 20 * 60
                        )
                    )
                } label: {
                    Label("Add Another Open Interval", systemImage: "plus")
                }
            }
        } label: {
            Toggle(
                Calendar.current.weekdaySymbols[weekday - 1],
                isOn: dayOpenBinding(for: weekday)
            )
        }
    }

    private func dayOpenBinding(for weekday: Int) -> Binding<Bool> {
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
        id: UUID,
        keyPath: WritableKeyPath<PlaceDayHours, Int>
    ) -> Binding<Date> {
        Binding(
            get: {
                let minutes = draft.weeklyHours
                    .first(where: { $0.id == id })?[keyPath: keyPath]
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
                    $0.id == id
                }) else {
                    return
                }
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                draft.weeklyHours[index][keyPath: keyPath] =
                    (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        )
    }

    private func intervalBinding<Value>(
        id: UUID,
        keyPath: WritableKeyPath<PlaceDayHours, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                guard let interval = draft.weeklyHours.first(where: { $0.id == id }) else {
                    preconditionFailure("Missing place-hours interval")
                }
                return interval[keyPath: keyPath]
            },
            set: { value in
                guard let index = draft.weeklyHours.firstIndex(where: { $0.id == id }) else {
                    return
                }
                draft.weeklyHours[index][keyPath: keyPath] = value
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
