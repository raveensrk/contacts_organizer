import Foundation

/// Hand-off for the one write macOS refuses to do natively.
///
/// Since macOS 13 a note on a card is gated behind the
/// `com.apple.developer.contacts.notes` entitlement, which a command-line
/// binary cannot have without an Apple-issued provisioning profile. Saving a
/// change to a card that carries a note makes the store fault the note
/// property it may not read, and the save dies with Cocoa error 134092
/// ("Unhandled error occurred during faulting") — the change never lands.
///
/// Contacts.app is entitled, so the same edit succeeds when Contacts.app makes
/// it. These scripts ask it to, and the tool stays useful for note-bearing
/// cards instead of dying on them.
enum ContactsFallback {

    /// Cocoa error 134092. Core Data raises it when faulting a record throws.
    static let noteFaultCode = 134092

    /// True for the fault error, however deeply the store wrapped it.
    static func isNoteFault(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let candidate = current {
            if candidate.domain == NSCocoaErrorDomain, candidate.code == noteFaultCode { return true }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    // MARK: - Scripts

    static func addMemberScript(contactID: String, groupID: String) -> String {
        """
        tell application "Contacts"
            add (first person whose id is \(quoted(contactID))) to (first group whose id is \(quoted(groupID)))
            save
        end tell
        """
    }

    static func removeMemberScript(contactID: String, groupID: String) -> String {
        """
        tell application "Contacts"
            remove (first person whose id is \(quoted(contactID))) from (first group whose id is \(quoted(groupID)))
            save
        end tell
        """
    }

    static func deleteScript(contactID: String) -> String {
        """
        tell application "Contacts"
            delete (first person whose id is \(quoted(contactID)))
            save
        end tell
        """
    }

    // MARK: - Writes

    static func addMember(contactID: String, groupID: String) throws {
        try run(addMemberScript(contactID: contactID, groupID: groupID))
    }

    static func removeMember(contactID: String, groupID: String) throws {
        try run(removeMemberScript(contactID: contactID, groupID: groupID))
    }

    static func delete(contactID: String) throws {
        try run(deleteScript(contactID: contactID))
    }

    // MARK: - Plumbing

    /// Runs one script. `osascript` is the system's own bridge, so the
    /// Automation permission (System Settings > Privacy & Security >
    /// Automation) covers it; the first call may prompt.
    private static func run(_ script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        // Nothing the script says is for the user's screen; only errors matter.
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw AppError("Could not run osascript: \(error.localizedDescription)")
        }
        // Read before waiting: a full pipe would otherwise block the child.
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw AppError("Contacts.app refused the change: "
                + (message.isEmpty ? "osascript exit \(process.terminationStatus)" : message))
        }
    }

    /// AppleScript string literal. Identifiers are UUIDs today, but a stray
    /// quote or newline must never turn into a second statement.
    private static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "\"\(escaped)\""
    }
}
