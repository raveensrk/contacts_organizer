import XCTest
@testable import contacts_organizer

private let ESC: UInt8 = 0x1B

final class KeyDecoderTests: XCTestCase {

    func testArrowsInNormalMode() {
        XCTAssertEqual(KeyDecoder.decode([ESC, 0x5B, 0x41]).events, [.up])
        XCTAssertEqual(KeyDecoder.decode([ESC, 0x5B, 0x42]).events, [.down])
    }

    /// Terminals in application cursor mode send ESC O A rather than ESC [ A.
    func testArrowsInApplicationCursorMode() {
        XCTAssertEqual(KeyDecoder.decode([ESC, 0x4F, 0x41]).events, [.up])
        XCTAssertEqual(KeyDecoder.decode([ESC, 0x4F, 0x42]).events, [.down])
    }

    /// A sequence split across two reads must survive being rejoined.
    func testPartialSequenceIsHeldBack() {
        let first = KeyDecoder.decode([ESC, 0x5B])
        XCTAssertTrue(first.events.isEmpty)
        XCTAssertEqual(first.leftover, [ESC, 0x5B])
        XCTAssertEqual(KeyDecoder.decode(first.leftover + [0x41]).events, [.up])
    }

    /// A terminal delivers an arrow's three bytes in one read, so an ESC that
    /// arrives alone is the Esc key — not a truncated arrow to wait on.
    func testLoneEscapeIsTheEscapeKey() {
        XCTAssertEqual(KeyDecoder.decode([ESC]).events, [.escape])
    }

    func testControlKeys() {
        XCTAssertEqual(KeyDecoder.decode([0x13, 0x15, 0x0F, 0x04, 0x11]).events,
                       [.skip, .undo, .open, .delete, .quit])
        XCTAssertEqual(KeyDecoder.decode([0x03]).events, [.quit])       // ctrl-c
        XCTAssertEqual(KeyDecoder.decode([0x0E, 0x10]).events, [.down, .up])  // ctrl-n/p
        XCTAssertEqual(KeyDecoder.decode([0x0D]).events, [.enter])
        XCTAssertEqual(KeyDecoder.decode([0x7F]).events, [.backspace])
    }

    func testMultiByteCharacters() {
        XCTAssertEqual(KeyDecoder.decode(Array("é".utf8)).events, [.char("é")])
        XCTAssertEqual(KeyDecoder.decode(Array("ab".utf8)).events, [.char("a"), .char("b")])
    }

    /// A truncated UTF-8 sequence must wait for the rest rather than emit junk.
    func testPartialUTF8IsHeldBack() {
        let bytes = Array("é".utf8)
        let first = KeyDecoder.decode([bytes[0]])
        XCTAssertTrue(first.events.isEmpty)
        XCTAssertEqual(KeyDecoder.decode(first.leftover + [bytes[1]]).events, [.char("é")])
    }
}
