import Foundation
import XCTest
@testable import PlannerCore

final class ConfigurationTests: XCTestCase {
    func testParsesPreferencesAndCourses() throws {
        let preferences = try ConfigurationLoader.parsePreferences(
            """
            priority_defaults:
              academics: 5
              health: 5
            deadline:
              default_due_time: "22:30"
              timezone: "America/Denver"
            planning:
              upcoming_days: 8
              weekly_lookahead_days: 16
              daily_focus_limit: 4
            """
        )
        XCTAssertEqual(preferences.priorityDefaults[.academics], 5)
        XCTAssertEqual(preferences.defaultDueTime.hour, 22)
        XCTAssertEqual(preferences.upcomingDays, 8)

        let courses = try ConfigurationLoader.parseCourses(
            """
            | ID | Course | Aliases |
            |---|---|---|
            | cs135 | CS 135 | cs, foundations |
            """
        )
        XCTAssertEqual(courses.count, 1)
        XCTAssertEqual(courses[0].calendarName, "Class • CS 135")
    }

    func testRejectsAmbiguousAliases() {
        XCTAssertThrowsError(
            try ConfigurationLoader.parseCourses(
                """
                | ID | Course | Aliases |
                |---|---|---|
                | math135 | MATH 135 | math |
                | math137 | MATH 137 | math |
                """
            )
        )
    }
}
