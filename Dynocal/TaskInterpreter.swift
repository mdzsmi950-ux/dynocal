//
//  TaskInterpreter.swift
//  Dynocal
//

import Foundation
import FoundationModels

struct InterpretedTaskDraft {
    let title: String
    let durationMinutes: Int
    let startDate: Date?
    let category: TaskCategory
    let travelTimeMinutes: Int
    let deadline: Date?
    let priority: TaskPriority
    let location: String
    let preferredTimeOfDay: String
    let isFixed: Bool
    let needsBusinessHoursLookup: Bool
}

enum TaskInterpreterAvailability: Equatable {
    case available
    case unavailable(String)
}

@Generable
private enum GeneratedTaskCategory {
    case none
    case errand
    case work
    case personal
    case health
}

@Generable
private enum GeneratedTaskPriority {
    case none
    case low
    case medium
    case high
}

@Generable
private enum GeneratedTimeOfDay {
    case none
    case morning
    case afternoon
    case evening
    case night
}

@Generable
private struct GeneratedTaskDetails {
    @Guide(description: "A concise task title containing only the action.")
    var title: String

    @Guide(description: "Estimated task duration in minutes.", .range(5...480))
    var durationMinutes: Int

    @Guide(description: "Recommended start as ISO 8601 with time zone, or an empty string when the request gives no timing clue.")
    var recommendedStartISO8601: String

    @Guide(description: "Deadline as ISO 8601 with time zone, or an empty string when no reliable deadline is stated or implied.")
    var deadlineISO8601: String

    var category: GeneratedTaskCategory
    var priority: GeneratedTaskPriority

    @Guide(description: "Travel time in minutes. Use zero when travel is not needed or cannot be inferred.", .range(0...240))
    var travelTimeMinutes: Int

    @Guide(description: "Place or business name from the request, or an empty string.")
    var location: String

    var preferredTimeOfDay: GeneratedTimeOfDay

    @Guide(description: "True only when the request indicates the exact time must not move.")
    var isFixed: Bool

    @Guide(description: "True when correct placement depends on current opening or closing hours that were not explicitly supplied.")
    var needsBusinessHoursLookup: Bool
}

final class TaskInterpreter {
    static let shared = TaskInterpreter()

    private init() {}

    var availability: TaskInterpreterAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable("Apple Intelligence isn’t supported on this device.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Turn on Apple Intelligence in Settings to fill task details automatically.")
        case .unavailable(.modelNotReady):
            return .unavailable("Apple Intelligence is still getting ready. Try again later.")
        @unknown default:
            return .unavailable("Apple Intelligence isn’t available right now.")
        }
    }

    func interpret(_ description: String, now: Date = Date()) async throws -> InterpretedTaskDraft {
        let timeZone = TimeZone.current
        let currentMoment = now.formatted(.iso8601.timeZone(separator: .colon))
        let session = LanguageModelSession(instructions: """
            Convert a person's task description into scheduling details for Dynocal.
            Use the supplied current date, time, and time zone to resolve relative phrases such as
            tomorrow, Monday evening, or before Tuesday.
            Do not invent live facts such as store hours. When placement depends on unknown current
            business hours, set needsBusinessHoursLookup to true and leave deadlineISO8601 empty.
            Keep the title short. Infer only what is reasonably supported by the request.
            """)

        let response = try await session.respond(
            to: """
                Current moment: \(currentMoment)
                Time zone identifier: \(timeZone.identifier)
                Task description: \(description)
                """,
            generating: GeneratedTaskDetails.self
        )

        let details = response.content

        return InterpretedTaskDraft(
            title: details.title,
            durationMinutes: details.durationMinutes,
            startDate: parseISO8601(details.recommendedStartISO8601),
            category: map(details.category),
            travelTimeMinutes: details.travelTimeMinutes,
            deadline: parseISO8601(details.deadlineISO8601),
            priority: map(details.priority),
            location: details.location,
            preferredTimeOfDay: label(details.preferredTimeOfDay),
            isFixed: details.isFixed,
            needsBusinessHoursLookup: details.needsBusinessHoursLookup
        )
    }

    private func parseISO8601(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        return try? Date(value, strategy: .iso8601)
    }

    private func map(_ value: GeneratedTaskCategory) -> TaskCategory {
        switch value {
        case .none: .none
        case .errand: .errand
        case .work: .work
        case .personal: .personal
        case .health: .health
        }
    }

    private func map(_ value: GeneratedTaskPriority) -> TaskPriority {
        switch value {
        case .none: .none
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
    }

    private func label(_ value: GeneratedTimeOfDay) -> String {
        switch value {
        case .none: ""
        case .morning: "Morning"
        case .afternoon: "Afternoon"
        case .evening: "Evening"
        case .night: "Night"
        }
    }
}
