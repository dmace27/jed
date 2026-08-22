import Darwin
import Foundation
import PlannerCore

@main
struct PlannerCommand {
    static func main() async {
        do {
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            FileHandle.standardError.write(Data("planner: \(message)\n".utf8))
            Darwin.exit(1)
        }
    }

    private static func run(arguments: [String]) async throws {
        let arguments = try CLIArguments(arguments)
        if arguments.positionals.isEmpty || arguments.flags.contains("help") {
            printHelp()
            return
        }

        let configDirectory = try configurationDirectory(from: arguments)
        let configuration = try ConfigurationLoader.load(from: configDirectory)
        let renderer = OutputRenderer(json: arguments.flags.contains("json"), configuration: configuration)
        if arguments.positionals[0] == "self-test" {
            let result = try await runOfflineSelfTests(configuration: configuration)
            try renderer.render(result, human: "Offline self-test passed: \(result.checks.joined(separator: ", "))")
            return
        }
        let databaseURL = try arguments.value("db").map(URL.init(fileURLWithPath:))
            ?? PlannerPaths.defaultDatabaseURL()
        let metadataStore = try SQLiteMetadataStore(url: databaseURL)
        let calendarStore = EventKitCalendarStore()
        let service = PlannerService(
            calendarStore: calendarStore,
            metadataStore: metadataStore,
            configuration: configuration
        )
        switch arguments.positionals[0] {
        case "status":
            let report = arguments.flags.contains("request-access")
                ? try await calendarStore.requestFullAccess()
                : await calendarStore.authorizationReport()
            try renderer.render(report, human: RendererText.authorization(report))
        case "setup":
            let apply = arguments.flags.contains("apply")
            let result = try await calendarStore.ensureStructure(courses: configuration.courses, apply: apply)
            try renderer.render(result, human: RendererText.setup(result, applied: apply))
        case "today":
            let date = try DateCodec.day(arguments.value("date"), configuration: configuration)
            let brief = try await service.dailyBrief(on: date)
            try renderer.render(brief, human: RendererText.daily(brief, configuration: configuration))
        case "week":
            let date = try DateCodec.day(arguments.value("date"), configuration: configuration)
            let brief = try await service.weeklyBrief(on: date)
            try renderer.render(brief, human: RendererText.weekly(brief, configuration: configuration))
        case "calendar":
            try await runCalendar(arguments, store: calendarStore, configuration: configuration, renderer: renderer)
        case "tasks":
            let ranked = try await service.rankedTasks()
            let filtered = try filterTasks(ranked, arguments: arguments, configuration: configuration)
            try renderer.render(filtered, human: RendererText.rankedTasks(filtered, configuration: configuration))
        case "task":
            try await runTask(
                arguments,
                store: calendarStore,
                service: service,
                configuration: configuration,
                renderer: renderer
            )
        case "event":
            try await runEvent(
                arguments,
                store: calendarStore,
                service: service,
                configuration: configuration,
                renderer: renderer
            )
        case "focus":
            try await runFocus(arguments, service: service, configuration: configuration, renderer: renderer)
        default:
            throw PlannerError.invalidArgument("Unknown command: \(arguments.positionals[0]). Run `planner --help`.")
        }
    }

    private static func runCalendar(
        _ arguments: CLIArguments,
        store: any PlannerCalendarStore,
        configuration: PlannerConfiguration,
        renderer: OutputRenderer
    ) async throws {
        guard arguments.positionals.dropFirst().first == "today" else {
            throw PlannerError.invalidArgument("Usage: planner calendar today [--date YYYY-MM-DD]")
        }
        let date = try DateCodec.day(arguments.value("date"), configuration: configuration)
        let calendar = DateCodec.calendar(configuration)
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let events = try await store.events(from: start, to: end).sorted { $0.startDate < $1.startDate }
        try renderer.render(events, human: RendererText.events(events, configuration: configuration))
    }

