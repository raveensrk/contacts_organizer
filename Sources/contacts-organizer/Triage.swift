import Contacts
import Foundation

final class Triage {
    private let repo: ContactsRepo
    private var groups: [CNGroup]
    private var queue: [CNContact]
    private var position = 0

    /// The one assignment `:u` can walk back.
    private var lastAssignment: (contact: CNContact, group: CNGroup)?

    private var filed = 0
    private var skipped = 0
    private var deleted = 0
    private var created: [String] = []

    init(repo: ContactsRepo, groups: [CNGroup], queue: [CNContact]) {
        self.repo = repo
        self.groups = groups
        self.queue = queue
    }

    func run() throws {
        print(Style.dim("enter skip · :u undo · :o open · :d delete · :q quit · :? help"))

        loop: while position < queue.count {
            let contact = queue[position]
            print(Render.card(contact, position: position + 1, total: queue.count))

            let choice = Picker.prompt(options: displayNames())

            // One failing record (a smart list rejecting a member, a sync
            // hiccup) should cost that contact, not the whole session.
            do {
                switch choice {
                case .quit:
                    break loop

                case .skip:
                    skipped += 1
                    print(Style.dim("  skipped"))
                    position += 1

                case .list(let index):
                    try file(contact, into: groups[index])

                case .create(let name):
                    try createAndFile(contact, listName: name)

                case .undo:
                    try undo()

                case .open:
                    // Punt to the GUI, then re-show the contact so it can still be filed.
                    if !Shell.open("addressbook://\(contact.identifier)") {
                        print(Style.yellow("  could not open Contacts.app for this record"))
                    } else {
                        print(Style.dim("  opened in Contacts.app"))
                    }

                case .delete:
                    try deleteCurrent(contact)
                }
            } catch {
                print(Style.red("  failed: \(error.localizedDescription)"))
                print(Style.dim("  re-showing — press enter to move past this one"))
            }
        }

        printSummary()
    }

    // MARK: - Actions

    private func file(_ contact: CNContact, into group: CNGroup) throws {
        try repo.addMember(contact, to: group)
        lastAssignment = (contact, group)
        filed += 1
        print(Style.green("  → \(group.name)"))
        position += 1
    }

    private func createAndFile(_ contact: CNContact, listName: String) throws {
        // Confirm, so a typo cannot quietly create a junk list that syncs to the phone.
        guard Prompt.confirm("  Create new list \(Style.bold("\"\(listName)\""))?") else {
            print(Style.dim("  cancelled"))
            return
        }
        let group = try repo.createGroup(named: listName)
        groups = try repo.groups()
        created.append(listName)
        try repo.addMember(contact, to: group)
        lastAssignment = (contact, group)
        filed += 1
        print(Style.green("  → \(group.name) (new list)"))
        position += 1
    }

    private func undo() throws {
        guard let last = lastAssignment else {
            print(Style.dim("  nothing to undo"))
            return
        }
        try repo.removeMember(last.contact, from: last.group)
        lastAssignment = nil
        filed -= 1
        // Re-queue it as the very next contact, wherever we happen to be now.
        queue.insert(last.contact, at: position)
        print(Style.yellow("  undid \(Render.displayName(last.contact)) → \(last.group.name)"))
    }

    private func deleteCurrent(_ contact: CNContact) throws {
        let name = Render.displayName(contact)
        print(Style.red("  Deleting \(name) removes it from iCloud and every synced device."))
        guard Prompt.confirm("  Delete \(Style.bold(name))? This cannot be undone.") else {
            print(Style.dim("  cancelled"))
            return
        }
        try repo.delete(contact)
        deleted += 1
        if lastAssignment?.contact.identifier == contact.identifier { lastAssignment = nil }
        print(Style.red("  deleted"))
        position += 1
    }

    // MARK: - Lists

    /// List names as shown, disambiguated if two lists share a name.
    private func displayNames() -> [String] {
        var counts: [String: Int] = [:]
        for group in groups { counts[group.name, default: 0] += 1 }
        return groups.map { group in
            counts[group.name, default: 0] > 1
                ? "\(group.name) [\(group.identifier.prefix(6))]"
                : group.name
        }
    }

    private func printSummary() {
        print("")
        print(Style.bold("Done."))
        print("  filed:   \(filed)")
        print("  skipped: \(skipped)")
        if deleted > 0 { print("  deleted: \(deleted)") }
        if !created.isEmpty { print("  new lists: \(created.joined(separator: ", "))") }
        let remaining = max(0, queue.count - position)
        if remaining > 0 { print(Style.dim("  \(remaining) still unfiled — re-run to continue")) }
    }
}
