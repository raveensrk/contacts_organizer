import Contacts
import Foundation

/// The two iCloud groups the wishlist pass files into. They hold a decision,
/// not a category, so triage, its picker and `audit` look straight past them.
enum WishlistGroups {
    static let yes = "Wishlist"
    static let no = "No Wishlist"
    static let names = [yes, no]

    static func isReserved(_ group: CNGroup) -> Bool { isReserved(name: group.name) }
    static func isReserved(name: String) -> Bool {
        names.contains { $0.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    /// Groups that count as lists for triage, stats and audit.
    static func lists(_ groups: [CNGroup]) -> [CNGroup] { groups.filter { !isReserved($0) } }
}

/// Which contacts the wishlist walk shows, and in what order. Pure value
/// logic over contacts, memberships and WhatsApp activity.
enum WishlistQueue {

    /// Contacts in neither Wishlist nor No Wishlist.
    static func undecided(_ contacts: [CNContact], decided: Set<String>) -> [CNContact] {
        contacts.filter { !decided.contains($0.identifier) }
    }

    /// Splits off contacts in any ignored group. A contact in an ignored group
    /// is hidden even when it is also in a group that is not ignored.
    static func hidingIgnored(_ contacts: [CNContact], membership: [String: [CNGroup]],
                              ignored: Set<String>) -> (shown: [CNContact], hidden: [CNContact]) {
        guard !ignored.isEmpty else { return (contacts, []) }
        var shown: [CNContact] = [], hidden: [CNContact] = []
        for contact in contacts {
            let groups = membership[contact.identifier] ?? []
            if groups.contains(where: { ignored.contains($0.identifier) }) {
                hidden.append(contact)
            } else {
                shown.append(contact)
            }
        }
        return (shown, hidden)
    }

    /// Most recent WhatsApp chat first, then everyone with no chat by name.
    /// Without a WhatsApp store, the triage order stands in.
    static func ordered(_ contacts: [CNContact], whatsApp: WhatsAppStore?) -> Queue {
        guard let whatsApp else { return QueueBuilder.ordered(contacts) }

        var chatted: [(CNContact, Date)] = []
        var rest: [CNContact] = []
        for contact in contacts {
            if let date = whatsApp.activity(for: phones(contact))?.lastChat {
                chatted.append((contact, date))
            } else {
                rest.append(contact)
            }
        }
        chatted.sort { lhs, rhs in
            lhs.1 == rhs.1 ? byName(lhs.0, rhs.0) : lhs.1 > rhs.1
        }
        rest.sort(by: byName)
        return Queue(contacts: chatted.map(\.0) + rest,
                     orderDescription: "latest WhatsApp chat first (\(chatted.count) with a chat)")
    }

    /// Everyone already decided, for `--review`: Wishlist first, then No
    /// Wishlist, each by name.
    static func review(_ contacts: [CNContact], yes: Set<String>, no: Set<String>) -> [CNContact] {
        let inYes = contacts.filter { yes.contains($0.identifier) }.sorted(by: byName)
        let inNo = contacts.filter { no.contains($0.identifier) && !yes.contains($0.identifier) }.sorted(by: byName)
        return inYes + inNo
    }

    static func phones(_ contact: CNContact) -> [String] {
        contact.phoneNumbers.map { $0.value.stringValue }
    }

    private static func byName(_ lhs: CNContact, _ rhs: CNContact) -> Bool {
        Render.displayName(lhs).localizedCaseInsensitiveCompare(Render.displayName(rhs)) == .orderedAscending
    }
}

/// The lines added under a contact's card in the wishlist walk.
enum WishlistCard {

    static func extras(name: String, lists: [String], current: String?,
                       activity: WhatsAppActivity?, whatsAppAvailable: Bool,
                       now: Date = Date()) -> [String] {
        var lines: [String] = []
        if let current { lines.append(field("now in", current)) }
        if !lists.isEmpty { lines.append(field("in", lists.joined(separator: ", "))) }

        guard whatsAppAvailable else { return lines }
        if let date = activity?.lastChat {
            lines.append(field("whatsapp", "last chat " + relative(date, now: now)))
        } else {
            lines.append(field("whatsapp", "no chat found"))
        }
        if let whatsAppName = activity?.whatsAppName,
           whatsAppName.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame {
            lines.append(field("wa name", whatsAppName))
        }
        if activity?.wishedLastDiwali == true {
            lines.append(field("diwali", "you messaged them around last Diwali"))
        }
        return lines
    }

    /// "today", "yesterday", "12 days ago", "4 months ago", "2 years ago".
    static func relative(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        case 2..<60: return "\(days) days ago"
        case 60..<730: return "\(days / 30) months ago"
        default: return "\(days / 365) years ago"
        }
    }

    private static func field(_ name: String, _ value: String) -> String {
        "  " + Style.dim(name.padding(toLength: max(10, name.count), withPad: " ", startingAt: 0)) + "  " + value
    }
}

/// `wishlist --export`: everyone in Wishlist as CSV.
enum WishlistExport {

    struct Row: Equatable {
        let name: String
        let phone: String
        let whatsApp: String
    }

