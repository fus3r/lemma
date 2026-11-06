import XCTest
import AppKit
import LemmaCore
@testable import Lemma

final class ReaderControlsRound4Tests: XCTestCase {
    @MainActor
    func testSameBookNoteSearchRevealsItsSourceOverAFile() async throws {
        let fixture = try WorkbenchFixture(hosted: true), store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        store.open(fixture.book)
        try await fixture.settle(300)
        store.reader.selection = (3, CGRect(x: 72, y: 600, width: 330, height: 35), "Exercises")
        store.addNote()
        let note = try XCTUnwrap(store.currentNote), book = try XCTUnwrap(store.workspace)
        let name = try store.createWorkspaceFile(name: "Notes", kind: .markdown)
        let file = try XCTUnwrap(store.activeFile)
        store.updateWorkspaceFile(file, text: "Keep these notes")
        try await fixture.settle()

        store.openSearchResult(workspace: book, note: note)
        try await fixture.settle(450)

        XCTAssertNil(store.activeFileName, "A matching note in the retained book must reveal its PDF source")
        XCTAssertEqual(store.selectedNoteID, note.id)
        XCTAssertEqual(store.reader.pageNumber, 4)
        XCTAssertTrue(store.fileTabs.contains(name))
        XCTAssertEqual(file.text, "Keep these notes")
    }

    @MainActor
    func testDebugStepRevealsItsRetainedBookAfterWorkingInAFile() async throws {
        let fixture = try WorkbenchFixture(hosted: true), store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        store.open(fixture.book)
        try await fixture.settle(300)
        store.reader.goToPage(2)
        try await fixture.settle()
        store.startDebugging()
        XCTAssertNotNil(store.debug)
        let line = try XCTUnwrap(store.reader.rulerLine)
        let name = try store.createWorkspaceFile(name: "Notes", kind: .text)
        try await fixture.settle()

        store.debugStepOver()
        try await fixture.settle(400)

        XCTAssertNil(store.activeFileName, "A debug step must show the proof line it steps to")
        XCTAssertNotEqual(store.reader.rulerLine, line)
        XCTAssertTrue(store.fileTabs.contains(name))
    }

    @MainActor
    func testStatementNavigationRevealsItsRetainedBookOverAFile() async throws {
        let fixture = try WorkbenchFixture(hosted: true), store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        store.open(fixture.book)
        try await fixture.waitForAnalysis()
        try await fixture.settle()
        let key = ReferenceKey(kind: .equation, number: "1.1")
        let target = try XCTUnwrap(store.analysis?.target(for: key))
        let name = try store.createWorkspaceFile(name: "Notes", kind: .markdown)
        let file = try XCTUnwrap(store.activeFile)
        store.updateWorkspaceFile(file, text: "Keep my notes")
        try await fixture.settle()

        store.goToKey(key)
        try await fixture.settle(400)

        XCTAssertNil(store.activeFileName, "Choosing a Results/Hierarchy statement must display its PDF")
        XCTAssertEqual(store.reader.pageNumber, target.pageIndex + 1)
        XCTAssertEqual(store.reader.flash?.pageIndex, target.pageIndex)
        XCTAssertTrue(store.fileTabs.contains(name))
        XCTAssertEqual(file.text, "Keep my notes")
    }

    @MainActor
    func testBreakpointNavigationRevealsItsRetainedBookOverAFile() async throws {
        let fixture = try WorkbenchFixture(hosted: true), store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        store.open(fixture.book)
        try await fixture.settle(300)
        let lines = store.reader.readingLines(onPage: 2)
        let line = try XCTUnwrap(lines.first)
        let breakpoint = LineBreakpoint(pageIndex: 2, y: line.midY, text: "Returning to the model")
        let name = try store.createWorkspaceFile(name: "Notes", kind: .text)
        try await fixture.settle()

        store.goToBreakpoint(breakpoint)
        try await fixture.settle(400)

        XCTAssertNil(store.activeFileName, "Clicking a breakpoint must reveal its source PDF")
        XCTAssertEqual(store.reader.pageNumber, 3)
        XCTAssertTrue(store.fileTabs.contains(name))
    }

    @MainActor
    func testResumeQuestionMarkRevealsItsRetainedBookOverAFile() async throws {
        let fixture = try WorkbenchFixture(hosted: true), store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        store.open(fixture.book)
        try await fixture.settle(300)
        let anchor = SourceAnchor(pageIndex: 2, pageLabel: "2", region: PageRegion(x: 72, y: 665, width: 400, height: 30),
                                  quote: "Returning to the model", imageName: "question.png")
        store.workspace?.notes.append(StudyNote(anchor: anchor, question: StudyNote.quickMarkPrefix, kind: .question))
        let name = try store.createWorkspaceFile(name: "Notes", kind: .text)
        try await fixture.settle()

        store.resumeAtFirstMark()
        try await fixture.settle(400)

        XCTAssertNil(store.activeFileName, "Resume at First ? must show the marked PDF passage")
        XCTAssertEqual(store.reader.pageNumber, 3)
        XCTAssertEqual(store.reader.flash?.pageIndex, 2)
        XCTAssertTrue(store.fileTabs.contains(name))
    }

    @MainActor
    func testSymbolDefinitionNavigationRevealsItsRetainedBookOverAFile() async throws {
        let fixture = try WorkbenchFixture(hosted: true), store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        store.open(fixture.book)
        try await fixture.settle(300)
        let definition = SymbolDefinition(symbol: "X", meaning: "design matrix", pageIndex: 1, location: 0, explicit: true)
        let name = try store.createWorkspaceFile(name: "Notes", kind: .text)
        try await fixture.settle()

        store.goToSymbolDefinition(definition)
        try await fixture.settle(400)

        XCTAssertNil(store.activeFileName, "Go to a symbol's definition must show its source PDF")
        XCTAssertEqual(store.reader.pageNumber, 2)
        XCTAssertEqual(store.reader.flash?.pageIndex, 1)
        XCTAssertTrue(store.fileTabs.contains(name))
    }
}
