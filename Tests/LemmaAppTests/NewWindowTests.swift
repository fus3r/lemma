import XCTest
import AppKit
import LemmaCore
@testable import Lemma

final class NewWindowTests: XCTestCase {
    @MainActor
    func testLegacySessionAndNewEmptyWindowRestoreSeparately() throws {
        let fixture = try WorkbenchFixture()
        defer { fixture.store.app.prepareForTermination(); fixture.close() }
        let first = fixture.store
        first.open(fixture.book)
        first.workspace?.reading.pageIndex = 3
        first.workbenchLayout.sidebarWidth = 310
        first.paneExpanded["collection-economics"] = true
        first.flush()
        let original = try JSONDecoder().decode(WorkbenchSession.self, from: Data(contentsOf: first.sessionURL))

        // The existing single-window file is adopted by the first window, with its tabs and layout intact.
        let app = AppModel(root: first.repository.root)
        let economics = app.claimWindow(nil)
        defer { app.prepareForTermination() }
        XCTAssertEqual(economics.tabs.map(\.id), original.bookIDs)
        XCTAssertEqual(economics.workspace?.reading.pageIndex, 3)
        XCTAssertEqual(economics.workbenchLayout.sidebarWidth, 310)
        var requested: [UUID] = []
        app.openWindow = { requested.append($0) }
        let csd = app.newWindow()
        XCTAssertNil(csd.workspace)
        XCTAssertTrue(csd.tabs.isEmpty, "A new window never copies the other window's tabs")
        XCTAssertEqual(requested, [csd.windowID])
        _ = app.claimWindow(csd.windowID)
        csd.open(fixture.paper)
        csd.workspace?.reading.pageIndex = 1
        csd.panelHeight = 320
        csd.paneExpanded["collection-economics"] = false
        economics.flush(); csd.flush()

        XCTAssertNotEqual(economics.sessionURL, csd.sessionURL)
        XCTAssertEqual(economics.paneExpanded["collection-economics"], true)
        let restored = AppModel(root: first.repository.root)
        restored.restoreWindows()
        defer { restored.prepareForTermination() }
        XCTAssertEqual(restored.windows.count, 2)
        let restoredEconomics = try XCTUnwrap(restored.window(economics.windowID))
        let restoredCSD = try XCTUnwrap(restored.window(csd.windowID))
        XCTAssertEqual(restoredEconomics.tabs.map(\.id), economics.tabs.map(\.id))
        XCTAssertEqual(restoredCSD.tabs.map(\.id), csd.tabs.map(\.id))
        XCTAssertEqual(restoredEconomics.workspace?.reading.pageIndex, 3)
        XCTAssertEqual(restoredCSD.workspace?.reading.pageIndex, 1)
        XCTAssertEqual(restoredCSD.panelHeight, 320)
        XCTAssertEqual(restoredCSD.paneExpanded["collection-economics"], false)
    }

    @MainActor
    func testSameBookSharesEditsWithoutSharingReadingOrFind() throws {
        let fixture = try WorkbenchFixture()
        let app = fixture.store.app
        defer { app.prepareForTermination(); fixture.close() }
        let first = app.claimWindow(nil)
        first.open(fixture.book)
        let second = app.newWindow()
        _ = app.claimWindow(second.windowID)
        second.open(fixture.book)
        first.workspace?.reading.pageIndex = 3
        second.workspace?.reading.pageIndex = 1
        first.reader.selection = (0, CGRect(x: 40, y: 600, width: 220, height: 40), "A shared note")
        first.addNote()
        let noteID = try XCTUnwrap(first.currentNote?.id)
        first.updateNote { $0.body = "Written in the first window" }
        XCTAssertEqual(second.workspace?.notes.first?.body, "Written in the first window", "Edits share a live buffer")
        second.selectedNoteID = noteID
        second.updateNote { $0.body = "Edited in the second window" }
        second.reader.selection = (1, CGRect(x: 40, y: 600, width: 220, height: 40), "A highlight")
        second.highlightSelection()
        first.flush(); second.flush(); first.flush()
        XCTAssertEqual(first.workspace?.notes.first?.body, "Edited in the second window")
        XCTAssertEqual(first.workspace?.highlights.count, 1)
        XCTAssertEqual(first.workspace?.reading.pageIndex, 3)
        XCTAssertEqual(second.workspace?.reading.pageIndex, 1)
        XCTAssertFalse(first.document === second.document, "PDFKit view and search state stay per window")
        first.find.show(first); first.find.query = "regression"
        XCTAssertFalse(second.find.isVisible)
        XCTAssertEqual(second.find.query, "")
        let saved = try XCTUnwrap(first.repository.load(id: try XCTUnwrap(first.workspace?.id)))
        XCTAssertEqual(saved.notes.first?.body, "Edited in the second window")
        XCTAssertEqual(saved.highlights.count, 1, "A later save from the other window cannot drop edits")

        let restored = AppModel(root: first.repository.root)
        restored.restoreWindows()
        defer { restored.prepareForTermination() }
        XCTAssertEqual(restored.window(first.windowID)?.workspace?.reading.pageIndex, 3)
        XCTAssertEqual(restored.window(second.windowID)?.workspace?.reading.pageIndex, 1)
        XCTAssertEqual(restored.window(second.windowID)?.workspace?.notes.first?.body, "Edited in the second window")
    }

