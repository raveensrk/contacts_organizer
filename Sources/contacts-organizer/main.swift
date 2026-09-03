import Contacts
import Foundation

let usage = """
contacts-organizer — file unsorted iCloud contacts into lists, from the terminal

USAGE
  contacts-organizer [command] [--container <id>]

COMMANDS
  triage    Walk contacts that are in no list, filing each one (default)
  stats     Counts for the iCloud account: total, filed, unfiled, per list
  lists     Print the lists in the iCloud account
  audit     Report contacts that are in more than one list
  doctor    Diagnose permissions, account detection and date matching
  help      This message

TRIAGE KEYS
  up/down     move the highlight (ctrl-p / ctrl-n also work)
  type        filter the lists as you type; no match means enter creates it
  enter       file into the highlighted list
  ctrl-s      skip — reappears on the next run
  ctrl-u      undo the last assignment and re-show that contact
  ctrl-o      open the contact in Contacts.app
  ctrl-d      delete the contact (confirmed; syncs to all devices)
  ctrl-q/esc  quit — everything filed so far is already saved

  Over a pipe or a dumb terminal it falls back to a numbered prompt
  (a number, or text to match, enter to skip, :q to quit, :? for help).
  Set CONTACTS_ORGANIZER_SIMPLE=1 to force that mode.
"""

func main() throws {
    var arguments = Array(CommandLine.arguments.dropFirst())

    var containerID: String?
    if let flag = arguments.firstIndex(of: "--container") {
        guard flag + 1 < arguments.count else { throw AppError("--container needs an identifier") }
        containerID = arguments[flag + 1]
        arguments.removeSubrange(flag...(flag + 1))
    }

    let command = arguments.first ?? "triage"
    if command == "help" || command == "--help" || command == "-h" {
        print(usage)
        return
    }

    if command == "doctor" {
        try runDoctor(containerID: containerID)
        return
    }

    let repo = try ContactsRepo.open(explicitContainerID: containerID)

    switch command {
    case "triage": try runTriage(repo)
    case "stats": try runStats(repo)
    case "lists": try runLists(repo)
    case "audit": try runAudit(repo)
    default:
        throw AppError("Unknown command \"\(command)\".\n\n\(usage)")
    }
}

func runTriage(_ repo: ContactsRepo) throws {
    let groups = try repo.groups()
    let contacts = try repo.contacts()
    let membership = try repo.membershipIndex(groups: groups)
    let unfiled = QueueBuilder.unfiled(contacts: contacts, membership: membership)

    guard !unfiled.isEmpty else {
        print(Style.green("Nothing to triage — every contact in \"\(repo.containerName)\" is in a list."))
        return
    }
    if groups.isEmpty {
        print(Style.yellow("No lists exist yet. Type a name at the picker to create your first one."))
    }

    let queue = QueueBuilder.ordered(unfiled)
    print(Style.bold("\(queue.contacts.count) unfiled") + Style.dim(" in \"\(repo.containerName)\" · ordered by \(queue.orderDescription)"))

    try Triage(repo: repo, groups: groups, queue: queue.contacts).run()
}

func runStats(_ repo: ContactsRepo) throws {
    let groups = try repo.groups()
    let contacts = try repo.contacts()
    let membership = try repo.membershipIndex(groups: groups)
    let unfiled = QueueBuilder.unfiled(contacts: contacts, membership: membership)

    print(Style.bold("Account") + " \(repo.containerName)")
    print(Style.dim("  container ") + repo.containerID)
    print("")
    print(Style.bold("Contacts"))
    print("  total:   \(contacts.count)")
    print("  filed:   \(contacts.count - unfiled.count)")
    print("  unfiled: \(unfiled.count)")

    if !groups.isEmpty {
        print("")
        print(Style.bold("Lists") + Style.dim(" (\(groups.count))"))
        let width = groups.map(\.name.count).max() ?? 0
        for group in groups {
            let count = try repo.memberIDs(of: group).count
            print("  " + group.name.padding(toLength: width, withPad: " ", startingAt: 0)
                + Style.dim("  \(count)"))
        }
    }

    // Ordering is best-effort; say which one triage would actually use.
    print("")
    print(Style.dim("Triage order: \(QueueBuilder.ordered(unfiled).orderDescription)"))

    // Other accounts are out of scope, but their size is worth knowing.
    let others = try repo.store.containers(matching: nil).filter { $0.identifier != repo.containerID }
    if !others.isEmpty {
        print("")
        print(Style.bold("Other accounts") + Style.dim(" (not touched)"))
        print(ContactsRepo.describeContainers(others))
    }
}

