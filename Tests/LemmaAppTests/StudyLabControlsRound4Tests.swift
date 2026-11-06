import XCTest
import AppKit
import SwiftUI
import LemmaCore
@testable import Lemma

final class StudyLabControlsRound4Tests: XCTestCase {
    @MainActor
    func testEditingClozeInAnotherWindowUpdatesTheActiveRecallMask() async throws {
        let fixture = try WorkbenchFixture()
        let first = fixture.store.app.claimWindow(nil)
        defer { first.app.prepareForTermination(); fixture.close() }
        first.open(fixture.book)
        first.reader.selection = (0, CGRect(x: 40, y: 600, width: 220, height: 40), "Recall this passage")
        first.addNote()
        let note = try XCTUnwrap(first.currentNote)
        let initial = PageRegion(x: 70, y: 610, width: 50, height: 20)
        let added = PageRegion(x: 160, y: 610, width: 70, height: 20)
        first.updateNote(id: note.id) { $0.masks = [initial] }
        first.addToReview(id: note.id)
        fixture.window.contentView = NSHostingView(rootView: ReviewPane(store: first))
        fixture.window.orderFront(nil)
        try await fixture.settle()
        XCTAssertEqual(first.reader.recallMaskRegions, [initial])

        let second = first.app.newWindow()
        _ = first.app.claimWindow(second.windowID)
        second.open(fixture.book)
        second.updateNote(id: note.id) { $0.masks.append(added) }
        try await fixture.settle()

        XCTAssertEqual(first.workspace?.notes.first(where: { $0.id == note.id })?.masks, [initial, added])
        XCTAssertEqual(first.reader.recallMask, note.anchor)
        XCTAssertEqual(first.reader.recallMaskRegions, [initial, added], "The PDF must hide newly added cloze parts while the same recall card remains open")

        second.updateNote(id: note.id) { $0.masks = [added] }
        try await fixture.settle()
        XCTAssertEqual(first.reader.recallMaskRegions, [added], "Removing a cloze part must also update the visible PDF mask")
    }
}
