import Foundation

public enum PlannerCategory: String, CaseIterable, Codable, Sendable {
    case academics
    case health
    case recruiting
    case clubs
    case social
    case personal
    case other
}

public struct CourseDefinition: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let aliases: [String]

    public init(id: String, name: String, aliases: [String]) {
        self.id = id
        self.name = name
        self.aliases = aliases
    }

    public var calendarName: String { "Class • \(name)" }
    public var reminderListName: String { name }
}

public struct PlannerPreferences: Codable, Equatable, Sendable {
    public var priorityDefaults: [PlannerCategory: Int]
    public var defaultDueTime: DateComponents
    public var timeZoneIdentifier: String
    public var upcomingDays: Int
    public var weeklyLookaheadDays: Int
    public var dailyFocusLimit: Int

    public init(
        priorityDefaults: [PlannerCategory: Int] = PlannerPreferences.standardPriorities,
        defaultDueTime: DateComponents = DateComponents(hour: 23, minute: 59),
        timeZoneIdentifier: String = TimeZone.current.identifier,
        upcomingDays: Int = 7,
        weeklyLookaheadDays: Int = 14,
        dailyFocusLimit: Int = 3
    ) {
        self.priorityDefaults = priorityDefaults
        self.defaultDueTime = defaultDueTime
        self.timeZoneIdentifier = timeZoneIdentifier
        self.upcomingDays = upcomingDays
        self.weeklyLookaheadDays = weeklyLookaheadDays
        self.dailyFocusLimit = dailyFocusLimit
    }

    public static let standardPriorities: [PlannerCategory: Int] = [
        .academics: 4,
        .health: 4,
        .recruiting: 3,
        .clubs: 2,
        .social: 2,
        .personal: 1,
        .other: 1,
    ]
}

public struct PlannerConfiguration: Codable, Equatable, Sendable {
    public let preferences: PlannerPreferences
    public let courses: [CourseDefinition]

    public init(preferences: PlannerPreferences, courses: [CourseDefinition]) {
        self.preferences = preferences
        self.courses = courses
    }

    public func course(matching value: String) -> CourseDefinition? {
        let needle = value.normalizedPlannerText
        return courses.first { course in
            course.id.normalizedPlannerText == needle
                || course.name.normalizedPlannerText == needle
                || course.aliases.contains { $0.normalizedPlannerText == needle }
        }
    }
}

public struct PlannerTask: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let externalIdentifier: String?
    public var title: String
    public var listName: String
    public var dueDate: Date?
    public var isCompleted: Bool
    public var completionDate: Date?
    public var notes: String?
    public var applePriority: Int

    public init(
        id: String,
        externalIdentifier: String? = nil,
        title: String,
        listName: String,
        dueDate: Date? = nil,
        isCompleted: Bool = false,
        completionDate: Date? = nil,
        notes: String? = nil,
        applePriority: Int = 0
    ) {
        self.id = id
        self.externalIdentifier = externalIdentifier
        self.title = title
        self.listName = listName
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.completionDate = completionDate
        self.notes = notes
        self.applePriority = applePriority
    }
}

public struct PlannerEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var calendarName: String
    public var startDate: Date
    public var endDate: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?

    public init(
        id: String,
        title: String,
        calendarName: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        location: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.calendarName = calendarName
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
    }
}

public struct TaskMetadata: Codable, Equatable, Sendable {
    public let reminderID: String
    public var externalIdentifier: String?
    public var estimatedMinutes: Int?
    public var category: PlannerCategory
    public var courseID: String?
    public var importance: Int
    public var notes: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        reminderID: String,
        externalIdentifier: String? = nil,
        estimatedMinutes: Int? = nil,
        category: PlannerCategory = .other,
        courseID: String? = nil,
        importance: Int = 0,
        notes: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.reminderID = reminderID
        self.externalIdentifier = externalIdentifier
        self.estimatedMinutes = estimatedMinutes
        self.category = category
        self.courseID = courseID
        self.importance = importance
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct WorkSession: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let reminderID: String
    public let minutes: Int
    public let loggedAt: Date
    public let note: String?

    public init(
        id: String = UUID().uuidString,
        reminderID: String,
        minutes: Int,
        loggedAt: Date = Date(),
        note: String? = nil
    ) {
        self.id = id
        self.reminderID = reminderID
        self.minutes = minutes
        self.loggedAt = loggedAt
        self.note = note
    }
}

public enum FocusTargetType: String, Codable, Sendable {
    case task
    case course
    case category
}

public struct PriorityOverride: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let targetType: FocusTargetType
    public let targetID: String
    public let priority: Int
    public let startsOn: Date
    public let expiresOn: Date
    public let reason: String?

    public init(
        id: String = UUID().uuidString,
        targetType: FocusTargetType,
        targetID: String,
        priority: Int,
        startsOn: Date,
        expiresOn: Date,
        reason: String? = nil
    ) {
        self.id = id
        self.targetType = targetType
        self.targetID = targetID
        self.priority = priority
        self.startsOn = startsOn
        self.expiresOn = expiresOn
        self.reason = reason
    }
}

