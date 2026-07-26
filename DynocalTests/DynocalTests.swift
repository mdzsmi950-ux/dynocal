//
//  DynocalTests.swift
//  DynocalTests
//
//  Created by Maddie Smith on 5/22/26.
//

import Foundation
import Testing
@testable import Dynocal

struct DynocalTests {

    @Test func higherPriorityTasksSortFirst() {
        let low = task(id: "low", priority: .low)
        let high = task(id: "high", priority: .high)

        let ordered = [low, high].sorted(by: DynocalTask.isOrderedBefore)

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

        let ordered = [later, sooner].sorted(by: DynocalTask.isOrderedBefore)

        #expect(ordered.map(\.id) == ["sooner", "later"])
    }

    @Test func manualOrderOverridesPriority() {
        let high = task(id: "high", priority: .high, manualOrder: 1)
        let low = task(id: "low", priority: .low, manualOrder: 0)

        let ordered = [high, low].sorted(by: DynocalTask.isOrderedBefore)

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

        let ordered = DynocalTask.sorted([later, sooner], by: .time)

        #expect(ordered.map(\.id) == ["sooner", "later"])
    }

    @Test func deadlineSortPlacesTasksWithoutDeadlinesLast() {
        let noDeadline = task(id: "none", priority: .high)
        let deadline = task(
            id: "deadline",
            priority: .low,
            deadline: Date(timeIntervalSince1970: 30_000)
        )

        let ordered = DynocalTask.sorted([noDeadline, deadline], by: .deadline)

        #expect(ordered.map(\.id) == ["deadline", "none"])
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

    private func task(
        id: String,
        priority: TaskPriority,
        startDate: Date = Date(timeIntervalSince1970: 10_000),
        deadline: Date? = nil,
        manualOrder: Int? = nil
    ) -> DynocalTask {
        return DynocalTask(
            id: id,
            title: id,
            taskDescription: id,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(1_800),
            category: .none,
            travelTimeMinutes: 0,
            deadline: deadline,
            priority: priority,
            location: "",
            isMovable: true,
            reflowCount: 0,
            manualOrder: manualOrder
        )
    }

}
