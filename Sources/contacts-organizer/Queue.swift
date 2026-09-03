import Contacts
import Foundation

struct Queue {
    let contacts: [CNContact]
    /// Human description of the ordering actually used, for the banner.
    let orderDescription: String
}

enum QueueBuilder {

    /// Contacts in the container that belong to no group. This is the whole
    /// point of the tool: "in no list" is the inbox.
    static func unfiled(contacts: [CNContact], membership: [String: [CNGroup]]) -> [CNContact] {
        contacts.filter { membership[$0.identifier] == nil }
    }

    /// Most-recently-modified first, per the tool's design.
    ///
    /// The dates come from the undocumented AddressBook Core Data schema, so
    /// this verifies it actually matched before trusting it; a poor match rate
    /// means the schema moved and alphabetical is the honest ordering.
    static func ordered(_ contacts: [CNContact]) -> Queue {
        guard !contacts.isEmpty else { return Queue(contacts: [], orderDescription: "empty") }

        let dates = ModificationDates.load()
        let matched = contacts.filter { dates[$0.identifier] != nil }.count
        let matchRate = Double(matched) / Double(contacts.count)

        guard matchRate >= 0.5 else {
            let sorted = contacts.sorted {
                Render.displayName($0).localizedCaseInsensitiveCompare(Render.displayName($1)) == .orderedAscending
            }
            let reason = dates.isEmpty
                ? "modification dates unavailable"
                : String(format: "only %.0f%% of contacts matched the AddressBook store", matchRate * 100)
            return Queue(contacts: sorted, orderDescription: "name (\(reason))")
        }

        let sorted = contacts.sorted { lhs, rhs in
            let l = dates[lhs.identifier] ?? .distantPast
            let r = dates[rhs.identifier] ?? .distantPast
            if l == r {
                return Render.displayName(lhs).localizedCaseInsensitiveCompare(Render.displayName(rhs)) == .orderedAscending
            }
            return l > r
        }
        return Queue(contacts: sorted, orderDescription: "most recently modified first")
    }
}
