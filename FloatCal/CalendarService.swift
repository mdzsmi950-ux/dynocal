//
//  CalendarService.swift
//  FloatCal
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

struct FloatCalTask: Identifiable, Hashable {
    let id: String
    let title: String
    let taskDescription: String
    let startDate: Date
    let endDate: Date
    let category: TaskCategory
    let workDurationMinutes: Int
    let travelTimeMinutes: Int
    let deadline: Date?
    let priority: TaskPriority
    let preferredTimeOfDay: String
    let location: String
    let isMovable: Bool
    let requiresBusinessHours: Bool
    let reflowCount: Int
    let manualOrder: Int?
    let needsDetailsReview: Bool

    var durationMinutes: Int {
        workDurationMinutes
    }

    var workStartDate: Date {
        startDate.addingTimeInterval(TimeInterval(travelTimeMinutes * 60))
    }

    nonisolated static func sorted(_ tasks: [FloatCalTask], by mode: TaskSortMode) -> [FloatCalTask] {
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

    nonisolated static func isOrderedBefore(_ left: FloatCalTask, _ right: FloatCalTask) -> Bool {
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
    let updatedTasks: [FloatCalTask]
    let issues: [ReflowIssue]
    let skippedConflicts: Bool
}

struct ReflowIssue: Identifiable {
    let task: FloatCalTask
    let reason: String

    var id: String { task.id }
}

private struct PlannedTaskUpdate {
    let originalTask: FloatCalTask
    let placement: PlacementResult
    let workDuration: TimeInterval
}

private struct PlacementResult {
    let newStartDate: Date
    let travelTimeMinutes: Int
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

struct TaskTimePreference {
    nonisolated static func matches(
        _ preference: String,
        date: Date,
        calendar: Calendar = .current
    ) -> Bool {
        let hour = calendar.component(.hour, from: date)
        switch preference.lowercased() {
        case "morning":
            return (5..<12).contains(hour)
        case "afternoon":
            return (12..<17).contains(hour)
        case "evening":
            return (17..<21).contains(hour)
        case "night":
            return hour >= 21 || hour < 5
        default:
            return true
        }
    }
}

struct DeletedTask {
    let title: String
    let startDate: Date
    let endDate: Date
    let notes: String?
    let location: String?
}

@MainActor
final class CalendarService {
    static let shared = CalendarService()

    private let appCalendarTitle = "FloatCal"
    private let legacyCalendarTitle = "Dynocal"
    private let metadataStart = "FLOATCAL_META_START"
    private let legacyMetadataStart = "DYNOCAL_META_START"

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
        deadline: Date?,
        priority: TaskPriority,
        preferredTimeOfDay: String,
        location: String,
        isMovable: Bool,
        requiresBusinessHours: Bool,
        createAsOverdue: Bool = false,
        allowFixedConflict: Bool = false
    ) async throws -> FloatCalTask {
        TravelTimeService.shared.beginSchedulingAttempt()
        let calendar = try floatCalCalendar()

        let taskDuration = TimeInterval(durationMinutes * 60)
        let placement: PlacementResult

        if isMovable, createAsOverdue {
            placement = PlacementResult(
                newStartDate: startDate,
                travelTimeMinutes: 0,
                skippedConflict: false
            )
        } else if isMovable {
            placement = try await nextOpenStartDate(
                from: startDate,
                workDuration: taskDuration,
                category: category,
                destination: location,
                requiresBusinessHours: requiresBusinessHours,
                preferredTimeOfDay: preferredTimeOfDay,
                deadline: deadline,
                excludingEventIDs: []
            )
        } else {
            placement = try await fixedPlacement(
                taskStartDate: startDate,
                workDuration: taskDuration,
                category: category,
                destination: location,
                requiresBusinessHours: requiresBusinessHours,
                allowConflict: allowFixedConflict,
                excludingEventIDs: []
            )
        }
        let travelDuration = TimeInterval(placement.travelTimeMinutes * 60)
        let endDate = placement.newStartDate
            .addingTimeInterval(travelDuration + taskDuration)

        if let deadline, endDate > deadline {
            throw CalendarServiceError.noRoomBeforeDeadline
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = placement.newStartDate
        event.endDate = endDate
        event.calendar = calendar
        event.location = location
        event.alarms = []
        event.notes = floatCalNotes(
            taskDescription: description,
            durationMinutes: durationMinutes,
            category: category,
            travelTimeMinutes: placement.travelTimeMinutes,
            deadline: deadline,
            priority: priority,
            preferredTimeOfDay: preferredTimeOfDay,
            isMovable: isMovable,
            requiresBusinessHours: requiresBusinessHours
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
        deadline: Date?,
        priority: TaskPriority,
        preferredTimeOfDay: String,
        location: String,
        isMovable: Bool,
        requiresBusinessHours: Bool,
        allowFixedConflict: Bool = false
    ) async throws -> FloatCalTask {
        TravelTimeService.shared.beginSchedulingAttempt()
        let event = try floatCalEvent(id: id)
        let existingTask = task(from: event)

        event.title = title
        let taskDuration = TimeInterval(durationMinutes * 60)
        let placement: PlacementResult

        if isMovable {
            placement = try await nextOpenStartDate(
                from: startDate,
                workDuration: taskDuration,
                category: category,
                destination: location,
                requiresBusinessHours: requiresBusinessHours,
                preferredTimeOfDay: preferredTimeOfDay,
                deadline: deadline,
                excludingEventIDs: [id]
            )
        } else {
            placement = try await fixedPlacement(
                taskStartDate: startDate,
                workDuration: taskDuration,
                category: category,
                destination: location,
                requiresBusinessHours: requiresBusinessHours,
                allowConflict: allowFixedConflict,
                excludingEventIDs: [id]
            )
        }
        let travelDuration = TimeInterval(placement.travelTimeMinutes * 60)
        let placedEndDate = placement.newStartDate
            .addingTimeInterval(travelDuration + taskDuration)

        if let deadline, placedEndDate > deadline {
            throw CalendarServiceError.noRoomBeforeDeadline
        }

        event.startDate = placement.newStartDate
        event.endDate = placedEndDate
        event.location = location
        event.notes = floatCalNotes(
            taskDescription: description,
            durationMinutes: durationMinutes,
            category: category,
            travelTimeMinutes: placement.travelTimeMinutes,
            deadline: deadline,
            priority: priority,
            preferredTimeOfDay: preferredTimeOfDay,
            isMovable: isMovable,
            reflowCount: existingTask.reflowCount,
            manualOrder: existingTask.manualOrder,
            requiresBusinessHours: requiresBusinessHours
        )
        event.alarms = []

        try store.save(event, span: .thisEvent, commit: true)

        return task(from: event)
    }

    func tasks() throws -> [FloatCalTask] {
        store.refreshSourcesIfNecessary()
        migrateLegacyCalendarNames()

        let calendars = store.calendars(for: .event)
            .filter { $0.title == appCalendarTitle || $0.title == legacyCalendarTitle }

        return eventsAcrossPracticalCalendarHistory(in: calendars)
            .filter { isFloatCalEvent($0) }
            .sorted { $0.startDate < $1.startDate }
            .map(task(from:))
    }

    private func eventsAcrossPracticalCalendarHistory(
        in calendars: [EKCalendar]
    ) -> [EKEvent] {
        let calendar = Calendar(identifier: .gregorian)
        guard var chunkStart = calendar.date(
            from: DateComponents(year: 1900, month: 1, day: 1)
        ), let finalEnd = calendar.date(
            from: DateComponents(year: 2200, month: 1, day: 1)
        ) else {
            return []
        }

        var eventsByIdentifier: [String: EKEvent] = [:]
        while chunkStart < finalEnd {
            let chunkEnd = min(
                calendar.date(byAdding: .year, value: 4, to: chunkStart) ?? finalEnd,
                finalEnd
            )
            let predicate = store.predicateForEvents(
                withStart: chunkStart,
                end: chunkEnd,
                calendars: calendars
            )
            for event in store.events(matching: predicate) {
                if let identifier = event.eventIdentifier {
                    eventsByIdentifier[identifier] = event
                }
            }
            chunkStart = chunkEnd
        }
        return Array(eventsByIdentifier.values)
    }

    func completeTask(id: String) throws -> DeletedTask {
        let event = try floatCalEvent(id: id)
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

    func restoreTask(_ deletedTask: DeletedTask) throws -> FloatCalTask {
        let calendar = try floatCalCalendar()

        let event = EKEvent(eventStore: store)
        event.title = deletedTask.title
        event.startDate = deletedTask.startDate
        event.endDate = deletedTask.endDate
        event.calendar = calendar
        event.location = deletedTask.location
        event.alarms = []
        event.notes = deletedTask.notes ?? floatCalNotes(
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

    func rescheduleOverdueTasks() async throws -> RescheduleResult {
        TravelTimeService.shared.beginSchedulingAttempt()
        let now = Date()
        let overdueTasks = try tasks()
            .filter {
                $0.startDate < now
                    && $0.isMovable
                    && !$0.needsDetailsReview
            }
            .sorted(by: FloatCalTask.isOrderedBefore)

        var plannedUpdates: [PlannedTaskUpdate] = []
        var issues: [ReflowIssue] = []
        var nextCandidateDate = now
        var skippedConflicts = false
        let overdueTaskIDs = Set(overdueTasks.map(\.id))

        for task in overdueTasks {
            let event = try floatCalEvent(id: task.id)
            let duration = storedDuration(for: event)
            do {
                let placement = try await nextOpenStartDate(
                    from: nextCandidateDate,
                    workDuration: duration,
                    category: task.category,
                    destination: task.location,
                    requiresBusinessHours: task.requiresBusinessHours,
                    preferredTimeOfDay: task.preferredTimeOfDay,
                    deadline: task.deadline,
                    excludingEventIDs: overdueTaskIDs
                )
                let endDate = placement.newStartDate.addingTimeInterval(
                    TimeInterval(placement.travelTimeMinutes * 60) + duration
                )
                if let deadline = task.deadline, endDate > deadline {
                    throw CalendarServiceError.noRoomBeforeDeadline
                }

                plannedUpdates.append(
                    PlannedTaskUpdate(
                        originalTask: task,
                        placement: placement,
                        workDuration: duration
                    )
                )
                nextCandidateDate = endDate
                skippedConflicts = skippedConflicts || placement.skippedConflict
            } catch {
                issues.append(
                    ReflowIssue(
                        task: task,
                        reason: error.localizedDescription
                    )
                )
            }
        }

        var updatedTasks: [FloatCalTask] = []
        do {
            for update in plannedUpdates {
                let task = update.originalTask
                let placement = update.placement
                let event = try floatCalEvent(id: task.id)
                let travelDuration = TimeInterval(placement.travelTimeMinutes * 60)

                event.startDate = placement.newStartDate
                event.endDate = event.startDate.addingTimeInterval(
                    travelDuration + update.workDuration
                )
                event.alarms = []
                event.notes = floatCalNotes(
                    taskDescription: task.taskDescription,
                    durationMinutes: task.durationMinutes,
                    category: task.category,
                    travelTimeMinutes: placement.travelTimeMinutes,
                    deadline: task.deadline,
                    priority: task.priority,
                    preferredTimeOfDay: task.preferredTimeOfDay,
                    isMovable: task.isMovable,
                    reflowCount: task.reflowCount + 1,
                    manualOrder: task.manualOrder,
                    requiresBusinessHours: task.requiresBusinessHours
                )

                try store.save(event, span: .thisEvent, commit: false)
                updatedTasks.append(self.task(from: event))
            }

            if !plannedUpdates.isEmpty {
                try store.commit()
            }
        } catch {
            store.reset()
            throw error
        }

        return RescheduleResult(
            updatedTasks: updatedTasks,
            issues: issues,
            skippedConflicts: skippedConflicts
        )
    }

    func setManualOrder(taskIDs: [String]) throws {
        for (order, id) in taskIDs.enumerated() {
            let event = try floatCalEvent(id: id)
            let task = task(from: event)

            event.notes = floatCalNotes(
                taskDescription: task.taskDescription,
                durationMinutes: task.durationMinutes,
                category: task.category,
                travelTimeMinutes: task.travelTimeMinutes,
                deadline: task.deadline,
                priority: task.priority,
                preferredTimeOfDay: task.preferredTimeOfDay,
                isMovable: task.isMovable,
                reflowCount: task.reflowCount,
                manualOrder: order,
                requiresBusinessHours: task.requiresBusinessHours
            )

            try store.save(event, span: .thisEvent, commit: false)
        }

        try store.commit()
    }

    func clearManualOrder(taskIDs: [String]) throws {
        for id in taskIDs {
            let event = try floatCalEvent(id: id)
            let task = task(from: event)

            event.notes = floatCalNotes(
                taskDescription: task.taskDescription,
                durationMinutes: task.durationMinutes,
                category: task.category,
                travelTimeMinutes: task.travelTimeMinutes,
                deadline: task.deadline,
                priority: task.priority,
                preferredTimeOfDay: task.preferredTimeOfDay,
                isMovable: task.isMovable,
                reflowCount: task.reflowCount,
                manualOrder: nil,
                requiresBusinessHours: task.requiresBusinessHours
            )

            try store.save(event, span: .thisEvent, commit: false)
        }

        try store.commit()
    }

    private func floatCalCalendar() throws -> EKCalendar {
        migrateLegacyCalendarNames()

        if let existing = store.calendars(for: .event).first(where: {
            $0.title == appCalendarTitle
                && $0.allowsContentModifications
                && $0.source.sourceType != .exchange
        }) {
            return existing
        }

        if let iCloudSource = iCloudSource() {
            return try floatCalCalendar(in: iCloudSource)
        }

        if let localSource = store.sources.first(where: { $0.sourceType == .local }) {
            return try floatCalCalendar(in: localSource)
        }

        if let defaultSource = store.defaultCalendarForNewEvents?.source {
            return try floatCalCalendar(in: defaultSource)
        }

        throw CalendarServiceError.noWritableCalendarSource
    }

    private func migrateLegacyCalendarNames() {
        for calendar in store.calendars(for: .event)
        where calendar.title == legacyCalendarTitle
            && calendar.allowsContentModifications {
            calendar.title = appCalendarTitle
            try? store.saveCalendar(calendar, commit: true)
        }
    }

    private func floatCalCalendar(in source: EKSource) throws -> EKCalendar {
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

    private func floatCalEvent(id: String) throws -> EKEvent {
        guard let event = store.event(withIdentifier: id),
              isFloatCalEvent(event) else {
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
        workDuration: TimeInterval,
        category: TaskCategory,
        destination: String,
        requiresBusinessHours: Bool,
        preferredTimeOfDay: String,
        deadline: Date?,
        excludingEventIDs: Set<String>
    ) async throws -> PlacementResult {
        let naturalSearchEnd = Calendar.current.date(byAdding: .day, value: 7, to: targetStartDate)
            ?? targetStartDate.addingTimeInterval(7 * 24 * 60 * 60)
        let searchEndDate = deadline.map { min($0, naturalSearchEnd) } ?? naturalSearchEnd
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
        let savedHours = PreferencesStore.shared.place(matching: destination)?.weeklyHours ?? []

        if requiresBusinessHours, savedHours.isEmpty {
            throw CalendarServiceError.unknownBusinessHours
        }

        var foundKnownOrigin = !needsKnownOrigin
        var calculatedRoute = !needsKnownOrigin

        var isTryingPreferredWindow = !preferredTimeOfDay.isEmpty

        while candidateStartDate < searchEndDate {
            if let conflict = blockedIntervals.first(where: {
                candidateStartDate >= $0.start && candidateStartDate < $0.end
            }) {
                candidateStartDate = roundedUpToNextFiveMinutes(conflict.end)
                continue
            }

            var travelTimeMinutes = 0
            if needsKnownOrigin {
                let origin = SchedulingContextResolver.origin(
                    at: candidateStartDate,
                    events: contextEvents,
                    profile: PreferencesStore.shared.profile
                )
                guard origin != .unknown else {
                    candidateStartDate = candidateStartDate.addingTimeInterval(5 * 60)
                    continue
                }
                foundKnownOrigin = true

                guard let estimatedMinutes = await TravelTimeService.shared.estimatedMinutes(
                    from: origin,
                    to: destination,
                    departureDate: candidateStartDate
                ) else {
                    candidateStartDate = candidateStartDate.addingTimeInterval(30 * 60)
                    continue
                }
                travelTimeMinutes = estimatedMinutes
                calculatedRoute = true
            }

            let travelDuration = TimeInterval(travelTimeMinutes * 60)
            let taskStartDate = candidateStartDate.addingTimeInterval(travelDuration)
            let candidateEndDate = taskStartDate.addingTimeInterval(workDuration)

            if let deadline, candidateEndDate > deadline {
                break
            }

            if isTryingPreferredWindow,
               !TaskTimePreference.matches(preferredTimeOfDay, date: taskStartDate) {
                candidateStartDate = candidateStartDate.addingTimeInterval(30 * 60)
                continue
            }

            if let conflict = blockedIntervals.first(where: {
                candidateStartDate < $0.end && candidateEndDate > $0.start
            }) {
                candidateStartDate = roundedUpToNextFiveMinutes(conflict.end)
                continue
            }

            if requiresBusinessHours {
                guard PlaceDayHours.contains(
                    savedHours,
                    start: taskStartDate,
                    end: candidateEndDate
                ) else {
                    if let nextOpening = PlaceDayHours.nextOpening(
                        after: taskStartDate,
                        in: savedHours
                    ) {
                        candidateStartDate = roundedUpToNextFiveMinutes(
                            nextOpening.addingTimeInterval(-travelDuration)
                        )
                    } else {
                        candidateStartDate = startOfNextDay(after: candidateStartDate)
                    }
                    continue
                }
            }

            return PlacementResult(
                newStartDate: candidateStartDate,
                travelTimeMinutes: travelTimeMinutes,
                skippedConflict: candidateStartDate > firstCandidateStartDate
            )
        }

        if isTryingPreferredWindow {
            isTryingPreferredWindow = false
            candidateStartDate = roundedUpToNextFiveMinutes(targetStartDate)
            calculatedRoute = !needsKnownOrigin

            while candidateStartDate < searchEndDate {
                if let conflict = blockedIntervals.first(where: {
                    candidateStartDate >= $0.start && candidateStartDate < $0.end
                }) {
                    candidateStartDate = roundedUpToNextFiveMinutes(conflict.end)
                    continue
                }

                var travelTimeMinutes = 0
                if needsKnownOrigin {
                    let origin = SchedulingContextResolver.origin(
                        at: candidateStartDate,
                        events: contextEvents,
                        profile: PreferencesStore.shared.profile
                    )
                    guard origin != .unknown else {
                        candidateStartDate = candidateStartDate.addingTimeInterval(5 * 60)
                        continue
                    }
                    foundKnownOrigin = true
                    guard let estimatedMinutes = await TravelTimeService.shared.estimatedMinutes(
                        from: origin,
                        to: destination,
                        departureDate: candidateStartDate
                    ) else {
                        candidateStartDate = candidateStartDate.addingTimeInterval(30 * 60)
                        continue
                    }
                    travelTimeMinutes = estimatedMinutes
                    calculatedRoute = true
                }

                let travelDuration = TimeInterval(travelTimeMinutes * 60)
                let taskStartDate = candidateStartDate.addingTimeInterval(travelDuration)
                let candidateEndDate = taskStartDate.addingTimeInterval(workDuration)
                if let deadline, candidateEndDate > deadline {
                    break
                }
                if let conflict = blockedIntervals.first(where: {
                    candidateStartDate < $0.end && candidateEndDate > $0.start
                }) {
                    candidateStartDate = roundedUpToNextFiveMinutes(conflict.end)
                    continue
                }
                if requiresBusinessHours {
                    guard PlaceDayHours.contains(
                        savedHours,
                        start: taskStartDate,
                        end: candidateEndDate
                    ) else {
                        if let nextOpening = PlaceDayHours.nextOpening(
                            after: taskStartDate,
                            in: savedHours
                        ) {
                            candidateStartDate = roundedUpToNextFiveMinutes(
                                nextOpening.addingTimeInterval(-travelDuration)
                            )
                        } else {
                            candidateStartDate = startOfNextDay(after: candidateStartDate)
                        }
                        continue
                    }
                }
                return PlacementResult(
                    newStartDate: candidateStartDate,
                    travelTimeMinutes: travelTimeMinutes,
                    skippedConflict: candidateStartDate > firstCandidateStartDate
                )
            }
        }

        if needsKnownOrigin, !foundKnownOrigin {
            throw CalendarServiceError.unknownTravelOrigin
        }
        if needsKnownOrigin, !calculatedRoute {
            throw CalendarServiceError.travelRouteUnavailable
        }
        if deadline != nil {
            throw CalendarServiceError.noRoomBeforeDeadline
        }

        throw CalendarServiceError.noAvailableTime
    }

    private func fixedPlacement(
        taskStartDate: Date,
        workDuration: TimeInterval,
        category: TaskCategory,
        destination: String,
        requiresBusinessHours: Bool,
        allowConflict: Bool,
        excludingEventIDs: Set<String>
    ) async throws -> PlacementResult {
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        var travelTimeMinutes = 0

        if !trimmedDestination.isEmpty {
            let contextStart = taskStartDate.addingTimeInterval(
            -SchedulingContextResolver.eventAnchorWindow
            )
            let predicate = store.predicateForEvents(
                withStart: contextStart,
                end: taskStartDate.addingTimeInterval(workDuration),
                calendars: store.calendars(for: .event)
            )
            let contextEvents = store.events(matching: predicate)
                .filter {
                    !$0.isAllDay
                        && !($0.eventIdentifier.map(excludingEventIDs.contains) ?? false)
                }
                .compactMap { event -> CalendarContextEvent? in
                    guard let start = event.startDate, let end = event.endDate else {
                        return nil
                    }
                    let location = event.location?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let structuredTitle = event.structuredLocation?.title?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return CalendarContextEvent(
                        start: start,
                        end: end,
                        location: location?.isEmpty == false ? location : structuredTitle
                    )
                }
            let origin = SchedulingContextResolver.origin(
                at: taskStartDate,
                events: contextEvents,
                profile: PreferencesStore.shared.profile
            )
            guard origin != .unknown else {
                throw CalendarServiceError.unknownTravelOrigin
            }
            guard let estimatedMinutes = await TravelTimeService.shared.estimatedMinutes(
                from: origin,
                to: trimmedDestination,
                departureDate: taskStartDate
            ) else {
                throw CalendarServiceError.travelRouteUnavailable
            }
            travelTimeMinutes = estimatedMinutes
        }

        let taskEndDate = taskStartDate.addingTimeInterval(workDuration)
        if requiresBusinessHours {
            let hours = PreferencesStore.shared.place(matching: trimmedDestination)?
                .weeklyHours ?? []
            guard !hours.isEmpty else {
                throw CalendarServiceError.unknownBusinessHours
            }
            guard PlaceDayHours.contains(
                hours,
                start: taskStartDate,
                end: taskEndDate
            ) else {
                throw CalendarServiceError.outsideBusinessHours
            }
        }

        let blockStartDate = taskStartDate.addingTimeInterval(
            TimeInterval(-travelTimeMinutes * 60)
        )
        let protectedTimeConflict = lifestyleBlockedIntervals(
            from: blockStartDate,
            through: taskEndDate,
            category: category
        ).contains {
            blockStartDate < $0.end && taskEndDate > $0.start
        }
        let calendarConflict = hasCalendarConflict(
            from: blockStartDate,
            through: taskEndDate,
            excludingEventIDs: excludingEventIDs
        )
        if !allowConflict, calendarConflict || protectedTimeConflict {
            throw CalendarServiceError.fixedTimeConflict
        }

        return PlacementResult(
            newStartDate: blockStartDate,
            travelTimeMinutes: travelTimeMinutes,
            skippedConflict: false
        )
    }

    private func hasCalendarConflict(
        from startDate: Date,
        through endDate: Date,
        excludingEventIDs: Set<String>
    ) -> Bool {
        let predicate = store.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: store.calendars(for: .event)
        )
        return store.events(matching: predicate).contains { event in
            guard !event.isAllDay,
                  event.availability != .free,
                  !(event.eventIdentifier.map(excludingEventIDs.contains) ?? false),
                  let eventStart = event.startDate,
                  let eventEnd = event.endDate else {
                return false
            }
            return startDate < eventEnd && endDate > eventStart
        }
    }

    private func startOfNextDay(after date: Date) -> Date {
        let calendar = Calendar.current
        let nextDay = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        return calendar.date(
            bySettingHour: 0,
            minute: 0,
            second: 0,
            of: nextDay
        ) ?? nextDay
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

    private func floatCalNotes(
        taskDescription: String,
        durationMinutes: Int,
        category: TaskCategory,
        travelTimeMinutes: Int,
        deadline: Date?,
        priority: TaskPriority,
        preferredTimeOfDay: String = "",
        isMovable: Bool = true,
        reflowCount: Int = 0,
        manualOrder: Int? = nil,
        requiresBusinessHours: Bool = false
    ) -> String {
        let deadlineTimestamp = deadline.map { String($0.timeIntervalSince1970) } ?? "none"
        let manualOrderValue = manualOrder.map(String.init) ?? "none"
        let encodedDescription = Data(taskDescription.utf8).base64EncodedString()

        return """
        Created by FloatCal

        FLOATCAL_META_START
        version: 6
        itemType: task
        scheduleType: \(isMovable ? "movable" : "fixed")
        taskDescriptionBase64: \(encodedDescription)
        category: \(category.rawValue)
        durationMinutes: \(durationMinutes)
        travelTimeMinutes: \(travelTimeMinutes)
        deadlineTimestamp: \(deadlineTimestamp)
        priority: \(priority.rawValue)
        preferredTimeOfDay: \(preferredTimeOfDay)
        reflowCount: \(reflowCount)
        manualOrder: \(manualOrderValue)
        requiresBusinessHours: \(requiresBusinessHours)
        FLOATCAL_META_END
        """
    }

    private func task(from event: EKEvent) -> FloatCalTask {
        let needsDetailsReview = !hasCompleteTaskMetadata(event.notes)
        let category = metadataValue("category", in: event.notes)
            .flatMap(TaskCategory.init(rawValue:)) ?? .none
        let travelTimeMinutes = metadataValue("travelTimeMinutes", in: event.notes)
            .flatMap(Int.init) ?? 0
        let workDurationMinutes = metadataValue("durationMinutes", in: event.notes)
            .flatMap(Int.init)
            ?? max(
                5,
                Int(event.endDate.timeIntervalSince(event.startDate) / 60)
                    - travelTimeMinutes
            )
        let deadline = metadataValue("deadlineTimestamp", in: event.notes)
            .flatMap(TimeInterval.init)
            .map(Date.init(timeIntervalSince1970:))
        let priority = metadataValue("priority", in: event.notes)
            .flatMap(TaskPriority.init(rawValue:)) ?? .none
        let preferredTimeOfDay = metadataValue("preferredTimeOfDay", in: event.notes) ?? ""
        let isMovable = !needsDetailsReview
            && metadataValue("scheduleType", in: event.notes) != "fixed"
        let reflowCount = metadataValue("reflowCount", in: event.notes)
            .flatMap(Int.init) ?? 0
        let manualOrder = metadataValue("manualOrder", in: event.notes)
            .flatMap(Int.init)
        let requiresBusinessHours = metadataValue("requiresBusinessHours", in: event.notes)
            .flatMap(Bool.init) ?? false
        let taskDescription = metadataValue("taskDescriptionBase64", in: event.notes)
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? event.title
            ?? "Untitled Task"

        return FloatCalTask(
            id: event.eventIdentifier,
            title: event.title,
            taskDescription: taskDescription,
            startDate: event.startDate,
            endDate: event.endDate,
            category: category,
            workDurationMinutes: workDurationMinutes,
            travelTimeMinutes: travelTimeMinutes,
            deadline: deadline,
            priority: priority,
            preferredTimeOfDay: preferredTimeOfDay,
            location: event.location ?? "",
            isMovable: isMovable,
            requiresBusinessHours: requiresBusinessHours,
            reflowCount: reflowCount,
            manualOrder: manualOrder,
            needsDetailsReview: needsDetailsReview
        )
    }

    private func hasCompleteTaskMetadata(_ notes: String?) -> Bool {
        guard notes?.contains(metadataStart) == true
                || notes?.contains(legacyMetadataStart) == true else {
            return false
        }

        return metadataValue("scheduleType", in: notes) != nil
            && metadataValue("durationMinutes", in: notes) != nil
            && metadataValue("category", in: notes) != nil
            && metadataValue("priority", in: notes) != nil
    }

    private func isFloatCalEvent(_ event: EKEvent) -> Bool {
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
    case travelRouteUnavailable
    case unknownBusinessHours
    case outsideBusinessHours
    case fixedTimeConflict

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
            return "FloatCal could not confidently tell where you would leave from. Add locations to nearby calendar events or set Home and Work in Settings."
        case .travelRouteUnavailable:
            return "FloatCal could not calculate a route for this destination. Check the saved addresses and try again."
        case .unknownBusinessHours:
            return "This task depends on business hours that have not been saved yet. Review the place in Settings."
        case .outsideBusinessHours:
            return "This fixed time falls outside the saved business hours."
        case .fixedTimeConflict:
            return "This fixed task overlaps another calendar event or protected work/sleep time, including any required travel. Choose a different time or confirm the override."
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
