//
//  FloatCalTests.swift
//  FloatCalTests
//
//  Created by Maddie Smith on 5/22/26.
//

import Foundation
import Testing
@testable import FloatCal

struct FloatCalTests {

    @Test func higherPriorityTasksSortFirst() {
        let low = task(id: "low", priority: .low)
        let high = task(id: "high", priority: .high)

        let ordered = [low, high].sorted(by: FloatCalTask.isOrderedBefore)

        #expect(ordered.map(\.id) == ["high", "low"])
    }

    @Test func earlierDeadlineBreaksPriorityTie() {
        let later = task(
            id: "later",
            priority: .medium,
            deadline: Date(timeIntervalSince1970: 2_000)
        )
        let sooner = task(
            id: "sooner",
            priority: .medium,
            deadline: Date(timeIntervalSince1970: 1_000)
        )

        let ordered = [later, sooner].sorted(by: FloatCalTask.isOrderedBefore)

        #expect(ordered.map(\.id) == ["sooner", "later"])
    }

    @Test func manualOrderOverridesPriority() {
        let high = task(id: "high", priority: .high, manualOrder: 1)
        let low = task(id: "low", priority: .low, manualOrder: 0)

        let ordered = [high, low].sorted(by: FloatCalTask.isOrderedBefore)

        #expect(ordered.map(\.id) == ["low", "high"])
    }

    @Test func timeSortIgnoresSavedPriorityOrder() {
        let later = task(
            id: "later",
            priority: .high,
            startDate: Date(timeIntervalSince1970: 20_000),
            manualOrder: 0
        )
        let sooner = task(
            id: "sooner",
            priority: .low,
            startDate: Date(timeIntervalSince1970: 10_000),
            manualOrder: 1
        )

        let ordered = FloatCalTask.sorted([later, sooner], by: .time)

        #expect(ordered.map(\.id) == ["sooner", "later"])
    }

    @Test func deadlineSortPlacesTasksWithoutDeadlinesLast() {
        let noDeadline = task(id: "none", priority: .high)
        let deadline = task(
            id: "deadline",
            priority: .low,
            deadline: Date(timeIntervalSince1970: 30_000)
        )

        let ordered = FloatCalTask.sorted([noDeadline, deadline], by: .deadline)

        #expect(ordered.map(\.id) == ["deadline", "none"])
    }

    @Test func reflowSelectsOverdueTasksEvenWhenTheirDeadlineExpired() {
        let now = Date(timeIntervalSince1970: 20_000)
        let overdue = task(
            id: "overdue",
            priority: .high,
            startDate: Date(timeIntervalSince1970: 10_000),
            deadline: Date(timeIntervalSince1970: 15_000)
        )

        let selected = ReflowSelection.candidateIDs(
            tasks: [overdue],
            now: now,
            externalBusyIntervals: []
        )

        #expect(selected == ["overdue"])
        #expect(ReflowDeadline.effective(overdue.deadline, now: now) == nil)
    }

    @Test func reflowMovesLowerPrioritySideOfFutureOverlap() {
        let now = Date(timeIntervalSince1970: 10_000)
        let start = Date(timeIntervalSince1970: 20_000)
        let high = task(id: "high", priority: .high, startDate: start)
        let low = task(
            id: "low",
            priority: .low,
            startDate: start.addingTimeInterval(900)
        )

        let selected = ReflowSelection.candidateIDs(
            tasks: [low, high],
            now: now,
            externalBusyIntervals: []
        )

        #expect(selected == ["low"])
    }

    @Test func reflowMovesMovableTaskAroundFixedCommitment() {
        let now = Date(timeIntervalSince1970: 10_000)
        let start = Date(timeIntervalSince1970: 20_000)
        let fixed = task(
            id: "fixed",
            priority: .medium,
            startDate: start,
            isMovable: false
        )
        let movable = task(
            id: "movable",
            priority: .high,
            startDate: start.addingTimeInterval(600)
        )

        let selected = ReflowSelection.candidateIDs(
            tasks: [movable, fixed],
            now: now,
            externalBusyIntervals: []
        )

        #expect(selected == ["movable"])
    }

