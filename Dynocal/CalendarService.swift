//
//  CalendarService.swift
//  Dynocal
//
//  Created by Maddie Smith on 5/22/26.
//

import EventKit
import Foundation

enum TaskCategory: String, CaseIterable, Identifiable {
    case none = "None"
    case errand = "Errand"
    case work = "Work"
    case personal = "Personal"
    case health = "Health"

    var id: Self { self }
}

enum TaskPriority: String, CaseIterable, Identifiable {
    case none = "None"
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    var id: Self { self }

    nonisolated var sortRank: Int {
        switch self {
        case .high: 3
        case .medium: 2
        case .low: 1
        case .none: 0
        }
    }
}

enum TaskSortMode: String, CaseIterable, Identifiable {
    case time = "Time"
    case deadline = "Deadline"
    case priority = "Priority"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .time: "clock"
        case .deadline: "calendar.badge.exclamationmark"
        case .priority: "flag.fill"
        }
    }
}

struct DynocalTask: Identifiable, Hashable {
    let id: String
    let title: String
    let taskDescription: String
    let startDate: Date
    let endDate: Date
    let category: TaskCategory
    let travelTimeMinutes: Int
    let deadline: Date?
    let priority: TaskPriority
    let location: String
    let isMovable: Bool
    let reflowCount: Int
    let manualOrder: Int?

    var durationMinutes: Int {
        Int(endDate.timeIntervalSince(startDate) / 60)
    }

    nonisolated static func sorted(_ tasks: [DynocalTask], by mode: TaskSortMode) -> [DynocalTask] {
        switch mode {
        case .time:
            tasks.sorted { left, right in
                if left.startDate != right.startDate {
                    return left.startDate < right.startDate
                }

                return left.priority.sortRank > right.priority.sortRank
            }
        case .deadline:
            tasks.sorted { left, right in
                switch (left.deadline, right.deadline) {
                case let (leftDeadline?, rightDeadline?):
                    return leftDeadline == rightDeadline
                        ? left.startDate < right.startDate
                        : leftDeadline < rightDeadline
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return left.startDate < right.startDate
                }
            }
        case .priority:
            tasks.sorted(by: isOrderedBefore)
        }
    }

    nonisolated static func isOrderedBefore(_ left: DynocalTask, _ right: DynocalTask) -> Bool {
        switch (left.manualOrder, right.manualOrder) {
        case let (leftOrder?, rightOrder?):
            return leftOrder == rightOrder
                ? left.startDate < right.startDate
                : leftOrder < rightOrder
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            if left.priority.sortRank != right.priority.sortRank {
                return left.priority.sortRank > right.priority.sortRank
            }

            switch (left.deadline, right.deadline) {
            case let (leftDeadline?, rightDeadline?) where leftDeadline != rightDeadline:
                return leftDeadline < rightDeadline
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return left.startDate < right.startDate
            }
        }
    }
}

struct RescheduleResult {
    let updatedTasks: [DynocalTask]
    let skippedConflicts: Bool
}

private struct PlacementResult {
    let newStartDate: Date
    let skippedConflict: Bool
}

private struct BlockedInterval {
    let start: Date
    let end: Date
}

struct CalendarContextEvent: Equatable {
    let start: Date
    let end: Date
    let location: String?
}

enum SchedulingOrigin: Equatable {
    case calendarEvent(String)
    case lifestyle(PlaceOrigin, String)
    case unknown
}

struct SchedulingContextResolver {
    nonisolated static let eventAnchorWindow: TimeInterval = 2 * 60 * 60

    nonisolated static func origin(
        at departureDate: Date,
        events: [CalendarContextEvent],
        profile: LifestyleProfile,
        calendar: Calendar = .current
    ) -> SchedulingOrigin {
        if let previousEvent = events
            .filter({
                $0.end <= departureDate
                    && departureDate.timeIntervalSince($0.end) <= eventAnchorWindow
            })
            .max(by: { $0.end < $1.end }) {
            let location = previousEvent.location?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            return location.isEmpty ? .unknown : .calendarEvent(location)
        }

        let expectedOrigin = profile.expectedOrigin(at: departureDate, calendar: calendar)
        let address: String

        switch expectedOrigin {
        case .home:
            address = profile.homeAddress
        case .work:
            address = profile.workAddress
        case .either:
            address = ""
        }

        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedAddress.isEmpty
            ? .unknown
            : .lifestyle(expectedOrigin, trimmedAddress)
    }
}

