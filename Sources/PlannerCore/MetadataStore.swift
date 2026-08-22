import CSQLite
import Foundation

public protocol PlannerMetadataStore: Sendable {
    func metadata(for tasks: [PlannerTask]) throws -> [String: TaskMetadata]
    func upsert(_ metadata: TaskMetadata) throws
    func logWork(_ session: WorkSession) throws
    func workTotals(for reminderIDs: [String]) throws -> [String: Int]
    func activeOverrides(on date: Date) throws -> [PriorityOverride]
    func saveOverride(_ override: PriorityOverride) throws
    func relations() throws -> [TaskRelation]
    func saveRelation(_ relation: TaskRelation) throws
    func removeMetadata(for reminderID: String) throws
}

public final class SQLiteMetadataStore: PlannerMetadataStore, @unchecked Sendable {
    private let connection: SQLiteConnection
    private let lock = NSLock()

    public init(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        connection = try SQLiteConnection(path: url.path)
        try migrate()
    }

    public func metadata(for tasks: [PlannerTask]) throws -> [String: TaskMetadata] {
        guard !tasks.isEmpty else { return [:] }
        return try synchronized {
            let statement = try connection.prepare(
                """
                SELECT reminder_id, external_identifier, estimated_minutes, category,
                       course_id, importance, notes, created_at, updated_at
                FROM task_metadata
                """
            )
            defer { sqlite3_finalize(statement) }

            let taskIDs = Set(tasks.map(\.id))
            let tasksByExternalID = Dictionary(
                tasks.compactMap { task in task.externalIdentifier.map { ($0, task) } },
                uniquingKeysWith: { first, _ in first }
            )
            var output: [String: TaskMetadata] = [:]

            while sqlite3_step(statement) == SQLITE_ROW {
                let stored = try decodeMetadata(statement)
                if taskIDs.contains(stored.reminderID) {
                    output[stored.reminderID] = stored
                } else if let externalID = stored.externalIdentifier,
                          let liveTask = tasksByExternalID[externalID] {
                    // EventKit identifiers can change after sync. Re-key only when the stable
                    // external identifier identifies one current reminder unambiguously.
                    let reconciled = try rekeyMetadata(stored, to: liveTask.id)
                    output[liveTask.id] = reconciled
                }
            }
            return output
        }
    }

