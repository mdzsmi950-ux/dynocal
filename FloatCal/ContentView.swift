//
//  ContentView.swift
//  FloatCal
//
//  Created by Maddie Smith on 5/22/26.
//

import SwiftUI
import SwiftData
import UIKit

private enum TaskSaveAlert {
    case overdue
    case fixedConflict
    case placementFailure(String)
}

struct ContentView: View {
    private let calendarService = CalendarService.shared
    private let taskInterpreter = TaskInterpreter.shared

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var preferences: PreferencesStore
    @Query(sort: \CompletedTaskRecord.completedAt, order: .reverse)
    private var completedTasks: [CompletedTaskRecord]

    @State private var statusText: String?
    @State private var hasCalendarAccess = CalendarService.shared.hasCalendarAccess
    @State private var calendarAccessIsDenied = CalendarService.shared.calendarAccessIsDenied
    @State private var isCreatingTask = false
    @State private var isReflowing = false
    @State private var isShowingNewTaskSheet = false
    @State private var editingTask: FloatCalTask?
    @State private var tasks: [FloatCalTask] = []
    @State private var conflictingTaskIDs: Set<String> = []
    @State private var reflowCandidateIDs: Set<String> = []
    @State private var newTaskTitle = ""
    @State private var newTaskDescription = ""
    @State private var newTaskStartDate = Self.defaultTaskStartDate()
    @State private var newTaskStartSource = TaskFactSource.defaultValue
    @State private var newTaskDurationMinutes = 30
    @State private var newTaskDurationSource = TaskFactSource.defaultValue
    @State private var newTaskCategory = TaskCategory.none
    @State private var newTaskHasDeadline = false
    @State private var newTaskDeadline = Self.defaultTaskStartDate()
    @State private var newTaskDeadlineSource = TaskFactSource.unknown
    @State private var newTaskPriority = TaskPriority.medium
    @State private var newTaskLocation = ""
    @State private var newTaskDestinationQuery = ""
    @State private var newTaskDestinationSource = TaskFactSource.unknown
    @State private var newTaskPlaceRequirement = TaskPlaceRequirement.anywhere
    @State private var newTaskTravelMode: TravelMode?
    @State private var newTaskRequiresBusinessHours = false
    @State private var newTaskIsMovable = true
    @State private var isInterpretingTask = false
    @State private var hasAttemptedAnalysis = false
    @State private var taskInterpretationMessage: String?
    @State private var interpretedTimePreference = ""
    @State private var isManualMode = false
    @State private var isShowingOptionalDetails = false
    @State private var isShowingSettings = false
    @State private var isShowingClarification = false
    @State private var clarificationIssues: [TaskClarificationIssue] = []
    @State private var dictationPrefix = ""
    @StateObject private var speechInput = SpeechInputService()
    @AppStorage("taskSortMode") private var taskSortModeRawValue = TaskSortMode.priority.rawValue
    @State private var isAdjustingPriority = false
    @State private var priorityDraftTaskIDs: [String] = []
    @State private var taskEditMode: EditMode = .inactive
    @State private var taskNeedingReview: FloatCalTask?
    @State private var promptedReviewTaskIDs: Set<String> = []
    @State private var taskSaveAlert: TaskSaveAlert?
    @State private var hasConfirmedPastStart = false
    @State private var activeReflowIssue: ReflowIssue?
    @State private var queuedReflowIssues: [ReflowIssue] = []
    @State private var lastReflowSnapshot: [FloatCalTask] = []

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Form {
                    if !hasCalendarAccess {
                        calendarAccessSection
                    } else {
                        tasksSection
                    }

                    completedHistorySection

                    if let statusText {
                        Section {
                            Label(statusText, systemImage: "info.circle")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: 118)
                }
                .environment(\.editMode, $taskEditMode)

                if hasCalendarAccess {
                    PButton(
                        isProcessing: isReflowing,
                        taskCount: reflowCandidateIDs.count
                    ) {
                        reflowTasks()
                    }
                    .padding(.bottom, 16)
                }
            }
            .navigationTitle("FloatCal")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        undoLastAction()
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(
                        (lastReflowSnapshot.isEmpty && completedTasks.isEmpty)
                            || !hasCalendarAccess
                            || isAdjustingPriority
                    )
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .disabled(isAdjustingPriority)

