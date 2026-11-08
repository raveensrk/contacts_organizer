import Contacts
import XCTest
@testable import contacts_organizer

/// Which contacts the wishlist walk shows, in what order, and what export
/// prints. Contacts and groups exist only in memory.
final class WishlistTests: XCTestCase {

    private func contact(_ given: String, phones: [String] = []) -> CNContact {
        let contact = CNMutableContact()
        contact.givenName = given
        contact.phoneNumbers = phones.map { CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: $0)) }
        return contact
    }

    private func group(_ name: String) -> CNGroup {
        let group = CNMutableGroup()
        group.name = name
        return group
    }

    private func store(_ entries: [String: WhatsAppActivity]) -> WhatsAppStore {
        WhatsAppStore(byPhone: entries, warnings: [])
    }

    // MARK: - Reserved groups

    func testWishlistGroupsAreNotLists() {
        let groups = [group("Family"), group("Wishlist"), group("No Wishlist"), group("no wishlist")]
        XCTAssertEqual(WishlistGroups.lists(groups).map(\.name), ["Family"])
    }

    /// A contact whose only group is Wishlist still needs triage.
    func testWishlistMembershipDoesNotFileForTriage() {
        let only = contact("Only")
        let lists = WishlistGroups.lists([group("Wishlist")])
        var membership: [String: [CNGroup]] = [:]
        for g in lists { membership[only.identifier, default: []].append(g) }
        XCTAssertEqual(QueueBuilder.unfiled(contacts: [only], membership: membership).count, 1)
    }

    // MARK: - Undecided and ignored

    func testUndecidedLeavesOutBothGroups() {
        let a = contact("A"), b = contact("B"), c = contact("C")
        let undecided = WishlistQueue.undecided([a, b, c], decided: [a.identifier, b.identifier])
        XCTAssertEqual(undecided.map(\.identifier), [c.identifier])
    }

    func testAnIgnoredGroupHidesEvenWithAKeptGroup() {
        let work = group("Work"), family = group("Family")
        let both = contact("Both"), kept = contact("Kept"), loose = contact("Loose"), ignored = contact("Ignored")
        let membership = [
            both.identifier: [family, work],
            kept.identifier: [family],
            ignored.identifier: [work],
        ]
        let (shown, hidden) = WishlistQueue.hidingIgnored(
            [both, kept, loose, ignored], membership: membership, ignored: [work.identifier])
        XCTAssertEqual(Set(shown.map(\.identifier)), [kept.identifier, loose.identifier], "unfiled is still asked")
        XCTAssertEqual(Set(hidden.map(\.identifier)), [both.identifier, ignored.identifier])
    }

    func testNoIgnoreListHidesNothing() {
        let a = contact("A")
        XCTAssertEqual(WishlistQueue.hidingIgnored([a], membership: [:], ignored: []).hidden.count, 0)
    }

    // MARK: - Order

    func testLatestChatFirstThenTheRestByName() {
        let old = contact("Old", phones: ["+91 98000 00001"])
        let recent = contact("Recent", phones: ["98000 00002"])
        let zed = contact("Zed"), amy = contact("Amy", phones: ["+1 555 000 0000"])
        let whatsApp = store([
            "919800000001": WhatsAppActivity(lastChat: Date(timeIntervalSince1970: 1_000)),
            "919800000002": WhatsAppActivity(lastChat: Date(timeIntervalSince1970: 2_000)),
        ])
        let queue = WishlistQueue.ordered([zed, old, amy, recent], whatsApp: whatsApp)
        XCTAssertEqual(queue.contacts.map(\.givenName), ["Recent", "Old", "Amy", "Zed"])
        XCTAssertTrue(queue.orderDescription.contains("2 with a chat"), queue.orderDescription)
    }

    func testWithoutWhatsAppTheTriageOrderStandsIn() {
        let queue = WishlistQueue.ordered([contact("Zoe"), contact("Adam")], whatsApp: nil)
        XCTAssertEqual(queue.contacts.map(\.givenName), ["Adam", "Zoe"])
        XCTAssertTrue(queue.orderDescription.hasPrefix("name"), queue.orderDescription)
    }

    func testReviewShowsWishlistFirstAndOnlyDecided() {
        let a = contact("Ann"), b = contact("Bob"), c = contact("Cat"), d = contact("Dan")
        let review = WishlistQueue.review([d, c, b, a], yes: [c.identifier, a.identifier], no: [b.identifier])
        XCTAssertEqual(review.map(\.givenName), ["Ann", "Cat", "Bob"])
    }

    // MARK: - Card

    func testCardExtras() {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 12))!
        let lastChat = Calendar.current.date(byAdding: .day, value: -3, to: now)!
        let lines = WishlistCard.extras(
            name: "Asha", lists: ["Family", "Work"], current: "Wishlist",
            activity: WhatsAppActivity(lastChat: lastChat, whatsAppName: "Asha K", wishedLastDiwali: true),
            whatsAppAvailable: true, now: now)
        let text = lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("Wishlist"))
        XCTAssertTrue(text.contains("Family, Work"))
        XCTAssertTrue(text.contains("last chat 3 days ago"))
        XCTAssertTrue(text.contains("Asha K"))
        XCTAssertTrue(text.contains("last Diwali"))
    }

    func testCardHidesASameWhatsAppNameAndSaysNoChat() {
        let lines = WishlistCard.extras(
            name: "Asha", lists: [], current: nil,
            activity: WhatsAppActivity(whatsAppName: "asha"), whatsAppAvailable: true)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("no chat found"))
        XCTAssertTrue(WishlistCard.extras(name: "A", lists: [], current: nil, activity: nil,
                                          whatsAppAvailable: false).isEmpty)
    }

    func testRelativeDates() {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 12))!
        let ago = { (days: Int) in Calendar.current.date(byAdding: .day, value: -days, to: now)! }
        XCTAssertEqual(WishlistCard.relative(ago(0), now: now), "today")
        XCTAssertEqual(WishlistCard.relative(ago(1), now: now), "yesterday")
        XCTAssertEqual(WishlistCard.relative(ago(12), now: now), "12 days ago")
        XCTAssertEqual(WishlistCard.relative(ago(120), now: now), "4 months ago")
        XCTAssertEqual(WishlistCard.relative(ago(800), now: now), "2 years ago")
    }

    // MARK: - Export

    func testExportPrefersTheNumberWhatsAppKnows() {
        let whatsApp = store(["919800000002": WhatsAppActivity()])
        let row = WishlistExport.row(name: "Asha", phones: ["080 1234 5678", "98000 00002"], whatsApp: whatsApp)
        XCTAssertEqual(row, .init(name: "Asha", phone: "+919800000002", whatsApp: "yes"))

        let unknown = WishlistExport.row(name: "Bo", phones: ["98000 00009"], whatsApp: whatsApp)
        XCTAssertEqual(unknown, .init(name: "Bo", phone: "+919800000009", whatsApp: "no"))

        let noStore = WishlistExport.row(name: "Cy", phones: [], whatsApp: nil)
        XCTAssertEqual(noStore, .init(name: "Cy", phone: "", whatsApp: "unknown"))
    }

    func testCSVQuotesOnlyWhatNeedsIt() {
        let csv = WishlistExport.csv([
            .init(name: "Plain", phone: "+1", whatsApp: "yes"),
            .init(name: "Doe, \"JD\"", phone: "+2", whatsApp: "no"),
        ])
        XCTAssertEqual(csv, "name,phone,whatsapp\nPlain,+1,yes\n\"Doe, \"\"JD\"\"\",+2,no\n")
    }

    // MARK: - Ignore picker

    private func send(_ events: [KeyEvent], to model: inout CheckboxModel) -> CheckboxModel.Outcome? {
        for event in events { if let outcome = model.apply(event) { return outcome } }
        return nil
    }

    func testSpaceTogglesAndEnterSaves() {
        var m = CheckboxModel(options: ["Work", "Family", "Clients"], checked: [2])
        XCTAssertEqual(send([.char(" "), .down, .char(" "), .down, .char(" "), .enter], to: &m), .save([0, 1]))
    }

    func testFilterThenTick() {
        var m = CheckboxModel(options: ["Work", "Family", "Clients"], checked: [])
        XCTAssertEqual(send("fam".map { .char($0) } + [.char(" "), .enter], to: &m), .save([1]))
    }

    func testEscapeCancels() {
        var m = CheckboxModel(options: ["Work"], checked: [])
        XCTAssertEqual(send([.char(" "), .escape], to: &m), .cancel)
        var q = CheckboxModel(options: ["Work"], checked: [])
        XCTAssertEqual(send([.quit], to: &q), .cancel)
    }

    func testOutOfRangeTicksAreDropped() {
        XCTAssertEqual(CheckboxModel(options: ["Work"], checked: [0, 5]).checked, [0])
    }

    func testCheckboxFrameFitsAndCountsRows() {
        let model = CheckboxModel(options: (1...40).map { "List \($0) " + String(repeating: "x", count: 200) }, checked: [0])
        setenv("COLUMNS", "80", 1)
        setenv("LINES", "24", 1)
        defer { unsetenv("COLUMNS"); unsetenv("LINES") }

        let frame = InteractivePicker.checkboxFrame(model, clearing: 0)
        var terminal = TerminalSimulator()
        terminal.feed(frame.text)
        XCTAssertLessThan(terminal.widestRow, 80, "a row that reaches the width wraps")
        XCTAssertEqual(frame.text.components(separatedBy: "\n").count, frame.rows)
        XCTAssertTrue(frame.text.contains("[x]"))
    }
}
