import XCTest
import AppKit
import PDFKit
import SwiftUI
import LemmaCore
@testable import Lemma

final class ReaderViewportTests: XCTestCase {
    @MainActor
    func testRestoredPageInspectorFollowsThePDFWhenReturningFromAFileThroughClassic() async throws {
        let previousStyle = ThemeManager.shared.style
        ThemeManager.shared.style = .vscode
        defer { ThemeManager.shared.style = previousStyle }
        let fixture = try WorkbenchFixture()
        let store = fixture.store
        defer { fixture.close() }
        store.open(fixture.book)
        store.workspace?.reading.pageIndex = 3
        store.workspace?.reading.layout = .singlePage
        store.workspace?.reading.scale = 1
        let name = try store.createWorkspaceFile(name: "Reading notes", kind: .markdown)
        store.flush()
        store.app.prepareForTermination()

        let restored = StudyStore(root: store.repository.root)
        defer { restored.app.prepareForTermination() }
        restored.restore()
        XCTAssertEqual(restored.activeFileName, name)
        fixture.window.contentView = NSHostingView(rootView: ReaderWindow(store: restored))
        fixture.window.orderFront(nil)
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(restored.reader.focusPageIndex, 3, "A restored file keeps the saved PDF page as its source context")
        XCTAssertEqual(restored.reader.settledPageIndex, 3, "The retained inspector must use the saved page before a PDF view is created")
        restored.openSpecial(.settings)
        try await Task.sleep(for: .milliseconds(100))
        ThemeManager.shared.style = .classic
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(restored.reader.pageNumber, 4)
        XCTAssertEqual(restored.reader.focusPageIndex, 3)
        XCTAssertEqual(restored.reader.settledPageIndex, 3, "The page inspector and its source actions must follow the restored visible PDF")
    }

    @MainActor
    func testPageInspectorSettlesWhileTheSamePageKeepsReceivingViewportUpdates() async throws {
        let fixture = try WorkbenchFixture()
        let store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        store.open(fixture.book)
        let view = RegionPDFView(frame: CGRect(x: 0, y: 0, width: 900, height: 800))
        view.controller = store.reader; store.reader.view = view; view.document = store.document
        view.displayMode = .singlePage; view.autoScales = true
        fixture.window.contentView = view; view.layoutDocumentView(); view.layoutSubtreeIfNeeded()
        view.go(to: try XCTUnwrap(store.document?.page(at: 2)))
        for _ in 0..<12 {
            store.reader.updateViewport()
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(store.reader.focusPageIndex, 2)
        XCTAssertEqual(store.reader.settledPageIndex, 2, "Repeated layout/scroll notifications on the same page must not starve the page inspector")
    }
}
