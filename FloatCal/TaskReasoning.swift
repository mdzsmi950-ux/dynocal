import Foundation

nonisolated enum TaskFactSource: String, Codable, Equatable {
    case explicit
    case userConfirmed
    case rememberedPreference
    case calendarDerived
    case mapDerived
    case modelInferred
    case defaultValue
    case unknown
}

nonisolated enum TaskFactScope: String, Codable, Equatable {
    case thisTask
    case rememberedPreference
}

nonisolated struct TaskFact<Value: Equatable>: Equatable {
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

nonisolated enum TaskPlaceRequirement: String, Codable, Equatable {
    case anywhere
    case destination
}

nonisolated enum TaskClarificationKind: String, Equatable, Identifiable {
    case title
    case duration
    case fixedStart
    case destination
    case businessHours
    case timing
    case dateConflict

    var id: String { rawValue }
}

nonisolated struct TaskClarificationIssue: Equatable, Identifiable {
    let kind: TaskClarificationKind
    let title: String
    let explanation: String

    var id: TaskClarificationKind { kind }
}

nonisolated struct TaskReasoningFacts: Equatable {
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

nonisolated struct TaskCompletenessEngine {
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

        let startNeedsConfirmation = facts.earliestStart.value != nil
            && facts.earliestStart.source == .modelInferred
        let deadlineNeedsConfirmation = facts.deadline.value != nil
            && facts.deadline.source == .modelInferred
        if startNeedsConfirmation || deadlineNeedsConfirmation {
            issues.append(
                TaskClarificationIssue(
                    kind: .timing,
                    title: "Confirm the timing",
                    explanation: "FloatCal found a timing clue, but it was not explicit enough to treat as a hard fact."
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
                    explanation: "FloatCal needs one exact destination before it can calculate travel."
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
                    explanation: "Save the weekly hours once and FloatCal will reuse them."
                )
            )
        }

        if let earliestStart = facts.earliestStart.value,
           let deadline = facts.deadline.value,
           deadline < earliestStart.addingTimeInterval(
                TimeInterval(max(0, facts.workDurationMinutes.value) * 60)
           ) {
            issues.append(
                TaskClarificationIssue(
                    kind: .dateConflict,
                    title: "Check the timing",
                    explanation: "The window must be long enough for the task itself. Travel may require additional room."
                )
            )
        }

        return issues
    }
}
