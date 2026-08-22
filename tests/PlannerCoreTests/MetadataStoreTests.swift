import Foundation
import XCTest
@testable import PlannerCore

final class MetadataStoreTests: XCTestCase {
    func testPersistsMetadataWorkAndRelations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteMetadataStore(url: directory.appendingPathComponent("test.sqlite"))
        let task = PlannerTask(id: "task", externalIdentifier: "external", title: "Study", listName: "Other")
        try store.upsert(TaskMetadata(reminderID: task.id, externalIdentifier: task.externalIdentifier, estimatedMinutes: 120, category: .academics))
        try store.logWork(WorkSession(reminderID: task.id, minutes: 45))
        try store.saveRelation(TaskRelation(parentReminderID: "parent", childReminderID: task.id))

        XCTAssertEqual(try store.metadata(for: [task])[task.id]?.estimatedMinutes, 120)
        XCTAssertEqual(try store.workTotals(for: [task.id])[task.id], 45)
        XCTAssertEqual(try store.relations(), [TaskRelation(parentReminderID: "parent", childReminderID: task.id)])
    }

    func testFocusOverrideExpires() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMetadataStore(url: directory.appendingPathComponent("test.sqlite"))
        let now = Date()
        try store.saveOverride(PriorityOverride(
            targetType: .category,
            targetID: "recruiting",
            priority: 7,
            startsOn: now.addingTimeInterval(-60),
            expiresOn: now.addingTimeInterval(60)
        ))
        XCTAssertEqual(try store.activeOverrides(on: now).count, 1)
        XCTAssertTrue(try store.activeOverrides(on: now.addingTimeInterval(120)).isEmpty)
    }
}
