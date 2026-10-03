import Foundation
import SQLite3
import XCTest
@testable import contacts_organizer

/// The date join reads Contacts.app's Core Data files directly. What it must
/// not do is miss a card that Contacts.app has written but not checkpointed:
/// those rows live in the -wal file, and they are always the newest cards.
final class ModificationDateTests: XCTestCase {

    private var directory: URL!
    private var db: OpaquePointer?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("contacts-organizer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let db { sqlite3_close(db) }
        db = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testReadsRowsThatAreStillInTheWriteAheadLog() throws {
        let path = directory.appendingPathComponent("AddressBook-v22.abcddb").path
        try createStore(at: path)

        // Checkpointed row, then a row that only exists in the WAL.
        try sql("INSERT INTO ZABCDRECORD (ZUNIQUEID, ZMODIFICATIONDATE) "
            + "VALUES ('11111111-1111-1111-1111-111111111111:ABPerson', 800000000);")
        try sql("PRAGMA wal_checkpoint(TRUNCATE);")
        try sql("INSERT INTO ZABCDRECORD (ZUNIQUEID, ZMODIFICATIONDATE) "
            + "VALUES ('22222222-2222-2222-2222-222222222222:ABPerson', 800000100);")

        let wal = path + "-wal"
        let attributes = try FileManager.default.attributesOfItem(atPath: wal)
        let walSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(walSize, 0,
            "the second row must still be in the WAL for this test to mean anything")

        let dates = ModificationDates.load(from: [path])

        XCTAssertNotNil(dates["11111111-1111-1111-1111-111111111111:ABPerson"])
        XCTAssertNotNil(dates["22222222-2222-2222-2222-222222222222:ABPerson"],
                        "a row in the WAL is a contact the tool must still be able to date")
        // Both halves of the identifier are indexed, because macOS has shipped
        // CNContact.identifier in both forms.
        XCTAssertNotNil(dates["22222222-2222-2222-2222-222222222222"])
    }

    func testIgnoresRowsTheJoinCannotUse() throws {
        let path = directory.appendingPathComponent("AddressBook-v22.abcddb").path
        try createStore(at: path)

        try sql("INSERT INTO ZABCDRECORD (ZUNIQUEID, ZMODIFICATIONDATE) "
            + "VALUES ('33333333-3333-3333-3333-333333333333:ABGroup', 800000200);")
        try sql("INSERT INTO ZABCDRECORD (ZUNIQUEID, ZMODIFICATIONDATE) "
            + "VALUES ('44444444-4444-4444-4444-444444444444:ABPerson', NULL);")

        let dates = ModificationDates.load(from: [path])

        XCTAssertTrue(dates.isEmpty, "groups and undated rows are not contacts: \(dates)")
    }

    func testAnUnreadableStoreIsNotFatal() {
        let missing = directory.appendingPathComponent("nothing-here.abcddb").path
        XCTAssertTrue(ModificationDates.load(from: [missing]).isEmpty)
    }

    // MARK: - Fixture

    private func createStore(at path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw XCTSkip("could not open a scratch sqlite store")
        }
        try sql("PRAGMA journal_mode=WAL;")
        try sql("CREATE TABLE ZABCDRECORD (ZUNIQUEID VARCHAR, ZMODIFICATIONDATE TIMESTAMP);")
    }

    private func sql(_ statement: String) throws {
        guard let db else { throw XCTSkip("no store") }
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, statement, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            XCTFail("\(statement) failed: \(text)")
            throw XCTSkip("statement failed")
        }
    }
}