    private static func runTask(
        _ arguments: CLIArguments,
        store: any PlannerCalendarStore,
        service: PlannerService,
        configuration: PlannerConfiguration,
        renderer: OutputRenderer
    ) async throws {
        guard arguments.positionals.count >= 2 else {
            throw PlannerError.invalidArgument("Task action is required. Run `planner --help`.")
        }
        let action = arguments.positionals[1]
        switch action {
        case "create":
            let title = try arguments.requiredValue("title")
            let destination = try taskDestination(arguments, configuration: configuration)
            let due = try arguments.value("due").map { try DateCodec.deadline($0, configuration: configuration) }
            let estimate = try arguments.integer("estimate-minutes")
            let importance = try arguments.integer("importance") ?? 0
            let request = TaskCreateRequest(
                title: title,
                listName: destination.listName,
                dueDate: due,
                notes: arguments.value("notes"),
                applePriority: try applePriority(arguments)
            )
            let task = try await service.createTask(
                request: request,
                estimatedMinutes: estimate,
                category: destination.category,
                courseID: destination.course?.id,
                importance: importance,
                parentQuery: arguments.value("parent")
            )
            try renderer.render(task, human: "Created task: \(task.title) [\(task.id)]")
        case "complete":
            let query = try positionalQuery(arguments, index: 2)
            let task = try await service.resolveTask(query)
            let completed = try await store.completeTask(id: task.id)
            try renderer.render(completed, human: "Completed: \(completed.title)")
        case "log":
            let query = try positionalQuery(arguments, index: 2)
            let minutes = try arguments.requiredInteger("minutes")
            let session = try await service.logWork(taskQuery: query, minutes: minutes, note: arguments.value("note"))
            try renderer.render(session, human: "Logged \(formatMinutes(session.minutes)) on task \(session.reminderID).")
        case "show":
            let query = try positionalQuery(arguments, index: 2)
            let task = try await service.resolveTask(query, includeCompleted: true)
            let metadata = try service.metadata(for: task)
            let result = TaskDetail(task: task, metadata: metadata)
            try renderer.render(result, human: RendererText.taskDetail(result, configuration: configuration))
        case "preview-update", "update":
            let query = try positionalQuery(arguments, index: 2)
            let task = try await service.resolveTask(query, includeCompleted: true)
            let request = try taskUpdateRequest(arguments, configuration: configuration)
            var preview = service.taskUpdatePreview(task: task, request: request)
            let contextChanges = try metadataChanges(arguments, task: task, service: service, configuration: configuration)
            preview = ChangePreview(
                itemID: preview.itemID,
                title: preview.title,
                action: preview.action,
                changes: preview.changes + contextChanges
            )
            if action == "preview-update" || !arguments.flags.contains("confirm-change") {
                try renderer.render(preview, human: RendererText.preview(preview, confirmationFlag: "--confirm-change"))
                return
            }
            var updated = task
            if !service.taskUpdatePreview(task: task, request: request).changes.isEmpty {
                updated = try await store.updateTask(id: task.id, request: request)
            }
            _ = try updateTaskMetadataIfRequested(arguments, task: updated, service: service, configuration: configuration)
            try renderer.render(updated, human: "Updated task: \(updated.title)")
        case "delete":
            let query = try positionalQuery(arguments, index: 2)
            let task = try await service.resolveTask(query, includeCompleted: true)
            let preview = service.deletePreview(task: task)
            guard arguments.flags.contains("confirm-delete") else {
                try renderer.render(preview, human: RendererText.preview(preview, confirmationFlag: "--confirm-delete"))
                return
            }
            try await store.deleteTask(id: task.id)
            try service.removeMetadata(for: task.id)
            try renderer.render(DeleteResult(id: task.id, title: task.title, deleted: true), human: "Deleted task: \(task.title)")
        default:
            throw PlannerError.invalidArgument("Unknown task action: \(action)")
        }
    }

