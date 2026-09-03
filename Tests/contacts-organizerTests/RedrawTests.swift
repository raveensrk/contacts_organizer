import XCTest
@testable import contacts_organizer

/// Guards the two faults that made the picker unusable: a frame that walks up
/// the screen on every keystroke, and rows wide enough to wrap.
final class RedrawTests: XCTestCase {

    /// No tty in tests, so the picker reads COLUMNS/LINES.
    private let columns = 80

    override func setUp() {
        super.setUp()
        setenv("COLUMNS", String(columns), 1)
        setenv("LINES", "24", 1)
    }

    override func tearDown() {
        unsetenv("COLUMNS")
        unsetenv("LINES")
        super.tearDown()
    }

    private func longList() -> PickerModel {
        PickerModel(options: (1...25).map { "List number \($0) with a fairly long name" })
    }

    /// The cursor sits on the last row after a draw, so returning to the top
    /// takes `rows - 1`. Getting this wrong moves the frame up one row a time.
    func testConsecutiveFramesStartOnTheSameRow() {
        var model = longList()
        var terminal = TerminalSimulator()
        var previous = 0
        var starts: [Int] = []

        for step in 0..<8 {
            let before = terminal.row
            let frame = InteractivePicker.frame(model, clearing: previous)

            var probe = TerminalSimulator()
            probe.feed(String(repeating: "\n", count: before))
            probe.feed(String(frame.text.prefix(while: { $0 != "l" })))
            starts.append(probe.row)

            terminal.feed(frame.text)
            previous = frame.rows
            _ = model.apply(step.isMultiple(of: 2) ? .down : .up)
        }

        XCTAssertEqual(Set(starts).count, 1, "frame drifted between redraws: \(starts)")
        XCTAssertEqual(starts.first, 0, "frames must start at the top of the block")
    }

    /// A wrapped row occupies a terminal line the cursor arithmetic cannot see.
    func testNoRowReachesTheTerminalWidth() {
        var terminal = TerminalSimulator()
        terminal.feed(InteractivePicker.frame(longList(), clearing: 0).text)
        XCTAssertLessThan(terminal.widestRow, columns)
    }

    func testLongQueryStillFits() {
        var model = longList()
        for character in String(repeating: "x", count: 200) { _ = model.apply(.char(character)) }
        var terminal = TerminalSimulator()
        terminal.feed(InteractivePicker.frame(model, clearing: 0).text)
        XCTAssertLessThan(terminal.widestRow, columns)
    }

    func testReportedRowCountMatchesEmittedRows() {
        let frame = InteractivePicker.frame(longList(), clearing: 0)
        XCTAssertEqual(frame.rows, frame.text.filter { $0 == "\n" }.count + 1)
    }

    /// Shrinking frames must wipe what the taller previous frame left behind.
    func testFrameClearsBelowItself() {
        XCTAssertTrue(InteractivePicker.frame(longList(), clearing: 0).text.contains("\u{1B}[0J"))
    }

    /// Without a synchronized update the redraw tears visibly.
    func testFrameIsASynchronizedUpdate() {
        let text = InteractivePicker.frame(longList(), clearing: 0).text
        XCTAssertTrue(text.hasPrefix("\u{1B}[?2026h"))
        XCTAssertTrue(text.hasSuffix("\u{1B}[?2026l"))
    }

    /// The visible window must shrink on a short terminal rather than produce
    /// a frame taller than the screen, which would scroll and drift.
    func testVisibleRowsShrinkOnAShortTerminal() {
        setenv("LINES", "14", 1)
        let short = InteractivePicker.frame(longList(), clearing: 0).rows
        setenv("LINES", "40", 1)
        let tall = InteractivePicker.frame(longList(), clearing: 0).rows
        XCTAssertLessThan(short, tall)
        XCTAssertLessThanOrEqual(short, 14)
    }
}
