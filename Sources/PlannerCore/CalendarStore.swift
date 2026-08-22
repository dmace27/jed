import Foundation

public struct AuthorizationReport: Codable, Equatable, Sendable {
    public let events: String
    public let reminders: String
    public let canReadAndWriteEvents: Bool
    public let canReadAndWriteReminders: Bool
}

public protocol PlannerCalendarStore: Sendable {
    func authorizationReport() async -> AuthorizationReport
    func requestFullAccess() async throws -> AuthorizationReport
    func ensureStructure(courses: [CourseDefinition], apply: Bool) async throws -> SetupResult
    func events(from startDate: Date, to endDate: Date) async throws -> [PlannerEvent]
    func reminders(includeCompleted: Bool) async throws -> [PlannerTask]
    func createTask(_ request: TaskCreateRequest) async throws -> PlannerTask
    func updateTask(id: String, request: TaskUpdateRequest) async throws -> PlannerTask
    func completeTask(id: String) async throws -> PlannerTask
    func deleteTask(id: String) async throws
    func createEvent(_ request: EventCreateRequest) async throws -> PlannerEvent
    func updateEvent(id: String, request: EventUpdateRequest) async throws -> PlannerEvent
    func deleteEvent(id: String) async throws
}

public struct InMemoryCalendarStore: PlannerCalendarStore {
    private let state: State

    public init(events: [PlannerEvent] = [], tasks: [PlannerTask] = []) {
        state = State(events: events, tasks: tasks)
    }

    public func authorizationReport() async -> AuthorizationReport {
        AuthorizationReport(events: "fullAccess", reminders: "fullAccess", canReadAndWriteEvents: true, canReadAndWriteReminders: true)
    }

    public func requestFullAccess() async throws -> AuthorizationReport { await authorizationReport() }

    public func ensureStructure(courses: [CourseDefinition], apply: Bool) async throws -> SetupResult {
        let eventNames = courses.map(\.calendarName) + ["Recruiting", "Health", "Social", "Other"]
        let listNames = courses.map(\.reminderListName) + ["Recruiting", "Other"]
        return SetupResult(items: eventNames.map { SetupItem(kind: "calendar", name: $0, created: apply) }
            + listNames.map { SetupItem(kind: "reminder-list", name: $0, created: apply) })
    }

    public func events(from startDate: Date, to endDate: Date) async throws -> [PlannerEvent] {
        await state.events.filter { $0.startDate < endDate && $0.endDate > startDate }
    }

    public func reminders(includeCompleted: Bool) async throws -> [PlannerTask] {
        await state.tasks.filter { includeCompleted || !$0.isCompleted }
    }

    public func createTask(_ request: TaskCreateRequest) async throws -> PlannerTask {
        let task = PlannerTask(
            id: UUID().uuidString,
            title: request.title,
            listName: request.listName,
            dueDate: request.dueDate,
            notes: request.notes,
            applePriority: request.applePriority
        )
        await state.add(task: task)
        return task
    }

    public func updateTask(id: String, request: TaskUpdateRequest) async throws -> PlannerTask {
        try await state.updateTask(id: id, request: request)
    }

    public func completeTask(id: String) async throws -> PlannerTask {
        try await state.completeTask(id: id)
    }

    public func deleteTask(id: String) async throws { try await state.deleteTask(id: id) }

    public func createEvent(_ request: EventCreateRequest) async throws -> PlannerEvent {
        let event = PlannerEvent(
            id: UUID().uuidString,
            title: request.title,
            calendarName: request.calendarName,
            startDate: request.startDate,
            endDate: request.endDate,
            isAllDay: request.isAllDay,
            location: request.location,
            notes: request.notes
        )
        await state.add(event: event)
        return event
    }

    public func updateEvent(id: String, request: EventUpdateRequest) async throws -> PlannerEvent {
        try await state.updateEvent(id: id, request: request)
    }

    public func deleteEvent(id: String) async throws { try await state.deleteEvent(id: id) }

    private actor State {
        var events: [PlannerEvent]
        var tasks: [PlannerTask]

        init(events: [PlannerEvent], tasks: [PlannerTask]) {
            self.events = events
            self.tasks = tasks
        }

        func add(task: PlannerTask) { tasks.append(task) }
        func add(event: PlannerEvent) { events.append(event) }

        func updateTask(id: String, request: TaskUpdateRequest) throws -> PlannerTask {
            guard let index = tasks.firstIndex(where: { $0.id == id }) else {
                throw PlannerError.notFound("Task not found: \(id)")
            }
            if let title = request.title { tasks[index].title = title }
            if let listName = request.listName { tasks[index].listName = listName }
            if request.clearDueDate { tasks[index].dueDate = nil }
            else if let dueDate = request.dueDate { tasks[index].dueDate = dueDate }
            if request.clearNotes { tasks[index].notes = nil }
            else if let notes = request.notes { tasks[index].notes = notes }
            return tasks[index]
        }

        func completeTask(id: String) throws -> PlannerTask {
            guard let index = tasks.firstIndex(where: { $0.id == id }) else {
                throw PlannerError.notFound("Task not found: \(id)")
            }
            tasks[index].isCompleted = true
            tasks[index].completionDate = Date()
            return tasks[index]
        }

        func deleteTask(id: String) throws {
            guard let index = tasks.firstIndex(where: { $0.id == id }) else {
                throw PlannerError.notFound("Task not found: \(id)")
            }
            tasks.remove(at: index)
        }

        func updateEvent(id: String, request: EventUpdateRequest) throws -> PlannerEvent {
            guard let index = events.firstIndex(where: { $0.id == id }) else {
                throw PlannerError.notFound("Event not found: \(id)")
            }
            if let title = request.title { events[index].title = title }
            if let calendarName = request.calendarName { events[index].calendarName = calendarName }
            if let startDate = request.startDate { events[index].startDate = startDate }
            if let endDate = request.endDate { events[index].endDate = endDate }
            if request.clearLocation { events[index].location = nil }
            else if let location = request.location { events[index].location = location }
            if request.clearNotes { events[index].notes = nil }
            else if let notes = request.notes { events[index].notes = notes }
            return events[index]
        }

        func deleteEvent(id: String) throws {
            guard let index = events.firstIndex(where: { $0.id == id }) else {
                throw PlannerError.notFound("Event not found: \(id)")
            }
            events.remove(at: index)
        }
    }
}