    private static func runEvent(
        _ arguments: CLIArguments,
        store: any PlannerCalendarStore,
        service: PlannerService,
        configuration: PlannerConfiguration,
        renderer: OutputRenderer
    ) async throws {
        guard arguments.positionals.count >= 2 else {
            throw PlannerError.invalidArgument("Event action is required. Run `planner --help`.")
        }
        let action = arguments.positionals[1]
        switch action {
        case "create":
            let request = try eventCreateRequest(arguments, configuration: configuration)
            let conflicts = try await service.eventConflicts(start: request.startDate, end: request.endDate)
            let event = try await store.createEvent(request)
            let result = EventMutationResult(event: event, conflicts: conflicts)
            try renderer.render(result, human: RendererText.eventMutation(result, configuration: configuration))
        case "preview-update", "update":
            let query = try positionalQuery(arguments, index: 2)
            let event = try await service.resolveEvent(query)
            let request = try eventUpdateRequest(arguments, configuration: configuration)
            let preview = service.eventUpdatePreview(event: event, request: request)
            if action == "preview-update" || !arguments.flags.contains("confirm-change") {
                try renderer.render(preview, human: RendererText.preview(preview, confirmationFlag: "--confirm-change"))
                return
            }
            let proposedStart = request.startDate ?? event.startDate
            let proposedEnd = request.endDate ?? event.endDate
            let conflicts = try await service.eventConflicts(start: proposedStart, end: proposedEnd, excludingID: event.id)
            let updated = try await store.updateEvent(id: event.id, request: request)
            let result = EventMutationResult(event: updated, conflicts: conflicts)
            try renderer.render(result, human: RendererText.eventMutation(result, configuration: configuration))
        case "delete":
            let query = try positionalQuery(arguments, index: 2)
            let event = try await service.resolveEvent(query)
            let preview = service.deletePreview(event: event)
            guard arguments.flags.contains("confirm-delete") else {
                try renderer.render(preview, human: RendererText.preview(preview, confirmationFlag: "--confirm-delete"))
                return
            }
            try await store.deleteEvent(id: event.id)
            try renderer.render(DeleteResult(id: event.id, title: event.title, deleted: true), human: "Deleted event: \(event.title)")
        default:
            throw PlannerError.invalidArgument("Unknown event action: \(action)")
        }
    }

