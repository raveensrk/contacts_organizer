import Foundation

/// A minimal terminal that applies the escape sequences the picker emits and
/// tracks where the cursor ends up. Enough to assert that a redraw returns to
/// the same screen row and that no row is wide enough to wrap.
struct TerminalSimulator {
    private(set) var row = 0
    private(set) var widestRow = 0
    private var column = 0

    mutating func feed(_ text: String) {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]

            if character == "\u{1B}" {
                var cursor = text.index(after: index)
                guard cursor < text.endIndex, text[cursor] == "[" else {
                    index = text.index(after: index); continue
                }
                cursor = text.index(after: cursor)
                var parameters = ""
                while cursor < text.endIndex, !text[cursor].isLetter {
                    parameters.append(text[cursor])
                    cursor = text.index(after: cursor)
                }
                if cursor < text.endIndex, text[cursor] == "A" {
                    row -= Int(parameters) ?? 1          // cursor up
                }
                index = cursor < text.endIndex ? text.index(after: cursor) : text.endIndex
                continue
            }

            switch character {
            case "\n": row += 1; widestRow = max(widestRow, column); column = 0
            case "\r": widestRow = max(widestRow, column); column = 0
            default: column += 1
            }
            index = text.index(after: index)
        }
        widestRow = max(widestRow, column)
    }
}
