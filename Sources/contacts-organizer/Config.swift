import Foundation

/// The groups the wishlist walk never asks about.
///
/// Kept in `~/.config/contacts-organizer/config.toml` as group identifiers,
/// with each group's name as a comment, so a group renamed in Contacts.app
/// stays ignored:
///
///     [wishlist]
///     ignore = [
///       "8F2C...:ABGroup",  # Work
///     ]
///
/// This is the tool's only state outside iCloud. The parser reads that one key
/// and nothing else, so the tool keeps its zero-dependency build.
struct IgnoreConfig: Equatable {
    var groupIDs: [String]

    static let empty = IgnoreConfig(groupIDs: [])

    static var defaultPath: String {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? NSHomeDirectory() + "/.config"
        return base + "/contacts-organizer/config.toml"
    }

    /// A missing file means nothing is ignored.
    static func load(path: String = defaultPath) throws -> IgnoreConfig {
        guard FileManager.default.fileExists(atPath: path) else { return .empty }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return try parse(text)
    }

    /// Reads `ignore` from the `[wishlist]` table. Other tables and keys are
    /// skipped; a malformed `ignore` value is an error, not a silent empty list.
    static func parse(_ text: String) throws -> IgnoreConfig {
        var table = ""
        var collecting = false
        var buffer = ""

        for (number, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)

            if collecting {
                buffer += " " + line
                if line.contains("]") { return try parseArray(buffer, line: number + 1) }
                continue
            }
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[") && !line.hasPrefix("[[") {
                table = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                continue
            }

            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            let isIgnore = (table == "wishlist" && key == "ignore") || (table.isEmpty && key == "wishlist.ignore")
            guard isIgnore else { continue }

            guard value.hasPrefix("[") else {
                throw AppError("config line \(number + 1): wishlist.ignore must be a list of strings")
            }
            if value.contains("]") { return try parseArray(value, line: number + 1) }
            collecting = true
            buffer = value
        }

        if collecting { throw AppError("config: wishlist.ignore list is never closed with ]") }
        return .empty
    }

    /// `[ "a", "b", ]` -> ["a", "b"]. Basic strings only, with \" and \\.
    private static func parseArray(_ text: String, line: Int) throws -> IgnoreConfig {
        guard let open = text.firstIndex(of: "["), let close = text.lastIndex(of: "]"), open < close else {
            throw AppError("config line \(line): wishlist.ignore must be a list of strings")
        }
        var ids: [String] = []
        var current: String?
        var escaped = false
        for character in text[text.index(after: open)..<close] {
            if var string = current {
                if escaped {
                    string.append(character); escaped = false; current = string
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    if !string.isEmpty, !ids.contains(string) { ids.append(string) }
                    current = nil
                } else {
                    string.append(character); current = string
                }
            } else if character == "\"" {
                current = ""
            } else if !(character == "," || character.isWhitespace) {
                throw AppError("config line \(line): wishlist.ignore holds \"\(character)\" outside a string")
            }
        }
        if current != nil { throw AppError("config line \(line): unterminated string in wishlist.ignore") }
        return IgnoreConfig(groupIDs: ids)
    }

    /// Drops a `#` comment that is not inside a string.
    private static func stripComment(_ line: String) -> String {
        var inString = false
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped { escaped = false; continue }
            if character == "\\" && inString { escaped = true; continue }
            if character == "\"" { inString.toggle() }
            if character == "#" && !inString { return String(line[..<index]) }
        }
        return line
    }

    /// The whole file, as the picker writes it. `names` labels each identifier.
    static func render(_ config: IgnoreConfig, names: [String: String]) -> String {
        var lines = [
            "# contacts-organizer settings.",
            "# Written by `contacts-organizer wishlist ignore`; edits by hand are fine.",
            "",
            "[wishlist]",
            "# Groups whose contacts the wishlist walk never asks about.",
            "# Identifiers, so a renamed group stays ignored; the comment is its name.",
        ]
        if config.groupIDs.isEmpty {
            lines.append("ignore = []")
        } else {
            lines.append("ignore = [")
            for id in config.groupIDs {
                let quoted = "\"" + id.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\","
                let name = names[id].map { $0.components(separatedBy: .newlines).joined(separator: " ") }
                lines.append("  " + quoted + (name.map { "  # \($0)" } ?? ""))
            }
            lines.append("]")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func save(_ config: IgnoreConfig, names: [String: String], path: String = defaultPath) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try render(config, names: names).write(toFile: path, atomically: true, encoding: .utf8)
    }
}