    @MainActor
    func testFrontWindowRoutesCommandsAndOnlyItCountsReading() throws {
        let fixture = try WorkbenchFixture()
        let app = fixture.store.app
        defer { app.prepareForTermination(); fixture.close() }
        let first = app.claimWindow(nil)
        first.open(fixture.book)
        let second = app.newWindow()
        _ = app.claimWindow(second.windowID)
        second.open(fixture.paper)
        let otherWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 700), styleMask: .titled, backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        defer { otherWindow.close() }
        first.mainWindow = fixture.window; second.mainWindow = otherWindow
        app.windowDidBecomeKey(fixture.window)
        XCTAssertTrue(app.front === first)
        first.tracker?.isReaderInFront = { true }; second.tracker?.isReaderInFront = { true }
        first.tracker?.idleSeconds = { 0 }; second.tracker?.idleSeconds = { 0 }
        let now = Date.now
        first.tracker?.lastTick = now.addingTimeInterval(-5)
        second.tracker?.lastTick = now.addingTimeInterval(-5)
        first.mainWindow = nil; second.mainWindow = nil
        first.tracker?.tick(now: now); second.tracker?.tick(now: now)
        XCTAssertGreaterThan(first.tracker?.pendingSeconds(for: try XCTUnwrap(first.workspace?.id)) ?? 0, 0)
        XCTAssertEqual(second.tracker?.pendingSeconds(for: try XCTUnwrap(second.workspace?.id)), 0)
        app.front.toggleLibrary()
        XCTAssertFalse(first.showLibrary)
        XCTAssertTrue(second.showLibrary)
        second.mainWindow = otherWindow
        app.windowDidBecomeKey(otherWindow)
        XCTAssertTrue(app.front === second)
        XCTAssertTrue(first.commandCatalog().contains { $0.title == "File: New Window" && $0.shortcut == "⇧⌘N" })
    }

    @MainActor
    func testClosingOneWindowPreservesTheOtherAndItsSavedBook() throws {
        let fixture = try WorkbenchFixture()
        let app = fixture.store.app
        defer { app.prepareForTermination(); fixture.close() }
        let first = app.claimWindow(nil)
        first.mainWindow = fixture.window
        first.open(fixture.book)
        let firstID = try XCTUnwrap(first.workspace?.id)
        let second = app.newWindow()
        _ = app.claimWindow(second.windowID)
        second.open(fixture.paper)
        let secondID = try XCTUnwrap(second.workspace?.id)
        app.windowWillClose(fixture.window)
        XCTAssertEqual(app.windows.map(\.windowID), [second.windowID])
        XCTAssertEqual(second.workspace?.id, secondID)
        let restored = AppModel(root: second.repository.root)
        restored.restoreWindows()
        defer { restored.prepareForTermination() }
        XCTAssertEqual(restored.windows.map(\.windowID), [second.windowID])
        XCTAssertEqual(restored.windows.first?.workspace?.id, secondID)
        XCTAssertNotNil(try first.repository.load(id: firstID), "Closing a window retains its saved book")
    }
}
