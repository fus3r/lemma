import XCTest
import AppKit
import PDFKit
import LemmaCore
@testable import Lemma

final class HighlightEditingTests: XCTestCase {
    @MainActor
    func testInwardShiftDragShortensEitherEndAndAStationaryClickDoesNothing() async throws {
        let fixture = try WorkbenchFixture(hosted: true)
        let store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        store.open(fixture.book)
        try await fixture.settle(250)
        let view = try XCTUnwrap(store.reader.view), page = try XCTUnwrap(store.document?.page(at: 0))
        let text = try XCTUnwrap(page.string) as NSString
        let letters = (0..<min(text.length, page.numberOfCharacters)).filter {
            text.substring(with: NSRange(location: $0, length: 1)).rangeOfCharacter(from: .letters) != nil
        }
        let selection = try XCTUnwrap(page.selection(for: NSRange(location: letters[2], length: letters[23] - letters[2] + 1)))
        view.setCurrentSelection(selection, animate: false)
        store.reader.selection = (0, selection.bounds(for: page), selection.string ?? "")
        var swatch = HighlightSwatch(.rose); swatch.hex = "#9B59B6"
        store.highlightSelection(swatch: swatch, style: .underline)
        let original = try XCTUnwrap(store.workspace?.highlights.first)
        let undo = store.pdfUndoManager
        undo.removeAllActions(); undo.groupsByEvent = false
        func event(_ type: NSEvent.EventType, character: Int) throws -> NSEvent {
            let bounds = page.characterBounds(at: character)
            let point = view.convert(CGPoint(x: bounds.midX, y: bounds.midY), from: page)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: .shift,
                                                   timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil,
                                                   eventNumber: 1, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, character: letters[3]))
        view.mouseUp(with: try event(.leftMouseUp, character: letters[3]))
        XCTAssertEqual(store.workspace?.highlights.first, original)
        XCTAssertFalse(undo.canUndo, "Shift-click without a drag must not trim a mark")
        view.mouseDown(with: try event(.leftMouseDown, character: letters[3]))
        view.mouseDragged(with: try event(.leftMouseDragged, character: letters[9]))
        view.mouseUp(with: try event(.leftMouseUp, character: letters[3]))
        XCTAssertEqual(store.workspace?.highlights.first, original)
        XCTAssertFalse(undo.canUndo, "Returning to the starting point cancels the resize")
        for (start, end) in [(letters[3], letters[9]), (letters[22], letters[16])] {
            view.mouseDown(with: try event(.leftMouseDown, character: start))
            view.mouseDragged(with: try event(.leftMouseDragged, character: end))
            XCTAssertEqual(store.workspace?.highlights.first, original, "The drag only previews the change")
            view.mouseUp(with: try event(.leftMouseUp, character: end))
            let shortened = try XCTUnwrap(store.workspace?.highlights.first)
            XCTAssertEqual(shortened.id, original.id)
            XCTAssertEqual(shortened.colorHex, original.colorHex)
            XCTAssertEqual(shortened.style, .underline)
            XCTAssertFalse(shortened.quote.isEmpty)
            XCTAssertLessThan(shortened.quote.count, original.quote.count)
            XCTAssertEqual(undo.undoActionName, "Shorten Underline")
            undo.undo(); XCTAssertEqual(store.workspace?.highlights.first, original)
            XCTAssertFalse(undo.canUndo, "Resizing is one undo step")
            undo.redo(); XCTAssertEqual(store.workspace?.highlights.first, shortened)
            undo.undo()
        }
    }

    @MainActor
    func testShiftDragExtendsEitherEndAndUndoRestoresTheOriginal() async throws {
        let fixture = try WorkbenchFixture(hosted: true)
        let store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        store.open(fixture.book)
        try await fixture.settle(250)
        let view = try XCTUnwrap(store.reader.view)
        let page = try XCTUnwrap(store.document?.page(at: 0))
        let text = try XCTUnwrap(page.string) as NSString
        let letters = (0..<min(text.length, page.numberOfCharacters)).filter {
            text.substring(with: NSRange(location: $0, length: 1)).rangeOfCharacter(from: .letters) != nil
        }
        XCTAssertGreaterThan(letters.count, 24)
        let range = NSRange(location: letters[8], length: letters[15] - letters[8] + 1)
        let selection = try XCTUnwrap(page.selection(for: range))
        let undo = store.pdfUndoManager
        undo.removeAllActions(); undo.groupsByEvent = false
        view.setCurrentSelection(selection, animate: false)
        store.reader.selection = (0, selection.bounds(for: page), selection.string ?? "")
        store.highlightSelection()
        let original = try XCTUnwrap(store.workspace?.highlights.first)
        undo.removeAllActions()

        func event(_ type: NSEvent.EventType, character: Int) throws -> NSEvent {
            let bounds = page.characterBounds(at: character)
            let point = view.convert(CGPoint(x: bounds.midX, y: bounds.midY), from: page)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: .shift,
                                                   timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil,
                                                   eventNumber: 1, clickCount: 1, pressure: 1))
        }
        for endpoint in [letters[2], letters[23]] {
            view.mouseDown(with: try event(.leftMouseDown, character: letters[10]))
            XCTAssertNotNil(view.highlightDrag)
            view.mouseDragged(with: try event(.leftMouseDragged, character: endpoint))
            XCTAssertEqual(store.workspace?.highlights.first, original, "Dragging previews without saving intermediate marks")
            view.mouseUp(with: try event(.leftMouseUp, character: endpoint))
            let extended = try XCTUnwrap(store.workspace?.highlights.first)
            XCTAssertEqual(extended.id, original.id)
            XCTAssertGreaterThan(extended.quote.count, original.quote.count)
            XCTAssertNotEqual(extended.regions, original.regions)
            XCTAssertEqual(undo.undoActionName, "Extend Highlight")
            undo.undo(); XCTAssertEqual(store.workspace?.highlights.first, original)
            undo.redo(); XCTAssertEqual(store.workspace?.highlights.first, extended)
            undo.undo()
        }
    }

    @MainActor
    func testRightClickOnAHighlightOffersRemovalWithUndo() async throws {
        let fixture = try WorkbenchFixture(hosted: true)
        let store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        store.open(fixture.book)
        try await fixture.settle(200)
        let view = try XCTUnwrap(store.reader.view), page = try XCTUnwrap(store.document?.page(at: 0))
        let selection = try XCTUnwrap(page.selection(for: NSRange(location: 10, length: 12)))
        view.setCurrentSelection(selection, animate: false)
        store.reader.selection = (0, selection.bounds(for: page), selection.string ?? "")
        let undo = store.pdfUndoManager
        undo.removeAllActions(); undo.groupsByEvent = false
        store.highlightSelection()
        let highlight = try XCTUnwrap(store.workspace?.highlights.first), region = try XCTUnwrap(highlight.regions.first)
        let point = view.convert(CGPoint(x: region.rect.midX, y: region.rect.midY), from: page)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: view.convert(point, to: nil), modifierFlags: [],
                                                   timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil,
                                                   eventNumber: 2, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(view.menu(for: event))
        let remove = try XCTUnwrap(menu.items.first { $0.title == "Remove Highlight" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(remove.action), to: remove.target, from: remove))
        XCTAssertTrue(store.workspace?.highlights.isEmpty == true)
        undo.undo()
        XCTAssertEqual(store.workspace?.highlights, [highlight])
    }
}
