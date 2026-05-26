//
//  ContentView.swift
//  Dynocal
//
//  Created by Maddie Smith on 5/22/26.
//

import SwiftUI

struct ContentView: View {
    private let calendarService = CalendarService.shared

    @State private var statusText: String?
    @State private var isCreatingTask = false
    @State private var isShowingNewTaskSheet = false
    @State private var tasks: [DynocalTask] = []
    @State private var lastDeletedTask: DeletedTask?
    @State private var newTaskTitle = ""
    @State private var newTaskStartDate = Self.defaultTaskStartDate()
    @State private var newTaskDurationMinutes = 30

    var body: some View {
        NavigationStack {
            Form {
                if !calendarService.hasCalendarAccess {
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
                    .disabled(!calendarService.hasCalendarAccess)
                }
            }
            .onAppear {
                loadInitialCalendarState()
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
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isShowingNewTaskSheet = false
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreatingTask ? "Creating..." : "Create") {
                        createTask()
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
            && calendarService.hasCalendarAccess
            && !isCreatingTask
    }

    private func beginNewTask() {
        newTaskTitle = ""
        newTaskStartDate = Self.defaultTaskStartDate()
        newTaskDurationMinutes = 30
        isShowingNewTaskSheet = true
    }

    private func requestCalendarAccess() {
        Task {
            do {
                let granted = try await calendarService.requestAccess()

                if granted {
                    statusText = nil
                    refreshTasks()
                } else {
                    statusText = "Calendar access denied"
                }
            } catch {
                statusText = "Calendar access failed: \(error.localizedDescription)"
            }
        }
    }

    private func createTask() {
        let trimmedTitle = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty else {
            statusText = "Add a task name first"
            return
        }

        isCreatingTask = true
        statusText = "Creating \(trimmedTitle)..."

        do {
            let createdTask = try calendarService.addTask(
                title: trimmedTitle,
                startDate: newTaskStartDate,
                durationMinutes: newTaskDurationMinutes
            )
            refreshTasks()
            upsertTask(createdTask)
            isShowingNewTaskSheet = false
            statusText = "Created \(trimmedTitle)."
        } catch {
            statusText = "Could not create task: \(error.localizedDescription)"
        }

        isCreatingTask = false
    }

    private func loadInitialCalendarState() {
        guard calendarService.hasCalendarAccess else {
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
