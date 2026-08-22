@preconcurrency import EventKit
import Foundation

/// Serializes all EventKit work through one actor and one event-store instance.
/// EventKit objects must not be mixed across event-store instances.
public actor EventKitCalendarStore: PlannerCalendarStore {
    private let eventStore: EKEventStore

    public init() {
        eventStore = EKEventStore()
    }

    public func authorizationReport() -> AuthorizationReport {
        let eventStatus = EKEventStore.authorizationStatus(for: .event)
        let reminderStatus = EKEventStore.authorizationStatus(for: .reminder)
        return AuthorizationReport(
            events: Self.statusName(eventStatus),
            reminders: Self.statusName(reminderStatus),
            canReadAndWriteEvents: eventStatus == .fullAccess,
            canReadAndWriteReminders: reminderStatus == .fullAccess
        )
    }

    public func requestFullAccess() async throws -> AuthorizationReport {
        let eventsGranted = try await eventStore.requestFullAccessToEvents()
        let remindersGranted = try await eventStore.requestFullAccessToReminders()
        eventStore.reset()
        guard eventsGranted, remindersGranted else {
            throw PlannerError.permissionDenied(
                "Planner needs Full Access to both Calendar and Reminders in System Settings → Privacy & Security."
            )
        }
        return authorizationReport()
    }

    public func ensureStructure(courses: [CourseDefinition], apply: Bool) throws -> SetupResult {
        try requireFullAccess()
        let calendarNames = courses.map(\.calendarName) + ["Recruiting", "Health", "Social", "Other"]
        let reminderNames = courses.map(\.reminderListName) + ["Recruiting", "Other"]
        var output: [SetupItem] = []

        for name in calendarNames {
            let exists = writableCalendar(named: name, entityType: .event) != nil
            if apply, !exists { try createCalendar(named: name, entityType: .event) }
            output.append(SetupItem(kind: "calendar", name: name, created: apply && !exists))
        }
        for name in reminderNames {
            let exists = writableCalendar(named: name, entityType: .reminder) != nil
            if apply, !exists { try createCalendar(named: name, entityType: .reminder) }
            output.append(SetupItem(kind: "reminder-list", name: name, created: apply && !exists))
        }
        return SetupResult(items: output)
    }

    public func events(from startDate: Date, to endDate: Date) throws -> [PlannerEvent] {
        try requireEventAccess()
        guard startDate < endDate else {
            throw PlannerError.invalidArgument("Event query end must be after its start.")
        }
        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        return eventStore.events(matching: predicate).map(Self.mapEvent)
    }

    public func reminders(includeCompleted: Bool) async throws -> [PlannerTask] {
        try requireReminderAccess()
        let predicate = eventStore.predicateForReminders(in: nil)
        let reminders: [PlannerTask] = await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { fetched in
                // Convert framework objects before crossing the continuation boundary;
                // EKReminder itself is intentionally not Sendable under Swift 6.
                continuation.resume(returning: (fetched ?? []).map(Self.mapReminder))
            }
        }
        return reminders.filter { includeCompleted || !$0.isCompleted }
    }

    public func createTask(_ request: TaskCreateRequest) throws -> PlannerTask {
        try requireReminderAccess()
        guard !request.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlannerError.invalidArgument("Task title cannot be empty.")
        }
        guard let list = writableCalendar(named: request.listName, entityType: .reminder) else {
            throw PlannerError.notFound("Writable Reminders list not found: \(request.listName). Run `planner setup --apply` first.")
        }
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = request.title
        reminder.calendar = list
        reminder.notes = request.notes
        reminder.priority = request.applePriority
        if let dueDate = request.dueDate {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone.current
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: dueDate)
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            reminder.dueDateComponents = components
        }
        try eventStore.save(reminder, commit: true)
        return Self.mapReminder(reminder)
    }

    public func updateTask(id: String, request: TaskUpdateRequest) throws -> PlannerTask {
        try requireReminderAccess()
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            throw PlannerError.notFound("Task not found: \(id)")
        }
        if let title = request.title { reminder.title = title }
        if let listName = request.listName {
            guard let list = writableCalendar(named: listName, entityType: .reminder) else {
                throw PlannerError.notFound("Writable Reminders list not found: \(listName)")
            }
            reminder.calendar = list
        }
        if request.clearDueDate {
            reminder.dueDateComponents = nil
        } else if let dueDate = request.dueDate {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone.current
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: dueDate)
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            reminder.dueDateComponents = components
        }
        if request.clearNotes { reminder.notes = nil }
        else if let notes = request.notes { reminder.notes = notes }
        try eventStore.save(reminder, commit: true)
        return Self.mapReminder(reminder)
    }

    public func completeTask(id: String) throws -> PlannerTask {
        try requireReminderAccess()
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            throw PlannerError.notFound("Task not found: \(id)")
        }
        reminder.isCompleted = true
        try eventStore.save(reminder, commit: true)
        return Self.mapReminder(reminder)
    }

    public func deleteTask(id: String) throws {
        try requireReminderAccess()
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            throw PlannerError.notFound("Task not found: \(id)")
        }
        try eventStore.remove(reminder, commit: true)
    }

    public func createEvent(_ request: EventCreateRequest) throws -> PlannerEvent {
        try requireEventAccess()
        try validateEventDates(start: request.startDate, end: request.endDate)
        guard let calendar = writableCalendar(named: request.calendarName, entityType: .event) else {
            throw PlannerError.notFound("Writable Calendar not found: \(request.calendarName). Run `planner setup --apply` first.")
        }
        let event = EKEvent(eventStore: eventStore)
        event.title = request.title
        event.calendar = calendar
        event.startDate = request.startDate
        event.endDate = request.endDate
        event.isAllDay = request.isAllDay
        event.location = request.location
        event.notes = request.notes
        try eventStore.save(event, span: .thisEvent, commit: true)
        return Self.mapEvent(event)
    }

    public func updateEvent(id: String, request: EventUpdateRequest) throws -> PlannerEvent {
        try requireEventAccess()
        guard let event = eventStore.calendarItem(withIdentifier: id) as? EKEvent else {
            throw PlannerError.notFound("Event not found: \(id)")
        }
        if let title = request.title { event.title = title }
        if let calendarName = request.calendarName {
            guard let calendar = writableCalendar(named: calendarName, entityType: .event) else {
                throw PlannerError.notFound("Writable Calendar not found: \(calendarName)")
            }
            event.calendar = calendar
        }
        if let startDate = request.startDate { event.startDate = startDate }
        if let endDate = request.endDate { event.endDate = endDate }
        try validateEventDates(start: event.startDate, end: event.endDate)
        if request.clearLocation { event.location = nil }
        else if let location = request.location { event.location = location }
        if request.clearNotes { event.notes = nil }
        else if let notes = request.notes { event.notes = notes }
        try eventStore.save(event, span: .thisEvent, commit: true)
        return Self.mapEvent(event)
    }

    public func deleteEvent(id: String) throws {
        try requireEventAccess()
        guard let event = eventStore.calendarItem(withIdentifier: id) as? EKEvent else {
            throw PlannerError.notFound("Event not found: \(id)")
        }
        try eventStore.remove(event, span: .thisEvent, commit: true)
    }

    private func requireFullAccess() throws {
        try requireEventAccess()
        try requireReminderAccess()
    }

    private func requireEventAccess() throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw PlannerError.permissionDenied("Calendar Full Access is required. Run `planner status --request-access`.")
        }
    }

    private func requireReminderAccess() throws {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            throw PlannerError.permissionDenied("Reminders Full Access is required. Run `planner status --request-access`.")
        }
    }

    private func writableCalendar(named name: String, entityType: EKEntityType) -> EKCalendar? {
        let normalized = name.normalizedPlannerText
        return eventStore.calendars(for: entityType).first {
            $0.allowsContentModifications && $0.title.normalizedPlannerText == normalized
        }
    }

    private func createCalendar(named name: String, entityType: EKEntityType) throws {
        let defaultCalendar = entityType == .event
            ? eventStore.defaultCalendarForNewEvents
            : eventStore.defaultCalendarForNewReminders()
        let preferredSource = defaultCalendar?.source
            ?? eventStore.sources.first(where: { $0.sourceType == .calDAV && $0.title.localizedCaseInsensitiveContains("icloud") })
            ?? eventStore.sources.first(where: { $0.sourceType == .local })
        guard let source = preferredSource else {
            throw PlannerError.eventKit("No writable iCloud or local source is available for \(name).")
        }
        let calendar = EKCalendar(for: entityType, eventStore: eventStore)
        calendar.title = name
        calendar.source = source
        try eventStore.saveCalendar(calendar, commit: true)
    }

    private func validateEventDates(start: Date, end: Date) throws {
        guard start < end else {
            throw PlannerError.invalidArgument("Event end must be after its start.")
        }
    }

    private static func mapReminder(_ reminder: EKReminder) -> PlannerTask {
        var dueDate: Date?
        if let components = reminder.dueDateComponents {
            var calendar = components.calendar ?? Calendar(identifier: .gregorian)
            calendar.timeZone = components.timeZone ?? .current
            dueDate = calendar.date(from: components)
        }
        return PlannerTask(
            id: reminder.calendarItemIdentifier,
            externalIdentifier: reminder.calendarItemExternalIdentifier,
            title: reminder.title ?? "Untitled reminder",
            listName: reminder.calendar.title,
            dueDate: dueDate,
            isCompleted: reminder.isCompleted,
            completionDate: reminder.completionDate,
            notes: reminder.notes,
            applePriority: reminder.priority
        )
    }

    private static func mapEvent(_ event: EKEvent) -> PlannerEvent {
        PlannerEvent(
            id: event.calendarItemIdentifier,
            title: event.title ?? "Untitled event",
            calendarName: event.calendar.title,
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            location: event.location,
            notes: event.notes
        )
    }

    private static func statusName(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .fullAccess: return "fullAccess"
        case .writeOnly: return "writeOnly"
        @unknown default: return "unknown"
        }
    }
}
