import XCTest
import AppKit
import PDFKit
import SwiftUI
import LemmaCore
@testable import Lemma

final class InkTests: XCTestCase {
    @MainActor
    func testOriginalEditionLeavesDrawingModeAndCannotEraseHiddenInk() throws {
        let fixture = try WorkbenchFixture()
        let store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        store.open(fixture.book)
        let document = try XCTUnwrap(store.document), page = try XCTUnwrap(document.page(at: 0))
        let view = RegionPDFView(frame: CGRect(x: 0, y: 0, width: 900, height: 800))
        view.controller = store.reader; store.reader.view = view; view.document = document
        view.displayMode = .singlePage; view.autoScales = true
        fixture.window.contentView = view; view.layoutDocumentView(); view.layoutSubtreeIfNeeded()
        let stroke = InkStroke(pageIndex: 0, points: [.init(x: 80, y: 80), .init(x: 160, y: 140)])
        store.addInk(stroke, undoManager: nil)
        store.reader.onEraseInk = { store.removeInk(id: $0, undoManager: nil) }
        store.reader.inkMode = true; store.reader.drawingTool = .eraser
        store.reader.showAnnotations = false
        store.reader.syncInk([stroke], in: document)
        XCTAssertTrue(page.annotations.isEmpty)
        XCTAssertFalse(store.reader.inkMode, "Original is a read-only view of the source, so drawing must end")
        let point = view.convert(view.convert(CGPoint(x: 120, y: 110), from: page), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        // In reading mode PDFKit tracks a normal selection until mouse-up.
        let release = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: 0.1, windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(release, atStart: true)
        view.mouseDown(with: event)
        XCTAssertEqual(store.workspace?.inkStrokes, [stroke], "Clicking the original page must not erase an invisible annotation")
    }

    @MainActor
    func testInkUndoTargetsItsBookAcrossWindowsAndClosedTabs() throws {
        let fixture = try WorkbenchFixture()
        let first = fixture.store
        defer { first.app.prepareForTermination(); fixture.close() }
        first.open(fixture.book)
        let bookID = try XCTUnwrap(first.workspace?.id)
        let undo = first.pdfUndoManager
        let stroke = InkStroke(pageIndex: 0, points: [.init(x: 80, y: 80), .init(x: 160, y: 140)])
        undo.beginUndoGrouping()
        first.addInk(stroke, undoManager: undo)
        undo.endUndoGrouping()

        let second = first.app.newWindow()
        second.open(fixture.book)
        let other = InkStroke(pageIndex: 0, points: [.init(x: 220, y: 80), .init(x: 260, y: 140)])
        second.addInk(other, undoManager: nil)
        first.open(fixture.paper)
        undo.undo()
        XCTAssertTrue(first.workspace?.inkStrokes.isEmpty == true, "Undo must leave the selected PDF untouched")
        XCTAssertEqual(second.workspace?.inkStrokes, [other], "Undo removes the original stroke and retains another window's work")
        XCTAssertEqual(second.reader.inkStrokes, [other])

        second.closeBook()
        undo.redo()
        XCTAssertEqual(try first.repository.load(id: bookID)?.inkStrokes, [stroke, other], "Redo also works when the original book is closed")

        first.activateTab(bookID)
        undo.removeAllActions()
        undo.beginUndoGrouping()
        first.removeInk(id: stroke.id, undoManager: undo)
        undo.endUndoGrouping()
        first.open(fixture.paper)
        undo.undo()
        XCTAssertEqual(try first.repository.load(id: bookID)?.inkStrokes, [stroke, other], "Undoing the eraser restores the original book")
        XCTAssertTrue(first.workspace?.inkStrokes.isEmpty == true)
    }

    @MainActor
    func testEditionSelectionSurvivesHostedPDFUpdates() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = UserDefaults.standard.object(forKey: "lastWorkspaceID")
        defer { UserDefaults.standard.set(previous, forKey: "lastWorkspaceID") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.pdf")
        let image = NSImage(size: CGSize(width: 300, height: 400), flipped: false) { rect in NSColor.white.setFill(); rect.fill(); return true }
        let pdf = PDFDocument(); pdf.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        XCTAssertTrue(pdf.write(to: source))
        let store = StudyStore(root: root.appendingPathComponent("support")); store.open(source)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ReaderWindow(store: store))
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let page = try XCTUnwrap(store.reader.view?.document?.page(at: 0))
        store.addInk(InkStroke(pageIndex: 0, points: [.init(x: 50, y: 50), .init(x: 150, y: 140)]), undoManager: nil)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(page.annotations.filter { $0.type == "Ink" }.count, 1)
        store.reader.showAnnotations = false
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(store.reader.showAnnotations)
        XCTAssertTrue(page.annotations.isEmpty)
        store.reader.showAnnotations = true
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(store.reader.showAnnotations)
        XCTAssertEqual(page.annotations.filter { $0.type == "Ink" }.count, 1)
    }

