import Contacts
import Foundation

/// `contacts-organizer wishlist [--review | --export | ignore]`.
func runWishlist(_ repo: ContactsRepo, arguments: [String]) throws {
    if arguments.first == "ignore" {
        guard arguments.count == 1 else { throw AppError("wishlist ignore takes no arguments") }
        try runWishlistIgnore(repo)
        return
    }

    var review = false, export = false
    for argument in arguments {
        switch argument {
        case "--review": review = true
        case "--export": export = true
        default: throw AppError("Unknown wishlist option \"\(argument)\".\n\n\(usage)")
        }
    }
    if review && export { throw AppError("--review and --export cannot be combined") }

    if export {
        try runWishlistExport(repo)
        return
    }

    let groups = try repo.groups()
    let yes = try wishlistGroup(WishlistGroups.yes, in: groups, repo: repo)
    let no = try wishlistGroup(WishlistGroups.no, in: groups, repo: repo)
    let allGroups = try repo.groups()      // re-read: either may be new

    let contacts = try repo.contacts()
    let membership = try repo.membershipIndex(groups: allGroups)
    let yesIDs = try repo.memberIDs(of: yes)
    let noIDs = try repo.memberIDs(of: no)

    let whatsApp = loadWhatsApp()

    var current: [String: CNGroup] = [:]
    for id in noIDs { current[id] = no }
    for id in yesIDs { current[id] = yes }      // Wishlist wins if in both

    let queue: Queue
    if review {
        let decided = WishlistQueue.review(contacts, yes: yesIDs, no: noIDs)
        guard !decided.isEmpty else {
            print(Style.green("Nobody is in \(yes.name) or \(no.name) yet. Run `contacts-organizer wishlist` first."))
            return
        }
        queue = Queue(contacts: decided, orderDescription: "\(yes.name), then \(no.name), by name")
        print(Style.bold("\(decided.count) decided") + Style.dim(" in \"\(repo.containerName)\" · \(queue.orderDescription)"))
    } else {
        let undecided = WishlistQueue.undecided(contacts, decided: yesIDs.union(noIDs))
        let ignore = loadIgnoredGroups(existing: allGroups)
        let (shown, hidden) = WishlistQueue.hidingIgnored(undecided, membership: membership, ignored: ignore.ids)

        if !hidden.isEmpty {
            print(Style.dim("\(hidden.count) contact\(hidden.count == 1 ? "" : "s") hidden by "
                + "\(ignore.ids.count) ignored list\(ignore.ids.count == 1 ? "" : "s")"))
        }
        guard !shown.isEmpty else {
            print(Style.green("Nothing to decide — every contact in \"\(repo.containerName)\" "
                + "is in \(yes.name) or \(no.name)\(hidden.isEmpty ? "" : ", or hidden by the ignore list")."))
            return
        }
        queue = WishlistQueue.ordered(shown, whatsApp: whatsApp)
        print(Style.bold("\(queue.contacts.count) undecided") + Style.dim(" in \"\(repo.containerName)\" · ordered by \(queue.orderDescription)"))
    }

    WishlistWalk(repo: repo, yes: yes, no: no, queue: queue.contacts, current: current) { contact, group in
        let lists = (membership[contact.identifier] ?? [])
            .filter { !WishlistGroups.isReserved($0) }
            .map(\.name)
        return WishlistCard.extras(
            name: Render.displayName(contact),
            lists: lists,
            current: review ? group?.name : nil,
            activity: whatsApp?.activity(for: WishlistQueue.phones(contact)),
            whatsAppAvailable: whatsApp != nil)
    }.run()
}

/// Everyone in Wishlist as CSV on stdout. Warnings go to stderr so the CSV
/// stays clean when redirected.
func runWishlistExport(_ repo: ContactsRepo) throws {
    guard let yes = try repo.groups().first(where: { $0.name == WishlistGroups.yes }) else {
        throw AppError("There is no \"\(WishlistGroups.yes)\" list yet. Run `contacts-organizer wishlist` first.")
    }
    let ids = try repo.memberIDs(of: yes)
    let whatsApp = loadWhatsApp(toStandardError: true)
    let rows = try repo.contacts()
        .filter { ids.contains($0.identifier) }
        .sorted { Render.displayName($0).localizedCaseInsensitiveCompare(Render.displayName($1)) == .orderedAscending }
        .map { WishlistExport.row(name: Render.displayName($0), phones: WishlistQueue.phones($0), whatsApp: whatsApp) }
    print(WishlistExport.csv(rows), terminator: "")
}

