import XCTest
@testable import contacts_organizer

/// CoreData logs a note-card save failure to stderr itself. The native attempt
/// runs with stderr silenced, and stderr must come back afterwards, even when
/// the attempt throws, or the tool's own error messages would vanish too.
final class StderrTests: XCTestCase {

    /// Points fd 2 at a temporary file for the duration of `body` and returns
    /// what reached it.
    private func captureStderr(_ body: () -> Void) throws -> String {
        let path = NSTemporaryDirectory() + "stderr-" + UUID().uuidString
        FileManager.default.createFile(atPath: path, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: path) }

        fflush(stderr)
        let saved = dup(STDERR_FILENO)
        let file = open(path, O_WRONLY)
        dup2(file, STDERR_FILENO)
        close(file)
        body()
        fflush(stderr)
        dup2(saved, STDERR_FILENO)
        close(saved)
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    private func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    func testSilencedWritesAreDroppedAndStderrComesBack() throws {
        let output = try captureStderr {
            write("before\n")
            Stderr.silenced { write("CoreData: error: noise\n") }
            write("after\n")
        }
        XCTAssertEqual(output, "before\nafter\n")
    }

    func testStderrComesBackWhenTheBodyThrows() throws {
        var threw = false
        let output = try captureStderr {
            do {
                try Stderr.silenced { () throws -> Void in
                    write("noise\n")
                    throw AppError("save failed")
                }
            } catch {
                threw = true
            }
            write("error: shown\n")
        }
        XCTAssertTrue(threw)
        XCTAssertEqual(output, "error: shown\n")
    }

    func testReturnsTheBodysValue() {
        XCTAssertEqual(Stderr.silenced { 42 }, 42)
    }
}