    private static func runFocus(
        _ arguments: CLIArguments,
        service: PlannerService,
        configuration: PlannerConfiguration,
        renderer: OutputRenderer
    ) async throws {
        guard arguments.positionals.dropFirst().first == "set" else {
            throw PlannerError.invalidArgument("Usage: planner focus set --target-type ...")
        }
        guard let type = FocusTargetType(rawValue: try arguments.requiredValue("target-type")) else {
            throw PlannerError.invalidArgument("target-type must be task, course, or category.")
        }
        let requestedTarget = try arguments.requiredValue("target")
        let target: String
        switch type {
        case .task:
            target = try await service.resolveTask(requestedTarget, includeCompleted: true).id
        case .course:
            guard let course = configuration.course(matching: requestedTarget) else {
                throw PlannerError.invalidArgument("Unknown course: \(requestedTarget)")
            }
            target = course.id
        case .category:
            guard let category = PlannerCategory(rawValue: requestedTarget) else {
                throw PlannerError.invalidArgument("Unknown category: \(requestedTarget)")
            }
            target = category.rawValue
        }
        let priority = try arguments.requiredInteger("priority")
        let start = try DateCodec.day(arguments.value("from"), configuration: configuration)
        let calendar = DateCodec.calendar(configuration)
        let end = try arguments.value("until").map { try DateCodec.endOfDay($0, configuration: configuration) }
            ?? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))!.addingTimeInterval(-1)
        let override = PriorityOverride(
            targetType: type,
            targetID: target,
            priority: priority,
            startsOn: calendar.startOfDay(for: start),
            expiresOn: end,
            reason: arguments.value("reason")
        )
        try service.saveFocusOverride(override)
        try renderer.render(override, human: "Saved temporary focus override for \(target).")
    }

    private static func filterTasks(
        _ tasks: [RankedTask],
        arguments: CLIArguments,
        configuration: PlannerConfiguration
    ) throws -> [RankedTask] {
        guard let duration = arguments.value("due-within") else { return tasks }
        guard duration.hasSuffix("d"), let days = Int(duration.dropLast()), days >= 0 else {
            throw PlannerError.invalidArgument("--due-within must use a non-negative day value such as 7d.")
        }
        let calendar = DateCodec.calendar(configuration)
        let end = calendar.date(byAdding: .day, value: days, to: Date())!
        return tasks.filter { $0.task.dueDate.map { $0 <= end } ?? false }
    }

    private static func taskDestination(
        _ arguments: CLIArguments,
        configuration: PlannerConfiguration
    ) throws -> (listName: String, category: PlannerCategory, course: CourseDefinition?) {
        if let courseValue = arguments.value("course") {
            guard let course = configuration.course(matching: courseValue) else {
                throw PlannerError.invalidArgument("Unknown course: \(courseValue)")
            }
            return (course.reminderListName, .academics, course)
        }
        if let list = arguments.value("list") {
            let category = try requestedCategory(arguments) ?? inferredCategory(list)
            return (list, category, nil)
        }
        let category = try requestedCategory(arguments) ?? .other
        return (category == .recruiting ? "Recruiting" : "Other", category, nil)
    }

    private static func eventCalendarName(_ arguments: CLIArguments, configuration: PlannerConfiguration) throws -> String {
        if let courseValue = arguments.value("course") {
            guard let course = configuration.course(matching: courseValue) else {
                throw PlannerError.invalidArgument("Unknown course: \(courseValue)")
            }
            return course.calendarName
        }
        if let calendar = arguments.value("calendar") { return calendar }
        let category = try requestedCategory(arguments) ?? .other
        switch category {
        case .recruiting: return "Recruiting"
        case .health: return "Health"
        case .social: return "Social"
        default: return "Other"
        }
    }

    private static func taskUpdateRequest(_ arguments: CLIArguments, configuration: PlannerConfiguration) throws -> TaskUpdateRequest {
        let due = try arguments.value("due").map { try DateCodec.deadline($0, configuration: configuration) }
        let list: String?
        if let courseValue = arguments.value("course") {
            guard let course = configuration.course(matching: courseValue) else {
                throw PlannerError.invalidArgument("Unknown course: \(courseValue)")
            }
            list = course.reminderListName
        } else {
            list = arguments.value("list")
        }
        return TaskUpdateRequest(
            title: arguments.value("title"),
            listName: list,
            dueDate: due,
            clearDueDate: arguments.flags.contains("clear-due"),
            notes: arguments.value("notes"),
            clearNotes: arguments.flags.contains("clear-notes")
        )
    }

    private static func metadataChanges(
        _ arguments: CLIArguments,
        task: PlannerTask,
        service: PlannerService,
        configuration: PlannerConfiguration
    ) throws -> [FieldChange] {
        let current = try service.metadata(for: task)
        var changes: [FieldChange] = []
        if arguments.flags.contains("clear-estimate") {
            changes.append(FieldChange(field: "estimatedMinutes", before: current?.estimatedMinutes.map(String.init), after: nil))
        } else if let estimate = try arguments.integer("estimate-minutes") {
            guard estimate > 0 else {
                throw PlannerError.invalidArgument("Estimated minutes must be positive.")
            }
            if estimate != current?.estimatedMinutes {
                changes.append(FieldChange(field: "estimatedMinutes", before: current?.estimatedMinutes.map(String.init), after: String(estimate)))
            }
        }
        if let category = arguments.value("category"), category != current?.category.rawValue {
            guard PlannerCategory(rawValue: category) != nil else {
                throw PlannerError.invalidArgument("Unknown category: \(category)")
            }
            changes.append(FieldChange(field: "category", before: current?.category.rawValue, after: category))
        }
        if arguments.flags.contains("clear-course") {
            changes.append(FieldChange(field: "course", before: current?.courseID, after: nil))
        } else if let courseValue = arguments.value("course") {
            guard let course = configuration.course(matching: courseValue) else {
                throw PlannerError.invalidArgument("Unknown course: \(courseValue)")
            }
            if course.id != current?.courseID {
                changes.append(FieldChange(field: "course", before: current?.courseID, after: course.id))
            }
            if arguments.value("category") == nil, current?.category != .academics {
                changes.append(FieldChange(field: "category", before: current?.category.rawValue, after: PlannerCategory.academics.rawValue))
            }
        }
        if let importance = try arguments.integer("importance") {
            guard (0...10).contains(importance) else {
                throw PlannerError.invalidArgument("Importance must be between 0 and 10.")
            }
            if importance != current?.importance {
                changes.append(FieldChange(field: "importance", before: current.map { String($0.importance) }, after: String(importance)))
            }
        }
        return changes
    }

    @discardableResult
    private static func updateTaskMetadataIfRequested(
        _ arguments: CLIArguments,
        task: PlannerTask,
        service: PlannerService,
        configuration: PlannerConfiguration
    ) throws -> TaskMetadata? {
        let hasChanges = arguments.value("estimate-minutes") != nil
            || arguments.flags.contains("clear-estimate")
            || arguments.value("category") != nil
            || arguments.value("course") != nil
            || arguments.flags.contains("clear-course")
            || arguments.value("importance") != nil
        guard hasChanges else { return nil }
        let course = arguments.value("course").flatMap { configuration.course(matching: $0) }
        let category = try requestedCategory(arguments) ?? (course == nil ? nil : .academics)
        return try service.updateMetadata(
            for: task,
            estimatedMinutes: try arguments.integer("estimate-minutes"),
            clearEstimate: arguments.flags.contains("clear-estimate"),
            category: category,
            courseID: course?.id,
            clearCourse: arguments.flags.contains("clear-course"),
            importance: try arguments.integer("importance")
        )
    }

    private static func eventCreateRequest(_ arguments: CLIArguments, configuration: PlannerConfiguration) throws -> EventCreateRequest {
        let title = try arguments.requiredValue("title")
        let start = try DateCodec.dateTime(try arguments.requiredValue("start"), configuration: configuration)
        let end = try DateCodec.dateTime(try arguments.requiredValue("end"), configuration: configuration)
        return EventCreateRequest(
            title: title,
            calendarName: try eventCalendarName(arguments, configuration: configuration),
            startDate: start,
            endDate: end,
            isAllDay: arguments.flags.contains("all-day"),
            location: arguments.value("location"),
            notes: arguments.value("notes")
        )
    }

    private static func eventUpdateRequest(_ arguments: CLIArguments, configuration: PlannerConfiguration) throws -> EventUpdateRequest {
        let start = try arguments.value("start").map { try DateCodec.dateTime($0, configuration: configuration) }
        let end = try arguments.value("end").map { try DateCodec.dateTime($0, configuration: configuration) }
        let calendar: String?
        if arguments.value("calendar") != nil || arguments.value("course") != nil || arguments.value("category") != nil {
            calendar = try eventCalendarName(arguments, configuration: configuration)
        } else {
            calendar = nil
        }
        return EventUpdateRequest(
            title: arguments.value("title"),
            calendarName: calendar,
            startDate: start,
            endDate: end,
            location: arguments.value("location"),
            clearLocation: arguments.flags.contains("clear-location"),
            notes: arguments.value("notes"),
            clearNotes: arguments.flags.contains("clear-notes")
        )
    }

    private static func configurationDirectory(from arguments: CLIArguments) throws -> URL {
        if let explicit = arguments.value("config") { return URL(fileURLWithPath: explicit, isDirectory: true) }
        let runtime = try PlannerPaths.defaultConfigurationDirectory()
        if FileManager.default.fileExists(atPath: runtime.appendingPathComponent("preferences.yaml").path) {
            return runtime
        }
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("config")
        if FileManager.default.fileExists(atPath: development.appendingPathComponent("preferences.yaml").path) {
            return development
        }
        return runtime
    }

    private static func positionalQuery(_ arguments: CLIArguments, index: Int) throws -> String {
        guard arguments.positionals.indices.contains(index) else {
            throw PlannerError.invalidArgument("A task or event ID/title is required.")
        }
        return arguments.positionals[index]
    }

    private static func inferredCategory(_ list: String) -> PlannerCategory {
        switch list.normalizedPlannerText {
        case "recruiting": return .recruiting
        case "health": return .health
        default: return .other
        }
    }

    private static func requestedCategory(_ arguments: CLIArguments) throws -> PlannerCategory? {
        guard let value = arguments.value("category") else { return nil }
        guard let category = PlannerCategory(rawValue: value) else {
            throw PlannerError.invalidArgument(
                "Unknown category \"\(value)\". Use: \(PlannerCategory.allCases.map(\.rawValue).joined(separator: ", "))."
            )
        }
        return category
    }

    private static func applePriority(_ arguments: CLIArguments) throws -> Int {
        let value = try arguments.integer("apple-priority") ?? 0
        guard (0...9).contains(value) else {
            throw PlannerError.invalidArgument("Apple priority must be between 0 and 9.")
        }
        return value
    }

    private static func runOfflineSelfTests(configuration: PlannerConfiguration) async throws -> SelfTestResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("planner-self-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let metadataStore = try SQLiteMetadataStore(url: directory.appendingPathComponent("planner.sqlite"))
        let now = Date()
        let urgent = PlannerTask(
            id: "urgent",
            externalIdentifier: "external-urgent",
            title: "Urgent assignment",
            listName: "Other",
            dueDate: now.addingTimeInterval(3_600)
        )
        let later = PlannerTask(id: "later", title: "Later task", listName: "Other")
        try metadataStore.upsert(TaskMetadata(
            reminderID: urgent.id,
            externalIdentifier: urgent.externalIdentifier,
            estimatedMinutes: 120,
            category: .academics
        ))
        try metadataStore.logWork(WorkSession(reminderID: urgent.id, minutes: 30))
        guard try metadataStore.workTotals(for: [urgent.id])[urgent.id] == 30 else {
            throw PlannerError.storage("Offline self-test could not round-trip a work session.")
        }

        let inMemoryStore = InMemoryCalendarStore(tasks: [later, urgent])
        let service = PlannerService(
            calendarStore: inMemoryStore,
            metadataStore: metadataStore,
            configuration: configuration
        )
        let ranked = try await service.rankedTasks(now: now)
        guard ranked.first?.task.id == urgent.id, ranked.first?.remainingMinutes == 90 else {
            throw PlannerError.invalidConfiguration("Offline self-test planning result was incorrect.")
        }
        guard try await service.resolveTask("urgent").id == urgent.id else {
            throw PlannerError.notFound("Offline self-test task resolution failed.")
        }
        return SelfTestResult(checks: [
            "configuration",
            "SQLite migrations",
            "metadata round-trip",
            "work logging",
            "task resolution",
            "planning rank",
            "remaining effort",
        ])
    }

    private static func printHelp() {
        print(
            """
            planner — local Apple Calendar and Reminders control layer

            Read:
              planner self-test
              planner status [--request-access]
              planner setup [--apply]
              planner today [--date YYYY-MM-DD]
              planner week [--date YYYY-MM-DD]
              planner calendar today [--date YYYY-MM-DD]
              planner tasks [--due-within 7d]

            Tasks:
              planner task create --title TEXT [--course ALIAS|--list NAME|--category NAME]
                  [--due DATE|DATETIME] [--estimate-minutes N] [--importance N]
                  [--notes TEXT] [--parent TASK]
              planner task show TASK
              planner task complete TASK
              planner task log TASK --minutes N [--note TEXT]
              planner task preview-update TASK [update options]
              planner task update TASK [update options] --confirm-change
              planner task delete TASK --confirm-delete

            Events:
              planner event create --title TEXT --start DATETIME --end DATETIME
                  [--course ALIAS|--calendar NAME|--category NAME] [--location TEXT]
              planner event preview-update EVENT [update options]
              planner event update EVENT [update options] --confirm-change
              planner event delete EVENT --confirm-delete

            Focus:
              planner focus set --target-type task|course|category --target ID
                  --priority 1..10 [--from YYYY-MM-DD] [--until YYYY-MM-DD] [--reason TEXT]

            Global options:
              --json            Emit stable JSON for Codex.
              --config PATH     Override the configuration directory.
              --db PATH         Override the metadata database path.
              --help            Show this help.

            DATE defaults to 23:59 in the configured timezone. DATETIME accepts
            YYYY-MM-DDTHH:mm or an ISO-8601 timestamp with an explicit offset.
            """
        )
    }
}