func runLists(_ repo: ContactsRepo) throws {
    let groups = try repo.groups()
    if groups.isEmpty {
        print(Style.dim("No lists in \"\(repo.containerName)\"."))
        return
    }
    for group in groups { print(group.name) }
}

func runAudit(_ repo: ContactsRepo) throws {
    let groups = try repo.groups()
    let membership = try repo.membershipIndex(groups: groups)
    let contactsByID = Dictionary(uniqueKeysWithValues: try repo.contacts().map { ($0.identifier, $0) })

    let multi = membership.filter { $0.value.count > 1 }
    guard !multi.isEmpty else {
        print(Style.green("Every filed contact is in exactly one list."))
        return
    }

    print(Style.yellow("\(multi.count) contact(s) in more than one list:"))
    for (id, memberships) in multi.sorted(by: { $0.value.count > $1.value.count }) {
        let name = contactsByID[id].map(Render.displayName) ?? id
        print("  \(name)" + Style.dim("  →  " + memberships.map(\.name).joined(separator: ", ")))
    }
}

/// Prints everything needed to diagnose a broken setup in one shot. Each
/// section is independent so a failure early on still lets the rest report.
func runDoctor(containerID: String?) throws {
    print(Style.bold("AddressBook modification dates"))
    let dates = ModificationDates.load()
    print("  keys indexed: \(dates.count)")
    for key in dates.keys.sorted().prefix(2) { print("    sample key: \(key)") }

    print("")
    print(Style.bold("Contacts"))
    do {
        let repo = try ContactsRepo.open(explicitContainerID: containerID)
        print("  account: \(repo.containerName)")
        print("  container: \(repo.containerID)")

        let contacts = try repo.contacts()
        print("  contacts: \(contacts.count)")
        for contact in contacts.prefix(2) {
            print("    sample identifier: \(contact.identifier)")
        }

        // The whole point of this section: does the date join actually land?
        let matched = contacts.filter { dates[$0.identifier] != nil }.count
        let rate = contacts.isEmpty ? 0 : Double(matched) / Double(contacts.count) * 100
        let line = String(format: "  date match: %d/%d (%.0f%%)", matched, contacts.count, rate)
        print(rate >= 50 ? Style.green(line) : Style.red(line))

        let groups = try repo.groups()
        print("  lists: \(groups.count)\(groups.isEmpty ? " — nothing for the picker to show" : "")")
        for group in groups.prefix(5) { print("    - \(group.name)") }
    } catch {
        print(Style.red("  \(error.localizedDescription)"))
    }

    print("")
    print(Style.bold("Picker self-test"))
    print(Style.dim("  type a colour, a number, or :q"))
    switch Picker.prompt(options: ["red", "green", "blue"]) {
    case .list(let index): print(Style.green("  picked #\(index + 1)"))
    case .create(let name): print(Style.green("  would create \"\(name)\""))
    case .skip: print(Style.green("  skip"))
    case .quit: print(Style.green("  quit"))
    case .undo: print(Style.green("  undo"))
    case .open: print(Style.green("  open"))
    case .delete: print(Style.green("  delete"))
    }
}

do {
    try main()
} catch {
    FileHandle.standardError.write(Data(("\n" + Style.red("error: ") + error.localizedDescription + "\n").utf8))
    exit(1)
}
