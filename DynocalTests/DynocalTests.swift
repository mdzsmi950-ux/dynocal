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
