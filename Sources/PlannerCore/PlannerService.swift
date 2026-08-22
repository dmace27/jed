import Foundation

public struct PlannerService: Sendable {
    private let calendarStore: any PlannerCalendarStore
    private let metadataStore: any PlannerMetadataStore
    private let configuration: PlannerConfiguration
    private let engine: PlannerEngine

    public init(
        calendarStore: any PlannerCalendarStore,
        metadataStore: any PlannerMetadataStore,
        configuration: PlannerConfiguration,
        engine: PlannerEngine = PlannerEngine()
    ) {
        self.calendarStore = calendarStore
        self.metadataStore = metadataStore
        self.configuration = configuration
        self.engine = engine
    }

    public func rankedTasks(now: Date = Date()) async throws -> [RankedTask] {
        let tasks = try await calendarStore.reminders(includeCompleted: false)
        let metadata = try metadataStore.metadata(for: tasks)
        let totals = try metadataStore.workTotals(for: tasks.map(\.id))
        let overrides = try metadataStore.activeOverrides(on: now)
        let relations = try metadataStore.relations()
        return engine.rankTasks(
            tasks,
            metadata: metadata,
            workMinutes: totals,
            relations: relations,
            overrides: overrides,
            configuration: configuration,
            now: now
        )
    }

    public func dailyBrief(on date: Date = Date()) async throws -> DailyBrief {
        let calendar = configuredCalendar()
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        async let events = calendarStore.events(from: start, to: end)
        async let tasks = rankedTasks(now: date)
        return try await engine.makeDailyBrief(
            date: date,
            events: events,
            rankedTasks: tasks,
            configuration: configuration
        )
    }

