import XCTest
@testable import contacts_organizer

final class PickerModelTests: XCTestCase {
    private let options = ["Work", "Workshop", "Family", "College"]

    private func model() -> PickerModel { PickerModel(options: options) }

    private func send(_ events: [KeyEvent], to model: inout PickerModel) -> Choice? {
        for event in events { if let choice = model.apply(event) { return choice } }
        return nil
    }

    func testEnterTakesTheHighlightedRow() {
        var m = model()
        XCTAssertEqual(send([.enter], to: &m), .list(index: 0))
    }

    func testArrowsMoveAndWrap() {
        var down = model()
        XCTAssertEqual(send([.down, .enter], to: &down), .list(index: 1))

        var up = model()
        XCTAssertEqual(send([.up, .enter], to: &up), .list(index: 3), "up from the top wraps to the end")
    }

    /// Exact beats prefix, so typing a full list name never lands on a longer one.
    func testExactMatchOutranksPrefix() {
        var m = model()
        XCTAssertEqual(send("work".map { .char($0) } + [.enter], to: &m), .list(index: 0))
    }

    func testPrefixNarrowsAndKeepsBothCandidates() {
        var m = model()
        _ = send("wor".map { .char($0) }, to: &m)
        XCTAssertEqual(m.filtered, [0, 1])
        XCTAssertEqual(send([.down, .enter], to: &m), .list(index: 1))
    }

    func testSubstringMatch() {
        var m = model()
        _ = send("ollege".map { .char($0) }, to: &m)
        XCTAssertEqual(m.filtered, [3])
    }

    func testNoMatchOffersToCreate() {
        var m = model()
        XCTAssertEqual(send("Gym".map { .char($0) } + [.enter], to: &m), .create(name: "Gym"))
    }

    func testBackspaceEditsTheFilter() {
        var m = model()
        XCTAssertEqual(send("Gymx".map { .char($0) } + [.backspace, .enter], to: &m),
                       .create(name: "Gym"))
    }

    /// Enter with nothing typed and nothing matching must not commit anything.
    func testEnterOnAnEmptyListDoesNothing() {
        var empty = PickerModel(options: [])
        XCTAssertNil(empty.apply(.enter))
    }

    func testEscapesMapToChoices() {
        for (event, expected) in [(KeyEvent.skip, Choice.skip), (.undo, .undo),
                                  (.open, .open), (.delete, .delete),
                                  (.quit, .quit), (.escape, .quit)] {
            var m = model()
            XCTAssertEqual(m.apply(event), expected)
        }
    }
}
