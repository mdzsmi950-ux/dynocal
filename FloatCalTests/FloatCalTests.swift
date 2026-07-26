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

    @Test func highPriorityOrDeadlineTasksCannotBeSilentlyDeferred() {
        let ordinary = task(id: "ordinary", priority: .medium)
        let high = task(id: "high", priority: .high)
        let timed = task(
            id: "timed",
            priority: .low,
            deadline: Date(timeIntervalSince1970: 30_000)
        )

        #expect(!ordinary.requiresGuaranteedPlacement)
        #expect(high.requiresGuaranteedPlacement)
        #expect(timed.requiresGuaranteedPlacement)
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
            ) == DateComponents(year: 2026, month: 8, day: 27, hour: 9, minute: 0)
        )
        #expect(
            calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: range!.deadline
            ) == DateComponents(year: 2026, month: 9, day: 17, hour: 23, minute: 59)
        )
    }

    @Test func timeOfDayMustBeExplicit() {
        #expect(!TaskTextConstraints.hasExplicitTimeOfDay(in: "Buy cat litter during the sale"))
        #expect(TaskTextConstraints.hasExplicitTimeOfDay(in: "Buy cat litter in the evening"))
        #expect(TaskTextConstraints.hasExplicitTimeOfDay(in: "Buy cat litter after 5 p.m."))
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
        manualOrder: Int? = nil
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
            isMovable: true,
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