    /// The number to message: the first one WhatsApp knows, else the first
    /// one saved, in +country form.
    static func row(name: String, phones: [String], whatsApp: WhatsAppStore?) -> Row {
        let normalized = phones.compactMap { PhoneNumber.normalize($0) }
        guard let whatsApp else {
            return Row(name: name, phone: normalized.first.map { "+" + $0 } ?? "", whatsApp: "unknown")
        }
        if let known = normalized.first(where: { whatsApp.byPhone[$0] != nil }) {
            return Row(name: name, phone: "+" + known, whatsApp: "yes")
        }
        return Row(name: name, phone: normalized.first.map { "+" + $0 } ?? "", whatsApp: "no")
    }

    static func csv(_ rows: [Row]) -> String {
        (["name,phone,whatsapp"] + rows.map { [$0.name, $0.phone, $0.whatsApp].map(quote).joined(separator: ",") })
            .joined(separator: "\n") + "\n"
    }

    private static func quote(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// The interactive walk: one contact at a time, Wishlist or No Wishlist.
final class WishlistWalk {
    private let repo: ContactsRepo
    private let yes: CNGroup
    private let no: CNGroup
    private var queue: [CNContact]
    private var position = 0
    private let extras: (CNContact, CNGroup?) -> [String]

    /// The group each contact sits in right now, for review and undo.
    private var current: [String: CNGroup]

    private var lastAssignment: (contact: CNContact, group: CNGroup, previous: CNGroup?)?

    private var counts: [String: Int] = [:]
    private var skipped = 0
    private var deleted = 0

    init(repo: ContactsRepo, yes: CNGroup, no: CNGroup, queue: [CNContact],
         current: [String: CNGroup], extras: @escaping (CNContact, CNGroup?) -> [String]) {
        self.repo = repo
        self.yes = yes
        self.no = no
        self.queue = queue
        self.current = current
        self.extras = extras
    }

    func run() {
        loop: while position < queue.count {
            let contact = queue[position]
            var card = Render.card(contact, position: position + 1, total: queue.count)
            let lines = extras(contact, current[contact.identifier])
            if !lines.isEmpty { card += "\n" + lines.joined(separator: "\n") }
            print(card)

            let choice = Picker.prompt(options: [yes.name, no.name], allowCreate: false)

            do {
                switch choice {
                case .quit:
                    break loop
                case .skip:
                    skipped += 1
                    print(Style.dim("  skipped"))
                    position += 1
                case .list(let index):
                    try choose(contact, index == 0 ? yes : no)
                case .create:
                    // The picker never offers it here; treat it as a no-op.
                    continue
                case .undo:
                    try undo()
                case .open:
                    if Shell.open("addressbook://\(contact.identifier)") {
                        print(Style.dim("  opened in Contacts.app"))
                    } else {
                        print(Style.yellow("  could not open Contacts.app for this record"))
                    }
                case .delete:
                    try deleteCurrent(contact)
                }
            } catch {
                print(Style.red("  failed: \(error.localizedDescription)"))
                print(Style.dim("  re-showing — ctrl-s moves past this one"))
            }
        }
        printSummary()
    }

    private func choose(_ contact: CNContact, _ group: CNGroup) throws {
        let previous = current[contact.identifier]
        if previous?.identifier == group.identifier {
            print(Style.dim("  already in \(group.name)"))
            position += 1
            return
        }
        var byContactsApp = try repo.addMember(contact, to: group)
        if let previous {
            byContactsApp = try repo.removeMember(contact, from: previous) || byContactsApp
        }
        current[contact.identifier] = group
        lastAssignment = (contact, group, previous)
        counts[group.name, default: 0] += 1
        let moved = previous.map { " (was \($0.name))" } ?? ""
        print(Style.green("  → \(group.name)\(moved)") + contactsAppNote(byContactsApp))
        position += 1
    }

    private func undo() throws {
        guard let last = lastAssignment else {
            print(Style.dim("  nothing to undo"))
            return
        }
        var byContactsApp = try repo.removeMember(last.contact, from: last.group)
        if let previous = last.previous {
            byContactsApp = try repo.addMember(last.contact, to: previous) || byContactsApp
            current[last.contact.identifier] = previous
        } else {
            current[last.contact.identifier] = nil
        }
        counts[last.group.name, default: 1] -= 1
        lastAssignment = nil
        queue.insert(last.contact, at: position)
        print(Style.yellow("  undid \(Render.displayName(last.contact)) → \(last.group.name)")
            + contactsAppNote(byContactsApp))
    }

    private func deleteCurrent(_ contact: CNContact) throws {
        let name = Render.displayName(contact)
        print(Style.red("  Deleting \(name) removes it from iCloud and every synced device."))
        guard Prompt.confirm("  Delete \(Style.bold(name))? This cannot be undone.") else {
            print(Style.dim("  cancelled"))
            return
        }
        let byContactsApp = try repo.delete(contact)
        deleted += 1
        if lastAssignment?.contact.identifier == contact.identifier { lastAssignment = nil }
        print(Style.red("  deleted") + contactsAppNote(byContactsApp))
        position += 1
    }

    private func contactsAppNote(_ byContactsApp: Bool) -> String {
        byContactsApp ? Style.dim("  (via Contacts.app: this card has a note)") : ""
    }

    private func printSummary() {
        print("")
        print(Style.bold("Done."))
        print("  \(yes.name): \(counts[yes.name, default: 0])")
        print("  \(no.name): \(counts[no.name, default: 0])")
        print("  skipped: \(skipped)")
        if deleted > 0 { print("  deleted: \(deleted)") }
        let remaining = max(0, queue.count - position)
        if remaining > 0 { print(Style.dim("  \(remaining) not shown yet — re-run to continue")) }
    }
}
