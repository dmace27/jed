import Foundation
import XCTest
@testable import PlannerCore

final class PlannerServiceTests: XCTestCase {
    func testInMemoryStoreSupportsSafeServiceFlow() async throws {
        let task = PlannerTask(id: "one", title: "Apply to company", listName: "Recruiting")
        let store = InMemoryCalendarStore(tasks: [task])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = try SQLiteMetadataStore(url: directory.appendingPathComponent("test.sqlite"))
        let service = PlannerService(
            calendarStore: store,
            metadataStore: metadata,
            configuration: PlannerConfiguration(preferences: PlannerPreferences(), courses: [])
        )

        let resolved = try await service.resolveTask("apply")
        XCTAssertEqual(resolved.id, task.id)
        let session = try await service.logWork(taskQuery: "apply", minutes: 30, note: nil)
        XCTAssertEqual(session.minutes, 30)
    }
}
