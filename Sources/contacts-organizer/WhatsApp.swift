import Foundation
import SQLite3

/// Phone numbers as WhatsApp keys them: country code plus number, digits only.
enum PhoneNumber {

    /// The country assumed for a number saved without one.
    static let defaultCountryCode = "91"

    /// "+91 98450 12345", "098450-12345" and "0091 9845012345" all become
    /// "919845012345". Returns nil when nothing dialable is left.
    static func normalize(_ raw: String, defaultCountryCode: String = defaultCountryCode) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPlus = trimmed.hasPrefix("+")
        var digits = trimmed.filter(\.isASCIIDigit)
        guard !digits.isEmpty else { return nil }

        if hasPlus || digits.hasPrefix("00") {
            // "+" and "00" both mean the country code follows; a code never
            // starts with 0, so leading zeros left over are noise.
            let international = digits.drop { $0 == "0" }
            return international.isEmpty ? nil : String(international)
        }

        // A leading 0 is the domestic trunk prefix, not part of the number.
        while digits.hasPrefix("0") { digits.removeFirst() }
        guard !digits.isEmpty else { return nil }

        // A bare national number gets the default country. A longer one that
        // already starts with that country code was saved without its "+".
        if digits.count == 10 { return defaultCountryCode + digits }
        return digits
    }

    /// The user part of a phone JID: "919845012345:12@s.whatsapp.net" ->
    /// "919845012345". The ":12" is a device suffix.
    static func user(ofJID jid: String) -> String {
        let user = jid.split(separator: "@", maxSplits: 1).first.map(String.init) ?? jid
        return user.split(separator: ":", maxSplits: 1).first.map(String.init) ?? user
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

/// What wacli knows about one phone number.
struct WhatsAppActivity: Equatable {
    var lastChat: Date?
    /// The name the person set for themselves on WhatsApp.
    var whatsAppName: String?
    /// A message I sent them inside the Diwali window.
    var wishedLastDiwali = false
}

/// The days around last Diwali in which a message from me counts as a wish.
struct DiwaliWindow {
    let start: Date
    let end: Date

    /// Diwali 2025 fell on 20 October; three days either side.
    static let lastYear: DiwaliWindow = around(year: 2025, month: 10, day: 20, days: 3)

    static func around(year: Int, month: Int, day: Int, days: Int) -> DiwaliWindow {
        let calendar = Calendar.current
        let centre = calendar.date(from: DateComponents(year: year, month: month, day: day))!
        return DiwaliWindow(
            start: calendar.date(byAdding: .day, value: -days, to: centre)!,
            end: calendar.date(byAdding: .day, value: days + 1, to: centre)!)
    }

    func contains(_ date: Date) -> Bool { date >= start && date < end }
}

/// A read-only view of wacli's local store (`~/.wacli`).
///
/// wacli keeps its message index in `wacli.db` and whatsmeow's session,
/// including the LID-to-phone map, in `session.db`. Both schemas belong to
/// wacli, so every failure here is non-fatal: the caller falls back to the
/// triage order and says why.
struct WhatsAppStore {
    /// Phone number (digits, with country code) -> activity.
    let byPhone: [String: WhatsAppActivity]
    /// Problems worth one line of warning, e.g. a fallback open mode.
    let warnings: [String]

    func activity(for phones: [String]) -> WhatsAppActivity? {
        var merged: WhatsAppActivity?
        for phone in phones {
            guard let key = PhoneNumber.normalize(phone), let found = byPhone[key] else { continue }
            var next = merged ?? WhatsAppActivity()
            if let date = found.lastChat, date > (next.lastChat ?? .distantPast) { next.lastChat = date }
            if next.whatsAppName == nil { next.whatsAppName = found.whatsAppName }
            next.wishedLastDiwali = next.wishedLastDiwali || found.wishedLastDiwali
            merged = next
        }
        return merged
    }

    /// wacli's own default, honouring its `WACLI_STORE_DIR` override.
    static var defaultDirectory: String {
        if let override = ProcessInfo.processInfo.environment["WACLI_STORE_DIR"], !override.isEmpty {
            return override
        }
        return NSHomeDirectory() + "/.wacli"
    }

    enum LoadError: Error, Equatable {
        case missing(String)
        case unreadable(String)

        var message: String {
            switch self {
            case .missing(let path): return "no wacli store at \(path)"
            case .unreadable(let detail): return "wacli store unreadable: \(detail)"
            }
        }
    }

    static func load(directory: String = defaultDirectory,
                     window: DiwaliWindow = .lastYear) -> Result<WhatsAppStore, LoadError> {
        let messagesPath = directory + "/wacli.db"
        guard FileManager.default.fileExists(atPath: messagesPath) else {
            return .failure(.missing(messagesPath))
        }

        var warnings: [String] = []
        guard let messages = SQLiteReader.open(messagesPath, warnings: &warnings) else {
            return .failure(.unreadable("could not open \(messagesPath)"))
        }
        defer { messages.close() }

        // LID -> phone. A missing session store only costs the @lid chats.
        var lidToPhone: [String: String] = [:]
        let sessionPath = directory + "/session.db"
        if let session = SQLiteReader.open(sessionPath, warnings: &warnings) {
            for row in session.rows("SELECT lid, pn FROM whatsmeow_lid_map") {
                if let lid = row[0], let pn = row[1], !lid.isEmpty, !pn.isEmpty {
                    lidToPhone[PhoneNumber.user(ofJID: lid)] = PhoneNumber.user(ofJID: pn)
                }
            }
            session.close()
        } else {
            warnings.append("no LID map: \(sessionPath) unreadable, @lid chats are not matched")
        }

        func phone(ofChat jid: String) -> String? {
            if jid.hasSuffix("@s.whatsapp.net") { return PhoneNumber.user(ofJID: jid) }
            if jid.hasSuffix("@lid") { return lidToPhone[PhoneNumber.user(ofJID: jid)] }
            return nil          // groups, newsletters, status
        }

        var byPhone: [String: WhatsAppActivity] = [:]

        // Last chat: the chat row's own timestamp, or the newest stored message.
        let lastChatSQL = """
            SELECT jid, MAX(COALESCE(last_message_ts, 0), COALESCE(
                (SELECT MAX(ts) FROM messages WHERE messages.chat_jid = chats.jid), 0))
            FROM chats
            """
        for row in messages.rows(lastChatSQL) {
            guard let jid = row[0], let key = phone(ofChat: jid),
                  let raw = row[1], let seconds = Double(raw), seconds > 0 else { continue }
            let date = Date(timeIntervalSince1970: seconds)
            if date > (byPhone[key]?.lastChat ?? .distantPast) { byPhone[key, default: .init()].lastChat = date }
        }

        let wishSQL = """
            SELECT DISTINCT chat_jid FROM messages
            WHERE from_me = 1 AND ts >= \(Int(window.start.timeIntervalSince1970))
              AND ts < \(Int(window.end.timeIntervalSince1970))
            """
        for row in messages.rows(wishSQL) {
            guard let jid = row[0], let key = phone(ofChat: jid) else { continue }
            byPhone[key, default: .init()].wishedLastDiwali = true
        }

        let namesSQL = """
            SELECT jid, phone, COALESCE(NULLIF(push_name, ''), NULLIF(business_name, ''))
            FROM contacts
            """
        for row in messages.rows(namesSQL) {
            guard let name = row[2] else { continue }
            let key = row[1].flatMap { $0.isEmpty ? nil : PhoneNumber.user(ofJID: $0) }
                ?? row[0].flatMap(phone(ofChat:))
            guard let key else { continue }
            if byPhone[key]?.whatsAppName == nil { byPhone[key, default: .init()].whatsAppName = name }
        }

        return .success(WhatsAppStore(byPhone: byPhone, warnings: warnings))
    }
}

/// Minimal read-only sqlite access: every column comes back as text.
final class SQLiteReader {
    private var db: OpaquePointer?

    private init(db: OpaquePointer?) { self.db = db }

    /// Opens read-only and still sees the -wal file. Only when that fails
    /// (sqlite must create the -shm file to read a WAL store) does it fall back
    /// to immutable=1, which skips the WAL, and records that it did.
    static func open(_ path: String, warnings: inout [String]) -> SQLiteReader? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        if let reader = attempt("file:\(path)?mode=ro") { return reader }
        if let reader = attempt("file:\(path)?mode=ro&immutable=1") {
            warnings.append("\((path as NSString).lastPathComponent) opened immutable: rows still in its -wal file are not seen")
            return reader
        }
        return nil
    }

    private static func attempt(_ uri: String) -> SQLiteReader? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        // Opening is lazy; a read proves the file is really usable.
        let reader = SQLiteReader(db: db)
        guard let probe = reader.prepare("SELECT count(*) FROM sqlite_master") else {
            reader.close()
            return nil
        }
        sqlite3_finalize(probe)
        return reader
    }

    /// A statement that has proven it can run: its first step succeeded. It
    /// is reset, so the caller steps it from the first row.
    private func prepare(_ sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW || code == SQLITE_DONE else {
            sqlite3_finalize(statement)
            return nil
        }
        sqlite3_reset(statement)
        return statement
    }

    /// All rows of a query, or none if the query does not fit the schema.
    func rows(_ sql: String) -> [[String?]] {
        guard let statement = prepare(sql) else { return [] }
        defer { sqlite3_finalize(statement) }
        let columns = sqlite3_column_count(statement)
        var result: [[String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((0..<columns).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            })
        }
        return result
    }

    func close() {
        sqlite3_close(db)
        db = nil
    }
}
