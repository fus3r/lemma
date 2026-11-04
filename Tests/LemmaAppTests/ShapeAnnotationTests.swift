import XCTest
import AppKit
import PDFKit
import SwiftUI
import LemmaCore
@testable import Lemma

final class ShapeAnnotationTests: XCTestCase {
    @MainActor
    func testHostedToolboxRefreshesRedoAfterUndo() async throws {
        let fixture = try WorkbenchFixture()
        let store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        store.open(fixture.book)
        let shape = PageShape(pageIndex: 0, kind: .rectangle, start: .init(x: 80, y: 80), end: .init(x: 220, y: 180))
        store.addShape(shape); store.pdfUndoManager.removeAllActions(); store.reader.selectShape(shape)
        let host = NSHostingView(rootView: AnnotationToolbox(store: store))
        host.frame = CGRect(x: 0, y: 0, width: 560, height: 70)
        fixture.window.contentView = host; fixture.window.makeKeyAndOrderFront(nil)
        try await fixture.settle(100)
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        // SwiftUI's native borderless buttons keep their AX identifiers on virtual elements.
        // The three actions occupy the toolbox's lower row, in Undo/Redo/Delete order.
        func actions() throws -> [NSButton] {
            let all = buttons(in: host)
            let bottom = try XCTUnwrap(all.map { host.convert($0.bounds, from: $0).midY }.max())
            let result = all.filter { abs(host.convert($0.bounds, from: $0).midY - bottom) < 5 }
                .sorted { host.convert($0.bounds, from: $0).midX < host.convert($1.bounds, from: $1).midX }
            XCTAssertEqual(result.count, 3)
            return result
        }
        try actions()[2].performClick(nil)
        try await fixture.settle(100)
        XCTAssertTrue(store.workspace?.shapes.isEmpty == true)
        let undo = try actions()[0]
        XCTAssertTrue(undo.isEnabled); undo.performClick(nil)
        try await fixture.settle(100)
        XCTAssertEqual(store.workspace?.shapes, [shape])
        let redo = try actions()[1]
        XCTAssertTrue(redo.isEnabled, "The toolbar must follow UndoManager's final state, after the shape update")
        if redo.isEnabled {
            redo.performClick(nil)
            try await fixture.settle(100)
            XCTAssertTrue(store.workspace?.shapes.isEmpty == true)
        }

    }