struct DeletedTask {
    let title: String
    let startDate: Date
    let endDate: Date
    let notes: String?
    let location: String?
}

final class CalendarService {
    static let shared = CalendarService()

    private let appCalendarTitle = "Dynocal"
    private let legacyCalendarTitle = "FloatCal"
    private let metadataStart = "DYNOCAL_META_START"
    private let legacyMetadataStart = "FLOATCAL_META_START"

    private let store = EKEventStore()

    private init() {}

    var hasCalendarAccess: Bool {
        if #available(iOS 17.0, *) {
            return EKEventStore.authorizationStatus(for: .event) == .fullAccess
        } else {
            return EKEventStore.authorizationStatus(for: .event) == .authorized
        }
    }

    var calendarAccessIsDenied: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .denied || status == .restricted
    }

    func requestAccess() async throws -> Bool {
        if #available(iOS 17.0, *) {
            return try await store.requestFullAccessToEvents()
        } else {
            return try await store.requestAccess(to: .event)
        }
    }

    func addTask(
        title: String,
        description: String,
        startDate: Date,
        durationMinutes: Int,
        category: TaskCategory,
        travelTimeMinutes: Int,
        deadline: Date?,
        priority: TaskPriority,
        location: String,
        isMovable: Bool
    ) throws -> DynocalTask {
        let calendar = try dynocalCalendar()

        let taskDuration = TimeInterval(durationMinutes * 60)
        let travelDuration = TimeInterval(travelTimeMinutes * 60)
        let placedStartDate: Date

        if isMovable {
            let placement = try nextOpenStartDate(
                from: startDate,
                duration: taskDuration + travelDuration,
                category: category,
                destination: location,
                excludingEventIDs: []
            )
            placedStartDate = placement.newStartDate.addingTimeInterval(travelDuration)
        } else {
            placedStartDate = startDate
        }
        let endDate = placedStartDate.addingTimeInterval(taskDuration)

        if let deadline, endDate > deadline {
            throw CalendarServiceError.noRoomBeforeDeadline
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = placedStartDate
        event.endDate = endDate
        event.calendar = calendar
        event.location = location
        event.alarms = []
        event.notes = dynocalNotes(
            taskDescription: description,
            durationMinutes: durationMinutes,
            category: category,
            travelTimeMinutes: travelTimeMinutes,
            deadline: deadline,
            priority: priority,
            isMovable: isMovable
        )

        try store.save(event, span: .thisEvent, commit: true)

        return task(from: event)
    }

    func updateTask(
        id: String,
        title: String,
        description: String,
        startDate: Date,
        durationMinutes: Int,
        category: TaskCategory,
        travelTimeMinutes: Int,
        deadline: Date?,
        priority: TaskPriority,
        location: String,
        isMovable: Bool
    ) throws -> DynocalTask {
        let event = try dynocalEvent(id: id)
        let existingTask = task(from: event)

        event.title = title
        let taskDuration = TimeInterval(durationMinutes * 60)
        let travelDuration = TimeInterval(travelTimeMinutes * 60)
        let placedStartDate: Date

        if isMovable {
            let placement = try nextOpenStartDate(
                from: startDate,
                duration: taskDuration + travelDuration,
                category: category,
                destination: location,
                excludingEventIDs: [id]
            )
            placedStartDate = placement.newStartDate.addingTimeInterval(travelDuration)
        } else {
            placedStartDate = startDate
        }
        let placedEndDate = placedStartDate.addingTimeInterval(taskDuration)

        if let deadline, placedEndDate > deadline {
            throw CalendarServiceError.noRoomBeforeDeadline
        }

        event.startDate = placedStartDate
        event.endDate = placedEndDate
        event.location = location
        event.notes = dynocalNotes(
            taskDescription: description,
            durationMinutes: durationMinutes,
            category: category,
            travelTimeMinutes: travelTimeMinutes,
            deadline: deadline,
            priority: priority,
            isMovable: isMovable,
            reflowCount: existingTask.reflowCount,
            manualOrder: existingTask.manualOrder
        )
        event.alarms = []

        try store.save(event, span: .thisEvent, commit: true)

        return task(from: event)
    }

    func tasks() throws -> [DynocalTask] {
        store.refreshSourcesIfNecessary()

        let calendars = store.calendars(for: .event)
            .filter { $0.title == appCalendarTitle || $0.title == legacyCalendarTitle }

        let today = Calendar.current.startOfDay(for: Date())
        let startDate = Calendar.current.date(byAdding: .day, value: -30, to: today) ?? today
        let endDate = Calendar.current.date(byAdding: .day, value: 14, to: today) ?? Date()
        let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)

        return store.events(matching: predicate)
            .filter { isDynocalEvent($0) }
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .map(task(from:))
    }

    func completeTask(id: String) throws -> DeletedTask {
        let event = try dynocalEvent(id: id)
        let deletedTask = DeletedTask(
            title: event.title,
            startDate: event.startDate,
            endDate: event.endDate,
            notes: event.notes,
            location: event.location
        )

        try store.remove(event, span: .thisEvent, commit: true)
        return deletedTask
    }

    func restoreTask(_ deletedTask: DeletedTask) throws -> DynocalTask {
        let calendar = try dynocalCalendar()

        let event = EKEvent(eventStore: store)
        event.title = deletedTask.title
        event.startDate = deletedTask.startDate
        event.endDate = deletedTask.endDate
        event.calendar = calendar
        event.location = deletedTask.location
        event.alarms = []
        event.notes = deletedTask.notes ?? dynocalNotes(
            taskDescription: deletedTask.title,
            durationMinutes: Int(deletedTask.endDate.timeIntervalSince(deletedTask.startDate) / 60),
            category: .none,
            travelTimeMinutes: 0,
            deadline: nil,
            priority: .none
        )

        try store.save(event, span: .thisEvent, commit: true)

        return task(from: event)
    }

    func rescheduleOverdueTasks() throws -> RescheduleResult {
        let now = Date()
        let overdueTasks = try tasks()
            .filter { $0.startDate < now && $0.isMovable }
            .sorted(by: DynocalTask.isOrderedBefore)

        var updatedTasks: [DynocalTask] = []
        var nextCandidateDate = now
        var skippedConflicts = false
        let overdueTaskIDs = Set(overdueTasks.map(\.id))

        for task in overdueTasks {
            let event = try dynocalEvent(id: task.id)
            let duration = storedDuration(for: event)
            let travelDuration = TimeInterval(task.travelTimeMinutes * 60)
            let placement = try nextOpenStartDate(
                from: nextCandidateDate,
                duration: duration + travelDuration,
                category: task.category,
                destination: task.location,
                excludingEventIDs: overdueTaskIDs
            )

            event.startDate = placement.newStartDate.addingTimeInterval(travelDuration)
            event.endDate = event.startDate.addingTimeInterval(duration)

            if let deadline = task.deadline, event.endDate > deadline {
                throw CalendarServiceError.noRoomBeforeDeadline
            }
            event.alarms = []
            event.notes = dynocalNotes(
                taskDescription: task.taskDescription,
                durationMinutes: task.durationMinutes,
                category: task.category,
                travelTimeMinutes: task.travelTimeMinutes,
                deadline: task.deadline,
                priority: task.priority,
                isMovable: task.isMovable,
                reflowCount: task.reflowCount + 1,
                manualOrder: task.manualOrder
            )

            try store.save(event, span: .thisEvent, commit: true)

            let updatedTask = self.task(from: event)

            updatedTasks.append(updatedTask)
            nextCandidateDate = updatedTask.endDate
            skippedConflicts = skippedConflicts || placement.skippedConflict
        }

        return RescheduleResult(
            updatedTasks: updatedTasks,
            skippedConflicts: skippedConflicts
        )
    }

    func setManualOrder(taskIDs: [String]) throws {
        for (order, id) in taskIDs.enumerated() {
            let event = try dynocalEvent(id: id)
            let task = task(from: event)

            event.notes = dynocalNotes(
                taskDescription: task.taskDescription,
                durationMinutes: task.durationMinutes,
                category: task.category,
                travelTimeMinutes: task.travelTimeMinutes,
                deadline: task.deadline,
                priority: task.priority,
                isMovable: task.isMovable,
                reflowCount: task.reflowCount,
                manualOrder: order
            )

            try store.save(event, span: .thisEvent, commit: false)
        }

        try store.commit()
    }

    func clearManualOrder(taskIDs: [String]) throws {
        for id in taskIDs {
            let event = try dynocalEvent(id: id)
            let task = task(from: event)

            event.notes = dynocalNotes(
                taskDescription: task.taskDescription,
                durationMinutes: task.durationMinutes,
                category: task.category,
                travelTimeMinutes: task.travelTimeMinutes,
                deadline: task.deadline,
                priority: task.priority,
                isMovable: task.isMovable,
                reflowCount: task.reflowCount,
                manualOrder: nil
            )

            try store.save(event, span: .thisEvent, commit: false)
        }

        try store.commit()
    }

    private func dynocalCalendar() throws -> EKCalendar {
        if let existing = store.calendars(for: .event).first(where: {
            $0.title == appCalendarTitle
                && $0.allowsContentModifications
                && $0.source.sourceType != .exchange
        }) {
            return existing
        }

        if let iCloudSource = iCloudSource() {
            return try dynocalCalendar(in: iCloudSource)
        }

        if let localSource = store.sources.first(where: { $0.sourceType == .local }) {
            return try dynocalCalendar(in: localSource)
        }

        if let defaultSource = store.defaultCalendarForNewEvents?.source {
            return try dynocalCalendar(in: defaultSource)
        }

        throw CalendarServiceError.noWritableCalendarSource
    }

    private func dynocalCalendar(in source: EKSource) throws -> EKCalendar {
        if let existing = store.calendars(for: .event).first(where: {
            $0.title == appCalendarTitle
                && $0.allowsContentModifications
                && $0.source.sourceIdentifier == source.sourceIdentifier
        }) {
            return existing
        }

        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = appCalendarTitle
        calendar.source = source

        try store.saveCalendar(calendar, commit: true)
        return calendar
    }

    private func dynocalEvent(id: String) throws -> EKEvent {
        guard let event = store.event(withIdentifier: id),
              isDynocalEvent(event) else {
            throw CalendarServiceError.taskNotFound
        }

        return event
    }

    private func iCloudSource() -> EKSource? {
        if let source = store.sources.first(where: { $0.isICloud }) {
            return source
        }

        return store.calendars(for: .event)
            .first(where: { $0.source.isICloud })?
            .source
    }

    private func nextOpenStartDate(
        from targetStartDate: Date,
        duration: TimeInterval,
        category: TaskCategory,
        destination: String,
        excludingEventIDs: Set<String>
    ) throws -> PlacementResult {
        let searchEndDate = Calendar.current.date(byAdding: .day, value: 7, to: targetStartDate)
            ?? targetStartDate.addingTimeInterval(7 * 24 * 60 * 60)
        let contextStartDate = targetStartDate.addingTimeInterval(
            -SchedulingContextResolver.eventAnchorWindow
        )
        let calendars = store.calendars(for: .event)
        let predicate = store.predicateForEvents(
            withStart: contextStartDate,
            end: searchEndDate,
            calendars: calendars
        )
        let calendarEvents = store.events(matching: predicate)
            .filter { event in
                let isExcluded = event.eventIdentifier.map(excludingEventIDs.contains) ?? false

                return !isExcluded
                    && !event.isAllDay
            }
        let eventIntervals = calendarEvents
            .filter { $0.availability != .free }
            .compactMap { event -> BlockedInterval? in
                guard let start = event.startDate, let end = event.endDate else { return nil }
                return BlockedInterval(start: start, end: end)
            }
        let contextEvents = calendarEvents.compactMap { event -> CalendarContextEvent? in
            guard let start = event.startDate, let end = event.endDate else { return nil }
            let eventLocation = event.location?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let structuredTitle = event.structuredLocation?.title?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return CalendarContextEvent(
                start: start,
                end: end,
                location: eventLocation?.isEmpty == false ? eventLocation : structuredTitle
            )
        }
        let blockedIntervals = (
            eventIntervals + lifestyleBlockedIntervals(
                from: targetStartDate,
                through: searchEndDate,
                category: category
            )
        )
        .sorted { $0.start < $1.start }

        var candidateStartDate = roundedUpToNextFiveMinutes(targetStartDate)
        let firstCandidateStartDate = candidateStartDate
        let needsKnownOrigin = !destination
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty

        while candidateStartDate < searchEndDate {
            let candidateEndDate = candidateStartDate.addingTimeInterval(duration)

            if let conflict = blockedIntervals.first(where: {
                candidateStartDate < $0.end && candidateEndDate > $0.start
            }) {
                candidateStartDate = roundedUpToNextFiveMinutes(conflict.end)
                continue
            }

            if needsKnownOrigin,
               SchedulingContextResolver.origin(
                    at: candidateStartDate,
                    events: contextEvents,
                    profile: PreferencesStore.shared.profile
               ) == .unknown {
                candidateStartDate = candidateStartDate.addingTimeInterval(5 * 60)
                continue
            }

            return PlacementResult(
                newStartDate: candidateStartDate,
                skippedConflict: candidateStartDate > firstCandidateStartDate
            )
        }

        if needsKnownOrigin {
            throw CalendarServiceError.unknownTravelOrigin
        }

        throw CalendarServiceError.noAvailableTime
    }

    private func lifestyleBlockedIntervals(
        from startDate: Date,
        through endDate: Date,
        category: TaskCategory
    ) -> [BlockedInterval] {
        let profile = PreferencesStore.shared.profile
        let calendar = Calendar.current
        let startOfTargetDay = calendar.startOfDay(for: startDate)
        let firstDay = calendar.date(byAdding: .day, value: -1, to: startOfTargetDay)
            ?? startOfTargetDay
        var intervals: [BlockedInterval] = []
        var day = firstDay

        while day < endDate {
            let weekday = calendar.component(.weekday, from: day)

            if profile.protectWorkHours,
               category != .work,
               profile.workDays.contains(weekday),
               let start = date(on: day, minutes: profile.workStartMinutes),
               let end = date(on: day, minutes: profile.workEndMinutes),
               end > start {
                intervals.append(BlockedInterval(start: start, end: end))
            }

            if profile.protectSleep,
               let sleepStart = date(on: day, minutes: profile.sleepStartMinutes) {
                let wakeDay = profile.sleepEndMinutes <= profile.sleepStartMinutes
                    ? calendar.date(byAdding: .day, value: 1, to: day) ?? day
                    : day
                if let sleepEnd = date(on: wakeDay, minutes: profile.sleepEndMinutes),
                   sleepEnd > sleepStart {
                    intervals.append(BlockedInterval(start: sleepStart, end: sleepEnd))
                }
            }

            day = calendar.date(byAdding: .day, value: 1, to: day)
                ?? day.addingTimeInterval(24 * 60 * 60)
        }

        return intervals
    }

    private func date(on day: Date, minutes: Int) -> Date? {
        Calendar.current.date(
            bySettingHour: minutes / 60,
            minute: minutes % 60,
            second: 0,
            of: day
        )
    }

    private func roundedUpToNextFiveMinutes(_ date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)

        guard let minute = components.minute,
              let roundedDate = calendar.date(from: components) else {
            return date
        }

        let remainder = minute % 5

        if remainder == 0 {
            return roundedDate
        }

        return calendar.date(byAdding: .minute, value: 5 - remainder, to: roundedDate) ?? date
    }

    private func dynocalNotes(
        taskDescription: String,
        durationMinutes: Int,
        category: TaskCategory,
        travelTimeMinutes: Int,
        deadline: Date?,
        priority: TaskPriority,
        isMovable: Bool = true,
        reflowCount: Int = 0,
        manualOrder: Int? = nil
    ) -> String {
        let deadlineTimestamp = deadline.map { String($0.timeIntervalSince1970) } ?? "none"
        let manualOrderValue = manualOrder.map(String.init) ?? "none"
        let encodedDescription = Data(taskDescription.utf8).base64EncodedString()

        return """
        Created by Dynocal

        DYNOCAL_META_START
        version: 5
        itemType: task
        scheduleType: \(isMovable ? "movable" : "fixed")
        taskDescriptionBase64: \(encodedDescription)
        category: \(category.rawValue)
        durationMinutes: \(durationMinutes)
        travelTimeMinutes: \(travelTimeMinutes)
        deadlineTimestamp: \(deadlineTimestamp)
        priority: \(priority.rawValue)
        reflowCount: \(reflowCount)
        manualOrder: \(manualOrderValue)
        DYNOCAL_META_END
        """
    }

    private func task(from event: EKEvent) -> DynocalTask {
        let category = metadataValue("category", in: event.notes)
            .flatMap(TaskCategory.init(rawValue:)) ?? .none
        let travelTimeMinutes = metadataValue("travelTimeMinutes", in: event.notes)
            .flatMap(Int.init) ?? 0
        let deadline = metadataValue("deadlineTimestamp", in: event.notes)
            .flatMap(TimeInterval.init)
            .map(Date.init(timeIntervalSince1970:))
        let priority = metadataValue("priority", in: event.notes)
            .flatMap(TaskPriority.init(rawValue:)) ?? .none
        let isMovable = metadataValue("scheduleType", in: event.notes) != "fixed"
        let reflowCount = metadataValue("reflowCount", in: event.notes)
            .flatMap(Int.init) ?? 0
        let manualOrder = metadataValue("manualOrder", in: event.notes)
            .flatMap(Int.init)
        let taskDescription = metadataValue("taskDescriptionBase64", in: event.notes)
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? event.title
            ?? "Untitled Task"

        return DynocalTask(
            id: event.eventIdentifier,
            title: event.title,
            taskDescription: taskDescription,
            startDate: event.startDate,
            endDate: event.endDate,
            category: category,
            travelTimeMinutes: travelTimeMinutes,
            deadline: deadline,
            priority: priority,
            location: event.location ?? "",
            isMovable: isMovable,
            reflowCount: reflowCount,
            manualOrder: manualOrder
        )
    }

    private func isDynocalEvent(_ event: EKEvent) -> Bool {
        event.calendar.title == appCalendarTitle
            || event.notes?.contains(metadataStart) == true
            || event.notes?.contains(legacyMetadataStart) == true
    }

    private func storedDuration(for event: EKEvent) -> TimeInterval {
        if let durationMinutes = metadataValue("durationMinutes", in: event.notes).flatMap(Int.init),
           durationMinutes > 0 {
            return TimeInterval(durationMinutes * 60)
        }

        let eventDuration = event.endDate.timeIntervalSince(event.startDate)

        if eventDuration > 0 && eventDuration <= 8 * 60 * 60 {
            return eventDuration
        }

        return 30 * 60
    }

    private func metadataValue(_ key: String, in notes: String?) -> String? {
        notes?
            .components(separatedBy: .newlines)
            .first { $0.hasPrefix("\(key):") }?
            .split(separator: ":", maxSplits: 1)
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CalendarServiceError: LocalizedError {
    case noWritableCalendarSource
    case taskNotFound
    case noRoomBeforeDeadline
    case noAvailableTime
    case unknownTravelOrigin

    var errorDescription: String? {
        switch self {
        case .noWritableCalendarSource:
            return "No writable calendar is available. Add a calendar account or enable a local calendar, then try again."
        case .taskNotFound:
            return "That task could not be found."
        case .noRoomBeforeDeadline:
            return "No available time fits before this task’s deadline. Adjust the deadline, duration, or protected hours."
        case .noAvailableTime:
            return "No available time was found in the next seven days."
        case .unknownTravelOrigin:
            return "Dynocal could not confidently tell where you would leave from. Add locations to nearby calendar events or set Home and Work in Settings."
        }
    }
}

private extension EKSourceType {
    var description: String {
        switch self {
        case .local:
            return "local"
        case .exchange:
            return "exchange"
        case .calDAV:
            return "calDAV"
        case .mobileMe:
            return "mobileMe"
        case .subscribed:
            return "subscribed"
        case .birthdays:
            return "birthdays"
        @unknown default:
            return "unknown"
        }
    }
}

private extension EKSource {
    var isICloud: Bool {
        sourceType == .mobileMe
            || title.localizedCaseInsensitiveContains("icloud")
            || title.localizedCaseInsensitiveContains("iCloud")
    }
}