private struct CLIArguments {
    let positionals: [String]
    let options: [String: String]
    let flags: Set<String>

    private static let booleanFlags: Set<String> = [
        "all-day", "apply", "clear-course", "clear-due", "clear-estimate",
        "clear-location", "clear-notes", "confirm-change", "confirm-delete",
        "help", "include-completed", "json", "open", "request-access",
    ]

    init(_ raw: [String]) throws {
        var positionals: [String] = []
        var options: [String: String] = [:]
        var flags = Set<String>()
        var index = 0
        while index < raw.count {
            let token = raw[index]
            guard token.hasPrefix("--") else {
                positionals.append(token)
                index += 1
                continue
            }
            let name = String(token.dropFirst(2))
            if Self.booleanFlags.contains(name) {
                flags.insert(name)
                index += 1
            } else {
                guard raw.indices.contains(index + 1), !raw[index + 1].hasPrefix("--") else {
                    throw PlannerError.invalidArgument("Option --\(name) requires a value.")
                }
                options[name] = raw[index + 1]
                index += 2
            }
        }
        self.positionals = positionals
        self.options = options
        self.flags = flags
    }

    func value(_ name: String) -> String? { options[name] }

    func requiredValue(_ name: String) throws -> String {
        guard let value = value(name), !value.isEmpty else {
            throw PlannerError.invalidArgument("Missing required option --\(name).")
        }
        return value
    }