    @Test func reflowSelectsTaskThatOverlapsExternalCalendarEvent() {
        let now = Date(timeIntervalSince1970: 10_000)
        let start = Date(timeIntervalSince1970: 20_000)
        let task = task(id: "task", priority: .medium, startDate: start)
        let busy = CalendarBusyInterval(
            start: start.addingTimeInterval(300),
            end: start.addingTimeInterval(600)
        )

        let selected = ReflowSelection.candidateIDs(
            tasks: [task],
            now: now,
            externalBusyIntervals: [busy]
        )

        #expect(selected == ["task"])
    }

    @Test func touchingTaskBoundariesDoNotCountAsOverlap() {
        let now = Date(timeIntervalSince1970: 10_000)
        let first = task(
            id: "first",
            priority: .high,
            startDate: Date(timeIntervalSince1970: 20_000)
        )
        let second = task(
            id: "second",
            priority: .low,
            startDate: first.endDate
        )

        let selected = ReflowSelection.candidateIDs(
            tasks: [first, second],
            now: now,
            externalBusyIntervals: []
        )

        #expect(selected.isEmpty)
    }

    @Test func lifestyleInfersWorkAndHomeOrigins() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        var profile = LifestyleProfile()
        profile.workDays = [2, 3, 4, 5, 6]
        profile.workStartMinutes = 9 * 60
        profile.workEndMinutes = 17 * 60