    @MainActor
    func testShapesReceivePageDragsAndKeepTheirGeometryAtZoomAndRotation() throws {
        let fixture = try WorkbenchFixture()
        let store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        store.open(fixture.book)
        let page = try XCTUnwrap(store.document?.page(at: 0))
        page.rotation = 90
        let view = host(store, in: fixture.window)
        view.autoScales = false; view.scaleFactor = 1.4; view.layoutDocumentView()
        for kind in PageShapeKind.allCases {
            store.reader.inkMode = true
            store.reader.drawingTool = try XCTUnwrap(DrawingTool(rawValue: kind.rawValue))
            let start = CGPoint(x: 240, y: 250)
            let end = kind.isClosed ? CGPoint(x: 100, y: 150) : CGPoint(x: 100, y: 250)
            let hit = view.convert(view.convert(start, from: page), to: view.superview)
            XCTAssertTrue(view.hitTest(hit) === view)
            try drag(view, page: page, window: fixture.window, from: start, to: end)
            let shape = try XCTUnwrap(store.workspace?.shapes.last)
            XCTAssertEqual(shape.kind, kind)
            XCTAssertEqual(shape.start.x, start.x, accuracy: 0.01)
            XCTAssertEqual(shape.end.y, end.y, accuracy: 0.01)
            XCTAssertEqual(shape.end.x, end.x, accuracy: 0.01)
            XCTAssertEqual(shape.annotation()?.type, kind == .rectangle ? "Square" : kind == .ellipse ? "Circle" : "Line")
        }
        XCTAssertEqual(store.workspace?.shapes.count, 4)
        XCTAssertEqual(page.annotations.count, 4)
        store.reader.drawingTool = .rectangle
        try drag(view, page: page, window: fixture.window, from: CGPoint(x: 60, y: 80), to: CGPoint(x: 130, y: 120), flags: .shift)
        let square = try XCTUnwrap(store.workspace?.shapes.last)
        XCTAssertEqual(square.rect.width, square.rect.height, accuracy: 0.01)
        let count = store.workspace?.shapes.count
        try drag(view, page: page, window: fixture.window, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 40, y: 40))
        XCTAssertEqual(store.workspace?.shapes.count, count, "A click alone does not create an empty box")
    }

    @MainActor
    func testShapeMoveResizeStyleDeleteUndoPersistenceAndPDFExport() throws {
        let fixture = try WorkbenchFixture()
        let store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        let original = try Data(contentsOf: fixture.book)
        store.open(fixture.book)
        let bookID = try XCTUnwrap(store.workspace?.id), page = try XCTUnwrap(store.document?.page(at: 0))
        let view = host(store, in: fixture.window)
        let region = PageRegion(x: 40, y: 40, width: 260, height: 210)
        let crop = try PDFRegionRenderer.png(page: page, region: region)
        let shape = PageShape(pageIndex: 0, kind: .rectangle, start: .init(x: 80, y: 80), end: .init(x: 220, y: 180), colorHex: "#CC3388", width: 3, fillOpacity: 0.15, dashed: true)
        store.addShape(shape)
        store.reader.inkMode = false
        try drag(view, page: page, window: fixture.window, from: CGPoint(x: 140, y: 80), to: CGPoint(x: 160, y: 100))
        var moved = try XCTUnwrap(store.workspace?.shapes.first)
        XCTAssertEqual(moved.start.x, 100, accuracy: 0.01)
        XCTAssertEqual(moved.start.y, 100, accuracy: 0.01)
        XCTAssertEqual(store.reader.drawingTool, .select)
        store.pdfUndoManager.undo(); XCTAssertEqual(store.workspace?.shapes, [shape])
        store.pdfUndoManager.redo(); XCTAssertEqual(store.workspace?.shapes, [moved])
        try drag(view, page: page, window: fixture.window, from: CGPoint(x: moved.end.x, y: moved.end.y), to: CGPoint(x: 275, y: 230))
        moved = try XCTUnwrap(store.workspace?.shapes.first)
        XCTAssertEqual(moved.start.x, 100, accuracy: 0.01, "Resizing keeps the opposite handle fixed")
        XCTAssertEqual(moved.start.y, 100, accuracy: 0.01)
        XCTAssertEqual(moved.end.x, 275, accuracy: 0.01)
        XCTAssertEqual(moved.end.y, 230, accuracy: 0.01)
        var recolored = moved; recolored.colorHex = "#228844"; recolored.width = 5
        store.replaceShape(recolored, bookID: bookID)
        store.pdfUndoManager.undo(); XCTAssertEqual(store.workspace?.shapes.first, moved)
        store.pdfUndoManager.redo(); XCTAssertEqual(store.workspace?.shapes.first, recolored)
        store.removeShape(id: shape.id)
        XCTAssertTrue(page.annotations.isEmpty)
        store.pdfUndoManager.undo(); XCTAssertEqual(store.workspace?.shapes.first, recolored)
        store.reader.showAnnotations = false; store.reader.syncShapes([recolored], in: try XCTUnwrap(store.document))
        XCTAssertTrue(page.annotations.isEmpty); XCTAssertNil(store.reader.activeShapeID)
        store.reader.showAnnotations = true; store.reader.syncShapes([recolored], in: try XCTUnwrap(store.document))
        XCTAssertEqual(page.annotations.count, 1)
        XCTAssertEqual(try PDFRegionRenderer.png(page: page, region: region), crop, "Source crops exclude personal shapes")
        store.flush()
        XCTAssertEqual(try store.repository.load(id: bookID)?.shapes, [recolored])
        try store.exportPersonalPDF(to: fixture.root.appendingPathComponent("annotated.pdf"))
        let exported = try XCTUnwrap(PDFDocument(url: fixture.root.appendingPathComponent("annotated.pdf"))?.page(at: 0)?.annotations.first)
        XCTAssertEqual(exported.type, "Square"); XCTAssertEqual(exported.border?.lineWidth, 5)
        XCTAssertEqual(exported.border?.style, .dashed)
        XCTAssertNotNil(exported.interiorColor)
        XCTAssertEqual(try Data(contentsOf: fixture.book), original)
        XCTAssertThrowsError(try store.exportPersonalPDF(to: fixture.book))
    }

    @MainActor
    func testShapeUndoTargetsTheOriginalBookAcrossWindowsAndClosedTabs() throws {
        let fixture = try WorkbenchFixture()
        let first = fixture.store
        defer { first.app.prepareForTermination(); fixture.close() }
        first.open(fixture.book)
        let id = try XCTUnwrap(first.workspace?.id)
        let shape = PageShape(pageIndex: 0, kind: .arrow, start: .init(x: 80, y: 100), end: .init(x: 200, y: 200))
        first.addShape(shape)
        let second = first.app.newWindow(); second.open(fixture.book)
        let other = PageShape(pageIndex: 0, kind: .ellipse, start: .init(x: 250, y: 100), end: .init(x: 350, y: 200))
        second.addShape(other)
        first.open(fixture.paper)
        first.pdfUndoManager.undo()
        XCTAssertTrue(first.workspace?.shapes.isEmpty == true)
        XCTAssertEqual(second.workspace?.shapes, [other])
        second.closeBook()
        first.pdfUndoManager.redo()
        XCTAssertEqual(try first.repository.load(id: id)?.shapes, [shape, other])
    }

    @MainActor
    func testEscapeCancelsDraftAndEraserRemovesOnlyTheHitShape() throws {
        let fixture = try WorkbenchFixture()
        let store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        store.open(fixture.book)
        let view = host(store, in: fixture.window), page = try XCTUnwrap(store.document?.page(at: 0))
        store.reader.inkMode = true; store.reader.drawingTool = .arrow
        view.mouseDown(with: try event(.leftMouseDown, in: view, page: page, window: fixture.window, at: CGPoint(x: 80, y: 80)))
        view.mouseDragged(with: try event(.leftMouseDragged, in: view, page: page, window: fixture.window, at: CGPoint(x: 200, y: 160)))
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        view.keyDown(with: escape)
        XCTAssertNil(view.shapeGesture); XCTAssertTrue(store.workspace?.shapes.isEmpty == true)
        try drag(view, page: page, window: fixture.window, from: CGPoint(x: 80, y: 80), to: CGPoint(x: 200, y: 160))
        let shape = try XCTUnwrap(store.workspace?.shapes.first)
        store.reader.drawingTool = .eraser
        view.mouseDown(with: try event(.leftMouseDown, in: view, page: page, window: fixture.window, at: CGPoint(x: 140, y: 120)))
        XCTAssertTrue(store.workspace?.shapes.isEmpty == true)
        store.pdfUndoManager.undo(); XCTAssertEqual(store.workspace?.shapes, [shape])
    }

    func testLegacyWorkspaceWithoutShapesRetainsExistingInk() throws {
        var workspace = StudyWorkspace(id: "legacy", title: "Legacy", sourcePath: "/book.pdf", sourceBookmark: nil, fingerprint: "legacy")
        workspace.inkStrokes = [InkStroke(pageIndex: 0, points: [.init(x: 20, y: 20), .init(x: 30, y: 40)])]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: WorkspaceRepository.encoder.encode(workspace)) as? [String: Any])
        object.removeValue(forKey: "shapes")
        let decoded = try WorkspaceRepository.decoder.decode(StudyWorkspace.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(decoded.shapes.isEmpty); XCTAssertEqual(decoded.inkStrokes, workspace.inkStrokes)
    }

    @MainActor private func host(_ store: StudyStore, in window: NSWindow) -> RegionPDFView {
        let view = RegionPDFView(frame: CGRect(x: 0, y: 0, width: 900, height: 800))
        view.controller = store.reader; store.reader.view = view; view.document = store.document
        view.displayMode = .singlePage; view.autoScales = true
        window.contentView = view; view.layoutDocumentView(); view.layoutSubtreeIfNeeded()
        store.pdfUndoManager.groupsByEvent = false
        return view
    }

    @MainActor private func event(_ type: NSEvent.EventType, in view: RegionPDFView, page: PDFPage, window: NSWindow, at point: CGPoint, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(view.convert(point, from: page), to: nil), modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }

    @MainActor private func drag(_ view: RegionPDFView, page: PDFPage, window: NSWindow, from start: CGPoint, to end: CGPoint, flags: NSEvent.ModifierFlags = []) throws {
        view.mouseDown(with: try event(.leftMouseDown, in: view, page: page, window: window, at: start, flags: flags))
        view.mouseDragged(with: try event(.leftMouseDragged, in: view, page: page, window: window, at: end, flags: flags))
        view.mouseUp(with: try event(.leftMouseUp, in: view, page: page, window: window, at: end, flags: flags))
    }
}
