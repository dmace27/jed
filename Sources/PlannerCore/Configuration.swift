import Foundation

public enum ConfigurationLoader {
    public static func load(from directory: URL) throws -> PlannerConfiguration {
        let preferencesURL = directory.appendingPathComponent("preferences.yaml")
        let coursesURL = directory.appendingPathComponent("courses.md")

        guard FileManager.default.fileExists(atPath: preferencesURL.path) else {
            throw PlannerError.invalidConfiguration("Missing preferences file at \(preferencesURL.path).")
        }
        guard FileManager.default.fileExists(atPath: coursesURL.path) else {
            throw PlannerError.invalidConfiguration("Missing courses file at \(coursesURL.path).")
        }

        let preferencesText = try String(contentsOf: preferencesURL, encoding: .utf8)
        let coursesText = try String(contentsOf: coursesURL, encoding: .utf8)
        return PlannerConfiguration(
            preferences: try parsePreferences(preferencesText),
            courses: try parseCourses(coursesText)
        )
    }

    /// Parses the intentionally narrow preferences schema without pulling a third-party YAML dependency.
    public static func parsePreferences(_ text: String) throws -> PlannerPreferences {
        var preferences = PlannerPreferences()
        var section: String?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let withoutComment = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            if withoutComment.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            let indentation = withoutComment.prefix { $0 == " " }.count
            let trimmed = withoutComment.trimmingCharacters(in: .whitespaces)
            if indentation == 0, trimmed.hasSuffix(":") {
                section = String(trimmed.dropLast())
                continue
            }

            let pair = trimmed.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard pair.count == 2 else {
                throw PlannerError.invalidConfiguration("Invalid preferences line: \(trimmed)")
            }
            let key = pair[0]
            let value = unquote(pair[1])

            switch section {
            case "priority_defaults":
                guard let category = PlannerCategory(rawValue: key), let priority = Int(value) else {
                    throw PlannerError.invalidConfiguration("Invalid priority setting: \(trimmed)")
                }
                preferences.priorityDefaults[category] = priority
            case "deadline":
                if key == "default_due_time" {
                    let components = value.split(separator: ":")
                    guard components.count == 2,
                          let hour = Int(components[0]),
                          let minute = Int(components[1]),
                          (0...23).contains(hour),
                          (0...59).contains(minute) else {
                        throw PlannerError.invalidConfiguration("default_due_time must be HH:mm.")
                    }
                    preferences.defaultDueTime = DateComponents(hour: hour, minute: minute)
                } else if key == "timezone" {
                    guard TimeZone(identifier: value) != nil else {
                        throw PlannerError.invalidConfiguration("Unknown timezone: \(value)")
                    }
                    preferences.timeZoneIdentifier = value
                }
            case "planning":
                guard let number = Int(value), number > 0 else {
                    throw PlannerError.invalidConfiguration("Planning values must be positive integers.")
                }
                switch key {
                case "upcoming_days": preferences.upcomingDays = number
                case "weekly_lookahead_days": preferences.weeklyLookaheadDays = number
                case "daily_focus_limit": preferences.dailyFocusLimit = number
                default: break
                }
            default:
                throw PlannerError.invalidConfiguration("Unknown preferences section for line: \(trimmed)")
            }
        }

        return preferences
    }

    public static func parseCourses(_ text: String) throws -> [CourseDefinition] {
        var courses: [CourseDefinition] = []
        var seenIDs = Set<String>()
        var seenAliases = Set<String>()

        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("|"), line.hasSuffix("|") else { continue }
            let columns = line.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard columns.count == 3 else { continue }
            if columns[0].lowercased() == "id" || columns.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" } }) {
                continue
            }

            let id = columns[0].lowercased()
            let name = columns[1]
            let aliases = columns[2].split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }

            guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
                throw PlannerError.invalidConfiguration("Course ID \"\(id)\" must contain only letters, numbers, or hyphens.")
            }
            guard !name.isEmpty else {
                throw PlannerError.invalidConfiguration("Course \(id) is missing a display name.")
            }
            guard seenIDs.insert(id).inserted else {
                throw PlannerError.invalidConfiguration("Duplicate course ID: \(id)")
            }

            // Repeating a course's own ID in its aliases is harmless and convenient.
            // Only collisions between different courses are ambiguous.
            let allNames = Set(([id, name] + aliases).map(\.normalizedPlannerText).filter { !$0.isEmpty })
            for alias in allNames {
                guard seenAliases.insert(alias).inserted else {
                    throw PlannerError.invalidConfiguration("Duplicate or ambiguous course alias: \(alias)")
                }
            }
            courses.append(CourseDefinition(id: id, name: name, aliases: aliases))
        }

        return courses
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}

public enum PlannerPaths {
    public static func applicationSupportDirectory(fileManager: FileManager = .default) throws -> URL {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw PlannerError.invalidConfiguration("Could not locate the user Application Support directory.")
        }
        return base.appendingPathComponent("Planner", isDirectory: true)
    }

    public static func defaultConfigurationDirectory(fileManager: FileManager = .default) throws -> URL {
        if let override = ProcessInfo.processInfo.environment["PLANNER_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return try applicationSupportDirectory(fileManager: fileManager).appendingPathComponent("config", isDirectory: true)
    }

    public static func defaultDatabaseURL(fileManager: FileManager = .default) throws -> URL {
        if let override = ProcessInfo.processInfo.environment["PLANNER_DB_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return try applicationSupportDirectory(fileManager: fileManager).appendingPathComponent("planner.sqlite")
    }
}