        let wednesdayAtTwo = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 29, hour: 14)
        )!
        let wednesdayAfterWork = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 29, hour: 17, minute: 30)
        )!
        let wednesdayAtNight = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 29, hour: 21)
        )!
        let saturdayAfternoon = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 1, hour: 14)
        )!

        #expect(profile.expectedOrigin(at: wednesdayAtTwo, calendar: calendar) == .work)
        #expect(profile.expectedOrigin(at: wednesdayAfterWork, calendar: calendar) == .work)
        #expect(profile.expectedOrigin(at: wednesdayAtNight, calendar: calendar) == .home)
        #expect(profile.expectedOrigin(at: saturdayAfternoon, calendar: calendar) == .home)
    }

    @Test func workLocationInferenceDoesNotDependOnBlockingWorkHours() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var profile = LifestyleProfile()
        profile.protectWorkHours = false
        profile.workDays = [2, 3, 4, 5, 6]
        profile.workStartMinutes = 9 * 60
        profile.workEndMinutes = 17 * 60
        let wednesdayAtTwo = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 29, hour: 14)
        )!

        #expect(
            profile.expectedOrigin(at: wednesdayAtTwo, calendar: calendar)
                == .work
        )
    }

    @Test func recentCalendarLocationOverridesLifestyleOrigin() {
        let departure = Date(timeIntervalSince1970: 20_000)
        var profile = LifestyleProfile()
        profile.homeAddress = "100 Home Street"
        profile.workAddress = "200 Work Avenue"
        let gymEvent = CalendarContextEvent(
            start: departure.addingTimeInterval(-5_400),
            end: departure.addingTimeInterval(-1_800),
            location: "Neighborhood Gym"
        )

        let origin = SchedulingContextResolver.origin(
            at: departure,
            events: [gymEvent],
            profile: profile
        )

        #expect(origin == .calendarEvent("Neighborhood Gym"))
    }

    @Test func recentEventWithoutLocationMakesOriginUnknown() {
        let departure = Date(timeIntervalSince1970: 20_000)
        var profile = LifestyleProfile()
        profile.homeAddress = "100 Home Street"
        let event = CalendarContextEvent(
            start: departure.addingTimeInterval(-5_400),
            end: departure.addingTimeInterval(-1_800),
            location: nil
        )

        let origin = SchedulingContextResolver.origin(
            at: departure,
            events: [event],
            profile: profile
        )

        #expect(origin == .unknown)
    }

    @Test func expiredCalendarAnchorFallsBackToLifestyleOrigin() {
        let departure = Date(timeIntervalSince1970: 20_000)
        var profile = LifestyleProfile()
        profile.homeAddress = "100 Home Street"
        profile.protectWorkHours = false
        let oldEvent = CalendarContextEvent(
            start: departure.addingTimeInterval(-18_000),
            end: departure.addingTimeInterval(-10_800),
            location: "Old Location"
        )

        let origin = SchedulingContextResolver.origin(
            at: departure,
            events: [oldEvent],
            profile: profile
        )

        #expect(origin == .lifestyle(.home, "100 Home Street"))
    }

    @Test func saleWindowCreatesNotBeforeDateAndEndOfDayDeadline() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 25, hour: 19)
        )!

        let range = TaskTextConstraints.dateRange(
            in: "Get cat litter during the Costco sale from August 27th to September 17th.",
            now: now,
            calendar: calendar
        )

        #expect(
            calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: range!.earliestStart
            ) == DateComponents(year: 2026, month: 8, day: 27, hour: 0, minute: 0)
        )
        #expect(
            calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: range!.deadline
            ) == DateComponents(year: 2026, month: 9, day: 17, hour: 23, minute: 59)
        )
    }

    @Test func nearbyYearlessDatesStayInCurrentYearEvenWhenOverdue() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = calendar.date(
            from: DateComponents(
                year: 2026,
                month: 7,
                day: 26,
                hour: 14
            )
        )!

        let facts = TaskTextConstraints.explicitFacts(
            in: """
                Submit expense report. It takes 25 minutes.
                Earliest start July 25 at 7:00 PM. High priority.
                Deadline July 26 at noon. Movable.
                """,
            now: now,
            calendar: calendar
        )

        #expect(
            calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: facts.startDate!
            ) == DateComponents(
                year: 2026,
                month: 7,
                day: 25,
                hour: 19,
                minute: 0
            )
        )
        #expect(
            calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: facts.deadline!
            ) == DateComponents(
                year: 2026,
                month: 7,
                day: 26,
                hour: 12,
                minute: 0
            )
        )
        #expect(facts.durationMinutes == 25)
        #expect(facts.priority == .high)
        #expect(facts.isFixed == false)
    }

    @Test func lateYearReferenceToJanuaryRollsIntoNextYear() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = calendar.date(
            from: DateComponents(
                year: 2026,
                month: 12,
                day: 20,
                hour: 12
            )
        )!

        let facts = TaskTextConstraints.explicitFacts(
            in: "File taxes. Earliest start January 10 at 9:00 AM. Movable.",
            now: now,
            calendar: calendar
        )

        #expect(
            calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: facts.startDate!
            ) == DateComponents(
                year: 2027,
                month: 1,
                day: 10,
                hour: 9,
                minute: 0
            )
        )
    }

    @Test func explicitYearIsNeverChanged() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = calendar.date(
            from: DateComponents(
                year: 2026,
                month: 7,
                day: 26,
                hour: 12
            )
        )!

        let facts = TaskTextConstraints.explicitFacts(
            in: "Review records from July 25, 2025 at 7:00 PM. Movable.",
            now: now,
            calendar: calendar
        )

        #expect(
            calendar.component(.year, from: facts.startDate!) == 2025
        )
    }

    @Test func weekdayMeansUpcomingOccurrence() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let saturday = calendar.date(
            from: DateComponents(
                year: 2026,
                month: 7,
                day: 25,
                hour: 12
            )
        )!

        let facts = TaskTextConstraints.explicitFacts(
            in: "Call the venue Tuesday at 3:30 PM. Movable.",
            now: saturday,
            calendar: calendar
        )

        #expect(
            calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: facts.startDate!
            ) == DateComponents(
                year: 2026,
                month: 7,
                day: 28,
                hour: 15,
                minute: 30
            )
        )
    }

    @Test func sameWeekdayPastTimeMeansNextWeek() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let tuesday = calendar.date(
            from: DateComponents(
                year: 2026,
                month: 7,
                day: 28,
                hour: 16
            )
        )!

        let facts = TaskTextConstraints.explicitFacts(
            in: "Call the venue Tuesday at 3:30 PM. Movable.",
            now: tuesday,
            calendar: calendar
        )

        #expect(
            calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: facts.startDate!
            ) == DateComponents(
                year: 2026,
                month: 8,
                day: 4,
                hour: 15,
                minute: 30
            )
        )
    }

    @Test func weekdayDeadlineIsNotMistakenForAFixedStart() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let saturday = calendar.date(
            from: DateComponents(
                year: 2026,
                month: 7,
                day: 25,
                hour: 12
            )
        )!

        let facts = TaskTextConstraints.explicitFacts(
            in: "Submit the report by Tuesday at 5:00 PM.",
            now: saturday,
            calendar: calendar
        )

        #expect(facts.startDate == nil)
        #expect(
            calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: facts.deadline!
            ) == DateComponents(
                year: 2026,
                month: 7,
                day: 28,
                hour: 17,
                minute: 0
            )
        )
        #expect(facts.isFixed == nil)
    }

    @Test func timeOfDayMustBeExplicit() {
        #expect(!TaskTextConstraints.hasExplicitTimeOfDay(in: "Buy cat litter during the sale"))
        #expect(TaskTextConstraints.hasExplicitTimeOfDay(in: "Buy cat litter in the evening"))
        #expect(!TaskTextConstraints.hasExplicitTimeOfDay(in: "Buy cat litter after 5 p.m."))
    }

    @Test func todayClockRangeIsAnExactProtectedFact() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 26, hour: 8)
        )!

        let facts = TaskTextConstraints.explicitFacts(
            in: "today meditate 10am to 11am",
            now: now,
            calendar: calendar
        )

        #expect(
            calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: facts.startDate!
            ) == DateComponents(year: 2026, month: 7, day: 26, hour: 10, minute: 0)
        )
        #expect(
            calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: facts.deadline!
            ) == DateComponents(year: 2026, month: 7, day: 26, hour: 11, minute: 0)
        )
        #expect(facts.durationMinutes == 60)
        #expect(facts.isFixed == true)
    }

    @Test func todayWithoutATimeCreatesATodayWindowFromNow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 26, hour: 14, minute: 7)
        )!

        let facts = TaskTextConstraints.explicitFacts(
            in: "Meditate today",
            now: now,
            calendar: calendar
        )

        #expect(facts.startDate == now)
        #expect(
            calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: facts.deadline!
            ) == DateComponents(year: 2026, month: 7, day: 26, hour: 23, minute: 59)
        )
    }

    @Test func todayAtAnExactTimeDoesNotDependOnTheModel() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 26, hour: 8)
        )!

        let facts = TaskTextConstraints.explicitFacts(
            in: "Meditate today at 10am for 20 minutes",
            now: now,
            calendar: calendar
        )

        #expect(
            calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: facts.startDate!
            ) == DateComponents(year: 2026, month: 7, day: 26, hour: 10, minute: 0)
        )
        #expect(facts.deadline == nil)
        #expect(facts.durationMinutes == 20)
        #expect(facts.isFixed == true)
    }

    @Test func statedDurationAndPriorityOverrideModelGuesses() {
        let facts = TaskTextConstraints.explicitFacts(
            in: "Submit expense report. It takes 25 minutes. High priority. Movable.",
            now: Date()
        )

        #expect(facts.durationMinutes == 25)
        #expect(facts.priority == .high)
        #expect(facts.isFixed == false)
    }

    @Test func compactDurationIsStillExplicit() {
        let facts = TaskTextConstraints.explicitFacts(
            in: "30min, need to go get groceries",
            now: Date()
        )

        #expect(facts.durationMinutes == 30)
    }

    @Test func explicitTravelModeOverridesTheLifestyleDefault() {
        #expect(
            TaskTextConstraints.explicitFacts(
                in: "Take public transit to return books",
                now: Date()
            ).travelMode == .transit
        )
        #expect(
            TaskTextConstraints.explicitFacts(
                in: "Walk to the dry cleaner",
                now: Date()
            ).travelMode == .walking
        )
        #expect(
            TaskTextConstraints.explicitFacts(
                in: "Drive to Costco",
                now: Date()
            ).travelMode == .driving
        )
    }

    @Test func datedAppointmentDoesNotDependOnModelDateGuess() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 26, hour: 8)
        )!

        let facts = TaskTextConstraints.explicitFacts(
            in: "Dentist appointment on July 27 at 10:00 AM for 60 minutes.",
            now: now,
            calendar: calendar
        )

        #expect(
            calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: facts.startDate!
            ) == DateComponents(year: 2026, month: 7, day: 27, hour: 10, minute: 0)
        )
        #expect(facts.durationMinutes == 60)
        #expect(facts.isFixed == true)
    }

    @Test func storeHoursAreNotMistakenForTaskDurationOrTiming() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 26, hour: 8)
        )!

        let facts = TaskTextConstraints.explicitFacts(
            in: "Buy groceries. Shopping takes 30 minutes. Costco is open 10am to 8:30pm.",
            now: now,
            calendar: calendar
        )

        #expect(facts.durationMinutes == 30)
        #expect(facts.startDate == nil)
        #expect(facts.deadline == nil)
        #expect(facts.requiresBusinessHours)
    }

    @Test func explicitMovableLanguageOverridesModelClassification() {
        #expect(TaskTextConstraints.explicitlyAllowsReflow(
            in: "Fold laundry. Medium priority. Movable."
        ))
        #expect(!TaskTextConstraints.explicitlyPreventsReflow(
            in: "Fold laundry. Medium priority. Movable."
        ))
    }

    @Test func explicitFixedLanguagePreventsReflow() {
        #expect(TaskTextConstraints.explicitlyPreventsReflow(
            in: "Dentist appointment at 10 AM. Do not reflow."
        ))
    }

    @Test func appointmentsAreFixedButSchedulingOneIsNot() {
        #expect(TaskTextConstraints.impliesFixedCommitment(
            in: "Dentist appointment July 27 at 10 AM."
        ))
        #expect(!TaskTextConstraints.impliesFixedCommitment(
            in: "Schedule a dentist appointment."
        ))
    }

    @Test func completenessAsksOnlyForUserResolvableBlockingFacts() {
        let facts = reasoningFacts(
            durationSource: .modelInferred,
            placeRequirement: .destination,
            destinationQuery: "Costco",
            destinationAddress: "",
            requiresBusinessHours: true,
            hasSavedBusinessHours: false
        )

        let issues = TaskCompletenessEngine.issues(for: facts)

        #expect(issues.map(\.kind) == [.duration, .destination])
        #expect(!issues.contains { $0.title.localizedCaseInsensitiveContains("travel") })
    }

    @Test func resolvedPlaceThenRequiresSavedBusinessHours() {
        let facts = reasoningFacts(
            durationSource: .explicit,
            placeRequirement: .destination,
            destinationQuery: "Costco",
            destinationAddress: "Costco, 123 Main Street",
            requiresBusinessHours: true,
            hasSavedBusinessHours: false
        )

        #expect(TaskCompletenessEngine.issues(for: facts).map(\.kind) == [.businessHours])
    }

    @Test func anywhereTaskDoesNotNeedTravelFacts() {
        let facts = reasoningFacts(
            durationSource: .explicit,
            placeRequirement: .anywhere,
            destinationQuery: "",
            destinationAddress: "",
            requiresBusinessHours: false,
            hasSavedBusinessHours: false
        )

        #expect(TaskCompletenessEngine.issues(for: facts).isEmpty)
    }

    @Test func userConfirmedManualTaskUsesTheSameCompletenessRules() {
        let facts = TaskReasoningFacts(
            title: TaskFact("Send email", source: .userConfirmed),
            workDurationMinutes: TaskFact(20, source: .userConfirmed),
            earliestStart: TaskFact(nil, source: .unknown),
            deadline: TaskFact(nil, source: .unknown),
            priority: TaskFact(.high, source: .userConfirmed),
            canReflow: TaskFact(true, source: .userConfirmed),
            placeRequirement: TaskFact(.anywhere, source: .userConfirmed),
            destinationQuery: TaskFact("", source: .unknown),
            destinationAddress: TaskFact("", source: .unknown),
            fixedStart: TaskFact(nil, source: .unknown),
            requiresBusinessHours: false,
            hasSavedBusinessHours: false
        )

        #expect(TaskCompletenessEngine.issues(for: facts).isEmpty)
    }

    @Test func deadlineMustLeaveRoomForTheWorkDuration() {
        let start = Date(timeIntervalSince1970: 10_000)
        let facts = TaskReasoningFacts(
            title: TaskFact("Long task", source: .explicit),
            workDurationMinutes: TaskFact(60, source: .explicit),
            earliestStart: TaskFact(start, source: .explicit),
            deadline: TaskFact(
                start.addingTimeInterval(30 * 60),
                source: .explicit
            ),
            priority: TaskFact(.medium, source: .modelInferred),
            canReflow: TaskFact(true, source: .explicit),
            placeRequirement: TaskFact(.anywhere, source: .explicit),
            destinationQuery: TaskFact("", source: .unknown),
            destinationAddress: TaskFact("", source: .unknown),
            fixedStart: TaskFact(nil, source: .unknown),
            requiresBusinessHours: false,
            hasSavedBusinessHours: false
        )

        #expect(TaskCompletenessEngine.issues(for: facts).map(\.kind) == [.dateConflict])
    }

    @Test func businessHoursContainWholeTaskNotTravel() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let hours = PlaceDayHours(
            weekday: 6,
            opensAtMinutes: 9 * 60,
            closesAtMinutes: 20 * 60
        )
        let taskStart = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 31, hour: 19, minute: 30)
        )!
        let taskEnd = taskStart.addingTimeInterval(30 * 60)

        #expect(hours.contains(start: taskStart, end: taskEnd, calendar: calendar))
        #expect(!hours.contains(
            start: taskStart,
            end: taskEnd.addingTimeInterval(5 * 60),
            calendar: calendar
        ))
    }

    @Test func overnightBusinessHoursContinueIntoNextDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fridayNight = PlaceDayHours(
            weekday: 6,
            opensAtMinutes: 20 * 60,
            closesAtMinutes: 2 * 60
        )
        let start = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 31, hour: 23, minute: 30)
        )!
        let end = start.addingTimeInterval(90 * 60)

        #expect(fridayNight.contains(start: start, end: end, calendar: calendar))
    }

    @Test func multipleBusinessHourIntervalsAreSupportedPerDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let hours = [
            PlaceDayHours(
                weekday: 6,
                opensAtMinutes: 9 * 60,
                closesAtMinutes: 12 * 60
            ),
            PlaceDayHours(
                weekday: 6,
                opensAtMinutes: 14 * 60,
                closesAtMinutes: 18 * 60
            )
        ]
        let start = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 31, hour: 15)
        )!

        #expect(
            PlaceDayHours.contains(
                hours,
                start: start,
                end: start.addingTimeInterval(60 * 60),
                calendar: calendar
            )
        )
    }

    @Test func closedPlaceAdvancesToNextSameDayOpening() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let hours = [
            PlaceDayHours(
                weekday: 6,
                opensAtMinutes: 9 * 60,
                closesAtMinutes: 12 * 60
            ),
            PlaceDayHours(
                weekday: 6,
                opensAtMinutes: 14 * 60,
                closesAtMinutes: 18 * 60
            )
        ]
        let afterLunch = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 31, hour: 12, minute: 30)
        )!
        let expected = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 31, hour: 14)
        )!

        #expect(
            PlaceDayHours.nextOpening(
                after: afterLunch,
                in: hours,
                calendar: calendar
            ) == expected
        )
    }

    @Test func travelExtendsCalendarBlockWithoutChangingWorkDuration() {
        let start = Date(timeIntervalSince1970: 10_000)
        let task = FloatCalTask(
            id: "travel",
            title: "Buy cat litter",
            taskDescription: "Buy cat litter",
            startDate: start,
            endDate: start.addingTimeInterval(50 * 60),
            category: .errand,
            workDurationMinutes: 30,
            travelTimeMinutes: 20,
            deadline: nil,
            priority: .medium,
            preferredTimeOfDay: "",
            location: "Costco",
            travelMode: .driving,
            isMovable: true,
            requiresBusinessHours: true,
            reflowCount: 0,
            manualOrder: nil,
            needsDetailsReview: false
        )

        #expect(task.durationMinutes == 30)
        #expect(task.workStartDate == start.addingTimeInterval(20 * 60))
        #expect(task.endDate.timeIntervalSince(task.startDate) == 50 * 60)
    }

    @Test func rememberedPlacesMigrateWithoutSavedHours() throws {
        let legacyJSON = """
        {
          "id": "7F69E48F-A5BA-4CC6-8E76-6BF7861B3705",
          "query": "Costco",
          "name": "Costco Wholesale",
          "address": "123 Main Street",
          "origin": "Home"
        }
        """

        let place = try JSONDecoder().decode(
            PlacePreference.self,
            from: Data(legacyJSON.utf8)
        )

        #expect(place.query == "Costco")
        #expect(place.weeklyHours.isEmpty)
        #expect(place.hoursLastVerified == nil)
    }

    @Test @MainActor func rememberingAPlaceDoesNotPretendItsHoursWereReverified() {
        let suiteName = "FloatCalTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferencesStore(defaults: defaults)

        store.rememberPlace(
            query: "Costco",
            name: "Costco Wholesale",
            address: "123 Main Street",
            origin: .home
        )
        var place = store.profile.placePreferences[0]
        let verifiedAt = Date(timeIntervalSince1970: 10_000)
        place.weeklyHours = PlaceDayHours.standardWeek
        place.hoursLastVerified = verifiedAt
        store.updatePlace(place)

        store.rememberPlace(
            query: "Costco",
            name: "Costco Wholesale",
            address: "123 Main Street",
            origin: .home
        )

        #expect(store.profile.placePreferences[0].hoursLastVerified == verifiedAt)
    }

    @Test func lifestyleProfileMigratesToDrivingWithoutLosingSettings() throws {
        let legacyJSON = """
        {
          "completedOnboarding": true,
          "lifestyleDescription": "Weekdays at the office",
          "homeAddress": "100 Home Street",
          "workAddress": "200 Work Avenue",
          "workDays": [2, 3, 4, 5, 6],
          "workStartMinutes": 540,
          "workEndMinutes": 1020,
          "sleepStartMinutes": 1380,
          "sleepEndMinutes": 420,
          "protectWorkHours": true,
          "protectSleep": true,
          "usesHealthSleep": false,
          "placePreferences": []
        }
        """

        let profile = try JSONDecoder().decode(
            LifestyleProfile.self,
            from: Data(legacyJSON.utf8)
        )

        #expect(profile.homeAddress == "100 Home Street")
        #expect(profile.effectiveTravelMode == .driving)
    }

    @Test func preferredTimeIsAWindowNotAPriority() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let morning = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 31, hour: 9)
        )!
        let evening = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 31, hour: 18)
        )!

        #expect(TaskTimePreference.matches("Morning", date: morning, calendar: calendar))
        #expect(!TaskTimePreference.matches("Morning", date: evening, calendar: calendar))
        #expect(TaskTimePreference.matches("Evening", date: evening, calendar: calendar))
    }

    private func task(
        id: String,
        priority: TaskPriority,
        startDate: Date = Date(timeIntervalSince1970: 10_000),
        deadline: Date? = nil,
        manualOrder: Int? = nil,
        isMovable: Bool = true
    ) -> FloatCalTask {
        return FloatCalTask(
            id: id,
            title: id,
            taskDescription: id,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(1_800),
            category: .none,
            workDurationMinutes: 30,
            travelTimeMinutes: 0,
            deadline: deadline,
            priority: priority,
            preferredTimeOfDay: "",
            location: "",
            travelMode: nil,
            isMovable: isMovable,
            requiresBusinessHours: false,
            reflowCount: 0,
            manualOrder: manualOrder,
            needsDetailsReview: false
        )
    }

    private func reasoningFacts(
        durationSource: TaskFactSource,
        placeRequirement: TaskPlaceRequirement,
        destinationQuery: String,
        destinationAddress: String,
        requiresBusinessHours: Bool,
        hasSavedBusinessHours: Bool
    ) -> TaskReasoningFacts {
        TaskReasoningFacts(
            title: TaskFact("Buy cat litter", source: .explicit),
            workDurationMinutes: TaskFact(30, source: durationSource),
            earliestStart: TaskFact(nil, source: .unknown),
            deadline: TaskFact(nil, source: .unknown),
            priority: TaskFact(.medium, source: .modelInferred),
            canReflow: TaskFact(true, source: .defaultValue),
            placeRequirement: TaskFact(placeRequirement, source: .modelInferred),
            destinationQuery: TaskFact(destinationQuery, source: .modelInferred),
            destinationAddress: TaskFact(destinationAddress, source: .unknown),
            fixedStart: TaskFact(nil, source: .unknown),
            requiresBusinessHours: requiresBusinessHours,
            hasSavedBusinessHours: hasSavedBusinessHours
        )
    }

}
