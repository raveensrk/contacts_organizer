import Foundation
import SQLite3

/// Reads per-contact modification dates straight out of the AddressBook stores.
///
/// `CNContact` exposes no public modification date, so most-recently-modified
/// ordering has to come from the Core Data files behind Contacts.app. That
/// schema is undocumented and can change with an OS release, so every failure
/// here is non-fatal: callers fall back to alphabetical ordering.
enum ModificationDates {

    /// Contact identifier -> last modification date. Empty if unreadable.
    static func load() -> [String: Date] {
        var byID: [String: Date] = [:]
        for path in storePaths() {
            for (id, date) in read(path: path) {
                // A contact can appear in more than one store; keep the newest.
                if let existing = byID[id], existing >= date { continue }
                byID[id] = date
            }
        }
        return byID
    }

    private static func storePaths() -> [String] {
        let root = NSHomeDirectory() + "/Library/Application Support/AddressBook"
        var paths = ["\(root)/AddressBook-v22.abcddb"]
        let sources = "\(root)/Sources"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: sources) {
            for entry in entries.sorted() {
                paths.append("\(sources)/\(entry)/AddressBook-v22.abcddb")
            }
        }
        return paths.filter { FileManager.default.fileExists(atPath: $0) }
    }

    private static func read(path: String) -> [String: Date] {
        // immutable=1 promises sqlite we will not write and no one else is mid-write,
        // which lets it open the file without touching the -wal/-shm sidecars.
        let uri = "file:\(path)?mode=ro&immutable=1"
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return [:]
        }
        defer { sqlite3_close(db) }

        // ZUNIQUEID is "<UUID>:ABPerson"; the UUID half is CNContact.identifier.
        let sql = """
            SELECT ZUNIQUEID, ZMODIFICATIONDATE FROM ZABCDRECORD
            WHERE ZUNIQUEID LIKE '%:ABPerson' AND ZMODIFICATIONDATE IS NOT NULL
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }

        var result: [String: Date] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            let uniqueID = String(cString: raw)
            // Core Data timestamps are seconds since 2001-01-01 UTC.
            let date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1))

            // CNContact.identifier has been observed both as the bare UUID and
            // as the full "<UUID>:ABPerson" unique id, and it differs by macOS
            // release. Index both so the join works either way.
            result[uniqueID] = date
            if let separator = uniqueID.firstIndex(of: ":") {
                let bare = String(uniqueID[uniqueID.startIndex..<separator])
                if !bare.isEmpty { result[bare] = date }
            }
        }
        return result
    }
}
