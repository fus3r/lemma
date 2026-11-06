import XCTest
import AppKit
import SwiftUI
import LemmaCore
@testable import Lemma

final class ReviewPaneTests: XCTestCase {
    @MainActor
    func testReviewFollowsTheRemainingAndNewlyAddedDueCards() async throws {
        let fixture = try WorkbenchFixture()
        let store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        store.open(fixture.book)
        store.reader.selection = (0, CGRect(x: 40, y: 600, width: 220, height: 40), "First recall")
        store.addNote()
        let first = try XCTUnwrap(store.currentNote)
        store.addToReview(id: first.id)
        store.reader.selection = (1, CGRect(x: 40, y: 500, width: 220, height: 40), "Second recall")
        store.addNote()
        let second = try XCTUnwrap(store.currentNote)
        store.addToReview(id: second.id)
        fixture.window.contentView = NSHostingView(rootView: ReviewPane(store: store))
        fixture.window.orderFront(nil)
        try await fixture.settle()
        XCTAssertEqual(store.reader.recallMask, first.anchor)

        // Removing a note through the application menu should continue the open review queue.
        store.removeNote(id: first.id, undoManager: store.pdfUndoManager)
        try await fixture.settle()
        XCTAssertEqual(store.reviewNotes.map(\.id), [second.id])
        XCTAssertEqual(store.reader.recallMask, second.anchor, "The next due card must replace the removed one")

        store.removeFromReview(id: second.id)
        try await fixture.settle()
        XCTAssertNil(store.reader.recallMask)
        // A shared-window edit can add a card while this review pane is already on its empty overview.
        store.addToReview(id: second.id)
        try await fixture.settle()
        XCTAssertEqual(store.reader.recallMask, second.anchor, "An open review pane must show the newly due card")
    }

    @MainActor
    func testRemovingARecalledNoteClearsItsSourceMask() async throws {
        let fixture = try WorkbenchFixture()
        let store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        store.open(fixture.book)
        store.reader.selection = (0, CGRect(x: 40, y: 600, width: 220, height: 40), "Recall this passage")
        store.addNote()
        let note = try XCTUnwrap(store.currentNote)
        let mask = PageRegion(x: 80, y: 610, width: 60, height: 20)
        store.updateNote(id: note.id) { $0.masks = [mask] }
        store.addToReview(id: note.id)
        fixture.window.contentView = NSHostingView(rootView: ReviewPane(store: store))
        fixture.window.orderFront(nil)
        try await fixture.settle()
        XCTAssertEqual(store.reader.recallMask, note.anchor)
        XCTAssertEqual(store.reader.recallMaskRegions, [mask])

        // The note can be removed through the application menu while the review card is open.
        store.removeNote(id: note.id, undoManager: store.pdfUndoManager)
        try await fixture.settle()
        XCTAssertTrue(store.reviewDeck.isEmpty)
        XCTAssertNil(store.reader.recallMask, "An overview with no review card must not keep hiding the deleted source.")
        XCTAssertTrue(store.reader.recallMaskRegions.isEmpty)
    }
}