    func integer(_ name: String) throws -> Int? {
        guard let raw = value(name) else { return nil }
        guard let value = Int(raw) else {
            throw PlannerError.invalidArgument("--\(name) must be an integer.")
        }
        return value
    }

    func requiredInteger(_ name: String) throws -> Int {
        guard let value = try integer(name) else {
            throw PlannerError.invalidArgument("Missing required option --\(name).")
        }
        return value
    }
}

private enum DateCodec {
    static func calendar(_ configuration: PlannerConfiguration) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: configuration.preferences.timeZoneIdentifier) ?? .current
        return calendar
    }

    static func day(_ value: String?, configuration: PlannerConfiguration) throws -> Date {
        guard let value else { return Date() }
        let formatter = DateFormatter()
        formatter.calendar = calendar(configuration)
        formatter.timeZone = formatter.calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let result = formatter.date(from: value) else {
            throw PlannerError.invalidArgument("Invalid date \"\(value)\"; expected YYYY-MM-DD.")
        }
        return result
    }

    static func endOfDay(_ value: String, configuration: PlannerConfiguration) throws -> Date {
        let date = try day(value, configuration: configuration)
        return calendar(configuration).date(byAdding: .day, value: 1, to: date)!.addingTimeInterval(-1)
    }

    static func deadline(_ value: String, configuration: PlannerConfiguration) throws -> Date {
        if !value.contains("T") {
            let date = try day(value, configuration: configuration)
            var components = calendar(configuration).dateComponents([.year, .month, .day], from: date)
            components.hour = configuration.preferences.defaultDueTime.hour
            components.minute = configuration.preferences.defaultDueTime.minute
            components.timeZone = calendar(configuration).timeZone
            return calendar(configuration).date(from: components)!
        }
        return try dateTime(value, configuration: configuration)
    }

    static func dateTime(_ value: String, configuration: PlannerConfiguration) throws -> Date {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }

        let formatter = DateFormatter()
        formatter.calendar = calendar(configuration)
        formatter.timeZone = formatter.calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        guard let date = formatter.date(from: value) else {
            throw PlannerError.invalidArgument("Invalid datetime \"\(value)\"; expected YYYY-MM-DDTHH:mm or ISO-8601.")
        }
        return date
    }
}

