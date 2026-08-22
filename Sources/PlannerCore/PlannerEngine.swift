import Foundation

public struct PlannerEngine: Sendable {
    public init() {}

    public func rankTasks(
        _ tasks: [PlannerTask],
        metadata: [String: TaskMetadata],
        workMinutes: [String: Int],
        relations: [TaskRelation],
        overrides: [PriorityOverride],
        configuration: PlannerConfiguration,
        now: Date
    ) -> [RankedTask] {
        let calendar = configuredCalendar(configuration)
        let startOfToday = calendar.startOfDay(for: now)
        let childrenByParent = Dictionary(grouping: relations, by: \.parentReminderID)
        let taskByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })

        return tasks
            .filter { !$0.isCompleted }
            .filter { relationChildID in !relations.contains { $0.childReminderID == relationChildID.id } }
            .map { task in
                let itemMetadata = metadata[task.id]
                let logged = workMinutes[task.id, default: 0]
                let remaining = itemMetadata?.estimatedMinutes.map { max(0, $0 - logged) }
                let activeOverride = bestOverride(
                    for: task,
                    metadata: itemMetadata,
                    overrides: overrides,
                    on: now
                )
                let category = itemMetadata?.category ?? inferCategory(for: task, courses: configuration.courses)
                let basePriority = activeOverride?.priority
                    ?? itemMetadata?.importance.nonZero
                    ?? configuration.preferences.priorityDefaults[category, default: 1]
                let urgency = urgencyScore(task.dueDate, startOfToday: startOfToday, calendar: calendar)
                let applePriorityBonus = applePriorityScore(task.applePriority)
                let workloadBonus = min(150, (remaining ?? 0) / 5)
                var reasons = urgency.reasons
                if let activeOverride {
                    reasons.append(activeOverride.reason ?? "temporary focus override")
                }
                if let remaining {
                    reasons.append("about \(formatMinutes(remaining)) remaining")
                }
                let childTasks = childrenByParent[task.id, default: []].compactMap { taskByID[$0.childReminderID] }

                return RankedTask(
                    task: task,
                    metadata: itemMetadata,
                    minutesLogged: logged,
                    remainingMinutes: remaining,
                    score: urgency.score + basePriority * 100 + applePriorityBonus + workloadBonus,
                    reasons: reasons,
                    children: childTasks
                )
            }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                switch ($0.task.dueDate, $1.task.dueDate) {
                case let (left?, right?) where left != right: return left < right
                case (_?, nil): return true
                case (nil, _?): return false
                default: return $0.task.title.localizedCaseInsensitiveCompare($1.task.title) == .orderedAscending
                }
            }
    }

    public func makeDailyBrief(
        date: Date,
        events: [PlannerEvent],
        rankedTasks: [RankedTask],
        configuration: PlannerConfiguration
    ) -> DailyBrief {
        let calendar = configuredCalendar(configuration)
        let today = calendar.startOfDay(for: date)
        let upcomingEnd = calendar.date(byAdding: .day, value: configuration.preferences.upcomingDays, to: today)!
        let focusCount = min(configuration.preferences.dailyFocusLimit, rankedTasks.count)
        let focus = Array(rankedTasks.prefix(focusCount))
        let remainder = Array(rankedTasks.dropFirst(focusCount))
        let ifTime = Array(remainder.filter { $0.task.dueDate == nil || $0.task.dueDate! < upcomingEnd }.prefix(3))
        let selectedIDs = Set((focus + ifTime).map { $0.task.id })
        let upcoming = remainder.filter { ranked in
            guard !selectedIDs.contains(ranked.task.id), let due = ranked.task.dueDate else { return false }
            return due < upcomingEnd
        }

        var warnings: [String] = []
        let overdueCount = rankedTasks.filter { task in
            guard let due = task.task.dueDate else { return false }
            return due < today
        }.count
        if overdueCount > 0 {
            warnings.append("\(overdueCount) open task\(overdueCount == 1 ? " is" : "s are") overdue.")
        }

        return DailyBrief(
            date: today,
            events: events.sorted { $0.startDate < $1.startDate },
            focus: focus,
            ifTime: ifTime,
            upcoming: upcoming,
            warnings: warnings
        )
    }

    public func makeWeeklyBrief(
        date: Date,
        events: [PlannerEvent],
        rankedTasks: [RankedTask],
        configuration: PlannerConfiguration
    ) -> WeeklyBrief {
        let calendar = configuredCalendar(configuration)
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: configuration.preferences.weeklyLookaheadDays, to: start)!
        let tasks = rankedTasks.filter { task in
            guard let due = task.task.dueDate else { return false }
            return due < end
        }
        let knownWork = tasks.compactMap(\.remainingMinutes).reduce(0, +)
        let warnings = knownWork >= 10 * 60
            ? ["About \(formatMinutes(knownWork)) of estimated work is due in this window."]
            : []
        return WeeklyBrief(
            startsOn: start,
            endsOn: end,
            tasks: tasks,
            events: events.sorted { $0.startDate < $1.startDate },
            warnings: warnings
        )
    }

    private func urgencyScore(_ dueDate: Date?, startOfToday: Date, calendar: Calendar) -> (score: Int, reasons: [String]) {
        guard let dueDate else { return (0, ["no deadline"] ) }
        let dueDay = calendar.startOfDay(for: dueDate)
        let days = calendar.dateComponents([.day], from: startOfToday, to: dueDay).day ?? 0
        if days < 0 { return (10_000 + abs(days) * 100, ["overdue by \(abs(days)) day\(abs(days) == 1 ? "" : "s")"]) }
        if days == 0 { return (5_000, ["due today"]) }
        if days <= 7 { return (3_000 - days * 250, ["due in \(days) day\(days == 1 ? "" : "s")"]) }
        return (max(0, 800 - days * 20), ["due in \(days) days"])
    }

    private func bestOverride(
        for task: PlannerTask,
        metadata: TaskMetadata?,
        overrides: [PriorityOverride],
        on date: Date
    ) -> PriorityOverride? {
        overrides
            .filter { $0.startsOn <= date && date <= $0.expiresOn }
            .filter { override in
                switch override.targetType {
                case .task: return override.targetID == task.id
                case .course: return override.targetID == metadata?.courseID
                case .category: return override.targetID == metadata?.category.rawValue
                }
            }
            .max { $0.priority < $1.priority }
    }

    private func inferCategory(for task: PlannerTask, courses: [CourseDefinition]) -> PlannerCategory {
        if courses.contains(where: { $0.reminderListName.normalizedPlannerText == task.listName.normalizedPlannerText }) {
            return .academics
        }
        switch task.listName.normalizedPlannerText {
        case "recruiting": return .recruiting
        case "health": return .health
        default: return .other
        }
    }

    private func applePriorityScore(_ priority: Int) -> Int {
        switch priority {
        case 1...4: return 80
        case 5: return 40
        case 6...9: return 10
        default: return 0
        }
    }

    private func configuredCalendar(_ configuration: PlannerConfiguration) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: configuration.preferences.timeZoneIdentifier) ?? .current
        return calendar
    }
}

public func formatMinutes(_ minutes: Int) -> String {
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    let remainder = minutes % 60
    return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
