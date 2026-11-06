import XCTest
import AppKit
import LemmaCore
@testable import Lemma

final class NoteLinkTests: XCTestCase {
    func testRelationshipsRequireDistinctNotesInTheCurrentWorkspace() throws {
        var workspace = fixture()
        let source = workspace.notes[0].id
        let target = workspace.notes[1].id
        XCTAssertNil(workspace.addNoteLink(from: source, to: source, kind: .definition))
        XCTAssertNil(workspace.addNoteLink(from: source, to: UUID(), kind: .definition))
        XCTAssertNil(workspace.addNoteLink(from: UUID(), to: target, kind: .definition))
        let link = try XCTUnwrap(workspace.addNoteLink(from: source, to: target, kind: .definition, usage: "  Defines X here.  "))
        XCTAssertEqual(link.usage, "Defines X here.")
        XCTAssertNil(workspace.addNoteLink(from: source, to: target, kind: .definition))
        XCTAssertNotNil(workspace.addNoteLink(from: source, to: target, kind: .assumption))
        XCTAssertEqual(workspace.outgoingLinks(from: source).count, 2)
        XCTAssertEqual(workspace.incomingLinks(to: target).count, 2)
        XCTAssertTrue(workspace.incomingLinks(to: source).isEmpty)
    }

    @MainActor
    func testLinksPersistExportAndKeepInspectionSeparateFromNavigation() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyStore(root: root)
        store.workspace = fixture()
        let source = try XCTUnwrap(store.workspace?.notes[0])
        let target = try XCTUnwrap(store.workspace?.notes[1])
        store.selectedNoteID = source.id
        store.reader.pageNumber = 8
        store.workspace?.reading.pageIndex = 7
        let link = try XCTUnwrap(store.addNoteLink(from: source.id, to: target.id, kind: .definition, usage: "Reader link context only."))
        store.updateNoteLinkUsage(id: link.id, usage: "Dimensions used in this step.")
        store.updateNote(id: target.id) { $0.question = "Local [X]\nconvention" }
        XCTAssertEqual(store.linkedNote(id: target.id)?.question, "Local [X]\nconvention")
        XCTAssertEqual(store.selectedNoteID, source.id, "Inspecting a linked note must leave the editor on the original note.")
        XCTAssertEqual(store.reader.pageNumber, 8)
        XCTAssertEqual(store.workspace?.reading.pageIndex, 7)
        let prompt = store.prompt(style: .explanation, pinIDs: [])
        XCTAssertFalse(prompt.contains("Dimensions used in this step."), "Linked notes must not be sent to a provider automatically.")
        XCTAssertFalse(prompt.contains("Local [X]"))
        store.flush()
        let saved = try XCTUnwrap(store.repository.load(id: try XCTUnwrap(store.workspace?.id)))
        XCTAssertEqual(saved.noteLinks.first?.id, link.id)
        XCTAssertEqual(saved.noteLinks.first?.targetNoteID, target.id)
        XCTAssertEqual(saved.noteLinks.first?.usage, "Dimensions used in this step.")
        XCTAssertEqual(saved.notes.first { $0.id == target.id }?.question, "Local [X]\nconvention")
        for note in saved.notes {
            try store.repository.saveImage(Data("local crop \(note.id)".utf8), workspaceID: saved.id, name: note.anchor.imageName)
        }
        let destination = root.appendingPathComponent("export")
        try store.repository.export(saved, to: destination)
        let markdown = try String(contentsOf: destination.appendingPathComponent("Study notes.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("<a id=\"\(target.markdownAnchor)\"></a>"))
        XCTAssertTrue(markdown.contains("[Local \\[X\\] convention](#\(target.markdownAnchor))"))
        XCTAssertTrue(markdown.contains("Definition in [\(source.title)](#\(source.markdownAnchor))"))
        XCTAssertTrue(markdown.contains("Dimensions used in this step."))
        let exported = try WorkspaceRepository.decoder.decode(StudyWorkspace.self, from: Data(contentsOf: destination.appendingPathComponent("workspace.json")))
        XCTAssertEqual(exported.noteLinks, saved.noteLinks)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: WorkspaceRepository.encoder.encode(saved)) as? [String: Any])
        legacy["schemaVersion"] = 2; legacy.removeValue(forKey: "noteLinks")
        let migrated = try WorkspaceRepository.decoder.decode(StudyWorkspace.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(migrated.noteLinks.isEmpty)
        XCTAssertEqual(migrated.notes, saved.notes)
        store.noteQuery = "does not match"; store.noteFilter = .revisit
        store.openLinkedNote(target.id)
        XCTAssertEqual(store.selectedNoteID, target.id)
        XCTAssertEqual(store.noteQuery, ""); XCTAssertEqual(store.noteFilter, .all)
        XCTAssertEqual(store.studySection, .glossary)
        XCTAssertEqual(store.reader.pageNumber, 8, "Open note must not implicitly jump the PDF.")
        XCTAssertNil(store.error)
    }

    @MainActor
    func testDeletedLinkUndoTargetsItsBookAcrossWindowsAndClosedTabs() throws {
        let workbench = try WorkbenchFixture()
        let first = workbench.store
        defer { first.app.prepareForTermination(); workbench.close() }
        first.open(workbench.book)
        let bookID = try XCTUnwrap(first.workspace?.id)
        first.workspace?.notes = fixture().notes
        let notes = try XCTUnwrap(first.workspace?.notes)
        let deleted = try XCTUnwrap(first.addNoteLink(from: notes[0].id, to: notes[1].id, kind: .definition, usage: "Keep this relationship."))
        let undo = first.pdfUndoManager
        undo.removeAllActions(); undo.groupsByEvent = false
        undo.beginUndoGrouping()
        first.removeNoteLink(id: deleted.id, undoManager: undo)
        undo.endUndoGrouping()
        first.open(workbench.paper)

        let second = first.app.newWindow()
        second.open(workbench.book)
        let other = try XCTUnwrap(second.addNoteLink(from: notes[1].id, to: notes[2].id, kind: .related))
        undo.undo()
        XCTAssertEqual(second.workspace?.noteLinks, [deleted, other], "Undo restores the original book without losing another window's links.")
        XCTAssertTrue(first.workspace?.noteLinks.isEmpty == true, "The selected PDF is untouched.")
        XCTAssertTrue(undo.canRedo)
        guard undo.canRedo else { return }
        undo.redo()
        XCTAssertEqual(second.workspace?.noteLinks, [other])

        second.closeBook()
        undo.undo()
        XCTAssertEqual(try first.repository.load(id: bookID)?.noteLinks, [deleted, other], "Undo also restores a closed book durably.")
        XCTAssertTrue(undo.canRedo)
        guard undo.canRedo else { return }
        undo.redo()
        XCTAssertEqual(try first.repository.load(id: bookID)?.noteLinks, [other])
        XCTAssertTrue(first.workspace?.noteLinks.isEmpty == true)
        XCTAssertNil(first.error)
    }

    @MainActor
    func testDeletingLinksAndNotesRestoresRelationshipsWithUndo() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyStore(root: root)
        store.workspace = fixture()
        let notes = try XCTUnwrap(store.workspace?.notes)
        store.selectedNoteID = notes[0].id
        let definition = try XCTUnwrap(store.addNoteLink(from: notes[0].id, to: notes[1].id, kind: .definition, usage: "Design matrix dimensions."))
        XCTAssertNotNil(store.addNoteLink(from: notes[1].id, to: notes[2].id, kind: .related))
        XCTAssertNotNil(store.addNoteLink(from: notes[0].id, to: notes[2].id, kind: .assumption, usage: "Full column rank."))
        let originalLinks = try XCTUnwrap(store.workspace?.noteLinks)
        let linkUndo = UndoManager(); linkUndo.groupsByEvent = false
        linkUndo.beginUndoGrouping()
        store.removeNoteLink(id: definition.id, undoManager: linkUndo)
        linkUndo.endUndoGrouping()
        XCTAssertEqual(store.workspace?.noteLinks.count, 2)
        XCTAssertTrue(store.workspace?.incomingLinks(to: notes[1].id).isEmpty == true)
        XCTAssertEqual(store.selectedNoteID, notes[0].id)
        linkUndo.undo()
        XCTAssertEqual(store.workspace?.noteLinks, originalLinks)
        linkUndo.redo(); XCTAssertEqual(store.workspace?.noteLinks.count, 2)
        linkUndo.undo(); XCTAssertEqual(store.workspace?.noteLinks, originalLinks)
        let noteUndo = UndoManager(); noteUndo.groupsByEvent = false
        noteUndo.beginUndoGrouping()
        store.removeNote(id: notes[1].id, undoManager: noteUndo)
        noteUndo.endUndoGrouping()
        XCTAssertNil(store.linkedNote(id: notes[1].id))
        XCTAssertEqual(store.workspace?.noteLinks.map(\.kind), [.assumption], "Deleting a note removes both its incoming and outgoing relationships.")
        noteUndo.undo()
        XCTAssertEqual(store.linkedNote(id: notes[1].id), notes[1])
        XCTAssertEqual(Set(store.workspace?.noteLinks.map(\.id) ?? []), Set(originalLinks.map(\.id)))
        XCTAssertEqual(store.workspace?.outgoingLinks(from: notes[0].id).count, 2)
        XCTAssertEqual(store.workspace?.incomingLinks(to: notes[1].id).first?.usage, "Design matrix dimensions.")
        XCTAssertEqual(try store.repository.load(id: try XCTUnwrap(store.workspace?.id))?.noteLinks.count, 3)
        XCTAssertTrue(noteUndo.canRedo, "Restoring a deleted note must register its matching Redo action.")
        guard noteUndo.canRedo else { return }
        noteUndo.redo()
        XCTAssertNil(store.linkedNote(id: notes[1].id))
        XCTAssertEqual(store.workspace?.noteLinks.map(\.kind), [.assumption])
        XCTAssertEqual(try store.repository.load(id: try XCTUnwrap(store.workspace?.id))?.notes.count, 2)
        noteUndo.undo()
        XCTAssertEqual(store.workspace?.notes, notes, "Another Undo restores the note at its original position.")
        XCTAssertEqual(Set(store.workspace?.noteLinks.map(\.id) ?? []), Set(originalLinks.map(\.id)))
        XCTAssertNil(store.error)
    }

    private func fixture() -> StudyWorkspace {
        var workspace = StudyWorkspace(id: "note-links-fixture", title: "Local algebra", sourcePath: "/local/algebra.pdf", sourceBookmark: nil, fingerprint: "note-links-fixture")
        workspace.notes = [
            StudyNote(anchor: anchor(page: 7, name: "step.png"), question: "Why is the matrix invertible?", body: "Check the kernel."),
            StudyNote(anchor: anchor(page: 1, name: "definition.png"), question: "Design matrix", body: "Rows represent observations.", kind: .definition),
            StudyNote(anchor: anchor(page: 2, name: "rank.png"), question: "Full column rank", body: "The kernel is trivial.", kind: .theorem)
        ]
        return workspace
    }

    private func anchor(page: Int, name: String) -> SourceAnchor {
        SourceAnchor(pageIndex: page, pageLabel: String(page + 1), region: PageRegion(x: 20, y: 30, width: 120, height: 45), quote: "A local source passage.", imageName: name)
    }
}