private struct TaskDetail: Codable {
    let task: PlannerTask
    let metadata: TaskMetadata?
}

private struct DeleteResult: Codable {
    let id: String
    let title: String
    let deleted: Bool
}

private struct EventMutationResult: Codable {
    let event: PlannerEvent
    let conflicts: [PlannerEvent]
}

private struct SelfTestResult: Codable {
    let checks: [String]
}

private struct OutputRenderer {
    let json: Bool
    let configuration: PlannerConfiguration

    func render<T: Encodable>(_ value: T, human: String) throws {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            FileHandle.standardOutput.write(try encoder.encode(value))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            print(human)
        }
    }
}

private enum RendererText {
    static func authorization(_ report: AuthorizationReport) -> String {
        "Calendar: \(report.events)\nReminders: \(report.reminders)"
    }

    static func setup(_ result: SetupResult, applied: Bool) -> String {
        let heading = applied ? "Planner structure:" : "Setup preview (run with --apply to create missing items):"
        return ([heading] + result.items.map { item in
            let state = item.created ? "created" : "exists or would be created"
            return "- \(item.kind): \(item.name) — \(state)"
        }).joined(separator: "\n")
    }

    static func daily(_ brief: DailyBrief, configuration: PlannerConfiguration) -> String {
        var lines = [dateHeading(brief.date, configuration: configuration), "", "FIXED", events(brief.events, configuration: configuration)]
        lines += ["", "AIM TO ACCOMPLISH", rankedTasks(brief.focus, configuration: configuration)]
        if !brief.ifTime.isEmpty { lines += ["", "IF YOU HAVE TIME", rankedTasks(brief.ifTime, configuration: configuration)] }
        if !brief.upcoming.isEmpty { lines += ["", "COMING UP", rankedTasks(brief.upcoming, configuration: configuration)] }
        if !brief.warnings.isEmpty { lines += ["", "RISKS"] + brief.warnings.map { "- \($0)" } }
        return lines.joined(separator: "\n")
    }