    @MainActor
    func testPenReceivesPageInputAndInkSurvivesUndoZoomReopenAndExport() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = UserDefaults.standard.object(forKey: "lastWorkspaceID")
        defer { UserDefaults.standard.set(previous, forKey: "lastWorkspaceID") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.pdf")
        let image = NSImage(size: CGSize(width: 300, height: 400), flipped: false) { rect in NSColor.white.setFill(); rect.fill(); return true }
        let pdf = PDFDocument(); pdf.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        XCTAssertTrue(pdf.write(to: source)); let original = try Data(contentsOf: source)
        let store = StudyStore(root: root.appendingPathComponent("support")); store.open(source)
        let page = try XCTUnwrap(store.document?.page(at: 0))
        let view = RegionPDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 700))
        view.controller = store.reader; store.reader.view = view; view.document = store.document; view.autoScales = true
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; defer { window.close() }
        view.layoutDocumentView(); view.layoutSubtreeIfNeeded()
        let clean = try PDFRegionRenderer.png(page: page, region: .init(x: 40, y: 40, width: 130, height: 130))
        store.reader.regionMode = true; store.reader.inkMode = true
        XCTAssertFalse(store.reader.regionMode)
        let start = view.convert(CGPoint(x: 50, y: 50), from: page), end = view.convert(CGPoint(x: 150, y: 140), from: page)
        XCTAssertTrue(view.hitTest(view.convert(start, to: view.superview)) === view)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        let undo = UndoManager(); undo.groupsByEvent = false
        store.reader.onInk = { store.addInk($0, undoManager: undo) }
        undo.beginUndoGrouping()
        view.mouseDown(with: try event(.leftMouseDown, start)); view.mouseDragged(with: try event(.leftMouseDragged, end))
        view.mouseUp(with: try event(.leftMouseUp, end)); undo.endUndoGrouping()
        let stroke = try XCTUnwrap(store.workspace?.inkStrokes.first)
        XCTAssertEqual(stroke.points.first?.x ?? 0, 50, accuracy: 0.01); XCTAssertEqual(stroke.points.last?.y ?? 0, 140, accuracy: 0.01)
        XCTAssertEqual(page.annotations.filter { $0.type == "Ink" }.count, 1)
        XCTAssertEqual(try PDFRegionRenderer.png(page: page, region: .init(x: 40, y: 40, width: 130, height: 130)), clean, "Source crops exclude handwriting.")
        undo.undo(); XCTAssertTrue(store.workspace?.inkStrokes.isEmpty == true); XCTAssertTrue(page.annotations.isEmpty)
        undo.redo(); XCTAssertEqual(store.workspace?.inkStrokes, [stroke])
        view.autoScales = false; view.scaleFactor = 2
        store.reader.showAnnotations = false; store.reader.syncInk([stroke], in: try XCTUnwrap(store.document)); XCTAssertTrue(page.annotations.isEmpty)
        store.reader.showAnnotations = true; store.reader.syncInk([stroke], in: try XCTUnwrap(store.document)); XCTAssertEqual(page.annotations.count, 1)
        let reopened = StudyStore(root: root.appendingPathComponent("support")); reopened.open(source)
        XCTAssertEqual(reopened.workspace?.inkStrokes, [stroke]); XCTAssertEqual(reopened.workspace?.schemaVersion, 10)
        try reopened.repository.export(try XCTUnwrap(reopened.workspace), to: root.appendingPathComponent("export"))
        let svg = try String(contentsOf: root.appendingPathComponent("export/assets/ink-page-1.svg"), encoding: .utf8)
        XCTAssertTrue(svg.contains("<polyline")); XCTAssertTrue(svg.contains(stroke.color.hex))
        try reopened.exportPersonalPDF(to: root.appendingPathComponent("edition.pdf"))
        XCTAssertEqual(PDFDocument(url: root.appendingPathComponent("edition.pdf"))?.page(at: 0)?.annotations.filter { $0.type == "Ink" }.count, 1)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertThrowsError(try reopened.exportPersonalPDF(to: source))
        store.reader.inkMode = true; store.reader.inkEraser = true
        store.reader.onEraseInk = { store.removeInk(id: $0, undoManager: undo) }
        undo.beginUndoGrouping(); view.mouseDown(with: try event(.leftMouseDown, view.convert(CGPoint(x: 100, y: 95), from: page))); undo.endUndoGrouping()
        XCTAssertTrue(store.workspace?.inkStrokes.isEmpty == true); undo.undo(); XCTAssertEqual(store.workspace?.inkStrokes, [stroke])
    }

    func testSchemaThreeLoadsWithNoInkAndRetainsItsNotes() throws {
        var workspace = StudyWorkspace(id: "legacy", title: "Legacy", sourcePath: "/local.pdf", sourceBookmark: nil, fingerprint: "legacy")
        workspace.notes = [StudyNote(anchor: SourceAnchor(pageIndex: 0, pageLabel: "1", region: .init(x: 1, y: 2, width: 3, height: 4), quote: "q", imageName: "a.png"), body: "Keep this.")]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: WorkspaceRepository.encoder.encode(workspace)) as? [String: Any])
        object["schemaVersion"] = 3; object.removeValue(forKey: "inkStrokes")
        let loaded = try WorkspaceRepository.decoder.decode(StudyWorkspace.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(loaded.inkStrokes.isEmpty); XCTAssertEqual(loaded.notes.map(\.body), ["Keep this."])
    }
}
