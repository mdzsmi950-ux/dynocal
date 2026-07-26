import Foundation
import FoundationModels

struct InterpretedLifestyle {
    let workDays: [Int]
    let workStartMinutes: Int
    let workEndMinutes: Int
    let sleepStartMinutes: Int
    let sleepEndMinutes: Int
    let mentionsWork: Bool
    let mentionsSleep: Bool
}

@Generable
private enum GeneratedWeekday {
    case sunday
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday
}

@Generable
private struct GeneratedLifestyle {
    var workDays: [GeneratedWeekday]

    @Guide(description: "Work start minutes after local midnight, 0 through 1439.", .range(0...1439))
    var workStartMinutes: Int

    @Guide(description: "Work end minutes after local midnight, 0 through 1439.", .range(0...1439))
    var workEndMinutes: Int

    @Guide(description: "Usual sleep start minutes after local midnight, 0 through 1439.", .range(0...1439))
    var sleepStartMinutes: Int

    @Guide(description: "Usual wake time in minutes after local midnight, 0 through 1439.", .range(0...1439))
    var sleepEndMinutes: Int

    @Guide(description: "True only when the description mentions a job, work schedule, school, or other recurring occupied daytime schedule.")
    var mentionsWork: Bool

    @Guide(description: "True only when the description mentions sleep, bedtime, or wake time.")
    var mentionsSleep: Bool
}

final class LifestyleInterpreter {
    static let shared = LifestyleInterpreter()

    private init() {}

    var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    func interpret(_ description: String) async throws -> InterpretedLifestyle {
        let session = LanguageModelSession(instructions: """
            Extract a person's normal weekly work and sleep routine.
            Treat "weekdays" as Monday through Friday. Preserve stated times exactly.
            Do not infer sleep times when none are supplied. Return local clock minutes.
            """)
        let response = try await session.respond(
            to: "Lifestyle description: \(description)",
            generating: GeneratedLifestyle.self
        )
        let result = response.content

        return InterpretedLifestyle(
            workDays: result.workDays.map(weekdayNumber),
            workStartMinutes: result.workStartMinutes,
            workEndMinutes: result.workEndMinutes,
            sleepStartMinutes: result.sleepStartMinutes,
            sleepEndMinutes: result.sleepEndMinutes,
            mentionsWork: result.mentionsWork,
            mentionsSleep: result.mentionsSleep
        )
    }

    private func weekdayNumber(_ weekday: GeneratedWeekday) -> Int {
        switch weekday {
        case .sunday: 1
        case .monday: 2
        case .tuesday: 3
        case .wednesday: 4
        case .thursday: 5
        case .friday: 6
        case .saturday: 7
        }
    }
}
