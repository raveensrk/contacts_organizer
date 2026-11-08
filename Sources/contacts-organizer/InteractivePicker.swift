import Darwin
import Foundation

/// Saved terminal state, global so a signal handler can put it back.
private var savedTerminal = termios()
private var terminalIsRaw = false

private func restoreTerminal() {
    guard terminalIsRaw else { return }
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &savedTerminal)
    terminalIsRaw = false
    print("\u{1B}[?25h", terminator: "")   // show cursor again
    fflush(stdout)
}

/// A killed process must not leave the shell without an echo or a cursor.
private func installTerminalGuards() {
    atexit { restoreTerminal() }
    for sig in [SIGTERM, SIGHUP, SIGQUIT] {
        signal(sig) { _ in restoreTerminal(); exit(128) }
    }
}

/// Arrow-key picker. Redraws in place on every keystroke.
enum InteractivePicker {

    /// Raw mode needs a real terminal on both ends.
    static var isAvailable: Bool { isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 }

    static func prompt(options: [String], allowCreate: Bool = true) -> Choice {
        guard enterRawMode() else { return LinePicker.prompt(options: options, allowCreate: allowCreate) }
        defer { restoreTerminal() }

        var model = PickerModel(options: options, allowCreate: allowCreate)
        var leftover: [UInt8] = []
        var linesDrawn = 0

        print("\u{1B}[?25l", terminator: "")   // hide cursor while we redraw

        while true {
            linesDrawn = draw(model, clearing: linesDrawn)

            var buffer = [UInt8](repeating: 0, count: 1024)
            let count = read(STDIN_FILENO, &buffer, 1024)
            guard count > 0 else { erase(linesDrawn); return .quit }

            let (events, pending) = KeyDecoder.decode(leftover + Array(buffer[0..<count]))
            leftover = pending

            for event in events {
                if let choice = model.apply(event) {
                    erase(linesDrawn)
                    return choice
                }
            }
        }
    }

    // MARK: - Drawing

    /// Terminal size. Falls back to COLUMNS/LINES when there is no tty to ask
    /// (a pipe, a renderer), then to a conservative 80x24.
    private static var terminalSize: (columns: Int, rows: Int) {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 {
            return (Int(size.ws_col), size.ws_row > 0 ? Int(size.ws_row) : 24)
        }
        let environment = ProcessInfo.processInfo.environment
        return (environment["COLUMNS"].flatMap(Int.init) ?? 80,
                environment["LINES"].flatMap(Int.init) ?? 24)
    }

    /// Clips to a visible width. Every row must fit on one terminal line: a
    /// wrapped row occupies two rows the cursor arithmetic does not know about,
    /// which is what makes a redraw walk up the screen.
    private static func clip(_ text: String, to width: Int) -> String {
        guard width > 1 else { return "" }
        return text.count <= width ? text : String(text.prefix(width - 1)) + "…"
    }

    /// Redraws in place, returning how many terminal rows the frame occupies.
    private static func draw(_ model: PickerModel, clearing previous: Int) -> Int {
        let rendered = frame(model, clearing: previous)
        fputs(rendered.text, stdout)
        fflush(stdout)
        return rendered.rows
    }

    /// Builds the frame without writing it, so the cursor arithmetic and the
    /// no-wrap guarantee can be tested without a terminal.
    static func frame(_ model: PickerModel, clearing previous: Int) -> (text: String, rows: Int) {
        let (columns, screenRows) = terminalSize
        let width = columns - 1          // never write the last column: some
                                         // terminals wrap as soon as it is used
        var rows: [String] = []

        rows.append(Style.bold("list > ") + clip(model.query, to: max(0, width - 7)))

        if model.options.isEmpty {
            rows.append(Style.dim(clip("  no lists yet — type a name to create the first one", to: width)))
        } else if model.filtered.isEmpty {
            let message = model.allowCreate
                ? "  no match — enter creates \"\(model.query)\""
                : "  no match — backspace to widen"
            rows.append(Style.yellow(clip(message, to: width)))
        } else {
            // Leave room for the card above, the prompt, the hint and the shell.
            let budget = max(3, min(maxRows, screenRows - 8))
            let visible = min(budget, model.filtered.count)
            let top = model.filtered.count > visible
                ? max(0, min(model.highlight - visible / 2, model.filtered.count - visible))
                : 0
            for row in top..<(top + visible) {
                let name = model.options[model.filtered[row]]
                if row == model.highlight {
                    // Pad so the highlight reads as a full-width bar.
                    let text = clip("▸ " + name, to: width)
                    rows.append(Style.selected(text.padding(toLength: max(text.count, width), withPad: " ", startingAt: 0)))
                } else {
                    rows.append(clip("  " + name, to: width))
                }
            }
            if model.filtered.count > visible {
                rows.append(Style.dim(clip("  … \(model.filtered.count - visible) more", to: width)))
            }
        }

        let hint = width < 72
            ? "  ↑↓ move · enter file · ctrl-s skip · ctrl-q quit"
            : "  ↑↓ move · enter file · ctrl-s skip · ctrl-u undo · ctrl-o open · ctrl-d delete · ctrl-q quit"
        rows.append(Style.dim(clip(hint, to: width)))

        return emit(rows, clearing: previous)
    }

