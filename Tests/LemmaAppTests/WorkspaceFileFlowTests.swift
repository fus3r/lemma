import XCTest
import AppKit
import SwiftUI
import LemmaCore
@testable import Lemma

final class WorkspaceFileFlowTests: XCTestCase {
    @MainActor
    func testFileFilterStaysAvailableWhenAFilteredFileIsRemoved() async throws {
        let fixture = try WorkbenchFixture(), store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        for index in 1...7 { _ = try store.createWorkspaceFile(name: "File \(index)", kind: .text) }
        let host = NSHostingView(rootView: WorkspaceFilesList(store: store).environment(\.theme, ThemeManager.shared.colors))
        fixture.window.contentView = host; fixture.window.makeKeyAndOrderFront(nil)
        try await fixture.settle(100)
        func filterField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap { filterField(in: $0) }.first
        }
        let field = try XCTUnwrap(filterField(in: host))
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("File 1", replacementRange: editor.selectedRange())
        try await fixture.settle(60)
        XCTAssertEqual(field.stringValue, "File 1")
        // Removing the fixture and refreshing produces the same list update as Move to Trash, without using the Mac's Trash.
        try FileManager.default.removeItem(at: store.workspaceFileRepository.url(for: "File 1.txt"))
        store.refreshWorkspaceFiles()
        try await fixture.settle(60)
        XCTAssertEqual(store.workspaceFiles.count, 6)
        let remainingFilter = try XCTUnwrap(filterField(in: host), "The active filter must remain available to clear after the file count falls below seven")
        XCTAssertEqual(remainingFilter.stringValue, "File 1")
        remainingFilter.selectText(nil)
        let remainingEditor = try XCTUnwrap(remainingFilter.currentEditor() as? NSTextView)
        remainingEditor.deleteBackward(nil)
        try await fixture.settle(60)
        XCTAssertNil(filterField(in: host), "Once cleared, a six-file list can hide its unneeded filter")
    }

    @MainActor
    func testFailedFileSaveCancelsTerminationUntilRetry() throws {
        let fixture = try WorkbenchFixture(), store = fixture.store
        let app = store.app
        let name = try store.createWorkspaceFile(name: "Unsaved notes", kind: .text)
        let file = try XCTUnwrap(store.activeFile)
        let url = try store.workspaceFileRepository.url(for: name)
        defer {
            try? FileManager.default.removeItem(at: url)
            app.quitting = false; app.prepareForTermination(); fixture.close()
        }
        store.updateWorkspaceFile(file, text: "The final unsaved edit")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

        app.prepareForTermination()

        XCTAssertFalse(app.quitting, "Quit must stop when the final save fails, while the editing buffer is still recoverable")
        XCTAssertTrue(file.isDirty)
        XCTAssertNotNil(file.saveError)
        XCTAssertEqual(store.activeFileName, name)
        try FileManager.default.removeItem(at: url)
        app.prepareForTermination()
        XCTAssertTrue(app.quitting, "The reader can retry Quit after the storage problem is fixed")
        XCTAssertEqual(try store.workspaceFileRepository.read(name), "The final unsaved edit")
    }

    @MainActor
    func testClosingABookBehindAFileKeepsTheFileInFront() throws {
        let fixture = try WorkbenchFixture(), store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        store.open(fixture.book)
        let bookID = try XCTUnwrap(store.workspace?.id)
        store.open(fixture.paper)
        let paperID = try XCTUnwrap(store.workspace?.id)
        let name = try store.createWorkspaceFile(name: "Working notes", kind: .markdown)
        let file = try XCTUnwrap(store.activeFile)
        store.updateWorkspaceFile(file, text: "Keep writing here")

        store.closeTab(paperID)

        XCTAssertEqual(store.tabs.map(\.id), [bookID])
        XCTAssertEqual(store.activeFileName, name, "Closing a background PDF must not switch away from the file being edited")
        XCTAssertTrue(store.activeFile === file)
        XCTAssertEqual(try store.workspaceFileRepository.read(name), "Keep writing here")
        let session = try JSONDecoder().decode(WorkbenchSession.self, from: Data(contentsOf: store.sessionURL))
        XCTAssertEqual(session.activeFileName, name)
    }

    @MainActor
    func testClosingTheLastSpecialEditorReturnsToAnOpenFile() throws {
        let previousStyle = ThemeManager.shared.style
        ThemeManager.shared.style = .vscode
        defer { ThemeManager.shared.style = previousStyle }
        let fixture = try WorkbenchFixture(), store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        let name = try store.createWorkspaceFile(name: "Working notes", kind: .text)
        store.openSettingsEditor()
        XCTAssertEqual(store.activeSpecial, .settings)

        store.closeSpecial(.settings)

        XCTAssertEqual(store.activeFileName, name, "An open file must take over instead of an empty editor")
        XCTAssertEqual(store.activeMainTabID, StudyStore.fileTabID(name))
    }

    @MainActor
    func testBackgroundBookRestorationKeepsTheSavedFileInFront() async throws {
        let fixture = try WorkbenchFixture(), store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        store.open(fixture.book)
        let bookID = try XCTUnwrap(store.workspace?.id)
        let name = try store.createWorkspaceFile(name: "Working notes", kind: .markdown)
        store.flush()
        // A PDF changed or synced while Lemma was closed needs its fingerprint read again.
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(2)], ofItemAtPath: fixture.book.path)
        let restored = StudyStore(root: store.repository.root)
        defer { restored.app.prepareForTermination() }
        restored.immediateHashLimit = 0
        restored.restore()
        XCTAssertNotNil(restored.openingFile)
        XCTAssertEqual(restored.activeFileName, name)
        let deadline = Date.now.addingTimeInterval(5)
        while restored.openingFile != nil, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }

        XCTAssertEqual(restored.workspace?.id, bookID)
        XCTAssertEqual(restored.activeFileName, name, "Completing the PDF load must preserve the restored foreground file")
        let session = try JSONDecoder().decode(WorkbenchSession.self, from: Data(contentsOf: restored.sessionURL))
        XCTAssertEqual(session.activeFileName, name)
    }

    @MainActor
    func testRenameFlushesPendingEditsAndUpdatesEveryWindowWithoutOverwritingAnotherFile() async throws {
        let fixture = try WorkbenchFixture(), store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        _ = store.app.claimWindow(nil)
        let name = try store.createWorkspaceFile(name: "Draft", kind: .markdown)
        let file = try XCTUnwrap(store.activeFile)
        let second = store.app.newWindow(); second.openWorkspaceFile(name)
        store.updateWorkspaceFile(file, text: "# Last unsaved keystroke\nλ")
        try store.renameWorkspaceFile(name, to: "Research.md")
        XCTAssertTrue(second.activeFile === file)
        XCTAssertEqual(second.activeFileName, "Research.md")
        XCTAssertEqual(store.activeFileName, "Research.md")
        XCTAssertEqual(try store.workspaceFileRepository.read("Research.md"), file.text)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.workspaceFileRepository.url(for: name).path), "A cancelled autosave cannot recreate the old filename")
        _ = try store.createWorkspaceFile(name: "Existing", kind: .text)
        XCTAssertThrowsError(try store.renameWorkspaceFile("Research.md", to: "Existing.txt"))
        XCTAssertEqual(try store.workspaceFileRepository.read("Research.md"), file.text)
        XCTAssertEqual(try store.workspaceFileRepository.read("Existing.txt"), "")
        XCTAssertEqual(file.id, "Research.md")
    }

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
        let quickOpen = PaletteProvider(store: store).items(mode: .goTo, query: "Ideas")
        let result = try XCTUnwrap(quickOpen.first { $0.id == StudyStore.fileTabID(name) })
        XCTAssertEqual(result.category, "File")
        result.perform()
        XCTAssertEqual(store.activeFileName, name, "Quick Open can find and open a file without a PDF")
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
