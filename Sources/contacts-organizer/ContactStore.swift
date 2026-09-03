import Contacts
import Foundation

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Keys fetched for every contact.
///
/// Deliberately excludes `CNContactNoteKey`: since macOS 11 it requires an
/// Apple-granted entitlement (`com.apple.developer.contacts.notes`), and a
/// self-signed binary that asks for it gets a throwing fetch instead of a note.
let contactKeys: [CNKeyDescriptor] = {
    let stringKeys: [String] = [
        CNContactIdentifierKey,
        CNContactGivenNameKey,
        CNContactMiddleNameKey,
        CNContactFamilyNameKey,
        CNContactNicknameKey,
        CNContactOrganizationNameKey,
        CNContactJobTitleKey,
        CNContactDepartmentNameKey,
        CNContactPhoneNumbersKey,
        CNContactEmailAddressesKey,
        CNContactPostalAddressesKey,
        CNContactUrlAddressesKey,
        CNContactBirthdayKey,
        CNContactTypeKey,
    ]
    return stringKeys.map { $0 as CNKeyDescriptor }
        + [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
}()

/// Just enough to identify a contact when computing set membership.
private let idOnlyKeys: [CNKeyDescriptor] = [CNContactIdentifierKey as CNKeyDescriptor]

final class ContactsRepo {
    let store = CNContactStore()
    let containerID: String
    let containerName: String

    private init(containerID: String, containerName: String) {
        self.containerID = containerID
        self.containerName = containerName
    }

    // MARK: - Setup

    /// Requests Contacts access, blocking until the user answers the TCC prompt.
    ///
    /// TCC attributes the request to the *responsible* app — the terminal
    /// emulator running this binary, not the binary itself. A standing denial
    /// for that app suppresses the prompt entirely, which reads as a bare
    /// "Access Denied", so the guidance below names the real fix.
    static func requestAccess() throws {
        let store = CNContactStore()
        if isBlocked(CNContactStore.authorizationStatus(for: .contacts)) {
            throw accessDenied(CNContactStore.authorizationStatus(for: .contacts))
        }

        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        var failure: Error?
        store.requestAccess(for: .contacts) { ok, error in
            granted = ok
            failure = error
            semaphore.signal()
        }
        semaphore.wait()
        if granted { return }

        // The status often only turns denied once the request has been refused.
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if isBlocked(status) { throw accessDenied(status) }
        if let failure { throw AppError("Contacts access failed: \(failure.localizedDescription)") }
        throw AppError("Contacts access was not granted.")
    }

    private static func isBlocked(_ status: CNAuthorizationStatus) -> Bool {
        status == .denied || status == .restricted
    }

    private static func accessDenied(_ status: CNAuthorizationStatus) -> AppError {
        AppError("""
            Contacts access is \(describe(status)) for the app running this command.

            macOS grants Contacts access to the terminal app, not to this binary.
            Open System Settings > Privacy & Security > Contacts and switch on the
            terminal you are running from, then try again.

            If the terminal is not listed, run this once to clear the stale decision:
              tccutil reset AddressBook
            """)
    }

    private static func describe(_ status: CNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .limited: return "limited"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    /// Resolves the iCloud container. Non-iCloud accounts (Google, Exchange,
    /// local) are out of scope: macOS cannot reliably edit their groups.
    static func open(explicitContainerID: String?) throws -> ContactsRepo {
        try requestAccess()
        let store = CNContactStore()
        let containers = try store.containers(matching: nil)

        if let explicitContainerID {
            guard let match = containers.first(where: { $0.identifier == explicitContainerID }) else {
                throw AppError("No container with identifier \(explicitContainerID).\n"
                    + describeContainers(containers))
            }
            return ContactsRepo(containerID: match.identifier, containerName: match.name)
        }

        let cardDAV = containers.filter { $0.type == .cardDAV }
        if cardDAV.isEmpty {
            throw AppError("No iCloud (CardDAV) container found.\n" + describeContainers(containers))
        }
        if cardDAV.count == 1 {
            return ContactsRepo(containerID: cardDAV[0].identifier, containerName: cardDAV[0].name)
        }
        // Several CardDAV accounts: prefer an obvious iCloud one rather than guessing.
        if let icloud = cardDAV.first(where: { $0.name.lowercased().contains("icloud") }) {
            return ContactsRepo(containerID: icloud.identifier, containerName: icloud.name)
        }
        throw AppError("Multiple CardDAV containers found; pass --container <id> to choose.\n"
            + describeContainers(cardDAV))
    }

    static func describeContainers(_ containers: [CNContainer]) -> String {
        containers.map { "  [\(typeName($0.type))] \"\($0.name)\"  \($0.identifier)" }
            .joined(separator: "\n")
    }

    static func typeName(_ type: CNContainerType) -> String {
        switch type {
        case .local: return "local"
        case .exchange: return "exchange"
        case .cardDAV: return "cardDAV"
        case .unassigned: return "unassigned"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Reads

    /// All contacts in the container.
    ///
    /// `unifyResults = false` matters: unified contacts merge linked records
    /// across accounts and carry a synthesized identifier, which cannot be
    /// passed to `CNSaveRequest.addMember`.
    func contacts() throws -> [CNContact] {
        try fetch(predicate: CNContact.predicateForContactsInContainer(withIdentifier: containerID),
                  keys: contactKeys)
    }

    func groups() throws -> [CNGroup] {
        try store.groups(matching: CNGroup.predicateForGroupsInContainer(withIdentifier: containerID))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func memberIDs(of group: CNGroup) throws -> Set<String> {
        let members = try fetch(
            predicate: CNContact.predicateForContactsInGroup(withIdentifier: group.identifier),
            keys: idOnlyKeys)
        return Set(members.map(\.identifier))
    }

    /// Identifier -> the groups it belongs to, across the whole container.
    func membershipIndex(groups: [CNGroup]) throws -> [String: [CNGroup]] {
        var index: [String: [CNGroup]] = [:]
        for group in groups {
            for id in try memberIDs(of: group) {
                index[id, default: []].append(group)
            }
        }
        return index
    }

    private func fetch(predicate: NSPredicate, keys: [CNKeyDescriptor]) throws -> [CNContact] {
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.predicate = predicate
        request.unifyResults = false
        var results: [CNContact] = []
        try store.enumerateContacts(with: request) { contact, _ in results.append(contact) }
        return results
    }

    // MARK: - Writes

    func addMember(_ contact: CNContact, to group: CNGroup) throws {
        let request = CNSaveRequest()
        request.addMember(contact, to: group)
        try store.execute(request)
    }

    func removeMember(_ contact: CNContact, from group: CNGroup) throws {
        let request = CNSaveRequest()
        request.removeMember(contact, from: group)
        try store.execute(request)
    }

    func createGroup(named name: String) throws -> CNGroup {
        let group = CNMutableGroup()
        group.name = name
        let request = CNSaveRequest()
        request.add(group, toContainerWithIdentifier: containerID)
        try store.execute(request)

        // Re-fetch so callers get a saved group whose identifier the store knows.
        guard let saved = try groups().first(where: { $0.identifier == group.identifier })
            ?? groups().first(where: { $0.name == name }) else {
            throw AppError("Created list \"\(name)\" but could not read it back.")
        }
        return saved
    }

    func delete(_ contact: CNContact) throws {
        guard let mutable = contact.mutableCopy() as? CNMutableContact else {
            throw AppError("Could not prepare \(contact.identifier) for deletion.")
        }
        let request = CNSaveRequest()
        request.delete(mutable)
        try store.execute(request)
    }
}