    /// Wraps finished rows in the cursor moves that redraw them in place.
    private static func emit(_ rows: [String], clearing previous: Int) -> (text: String, rows: Int) {
        // One frame, one write. Each row erases only its own tail as it is
        // rewritten, so no blanked region is ever visible; the trailing ED(0)
        // removes leftovers when the previous frame was taller.
        var out = "\u{1B}[?2026h"                                   // begin synchronized update
        if previous > 1 { out += "\u{1B}[\(previous - 1)A" }        // cursor sits on the last row
        out += "\r"
        out += rows.map { $0 + "\u{1B}[K" }.joined(separator: "\n")
        out += "\u{1B}[0J"
        out += "\u{1B}[?2026l"                                      // end synchronized update
        return (out, rows.count)
    }

    private static let maxRows = 10

    private static func erase(_ lines: Int) {
        guard lines > 0 else { return }
        var out = ""
        if lines > 1 { out += "\u{1B}[\(lines - 1)A" }
        out += "\r\u{1B}[0J"
        fputs(out, stdout)
        fflush(stdout)
    }

    // MARK: - Raw mode

    private static func enterRawMode() -> Bool {
        guard tcgetattr(STDIN_FILENO, &savedTerminal) == 0 else { return false }
        installTerminalGuards()

        var raw = savedTerminal
        // Read keys as they are typed, with no echo, and let ctrl-c/ctrl-s
        // arrive as bytes rather than signals or flow control.
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        // OPOST stays on so "\n" still means a fresh column.
        raw.c_cc.16 = 1     // VMIN: one byte is enough to return
        raw.c_cc.17 = 0     // VTIME: no timeout
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return false }
        terminalIsRaw = true
        return true
    }
}

// MARK: - Checkbox picker

extension InteractivePicker {

    /// Ticks and unticks options; nil means cancelled.
    static func checkboxes(options: [String], checked: Set<Int>) -> Set<Int>? {
        guard enterRawMode() else { return LineCheckboxes.prompt(options: options, checked: checked) }
        defer { restoreTerminal() }

        var model = CheckboxModel(options: options, checked: checked)
        var leftover: [UInt8] = []
        var linesDrawn = 0
        print("\u{1B}[?25l", terminator: "")

        while true {
            let rendered = checkboxFrame(model, clearing: linesDrawn)
            fputs(rendered.text, stdout)
            fflush(stdout)
            linesDrawn = rendered.rows

            var buffer = [UInt8](repeating: 0, count: 1024)
            let count = read(STDIN_FILENO, &buffer, 1024)
            guard count > 0 else { erase(linesDrawn); return nil }

            let (events, pending) = KeyDecoder.decode(leftover + Array(buffer[0..<count]))
            leftover = pending
            for event in events {
                switch model.apply(event) {
                case .save(let result): erase(linesDrawn); return result
                case .cancel: erase(linesDrawn); return nil
                case nil: continue
                }
            }
        }
    }

    static func checkboxFrame(_ model: CheckboxModel, clearing previous: Int) -> (text: String, rows: Int) {
        let (columns, screenRows) = terminalSize
        let width = columns - 1
        var rows: [String] = []

        rows.append(Style.bold("ignore > ") + clip(model.query, to: max(0, width - 9)))

        if model.options.isEmpty {
            rows.append(Style.dim(clip("  no lists to ignore", to: width)))
        } else if model.filtered.isEmpty {
            rows.append(Style.yellow(clip("  no match — backspace to widen", to: width)))
        } else {
            let budget = max(3, min(16, screenRows - 6))
            let visible = min(budget, model.filtered.count)
            let top = model.filtered.count > visible
                ? max(0, min(model.highlight - visible / 2, model.filtered.count - visible))
                : 0
            for row in top..<(top + visible) {
                let index = model.filtered[row]
                let box = model.checked.contains(index) ? "[x] " : "[ ] "
                if row == model.highlight {
                    let text = clip("▸ " + box + model.options[index], to: width)
                    rows.append(Style.selected(text.padding(toLength: max(text.count, width), withPad: " ", startingAt: 0)))
                } else {
                    rows.append(clip("  " + box + model.options[index], to: width))
                }
            }
            if model.filtered.count > visible {
                rows.append(Style.dim(clip("  … \(model.filtered.count - visible) more", to: width)))
            }
        }

        let hint = "  ↑↓ move · space tick · type to filter · enter save · esc cancel"
        rows.append(Style.dim(clip("\(model.checked.count) ticked" + hint, to: width)))
        return emit(rows, clearing: previous)
    }
}
