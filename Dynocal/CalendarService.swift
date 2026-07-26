//
//  CalendarService.swift
//  Dynocal
//
//  Created by Maddie Smith on 5/22/26.
//

import EventKit

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
}

struct DynocalTask: Identifiable, Hashable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let category: TaskCategory
    let travelTimeMinutes: Int
    let deadline: Date?
    let priority: TaskPriority
    let location: String

    var durationMinutes: Int {
        Int(endDate.timeIntervalSince(startDate) / 60)
    }
}

struct SnoozeResult {
    let updatedTask: DynocalTask
    let newStartDate: Date
    let skippedConflict: Bool
}

struct RescheduleResult {
    let updatedTasks: [DynocalTask]
    let skippedConflicts: Bool
}

private struct PlacementResult {
    let newStartDate: Date
    let skippedConflict: Bool
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
        startDate: Date,
        durationMinutes: Int,
        category: TaskCategory,
        travelTimeMinutes: Int,
        deadline: Date?,
        priority: TaskPriority,
        location: String
    ) throws -> DynocalTask {
        let calendar = try dynocalCalendar()

        let endDate = startDate.addingTimeInterval(TimeInterval(durationMinutes * 60))

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.calendar = calendar
        event.location = location
        event.alarms = []
        event.notes = dynocalNotes(
            durationMinutes: durationMinutes,
            category: category,
            travelTimeMinutes: travelTimeMinutes,
            deadline: deadline,
            priority: priority
        )

        try store.save(event, span: .thisEvent, commit: true)

        return task(from: event)
    }

    func updateTask(
        id: String,
        title: String,
        startDate: Date,
        durationMinutes: Int,
        category: TaskCategory,
        travelTimeMinutes: Int,
        deadline: Date?,
        priority: TaskPriority,
        location: String
    ) throws -> DynocalTask {
        let event = try dynocalEvent(id: id)

        event.title = title
        event.startDate = startDate
        event.endDate = startDate.addingTimeInterval(TimeInterval(durationMinutes * 60))
        event.location = location
        event.notes = dynocalNotes(
            durationMinutes: durationMinutes,
            category: category,
            travelTimeMinutes: travelTimeMinutes,
            deadline: deadline,
            priority: priority
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
            durationMinutes: Int(deletedTask.endDate.timeIntervalSince(deletedTask.startDate) / 60),
            category: .none,
            travelTimeMinutes: 0,
            deadline: nil,
            priority: .none
        )

        try store.save(event, span: .thisEvent, commit: true)

        return task(from: event)
    }

    func snoozeTask(id: String, by minutes: Int) throws -> SnoozeResult {
        let event = try dynocalEvent(id: id)
        let duration = storedDuration(for: event)
        let baseStartDate = max(event.startDate, Date())
        let targetStartDate = baseStartDate.addingTimeInterval(TimeInterval(minutes * 60))
        let result = nextOpenStartDate(
            from: targetStartDate,
            duration: duration,
            excludingEventIDs: [event.eventIdentifier]
        )
        let newEndDate = result.newStartDate.addingTimeInterval(duration)

        event.endDate = newEndDate
        event.startDate = result.newStartDate
        event.alarms = []

        try store.save(event, span: .thisEvent, commit: true)

        let updatedTask = task(from: event)

        return SnoozeResult(
            updatedTask: updatedTask,
            newStartDate: result.newStartDate,
            skippedConflict: result.skippedConflict
        )
    }

    func rescheduleOverdueTasks() throws -> RescheduleResult {
        let now = Date()
        let overdueTasks = try tasks()
            .filter { $0.startDate < now }
            .sorted { $0.startDate < $1.startDate }

        var updatedTasks: [DynocalTask] = []
        var nextCandidateDate = now
        var skippedConflicts = false
        let overdueTaskIDs = Set(overdueTasks.map(\.id))

        for task in overdueTasks {
            let event = try dynocalEvent(id: task.id)
            let duration = storedDuration(for: event)
            let placement = nextOpenStartDate(
                from: nextCandidateDate,
                duration: duration,
                excludingEventIDs: overdueTaskIDs
            )

            event.endDate = placement.newStartDate.addingTimeInterval(duration)
            event.startDate = placement.newStartDate
            event.alarms = []

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
        excludingEventIDs: Set<String>
    ) -> PlacementResult {
        let searchEndDate = Calendar.current.date(byAdding: .day, value: 7, to: targetStartDate)
            ?? targetStartDate.addingTimeInterval(7 * 24 * 60 * 60)
        let calendars = store.calendars(for: .event)
        let predicate = store.predicateForEvents(withStart: targetStartDate, end: searchEndDate, calendars: calendars)
        let busyEvents = store.events(matching: predicate)
            .filter { event in
                let isExcluded = event.eventIdentifier.map(excludingEventIDs.contains) ?? false

                return !isExcluded
                    && !event.isAllDay
                    && event.availability != .free
            }
            .sorted { $0.startDate < $1.startDate }

        var candidateStartDate = roundedUpToNextFiveMinutes(targetStartDate)
        let firstCandidateStartDate = candidateStartDate

        for busyEvent in busyEvents {
            guard let busyStartDate = busyEvent.startDate,
                  let busyEndDate = busyEvent.endDate else {
                continue
            }

            let candidateEndDate = candidateStartDate.addingTimeInterval(duration)

            if candidateEndDate <= busyStartDate {
                return PlacementResult(
                    newStartDate: candidateStartDate,
                    skippedConflict: candidateStartDate > firstCandidateStartDate
                )
            }

            if candidateStartDate < busyEndDate {
                candidateStartDate = roundedUpToNextFiveMinutes(busyEndDate)
            }
        }

        return PlacementResult(
            newStartDate: candidateStartDate,
            skippedConflict: candidateStartDate > firstCandidateStartDate
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
        durationMinutes: Int,
        category: TaskCategory,
        travelTimeMinutes: Int,
        deadline: Date?,
        priority: TaskPriority
    ) -> String {
        let deadlineTimestamp = deadline.map { String($0.timeIntervalSince1970) } ?? "none"

        return """
        Created by Dynocal

        DYNOCAL_META_START
        version: 2
        itemType: task
        scheduleType: movable
        category: \(category.rawValue)
        durationMinutes: \(durationMinutes)
        travelTimeMinutes: \(travelTimeMinutes)
        deadlineTimestamp: \(deadlineTimestamp)
        priority: \(priority.rawValue)
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

        return DynocalTask(
            id: event.eventIdentifier,
            title: event.title,
            startDate: event.startDate,
            endDate: event.endDate,
            category: category,
            travelTimeMinutes: travelTimeMinutes,
            deadline: deadline,
            priority: priority,
            location: event.location ?? ""
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

    var errorDescription: String? {
        switch self {
        case .noWritableCalendarSource:
            return "No writable calendar is available. Add a calendar account or enable a local calendar, then try again."
        case .taskNotFound:
            return "That task could not be found."
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