                    Menu {
                        Picker("Sort Tasks", selection: $taskSortModeRawValue) {
                            ForEach(TaskSortMode.allCases) { mode in
                                Label(mode.rawValue, systemImage: mode.systemImage)
                                    .tag(mode.rawValue)
                            }
                        }

                        if hasManualOrder {
                            Divider()

                            Button {
                                resetToPriorityOrder()
                            } label: {
                                Label("Reset Priority Adjustments", systemImage: "arrow.uturn.backward")
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .disabled(isAdjustingPriority)

                    Button {
                        beginNewTask()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!hasCalendarAccess || isAdjustingPriority)
                }
            }
            .onAppear {
                loadInitialCalendarState()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    loadInitialCalendarState()
                }
            }
            .onChange(of: isShowingNewTaskSheet) { wasShowing, isShowing in
                if wasShowing, !isShowing {
                    presentNextReflowIssue()
                }
            }
            .sheet(isPresented: $isShowingNewTaskSheet) {
                newTaskSheet
            }
            .sheet(isPresented: $isShowingSettings) {
                LifestyleSettingsView(isOnboarding: false)
                    .environmentObject(preferences)
            }
            .fullScreenCover(
                isPresented: Binding(
                    get: { !preferences.profile.completedOnboarding },
                    set: { _ in }
                )
            ) {
                LifestyleSettingsView(isOnboarding: true)
                    .environmentObject(preferences)
                    .interactiveDismissDisabled()
            }
            .onDisappear {
                speechInput.stop()
            }
            .alert(
                "Task Details Needed",
                isPresented: Binding(
                    get: { taskNeedingReview != nil },
                    set: { if !$0 { taskNeedingReview = nil } }
                ),
                presenting: taskNeedingReview
            ) { task in
                Button("Review Now") {
                    taskNeedingReview = nil
                    beginEditing(task)
                }
                Button("Later", role: .cancel) {
                    taskNeedingReview = nil
                }
            } message: { task in
                Text("“\(task.title)” was added directly to the FloatCal calendar. Review its duration, priority, and whether FloatCal may reflow it.")
            }
            .alert(
                "Task Couldn’t Reflow",
                isPresented: Binding(
                    get: { activeReflowIssue != nil },
                    set: { if !$0 { activeReflowIssue = nil } }
                ),
                presenting: activeReflowIssue
            ) { issue in
                Button("Edit Task") {
                    activeReflowIssue = nil
                    beginEditing(issue.task)
                }
                Button("Keep It Here", role: .cancel) {
                    activeReflowIssue = nil
                    Task {
                        await Task.yield()
                        presentNextReflowIssue()
                    }
                }
            } message: { issue in
                Text("“\(issue.task.title)” stayed where it was scheduled. \(issue.reason)")
            }
        }
    }

    private var taskSortMode: TaskSortMode {
        TaskSortMode(rawValue: taskSortModeRawValue) ?? .priority
    }

    private var displayedTasks: [FloatCalTask] {
        guard isAdjustingPriority else {
            return FloatCalTask.sorted(tasks, by: taskSortMode)
        }

        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let draftedTasks = priorityDraftTaskIDs.compactMap { tasksByID[$0] }
        let draftedIDs = Set(priorityDraftTaskIDs)
        let missingTasks = FloatCalTask.sorted(
            tasks.filter { !draftedIDs.contains($0.id) },
            by: .priority
        )

        return draftedTasks + missingTasks
    }

    private var hasManualOrder: Bool {
        tasks.contains { $0.manualOrder != nil }
    }

    private var calendarAccessSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label("Calendar Access", systemImage: "calendar.badge.plus")
                    .font(.headline)

                Text("FloatCal needs Calendar access to place tasks on your calendar and move them when plans change.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button {
                    requestCalendarAccess()
                } label: {
                    Label("Allow Access", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)

                if calendarAccessIsDenied {
                    Button {
                        if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                            openURL(settingsURL)
                        }
                    } label: {
                        Label("Open Settings", systemImage: "gear")
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var tasksSection: some View {
        Section {
            if tasks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No Tasks")
                        .font(.headline)

                    Text("Tap + above to add a task.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
            } else {
                ForEach(displayedTasks) { task in
                    taskRow(task)
                        .swipeActions(edge: .leading) {
                            Button {
                                beginEditing(task)
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Done", role: .destructive) {
                                completeTask(task)
                            }
                        }
                }
                .onMove(perform: moveTasks)
                .moveDisabled(!isAdjustingPriority)
            }
        } header: {
            HStack {
                Text("Tasks")

                Spacer()

                if taskSortMode == .priority {
                    if isAdjustingPriority {
                        Button("Cancel") {
                            cancelPriorityAdjustment()
                        }
                        .font(.caption)
                        .textCase(nil)

                        Button("Save") {
                            savePriorityAdjustment()
                        }
                        .font(.caption.bold())
                        .textCase(nil)
                    } else {
                        Button("Adjust") {
                            beginPriorityAdjustment()
                        }
                        .disabled(tasks.count < 2)
                        .font(.caption)
                        .textCase(nil)
                    }
                }
            }
        }
    }

    private var completedHistorySection: some View {
        Section {
            NavigationLink {
                CompletedTasksView { restoredTask in
                    upsertTask(restoredTask)
                    statusText = "Recovered \(restoredTask.title)."
                }
            } label: {
                HStack {
                    Label("Completed", systemImage: "checkmark.circle")

                    Spacer()

                    Text("\(completedTasks.count)")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var newTaskSheet: some View {
        NavigationStack {
            Form {
                Section("What do you need to do?") {
                    ZStack(alignment: .topLeading) {
                        if newTaskDescription.isEmpty {
                            Text("Describe the task, timing, and anything FloatCal should know...")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }

                        TextEditor(text: $newTaskDescription)
                            .frame(minHeight: 150)
                            .scrollContentBackground(.hidden)
                    }

                    HStack {
                        Button {
                            toggleVoiceInput()
                        } label: {
                            Image(systemName: speechInput.isRecording ? "stop.fill" : "mic.fill")
                        }
                        .accessibilityLabel(speechInput.isRecording ? "Stop speaking" : "Speak")
                        .tint(speechInput.isRecording ? .red : .accentColor)
                        .buttonStyle(.borderless)

                        Spacer()

                        switch taskInterpreter.availability {
                        case .available:
                            Button {
                                interpretTaskDescription()
                            } label: {
                                Label(
                                    isInterpretingTask ? "Analyzing..." : "Analyze",
                                    systemImage: "apple.intelligence"
                                )
                            }
                            .disabled(
                                newTaskDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || isInterpretingTask
                                    || speechInput.isRecording
                            )
                            .buttonStyle(.borderless)
                        case .unavailable:
                            EmptyView()
                        }
                    }

                    if let message = speechInput.message ?? taskInterpretationMessage {
                        Label(
                            message,
                            systemImage: message.hasPrefix("Analyzed") ? "checkmark.circle.fill" : "info.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(message.hasPrefix("Analyzed") ? .green : .secondary)
                    }

                    if isInterpretingTask {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Analyzing task details…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Task Details") {
                    taskDetailControls
                }

                Section {
                    manualCompletenessChecklist
                } header: {
                    Text(manualIssues.isEmpty ? "Complete" : "Still Needed")
                } footer: {
                    Text("FloatCal uses the same scheduling rules with or without Apple Intelligence.")
                }
            }
            .navigationTitle(editingTask == nil ? "New Task" : "Edit Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        speechInput.stop()
                        isShowingNewTaskSheet = false
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        isInterpretingTask
                            ? "Analyzing..."
                            : (isCreatingTask
                                ? "Saving..."
                                : (editingTask == nil ? "Create" : "Save"))
                    ) {
                        saveTask()
                    }
                    .disabled(!canCreateTask)
                }
            }
            .sheet(isPresented: $isShowingClarification) {
                TaskClarificationView(
                    issues: clarificationIssues,
                    locationQuery: newTaskDestinationQuery,
                    origin: clarificationOrigin,
                    originAddress: clarificationOriginAddress,
                    confirmationTitle: editingTask == nil ? "Create Task" : "Save Task",
                    title: $newTaskTitle,
                    durationMinutes: confirmedDurationBinding,
                    startDate: confirmedStartBinding,
                    hasDeadline: confirmedHasDeadlineBinding,
                    deadline: confirmedDeadlineBinding,
                    location: $newTaskLocation,
                    onTimingConfirmed: {
                        newTaskStartSource = .userConfirmed
                        if newTaskHasDeadline {
                            newTaskDeadlineSource = .userConfirmed
                        }
                    },
                    onPlaceSelected: {
                        newTaskDestinationSource = .userConfirmed
                        refreshClarificationIssues()
                    }
                ) {
                    saveTask()
                }
                .environmentObject(preferences)
            }
            .alert(
                taskSaveAlertTitle,
                isPresented: Binding(
                    get: { taskSaveAlert != nil },
                    set: { if !$0 { taskSaveAlert = nil } }
                )
            ) {
                switch taskSaveAlert {
                case .overdue:
                    Button("Create as Overdue") {
                        hasConfirmedPastStart = true
                        taskSaveAlert = nil
                        saveTask()
                    }
                    Button("Edit Timing", role: .cancel) {
                        taskSaveAlert = nil
                    }
                case .fixedConflict:
                    Button("Save Anyway") {
                        taskSaveAlert = nil
                        saveTask(allowFixedConflict: true)
                    }
                    Button("Edit Task", role: .cancel) {
                        taskSaveAlert = nil
                    }
                case .placementFailure:
                    Button("Save Anyway") {
                        taskSaveAlert = nil
                        saveTask(saveAtRequestedTime: true)
                    }
                    Button("Edit Task", role: .cancel) {
                        taskSaveAlert = nil
                    }
                case nil:
                    Button("OK", role: .cancel) {}
                }
            } message: {
                Text(taskSaveAlertMessage)
            }
        }
    }

    @ViewBuilder
    private var taskDetailControls: some View {
        TextField("Task Name", text: $newTaskTitle)

        DatePicker(
            newTaskIsMovable ? "Earliest Start" : "Task Starts",
            selection: confirmedStartBinding,
            displayedComponents: [.date, .hourAndMinute]
        )

        Stepper(
            "Task Duration: \(newTaskDurationMinutes) min",
            value: confirmedDurationBinding,
            in: 5...480,
            step: 5
        )

        if ![TaskFactSource.explicit, .userConfirmed].contains(newTaskDurationSource) {
            Button("Confirm \(newTaskDurationMinutes) Minutes") {
                newTaskDurationSource = .userConfirmed
            }
        }

        if !newTaskIsMovable,
           ![TaskFactSource.explicit, .userConfirmed].contains(newTaskStartSource) {
            Button("Confirm This Start Time") {
                newTaskStartSource = .userConfirmed
            }
        }

        DisclosureGroup(
            "Optional Details",
            isExpanded: $isShowingOptionalDetails
        ) {
            Toggle("Can I reflow this task?", isOn: $newTaskIsMovable)

            Toggle("Deadline", isOn: confirmedHasDeadlineBinding)

            if newTaskHasDeadline {
                DatePicker(
                    "Due",
                    selection: confirmedDeadlineBinding,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }

            Picker("Preferred Time", selection: $interpretedTimePreference) {
                Text("Any Time").tag("")
                Text("Morning").tag("Morning")
                Text("Afternoon").tag("Afternoon")
                Text("Evening").tag("Evening")
                Text("Night").tag("Night")
            }

            Picker("Where", selection: placeRequirementBinding) {
                Text("Anywhere").tag(TaskPlaceRequirement.anywhere)
                Text("At a Place").tag(TaskPlaceRequirement.destination)
            }

            if newTaskPlaceRequirement == .destination {
                TextField(
                    "Exact destination",
                    text: confirmedLocationBinding
                )

                if let missingTravelAddressWarning {
                    Text(missingTravelAddressWarning)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Picker("Travel", selection: $newTaskTravelMode) {
                    Text("Lifestyle Default").tag(nil as TravelMode?)
                    ForEach(TravelMode.allCases) { mode in
                        Label(mode.rawValue, systemImage: mode.systemImage)
                            .tag(Optional(mode))
                    }
                }

                Toggle(
                    "Place has opening hours",
                    isOn: $newTaskRequiresBusinessHours
                )
            }

            Picker("Category", selection: $newTaskCategory) {
                ForEach(TaskCategory.allCases) { category in
                    Text(category.rawValue).tag(category)
                }
            }

            Picker("Priority", selection: $newTaskPriority) {
                ForEach(TaskPriority.allCases) { priority in
                    Text(priority.rawValue).tag(priority)
                }
            }
        }
    }

    private var missingTravelAddressWarning: String? {
        let profile = preferences.profile
        switch profile.expectedOrigin(at: newTaskStartDate) {
        case .home where profile.homeAddress
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return "Travel time cannot be accounted for until a Home address is added in Settings."
        case .work where profile.workAddress
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return "Travel time cannot be accounted for until a Work address is added in Settings."
        case .either where profile.homeAddress
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && profile.workAddress
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return "Travel time cannot be accounted for until a Home or Work address is added in Settings."
        default:
            return nil
        }
    }

    @ViewBuilder
    private var manualCompletenessChecklist: some View {
        if manualIssues.isEmpty {
            Label("Ready to schedule", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            ForEach(manualIssues) { issue in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.title)
                        Text(issue.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "circle")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func taskRow(_ task: FloatCalTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(task.title)
                    .font(.headline)

                Spacer()

                taskStatusView(task)
            }

            Text("\(task.startDate.formatted(date: .abbreviated, time: .shortened)) – \(task.endDate.formatted(date: .omitted, time: .shortened))")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func taskStatusView(_ task: FloatCalTask) -> some View {
        HStack(spacing: 6) {
            if task.needsDetailsReview {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Needs task details")
            } else if task.startDate < Date() {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Overdue")
            } else {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Planned")
            }

            if conflictingTaskIDs.contains(task.id) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Conflicts with another calendar event")
            }

            if task.reflowCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("×\(task.reflowCount)")
                }
                .foregroundStyle(.blue)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Reflowed \(task.reflowCount) times")
            }
        }
        .font(.body.weight(.semibold))
    }

    private var canCreateTask: Bool {
        (
            !newTaskDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
            && hasCalendarAccess
            && !isCreatingTask
            && !isInterpretingTask
            && !speechInput.isRecording
    }

    private var taskSaveAlertTitle: String {
        switch taskSaveAlert {
        case .overdue:
            return "This Task Is Already Overdue"
        case .fixedConflict:
            return "This Fixed Time Conflicts"
        case .placementFailure:
            return "This Task Can’t Be Placed Safely"
        case nil:
            return ""
        }
    }

    private var taskSaveAlertMessage: String {
        switch taskSaveAlert {
        case .overdue:
            return "The earliest start has already passed. Create it on the calendar as overdue so you can Reflow it, or edit the timing first."
        case .fixedConflict:
            return "This fixed task overlaps another calendar event or protected work/sleep time, including any required travel. Override it only if this commitment takes precedence."
        case let .placementFailure(reason):
            return "\(reason) Save it at the requested time anyway, or edit its details first. Reflow can reconcile it later."
        case nil:
            return ""
        }
    }

    private func beginNewTask() {
        editingTask = nil
        newTaskTitle = ""
        newTaskDescription = ""
        newTaskStartDate = Self.defaultTaskStartDate()
        newTaskStartSource = .defaultValue
        newTaskDurationMinutes = 30
        newTaskDurationSource = .defaultValue
        newTaskCategory = .none
        newTaskHasDeadline = false
        newTaskDeadline = newTaskStartDate
        newTaskDeadlineSource = .unknown
        newTaskPriority = .medium
        newTaskLocation = ""
        newTaskDestinationQuery = ""
        newTaskDestinationSource = .unknown
        newTaskPlaceRequirement = .anywhere
        newTaskTravelMode = nil
        newTaskRequiresBusinessHours = false
        newTaskIsMovable = true
        taskInterpretationMessage = nil
        interpretedTimePreference = ""
        hasAttemptedAnalysis = false
        isManualMode = true
        isShowingOptionalDetails = false
        clarificationIssues = []
        isShowingClarification = false
        dictationPrefix = ""
        taskSaveAlert = nil
        hasConfirmedPastStart = false

        if case .unavailable(let reason) = taskInterpreter.availability {
            taskInterpretationMessage = "\(reason) Manual entry is ready."
        }

        isShowingNewTaskSheet = true
    }

    private func beginEditing(_ task: FloatCalTask) {
        editingTask = task
        newTaskTitle = task.title
        newTaskDescription = task.taskDescription
        newTaskStartDate = task.isMovable ? task.startDate : task.workStartDate
        newTaskStartSource = .userConfirmed
        newTaskDurationMinutes = task.durationMinutes
        newTaskDurationSource = .userConfirmed
        newTaskCategory = task.category
        newTaskHasDeadline = task.deadline != nil
        newTaskDeadline = task.deadline ?? task.startDate
        newTaskDeadlineSource = task.deadline == nil ? .unknown : .userConfirmed
        newTaskPriority = task.priority
        newTaskLocation = task.location
        newTaskDestinationQuery = preferences.place(matching: task.location)?.query
            ?? task.location
        newTaskDestinationSource = task.location.isEmpty ? .unknown : .userConfirmed
        newTaskPlaceRequirement = task.location.isEmpty ? .anywhere : .destination
        newTaskTravelMode = task.travelMode
        newTaskRequiresBusinessHours = task.requiresBusinessHours
        newTaskIsMovable = task.isMovable
        taskInterpretationMessage = nil
        interpretedTimePreference = task.preferredTimeOfDay
        hasAttemptedAnalysis = false
        isManualMode = true
        isShowingOptionalDetails = true
        clarificationIssues = []
        dictationPrefix = ""
        taskSaveAlert = nil
        hasConfirmedPastStart = false
        isShowingNewTaskSheet = true
    }

    private func requestCalendarAccess() {
        Task {
            do {
                let granted = try await calendarService.requestAccess()
                hasCalendarAccess = granted
                calendarAccessIsDenied = calendarService.calendarAccessIsDenied

                if granted {
                    statusText = nil
                    refreshTasks()
                } else {
                    statusText = "Calendar access denied"
                }
            } catch {
                hasCalendarAccess = calendarService.hasCalendarAccess
                calendarAccessIsDenied = calendarService.calendarAccessIsDenied
                statusText = "Calendar access failed: \(error.localizedDescription)"
            }
        }
    }

    private func toggleVoiceInput() {
        if !speechInput.isRecording {
            let trimmedText = newTaskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            dictationPrefix = trimmedText.isEmpty ? "" : "\(trimmedText) "
        }

        let prefixAtRecordingStart = dictationPrefix
        speechInput.toggle { transcription in
            guard !transcription.isEmpty else { return }
            newTaskDescription = prefixAtRecordingStart + transcription
            taskInterpretationMessage = nil
        }
    }

    private func interpretTaskDescription(automaticallyCreate: Bool = false) {
        let description = newTaskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty, !isInterpretingTask else { return }

        switch taskInterpreter.availability {
        case .available:
            break
        case .unavailable(let reason):
            isManualMode = true
            taskInterpretationMessage = "\(reason) Manual entry is ready."
            return
        }

        isManualMode = false
        isInterpretingTask = true
        hasAttemptedAnalysis = true
        taskInterpretationMessage = nil

        Task {
            do {
                let draft = try await taskInterpreter.interpret(description)

                newTaskTitle = draft.title
                newTaskDurationMinutes = draft.durationMinutes
                newTaskDurationSource = draft.durationSource
                newTaskCategory = draft.category
                newTaskPriority = draft.priority
                newTaskDestinationQuery = draft.destinationQuery
                newTaskPlaceRequirement = draft.placeRequirement
                newTaskLocation = ""
                newTaskDestinationSource = .unknown
                newTaskTravelMode = draft.placeRequirement == .destination
                    ? draft.travelMode
                    : nil
                newTaskRequiresBusinessHours = draft.requiresBusinessHours
                interpretedTimePreference = draft.preferredTimeOfDay
                newTaskIsMovable = !draft.isFixed
                isShowingOptionalDetails = draft.isFixed
                    || draft.deadline != nil
                    || draft.placeRequirement == .destination
                    || !draft.preferredTimeOfDay.isEmpty
                    || draft.category != .none
                    || draft.priority != .medium

                if let startDate = draft.startDate {
                    newTaskStartDate = startDate
                    newTaskStartSource = draft.startSource
                } else {
                    newTaskStartSource = .defaultValue
                }

                if let deadline = draft.deadline {
                    newTaskHasDeadline = true
                    newTaskDeadline = deadline
                    newTaskDeadlineSource = draft.deadlineSource
                } else {
                    newTaskHasDeadline = false
                    newTaskDeadlineSource = .unknown
                }

                if !draft.destinationQuery.isEmpty,
                   let savedPlace = preferences.preferredPlace(
                       for: draft.destinationQuery,
                       origin: clarificationOrigin
                   ) {
                    newTaskLocation = savedPlace.address
                    newTaskDestinationSource = .rememberedPreference
                }

                refreshClarificationIssues()
                isShowingClarification = !clarificationIssues.isEmpty

                if draft.requiresBusinessHours {
                    taskInterpretationMessage = "Analyzed with Apple Intelligence. Confirm the location and timing because current business hours aren’t available."
                } else {
                    taskInterpretationMessage = "Analyzed with Apple Intelligence. Review before creating."
                }

                isInterpretingTask = false

                if automaticallyCreate, clarificationIssues.isEmpty {
                    saveTask()
                }
            } catch {
                isManualMode = true
                taskInterpretationMessage = "Apple Intelligence couldn’t fill the details: \(error.localizedDescription)"
                isInterpretingTask = false
            }
        }
    }

    private var clarificationOrigin: PlaceOrigin {
        let inferredOrigin = preferences.profile.expectedOrigin(at: newTaskStartDate)

        if inferredOrigin == .work, !preferences.profile.workAddress.isEmpty {
            return inferredOrigin
        }

        return preferences.profile.homeAddress.isEmpty ? .either : .home
    }

    private var clarificationOriginAddress: String {
        switch clarificationOrigin {
        case .home:
            preferences.profile.homeAddress
        case .work:
            preferences.profile.workAddress
        case .either:
            preferences.profile.homeAddress.isEmpty
                ? preferences.profile.workAddress
                : preferences.profile.homeAddress
        }
    }

    private var confirmedDurationBinding: Binding<Int> {
        Binding(
            get: { newTaskDurationMinutes },
            set: {
                newTaskDurationMinutes = $0
                newTaskDurationSource = .userConfirmed
            }
        )
    }

    private var confirmedStartBinding: Binding<Date> {
        Binding(
            get: { newTaskStartDate },
            set: {
                newTaskStartDate = $0
                newTaskStartSource = .userConfirmed
            }
        )
    }

    private var confirmedHasDeadlineBinding: Binding<Bool> {
        Binding(
            get: { newTaskHasDeadline },
            set: {
                newTaskHasDeadline = $0
                newTaskDeadlineSource = $0 ? .userConfirmed : .unknown
            }
        )
    }

    private var confirmedDeadlineBinding: Binding<Date> {
        Binding(
            get: { newTaskDeadline },
            set: {
                newTaskDeadline = $0
                newTaskDeadlineSource = .userConfirmed
            }
        )
    }

    private var confirmedLocationBinding: Binding<String> {
        Binding(
            get: { newTaskLocation },
            set: {
                newTaskLocation = $0
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                newTaskDestinationSource = trimmed.isEmpty ? .unknown : .userConfirmed
                newTaskPlaceRequirement = trimmed.isEmpty ? .anywhere : .destination
                if isManualMode {
                    newTaskDestinationQuery = trimmed
                }
            }
        )
    }

    private var placeRequirementBinding: Binding<TaskPlaceRequirement> {
        Binding(
            get: { newTaskPlaceRequirement },
            set: { requirement in
                newTaskPlaceRequirement = requirement
                if requirement == .anywhere {
                    newTaskLocation = ""
                    newTaskDestinationQuery = ""
                    newTaskDestinationSource = .unknown
                    newTaskTravelMode = nil
                    newTaskRequiresBusinessHours = false
                }
            }
        )
    }

    private var currentReasoningFacts: TaskReasoningFacts {
        let savedPlace = preferences.place(matching: newTaskLocation)
        return TaskReasoningFacts(
            title: TaskFact(
                newTaskTitle,
                source: newTaskTitle.isEmpty
                    ? .unknown
                    : (isManualMode ? .userConfirmed : .modelInferred)
            ),
            workDurationMinutes: TaskFact(
                newTaskDurationMinutes,
                source: newTaskDurationSource
            ),
            earliestStart: TaskFact(
                Optional(newTaskStartDate),
                source: newTaskStartSource
            ),
            deadline: TaskFact(
                newTaskHasDeadline ? Optional(newTaskDeadline) : nil,
                source: newTaskHasDeadline ? newTaskDeadlineSource : .unknown
            ),
            priority: TaskFact(
                newTaskPriority,
                source: isManualMode ? .userConfirmed : .modelInferred
            ),
            canReflow: TaskFact(
                newTaskIsMovable,
                source: isManualMode ? .userConfirmed : .explicit
            ),
            placeRequirement: TaskFact(
                newTaskPlaceRequirement,
                source: isManualMode
                    ? .userConfirmed
                    : (newTaskPlaceRequirement == .destination
                        ? .modelInferred
                        : .defaultValue)
            ),
            destinationQuery: TaskFact(
                newTaskDestinationQuery,
                source: newTaskDestinationQuery.isEmpty
                    ? .unknown
                    : (isManualMode ? .userConfirmed : .modelInferred)
            ),
            destinationAddress: TaskFact(
                newTaskLocation,
                source: newTaskDestinationSource
            ),
            fixedStart: TaskFact(
                newTaskIsMovable
                    || [.defaultValue, .unknown].contains(newTaskStartSource)
                    ? nil
                    : Optional(newTaskStartDate),
                source: newTaskIsMovable ? .unknown : newTaskStartSource
            ),
            requiresBusinessHours: newTaskRequiresBusinessHours,
            hasSavedBusinessHours: !(savedPlace?.weeklyHours.isEmpty ?? true)
        )
    }

    private var manualIssues: [TaskClarificationIssue] {
        TaskCompletenessEngine.issues(for: currentReasoningFacts)
    }

    private func refreshClarificationIssues() {
        clarificationIssues = TaskCompletenessEngine.issues(
            for: currentReasoningFacts
        )
    }

    private var shouldAutomaticallyAnalyzeBeforeCreating: Bool {
        guard editingTask == nil,
              isManualMode,
              !hasAttemptedAnalysis,
              !newTaskDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              newTaskStartSource == .defaultValue,
              newTaskDurationSource == .defaultValue,
              newTaskCategory == .none,
              !newTaskHasDeadline,
              newTaskPriority == .medium,
              newTaskLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              newTaskIsMovable,
              case .available = taskInterpreter.availability else {
            return false
        }

        return true
    }

    private func saveTask(
        allowFixedConflict: Bool = false,
        saveAtRequestedTime: Bool = false
    ) {
        if shouldAutomaticallyAnalyzeBeforeCreating {
            interpretTaskDescription(automaticallyCreate: true)
            return
        }

        let trimmedDescription = newTaskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let enteredTitle = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = enteredTitle.isEmpty ? trimmedDescription : enteredTitle
        let effectiveDescription = trimmedDescription.isEmpty ? trimmedTitle : trimmedDescription

        guard !effectiveDescription.isEmpty else {
            statusText = "Name or describe the task first"
            return
        }

        refreshClarificationIssues()
        guard clarificationIssues.isEmpty else {
            isShowingClarification = true
            statusText = "Confirm the missing task details first"
            return
        }

        if editingTask == nil,
           newTaskIsMovable,
           newTaskStartDate < Date(),
           !hasConfirmedPastStart {
            taskSaveAlert = .overdue
            return
        }

        isCreatingTask = true
        statusText = editingTask == nil ? "Creating \(trimmedTitle)..." : "Saving \(trimmedTitle)..."

        Task {
            do {
                let savedTask: FloatCalTask

                if let editingTask {
                    savedTask = try await calendarService.updateTask(
                        id: editingTask.id,
                        title: trimmedTitle,
                        description: effectiveDescription,
                        startDate: newTaskStartDate,
                        durationMinutes: newTaskDurationMinutes,
                        category: newTaskCategory,
                        deadline: newTaskHasDeadline ? newTaskDeadline : nil,
                        priority: newTaskPriority,
                        preferredTimeOfDay: interpretedTimePreference,
                        location: newTaskLocation.trimmingCharacters(in: .whitespacesAndNewlines),
                        travelMode: newTaskTravelMode,
                        isMovable: newTaskIsMovable,
                        requiresBusinessHours: newTaskRequiresBusinessHours,
                        allowFixedConflict: allowFixedConflict,
                        saveAtRequestedTime: saveAtRequestedTime
                    )
                } else {
                    savedTask = try await calendarService.addTask(
                        title: trimmedTitle,
                        description: effectiveDescription,
                        startDate: newTaskStartDate,
                        durationMinutes: newTaskDurationMinutes,
                        category: newTaskCategory,
                        deadline: newTaskHasDeadline ? newTaskDeadline : nil,
                        priority: newTaskPriority,
                        preferredTimeOfDay: interpretedTimePreference,
                        location: newTaskLocation.trimmingCharacters(in: .whitespacesAndNewlines),
                        travelMode: newTaskTravelMode,
                        isMovable: newTaskIsMovable,
                        requiresBusinessHours: newTaskRequiresBusinessHours,
                        createAsOverdue: hasConfirmedPastStart,
                        allowFixedConflict: allowFixedConflict,
                        saveAtRequestedTime: saveAtRequestedTime
                    )
                }

                refreshTasks()
                upsertTask(savedTask)
                lastReflowSnapshot = []
                speechInput.stop()
                isShowingNewTaskSheet = false
                self.editingTask = nil
                hasConfirmedPastStart = false
                statusText = "Saved \(trimmedTitle)."
            } catch CalendarServiceError.fixedTimeConflict {
                taskSaveAlert = .fixedConflict
                statusText = "Confirm whether this fixed commitment should override the conflict."
            } catch let error as CalendarServiceError {
                switch error {
                case .noWritableCalendarSource, .taskNotFound:
                    statusText = "Could not save task: \(error.localizedDescription)"
                default:
                    taskSaveAlert = .placementFailure(
                        error.localizedDescription
                    )
                    statusText = "Choose whether to edit the task or save it for later reconciliation."
                }
            } catch {
                statusText = "Could not save task: \(error.localizedDescription)"
            }

            isCreatingTask = false
        }
    }

    private func loadInitialCalendarState() {
        hasCalendarAccess = calendarService.hasCalendarAccess
        calendarAccessIsDenied = calendarService.calendarAccessIsDenied

        guard hasCalendarAccess else {
            statusText = nil
            return
        }

        refreshTasks()
    }

    private func refreshTasks() {
        do {
            tasks = try calendarService.tasks()
            conflictingTaskIDs = calendarService.conflictingTaskIDs(for: tasks)
            reflowCandidateIDs = calendarService.reflowCandidateIDs(for: tasks)
            statusText = nil
            promptForImportedTaskDetailsIfNeeded()
        } catch {
            statusText = "Could not load tasks: \(error.localizedDescription)"
        }
    }

    private func promptForImportedTaskDetailsIfNeeded() {
        guard taskNeedingReview == nil,
              !isShowingNewTaskSheet,
              let task = tasks.first(where: {
                  $0.needsDetailsReview && !promptedReviewTaskIDs.contains($0.id)
              }) else {
            return
        }

        promptedReviewTaskIDs.insert(task.id)
        taskNeedingReview = task
    }

    private func upsertTask(_ task: FloatCalTask) {
        tasks.removeAll { $0.id == task.id }
        tasks.append(task)
        tasks.sort { $0.startDate < $1.startDate }
    }

    private func completeTask(_ task: FloatCalTask) {
        do {
            statusText = "Removing \(task.title)..."
            let deletedTask = try calendarService.completeTask(id: task.id)
            let completedRecord = CompletedTaskRecord(task: task, deletedTask: deletedTask)
            modelContext.insert(completedRecord)

            do {
                try modelContext.save()
            } catch {
                modelContext.delete(completedRecord)
                _ = try? calendarService.restoreTask(deletedTask)
                throw error
            }

            lastReflowSnapshot = []
            refreshTasks()
            statusText = "Completed \(task.title)"
        } catch {
            statusText = "Could not complete task: \(error.localizedDescription)"
        }
    }

    private func undoCompleteTask() {
        guard let completedTask = completedTasks.first else { return }

        do {
            let restoredTask = try calendarService.restoreTask(completedTask.deletedTask)
            modelContext.delete(completedTask)
            try modelContext.save()
            refreshTasks()
            upsertTask(restoredTask)
            statusText = "Restored \(restoredTask.title)."
        } catch {
            statusText = "Could not undo: \(error.localizedDescription)"
        }
    }

    private func moveTasks(from source: IndexSet, to destination: Int) {
        guard isAdjustingPriority else { return }
        priorityDraftTaskIDs.move(fromOffsets: source, toOffset: destination)
    }

    private func beginPriorityAdjustment() {
        guard taskSortMode == .priority, tasks.count > 1 else { return }

        priorityDraftTaskIDs = FloatCalTask.sorted(tasks, by: .priority).map(\.id)

        withAnimation {
            isAdjustingPriority = true
            taskEditMode = .active
        }
    }

    private func cancelPriorityAdjustment() {
        withAnimation {
            isAdjustingPriority = false
            taskEditMode = .inactive
        }

        priorityDraftTaskIDs = []
        statusText = "Priority changes canceled."
    }

    private func savePriorityAdjustment() {
        guard isAdjustingPriority else { return }

        do {
            try calendarService.setManualOrder(taskIDs: priorityDraftTaskIDs)
            refreshTasks()

            withAnimation {
                isAdjustingPriority = false
                taskEditMode = .inactive
            }

            priorityDraftTaskIDs = []
            statusText = "Saved relative priority."
        } catch {
            statusText = "Could not save priority: \(error.localizedDescription)"
        }
    }

    private func resetToPriorityOrder() {
        do {
            try calendarService.clearManualOrder(taskIDs: tasks.map(\.id))
            refreshTasks()
            statusText = "Reset to assigned priorities."
        } catch {
            statusText = "Could not reset task order: \(error.localizedDescription)"
        }
    }

    private func reflowTasks() {
        guard !isReflowing else { return }

        isReflowing = true
        statusText = "Finding room for tasks that need Reflow..."

        Task {
            await Task.yield()

            do {
                let result = try await calendarService.reflowTasks()
                refreshTasks()
                if !result.originalTasks.isEmpty {
                    lastReflowSnapshot = result.originalTasks
                }

                if result.updatedTasks.isEmpty {
                    if result.issues.isEmpty {
                        statusText = "Everything is clear — no tasks need Reflow."
                    } else {
                        statusText = "\(result.issues.count) task(s) still need your attention."
                    }
                } else if !result.issues.isEmpty {
                    statusText = "Reflowed \(result.updatedTasks.count) task(s); \(result.issues.count) still need your attention."
                } else if result.skippedConflicts {
                    statusText = "Reflowed \(result.updatedTasks.count) task(s) around your calendar."
                } else {
                    statusText = "Reflowed \(result.updatedTasks.count) task(s)."
                }

                queuedReflowIssues = result.issues
                presentNextReflowIssue()
            } catch {
                statusText = "Could not reflow tasks: \(error.localizedDescription)"
            }

            try? await Task.sleep(for: .milliseconds(450))
            isReflowing = false
        }
    }

    private func presentNextReflowIssue() {
        guard activeReflowIssue == nil,
              !isShowingNewTaskSheet,
              !queuedReflowIssues.isEmpty else {
            return
        }

        activeReflowIssue = queuedReflowIssues.removeFirst()
    }

    private func undoLastAction() {
        if !lastReflowSnapshot.isEmpty {
            do {
                _ = try calendarService.undoReflow(lastReflowSnapshot)
                lastReflowSnapshot = []
                refreshTasks()
                statusText = "Undid the last Reflow."
            } catch {
                statusText = "Could not undo Reflow: \(error.localizedDescription)"
            }
        } else {
            undoCompleteTask()
        }
    }

    private static func defaultTaskStartDate() -> Date {
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)

        guard let minute = components.minute,
              let baseDate = calendar.date(from: components) else {
            return now
        }

        let remainder = minute % 15
        let minutesToAdd = remainder == 0 ? 15 : 15 - remainder

        return calendar.date(byAdding: .minute, value: minutesToAdd, to: baseDate) ?? now
    }

}

private struct CompletedTasksView: View {
    private let calendarService = CalendarService.shared
    let onRecover: (FloatCalTask) -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CompletedTaskRecord.completedAt, order: .reverse)
    private var completedTasks: [CompletedTaskRecord]

    @State private var isConfirmingDeleteAll = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if completedTasks.isEmpty {
                ContentUnavailableView(
                    "No Completed Tasks",
                    systemImage: "checkmark.circle",
                    description: Text("Tasks you complete will be kept here.")
                )
            } else {
                ForEach(completedTasks) { task in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(task.title)
                                .font(.headline)

                            Spacer()

                            if task.reflowCount > 0 {
                                Label(
                                    "×\(task.reflowCount)",
                                    systemImage: "arrow.triangle.2.circlepath"
                                )
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.blue)
                                .labelStyle(.titleAndIcon)
                            }
                        }

                        Text("Completed \(task.completedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text("Originally \(task.startDate.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            recoverCompletedTask(task)
                        } label: {
                            Label("Recover", systemImage: "arrow.uturn.backward.circle.fill")
                        }
                        .tint(.green)
                    }
                }
                .onDelete(perform: deleteCompletedTasks)
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Completed")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Delete All", role: .destructive) {
                    isConfirmingDeleteAll = true
                }
                .disabled(completedTasks.isEmpty)
            }
        }
        .confirmationDialog(
            "Delete all completed-task history?",
            isPresented: $isConfirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                deleteAllCompletedTasks()
            }
        } message: {
            Text("This cannot be undone. Active Calendar events will not be affected.")
        }
    }

    private func deleteCompletedTasks(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(completedTasks[index])
        }

        saveChanges()
    }

    private func recoverCompletedTask(_ task: CompletedTaskRecord) {
        do {
            let restoredTask = try calendarService.restoreTask(task.deletedTask)
            modelContext.delete(task)

            do {
                try modelContext.save()
            } catch {
                _ = try? calendarService.completeTask(id: restoredTask.id)
                modelContext.rollback()
                throw error
            }

            errorMessage = nil
            onRecover(restoredTask)
        } catch {
            errorMessage = "Could not recover \(task.title): \(error.localizedDescription)"
        }
    }

    private func deleteAllCompletedTasks() {
        for task in completedTasks {
            modelContext.delete(task)
        }

        saveChanges()
    }

    private func saveChanges() {
        do {
            try modelContext.save()
            errorMessage = nil
        } catch {
            errorMessage = "Could not update completed history: \(error.localizedDescription)"
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: CompletedTaskRecord.self, inMemory: true)
        .environmentObject(PreferencesStore())
}

