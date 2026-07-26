import Foundation

enum TaskFactSource: String, Codable, Equatable {
    case explicit
    case userConfirmed
    case rememberedPreference
    case calendarDerived
    case mapDerived
    case modelInferred
    case defaultValue
    case unknown
}

enum TaskFactScope: String, Codable, Equatable {
    case thisTask
    case rememberedPreference
}

struct TaskFact<Value: Equatable>: Equatable {
    var value: Value
    var source: TaskFactSource
    var scope: TaskFactScope
    var evidence: String?

    init(
        _ value: Value,
        source: TaskFactSource,
        scope: TaskFactScope = .thisTask,
        evidence: String? = nil
    ) {
        self.value = value
        self.source = source
        self.scope = scope
        self.evidence = evidence
    }
}

enum TaskPlaceRequirement: String, Codable, Equatable {
    case anywhere
    case destination
}

enum TaskClarificationKind: String, Equatable, Identifiable {
    case title
    case duration
    case fixedStart
    case destination
    case businessHours
    case dateConflict

    var id: String { rawValue }
}

struct TaskClarificationIssue: Equatable, Identifiable {
    let kind: TaskClarificationKind
    let title: String
    let explanation: String

    var id: TaskClarificationKind { kind }
}

struct TaskReasoningFacts: Equatable {
    var title: TaskFact<String>
    var workDurationMinutes: TaskFact<Int>
    var earliestStart: TaskFact<Date?>
    var deadline: TaskFact<Date?>
    var priority: TaskFact<TaskPriority>
    var canReflow: TaskFact<Bool>
    var placeRequirement: TaskFact<TaskPlaceRequirement>
    var destinationQuery: TaskFact<String>
    var destinationAddress: TaskFact<String>
    var fixedStart: TaskFact<Date?>
    var requiresBusinessHours: Bool
    var hasSavedBusinessHours: Bool
}

struct TaskCompletenessEngine {
    static func issues(for facts: TaskReasoningFacts) -> [TaskClarificationIssue] {
        var issues: [TaskClarificationIssue] = []

        if facts.title.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(
                TaskClarificationIssue(
                    kind: .title,
                    title: "What should I call this task?",
                    explanation: "Every task needs a short action title."
                )
            )
        }

        if facts.workDurationMinutes.value <= 0
            || facts.workDurationMinutes.source == .modelInferred
            || facts.workDurationMinutes.source == .defaultValue
            || facts.workDurationMinutes.source == .unknown {
            issues.append(
                TaskClarificationIssue(
                    kind: .duration,
                    title: "How long will the task itself take?",
                    explanation: "Travel is calculated separately for every possible time slot."
                )
            )
        }

        if facts.canReflow.value == false, facts.fixedStart.value == nil {
            issues.append(
                TaskClarificationIssue(
                    kind: .fixedStart,
                    title: "When is this fixed task?",
                    explanation: "A task that cannot reflow needs an exact start time."
                )
            )
        }

        if facts.placeRequirement.value == .destination,
           facts.destinationAddress.value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty {
            let query = facts.destinationQuery.value
                .trimmingCharacters(in: .whitespacesAndNewlines)
            issues.append(
                TaskClarificationIssue(
                    kind: .destination,
                    title: query.isEmpty ? "Where does this happen?" : "Which \(query)?",
                    explanation: "Dynocal needs one exact destination before it can calculate travel."
                )
            )
        }

        if facts.requiresBusinessHours,
           facts.placeRequirement.value == .destination,
           !facts.destinationAddress.value.isEmpty,
           !facts.hasSavedBusinessHours {
            issues.append(
                TaskClarificationIssue(
                    kind: .businessHours,
                    title: "What hours is this place open?",
                    explanation: "Save the weekly hours once and Dynocal will reuse them."
                )
            )
        }

        if let earliestStart = facts.earliestStart.value,
           let deadline = facts.deadline.value,
           deadline <= earliestStart {
            issues.append(
                TaskClarificationIssue(
                    kind: .dateConflict,
                    title: "Check the timing",
                    explanation: "The deadline must be later than the earliest allowed start."
                )
            )
        }

        return issues
    }
}
