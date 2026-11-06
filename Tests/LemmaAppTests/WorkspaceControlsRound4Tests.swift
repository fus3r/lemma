import XCTest
import AppKit
import LemmaCore
@testable import Lemma

final class WorkspaceControlsRound4Tests: XCTestCase {
    @MainActor
    func testEarlierBookRenameUndoKeepsANewerTitleFromAnotherWindow() throws {
        let fixture = try WorkbenchFixture(), first = fixture.store
        let app = first.app
        defer { app.prepareForTermination(); fixture.close() }
        _ = app.claimWindow(nil)
        first.open(fixture.book)
        let id = try XCTUnwrap(first.workspace?.id)
        let second = app.newWindow(); _ = app.claimWindow(second.windowID)
        second.open(fixture.book)
        let firstUndo = UndoManager(), secondUndo = UndoManager()
        firstUndo.groupsByEvent = false; secondUndo.groupsByEvent = false
        first.libraryTree.undoManager = firstUndo; second.libraryTree.undoManager = secondUndo
        firstUndo.beginUndoGrouping()
        _ = try first.renameLibraryPDF(path: fixture.book.path, bookID: id, to: "First title", mode: .lemma)
        firstUndo.endUndoGrouping()
        secondUndo.beginUndoGrouping()
        _ = try second.renameLibraryPDF(path: fixture.book.path, bookID: id, to: "Second title", mode: .lemma)
        secondUndo.endUndoGrouping()
        XCTAssertEqual(first.workspace?.title, "Second title")

        firstUndo.undo()

        XCTAssertEqual(first.workspace?.title, "Second title", "A stale rename Undo must preserve the newer name chosen in another window")
        XCTAssertEqual(second.workspace?.title, "Second title")
        XCTAssertEqual(try first.repository.load(id: id)?.title, "Second title")
        XCTAssertNotNil(first.error)
        XCTAssertFalse(firstUndo.canRedo, "A rejected rename Undo must not register a misleading Redo")
        secondUndo.undo()
        XCTAssertEqual(first.workspace?.title, "First title", "The most recent compatible rename still supports Undo")
        secondUndo.redo()
        XCTAssertEqual(second.workspace?.title, "Second title")
    }

    @MainActor
    func testWorkspaceCaseOnlyRenameKeepsSharedBufferAndLatestText() throws {
        let fixture = try WorkbenchFixture(), first = fixture.store
        let app = first.app
        defer { app.prepareForTermination(); fixture.close() }
        _ = app.claimWindow(nil)
        let name = try first.createWorkspaceFile(name: "notes", kind: .markdown)
        let file = try XCTUnwrap(first.activeFile)
        let second = app.newWindow(); _ = app.claimWindow(second.windowID)
        second.openWorkspaceFile(name)
        second.updateWorkspaceFile(file, text: "# Latest text\nλ")

        try first.renameWorkspaceFile(name, to: "Notes.md")

        XCTAssertEqual(first.activeFileName, "Notes.md")
        XCTAssertEqual(second.activeFileName, "Notes.md")
        XCTAssertTrue(second.activeFile === file)
        XCTAssertEqual(try first.workspaceFileRepository.read("Notes.md"), "# Latest text\nλ")
        XCTAssertEqual(try first.workspaceFileRepository.list(), ["Notes.md"])
    }
}
