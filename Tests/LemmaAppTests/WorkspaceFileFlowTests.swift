import XCTest
import LemmaCore
@testable import Lemma

final class WorkspaceFileFlowTests: XCTestCase {
    @MainActor
    func testAutosaveCloseReopenAndSessionRestoreWithoutAPDF() async throws {
        let fixture = try WorkbenchFixture()
        let store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        store.restore()
        let name = try store.createWorkspaceFile(name: "Ideas", kind: .markdown)
        let file = try XCTUnwrap(store.activeFile)
        XCTAssertNil(store.workspace, "Standalone files work without opening a PDF")
        XCTAssertNil(store.activeSpecial)
        XCTAssertEqual(store.activeMainTabID, StudyStore.fileTabID(name))
        store.updateWorkspaceFile(file, text: "# Notes\n\nA saved thought: λ.\n")
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertFalse(file.isDirty, "Edits save once typing pauses, without an explicit Save")
        XCTAssertEqual(try store.workspaceFileRepository.read(name), file.text)
        store.updateWorkspaceFile(file, text: file.text + "Last keystroke\n")
        XCTAssertTrue(store.closeWorkspaceFile(name), "Closing flushes a pending autosave")
        XCTAssertEqual(try store.workspaceFileRepository.read(name), file.text)
        XCTAssertTrue(store.workspaceFiles.contains(name), "Closing never deletes the file")
        store.openWorkspaceFile(name)
        let app = AppModel(root: store.repository.root)
        defer { app.prepareForTermination() }
        let restored = app.claimWindow(nil)
        XCTAssertEqual(restored.fileTabs, [name])
        XCTAssertEqual(restored.activeFile?.text, file.text)
        XCTAssertEqual(restored.activeFileName, name)
        XCTAssertNil(restored.activeSpecial, "Welcome must not replace a restored file")
    }

    @MainActor
    func testFilesShareBuffersAcrossWindowsAndKeepBookState() throws {
        let fixture = try WorkbenchFixture()
        let first = fixture.store
        let app = first.app
        defer { app.prepareForTermination(); fixture.close() }
        let firstWindow = app.claimWindow(nil)
        firstWindow.open(fixture.book)
        let id = try XCTUnwrap(firstWindow.workspace?.id)
        firstWindow.workspace?.reading.pageIndex = 3
        let notes = firstWindow.workspace?.notes
        let name = try firstWindow.createWorkspaceFile(name: "Questions", kind: .text)
        let file = try XCTUnwrap(firstWindow.activeFile)
        XCTAssertEqual(firstWindow.activeDocumentTitle, name)
        firstWindow.updateWorkspaceFile(file, text: "From window one")
        let second = app.newWindow()
        _ = app.claimWindow(second.windowID)
        XCTAssertTrue(second.fileTabs.isEmpty)
        XCTAssertTrue(second.workspaceFiles.contains(name))
        second.openWorkspaceFile(name)
        XCTAssertTrue(second.activeFile === file)
        second.updateWorkspaceFile(file, text: "From window two")
        firstWindow.flush(); second.flush()
        XCTAssertEqual(try firstWindow.workspaceFileRepository.read(name), "From window two")
        firstWindow.activateMainTab(id)
        XCTAssertNil(firstWindow.activeFileName)
        XCTAssertEqual(firstWindow.workspace?.reading.pageIndex, 3)
        XCTAssertEqual(firstWindow.workspace?.notes, notes)
        XCTAssertEqual(second.activeFileName, name, "Each window keeps its selected tab")
        firstWindow.openWorkspaceFile(name)
        firstWindow.closeWorkspaceFile(name)
        XCTAssertEqual(firstWindow.workspace?.id, id)
        XCTAssertEqual(firstWindow.workspace?.reading.pageIndex, 3)
        XCTAssertEqual(firstWindow.activeMainTabID, id)
        XCTAssertEqual(firstWindow.activeDocumentTitle, "Synthetic Book")
        firstWindow.openWorkspaceFile(name)
        firstWindow.openBook(id, atPage: 2)
        XCTAssertNil(firstWindow.activeFileName, "Following a book location returns to the PDF")
        XCTAssertEqual(firstWindow.workspace?.reading.pageIndex, 2)
    }

    @MainActor
    func testFailedSaveKeepsTheFileOpenAndEditsAvailable() throws {
        let fixture = try WorkbenchFixture()
        let store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        let name = try store.createWorkspaceFile(name: "Notes", kind: .text)
        let file = try XCTUnwrap(store.activeFile)
        store.updateWorkspaceFile(file, text: "Unsaved work")
        let url = try store.workspaceFileRepository.url(for: name)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertFalse(store.closeWorkspaceFile(name))
        XCTAssertEqual(store.activeFileName, name)
        XCTAssertTrue(file.isDirty)
        XCTAssertNotNil(file.saveError)
        XCTAssertEqual(file.text, "Unsaved work")
        try FileManager.default.removeItem(at: url)
        store.saveActiveFile()
        XCTAssertFalse(file.isDirty)
        XCTAssertNil(file.saveError)
        XCTAssertEqual(try store.workspaceFileRepository.read(name), "Unsaved work")
    }
}