public struct TaskRelation: Codable, Equatable, Sendable {
    public let parentReminderID: String
    public let childReminderID: String

    public init(parentReminderID: String, childReminderID: String) {
        self.parentReminderID = parentReminderID
        self.childReminderID = childReminderID
    }
}

public struct RankedTask: Codable, Equatable, Sendable {
    public let task: PlannerTask
    public let metadata: TaskMetadata?
    public let minutesLogged: Int
    public let remainingMinutes: Int?
    public let score: Int
    public let reasons: [String]
    public let children: [PlannerTask]
}

public struct DailyBrief: Codable, Equatable, Sendable {
    public let date: Date
    public let events: [PlannerEvent]
    public let focus: [RankedTask]
    public let ifTime: [RankedTask]
    public let upcoming: [RankedTask]
    public let warnings: [String]
}

public struct WeeklyBrief: Codable, Equatable, Sendable {
    public let startsOn: Date
    public let endsOn: Date
    public let tasks: [RankedTask]
    public let events: [PlannerEvent]
    public let warnings: [String]
}

public struct SetupItem: Codable, Equatable, Sendable {
    public let kind: String
    public let name: String
    public let created: Bool
}

public struct SetupResult: Codable, Equatable, Sendable {
    public let items: [SetupItem]
}

public struct TaskCreateRequest: Codable, Equatable, Sendable {
    public var title: String
    public var listName: String
    public var dueDate: Date?
    public var notes: String?
    public var applePriority: Int

    public init(title: String, listName: String, dueDate: Date? = nil, notes: String? = nil, applePriority: Int = 0) {
        self.title = title
        self.listName = listName
        self.dueDate = dueDate
        self.notes = notes
        self.applePriority = applePriority
    }
}

public struct TaskUpdateRequest: Codable, Equatable, Sendable {
    public var title: String?
    public var listName: String?
    public var dueDate: Date?
    public var clearDueDate: Bool
    public var notes: String?
    public var clearNotes: Bool

    public init(
        title: String? = nil,
        listName: String? = nil,
        dueDate: Date? = nil,
        clearDueDate: Bool = false,
        notes: String? = nil,
        clearNotes: Bool = false
    ) {
        self.title = title
        self.listName = listName
        self.dueDate = dueDate
        self.clearDueDate = clearDueDate
        self.notes = notes
        self.clearNotes = clearNotes
    }
}

public struct EventCreateRequest: Codable, Equatable, Sendable {
    public var title: String
    public var calendarName: String
    public var startDate: Date
    public var endDate: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?

    public init(
        title: String,
        calendarName: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        location: String? = nil,
        notes: String? = nil
    ) {
        self.title = title
        self.calendarName = calendarName
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
    }
}

public struct EventUpdateRequest: Codable, Equatable, Sendable {
    public var title: String?
    public var calendarName: String?
    public var startDate: Date?
    public var endDate: Date?
    public var location: String?
    public var clearLocation: Bool
    public var notes: String?
    public var clearNotes: Bool

    public init(
        title: String? = nil,
        calendarName: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        location: String? = nil,
        clearLocation: Bool = false,
        notes: String? = nil,
        clearNotes: Bool = false
    ) {
        self.title = title
        self.calendarName = calendarName
        self.startDate = startDate
        self.endDate = endDate
        self.location = location
        self.clearLocation = clearLocation
        self.notes = notes
        self.clearNotes = clearNotes
    }
}

public struct FieldChange: Codable, Equatable, Sendable {
    public let field: String
    public let before: String?
    public let after: String?

    public init(field: String, before: String?, after: String?) {
        self.field = field
        self.before = before
        self.after = after
    }
}

public struct ChangePreview: Codable, Equatable, Sendable {
    public let itemID: String
    public let title: String
    public let action: String
    public let changes: [FieldChange]

    public init(itemID: String, title: String, action: String, changes: [FieldChange]) {
        self.itemID = itemID
        self.title = title
        self.action = action
        self.changes = changes
    }
}

public enum PlannerError: LocalizedError, Equatable {
    case invalidConfiguration(String)
    case invalidArgument(String)
    case permissionDenied(String)
    case notFound(String)
    case ambiguous(String, [String])
    case confirmationRequired(String)
    case storage(String)
    case eventKit(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message), .invalidArgument(let message),
             .permissionDenied(let message), .notFound(let message),
             .confirmationRequired(let message), .storage(let message),
             .eventKit(let message):
            return message
        case .ambiguous(let query, let matches):
            return "\"\(query)\" is ambiguous. Matches: \(matches.joined(separator: ", "))."
        }
    }
}

extension String {
    public var normalizedPlannerText: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
