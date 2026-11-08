import Foundation

enum KeyEvent: Equatable {
    case up, down, enter, backspace, escape
    case skip, undo, open, delete, quit
    case char(Character)
}

/// Turns a raw byte stream into key events.
///
/// Kept free of any terminal handling so it can be tested by feeding it bytes.
enum KeyDecoder {

    /// Decodes what it can, returning the events plus any trailing bytes that
    /// form an incomplete escape sequence and should be kept for the next read.
    static func decode(_ bytes: [UInt8]) -> (events: [KeyEvent], leftover: [UInt8]) {
        var events: [KeyEvent] = []
        var index = 0
        var pending: [UInt8] = []

        while index < bytes.count {
            let byte = bytes[index]

            if byte == 0x1B {
                // ESC [ A / ESC O A and friends. Both forms appear depending on
                // whether the terminal is in application cursor mode.
                //
                // A terminal delivers an arrow key's three bytes in one read, so
                // an ESC arriving alone is the Esc key, not a truncated arrow.
                // Only a sequence already past its introducer is worth holding.
                guard index + 1 < bytes.count else {
                    events.append(.escape); index += 1; continue
                }
                let second = bytes[index + 1]
                guard second == 0x5B || second == 0x4F else {
                    events.append(.escape); index += 1; continue
                }
                guard index + 2 < bytes.count else {
                    pending = Array(bytes[index...]); break
                }
                switch bytes[index + 2] {
                case 0x41: events.append(.up)
                case 0x42: events.append(.down)
                default: break          // arrows are all we act on
                }
                index += 3
                continue
            }

            switch byte {
            case 0x0D, 0x0A: events.append(.enter)
            case 0x7F, 0x08: events.append(.backspace)
            case 0x03, 0x11: events.append(.quit)      // ctrl-c, ctrl-q
            case 0x13: events.append(.skip)            // ctrl-s
            case 0x15: events.append(.undo)            // ctrl-u
            case 0x0F: events.append(.open)            // ctrl-o
            case 0x04: events.append(.delete)          // ctrl-d
            case 0x0E: events.append(.down)            // ctrl-n
            case 0x10: events.append(.up)              // ctrl-p
            default:
                guard byte >= 0x20 else { break }
                if byte < 0x80 {
                    events.append(.char(Character(UnicodeScalar(byte))))
                    index += 1
                    continue
                }
                // Multi-byte UTF-8: take the whole sequence, or keep it back.
                let length = byte >= 0xF0 ? 4 : (byte >= 0xE0 ? 3 : 2)
                guard index + length <= bytes.count else {
                    pending = Array(bytes[index...]); index = bytes.count; continue
                }
                if let text = String(bytes: bytes[index..<(index + length)], encoding: .utf8) {
                    events.append(contentsOf: text.map { KeyEvent.char($0) })
                }
                index += length
                continue
            }
            index += 1
        }
        return (events, pending)
    }
}

/// The picker's state: what has been typed, which rows survive, and where the
/// highlight sits. Pure value logic, so every transition is testable.
struct PickerModel {
    let options: [String]
    /// When false, enter on no match does nothing instead of offering a new list.
    let allowCreate: Bool
    private(set) var query = ""
    private(set) var highlight = 0
    private(set) var filtered: [Int] = []

    init(options: [String], allowCreate: Bool = true) {
        self.options = options
        self.allowCreate = allowCreate
        refilter()
    }

    /// Applies one key. Returns a Choice once the user has committed,
    /// or nil to keep editing.
    mutating func apply(_ event: KeyEvent) -> Choice? {
        switch event {
        case .up:
            if !filtered.isEmpty { highlight = highlight == 0 ? filtered.count - 1 : highlight - 1 }
        case .down:
            if !filtered.isEmpty { highlight = (highlight + 1) % filtered.count }
        case .char(let character):
            query.append(character); refilter()
        case .backspace:
            if !query.isEmpty { query.removeLast(); refilter() }
        case .enter:
            if !filtered.isEmpty { return .list(index: filtered[highlight]) }
            let name = query.trimmingCharacters(in: .whitespaces)
            return name.isEmpty || !allowCreate ? nil : .create(name: name)
        case .skip: return .skip
        case .undo: return .undo
        case .open: return .open
        case .delete: return .delete
        case .quit, .escape: return .quit
        }
        return nil
    }

    /// Case-insensitive substring filter, ranked exact → prefix → contains so
    /// typing "work" puts Work above Workshop.
    private mutating func refilter() {
        filtered = Self.rank(query, in: options)
        highlight = 0
    }

    /// Indexes of the options matching `query`, exact first, then prefix,
    /// then substring. An empty query keeps every option in order.
    static func rank(_ query: String, in options: [String]) -> [Int] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return Array(options.indices) }
        var exact: [Int] = [], prefix: [Int] = [], contains: [Int] = []
        for index in options.indices {
            let name = options[index].lowercased()
            if name == needle { exact.append(index) }
            else if name.hasPrefix(needle) { prefix.append(index) }
            else if name.contains(needle) { contains.append(index) }
        }
        return exact + prefix + contains
    }
}

/// The ignore picker's state: which options are ticked, plus the same
/// filter and highlight as `PickerModel`. Space ticks, so a query cannot
/// hold a space; typing a word of the name is enough to find it.
struct CheckboxModel {
    enum Outcome: Equatable {
        case save(Set<Int>)
        case cancel
    }

    let options: [String]
    private(set) var checked: Set<Int>
    private(set) var query = ""
    private(set) var highlight = 0
    private(set) var filtered: [Int] = []

    init(options: [String], checked: Set<Int>) {
        self.options = options
        self.checked = checked.filter { options.indices.contains($0) }
        filtered = Array(options.indices)
    }

    mutating func apply(_ event: KeyEvent) -> Outcome? {
        switch event {
        case .up:
            if !filtered.isEmpty { highlight = highlight == 0 ? filtered.count - 1 : highlight - 1 }
        case .down:
            if !filtered.isEmpty { highlight = (highlight + 1) % filtered.count }
        case .char(" "):
            if !filtered.isEmpty {
                let index = filtered[highlight]
                if checked.contains(index) { checked.remove(index) } else { checked.insert(index) }
            }
        case .char(let character):
            query.append(character); refilter()
        case .backspace:
            if !query.isEmpty { query.removeLast(); refilter() }
        case .enter:
            return .save(checked)
        case .escape, .quit:
            return .cancel
        case .skip, .undo, .open, .delete:
            break
        }
        return nil
    }

    private mutating func refilter() {
        filtered = PickerModel.rank(query, in: options)
        highlight = 0
    }
}
