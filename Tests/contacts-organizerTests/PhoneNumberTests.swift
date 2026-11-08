import XCTest
@testable import contacts_organizer

/// iCloud numbers are typed by people; WhatsApp keys them as country code plus
/// number. The join between the two is only as good as this normalisation.
final class PhoneNumberTests: XCTestCase {

    func testInternationalFormKeepsItsCountryCode() {
        XCTAssertEqual(PhoneNumber.normalize("+91 98450 12345"), "919845012345")
        XCTAssertEqual(PhoneNumber.normalize("+44 (0)20-7946 0000"), "4402079460000",
                       "a + number is taken as typed, digits only")
        XCTAssertEqual(PhoneNumber.normalize("+1-555-123-4567"), "15551234567")
    }

    func testDoubleZeroIsAnInternationalPrefix() {
        XCTAssertEqual(PhoneNumber.normalize("0091 98450 12345"), "919845012345")
    }

    func testBareNationalNumberGetsIndia() {
        XCTAssertEqual(PhoneNumber.normalize("98450 12345"), "919845012345")
        XCTAssertEqual(PhoneNumber.normalize("098450-12345"), "919845012345", "trunk 0 dropped")
    }

    func testCountryCodeWithoutPlusIsKept() {
        XCTAssertEqual(PhoneNumber.normalize("919845012345"), "919845012345")
    }

    func testOtherDefaultCountry() {
        XCTAssertEqual(PhoneNumber.normalize("5551234567", defaultCountryCode: "1"), "15551234567")
    }

    func testNothingDialable() {
        XCTAssertNil(PhoneNumber.normalize(""))
        XCTAssertNil(PhoneNumber.normalize("n/a"))
        XCTAssertNil(PhoneNumber.normalize("000"))
    }

    func testJIDUserDropsServerAndDevice() {
        XCTAssertEqual(PhoneNumber.user(ofJID: "919845012345@s.whatsapp.net"), "919845012345")
        XCTAssertEqual(PhoneNumber.user(ofJID: "919845012345:12@s.whatsapp.net"), "919845012345")
        XCTAssertEqual(PhoneNumber.user(ofJID: "123456789012345@lid"), "123456789012345")
        XCTAssertEqual(PhoneNumber.user(ofJID: "919845012345"), "919845012345")
    }
}
