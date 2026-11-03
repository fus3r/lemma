import XCTest
import LemmaCore

final class WorkspaceFileTests: XCTestCase {
    func testTextAndMarkdownAreRealUTF8FilesAndNeverOverwriteOnCreate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceFileRepository(root: root)
        XCTAssertEqual(try repository.list(), [])
        let markdown = try repository.create(name: "Study notes", kind: .markdown)
        let text = try repository.create(name: "Questions.txt", kind: .markdown)
        XCTAssertEqual(markdown, "Study notes.md")
        XCTAssertEqual(text, "Questions.txt", "An explicit supported extension wins over the picker")
        let contents = "# Étude\n\nλ = 2\n"
        try repository.save(contents, name: markdown)
        XCTAssertEqual(try WorkspaceFileRepository(root: root).read(markdown), contents)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Files/Study notes.md"), encoding: .utf8), contents)
        XCTAssertThrowsError(try repository.create(name: markdown, kind: .markdown))
        XCTAssertEqual(try repository.read(markdown), contents)
        XCTAssertEqual(try repository.list(), [text, markdown])
    }

    func testInvalidNamesCannotEscapeTheFilesFolderOrCreateOtherTypes() throws {
        let repository = WorkspaceFileRepository(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        for name in ["", "   ", "../notes.md", "a/b.txt", "a\\b.txt", ".hidden.md", "a:b.md", "notes.pdf", "notes\nmore.txt"] {
            XCTAssertThrowsError(try repository.filename(name, kind: .text), name)
        }
        XCTAssertThrowsError(try repository.url(for: "../workbench.json"))
        XCTAssertEqual(try repository.filename("  Notes  ", kind: .text), "Notes.txt")
        XCTAssertEqual(try repository.filename("Notes.MD", kind: .text), "Notes.MD")
    }
}
