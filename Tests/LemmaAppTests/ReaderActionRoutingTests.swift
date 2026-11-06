import XCTest
import AppKit
import LemmaCore
@testable import Lemma

final class ReaderActionRoutingTests: XCTestCase {
    @MainActor
    func testEditingASharedDerivationRefreshesBothWindowsVerdicts() async throws {
        let fixture = try WorkbenchFixture(), app = fixture.store.app
        let first = app.claimWindow(nil)
        defer { app.prepareForTermination(); fixture.close() }
        first.open(fixture.book)
        let id = try XCTUnwrap(first.newDerivation(title: "Square", source: "(a+b)^2 = a^2 + 2ab + b^2"))
        await first.derivationChecks[id]?.value
        XCTAssertEqual(first.derivationReports[id]?.holds, 1)
        let second = app.newWindow()
        _ = app.claimWindow(second.windowID)
        second.open(fixture.book)
        second.openDerivation(id)
        await second.derivationChecks[id]?.value
        XCTAssertEqual(second.derivationReports[id]?.holds, 1)

        first.updateDerivation(id) { $0.source = "(a+b)^2 = a^2 + b^2" }
        await first.derivationChecks[id]?.value
        await second.derivationChecks[id]?.value

        XCTAssertEqual(second.derivation(id)?.source, "(a+b)^2 = a^2 + b^2")
        XCTAssertEqual(first.derivationReports[id]?.fails, 1)
        XCTAssertEqual(second.derivationReports[id]?.fails, 1, "A shared source edit must replace the other window's previous successful verdict")
        let derivation = try XCTUnwrap(second.derivation(id))
        XCTAssertTrue(second.derivationMarkdown(derivation).contains("✗ $$"), "Export must use the verdict for the displayed source")
    }

    @MainActor
    func testOpeningASearchHitRevealsItsBookOverAWorkspaceFile() async throws {
        let fixture = try WorkbenchFixture(hosted: true), store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        store.open(fixture.book)
        try await fixture.settle(300)
        let bookID = try XCTUnwrap(store.workspace?.id)
        let name = try store.createWorkspaceFile(name: "Working notes", kind: .text)
        let file = try XCTUnwrap(store.activeFile)
        store.updateWorkspaceFile(file, text: "Keep these notes")
        try await fixture.settle(150)

        let hit = LibraryTextSearch.Hit(id: "hit", bookID: bookID, pageIndex: 1, pageLabel: "2",
                                       range: NSRange(location: 0, length: 5), before: "", match: "", after: "")
        store.openSearchHit(hit)
        try await fixture.settle(500)

        XCTAssertNil(store.activeFileName, "Choosing a PDF search result must reveal its page, including when that PDF is already the retained book")
        XCTAssertEqual(store.activeMainTabID, bookID)
        XCTAssertEqual(store.reader.pageNumber, 2)
        XCTAssertTrue(store.fileTabs.contains(name), "The previous file remains open")
        XCTAssertEqual(file.text, "Keep these notes")
    }

    @MainActor
    func testOpeningAnIndexedPageResultRevealsItsBookOverAWorkspaceFile() async throws {
        let fixture = try WorkbenchFixture(hosted: true), store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        store.open(fixture.book)
        try await fixture.settle(300)
        let bookID = try XCTUnwrap(store.workspace?.id)
        let name = try store.createWorkspaceFile(name: "Working notes", kind: .text)
        try await fixture.settle(150)
        let indexed = IndexedPage(pageIndex: 1, pageLabel: "2", origin: .pdfText,
                                  passages: [.init(text: "A matching passage")])
        let hit = try XCTUnwrap(PassageSearch.find("matching", in: [(bookID, [indexed])], byMeaning: false).first)

        store.openPageResult(hit)
        try await fixture.settle(350)

        XCTAssertNil(store.activeFileName, "Choosing an indexed PDF result must reveal its page")
        XCTAssertEqual(store.activeMainTabID, bookID)
        XCTAssertEqual(store.reader.pageNumber, 2)
        XCTAssertTrue(store.fileTabs.contains(name))
    }

    @MainActor
    func testStartingDebuggingRevealsTheRetainedBookOverAWorkspaceFile() async throws {
        let fixture = try WorkbenchFixture(hosted: true), store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        store.open(fixture.book)
        try await fixture.waitForAnalysis()
        try await fixture.settle(300)
        let bookID = try XCTUnwrap(store.workspace?.id)
        let name = try store.createWorkspaceFile(name: "Working notes", kind: .text)
        try await fixture.settle(150)

        store.startDebugging()
        try await fixture.settle(600)

        XCTAssertNil(store.activeFileName, "Run and Debug needs to display the PDF that contains its reading line")
        XCTAssertEqual(store.activeMainTabID, bookID)
        XCTAssertNotNil(store.debug)
        XCTAssertNotNil(store.reader.rulerLine)
        XCTAssertTrue(store.fileTabs.contains(name))
        store.stopDebugging()
    }
}
