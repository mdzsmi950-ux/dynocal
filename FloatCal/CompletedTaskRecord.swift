//
//  CompletedTaskRecord.swift
//  FloatCal
//

import Foundation
import SwiftData

@Model
final class CompletedTaskRecord {
    var id: UUID
    var title: String
    var startDate: Date
    var endDate: Date
    var completedAt: Date
    var categoryRawValue: String
    var travelTimeMinutes: Int
    var deadline: Date?
    var priorityRawValue: String
    var location: String
    var reflowCount: Int
    var calendarNotes: String?

    init(task: FloatCalTask, deletedTask: DeletedTask, completedAt: Date = Date()) {
        id = UUID()
        title = task.title
        startDate = task.startDate
        endDate = task.endDate
        self.completedAt = completedAt
        categoryRawValue = task.category.rawValue
        travelTimeMinutes = task.travelTimeMinutes
        deadline = task.deadline
        priorityRawValue = task.priority.rawValue
        location = task.location
        reflowCount = task.reflowCount
        calendarNotes = deletedTask.notes
    }

    var deletedTask: DeletedTask {
        DeletedTask(
            title: title,
            startDate: startDate,
            endDate: endDate,
            notes: calendarNotes,
            location: location
        )
    }
}