/// `wishlist ignore`: tick the lists the walk should never ask about.
func runWishlistIgnore(_ repo: ContactsRepo) throws {
    let lists = WishlistGroups.lists(try repo.groups())
    guard !lists.isEmpty else {
        print(Style.dim("No lists in \"\(repo.containerName)\" to ignore."))
        return
    }
    let path = IgnoreConfig.defaultPath
    let config = try IgnoreConfig.load(path: path)

    let labels = try lists.map { group in "\(group.name)  " + Style.dim("(\(try repo.memberIDs(of: group).count))") }
    let checked = Set(lists.indices.filter { config.groupIDs.contains(lists[$0].identifier) })

    print(Style.bold("Lists the wishlist walk ignores") + Style.dim(" · \(path)"))
    guard let result = Picker.checkboxes(options: labels, checked: checked) else {
        print(Style.dim("  cancelled — nothing saved"))
        return
    }

    // Saving drops identifiers of lists that no longer exist.
    let ids = result.sorted().map { lists[$0].identifier }
    let names = Dictionary(uniqueKeysWithValues: lists.map { ($0.identifier, $0.name) })
    try IgnoreConfig.save(IgnoreConfig(groupIDs: ids), names: names, path: path)

    let chosen = result.sorted().map { lists[$0].name }
    print(Style.green("  saved \(chosen.count) ignored list\(chosen.count == 1 ? "" : "s")")
        + (chosen.isEmpty ? "" : Style.dim(": " + chosen.joined(separator: ", "))))
}

/// The wishlist lines of `stats`. Never creates the groups.
func printWishlistStats(_ repo: ContactsRepo, allGroups: [CNGroup], contacts: [CNContact],
                        listMembership: [String: [CNGroup]]) throws {
    let yes = allGroups.first { $0.name == WishlistGroups.yes }
    let no = allGroups.first { $0.name == WishlistGroups.no }
    let yesIDs = try yes.map(repo.memberIDs(of:)) ?? []
    let noIDs = try no.map(repo.memberIDs(of:)) ?? []

    let undecided = WishlistQueue.undecided(contacts, decided: yesIDs.union(noIDs))
    let ignore = loadIgnoredGroups(existing: allGroups)
    let (_, hidden) = WishlistQueue.hidingIgnored(undecided, membership: listMembership, ignored: ignore.ids)

    print("")
    print(Style.bold("Wishlist"))
    print("  \(WishlistGroups.yes):    \(yesIDs.count)")
    print("  \(WishlistGroups.no): \(noIDs.count)")
    print("  undecided:   \(undecided.count - hidden.count)")
    if !hidden.isEmpty {
        print("  hidden:      \(hidden.count)" + Style.dim("  by \(ignore.ids.count) ignored list\(ignore.ids.count == 1 ? "" : "s")"))
    }
}

// MARK: - Helpers

/// Finds a wishlist group by exact name, creating it on first use.
private func wishlistGroup(_ name: String, in groups: [CNGroup], repo: ContactsRepo) throws -> CNGroup {
    let matches = groups.filter { $0.name == name }
    if matches.count > 1 {
        print(Style.yellow("\(matches.count) lists are named \"\(name)\"; using the first. Merge them in Contacts.app."))
    }
    if let found = matches.first { return found }
    let created = try repo.createGroup(named: name)
    print(Style.dim("created list \"\(name)\""))
    return created
}

/// wacli's store, or nil with one line saying why the order falls back.
private func loadWhatsApp(toStandardError: Bool = false) -> WhatsAppStore? {
    func warn(_ text: String) {
        if toStandardError {
            FileHandle.standardError.write(Data((text + "\n").utf8))
        } else {
            print(Style.yellow(text))
        }
    }
    switch WhatsAppStore.load() {
    case .success(let store):
        for warning in store.warnings { warn("whatsapp: \(warning)") }
        return store
    case .failure(let error):
        warn("whatsapp: \(error.message); falling back to the triage order")
        return nil
    }
}

/// Ignored group identifiers that still exist; warns once about the rest.
/// A broken config file warns and ignores nothing rather than stopping.
private func loadIgnoredGroups(existing groups: [CNGroup]) -> (ids: Set<String>, missing: [String]) {
    let config: IgnoreConfig
    do {
        config = try IgnoreConfig.load()
    } catch {
        print(Style.yellow("ignore list not used: \(error.localizedDescription)"))
        return ([], [])
    }
    let known = Set(groups.filter { !WishlistGroups.isReserved($0) }.map(\.identifier))
    let missing = config.groupIDs.filter { !known.contains($0) }
    if !missing.isEmpty {
        print(Style.yellow("\(missing.count) ignored list\(missing.count == 1 ? " no longer exists" : "s no longer exist")"
            + "; run `contacts-organizer wishlist ignore` to tidy the config"))
    }
    return (Set(config.groupIDs).intersection(known), missing)
}
