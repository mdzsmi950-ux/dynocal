import SwiftUI

struct PrivacyPolicyView: View {
    var body: some View {
        List {
            Section {
                Text("Effective July 25, 2026")
                    .foregroundStyle(.secondary)

                Text("FloatCal is designed to process your scheduling information on your device. FloatCal has no developer-operated account system, advertising, analytics, or backend server.")
            }

            policySection(
                "Calendar",
                "With your permission, FloatCal reads events from your calendars to find available time and understand scheduling context. FloatCal creates and edits only events that it identifies as FloatCal tasks. Other calendar events remain read-only."
            )

            policySection(
                "Tasks and Preferences",
                "Task descriptions, completed-task history, lifestyle settings, Home and Work addresses, and remembered places are stored on your device or in the calendar account you choose through Apple Calendar. They are not sent to the FloatCal developer."
            )

            policySection(
                "Apple Intelligence",
                "On supported devices, FloatCal uses Apple’s on-device Foundation Models framework to interpret task and lifestyle descriptions. FloatCal does not send this text to a developer-operated server."
            )

            policySection(
                "Speech and Maps",
                "Voice input uses Apple Speech Recognition, and place search uses Apple MapKit. Apple may process requests according to Apple’s privacy policy and your device settings. FloatCal does not request continuous or precise device location."
            )

            policySection(
                "Apple Health",
                "If you choose Use Sleep from Apple Health, FloatCal reads recent sleep intervals to derive a typical sleep window. FloatCal stores only that derived schedule in its preferences, does not write Health data, and does not share Health data with the developer or third parties."
            )

            policySection(
                "Control and Deletion",
                "You can revoke Calendar, Speech Recognition, Microphone, and Health permissions in iOS Settings. You can delete FloatCal tasks and completed history in the app, remove remembered places in Settings, and edit lifestyle information at any time. Deleting the app removes its on-device preferences and history; calendar events already saved to an external calendar account may remain until you delete them in Apple Calendar."
            )

            policySection(
                "Tracking and Sharing",
                "FloatCal does not track you, sell personal information, serve advertisements, or share your information with the developer or data brokers."
            )

            Section("Questions") {
                Text("Use TestFlight’s Send Beta Feedback feature to contact the developer about privacy or data handling.")
            }
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func policySection(_ title: String, _ text: String) -> some View {
        Section(title) {
            Text(text)
        }
    }
}
