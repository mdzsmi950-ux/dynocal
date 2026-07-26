//
//  TaskInterpreter.swift
//  FloatCal
//

import Foundation
import FoundationModels

nonisolated struct InterpretedTaskDraft {
    let title: String
    let durationMinutes: Int
    let durationSource: TaskFactSource
    let startDate: Date?
    let startSource: TaskFactSource
    let category: TaskCategory
    let deadline: Date?
    let deadlineSource: TaskFactSource
    let priority: TaskPriority
    let destinationQuery: String
    let placeRequirement: TaskPlaceRequirement
    let travelMode: TravelMode?
    let preferredTimeOfDay: String
    let isFixed: Bool
    let requiresBusinessHours: Bool
}

nonisolated struct StatedDateRange: Equatable {
    let earliestStart: Date
    let deadline: Date
}

nonisolated struct ExplicitTaskFacts: Equatable {
    var startDate: Date?
    var deadline: Date?
    var durationMinutes: Int?
    var priority: TaskPriority?
    var travelMode: TravelMode?
    var preferredTimeOfDay: String?
    var isFixed: Bool?
    var requiresBusinessHours = false
}

nonisolated struct TaskTextConstraints {
    nonisolated static func explicitFacts(
        in text: String,
        now: Date,
        calendar: Calendar = .current
    ) -> ExplicitTaskFacts {
        var facts = ExplicitTaskFacts()

        if let range = dateRange(in: text, now: now, calendar: calendar) {
            facts.startDate = range.earliestStart
            facts.deadline = range.deadline
        } else if let window = relativeDayWindow(
            in: text,
            now: now,
            calendar: calendar
        ) {
            facts.startDate = window.earliestStart
            facts.deadline = window.deadline
        }

        for detected in statedDates(in: text, now: now, calendar: calendar) {
            if detected.isDeadline {
                if facts.deadline == nil {
                    facts.deadline = detected.date
                }
            } else if facts.startDate == nil {
                facts.startDate = detected.date
            }
        }

        if let clockRange = taskClockRange(in: text),
           let day = statedDay(in: text, now: now, calendar: calendar),
           let start = date(on: day, clock: clockRange.start, calendar: calendar),
           var end = date(on: day, clock: clockRange.end, calendar: calendar) {
            if end <= start {
                end = calendar.date(byAdding: .day, value: 1, to: end) ?? end
            }
            facts.startDate = start
            facts.deadline = end
            facts.durationMinutes = max(
                1,
                Int(end.timeIntervalSince(start) / 60)
            )
            facts.isFixed = true
        } else if mentionsNamedCalendarDay(in: text),
                  !explicitlyAllowsReflow(in: text),
                  !mentionsEarliestConstraint(in: text),
                  (!mentionsDeadline(in: text)
                    || explicitlyPreventsReflow(in: text)
                    || impliesFixedCommitment(in: text)),
                  let clock = exactClock(in: text),
                  let day = statedDay(in: text, now: now, calendar: calendar),
                  let start = date(on: day, clock: clock, calendar: calendar) {
            facts.startDate = start
            facts.deadline = nil
            facts.isFixed = true
        }

        if facts.durationMinutes == nil {
            facts.durationMinutes = statedDuration(in: text)
        }

        facts.priority = statedPriority(in: text)
        facts.travelMode = statedTravelMode(in: text)
        facts.preferredTimeOfDay = statedPreferredTime(in: text)
        facts.requiresBusinessHours = mentionsBusinessHours(in: text)

        if explicitlyAllowsReflow(in: text) {
            facts.isFixed = false
        } else if explicitlyPreventsReflow(in: text)
                    || impliesFixedCommitment(in: text) {
            facts.isFixed = true
        }

        return facts
    }

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

        guard let start = resolvedMonthDay(
            month: startParts.month,
            day: startParts.day,
            explicitYear: startParts.year,
            clock: Clock(hour: 0, minute: 0),
            now: now,
            calendar: calendar
        ) else {
            return nil
        }
        let startYear = calendar.component(.year, from: start)
        var endYear = endParts.year ?? startYear
        var end = validatedDate(
            year: endYear,
            month: endParts.month,
            day: endParts.day,
            clock: Clock(hour: 23, minute: 59),
            calendar: calendar
        )

        if endParts.year == nil,
           let candidate = end,
           candidate < start {
            endYear += 1
            end = validatedDate(
                year: endYear,
                month: endParts.month,
                day: endParts.day,
                clock: Clock(hour: 23, minute: 59),
                calendar: calendar
            )
        }

        guard let end, end >= start else { return nil }
        return StatedDateRange(earliestStart: start, deadline: end)
    }

    nonisolated static func hasDeterministicCalendarReference(
        in text: String
    ) -> Bool {
        text.range(
            of: #"(?i)\b(today|tomorrow|tonight|monday|tuesday|wednesday|thursday|friday|saturday|sunday|january|february|march|april|may|june|july|august|september|october|november|december)\b"#,
            options: .regularExpression
        ) != nil
    }

    nonisolated static func hasExplicitTimeOfDay(in text: String) -> Bool {
        text.range(
            of: #"(?i)\b(morning|afternoon|evening|night)\b"#,
            options: .regularExpression
        ) != nil
    }

    nonisolated static func mentionsTiming(in text: String) -> Bool {
        text.range(
            of: #"(?i)\b(today|tomorrow|tonight|monday|tuesday|wednesday|thursday|friday|saturday|sunday|january|february|march|april|may|june|july|august|september|october|november|december|morning|afternoon|evening|night|noon|midnight|deadline|due|before|after|earliest|at\s+\d{1,2}(?::\d{2})?\s*(?:a\.?m\.?|p\.?m\.?))\b"#,
            options: .regularExpression
        ) != nil
    }

    nonisolated static func mentionsDeadline(in text: String) -> Bool {
        text.range(
            of: #"(?i)\b(deadline|due|by|before|until|through|last\s+day|ends?)\b"#,
            options: .regularExpression
        ) != nil
    }

    nonisolated static func explicitlyAllowsReflow(in text: String) -> Bool {
        text.range(
            of: #"(?i)\b(movable|flexible|can\s+(?:be\s+)?reflowed|can\s+reflow)\b"#,
            options: .regularExpression
        ) != nil
    }

    nonisolated static func explicitlyPreventsReflow(in text: String) -> Bool {
        text.range(
            of: #"(?i)\b(fixed(?:\s+time)?|do\s+not\s+reflow|don['’]?t\s+reflow|cannot\s+(?:be\s+)?reflowed|can['’]?t\s+(?:be\s+)?reflowed)\b"#,
            options: .regularExpression
        ) != nil
    }

    nonisolated static func impliesFixedCommitment(in text: String) -> Bool {
        let isCreatingCommitment = text.range(
            of: #"(?i)\b(book|make|schedule|arrange|reschedule)\b.{0,30}\b(appointment|reservation)\b"#,
            options: .regularExpression
        ) != nil
        guard !isCreatingCommitment else { return false }

        return text.range(
            of: #"(?i)\b(appointment|reservation|interview|flight|ticketed\s+(?:train|bus)|scheduled\s+class)\b"#,
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

    private struct Clock {
        let hour: Int
        let minute: Int
    }

    private static func taskClockRange(
        in text: String
    ) -> (start: Clock, end: Clock)? {
        let pattern = #"(?i)\b(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)?\s*(?:to|through|until|[-–—])\s*(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ) else {
            return nil
        }

        let prefixLength = min(match.range.location, 45)
        let prefixRange = NSRange(
            location: match.range.location - prefixLength,
            length: prefixLength
        )
        let prefix = (text as NSString).substring(with: prefixRange)
        if prefix.range(
            of: #"(?i)\b(open|opens|hours?|closes?)\b"#,
            options: .regularExpression
        ) != nil {
            return nil
        }

        let source = text as NSString
        guard let firstHour = intCapture(1, match: match, source: source),
              let secondHour = intCapture(4, match: match, source: source) else {
            return nil
        }
        let firstMinute = intCapture(2, match: match, source: source) ?? 0
        let secondMinute = intCapture(5, match: match, source: source) ?? 0
        let firstMarker = stringCapture(3, match: match, source: source)
        let secondMarker = stringCapture(6, match: match, source: source)
        guard let end = normalizedClock(
            hour: secondHour,
            minute: secondMinute,
            marker: secondMarker
        ) else {
            return nil
        }

        var inferredFirstMarker = firstMarker
        if inferredFirstMarker == nil {
            inferredFirstMarker = secondMarker
            if secondMarker?.lowercased().contains("p") == true,
               firstHour > secondHour {
                inferredFirstMarker = "am"
            }
        }
        guard let start = normalizedClock(
            hour: firstHour,
            minute: firstMinute,
            marker: inferredFirstMarker
        ) else {
            return nil
        }
        return (start, end)
    }

    private static func exactClock(in text: String) -> Clock? {
        let pattern = #"(?i)\bat\s+(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ) else {
            return nil
        }
        let source = text as NSString
        let prefixLength = min(match.range.location, 35)
        let prefix = source.substring(
            with: NSRange(
                location: match.range.location - prefixLength,
                length: prefixLength
            )
        )
        if prefix.range(
            of: #"(?i)\b(open|opens|opening|hours?|closes?)\b"#,
            options: .regularExpression
        ) != nil {
            return nil
        }
        guard let hour = intCapture(1, match: match, source: source),
              let marker = stringCapture(3, match: match, source: source) else {
            return nil
        }
        return normalizedClock(
            hour: hour,
            minute: intCapture(2, match: match, source: source) ?? 0,
            marker: marker
        )
    }

    private static func mentionsNamedCalendarDay(in text: String) -> Bool {
        hasDeterministicCalendarReference(in: text)
    }

    private static func mentionsEarliestConstraint(in text: String) -> Bool {
        text.range(
            of: #"(?i)\b(earliest(?:\s+start)?|not\s+before|after)\b"#,
            options: .regularExpression
        ) != nil
    }

    private static func relativeDayWindow(
        in text: String,
        now: Date,
        calendar: Calendar
    ) -> StatedDateRange? {
        let day: Date
        if text.range(
            of: #"(?i)\btomorrow\b"#,
            options: .regularExpression
        ) != nil {
            day = calendar.date(
                byAdding: .day,
                value: 1,
                to: calendar.startOfDay(for: now)
            ) ?? now
        } else if text.range(
            of: #"(?i)\b(today|tonight)\b"#,
            options: .regularExpression
        ) != nil {
            day = calendar.startOfDay(for: now)
        } else {
            return nil
        }

        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day),
              let deadline = calendar.date(
                byAdding: .minute,
                value: -1,
                to: nextDay
              ) else {
            return nil
        }
        let earliestStart = calendar.isDate(day, inSameDayAs: now) ? now : day
        return StatedDateRange(
            earliestStart: earliestStart,
            deadline: deadline
        )
    }

    private static func statedDay(
        in text: String,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        if text.range(of: #"(?i)\btomorrow\b"#, options: .regularExpression) != nil {
            return calendar.date(
                byAdding: .day,
                value: 1,
                to: calendar.startOfDay(for: now)
            )
        }
        if text.range(
            of: #"(?i)\b(today|tonight)\b"#,
            options: .regularExpression
        ) != nil {
            return calendar.startOfDay(for: now)
        }

        return statedDates(in: text, now: now, calendar: calendar)
            .first
            .map { calendar.startOfDay(for: $0.date) }
    }

    private static func statedDuration(in text: String) -> Int? {
        let patterns = [
            #"(?i)\b(?:takes?|for|duration(?:\s+of)?|lasts?)\s*(\d+(?:\.\d+)?)\s*(minutes?|mins?|hours?|hrs?)\b"#,
            #"(?i)\b(\d+(?:\.\d+)?)\s*(minutes?|mins?|hours?|hrs?)\b"#
        ]
        var match: NSTextCheckingResult?
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            if let candidate = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
            ) {
                match = candidate
                break
            }
        }
        guard let match else { return nil }
        let source = text as NSString
        guard let amountText = stringCapture(1, match: match, source: source),
              let amount = Double(amountText),
              let unit = stringCapture(2, match: match, source: source) else {
            return nil
        }
        return Int((unit.lowercased().hasPrefix("h") ? amount * 60 : amount).rounded())
    }

    private static func statedDates(
        in text: String,
        now: Date,
        calendar: Calendar
    ) -> [(date: Date, isDeadline: Bool)] {
        guard mentionsTiming(in: text) else { return [] }
        let source = text as NSString
        let fullRange = NSRange(text.startIndex..., in: text)
        var results: [(date: Date, isDeadline: Bool)] = []

        let monthPattern = #"(?i)\b(january|february|march|april|may|june|july|august|september|october|november|december)\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?"#
        if let regex = try? NSRegularExpression(pattern: monthPattern) {
            let matches = regex.matches(in: text, range: fullRange)
            for (index, match) in matches.enumerated() {
                guard let parts = dateParts(from: match, text: text) else {
                    continue
                }
                let nextLocation = index + 1 < matches.count
                    ? matches[index + 1].range.location
                    : source.length
                let isDeadline = isDeadlineReference(
                    match: match,
                    source: source
                )
                let clock = clockFollowing(
                    match: match,
                    before: nextLocation,
                    source: source
                ) ?? (isDeadline
                    ? Clock(hour: 23, minute: 59)
                    : Clock(hour: 0, minute: 0))
                guard let date = resolvedMonthDay(
                    month: parts.month,
                    day: parts.day,
                    explicitYear: parts.year,
                    clock: clock,
                    now: now,
                    calendar: calendar
                ) else {
                    continue
                }
                results.append((date, isDeadline))
            }
        }

        let weekdayPattern = #"(?i)\b(sunday|monday|tuesday|wednesday|thursday|friday|saturday)\b"#
        if let regex = try? NSRegularExpression(pattern: weekdayPattern) {
            for match in regex.matches(in: text, range: fullRange) {
                let prefixLength = min(match.range.location, 25)
                let prefix = source.substring(
                    with: NSRange(
                        location: match.range.location - prefixLength,
                        length: prefixLength
                    )
                )
                if prefix.range(
                    of: #"(?i)\b(open|opens|opening|hours?)\b"#,
                    options: .regularExpression
                ) != nil {
                    continue
                }
                let name = source.substring(with: match.range).lowercased()
                let names = [
                    "sunday", "monday", "tuesday", "wednesday",
                    "thursday", "friday", "saturday"
                ]
                guard let index = names.firstIndex(of: name) else { continue }
                let isDeadline = isDeadlineReference(
                    match: match,
                    source: source
                )
                let suppliedClock = clockFollowing(
                    match: match,
                    before: source.length,
                    source: source
                )
                guard let date = resolvedWeekday(
                    weekday: index + 1,
                    clock: suppliedClock,
                    isDeadline: isDeadline,
                    now: now,
                    calendar: calendar
                ) else {
                    continue
                }
                results.append((date, isDeadline))
            }
        }
        return results.sorted { $0.date < $1.date }
    }

    private static func isDeadlineReference(
        match: NSTextCheckingResult,
        source: NSString
    ) -> Bool {
        let prefixLength = min(match.range.location, 40)
        let context = source.substring(
            with: NSRange(
                location: match.range.location - prefixLength,
                length: prefixLength + match.range.length
            )
        )
        return context.range(
            of: #"(?i)\b(deadline|due|by|before|until|through|last\s+day|ends?)\b"#,
            options: .regularExpression
        ) != nil
    }

    private static func clockFollowing(
        match: NSTextCheckingResult,
        before boundary: Int,
        source: NSString
    ) -> Clock? {
        let start = match.range.location + match.range.length
        let length = min(max(0, boundary - start), 35)
        guard length > 0 else { return nil }
        let suffix = source.substring(
            with: NSRange(location: start, length: length)
        )
        let pattern = #"(?i)^\s*(?:at\s+)?(?:(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)|(noon|midnight))\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let clockMatch = regex.firstMatch(
                in: suffix,
                range: NSRange(suffix.startIndex..., in: suffix)
              ) else {
            return nil
        }
        let clockSource = suffix as NSString
        if let word = stringCapture(4, match: clockMatch, source: clockSource) {
            return word.lowercased() == "noon"
                ? Clock(hour: 12, minute: 0)
                : Clock(hour: 0, minute: 0)
        }
        guard let hour = intCapture(1, match: clockMatch, source: clockSource),
              let marker = stringCapture(3, match: clockMatch, source: clockSource) else {
            return nil
        }
        return normalizedClock(
            hour: hour,
            minute: intCapture(2, match: clockMatch, source: clockSource) ?? 0,
            marker: marker
        )
    }

    private static func resolvedMonthDay(
        month: Int,
        day: Int,
        explicitYear: Int?,
        clock: Clock,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        if let explicitYear {
            return validatedDate(
                year: explicitYear,
                month: month,
                day: day,
                clock: clock,
                calendar: calendar
            )
        }

        let currentYear = calendar.component(.year, from: now)
        guard let currentYearDate = validatedDate(
            year: currentYear,
            month: month,
            day: day,
            clock: clock,
            calendar: calendar
        ) else {
            return nil
        }
        let sixMonthsAgo = calendar.date(
            byAdding: .month,
            value: -6,
            to: now
        ) ?? now
        if currentYearDate < sixMonthsAgo {
            return validatedDate(
                year: currentYear + 1,
                month: month,
                day: day,
                clock: clock,
                calendar: calendar
            )
        }
        return currentYearDate
    }

    private static func resolvedWeekday(
        weekday: Int,
        clock: Clock?,
        isDeadline: Bool,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        let today = calendar.startOfDay(for: now)
        let currentWeekday = calendar.component(.weekday, from: today)
        var daysAhead = (weekday - currentWeekday + 7) % 7
        let effectiveClock = clock ?? (isDeadline
            ? Clock(hour: 23, minute: 59)
            : Clock(hour: 0, minute: 0))
        guard var day = calendar.date(
            byAdding: .day,
            value: daysAhead,
            to: today
        ),
        var candidate = date(
            on: day,
            clock: effectiveClock,
            calendar: calendar
        ) else {
            return nil
        }
        if daysAhead == 0, clock != nil, candidate <= now {
            daysAhead = 7
            day = calendar.date(
                byAdding: .day,
                value: daysAhead,
                to: today
            ) ?? day
            candidate = date(
                on: day,
                clock: effectiveClock,
                calendar: calendar
            ) ?? candidate
        } else if daysAhead == 0, clock == nil, !isDeadline {
            candidate = now
        }
        return candidate
    }

    private static func validatedDate(
        year: Int,
        month: Int,
        day: Int,
        clock: Clock,
        calendar: Calendar
    ) -> Date? {
        let components = DateComponents(
            year: year,
            month: month,
            day: day,
            hour: clock.hour,
            minute: clock.minute
        )
        guard let date = calendar.date(from: components) else { return nil }
        let resolved = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        guard resolved.year == year,
              resolved.month == month,
              resolved.day == day,
              resolved.hour == clock.hour,
              resolved.minute == clock.minute else {
            return nil
        }
        return date
    }

    private static func statedPriority(in text: String) -> TaskPriority? {
        if text.range(
            of: #"(?i)\b(high|urgent)\s+priority\b|\burgent\b"#,
            options: .regularExpression
        ) != nil {
            return .high
        }
        if text.range(
            of: #"(?i)\bmedium\s+priority\b"#,
            options: .regularExpression
        ) != nil {
            return .medium
        }
        if text.range(
            of: #"(?i)\blow\s+priority\b"#,
            options: .regularExpression
        ) != nil {
            return .low
        }
        return nil
    }

    private static func statedTravelMode(in text: String) -> TravelMode? {
        if text.range(
            of: #"(?i)\b(public\s+transit|mass\s+transit|take\s+(?:the\s+)?(?:bus|train|subway)|by\s+(?:bus|train|subway))\b"#,
            options: .regularExpression
        ) != nil {
            return .transit
        }
        if text.range(
            of: #"(?i)\b(walk|walking|on\s+foot)\b"#,
            options: .regularExpression
        ) != nil {
            return .walking
        }
        if text.range(
            of: #"(?i)\b(drive|driving|by\s+car)\b"#,
            options: .regularExpression
        ) != nil {
            return .driving
        }
        return nil
    }

    private static func statedPreferredTime(in text: String) -> String? {
        for label in ["Morning", "Afternoon", "Evening", "Night"] {
            if text.range(
                of: "\\b\(label.lowercased())\\b",
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
                return label
            }
        }
        return nil
    }

    private static func mentionsBusinessHours(in text: String) -> Bool {
        text.range(
            of: #"(?i)\b(open|opens|opening|closes?|business\s+hours|24\s*hours?)\b"#,
            options: .regularExpression
        ) != nil
    }

    private static func date(
        on day: Date,
        clock: Clock,
        calendar: Calendar
    ) -> Date? {
        calendar.date(
            bySettingHour: clock.hour,
            minute: clock.minute,
            second: 0,
            of: day
        )
    }

    private static func normalizedClock(
        hour: Int,
        minute: Int,
        marker: String?
    ) -> Clock? {
        guard (0...59).contains(minute) else { return nil }
        if let marker {
            guard (1...12).contains(hour) else { return nil }
            let isPM = marker.lowercased().contains("p")
            return Clock(
                hour: (hour % 12) + (isPM ? 12 : 0),
                minute: minute
            )
        }
        guard (0...23).contains(hour) else { return nil }
        return Clock(hour: hour, minute: minute)
    }

    private static func intCapture(
        _ index: Int,
        match: NSTextCheckingResult,
        source: NSString
    ) -> Int? {
        stringCapture(index, match: match, source: source).flatMap(Int.init)
    }

    private static func stringCapture(
        _ index: Int,
        match: NSTextCheckingResult,
        source: NSString
    ) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound else { return nil }
        return source.substring(with: range)
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
            Convert a person's task description into scheduling details for FloatCal.
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
        let explicit = TaskTextConstraints.explicitFacts(
            in: description,
            now: now
        )
        let location = details.location.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = map(details.category)
        let placeRequirement: TaskPlaceRequirement = details.requiresDestination
            || (!location.isEmpty && category == .errand)
            ? .destination
            : .anywhere
        let isFixed = explicit.isFixed ?? details.isFixed
        let hasLocalDateReference =
            TaskTextConstraints.hasDeterministicCalendarReference(
                in: description
            )
        let modelStart = TaskTextConstraints.mentionsTiming(in: description)
            && !hasLocalDateReference
            ? parseISO8601(details.earliestStartISO8601)
            : nil
        let modelDeadline = TaskTextConstraints.mentionsDeadline(in: description)
            && !hasLocalDateReference
            ? parseISO8601(details.deadlineISO8601)
            : nil
        let startDate = explicit.startDate ?? modelStart
        let deadline = explicit.deadline ?? modelDeadline

        return InterpretedTaskDraft(
            title: shortTitle(details.title),
            durationMinutes: explicit.durationMinutes ?? details.durationMinutes,
            durationSource: explicit.durationMinutes == nil ? .modelInferred : .explicit,
            startDate: startDate,
            startSource: explicit.startDate == nil
                ? (modelStart == nil ? .unknown : .modelInferred)
                : .explicit,
            category: category,
            deadline: deadline,
            deadlineSource: explicit.deadline == nil
                ? (modelDeadline == nil ? .unknown : .modelInferred)
                : .explicit,
            priority: explicit.priority ?? map(details.priority),
            destinationQuery: location,
            placeRequirement: placeRequirement,
            travelMode: explicit.travelMode,
            preferredTimeOfDay: explicit.preferredTimeOfDay ?? "",
            isFixed: isFixed,
            requiresBusinessHours: explicit.requiresBusinessHours
                || details.needsBusinessHoursLookup
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

}
