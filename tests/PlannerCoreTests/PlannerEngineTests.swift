import Foundation
import XCTest
@testable import PlannerCore

final class PlannerEngineTests: XCTestCase {
    func testOverdueTaskRanksAheadOfUndatedPriorityTask() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let overdue = PlannerTask(
            id: "overdue",
            title: "Submit assignment",
            listName: "CS 135",
            dueDate: now.addingTimeInterval(-86_400)
        )
        let undated = PlannerTask(id: "undated", title: "Polish resume", listName: "Recruiting")
        let metadata = [
            "undated": TaskMetadata(reminderID: "undated", category: .recruiting, importance: 10),
        ]
        let configuration = PlannerConfiguration(preferences: PlannerPreferences(), courses: [])

        let ranked = PlannerEngine().rankTasks(
            [undated, overdue],
            metadata: metadata,
            workMinutes: [:],
            relations: [],
            overrides: [],
            configuration: configuration,
            now: now
        )

        XCTAssertEqual(ranked.first?.task.id, "overdue")
    }

    func testRemainingWorkIsAdvisoryAndFlooredAtZero() {
        let task = PlannerTask(id: "task", title: "Practice", listName: "Other")
        let metadata = [
            "task": TaskMetadata(reminderID: "task", estimatedMinutes: 60, category: .other),
        ]
        let ranked = PlannerEngine().rankTasks(
            [task],
            metadata: metadata,
            workMinutes: ["task": 90],
            relations: [],
            overrides: [],
            configuration: PlannerConfiguration(preferences: PlannerPreferences(), courses: []),
            now: Date()
        )
        XCTAssertEqual(ranked[0].remainingMinutes, 0)
    }

    func testChildrenAreNestedAndNotDuplicatedAtTopLevel() {
        let parent = PlannerTask(id: "parent", title: "Assignment", listName: "CS 135")
        let child = PlannerTask(id: "child", title: "Write tests", listName: "CS 135")
        let ranked = PlannerEngine().rankTasks(
            [parent, child],
            metadata: [:],
            workMinutes: [:],
            relations: [TaskRelation(parentReminderID: "parent", childReminderID: "child")],
            overrides: [],
            configuration: PlannerConfiguration(preferences: PlannerPreferences(), courses: []),
            now: Date()
        )
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked[0].children, [child])
    }
}
