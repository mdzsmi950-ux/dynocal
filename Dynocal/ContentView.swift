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
                    PButton(isProcessing: isRescheduling) {
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
                Section {
                    TextField("What do you need to do?", text: $newTaskTitle)

                    DatePicker(
                        "When",
                        selection: $newTaskStartDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )

                    Picker("Duration", selection: $newTaskDurationMinutes) {
                        Text("30 min").tag(30)
                        Text("1 hr").tag(60)
                    }
                    .pickerStyle(.segmented)
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

    private func beginNewTask() {
        editingTask = nil
        newTaskTitle = ""
        newTaskStartDate = Self.defaultTaskStartDate()
        newTaskDurationMinutes = 30
        isShowingNewTaskSheet = true
    }

    private func beginEditing(_ task: DynocalTask) {
        editingTask = task
        newTaskTitle = task.title
        newTaskStartDate = task.startDate
        newTaskDurationMinutes = task.durationMinutes
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
                    durationMinutes: newTaskDurationMinutes
                )
            } else {
                savedTask = try calendarService.addTask(
                    title: trimmedTitle,
                    startDate: newTaskStartDate,
                    durationMinutes: newTaskDurationMinutes
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

        isRescheduling = false
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
    let action: () -> Void

    private let buttonColor = Color(uiColor: .systemBlue)

    @State private var holdProgress = 0.0
    @State private var isHolding = false
    @State private var holdStartAngle = 0.0
    @State private var didConfirm = false
    @State private var orbitStartedAt = Date()

    private let holdDuration = 1.4
    private let orbitDuration = 18.0

    var body: some View {
        VStack(spacing: 8) {
            TimelineView(.animation) { timeline in
                let idleAngle = orbitAngle(at: timeline.date)
                let dotAngle = isHolding
                    ? holdStartAngle + (holdProgress * 360)
                    : idleAngle

                ZStack {
                    Circle()
                        .trim(from: 0, to: holdProgress)
                        .stroke(
                            buttonColor,
                            style: StrokeStyle(lineWidth: 7, lineCap: .round)
                        )
                        .frame(width: 92, height: 92)
                        .rotationEffect(.degrees(holdStartAngle - 90))
                        .opacity(isHolding || isProcessing ? 1 : 0)

                    Circle()
                        .fill(buttonColor)
                        .frame(width: 10, height: 10)
                        .offset(y: -46)
                        .rotationEffect(.degrees(dotAngle))
                        .opacity(isProcessing ? 0.35 : 0.9)

                    Circle()
                        .fill(buttonColor)
                        .frame(width: 78, height: 78)
                        .shadow(color: buttonColor.opacity(0.3), radius: 12, y: 5)

                    if isProcessing {
                        ProgressView()
                            .tint(.white)
                            .controlSize(.large)
                    } else if didConfirm {
                        Image(systemName: "checkmark")
                            .symbolRenderingMode(.monochrome)
                            .transition(.scale(scale: 0.82).combined(with: .opacity))
                    } else {
                        Text("P")
                            .transition(.scale(scale: 0.82).combined(with: .opacity))
                    }
                }
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
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
            .accessibilityHint("Press and hold to confirm. Release early to cancel.")
            .accessibilityAddTraits(.isButton)
            .allowsHitTesting(!isProcessing)

            Text(isProcessing ? "Reflowing..." : "Hold to reflow")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func handlePressing(_ isPressing: Bool) {
        guard !isProcessing else { return }

        if isPressing {
            didConfirm = false
            holdProgress = 0
            holdStartAngle = orbitAngle(at: Date())
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
        guard !isProcessing else { return }

        didConfirm = true
        holdProgress = 1
        action()

        Task {
            try? await Task.sleep(for: .milliseconds(650))

            await MainActor.run {
                withAnimation(.easeOut(duration: 0.25)) {
                    didConfirm = false
                    holdProgress = 0
                }
                isHolding = false
            }
        }
    }

    private func orbitAngle(at date: Date) -> Double {
        date.timeIntervalSince(orbitStartedAt)
            .truncatingRemainder(dividingBy: orbitDuration) / orbitDuration * 360
    }
}
