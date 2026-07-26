//
//  TaskInterpreter.swift
//  Dynocal
//

import Foundation
import FoundationModels

struct InterpretedTaskDraft {
    let title: String
    let durationMinutes: Int
    let durationSource: TaskFactSource
    let startDate: Date?
    let category: TaskCategory
    let deadline: Date?
    let priority: TaskPriority
    let destinationQuery: String
    let placeRequirement: TaskPlaceRequirement
    let preferredTimeOfDay: String
    let isFixed: Bool
    let requiresBusinessHours: Bool
}

struct StatedDateRange: Equatable {
    let earliestStart: Date
    let deadline: Date
}

struct TaskTextConstraints {
    nonisolated static func dateRange(
        in text: String,
        now: Date,
        calendar: Calendar = .current
    ) -> StatedDateRange? {
        let monthPattern = "(january|february|march|april|may|june|july|august|september|october|november|december)"
        let pattern = "\\b\(monthPattern)\\s+(\\d{1,2})(?:st|nd|rd|th)?(?:,?\\s+(\\d{4}))?"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let fullRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: fullRange)
        guard matches.count >= 2 else { return nil }

        let startMatch = matches[matches.count - 2]
        let endMatch = matches[matches.count - 1]
        let bridgeRange = NSRange(
            location: startMatch.range.location + startMatch.range.length,
            length: endMatch.range.location - startMatch.range.location - startMatch.range.length
        )
        let bridge = (text as NSString).substring(with: bridgeRange)
        let bridgePattern = "\\b(to|through|until|thru)\\b|[-–—]"
        guard let bridgeRegex = try? NSRegularExpression(
            pattern: bridgePattern,
            options: [.caseInsensitive]
        ),
        bridgeRegex.firstMatch(
            in: bridge,
            range: NSRange(bridge.startIndex..., in: bridge)
        ) != nil else {
            return nil
        }

        guard let startParts = dateParts(from: startMatch, text: text),
              let endParts = dateParts(from: endMatch, text: text) else {
            return nil
        }

        let currentYear = calendar.component(.year, from: now)
        var startYear = startParts.year ?? currentYear
        var start = calendar.date(
            from: DateComponents(
                year: startYear,
                month: startParts.month,
                day: startParts.day,
                hour: 9
            )
        )

        if startParts.year == nil,
           let candidate = start,
           candidate < calendar.startOfDay(for: now) {
            startYear += 1
            start = calendar.date(
                from: DateComponents(
                    year: startYear,
                    month: startParts.month,
                    day: startParts.day,
                    hour: 9
                )
            )
        }

        var endYear = endParts.year ?? startYear
        var end = calendar.date(
            from: DateComponents(
                year: endYear,
                month: endParts.month,
                day: endParts.day,
                hour: 23,
                minute: 59
            )
        )

        if endParts.year == nil,
           let start,
           let candidate = end,
           candidate < start {
            endYear += 1
            end = calendar.date(
                from: DateComponents(
                    year: endYear,
                    month: endParts.month,
                    day: endParts.day,
                    hour: 23,
                    minute: 59
                )
            )
        }

        guard let start, let end, end >= start else { return nil }
        return StatedDateRange(earliestStart: start, deadline: end)
    }

    nonisolated static func hasExplicitTimeOfDay(in text: String) -> Bool {
        text.range(
            of: #"(?i)\b(morning|afternoon|evening|night|noon|midnight|a\.?m\.?|p\.?m\.?)\b"#,
            options: .regularExpression
        ) != nil
    }

    private nonisolated static func dateParts(
        from match: NSTextCheckingResult,
        text: String
    ) -> (month: Int, day: Int, year: Int?)? {
        let source = text as NSString
        let monthName = source.substring(with: match.range(at: 1)).lowercased()
        let monthNames = [
            "january", "february", "march", "april", "may", "june",
            "july", "august", "september", "october", "november", "december"
        ]
        guard let monthIndex = monthNames.firstIndex(of: monthName),
              let day = Int(source.substring(with: match.range(at: 2))),
              (1...31).contains(day) else {
            return nil
        }

        let yearRange = match.range(at: 3)
        let year = yearRange.location == NSNotFound
            ? nil
            : Int(source.substring(with: yearRange))
        return (monthIndex + 1, day, year)
    }
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
    @Guide(description: "A two-to-four-word action title. Exclude dates, times, duration, explanations, and location unless essential.")
    var title: String

    @Guide(description: "Estimated task duration in minutes.", .range(5...480))
    var durationMinutes: Int

    @Guide(description: "Earliest allowed start as ISO 8601 with the supplied time-zone offset. Never place a not-before date on the prior calendar day. Empty when there is no timing clue.")
    var earliestStartISO8601: String

    @Guide(description: "Deadline as ISO 8601 with time zone. The end of a sale, availability window, submission window, or phrase like 'by/until' is a deadline. For a date-only last day, use 23:59 local time. Empty only when no reliable deadline is stated or implied.")
    var deadlineISO8601: String

    var category: GeneratedTaskCategory
    var priority: GeneratedTaskPriority

    @Guide(description: "Place or business name from the request, or an empty string.")
    var location: String

    @Guide(description: "True only when the task must happen at a physical destination. False for thinking, calling, writing, emailing, online work, or anything that can be done anywhere.")
    var requiresDestination: Bool

    var preferredTimeOfDay: GeneratedTimeOfDay

    @Guide(description: "True only when the request indicates the exact time must not move.")
    var isFixed: Bool

    @Guide(description: "True when correct placement depends on current opening or closing hours that were not explicitly supplied.")
    var needsBusinessHoursLookup: Bool

    @Guide(description: "True only when the person explicitly supplied a duration.")
    var durationWasExplicit: Bool

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
            A phrase such as "after August 28 starts" is a hard not-before constraint, never August 27.
            A stated range such as "August 27 through September 17" means the task cannot start
            before August 27 and must be finished by the end of September 17.
            Never infer morning, afternoon, evening, or night unless the person explicitly says it.
            Keep the title to two-to-four words. Infer only what is reasonably supported by the request.
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
        let statedRange = TaskTextConstraints.dateRange(
            in: description,
            now: now
        )
        let location = details.location.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = map(details.category)
        let placeRequirement: TaskPlaceRequirement = details.requiresDestination
            || (!location.isEmpty && category == .errand)
            ? .destination
            : .anywhere

        return InterpretedTaskDraft(
            title: shortTitle(details.title),
            durationMinutes: details.durationMinutes,
            durationSource: details.durationWasExplicit ? .explicit : .modelInferred,
            startDate: statedRange?.earliestStart
                ?? parseISO8601(details.earliestStartISO8601),
            category: category,
            deadline: statedRange?.deadline
                ?? parseISO8601(details.deadlineISO8601),
            priority: map(details.priority),
            destinationQuery: location,
            placeRequirement: placeRequirement,
            preferredTimeOfDay: TaskTextConstraints.hasExplicitTimeOfDay(in: description)
                ? label(details.preferredTimeOfDay)
                : "",
            isFixed: details.isFixed,
            requiresBusinessHours: details.needsBusinessHoursLookup
        )
    }

    private func shortTitle(_ value: String) -> String {
        value
            .split(whereSeparator: \.isWhitespace)
            .prefix(4)
            .joined(separator: " ")
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
        case .none: .medium
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
