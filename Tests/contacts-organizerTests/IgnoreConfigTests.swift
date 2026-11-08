import XCTest
@testable import contacts_organizer

/// The ignore list is the tool's one file of its own. It is read by a small
/// parser, so the shapes a person might write by hand are pinned here.
final class IgnoreConfigTests: XCTestCase {

    func testMissingFileIgnoresNothing() throws {
        let path = NSTemporaryDirectory() + UUID().uuidString + "/config.toml"
        XCTAssertEqual(try IgnoreConfig.load(path: path), .empty)
    }

    func testEmptyList() throws {
        XCTAssertEqual(try IgnoreConfig.parse("[wishlist]\nignore = []\n").groupIDs, [])
    }

    func testMultiLineListWithComments() throws {
        let text = """
            # top comment
            [wishlist]
            # Groups to skip
            ignore = [
              "AAA:ABGroup",  # Work
              "BBB:ABGroup",  # Clients, # with a hash
            ]
            """
        XCTAssertEqual(try IgnoreConfig.parse(text).groupIDs, ["AAA:ABGroup", "BBB:ABGroup"])
    }

    func testSingleLineAndDottedKey() throws {
        XCTAssertEqual(try IgnoreConfig.parse("[wishlist]\nignore = [\"A\", \"B\"]").groupIDs, ["A", "B"])
        XCTAssertEqual(try IgnoreConfig.parse("wishlist.ignore = [\"A\"]").groupIDs, ["A"])
    }

    func testOtherTablesAreSkipped() throws {
        let text = "[other]\nignore = [\"X\"]\n[wishlist]\nignore = [\"Y\"]\n"
        XCTAssertEqual(try IgnoreConfig.parse(text).groupIDs, ["Y"])
    }

    func testHashInsideAStringIsNotAComment() throws {
        XCTAssertEqual(try IgnoreConfig.parse("[wishlist]\nignore = [\"a#b\"]").groupIDs, ["a#b"])
    }

    func testDuplicatesCollapse() throws {
        XCTAssertEqual(try IgnoreConfig.parse("[wishlist]\nignore = [\"A\", \"A\"]").groupIDs, ["A"])
    }

    func testMalformedValuesAreErrors() {
        XCTAssertThrowsError(try IgnoreConfig.parse("[wishlist]\nignore = \"A\""))
        XCTAssertThrowsError(try IgnoreConfig.parse("[wishlist]\nignore = [A]"))
        XCTAssertThrowsError(try IgnoreConfig.parse("[wishlist]\nignore = [\n\"A\",\n"))
        XCTAssertThrowsError(try IgnoreConfig.parse("[wishlist]\nignore = [\"A]"))
    }

    func testRenderedFileReadsBackAndNamesEachGroup() throws {
        let config = IgnoreConfig(groupIDs: ["AAA:ABGroup", "quote\"d"])
        let text = IgnoreConfig.render(config, names: ["AAA:ABGroup": "Work"])
        XCTAssertTrue(text.contains("\"AAA:ABGroup\",  # Work"), text)
        XCTAssertEqual(try IgnoreConfig.parse(text), config)
        XCTAssertEqual(try IgnoreConfig.parse(IgnoreConfig.render(.empty, names: [:])), .empty)
    }

    func testSaveCreatesTheDirectory() throws {
        let directory = NSTemporaryDirectory() + "contacts-organizer-config-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/nested/config.toml"
        try IgnoreConfig.save(IgnoreConfig(groupIDs: ["A"]), names: ["A": "Work"], path: path)
        XCTAssertEqual(try IgnoreConfig.load(path: path).groupIDs, ["A"])
    }
}
