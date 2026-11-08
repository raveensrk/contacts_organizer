import Foundation
import SQLite3
import XCTest
@testable import contacts_organizer

/// Reads a throwaway wacli store laid out like the real one: messages and
/// names in wacli.db, the LID-to-phone map in session.db.
final class WhatsAppStoreTests: XCTestCase {

    private var directory: URL!
    private let window = DiwaliWindow.around(year: 2025, month: 10, day: 20, days: 3)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("contacts-organizer-wacli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func seconds(_ year: Int, _ month: Int, _ day: Int) -> Int {
        Int(Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
            .timeIntervalSince1970)
    }

    private func makeStore(walOnly: [String] = []) throws {
        try execute(path: "session.db", [
            "CREATE TABLE whatsmeow_lid_map (lid TEXT PRIMARY KEY, pn TEXT)",
            "INSERT INTO whatsmeow_lid_map VALUES ('555000111', '919800000002')",
        ])
        try execute(path: "wacli.db", [
            "PRAGMA journal_mode=WAL",
            "CREATE TABLE chats (jid TEXT PRIMARY KEY, kind TEXT, name TEXT, last_message_ts INTEGER)",
            "CREATE TABLE messages (rowid INTEGER PRIMARY KEY, chat_jid TEXT, ts INTEGER, from_me INTEGER, text TEXT)",
            "CREATE TABLE contacts (jid TEXT PRIMARY KEY, phone TEXT, push_name TEXT, full_name TEXT, business_name TEXT)",
            // A phone chat with a message from me inside the Diwali window.
            "INSERT INTO chats VALUES ('919800000001@s.whatsapp.net', 'dm', 'A', \(seconds(2026, 11, 1)))",
            "INSERT INTO messages (chat_jid, ts, from_me) VALUES ('919800000001@s.whatsapp.net', \(seconds(2025, 10, 21)), 1)",
            // A LID chat whose newest message is newer than the chat row says.
            "INSERT INTO chats VALUES ('555000111@lid', 'unknown', 'B', \(seconds(2026, 1, 1)))",
            "INSERT INTO messages (chat_jid, ts, from_me) VALUES ('555000111@lid', \(seconds(2026, 6, 1)), 0)",
            // Received during Diwali: not a wish from me.
            "INSERT INTO messages (chat_jid, ts, from_me) VALUES ('555000111@lid', \(seconds(2025, 10, 20)), 0)",
            // A group: never a person's last chat.
            "INSERT INTO chats VALUES ('120363000000@g.us', 'group', 'G', \(seconds(2026, 11, 5)))",
            "INSERT INTO contacts VALUES ('919800000001@s.whatsapp.net', '919800000001', 'Asha WA', 'Asha', '')",
            "INSERT INTO contacts VALUES ('919800000003@s.whatsapp.net', '919800000003', '', '', 'Shop Ltd')",
            "PRAGMA wal_checkpoint(TRUNCATE)",
        ], keepWAL: walOnly)
    }

    /// Runs statements, then `keepWAL` ones that stay in the -wal file because
    /// the connection is left without a checkpoint.
    private func execute(path: String, _ statements: [String], keepWAL: [String] = []) throws {
        var db: OpaquePointer?
        let full = directory.appendingPathComponent(path).path
        guard sqlite3_open(full, &db) == SQLITE_OK else { throw AppError("open \(full)") }
        for statement in statements + keepWAL {
            guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
                throw AppError("\(statement): \(String(cString: sqlite3_errmsg(db)))")
            }
        }
        if keepWAL.isEmpty {
            sqlite3_close(db)
        } else {
            // Leave it open: closing the last connection checkpoints the WAL.
            openConnections.append(db)
        }
    }

    private var openConnections: [OpaquePointer?] = []

    private func load() throws -> WhatsAppStore {
        switch WhatsAppStore.load(directory: directory.path, window: window) {
        case .success(let store): return store
        case .failure(let error): throw AppError(error.message)
        }
    }

    func testPhoneChatHasLastChatNameAndDiwaliWish() throws {
        try makeStore()
        let activity = try XCTUnwrap(try load().activity(for: ["+91 98000 00001"]))
        XCTAssertEqual(activity.lastChat, Date(timeIntervalSince1970: Double(seconds(2026, 11, 1))))
        XCTAssertEqual(activity.whatsAppName, "Asha WA")
        XCTAssertTrue(activity.wishedLastDiwali)
    }

    func testLIDChatIsMatchedThroughTheMapAndUsesTheNewestMessage() throws {
        try makeStore()
        let activity = try XCTUnwrap(try load().activity(for: ["98000 00002"]))
        XCTAssertEqual(activity.lastChat, Date(timeIntervalSince1970: Double(seconds(2026, 6, 1))))
        XCTAssertFalse(activity.wishedLastDiwali, "a message received in the window is not my wish")
    }

    func testBusinessNameStandsInForAMissingPushName() throws {
        try makeStore()
        let activity = try XCTUnwrap(try load().activity(for: ["919800000003"]))
        XCTAssertEqual(activity.whatsAppName, "Shop Ltd")
        XCTAssertNil(activity.lastChat)
    }

    func testUnknownNumberHasNoActivity() throws {
        try makeStore()
        XCTAssertNil(try load().activity(for: ["+1 555 000 0000"]))
    }

    func testGroupsAreNotPeople() throws {
        try makeStore()
        XCTAssertNil(try load().byPhone["120363000000"])
    }

    func testMissingStoreIsReportedNotFatal() {
        guard case .failure(.missing) = WhatsAppStore.load(directory: directory.path, window: window) else {
            return XCTFail("an empty directory is a missing store")
        }
    }

    /// The newest chat is exactly the row wacli has not checkpointed yet.
    func testSeesRowsStillInTheWriteAheadLog() throws {
        try makeStore(walOnly: [
            "INSERT INTO chats VALUES ('919800000009@s.whatsapp.net', 'dm', 'New', \(seconds(2026, 11, 7)))",
        ])
        defer { for db in openConnections { sqlite3_close(db) } }
        let walSize = (try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("wacli.db-wal").path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(walSize, 0, "the row must still be in the WAL for this test to mean anything")

        let store = try load()
        XCTAssertNotNil(store.activity(for: ["9800000009"])?.lastChat)
        XCTAssertTrue(store.warnings.isEmpty, "\(store.warnings)")
    }

    func testDiwaliWindowBounds() {
        let calendar = Calendar.current
        let day = { (d: Int) in calendar.date(from: DateComponents(year: 2025, month: 10, day: d, hour: 1))! }
        XCTAssertFalse(window.contains(day(16)))
        XCTAssertTrue(window.contains(day(17)))
        XCTAssertTrue(window.contains(day(23)))
        XCTAssertFalse(window.contains(day(24)))
    }
}