    public func upsert(_ metadata: TaskMetadata) throws {
        try synchronized {
            let statement = try connection.prepare(
                """
                INSERT INTO task_metadata (
                    reminder_id, external_identifier, estimated_minutes, category,
                    course_id, importance, notes, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(reminder_id) DO UPDATE SET
                    external_identifier = excluded.external_identifier,
                    estimated_minutes = excluded.estimated_minutes,
                    category = excluded.category,
                    course_id = excluded.course_id,
                    importance = excluded.importance,
                    notes = excluded.notes,
                    updated_at = excluded.updated_at
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind(metadata, to: statement)
            try connection.expectDone(statement)
        }
    }

    public func logWork(_ session: WorkSession) throws {
        guard session.minutes > 0 else {
            throw PlannerError.invalidArgument("Work-session minutes must be positive.")
        }
        try synchronized {
            let statement = try connection.prepare(
                "INSERT INTO work_sessions (id, reminder_id, minutes, logged_at, note) VALUES (?, ?, ?, ?, ?)"
            )
            defer { sqlite3_finalize(statement) }
            SQLiteBinding.text(session.id, at: 1, in: statement)
            SQLiteBinding.text(session.reminderID, at: 2, in: statement)
            sqlite3_bind_int(statement, 3, Int32(session.minutes))
            sqlite3_bind_double(statement, 4, session.loggedAt.timeIntervalSince1970)
            SQLiteBinding.optionalText(session.note, at: 5, in: statement)
            try connection.expectDone(statement)
        }
    }

    public func workTotals(for reminderIDs: [String]) throws -> [String: Int] {
        guard !reminderIDs.isEmpty else { return [:] }
        return try synchronized {
            let statement = try connection.prepare(
                "SELECT reminder_id, SUM(minutes) FROM work_sessions GROUP BY reminder_id"
            )
            defer { sqlite3_finalize(statement) }
            let wanted = Set(reminderIDs)
            var totals: [String: Int] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                let reminderID = SQLiteBinding.columnText(statement, at: 0)
                if wanted.contains(reminderID) {
                    totals[reminderID] = Int(sqlite3_column_int(statement, 1))
                }
            }
            return totals
        }
    }

    public func activeOverrides(on date: Date) throws -> [PriorityOverride] {
        try synchronized {
            let statement = try connection.prepare(
                """
                SELECT id, target_type, target_id, priority, starts_on, expires_on, reason
                FROM priority_overrides
                WHERE starts_on <= ? AND expires_on >= ?
                """
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
            var output: [PriorityOverride] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let targetType = FocusTargetType(rawValue: SQLiteBinding.columnText(statement, at: 1)) else {
                    continue
                }
                output.append(PriorityOverride(
                    id: SQLiteBinding.columnText(statement, at: 0),
                    targetType: targetType,
                    targetID: SQLiteBinding.columnText(statement, at: 2),
                    priority: Int(sqlite3_column_int(statement, 3)),
                    startsOn: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    expiresOn: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                    reason: SQLiteBinding.optionalColumnText(statement, at: 6)
                ))
            }
            return output
        }
    }

    public func saveOverride(_ override: PriorityOverride) throws {
        guard (1...10).contains(override.priority) else {
            throw PlannerError.invalidArgument("Temporary priority must be between 1 and 10.")
        }
        guard override.startsOn <= override.expiresOn else {
            throw PlannerError.invalidArgument("Focus override must end on or after its start date.")
        }
        try synchronized {
            let statement = try connection.prepare(
                """
                INSERT OR REPLACE INTO priority_overrides
                    (id, target_type, target_id, priority, starts_on, expires_on, reason)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """
            )
            defer { sqlite3_finalize(statement) }
            SQLiteBinding.text(override.id, at: 1, in: statement)
            SQLiteBinding.text(override.targetType.rawValue, at: 2, in: statement)
            SQLiteBinding.text(override.targetID, at: 3, in: statement)
            sqlite3_bind_int(statement, 4, Int32(override.priority))
            sqlite3_bind_double(statement, 5, override.startsOn.timeIntervalSince1970)
            sqlite3_bind_double(statement, 6, override.expiresOn.timeIntervalSince1970)
            SQLiteBinding.optionalText(override.reason, at: 7, in: statement)
            try connection.expectDone(statement)
        }
    }

    public func relations() throws -> [TaskRelation] {
        try synchronized {
            let statement = try connection.prepare(
                "SELECT parent_reminder_id, child_reminder_id FROM task_relations"
            )
            defer { sqlite3_finalize(statement) }
            var output: [TaskRelation] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                output.append(TaskRelation(
                    parentReminderID: SQLiteBinding.columnText(statement, at: 0),
                    childReminderID: SQLiteBinding.columnText(statement, at: 1)
                ))
            }
            return output
        }
    }

    public func saveRelation(_ relation: TaskRelation) throws {
        guard relation.parentReminderID != relation.childReminderID else {
            throw PlannerError.invalidArgument("A task cannot be its own subtask.")
        }
        try synchronized {
            let statement = try connection.prepare(
                "INSERT OR IGNORE INTO task_relations (parent_reminder_id, child_reminder_id) VALUES (?, ?)"
            )
            defer { sqlite3_finalize(statement) }
            SQLiteBinding.text(relation.parentReminderID, at: 1, in: statement)
            SQLiteBinding.text(relation.childReminderID, at: 2, in: statement)
            try connection.expectDone(statement)
        }
    }

    public func removeMetadata(for reminderID: String) throws {
        try synchronized {
            try connection.transaction {
                for sql in [
                    "DELETE FROM work_sessions WHERE reminder_id = ?",
                    "DELETE FROM task_relations WHERE parent_reminder_id = ? OR child_reminder_id = ?",
                    "DELETE FROM task_metadata WHERE reminder_id = ?",
                ] {
                    let statement = try connection.prepare(sql)
                    defer { sqlite3_finalize(statement) }
                    SQLiteBinding.text(reminderID, at: 1, in: statement)
                    if sql.contains(" OR ") {
                        SQLiteBinding.text(reminderID, at: 2, in: statement)
                    }
                    try connection.expectDone(statement)
                }
            }
        }
    }

    private func migrate() throws {
        try synchronized {
            try connection.execute("PRAGMA foreign_keys = ON")
            try connection.execute("PRAGMA journal_mode = WAL")
            try connection.execute(
                """
                CREATE TABLE IF NOT EXISTS task_metadata (
                    reminder_id TEXT PRIMARY KEY,
                    external_identifier TEXT,
                    estimated_minutes INTEGER,
                    category TEXT NOT NULL,
                    course_id TEXT,
                    importance INTEGER NOT NULL DEFAULT 0,
                    notes TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_task_metadata_external_identifier
                    ON task_metadata(external_identifier);
                CREATE TABLE IF NOT EXISTS work_sessions (
                    id TEXT PRIMARY KEY,
                    reminder_id TEXT NOT NULL,
                    minutes INTEGER NOT NULL CHECK(minutes > 0),
                    logged_at REAL NOT NULL,
                    note TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_work_sessions_reminder_id
                    ON work_sessions(reminder_id);
                CREATE TABLE IF NOT EXISTS priority_overrides (
                    id TEXT PRIMARY KEY,
                    target_type TEXT NOT NULL,
                    target_id TEXT NOT NULL,
                    priority INTEGER NOT NULL,
                    starts_on REAL NOT NULL,
                    expires_on REAL NOT NULL,
                    reason TEXT
                );
                CREATE TABLE IF NOT EXISTS task_relations (
                    parent_reminder_id TEXT NOT NULL,
                    child_reminder_id TEXT NOT NULL,
                    PRIMARY KEY(parent_reminder_id, child_reminder_id)
                );
                PRAGMA user_version = 1;
                """
            )
        }
    }

    private func bind(_ metadata: TaskMetadata, to statement: OpaquePointer) throws {
        SQLiteBinding.text(metadata.reminderID, at: 1, in: statement)
        SQLiteBinding.optionalText(metadata.externalIdentifier, at: 2, in: statement)
        if let estimate = metadata.estimatedMinutes {
            guard estimate > 0 else {
                throw PlannerError.invalidArgument("Estimated minutes must be positive when provided.")
            }
            sqlite3_bind_int(statement, 3, Int32(estimate))
        } else {
            sqlite3_bind_null(statement, 3)
        }
        SQLiteBinding.text(metadata.category.rawValue, at: 4, in: statement)
        SQLiteBinding.optionalText(metadata.courseID, at: 5, in: statement)
        sqlite3_bind_int(statement, 6, Int32(metadata.importance))
        SQLiteBinding.optionalText(metadata.notes, at: 7, in: statement)
        sqlite3_bind_double(statement, 8, metadata.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 9, metadata.updatedAt.timeIntervalSince1970)
    }

    private func decodeMetadata(_ statement: OpaquePointer) throws -> TaskMetadata {
        let categoryValue = SQLiteBinding.columnText(statement, at: 3)
        guard let category = PlannerCategory(rawValue: categoryValue) else {
            throw PlannerError.storage("Unknown stored category: \(categoryValue)")
        }
        let estimate = sqlite3_column_type(statement, 2) == SQLITE_NULL
            ? nil
            : Int(sqlite3_column_int(statement, 2))
        return TaskMetadata(
            reminderID: SQLiteBinding.columnText(statement, at: 0),
            externalIdentifier: SQLiteBinding.optionalColumnText(statement, at: 1),
            estimatedMinutes: estimate,
            category: category,
            courseID: SQLiteBinding.optionalColumnText(statement, at: 4),
            importance: Int(sqlite3_column_int(statement, 5)),
            notes: SQLiteBinding.optionalColumnText(statement, at: 6),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
        )
    }

    private func rekeyMetadata(_ metadata: TaskMetadata, to newID: String) throws -> TaskMetadata {
        try connection.transaction {
            let tablesAndColumns = [
                ("work_sessions", "reminder_id"),
                ("task_relations", "parent_reminder_id"),
                ("task_relations", "child_reminder_id"),
            ]
            for (table, column) in tablesAndColumns {
                let statement = try connection.prepare("UPDATE \(table) SET \(column) = ? WHERE \(column) = ?")
                defer { sqlite3_finalize(statement) }
                SQLiteBinding.text(newID, at: 1, in: statement)
                SQLiteBinding.text(metadata.reminderID, at: 2, in: statement)
                try connection.expectDone(statement)
            }
            let statement = try connection.prepare("UPDATE task_metadata SET reminder_id = ? WHERE reminder_id = ?")
            defer { sqlite3_finalize(statement) }
            SQLiteBinding.text(newID, at: 1, in: statement)
            SQLiteBinding.text(metadata.reminderID, at: 2, in: statement)
            try connection.expectDone(statement)
        }
        return TaskMetadata(
            reminderID: newID,
            externalIdentifier: metadata.externalIdentifier,
            estimatedMinutes: metadata.estimatedMinutes,
            category: metadata.category,
            courseID: metadata.courseID,
            importance: metadata.importance,
            notes: metadata.notes,
            createdAt: metadata.createdAt,
            updatedAt: Date()
        )
    }

    private func synchronized<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private final class SQLiteConnection {
    private var database: OpaquePointer?

    init(path: String) throws {
        if sqlite3_open_v2(path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            if let database { sqlite3_close(database) }
            throw PlannerError.storage("Could not open metadata database: \(message)")
        }
        sqlite3_busy_timeout(database, 5_000)
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(database, sql, nil, nil, &errorPointer) != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(errorPointer)
            throw PlannerError.storage(message)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw PlannerError.storage(errorMessage)
        }
        return statement
    }

    func expectDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw PlannerError.storage(errorMessage)
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private var errorMessage: String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
    }
}

private enum SQLiteBinding {
    // sqlite3_bind_text needs SQLITE_TRANSIENT so SQLite copies Swift's temporary UTF-8 buffer.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func text(_ value: String, at index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    static func optionalText(_ value: String?, at index: Int32, in statement: OpaquePointer) {
        if let value {
            text(value, at: index, in: statement)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    static func columnText(_ statement: OpaquePointer, at index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    static func optionalColumnText(_ statement: OpaquePointer, at index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return columnText(statement, at: index)
    }
}