private struct TaskClarificationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var preferences: PreferencesStore
    @StateObject private var placeSearch = PlaceSearchService()
    @State private var manualLocation = ""
    @State private var didConfirmInferredTiming = false

    let issues: [TaskClarificationIssue]
    let locationQuery: String
    let origin: PlaceOrigin
    let originAddress: String
    let confirmationTitle: String
    @Binding var title: String
    @Binding var durationMinutes: Int
    @Binding var startDate: Date
    @Binding var hasDeadline: Bool
    @Binding var deadline: Date
    @Binding var location: String
    let onTimingConfirmed: () -> Void
    let onPlaceSelected: () -> Void
    let onConfirm: () -> Void

    private var savedPlace: PlacePreference? {
        preferences.place(matching: location)
    }

    private var canContinue: Bool {
        if has(.title), title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if has(.duration), durationMinutes <= 0 {
            return false
        }
        if has(.destination), location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if has(.businessHours), savedPlace?.weeklyHours.isEmpty != false {
            return false
        }
        if has(.dateConflict) {
            guard hasDeadline else { return false }
            let minimumEnd = startDate.addingTimeInterval(
                TimeInterval(durationMinutes * 60)
            )
            if deadline < minimumEnd {
                return false
            }
        }
        if has(.timing), !didConfirmInferredTiming {
            return false
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Just a few details")
                        .font(.headline)
                    Text("FloatCal asks only about information that is missing or could change where the task belongs.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if has(.title) {
                    Section("What should I call this task?") {
                        TextField("Short task name", text: $title)
                    }
                }

                if has(.duration) {
                    Section {
                        Stepper(
                            "Duration: \(durationMinutes) min",
                            value: $durationMinutes,
                            in: 5...480,
                            step: 5
                        )
                    } header: {
                        Text("How long will the task itself take?")
                    } footer: {
                        Text("Travel is calculated separately for each possible calendar slot.")
                    }
                }

                if has(.fixedStart) {
                    Section("When is this fixed task?") {
                        DatePicker(
                            "Starts",
                            selection: $startDate,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                }

                if has(.dateConflict) {
                    Section("Check the timing") {
                        DatePicker(
                            "Earliest Start",
                            selection: $startDate,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        Toggle("Deadline", isOn: $hasDeadline)
                        if hasDeadline {
                            DatePicker(
                                "Due",
                                selection: $deadline,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                        }
                    }
                }

                if has(.timing) {
                    Section {
                        DatePicker(
                            "Earliest Start",
                            selection: $startDate,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        Toggle("Deadline", isOn: $hasDeadline)
                        if hasDeadline {
                            DatePicker(
                                "Due",
                                selection: $deadline,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                        }
                        Button("Use This Timing") {
                            onTimingConfirmed()
                            didConfirmInferredTiming = true
                        }
                    } header: {
                        Text("Confirm the timing")
                    } footer: {
                        Text("Explicit dates and times are protected automatically. This confirmation is only for timing inferred from context.")
                    }
                }

                if has(.destination) {
                    Section {
                        if placeSearch.isSearching {
                            HStack {
                                ProgressView()
                                Text("Finding nearby \(locationQuery)…")
                            }
                        }

                        ForEach(placeSearch.results) { candidate in
                            Button {
                                location = candidate.address.isEmpty
                                    ? candidate.name
                                    : "\(candidate.name), \(candidate.address)"
                                preferences.rememberPlace(
                                    query: locationQuery,
                                    name: candidate.name,
                                    address: location,
                                    origin: origin,
                                    placeID: candidate.id,
                                    latitude: candidate.latitude,
                                    longitude: candidate.longitude
                                )
                                onPlaceSelected()
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(candidate.name)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        if location.contains(candidate.address), !candidate.address.isEmpty {
                                            Image(systemName: "checkmark.circle.fill")
                                        }
                                    }
                                    if !candidate.address.isEmpty {
                                        Text(candidate.address)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }

                        if let message = placeSearch.message {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        TextField("Search or enter another location", text: $manualLocation)
                        Button("Use This Location") {
                            let trimmed = manualLocation.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            location = trimmed
                            preferences.rememberPlace(
                                query: locationQuery,
                                name: locationQuery,
                                address: trimmed,
                                origin: origin
                            )
                            onPlaceSelected()
                        }
                        .disabled(manualLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } header: {
                        Text(locationQuery.isEmpty ? "Where does this happen?" : "Which \(locationQuery)?")
                    } footer: {
                        Text("Your choice becomes the usual \(locationQuery) from \(origin.rawValue). Change it anytime in Settings.")
                    }
                }

                if has(.businessHours) {
                    Section {
                        if let savedPlace {
                            NavigationLink {
                                PlaceHoursEditorView(place: savedPlace)
                                    .environmentObject(preferences)
                            } label: {
                                Label(
                                    savedPlace.weeklyHours.isEmpty
                                        ? "Set Weekly Hours"
                                        : "Review Weekly Hours",
                                    systemImage: "clock.badge.checkmark"
                                )
                            }

                            if !savedPlace.weeklyHours.isEmpty {
                                Label("Weekly hours saved", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        } else {
                            Button {
                                let trimmed = location.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                )
                                guard !trimmed.isEmpty else { return }
                                preferences.rememberPlace(
                                    query: locationQuery.isEmpty ? trimmed : locationQuery,
                                    name: locationQuery.isEmpty ? trimmed : locationQuery,
                                    address: trimmed,
                                    origin: origin
                                )
                                onPlaceSelected()
                            } label: {
                                Label("Save This Place", systemImage: "mappin.and.ellipse")
                            }
                            .disabled(
                                location.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                ).isEmpty
                            )
                        }
                    } header: {
                        Text("What hours is this place open?")
                    } footer: {
                        Text("Save these once. FloatCal will reuse them and you can review them later in Settings.")
                    }
                }
            }
            .navigationTitle("Confirm Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmationTitle) {
                        dismiss()
                        Task { @MainActor in
                            await Task.yield()
                            onConfirm()
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!canContinue)
                }
            }
            .task(id: locationQuery) {
                guard has(.destination), !locationQuery.isEmpty else { return }
                await placeSearch.search(locationQuery, near: originAddress)
            }
            .onChange(of: startDate) { _, _ in
                guard has(.timing) else { return }
                onTimingConfirmed()
                didConfirmInferredTiming = true
            }
            .onChange(of: deadline) { _, _ in
                guard has(.timing) else { return }
                onTimingConfirmed()
                didConfirmInferredTiming = true
            }
            .onChange(of: hasDeadline) { _, _ in
                guard has(.timing) else { return }
                onTimingConfirmed()
                didConfirmInferredTiming = true
            }
        }
    }

    private func has(_ kind: TaskClarificationKind) -> Bool {
        issues.contains { $0.kind == kind }
    }
}

private struct PButton: View {
    let isProcessing: Bool
    let taskCount: Int
    let action: () -> Void

    private let buttonColor = Color(uiColor: .systemBlue)

    @State private var isHolding = false
    @State private var didConfirm = false
    @State private var orbitStartedAt = Date()
    @State private var orbitBaseAngle = 0.0
    @State private var heldAngle = 0.0
    @State private var holdStartedAt: Date?

    private let holdDuration = 1.4
    private let orbitDuration = 18.0

    var body: some View {
        VStack(spacing: 8) {
            TimelineView(.animation) { timeline in
                let progress = holdProgress(at: timeline.date)
                let dotAngle = isHolding
                    ? heldAngle + (progress * 360)
                    : orbitAngle(at: timeline.date)

                ZStack {
                    if isHolding {
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(
                                buttonColor,
                                style: StrokeStyle(lineWidth: 5, lineCap: .round)
                            )
                            .frame(width: 80, height: 80)
                            .rotationEffect(.degrees(heldAngle - 90))
                    }

                    Circle()
                        .fill(buttonColor)
                        .frame(width: 68, height: 68)
                        .shadow(color: buttonColor.opacity(0.3), radius: 12, y: 5)

                    Circle()
                        .fill(buttonColor)
                        .frame(width: 10, height: 10)
                        .offset(y: -40)
                        .rotationEffect(.degrees(dotAngle))
                        .opacity(isProcessing ? 0.35 : 0.9)

                    if didConfirm || isProcessing {
                        ReflowCheckmark()
                            .stroke(
                                .white,
                                style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                            )
                            .frame(width: 30, height: 24)
                    }
                }
                .frame(width: 86, height: 86)
                .animation(.easeOut(duration: 0.18), value: didConfirm)
            }
            .contentShape(Circle())
            .onLongPressGesture(
                minimumDuration: holdDuration,
                maximumDistance: 70,
                pressing: handlePressing,
                perform: confirm
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Reflow overdue tasks")
            .accessibilityValue("\(taskCount) tasks need Reflow")
            .accessibilityHint("Press and hold to confirm. Release early to cancel.")
            .accessibilityAddTraits(.isButton)
            .allowsHitTesting(!isProcessing && taskCount > 0)
            .onChange(of: isProcessing) { wasProcessing, isNowProcessing in
                guard wasProcessing, !isNowProcessing else { return }

                Task {
                    try? await Task.sleep(for: .milliseconds(500))

                    await MainActor.run {
                        withAnimation(.easeOut(duration: 0.2)) {
                            didConfirm = false
                        }
                    }
                }
            }

            Text(
                isProcessing
                    ? "Reflowing..."
                    : (taskCount == 0 ? "All caught up" : "Hold to reflow")
            )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func handlePressing(_ isPressing: Bool) {
        guard !isProcessing, taskCount > 0 else { return }

        if isPressing {
            let now = Date()
            didConfirm = false
            heldAngle = orbitAngle(at: now)
            holdStartedAt = now
            isHolding = true
        } else if !didConfirm {
            let now = Date()
            orbitBaseAngle = normalizedAngle(
                heldAngle + (holdProgress(at: now) * 360)
            )
            orbitStartedAt = now
            isHolding = false
            holdStartedAt = nil
        }
    }

    private func confirm() {
        guard !isProcessing, taskCount > 0 else { return }

        let now = Date()
        orbitBaseAngle = normalizedAngle(heldAngle)
        orbitStartedAt = now
        holdStartedAt = nil
        isHolding = false
        didConfirm = true
        action()
    }

    private func orbitAngle(at date: Date) -> Double {
        normalizedAngle(
            orbitBaseAngle
                + date.timeIntervalSince(orbitStartedAt)
                    .truncatingRemainder(dividingBy: orbitDuration) / orbitDuration * 360
        )
    }

    private func holdProgress(at date: Date) -> Double {
        guard isHolding, let holdStartedAt else { return 0 }
        return min(max(date.timeIntervalSince(holdStartedAt) / holdDuration, 0), 1)
    }

    private func normalizedAngle(_ angle: Double) -> Double {
        let remainder = angle.truncatingRemainder(dividingBy: 360)
        return remainder >= 0 ? remainder : remainder + 360
    }
}

private struct ReflowCheckmark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
