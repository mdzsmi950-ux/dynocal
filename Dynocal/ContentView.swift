//
//  ContentView.swift
//  Dynocal
//
//  Created by Maddie Smith on 5/22/26.
//

import SwiftUI
import UIKit

struct ContentView: View {
    private let calendarService = CalendarService.shared

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var statusText: String?
    @State private var hasCalendarAccess = CalendarService.shared.hasCalendarAccess
    @State private var calendarAccessIsDenied = CalendarService.shared.calendarAccessIsDenied
    @State private var isCreatingTask = false
    @State private var isRescheduling = false
    @State private var isShowingNewTaskSheet = false
    @State private var editingTask: DynocalTask?
    @State private var tasks: [DynocalTask] = []
    @State private var lastDeletedTask: DeletedTask?
    @State private var newTaskTitle = ""
    @State private var newTaskStartDate = Self.defaultTaskStartDate()
    @State private var newTaskDurationMinutes = 30
    @State private var newTaskCategory = TaskCategory.none
    @State private var newTaskTravelTimeMinutes = 0
    @State private var newTaskHasDeadline = false
    @State private var newTaskDeadline = Self.defaultTaskStartDate()
    @State private var newTaskPriority = TaskPriority.none
    @State private var newTaskLocation = ""

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Form {
                    if !hasCalendarAccess {
                        calendarAccessSection
                    } else {
                        tasksSection
                    }

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
                    .disabled(lastDeletedTask == nil)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        beginNewTask()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!hasCalendarAccess)
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
        }
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
        Section("Tasks") {
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
                ForEach(tasks) { task in
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
            }
        }
    }

    private var newTaskSheet: some View {
        NavigationStack {
            Form {
                Section("Schedule") {
                    DatePicker(
                        "When",
                        selection: $newTaskStartDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )

                    Picker("Duration", selection: $newTaskDurationMinutes) {
                        Text("15m").tag(15)
                        Text("30 min").tag(30)
                        Text("45m").tag(45)
                        Text("1 hr").tag(60)
                        Text("90m").tag(90)
                    }
                    .pickerStyle(.menu)
                }

                Section("What do you need to do?") {
                    ZStack(alignment: .topLeading) {
                        if newTaskTitle.isEmpty {
                            Text("Describe the task...")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }

                        TextEditor(text: $newTaskTitle)
                            .frame(minHeight: 120)
                            .scrollContentBackground(.hidden)
                    }
                }

                Section {
                    Picker("Category", selection: $newTaskCategory) {
                        ForEach(TaskCategory.allCases) { category in
                            Text(category.rawValue).tag(category)
                        }
                    }

                    Picker("Travel Time", selection: $newTaskTravelTimeMinutes) {
                        Text("None").tag(0)
                        Text("15 min").tag(15)
                        Text("30 min").tag(30)
                        Text("45 min").tag(45)
                        Text("1 hr").tag(60)
                    }

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
                } header: {
                    Text("Optional")
                } footer: {
                    Text("These details are saved with the task. Smarter scheduling rules can use them later.")
                }
            }
            .navigationTitle(editingTask == nil ? "New Task" : "Edit Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
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

                Text("\(task.durationMinutes)m")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Label {
                Text("\(task.startDate.formatted(date: .abbreviated, time: .shortened)) - \(task.endDate.formatted(date: .omitted, time: .shortened))")
            } icon: {
                Image(systemName: "clock")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            HStack {
                Button {
                    snoozeTask(task, by: 30)
                } label: {
                    Label("30 min", systemImage: "goforward.30")
                }

                Button {
                    snoozeTask(task, by: 60)
                } label: {
                    Label("1 hr", systemImage: "goforward.60")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 6)
    }

    private var canCreateTask: Bool {
        !newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasCalendarAccess
            && !isCreatingTask
    }

    private var overdueTaskCount: Int {
        tasks.filter { $0.startDate < Date() }.count
    }

    private func beginNewTask() {
        editingTask = nil
        newTaskTitle = ""
        newTaskStartDate = Self.defaultTaskStartDate()
        newTaskDurationMinutes = 30
        newTaskCategory = .none
        newTaskTravelTimeMinutes = 0
        newTaskHasDeadline = false
        newTaskDeadline = newTaskStartDate
        newTaskPriority = .none
        newTaskLocation = ""
        isShowingNewTaskSheet = true
    }

    private func beginEditing(_ task: DynocalTask) {
        editingTask = task
        newTaskTitle = task.title
        newTaskStartDate = task.startDate
        newTaskDurationMinutes = task.durationMinutes
        newTaskCategory = task.category
        newTaskTravelTimeMinutes = task.travelTimeMinutes
        newTaskHasDeadline = task.deadline != nil
        newTaskDeadline = task.deadline ?? task.startDate
        newTaskPriority = task.priority
        newTaskLocation = task.location
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

    private func saveTask() {
        let trimmedTitle = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty else {
            statusText = "Add a task name first"
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
            lastDeletedTask = try calendarService.completeTask(id: task.id)
            refreshTasks()
            statusText = "Completed \(task.title)"
        } catch {
            statusText = "Could not complete task: \(error.localizedDescription)"
        }
    }

    private func undoCompleteTask() {
        guard let lastDeletedTask else { return }

        do {
            let restoredTask = try calendarService.restoreTask(lastDeletedTask)
            refreshTasks()
            upsertTask(restoredTask)
            self.lastDeletedTask = nil
            statusText = "Restored \(restoredTask.title)."
        } catch {
            statusText = "Could not undo: \(error.localizedDescription)"
        }
    }

    private func snoozeTask(_ task: DynocalTask, by minutes: Int) {
        do {
            statusText = "Moving \(task.title)..."
            let result = try calendarService.snoozeTask(id: task.id, by: minutes)
            replaceTaskInPlace(result.updatedTask)
            let newTime = result.newStartDate.formatted(date: .omitted, time: .shortened)

            if result.skippedConflict {
                statusText = "There wasn’t a good time immediately, so I moved \(task.title) to \(newTime)."
            } else {
                statusText = "Moved \(task.title) to \(newTime)."
            }
        } catch {
            statusText = "Could not move task: \(error.localizedDescription)"
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

    private func replaceTaskInPlace(_ task: DynocalTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else {
            upsertTask(task)
            return
        }

        tasks[index] = task
    }
}

#Preview {
    ContentView()
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