    static func weekly(_ brief: WeeklyBrief, configuration: PlannerConfiguration) -> String {
        var lines = ["NEXT \(configuration.preferences.weeklyLookaheadDays) DAYS", "", rankedTasks(brief.tasks, configuration: configuration)]
        if !brief.warnings.isEmpty { lines += ["", "RISKS"] + brief.warnings.map { "- \($0)" } }
        return lines.joined(separator: "\n")
    }

    static func events(_ events: [PlannerEvent], configuration: PlannerConfiguration) -> String {
        guard !events.isEmpty else { return "No fixed events." }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone(identifier: configuration.preferences.timeZoneIdentifier)
        return events.map { event in
            event.isAllDay ? "- All day  \(event.title)" : "- \(formatter.string(from: event.startDate))  \(event.title)"
        }.joined(separator: "\n")
    }

    static func rankedTasks(_ tasks: [RankedTask], configuration: PlannerConfiguration) -> String {
        guard !tasks.isEmpty else { return "No open tasks." }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d, HH:mm"
        formatter.timeZone = TimeZone(identifier: configuration.preferences.timeZoneIdentifier)
        return tasks.enumerated().map { index, ranked in
            let due = ranked.task.dueDate.map { "due \(formatter.string(from: $0))" } ?? "no deadline"
            let remaining = ranked.remainingMinutes.map { " • ~\(formatMinutes($0)) remaining" } ?? ""
            let children = ranked.children.filter { !$0.isCompleted }.map { "\n    - \($0.title)" }.joined()
            return "\(index + 1). \(ranked.task.title) — \(due)\(remaining)\(children)"
        }.joined(separator: "\n")
    }

    static func taskDetail(_ detail: TaskDetail, configuration: PlannerConfiguration) -> String {
        var lines = ["\(detail.task.title) [\(detail.task.id)]", "List: \(detail.task.listName)"]
        if let due = detail.task.dueDate { lines.append("Due: \(ISO8601DateFormatter().string(from: due))") }
        if let estimate = detail.metadata?.estimatedMinutes { lines.append("Estimate: \(formatMinutes(estimate))") }
        if let category = detail.metadata?.category { lines.append("Category: \(category.rawValue)") }
        return lines.joined(separator: "\n")
    }

    static func preview(_ preview: ChangePreview, confirmationFlag: String) -> String {
        var lines = ["Preview: \(preview.action) \(preview.title) [\(preview.itemID)]"]
        if preview.changes.isEmpty { lines.append("- No field changes") }
        else { lines += preview.changes.map { "- \($0.field): \($0.before ?? "∅") → \($0.after ?? "∅")" } }
        lines.append("Re-run the command with \(confirmationFlag) to apply.")
        return lines.joined(separator: "\n")
    }

    static func eventMutation(_ result: EventMutationResult, configuration: PlannerConfiguration) -> String {
        var lines = ["Saved event: \(result.event.title) [\(result.event.id)]"]
        if !result.conflicts.isEmpty {
            lines.append("Conflicts detected:")
            lines += result.conflicts.map { "- \($0.title)" }
        }
        return lines.joined(separator: "\n")
    }

    private static func dateHeading(_ date: Date, configuration: PlannerConfiguration) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        formatter.timeZone = TimeZone(identifier: configuration.preferences.timeZoneIdentifier)
        return formatter.string(from: date).uppercased()
    }
}
