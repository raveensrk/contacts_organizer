import Foundation

/// What the user asked for at the prompt.
enum Choice: Equatable {
    case list(index: Int)
    case create(name: String)
    case skip
    case undo
    case open
    case delete
    case quit
}

/// Chooses between the arrow-key picker and the line-based one.
enum Picker {
    static func prompt(options: [String]) -> Choice {
        // The line picker is the safe path: it needs no terminal at all, so it
        // covers piped input, dumb terminals, and anyone who wants out of raw mode.
        let forceSimple = ProcessInfo.processInfo.environment["CONTACTS_ORGANIZER_SIMPLE"] != nil
        return !forceSimple && InteractivePicker.isAvailable
            ? InteractivePicker.prompt(options: options)
            : LinePicker.prompt(options: options)
    }
}

/// A plain line-based picker.
///
/// It only ever prints lines and reads lines, so it works over any stdin,
/// needs no controlling terminal, and can be tested by piping input.
enum LinePicker {

    /// Prints the lists and reads one instruction, re-prompting until the
    /// input makes sense. Only valid choices are returned.
    static func prompt(options: [String]) -> Choice {
        printOptions(options)

        while true {
            print(Style.bold("list > "), terminator: "")
            fflush(stdout)
            guard let raw = readLine(strippingNewline: true) else {
                print("")
                return .quit          // stdin closed
            }
            let input = raw.trimmingCharacters(in: .whitespaces)

            if input.isEmpty { return .skip }

            if input.hasPrefix(":") {
                switch String(input.dropFirst()).lowercased() {
                case "q", "quit": return .quit
                case "s", "skip": return .skip
                case "u", "undo": return .undo
                case "o", "open": return .open
                case "d", "delete": return .delete
                case "l", "list": printOptions(options); continue
                case "?", "h", "help": printHelp(); continue
                default:
                    // ":new Name" forces a new list whose name would otherwise
                    // read as a number or a command.
                    let parts = input.dropFirst().split(separator: " ", maxSplits: 1)
                    if let head = parts.first, head.lowercased() == "new", parts.count == 2 {
                        return .create(name: String(parts[1]).trimmingCharacters(in: .whitespaces))
                    }
                    print(Style.yellow("  unknown command \(input) — :? for help"))
                    continue
                }
            }

            if let number = Int(input) {
                guard number >= 1, number <= options.count else {
                    print(Style.yellow("  pick 1–\(options.count), or type part of a name"))
                    continue
                }
                return .list(index: number - 1)
            }

            switch match(input, in: options) {
            case .one(let index):
                return .list(index: index)
            case .none:
                return .create(name: input)
            case .many(let indexes):
                print(Style.yellow("  \(indexes.count) lists match \"\(input)\":"))
                for index in indexes { print("    \(index + 1). \(options[index])") }
                print(Style.dim("  narrow it down, or use the number"))
                continue
            }
        }
    }

    // MARK: - Matching

    private enum Match {
        case one(Int)
        case many([Int])
        case none
    }

    /// Exact, then prefix, then substring. The first tier that yields a single
    /// hit wins, so "work" beats "Workshop" when a list is actually named Work.
    private static func match(_ input: String, in options: [String]) -> Match {
        let tiers: [(String, String) -> Bool] = [
            { $0.compare($1, options: .caseInsensitive) == .orderedSame },
            { $1.lowercased().hasPrefix($0.lowercased()) },
            { $1.range(of: $0, options: .caseInsensitive) != nil },
        ]
        for isMatch in tiers {
            let hits = options.indices.filter { isMatch(input, options[$0]) }
            if hits.count == 1 { return .one(hits[0]) }
            if hits.count > 1 { return .many(hits) }
        }
        return .none
    }

    // MARK: - Display

    private static func printOptions(_ options: [String]) {
        guard !options.isEmpty else {
            print(Style.dim("  no lists yet — type a name to create the first one"))
            return
        }
        // Two columns keep a long list from pushing the contact off screen.
        let width = (options.map(\.count).max() ?? 0) + 6
        let rows = (options.count + 1) / 2
        for row in 0..<rows {
            var line = "  "
            for column in 0..<2 {
                let index = row + column * rows
                guard index < options.count else { continue }
                let cell = Style.dim("\(index + 1).".padding(toLength: 4, withPad: " ", startingAt: 0))
                    + options[index]
                line += column == 0
                    ? cell.padding(toLength: cell.count + max(0, width - options[index].count - 4), withPad: " ", startingAt: 0)
                    : cell
            }
            print(line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
        }
    }

    private static func printHelp() {
        print("""
          \(Style.bold("number"))     file into that list
          \(Style.bold("text"))       file into the list matching that text; no match offers to create it
          \(Style.bold("enter"))      skip — comes back next run
          \(Style.bold(":u"))         undo the last assignment
          \(Style.bold(":o"))         open this contact in Contacts.app
          \(Style.bold(":d"))         delete this contact
          \(Style.bold(":new NAME"))  create a list named NAME, even if it looks like a number
          \(Style.bold(":l"))         reprint the lists
          \(Style.bold(":q"))         quit
        """)
    }
}

enum Shell {
    /// Opens a URL with the system handler (used for addressbook:// links).
    @discardableResult
    static func open(_ url: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

enum Prompt {
    /// Blocking y/N confirmation. Anything but an explicit "y" is a no.
    static func confirm(_ question: String) -> Bool {
        print(question + " " + Style.dim("[y/N]") + " ", terminator: "")
        fflush(stdout)
        guard let answer = readLine(strippingNewline: true) else { return false }
        return answer.trimmingCharacters(in: .whitespaces).lowercased() == "y"
    }
}