    public func weeklyBrief(on date: Date = Date()) async throws -> WeeklyBrief {
        let calendar = configuredCalendar()
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: configuration.preferences.weeklyLookaheadDays, to: start)!
        async let events = calendarStore.events(from: start, to: end)
        async let tasks = rankedTasks(now: date)
        return try await engine.makeWeeklyBrief(
            date: date,
            events: events,
            rankedTasks: tasks,
            configuration: configuration
        )
    }

    public func resolveTask(_ query: String, includeCompleted: Bool = false) async throws -> PlannerTask {
        let tasks = try await calendarStore.reminders(includeCompleted: includeCompleted)
        if let identifierMatch = tasks.first(where: { $0.id == query }) { return identifierMatch }
        let needle = query.normalizedPlannerText
        let exact = tasks.filter { $0.title.normalizedPlannerText == needle }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { throw PlannerError.ambiguous(query, exact.map { "\($0.title) [\($0.id)]" }) }
        let partial = tasks.filter { $0.title.normalizedPlannerText.contains(needle) }
        if partial.count == 1 { return partial[0] }
        if partial.count > 1 { throw PlannerError.ambiguous(query, partial.map { "\($0.title) [\($0.id)]" }) }
        throw PlannerError.notFound("No task matches \"\(query)\".")
    }

    public func resolveEvent(_ query: String, around date: Date = Date()) async throws -> PlannerEvent {
        let calendar = configuredCalendar()
        let start = calendar.date(byAdding: .year, value: -1, to: date)!
        let end = calendar.date(byAdding: .year, value: 2, to: date)!
        let events = try await calendarStore.events(from: start, to: end)
        if let identifierMatch = events.first(where: { $0.id == query }) { return identifierMatch }
        let needle = query.normalizedPlannerText
        let exact = events.filter { $0.title.normalizedPlannerText == needle }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { throw PlannerError.ambiguous(query, exact.map { "\($0.title) at \($0.startDate) [\($0.id)]" }) }
        let partial = events.filter { $0.title.normalizedPlannerText.contains(needle) }
        if partial.count == 1 { return partial[0] }
        if partial.count > 1 { throw PlannerError.ambiguous(query, partial.map { "\($0.title) at \($0.startDate) [\($0.id)]" }) }
        throw PlannerError.notFound("No event matches \"\(query)\".")
    }

    public func createTask(
        request: TaskCreateRequest,
        estimatedMinutes: Int?,
        category: PlannerCategory,
        courseID: String?,
        importance: Int = 0,
        parentQuery: String? = nil
    ) async throws -> PlannerTask {
        if let estimatedMinutes, estimatedMinutes <= 0 {
            throw PlannerError.invalidArgument("Estimated minutes must be positive.")
        }
        guard (0...10).contains(importance) else {
            throw PlannerError.invalidArgument("Importance must be between 0 and 10.")
        }
        let parent: PlannerTask?
        if let parentQuery {
            parent = try await resolveTask(parentQuery)
        } else {
            parent = nil
        }
        let task = try await calendarStore.createTask(request)
        let metadata = TaskMetadata(
            reminderID: task.id,
            externalIdentifier: task.externalIdentifier,
            estimatedMinutes: estimatedMinutes,
            category: category,
            courseID: courseID,
            importance: importance
        )
        do {
            try metadataStore.upsert(metadata)
            if let parent {
                try metadataStore.saveRelation(TaskRelation(parentReminderID: parent.id, childReminderID: task.id))
            }
        } catch {
            // The reminder remains valid if metadata persistence fails. Report the failure so
            // the caller knows that effort context or task linking was not saved.
            throw PlannerError.storage("Task was created in Reminders, but planner metadata failed to save: \(error.localizedDescription)")
        }
        return task
    }

    public func logWork(taskQuery: String, minutes: Int, note: String?) async throws -> WorkSession {
        let task = try await resolveTask(taskQuery)
        let session = WorkSession(reminderID: task.id, minutes: minutes, note: note)
        try metadataStore.logWork(session)
        return session
    }

    public func metadata(for task: PlannerTask) throws -> TaskMetadata? {
        try metadataStore.metadata(for: [task])[task.id]
    }

    public func updateMetadata(
        for task: PlannerTask,
        estimatedMinutes: Int?,
        clearEstimate: Bool,
        category: PlannerCategory?,
        courseID: String?,
        clearCourse: Bool,
        importance: Int?
    ) throws -> TaskMetadata {
        if let estimatedMinutes, estimatedMinutes <= 0 {
            throw PlannerError.invalidArgument("Estimated minutes must be positive.")
        }
        if let importance, !(0...10).contains(importance) {
            throw PlannerError.invalidArgument("Importance must be between 0 and 10.")
        }
        var value = try metadata(for: task) ?? TaskMetadata(
            reminderID: task.id,
            externalIdentifier: task.externalIdentifier,
            category: .other
        )
        if clearEstimate { value.estimatedMinutes = nil }
        else if let estimatedMinutes { value.estimatedMinutes = estimatedMinutes }
        if let category { value.category = category }
        if clearCourse { value.courseID = nil }
        else if let courseID { value.courseID = courseID }
        if let importance { value.importance = importance }
        value.updatedAt = Date()
        try metadataStore.upsert(value)
        return value
    }

    public func saveFocusOverride(_ override: PriorityOverride) throws {
        try metadataStore.saveOverride(override)
    }

    public func eventConflicts(start: Date, end: Date, excludingID: String? = nil) async throws -> [PlannerEvent] {
        let events = try await calendarStore.events(from: start, to: end)
        return events.filter { $0.id != excludingID && $0.startDate < end && $0.endDate > start }
    }

    public func taskUpdatePreview(task: PlannerTask, request: TaskUpdateRequest) -> ChangePreview {
        var changes: [FieldChange] = []
        if let title = request.title, title != task.title { changes.append(FieldChange(field: "title", before: task.title, after: title)) }
        if let list = request.listName, list != task.listName { changes.append(FieldChange(field: "list", before: task.listName, after: list)) }
        if request.clearDueDate { changes.append(FieldChange(field: "dueDate", before: task.dueDate.map(isoDate), after: nil)) }
        else if let due = request.dueDate, due != task.dueDate { changes.append(FieldChange(field: "dueDate", before: task.dueDate.map(isoDate), after: isoDate(due))) }
        if request.clearNotes { changes.append(FieldChange(field: "notes", before: task.notes, after: nil)) }
        else if let notes = request.notes, notes != task.notes { changes.append(FieldChange(field: "notes", before: task.notes, after: notes)) }
        return ChangePreview(itemID: task.id, title: task.title, action: "update-task", changes: changes)
    }

    public func eventUpdatePreview(event: PlannerEvent, request: EventUpdateRequest) -> ChangePreview {
        var changes: [FieldChange] = []
        if let title = request.title, title != event.title { changes.append(FieldChange(field: "title", before: event.title, after: title)) }
        if let calendar = request.calendarName, calendar != event.calendarName { changes.append(FieldChange(field: "calendar", before: event.calendarName, after: calendar)) }
        if let start = request.startDate, start != event.startDate { changes.append(FieldChange(field: "startDate", before: isoDate(event.startDate), after: isoDate(start))) }
        if let end = request.endDate, end != event.endDate { changes.append(FieldChange(field: "endDate", before: isoDate(event.endDate), after: isoDate(end))) }
        if request.clearLocation { changes.append(FieldChange(field: "location", before: event.location, after: nil)) }
        else if let location = request.location, location != event.location { changes.append(FieldChange(field: "location", before: event.location, after: location)) }
        if request.clearNotes { changes.append(FieldChange(field: "notes", before: event.notes, after: nil)) }
        else if let notes = request.notes, notes != event.notes { changes.append(FieldChange(field: "notes", before: event.notes, after: notes)) }
        return ChangePreview(itemID: event.id, title: event.title, action: "update-event", changes: changes)
    }

    public func deletePreview(task: PlannerTask) -> ChangePreview {
        ChangePreview(itemID: task.id, title: task.title, action: "delete-task", changes: [])
    }

    public func deletePreview(event: PlannerEvent) -> ChangePreview {
        ChangePreview(itemID: event.id, title: event.title, action: "delete-event", changes: [])
    }

    public func removeMetadata(for reminderID: String) throws {
        try metadataStore.removeMetadata(for: reminderID)
    }

    private func configuredCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: configuration.preferences.timeZoneIdentifier) ?? .current
        return calendar
    }

    private func isoDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
