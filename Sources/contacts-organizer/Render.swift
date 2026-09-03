import Contacts
import Foundation

enum Style {
    /// Honour NO_COLOR, and stay plain when stdout is redirected.
    static let enabled: Bool = ProcessInfo.processInfo.environment["NO_COLOR"] == nil
        && isatty(FileHandle.standardOutput.fileDescriptor) == 1

    static func bold(_ s: String) -> String { enabled ? "\u{1B}[1m\(s)\u{1B}[0m" : s }
    static func dim(_ s: String) -> String { enabled ? "\u{1B}[2m\(s)\u{1B}[0m" : s }
    static func green(_ s: String) -> String { enabled ? "\u{1B}[32m\(s)\u{1B}[0m" : s }
    static func yellow(_ s: String) -> String { enabled ? "\u{1B}[33m\(s)\u{1B}[0m" : s }
    static func red(_ s: String) -> String { enabled ? "\u{1B}[31m\(s)\u{1B}[0m" : s }
    /// Highlighted row: reverse video, so it reads on any theme.
    static func selected(_ s: String) -> String { enabled ? "\u{1B}[7m\(s)\u{1B}[0m" : "\(s)" }
}

enum Render {

    /// Best available human name, falling back through the fields that people
    /// with half-filled contact records actually have.
    static func displayName(_ contact: CNContact) -> String {
        if let formatted = CNContactFormatter.string(from: contact, style: .fullName),
           !formatted.trimmingCharacters(in: .whitespaces).isEmpty {
            return formatted
        }
        if !contact.nickname.isEmpty { return contact.nickname }
        if !contact.organizationName.isEmpty { return contact.organizationName }
        if let phone = contact.phoneNumbers.first?.value.stringValue, !phone.isEmpty { return phone }
        if let email = contact.emailAddresses.first?.value as String?, !email.isEmpty { return email }
        return "(no name)"
    }

    /// The full card printed above the picker.
    static func card(_ contact: CNContact, position: Int, total: Int) -> String {
        var lines: [String] = []
        lines.append("")
        lines.append(Style.dim("── \(position)/\(total) " + String(repeating: "─", count: max(0, 56 - "\(position)/\(total)".count))))
        lines.append(Style.bold(displayName(contact)))

        let role = [contact.jobTitle, contact.departmentName, contact.organizationName]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        if !role.isEmpty { lines.append(Style.dim("  ") + role) }

        for phone in contact.phoneNumbers {
            lines.append("  " + field(label(phone.label), phone.value.stringValue))
        }
        for email in contact.emailAddresses {
            lines.append("  " + field(label(email.label), email.value as String))
        }
        for url in contact.urlAddresses {
            lines.append("  " + field(label(url.label), url.value as String))
        }
        for address in contact.postalAddresses {
            let text = CNPostalAddressFormatter.string(from: address.value, style: .mailingAddress)
                .replacingOccurrences(of: "\n", with: ", ")
            lines.append("  " + field(label(address.label), text))
        }
        if let birthday = contact.birthday, let month = birthday.month, let day = birthday.day {
            let year = birthday.year.map { String(format: "%04d", $0) } ?? "————"
            lines.append("  " + field("birthday", String(format: "\(year)-%02d-%02d", month, day)))
        }
        if contact.contactType == .organization {
            lines.append("  " + Style.dim("(company record)"))
        }
        return lines.joined(separator: "\n")
    }

    private static func field(_ name: String, _ value: String) -> String {
        Style.dim(name.padding(toLength: max(10, name.count), withPad: " ", startingAt: 0)) + "  " + value
    }

    private static func label(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "—" }
        return CNLabeledValue<NSString>.localizedString(forLabel: raw).lowercased()
    }
}
