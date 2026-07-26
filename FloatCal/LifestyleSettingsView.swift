import SwiftUI

struct LifestyleSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var preferences: PreferencesStore
    @StateObject private var sleepService = SleepScheduleService()
    @State private var isInterpretingLifestyle = false
    @State private var lifestyleMessage: String?

    let isOnboarding: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("What does a normal week look like?")
                        .font(.headline)

                    ZStack(alignment: .topLeading) {
                        if preferences.profile.lifestyleDescription.isEmpty {
                            Text("For example: I work Monday through Friday from 9 to 5. I usually run errands after work and keep weekends flexible.")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }

                        TextEditor(text: profileBinding(\.lifestyleDescription))
                            .frame(minHeight: 110)
                            .scrollContentBackground(.hidden)
                    }

                    if LifestyleInterpreter.shared.isAvailable {
                        Button {
                            interpretLifestyle()
                        } label: {
                            Label(
                                isInterpretingLifestyle ? "Understanding…" : "Fill My Routine",
                                systemImage: "apple.intelligence"
                            )
                        }
                        .disabled(
                            preferences.profile.lifestyleDescription
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty || isInterpretingLifestyle
                        )
                    }

                    if let lifestyleMessage {
                        Text(lifestyleMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("FloatCal keeps this profile on your device and uses it to avoid times that don’t fit your life.")
                }

                Section("Work") {
                    weekdayPicker
                    DatePicker("Starts", selection: timeBinding(\.workStartMinutes), displayedComponents: .hourAndMinute)
                    DatePicker("Ends", selection: timeBinding(\.workEndMinutes), displayedComponents: .hourAndMinute)

                    Toggle(
                        "Keep non-work tasks outside these hours",
                        isOn: profileBinding(\.protectWorkHours)
                    )

                    TextField("Work address", text: profileBinding(\.workAddress))
                        .textContentType(.fullStreetAddress)

                    if preferences.profile.workAddress
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Travel time from work cannot be accounted for until this is added.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("Home & Sleep") {
                    TextField("Home address", text: profileBinding(\.homeAddress))
                        .textContentType(.fullStreetAddress)

                    if preferences.profile.homeAddress
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Travel time from home cannot be accounted for until this is added.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Toggle("Protect sleep", isOn: profileBinding(\.protectSleep))

                    if preferences.profile.protectSleep {
                        DatePicker("Usually asleep", selection: timeBinding(\.sleepStartMinutes), displayedComponents: .hourAndMinute)
                        DatePicker("Usually awake", selection: timeBinding(\.sleepEndMinutes), displayedComponents: .hourAndMinute)

                        Button {
                            Task {
                                if let window = await sleepService.updateSleepWindow() {
                                    preferences.profile.sleepStartMinutes = window.start
                                    preferences.profile.sleepEndMinutes = window.end
                                    preferences.profile.usesHealthSleep = true
                                }
                            }
                        } label: {
                            Label(
                                sleepService.isLoading ? "Reading Sleep…" : "Use Sleep from Apple Health",
                                systemImage: "heart.fill"
                            )
                        }
                        .disabled(sleepService.isLoading)

                        if preferences.profile.usesHealthSleep {
                            Button("Use Manual Sleep Schedule", role: .destructive) {
                                preferences.profile.usesHealthSleep = false
                            }
                        }

                        if let message = sleepService.message {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Picker("Usual Travel Mode", selection: travelModeBinding) {
                        ForEach(TravelMode.allCases) { mode in
                            Label(mode.rawValue, systemImage: mode.systemImage)
                                .tag(mode)
                        }
                    }
                } header: {
                    Text("Travel")
                } footer: {
                    Text("FloatCal uses this mode when calculating travel time for destination tasks.")
                }

                if !isOnboarding {
                    Section("Remembered Places") {
                        if preferences.profile.placePreferences.isEmpty {
                            Text("Stores you choose during task clarification will appear here.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(preferences.profile.placePreferences) { place in
                                NavigationLink {
                                    PlaceHoursEditorView(place: place)
                                        .environmentObject(preferences)
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(place.name)
                                        Text("\(place.origin.rawValue) · \(place.address)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)

                                        Text(
                                            place.weeklyHours.isEmpty
                                                ? "Hours not saved"
                                                : "Hours saved · \(place.hoursLastVerified?.formatted(date: .abbreviated, time: .omitted) ?? "review needed")"
                                        )
                                        .font(.caption2)
                                        .foregroundStyle(
                                            place.weeklyHours.isEmpty ? .orange : .secondary
                                        )
                                    }
                                }
                            }
                            .onDelete(perform: preferences.removePlaces)
                        }
                    }

                    Section("Privacy & About") {
                        NavigationLink {
                            PrivacyPolicyView()
                        } label: {
                            Label("Privacy Policy", systemImage: "hand.raised")
                        }

                        LabeledContent("Version", value: appVersion)
                    }
                }
            }
            .navigationTitle(isOnboarding ? "Make FloatCal Yours" : "Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isOnboarding {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(isOnboarding ? "Get Started" : "Done") {
                        preferences.profile.completedOnboarding = true
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "1.0"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var weekdayPicker: some View {
        HStack {
            ForEach(Array(Calendar.current.shortWeekdaySymbols.enumerated()), id: \.offset) { index, symbol in
                let weekday = index + 1
                Button {
                    var days = preferences.profile.workDays
                    if let existing = days.firstIndex(of: weekday) {
                        days.remove(at: existing)
                    } else {
                        days.append(weekday)
                    }
                    preferences.profile.workDays = days.sorted()
                } label: {
                    Text(String(symbol.prefix(1)))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            preferences.profile.workDays.contains(weekday)
                                ? Color.accentColor
                                : Color.secondary.opacity(0.13),
                            in: Circle()
                        )
                        .foregroundStyle(
                            preferences.profile.workDays.contains(weekday) ? .white : .primary
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func profileBinding<Value>(_ keyPath: WritableKeyPath<LifestyleProfile, Value>) -> Binding<Value> {
        Binding(
            get: { preferences.profile[keyPath: keyPath] },
            set: { preferences.profile[keyPath: keyPath] = $0 }
        )
    }

    private var travelModeBinding: Binding<TravelMode> {
        Binding(
            get: { preferences.profile.effectiveTravelMode },
            set: { preferences.profile.travelMode = $0 }
        )
    }

    private func timeBinding(_ keyPath: WritableKeyPath<LifestyleProfile, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minutes = preferences.profile[keyPath: keyPath]
                return Calendar.current.date(
                    bySettingHour: minutes / 60,
                    minute: minutes % 60,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: {
                let components = Calendar.current.dateComponents([.hour, .minute], from: $0)
                preferences.profile[keyPath: keyPath] = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        )
    }

    private func interpretLifestyle() {
        let description = preferences.profile.lifestyleDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { return }

        isInterpretingLifestyle = true
        lifestyleMessage = nil

        Task {
            do {
                let result = try await LifestyleInterpreter.shared.interpret(description)

                if result.mentionsWork {
                    preferences.profile.protectWorkHours = true
                    preferences.profile.workDays = result.workDays.sorted()
                    preferences.profile.workStartMinutes = result.workStartMinutes
                    preferences.profile.workEndMinutes = result.workEndMinutes
                }

                if result.mentionsSleep {
                    preferences.profile.protectSleep = true
                    preferences.profile.sleepStartMinutes = result.sleepStartMinutes
                    preferences.profile.sleepEndMinutes = result.sleepEndMinutes
                }

                lifestyleMessage = "Routine filled. Review the times below before continuing."
            } catch {
                lifestyleMessage = "Couldn’t fill the routine: \(error.localizedDescription)"
            }

            isInterpretingLifestyle = false
        }
    }
}
