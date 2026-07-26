//
//  ContentView.swift
//  Dynocal
//
//  Created by Maddie Smith on 5/22/26.
//

import SwiftUI
import SwiftData
import UIKit

struct ContentView: View {
    private let calendarService = CalendarService.shared
    private let taskInterpreter = TaskInterpreter.shared

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CompletedTaskRecord.completedAt, order: .reverse)
    private var completedTasks: [CompletedTaskRecord]

    @State private var statusText: String?
    @State private var hasCalendarAccess = CalendarService.shared.hasCalendarAccess
    @State private var calendarAccessIsDenied = CalendarService.shared.calendarAccessIsDenied
    @State private var isCreatingTask = false
    @State private var isRescheduling = false
    @State private var isShowingNewTaskSheet = false
    @State private var editingTask: DynocalTask?
    @State private var tasks: [DynocalTask] = []
    @State private var newTaskTitle = ""
    @State private var newTaskDescription = ""
    @State private var newTaskStartDate = Self.defaultTaskStartDate()
    @State private var newTaskDurationMinutes = 30
    @State private var newTaskCategory = TaskCategory.none
    @State private var newTaskTravelTimeMinutes = 0
    @State private var newTaskHasDeadline = false
    @State private var newTaskDeadline = Self.defaultTaskStartDate()
    @State private var newTaskPriority = TaskPriority.none
    @State private var newTaskLocation = ""
    @State private var isInterpretingTask = false
    @State private var taskInterpretationMessage: String?
    @State private var interpretedTimePreference = ""
    @State private var interpretedAsFixed = false
    @State private var isShowingTaskDetails = false
    @State private var dictationPrefix = ""
    @StateObject private var speechInput = SpeechInputService()
    @AppStorage("taskSortMode") private var taskSortModeRawValue = TaskSortMode.priority.rawValue
    @State private var isAdjustingPriority = false
    @State private var priorityDraftTaskIDs: [String] = []
    @State private var taskEditMode: EditMode = .inactive

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
                        isProcessing: isRescheduling,
                        overdueTaskCount: overdueTaskCount
                    ) {
                        rescheduleOverdueTasks()
                    }
                    .padding(.bottom, 16)
                }
            }
            .navigationTitle("Dynocal")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        undoCompleteTask()
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(completedTasks.isEmpty || !hasCalendarAccess || isAdjustingPriority)
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
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
            .sheet(isPresented: $isShowingNewTaskSheet) {
                newTaskSheet
            }
            .onDisappear {
                speechInput.stop()
            }
        }
    }

    private var taskSortMode: TaskSortMode {
        TaskSortMode(rawValue: taskSortModeRawValue) ?? .priority
    }

    private var displayedTasks: [DynocalTask] {
        guard isAdjustingPriority else {
            return DynocalTask.sorted(tasks, by: taskSortMode)
        }

        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let draftedTasks = priorityDraftTaskIDs.compactMap { tasksByID[$0] }
        let draftedIDs = Set(priorityDraftTaskIDs)
        let missingTasks = DynocalTask.sorted(
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

                Text("Dynocal needs Calendar access to place tasks on your calendar and move them when plans change.")
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
                VStack(alignment: .leading, spacing: 10) {
                    Text("No Tasks")
                        .font(.headline)

                    Text("Create a task to put it on your calendar.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        beginNewTask()
                    } label: {
                        Label("New Task", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
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
                CompletedTasksView()
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
                            Text("Describe the task, timing, and anything Dynocal should know...")
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
                            Label(
                                speechInput.isRecording ? "Stop" : "Speak",
                                systemImage: speechInput.isRecording ? "stop.fill" : "mic.fill"
                            )
                        }
                        .tint(speechInput.isRecording ? .red : .accentColor)

                        Spacer()

                        Button {
                            interpretTaskDescription()
                        } label: {
                            Label(
                                isInterpretingTask ? "Understanding..." : "Fill Details",
                                systemImage: "apple.intelligence"
                            )
                        }
                        .disabled(
                            newTaskDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || isInterpretingTask
                                || speechInput.isRecording
                        )
                    }

                    if let message = speechInput.message ?? taskInterpretationMessage {
                        Label(
                            message,
                            systemImage: message.hasPrefix("Filled") ? "checkmark.circle.fill" : "info.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(message.hasPrefix("Filled") ? .green : .secondary)
                    }
                }

                Section {
                    DisclosureGroup("Review details", isExpanded: $isShowingTaskDetails) {
                        TextField("Task Name", text: $newTaskTitle)

                        DatePicker(
                            "When",
                            selection: $newTaskStartDate,
                            displayedComponents: [.date, .hourAndMinute]
                        )

                        Stepper(
                            "Duration: \(newTaskDurationMinutes) min",
                            value: $newTaskDurationMinutes,
                            in: 5...480,
                            step: 5
                        )

                        Picker("Category", selection: $newTaskCategory) {
                            ForEach(TaskCategory.allCases) { category in
                                Text(category.rawValue).tag(category)
                            }
                        }

                        Stepper(
                            newTaskTravelTimeMinutes == 0
                                ? "Travel Time: None"
                                : "Travel Time: \(newTaskTravelTimeMinutes) min",
                            value: $newTaskTravelTimeMinutes,
                            in: 0...240,
                            step: 5
                        )

                        TextField("Location", text: $newTaskLocation)

                        Toggle("Deadline", isOn: $newTaskHasDeadline)

                        if newTaskHasDeadline {
                            DatePicker(
                                "Due",
                                selection: $newTaskDeadline,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                        }

                        Picker("Priority", selection: $newTaskPriority) {
                            ForEach(TaskPriority.allCases) { priority in
                                Text(priority.rawValue).tag(priority)
                            }
                        }

                        if !interpretedTimePreference.isEmpty {
                            LabeledContent("Preferred Time", value: interpretedTimePreference)
                        }

                        if interpretedAsFixed {
                            LabeledContent("Scheduling", value: "Fixed time")
                        }
                    }
                } header: {
                    Text("Optional")
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
                    Button(isCreatingTask ? "Saving..." : (editingTask == nil ? "Create" : "Save")) {
                        saveTask()
                    }
                    .disabled(!canCreateTask)
                }
            }
        }
    }

    private func taskRow(_ task: DynocalTask) -> some View {
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
    private func taskStatusView(_ task: DynocalTask) -> some View {
        HStack(spacing: 6) {
            if task.startDate < Date() {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Overdue")
            } else {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Planned")
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
        !newTaskDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasCalendarAccess
            && !isCreatingTask
            && !isInterpretingTask
            && !speechInput.isRecording
    }

    private var overdueTaskCount: Int {
        tasks.filter { $0.startDate < Date() }.count
    }

    private func beginNewTask() {
        editingTask = nil
        newTaskTitle = ""
        newTaskDescription = ""
        newTaskStartDate = Self.defaultTaskStartDate()
        newTaskDurationMinutes = 30
        newTaskCategory = .none
        newTaskTravelTimeMinutes = 0
        newTaskHasDeadline = false
        newTaskDeadline = newTaskStartDate
        newTaskPriority = .none
        newTaskLocation = ""
        taskInterpretationMessage = nil
        interpretedTimePreference = ""
        interpretedAsFixed = false
        isShowingTaskDetails = false
        dictationPrefix = ""
        isShowingNewTaskSheet = true
    }

    private func beginEditing(_ task: DynocalTask) {
        editingTask = task
        newTaskTitle = task.title
        newTaskDescription = task.taskDescription
        newTaskStartDate = task.startDate
        newTaskDurationMinutes = task.durationMinutes
        newTaskCategory = task.category
        newTaskTravelTimeMinutes = task.travelTimeMinutes
        newTaskHasDeadline = task.deadline != nil
        newTaskDeadline = task.deadline ?? task.startDate
        newTaskPriority = task.priority
        newTaskLocation = task.location
        taskInterpretationMessage = nil
        interpretedTimePreference = ""
        interpretedAsFixed = false
        isShowingTaskDetails = true
        dictationPrefix = ""
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

        speechInput.toggle { transcription in
            newTaskDescription = dictationPrefix + transcription
            taskInterpretationMessage = nil
        }
    }

    private func interpretTaskDescription() {
        let description = newTaskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty, !isInterpretingTask else { return }

        switch taskInterpreter.availability {
        case .available:
            break
        case .unavailable(let reason):
            taskInterpretationMessage = reason
            isShowingTaskDetails = true
            return
        }

        isInterpretingTask = true
        taskInterpretationMessage = nil

        Task {
            do {
                let draft = try await taskInterpreter.interpret(description)

                newTaskTitle = draft.title
                newTaskDurationMinutes = draft.durationMinutes
                newTaskCategory = draft.category
                newTaskTravelTimeMinutes = draft.travelTimeMinutes
                newTaskPriority = draft.priority
                newTaskLocation = draft.location
                interpretedTimePreference = draft.preferredTimeOfDay
                interpretedAsFixed = draft.isFixed

                if let startDate = draft.startDate {
                    newTaskStartDate = startDate
                }

                if let deadline = draft.deadline {
                    newTaskHasDeadline = true
                    newTaskDeadline = deadline
                } else {
                    newTaskHasDeadline = false
                }

                isShowingTaskDetails = true

                if draft.needsBusinessHoursLookup {
                    taskInterpretationMessage = "Filled what I could. Confirm the deadline because current business hours aren’t available."
                } else {
                    taskInterpretationMessage = "Filled details with Apple Intelligence. Review before creating."
                }
            } catch {
                taskInterpretationMessage = "Apple Intelligence couldn’t fill the details: \(error.localizedDescription)"
                isShowingTaskDetails = true
            }

            isInterpretingTask = false
        }
    }

    private func saveTask() {
        let trimmedDescription = newTaskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let enteredTitle = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = enteredTitle.isEmpty ? trimmedDescription : enteredTitle

        guard !trimmedDescription.isEmpty else {
            statusText = "Describe the task first"
            return
        }

        isCreatingTask = true
        statusText = editingTask == nil ? "Creating \(trimmedTitle)..." : "Saving \(trimmedTitle)..."

        do {
            let savedTask: DynocalTask

            if let editingTask {
                savedTask = try calendarService.updateTask(
                    id: editingTask.id,
                    title: trimmedTitle,
                    description: trimmedDescription,
                    startDate: newTaskStartDate,
                    durationMinutes: newTaskDurationMinutes,
                    category: newTaskCategory,
                    travelTimeMinutes: newTaskTravelTimeMinutes,
                    deadline: newTaskHasDeadline ? newTaskDeadline : nil,
                    priority: newTaskPriority,
                    location: newTaskLocation.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            } else {
                savedTask = try calendarService.addTask(
                    title: trimmedTitle,
                    description: trimmedDescription,
                    startDate: newTaskStartDate,
                    durationMinutes: newTaskDurationMinutes,
                    category: newTaskCategory,
                    travelTimeMinutes: newTaskTravelTimeMinutes,
                    deadline: newTaskHasDeadline ? newTaskDeadline : nil,
                    priority: newTaskPriority,
                    location: newTaskLocation.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }

            refreshTasks()
            upsertTask(savedTask)
            speechInput.stop()
            isShowingNewTaskSheet = false
            self.editingTask = nil
            statusText = "Saved \(trimmedTitle)."
        } catch {
            statusText = "Could not save task: \(error.localizedDescription)"
        }

        isCreatingTask = false
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
            statusText = tasks.isEmpty ? nil : "Loaded \(tasks.count) task(s)"
        } catch {
            statusText = "Could not load tasks: \(error.localizedDescription)"
        }
    }

    private func upsertTask(_ task: DynocalTask) {
        tasks.removeAll { $0.id == task.id }
        tasks.append(task)
        tasks.sort { $0.startDate < $1.startDate }
    }

    private func completeTask(_ task: DynocalTask) {
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

        priorityDraftTaskIDs = DynocalTask.sorted(tasks, by: .priority).map(\.id)

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

    private func rescheduleOverdueTasks() {
        guard !isRescheduling else { return }

        isRescheduling = true
        statusText = "Finding room for overdue tasks..."

        Task {
            await Task.yield()

            do {
                let result = try calendarService.rescheduleOverdueTasks()
                refreshTasks()

                if result.updatedTasks.isEmpty {
                    statusText = "You’re caught up — there are no overdue tasks."
                } else if result.skippedConflicts {
                    statusText = "Reflowed \(result.updatedTasks.count) overdue task(s) around your calendar."
                } else {
                    statusText = "Reflowed \(result.updatedTasks.count) overdue task(s)."
                }
            } catch {
                statusText = "Could not reflow tasks: \(error.localizedDescription)"
            }

            try? await Task.sleep(for: .milliseconds(450))
            isRescheduling = false
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
}

private struct PButton: View {
    let isProcessing: Bool
    let overdueTaskCount: Int
    let action: () -> Void

    private let buttonColor = Color(uiColor: .systemBlue)

    @State private var holdProgress = 0.0
    @State private var isHolding = false
    @State private var didConfirm = false
    @State private var orbitStartedAt = Date()

    private let holdDuration = 1.4
    private let orbitDuration = 18.0

    var body: some View {
        VStack(spacing: 8) {
            TimelineView(.animation) { timeline in
                let dotAngle = orbitAngle(at: timeline.date)

                ZStack {
                    Circle()
                        .fill(buttonColor)
                        .frame(width: 9, height: 9)
                        .offset(y: -40)
                        .rotationEffect(.degrees(dotAngle))
                        .opacity(isProcessing ? 0.35 : 0.9)

                    Circle()
                        .fill(buttonColor)
                        .frame(width: 68, height: 68)
                        .shadow(color: buttonColor.opacity(0.3), radius: 12, y: 5)

                    if isHolding || didConfirm || isProcessing {
                        ReflowCheckmark()
                            .trim(from: 0, to: didConfirm || isProcessing ? 1 : holdProgress)
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
            .accessibilityLabel("Reschedule overdue tasks")
            .accessibilityValue("\(overdueTaskCount) overdue")
            .accessibilityHint("Press and hold to confirm. Release early to cancel.")
            .accessibilityAddTraits(.isButton)
            .allowsHitTesting(!isProcessing && overdueTaskCount > 0)
            .onChange(of: isProcessing) { wasProcessing, isNowProcessing in
                guard wasProcessing, !isNowProcessing else { return }

                Task {
                    try? await Task.sleep(for: .milliseconds(500))

                    await MainActor.run {
                        withAnimation(.easeOut(duration: 0.2)) {
                            didConfirm = false
                            holdProgress = 0
                        }
                    }
                }
            }

            Text(
                isProcessing
                    ? "Reflowing..."
                    : (overdueTaskCount == 0 ? "All caught up" : "Hold to reflow")
            )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func handlePressing(_ isPressing: Bool) {
        guard !isProcessing, overdueTaskCount > 0 else { return }

        if isPressing {
            didConfirm = false
            holdProgress = 0
            isHolding = true

            withAnimation(.linear(duration: holdDuration)) {
                holdProgress = 1
            }
        } else if !didConfirm {
            withAnimation(.easeOut(duration: 0.2)) {
                holdProgress = 0
            }
            isHolding = false
        }
    }

    private func confirm() {
        guard !isProcessing, overdueTaskCount > 0 else { return }

        didConfirm = true
        holdProgress = 1
        isHolding = false
        action()
    }

    private func orbitAngle(at date: Date) -> Double {
        date.timeIntervalSince(orbitStartedAt)
            .truncatingRemainder(dividingBy: orbitDuration) / orbitDuration * 360
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
