import XCTest
import AppKit
import SwiftUI
import LemmaCore
@testable import Lemma

final class WorkspaceTextEditorTests: XCTestCase {
    @MainActor
    func testUndoAfterAnotherWindowEditsTheSharedFileDoesNotCorruptItsText() async throws {
        let fixture = try WorkbenchFixture(), store = fixture.store
        let otherWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: .titled, backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        defer { otherWindow.close(); store.app.prepareForTermination(); fixture.close() }
        let name = try store.createWorkspaceFile(name: "Shared notes", kind: .text)
        let file = try XCTUnwrap(store.activeFile)
        store.updateWorkspaceFile(file, text: "base")
        let other = store.app.newWindow(); other.openWorkspaceFile(name)
        let firstHost = NSHostingView(rootView: WorkspaceTextEditor(store: store, file: file, wrapsLines: true))
        let secondHost = NSHostingView(rootView: WorkspaceTextEditor(store: other, file: file, wrapsLines: true))
        fixture.window.contentView = firstHost; fixture.window.makeKeyAndOrderFront(nil)
        otherWindow.contentView = secondHost; otherWindow.orderFront(nil)
        try await fixture.settle(100)
        func editor(in view: NSView) -> WorkspaceTextView? {
            (view as? WorkspaceTextView) ?? view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        let first = try XCTUnwrap(editor(in: firstHost)), second = try XCTUnwrap(editor(in: secondHost))
        fixture.window.makeFirstResponder(first)
        first.setSelectedRange(NSRange(location: 4, length: 0))
        first.insertText(" local", replacementRange: first.selectedRange()); first.breakUndoCoalescing()
        try await fixture.settle(50)
        XCTAssertTrue(try XCTUnwrap(first.undoManager).canUndo, "The local edit must initially be undoable")
        XCTAssertEqual(second.string, "base local")
        otherWindow.makeFirstResponder(second)
        second.setSelectedRange(NSRange(location: 0, length: 0))
        second.insertText("remote ", replacementRange: second.selectedRange()); second.breakUndoCoalescing()
        try await fixture.settle(50)
        XCTAssertEqual(first.string, "remote base local")

        fixture.window.makeFirstResponder(first)
        first.undoManager?.undo()
        try await fixture.settle(50)

        XCTAssertEqual(file.text, "remote base local", "Synchronization invalidates character ranges from the earlier local edit")
        XCTAssertFalse(try XCTUnwrap(first.undoManager).canUndo)
        XCTAssertEqual(first.string, file.text)
        XCTAssertEqual(second.string, file.text)
        otherWindow.makeFirstResponder(second)
        second.undoManager?.undo()
        try await fixture.settle(50)
        XCTAssertEqual(file.text, "base local", "The editor that made the current edit keeps its native Undo")
        second.undoManager?.redo()
        try await fixture.settle(50)
        XCTAssertEqual(file.text, "remote base local")
        XCTAssertEqual(first.string, file.text)
    }

    @MainActor
    func testNativeEditingSelectionUndoAndSaveUseTheSameBuffer() async throws {
        let fixture = try WorkbenchFixture(), store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        _ = try store.createWorkspaceFile(name: "Working notes", kind: .markdown)
        let file = try XCTUnwrap(store.activeFile)
        store.updateWorkspaceFile(file, text: "# Working notes\n\nA **useful** thought.\n")
        let host = NSHostingView(rootView: WorkspaceTextEditor(store: store, file: file, wrapsLines: true))
        fixture.window.contentView = host; fixture.window.makeKeyAndOrderFront(nil)
        try await fixture.settle(100)
        func findEditor(_ view: NSView) -> WorkspaceTextView? {
            if let found = view as? WorkspaceTextView { return found }
            return view.subviews.compactMap(findEditor).first
        }
        let editor = try XCTUnwrap(findEditor(host))
        XCTAssertTrue(fixture.window.firstResponder === editor, "Opening a file makes its editor ready for typing")
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText("A final line", replacementRange: editor.selectedRange())
        try await fixture.settle(30)
        XCTAssertTrue(file.text.hasSuffix("A final line"))
        XCTAssertEqual(file.cursorLine, 4)
        XCTAssertEqual(file.cursorColumn, 13)
        XCTAssertEqual((editor.enclosingScrollView?.verticalRulerView as? WorkspaceLineGutter)?.lineStarts.count, 4)
        editor.breakUndoCoalescing(); editor.undoManager?.undo()
        try await fixture.settle(30)
        XCTAssertFalse(file.text.contains("A final line"), "Syntax coloring must preserve native text Undo")
        store.saveActiveFile()
        XCTAssertEqual(try store.workspaceFileRepository.read(file.id), file.text)
        XCTAssertTrue(editor.usesFindBar)
        XCTAssertFalse(editor.isAutomaticQuoteSubstitutionEnabled)
    }

    @MainActor
    func testLogicalLinesHandleUnicodeCRLFAndTrailingNewlines() {
        XCTAssertEqual(WorkspaceTextEditor.Coordinator.lineStarts(in: ""), [0])
        XCTAssertEqual(WorkspaceTextEditor.Coordinator.lineStarts(in: "λ\r\n😀\n"), [0, 3, 6])
        XCTAssertEqual(WorkspaceTextEditor.Coordinator.lineStarts(in: "a\nb"), [0, 2])
    }
}
