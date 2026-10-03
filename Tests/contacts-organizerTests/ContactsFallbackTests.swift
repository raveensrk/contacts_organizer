import Contacts
import XCTest
@testable import contacts_organizer

/// macOS refuses to save a card that carries a note until Contacts.app does it
/// (see `ContactsFallback`). Two things must hold: the failure is recognised
/// however the store wraps it, and the script that replaces it cannot be
/// broken by the data it carries.
final class ContactsFallbackTests: XCTestCase {

    func testRecognisesTheNoteFault() {
        let error = NSError(domain: NSCocoaErrorDomain, code: ContactsFallback.noteFaultCode)
        XCTAssertTrue(ContactsFallback.isNoteFault(error))
    }

    func testRecognisesTheFaultBehindAWrappingError() {
        let inner = NSError(domain: NSCocoaErrorDomain, code: ContactsFallback.noteFaultCode)
        let outer = NSError(domain: NSCocoaErrorDomain, code: 134060,
                            userInfo: [NSUnderlyingErrorKey: inner])
        XCTAssertTrue(ContactsFallback.isNoteFault(outer))
    }

    func testIgnoresUnrelatedErrors() {
        XCTAssertFalse(ContactsFallback.isNoteFault(
            NSError(domain: NSCocoaErrorDomain, code: 134060)))
        XCTAssertFalse(ContactsFallback.isNoteFault(
            NSError(domain: "CNErrorDomain", code: 200)))
        XCTAssertFalse(ContactsFallback.isNoteFault(
            NSError(domain: NSCocoaErrorDomain, code: ContactsFallback.noteFaultCode + 1)))
    }

    func testScriptsNameBothRecords() {
        let script = ContactsFallback.addMemberScript(
            contactID: "CC9D7679-4DEB-4A96-B4C6-52E6294054D8:ABPerson",
            groupID: "4F8E19C8-6AD2-435C-A992-230F50E10327:ABGroup")

        XCTAssertTrue(script.contains("id is \"CC9D7679-4DEB-4A96-B4C6-52E6294054D8:ABPerson\""))
        XCTAssertTrue(script.contains("id is \"4F8E19C8-6AD2-435C-A992-230F50E10327:ABGroup\""))
        XCTAssertTrue(script.contains("tell application \"Contacts\""))
        XCTAssertTrue(script.contains("save"))
    }

    func testNamesCannotEscapeTheStringLiteral() {
        let script = ContactsFallback.addMemberScript(contactID: "A\"B\nC", groupID: "G\"H")

        XCTAssertTrue(script.contains("id is \"A\\\"B C\""), script)
        XCTAssertTrue(script.contains("id is \"G\\\"H\""), script)
        XCTAssertFalse(script.contains("B\nC"), "a newline in the id must not start a new statement")
    }

    func testEachWriteUsesItsOwnVerb() {
        XCTAssertTrue(ContactsFallback.addMemberScript(contactID: "p", groupID: "g")
            .contains("add (first person whose id is \"p\") to (first group whose id is \"g\")"))
        XCTAssertTrue(ContactsFallback.removeMemberScript(contactID: "p", groupID: "g")
            .contains("remove (first person whose id is \"p\") from (first group whose id is \"g\")"))
        XCTAssertTrue(ContactsFallback.deleteScript(contactID: "p")
            .contains("delete (first person whose id is \"p\")"))
    }
}
