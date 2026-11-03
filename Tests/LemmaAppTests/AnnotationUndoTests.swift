import XCTest
import AppKit
import LemmaCore
@testable import Lemma

final class AnnotationUndoTests: XCTestCase {
    @MainActor
    func testNotesHighlightsAndUnderlinesHaveDurableUndoAndRedo() throws {
        let fixture = try WorkbenchFixture()
        let store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        let source = try Data(contentsOf: fixture.book)
        store.open(fixture.book)
        let bookID = try XCTUnwrap(store.workspace?.id)
        let undo = store.pdfUndoManager
        store.reader.selection = (0, CGRect(x: 40, y: 600, width: 220, height: 40), "A passage")
        store.addNote()
        let note = try XCTUnwrap(store.currentNote)
        let image = store.repository.assetURL(workspaceID: bookID, name: note.anchor.imageName)
        store.updateNote { $0.body = "Keep this reasoning when the note is redone." }
        XCTAssertEqual(undo.undoActionName, "Add Note")
        undo.undo()
        XCTAssertTrue(store.workspace?.notes.isEmpty == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path), "Undo keeps the crop available for redo")
        undo.redo()
        XCTAssertEqual(store.workspace?.notes.first?.id, note.id)
        XCTAssertEqual(store.workspace?.notes.first?.body, "Keep this reasoning when the note is redone.")
        store.removeNote(id: note.id, undoManager: undo)
        undo.undo()
        XCTAssertEqual(store.workspace?.notes.first?.id, note.id)

        undo.removeAllActions()
        store.highlightSelection()
        let highlight = try XCTUnwrap(store.workspace?.highlights.first)
        XCTAssertEqual(undo.undoActionName, "Highlight")
        undo.undo(); XCTAssertTrue(store.workspace?.highlights.isEmpty == true)
        undo.redo(); XCTAssertEqual(store.workspace?.highlights.first, highlight)
        store.highlightSelection(style: .underline)
        XCTAssertEqual(undo.undoActionName, "Underline")
        undo.undo(); XCTAssertEqual(store.workspace?.highlights, [highlight])
        undo.redo(); XCTAssertEqual(store.workspace?.highlights.last?.style, .underline)
        store.removeHighlight(id: highlight.id)
        undo.undo(); XCTAssertEqual(store.workspace?.highlights.first, highlight)
        store.flush()
        let saved = try XCTUnwrap(store.repository.load(id: bookID))
        XCTAssertEqual(saved.highlights, store.workspace?.highlights)
        XCTAssertEqual(saved.notes.first?.body, "Keep this reasoning when the note is redone.")
        XCTAssertEqual(try Data(contentsOf: fixture.book), source, "Annotations and their undo never rewrite the original PDF")
    }

    @MainActor
    func testUndoAfterSwitchingBooksPreservesOtherWindowEdits() throws {
        let fixture = try WorkbenchFixture()
        let app = fixture.store.app
        defer { app.prepareForTermination(); fixture.close() }
        let first = app.claimWindow(nil)
        first.open(fixture.book)
        let bookID = try XCTUnwrap(first.workspace?.id)
        first.reader.selection = (0, CGRect(x: 40, y: 600, width: 220, height: 40), "First note")
        first.addNote()
        let firstID = try XCTUnwrap(first.currentNote?.id)
        let second = app.newWindow()
        _ = app.claimWindow(second.windowID)
        second.open(fixture.book)
        second.reader.selection = (1, CGRect(x: 40, y: 600, width: 220, height: 40), "Second note")
        second.addNote()
        let secondID = try XCTUnwrap(second.currentNote?.id)
        first.open(fixture.paper)
        first.pdfUndoManager.undo()
        XCTAssertTrue(first.workspace?.notes.isEmpty == true, "The other PDF is untouched")
        XCTAssertEqual(second.workspace?.notes.map(\.id), [secondID], "Only the original note is undone")
        first.pdfUndoManager.redo()
        XCTAssertEqual(Set(second.workspace?.notes.map(\.id) ?? []), [firstID, secondID])
        XCTAssertTrue(first.workspace?.notes.isEmpty == true)
        XCTAssertEqual(try first.repository.load(id: bookID)?.notes.count, 2)
    }
}
