import XCTest
@testable import contacts_organizer

/// The fallback picker used whenever stdin or stdout is not a terminal. It
/// reads lines, so it can be driven by pointing stdin at a file.
final class LinePickerTests: XCTestCase {
    private let options = ["Work", "Workshop", "Family", "College"]

    /// Feeds `input` to LinePicker.prompt, collecting one choice per call.
    /// Its own output is muted so the test log stays readable.
    private func choices(_ input: String, calls: Int = 1) -> [Choice] {
        let path = NSTemporaryDirectory() + UUID().uuidString
        try? input.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let savedOut = dup(STDOUT_FILENO)
        fflush(stdout)
        freopen("/dev/null", "w", stdout)
        freopen(path, "r", stdin)

        var results: [Choice] = []
        for _ in 0..<calls { results.append(LinePicker.prompt(options: options)) }

        fflush(stdout)
        dup2(savedOut, STDOUT_FILENO)
        close(savedOut)
        freopen("/dev/null", "r", stdin)
        return results
    }

    func testNumberSelectsThatList() {
        XCTAssertEqual(choices("1\n"), [.list(index: 0)])
        XCTAssertEqual(choices("4\n"), [.list(index: 3)])
    }

    func testTextMatching() {
        XCTAssertEqual(choices("family\n"), [.list(index: 2)], "exact")
        XCTAssertEqual(choices("col\n"), [.list(index: 3)], "prefix")
        XCTAssertEqual(choices("work\n"), [.list(index: 0)], "exact beats the longer prefix match")
    }

    /// An ambiguous prefix must re-prompt rather than guess.
    func testAmbiguousTextRePrompts() {
        XCTAssertEqual(choices("wor\n2\n"), [.list(index: 1)])
    }

    func testUnmatchedTextOffersToCreate() {
        XCTAssertEqual(choices("Gym\n"), [.create(name: "Gym")])
    }

    func testEmptyLineSkips() {
        XCTAssertEqual(choices("\n"), [.skip])
    }

    func testCommands() {
        XCTAssertEqual(choices(":u\n:o\n:d\n:q\n", calls: 4), [.undo, .open, .delete, .quit])
    }

    /// ":new" exists so a list whose name reads as a number is still reachable.
    func testNewForcesALiteralName() {
        XCTAssertEqual(choices(":new 5\n"), [.create(name: "5")])
    }

    func testOutOfRangeNumberRePrompts() {
        XCTAssertEqual(choices("99\n4\n"), [.list(index: 3)])
    }

    func testUnknownCommandRePrompts() {
        XCTAssertEqual(choices(":x\n:q\n"), [.quit])
    }

    /// Closed stdin must end the session instead of spinning forever.
    func testEndOfInputQuits() {
        XCTAssertEqual(choices(""), [.quit])
    }
}
