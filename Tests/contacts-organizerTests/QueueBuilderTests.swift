import Contacts
import XCTest
@testable import contacts_organizer

/// "Unfiled" is the whole premise of the tool: a contact in no group is a
/// contact that still needs triaging.
final class QueueBuilderTests: XCTestCase {

    private func contact(_ given: String) -> CNContact {
        let contact = CNMutableContact()
        contact.givenName = given
        return contact
    }

    private func group(_ name: String) -> CNGroup {
        let group = CNMutableGroup()
        group.name = name
        return group
    }

    func testUnfiledKeepsOnlyContactsInNoGroup() {
        let filed = contact("Filed")
        let alsoFiled = contact("Also Filed")
        let loose = contact("Loose")
        let work = group("Work")

        let unfiled = QueueBuilder.unfiled(
            contacts: [filed, alsoFiled, loose],
            membership: [filed.identifier: [work], alsoFiled.identifier: [work]])

        XCTAssertEqual(unfiled.map(\.identifier), [loose.identifier])
    }

    func testEverythingIsUnfiledWhenNoGroupsExist() {
        let contacts = [contact("A"), contact("B")]
        XCTAssertEqual(QueueBuilder.unfiled(contacts: contacts, membership: [:]).count, 2)
    }

    /// A contact in several groups is still filed, not surfaced again.
    func testMultipleMembershipsStillCountAsFiled() {
        let both = contact("Both")
        let membership = [both.identifier: [group("Work"), group("Family")]]
        XCTAssertTrue(QueueBuilder.unfiled(contacts: [both], membership: membership).isEmpty)
    }

    func testOrderingFallsBackToNameWhenDatesDoNotMatch() {
        // These contacts exist only in memory, so no AddressBook row can match
        // them and the ordering must say so rather than pretend.
        let queue = QueueBuilder.ordered([contact("Zoe"), contact("Adam"), contact("Mira")])
        XCTAssertTrue(queue.orderDescription.hasPrefix("name"), queue.orderDescription)
        XCTAssertEqual(queue.contacts.map(\.givenName), ["Adam", "Mira", "Zoe"])
    }

    func testEmptyQueue() {
        XCTAssertTrue(QueueBuilder.ordered([]).contacts.isEmpty)
    }
}
