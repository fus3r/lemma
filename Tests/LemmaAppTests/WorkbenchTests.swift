import XCTest
import AppKit
import PDFKit
import SwiftUI
import LemmaCore
@testable import Lemma

/// The IDE workbench: book tabs, Go to and the command palette, breadcrumbs, the book's apparatus
/// (printed pages, index, references, exercises), the side editor and margin notes.
final class WorkbenchTests: XCTestCase {
    @MainActor
    func testTabsKeepEachBooksPlaceAndClosingFallsBackToTheNeighbour() async throws {
        let fixture = try WorkbenchFixture()
        defer { fixture.close() }
        let store = fixture.store
        store.open(fixture.book)
        let bookID = try XCTUnwrap(store.workspace?.id)
        store.workspace?.reading.pageIndex = 3
        store.flush()
        store.open(fixture.paper)
        XCTAssertEqual(store.tabs.map(\.title), ["Synthetic Book", "Paper"])
        XCTAssertEqual(store.workspace?.title, "Paper")
        store.activateTab(bookID)
        XCTAssertEqual(store.workspace?.id, bookID)
        XCTAssertEqual(store.workspace?.reading.pageIndex, 3, "Each book reopens where it was left.")
        XCTAssertNotNil(store.documents[bookID], "Switching back reuses the open document.")
        store.cycleTab(1)
        XCTAssertEqual(store.workspace?.title, "Paper")
        store.closeTab(store.workspace!.id)
        XCTAssertEqual(store.workspace?.id, bookID, "Closing a tab shows its neighbour.")
        XCTAssertEqual(store.tabs.count, 1)
        store.navigatorSection = .symbols
        store.closeBook()
        XCTAssertNil(store.workspace)
        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertEqual(store.navigatorSection, .library, "With no book open the sidebar shows the library.")
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: "openTabs"), [])
    }

    /// A tab dropped on another takes its place in either direction. Dragged to the right, it landed before the tab it was
    /// dropped on: on its right-hand neighbour it stayed where it was, and no tab could be made last. A book's tab dropped
    /// after the last tab goes last.
    @MainActor
    func testATabDroppedOnAnotherTakesItsPlaceInEitherDirection() throws {
        var tabs = ["a", "b", "c"].map { BookTab(id: $0, title: $0) }
        XCTAssertTrue(tabs.move("a", onto: "b")); XCTAssertEqual(tabs.map(\.id), ["b", "a", "c"])
        XCTAssertTrue(tabs.move("b", onto: "c")); XCTAssertEqual(tabs.map(\.id), ["a", "c", "b"])
        XCTAssertTrue(tabs.move("b", onto: "a")); XCTAssertEqual(tabs.map(\.id), ["b", "a", "c"])
        XCTAssertTrue(tabs.move("b", onto: nil)); XCTAssertEqual(tabs.map(\.id), ["a", "c", "b"])
        XCTAssertFalse(tabs.move("b", onto: nil), "Already last.")
        XCTAssertFalse(tabs.move("a", onto: "a"))
        XCTAssertFalse(tabs.move("a", onto: "missing"))
        XCTAssertFalse(tabs.move("missing", onto: "a"))
        XCTAssertEqual(tabs.map(\.id), ["a", "c", "b"])

        let fixture = try WorkbenchFixture()
        defer { fixture.close() }
        let store = fixture.store
        store.open(fixture.book); let bookID = try XCTUnwrap(store.workspace?.id)
        store.open(fixture.paper); let paperID = try XCTUnwrap(store.workspace?.id)
        XCTAssertTrue(store.dropBookTab(["lemma-tab:\(bookID)"], onto: paperID))
        XCTAssertEqual(store.tabs.map(\.id), [paperID, bookID], "Dropped on its right-hand neighbour.")
        XCTAssertTrue(store.dropBookTab(["lemma-tab:\(bookID)"], onto: paperID))
        XCTAssertEqual(store.tabs.map(\.id), [bookID, paperID], "And back on its left-hand one.")
        XCTAssertTrue(store.dropBookTab(["lemma-tab:\(bookID)"], onto: nil))
        XCTAssertEqual(store.tabs.map(\.id), [paperID, bookID], "Dropped after the last tab.")
        XCTAssertFalse(store.dropBookTab(["lemma-side:map"], onto: nil), "Only a book's tab moves along the book tabs.")
        XCTAssertEqual(store.tabs.map(\.id), [paperID, bookID])

        store.openToSide(page: 1, title: "Page two")
        store.openToSide(page: 2, title: "Page three")
        let sideIDs = store.sideEditors.map(\.id)
        XCTAssertEqual(sideIDs.count, 2)
        XCTAssertTrue(store.dropSideTab(["lemma-side:\(sideIDs[0])"], onto: sideIDs[1]))
        XCTAssertEqual(store.sideEditors.map(\.id), Array(sideIDs.reversed()), "Side tabs move to the right too.")
        XCTAssertFalse(store.dropSideTab(["lemma-tab:\(bookID)"], onto: sideIDs[0]))
    }

    /// The find widget's query belongs to its book. Switching tabs searched the other book for it and went to its first
    /// match there: "regression", found in the book, took the paper from page 1 to its references on page 2.
    @MainActor
    func testFindStaysWithItsBookWhenTabsSwitch() async throws {
        let fixture = try WorkbenchFixture(hosted: true)
        let find = FindController.shared
        defer { find.hide(); fixture.close() }
        let store = fixture.store
        store.open(fixture.paper); let paperID = try XCTUnwrap(store.workspace?.id)
        store.open(fixture.book); let bookID = try XCTUnwrap(store.workspace?.id)
        try await fixture.settle(400)
        find.show(store)
        find.query = "regression"; find.search()
        try await fixture.settle(400)
        XCTAssertFalse(store.reader.searchResults.isEmpty, "The book has the word.")

        store.activateTab(paperID)
        try await fixture.settle(400)
        XCTAssertEqual(store.reader.pageNumber, 1, "The paper stays on its page.")
        XCTAssertEqual(find.query, "", "The book's query does not follow the reader into the paper.")
        XCTAssertFalse(store.reader.hasSearched, "Nothing is searched in the paper.")

        store.activateTab(bookID)
        try await fixture.settle(400)
        XCTAssertEqual(find.query, "regression", "The book's query comes back with it.")
        XCTAssertFalse(store.reader.hasSearched, "Coming back searches nothing until the reader asks.")
        find.next()
        try await fixture.settle(400)
        XCTAssertFalse(store.reader.searchResults.isEmpty, "Asking for the next match searches the book again.")

        // A tab change also cancels a query whose typing debounce has not fired yet.
        find.query = "Least"; find.queryChanged()
        store.activateTab(paperID)
        try await fixture.settle(400)
        XCTAssertEqual(find.query, "")
        XCTAssertFalse(store.reader.hasSearched, "Pending typing in the book cannot search the paper.")
        XCTAssertTrue(store.reader.view?.highlightedSelections?.isEmpty ?? true, "The previous book's highlights are cleared.")

        find.hide()
        store.activateTab(bookID)
        try await fixture.settle(400)
        // A selected word intentionally seeds Find; clear the prior search's selected match to test query restoration.
        let selectedMatch = store.reader.view?.currentSelection
        store.reader.view?.clearSelection()
        find.show(store)
        XCTAssertEqual(find.query, "Least", "Opening Find after switching with it closed restores this book's query.")
        XCTAssertFalse(store.reader.hasSearched)
        store.reader.view?.setCurrentSelection(try XCTUnwrap(selectedMatch), animate: false)
        find.show(store)
        XCTAssertEqual(find.query, "regression", "An explicitly selected word still seeds Find.")
    }

    @MainActor
    func testWholeBookAnalysisDrivesGoToPrintedPagesAndBreadcrumbs() async throws {
        let fixture = try WorkbenchFixture(hosted: true)
        defer { fixture.close() }
        let store = fixture.store
        store.open(fixture.book)
        try await fixture.waitForAnalysis()
        try await fixture.settle()
        XCTAssertEqual(store.printedLabel(for: 1), "1", "The running heads number the book's pages one below the PDF's.")
        XCTAssertEqual(store.pageText(2), "p. 2")
        XCTAssertEqual(store.pageIndex(forTyped: "3"), 3)
        XCTAssertEqual(store.pageIndex(forTyped: "pdf 3"), 2)

        let provider = PaletteProvider(store: store)
        XCTAssertEqual(provider.items(mode: .goTo, query: "3").first?.title, "Go to page 3")
        XCTAssertEqual(provider.items(mode: .goTo, query: "(1.1)").first?.title, "Equation (1.1)")
        XCTAssertEqual(provider.items(mode: .goTo, query: "ex 1.1").first?.title, "Exercise 1.1")
        XCTAssertEqual(provider.items(mode: .goTo, query: "ridge").first?.title, "Ridge regression", "Index terms come first for a word.")
        XCTAssertEqual(provider.items(mode: .commands, query: "split").first?.title, "View: Split Editor")
        XCTAssertEqual(provider.items(mode: .goTo, query: ">panel").first?.title, "View: Toggle Panel")
        XCTAssertTrue(provider.items(mode: .symbols, query: "").contains { $0.title == "Equation (1.1)" })

        provider.items(mode: .goTo, query: "(1.1)").first?.perform()
        store.reader.updatePage()
        XCTAssertEqual(store.reader.pageNumber, 2, "Go to moves to the equation's page.")
        XCTAssertNotNil(store.reader.flash)
        store.reader.updateViewport()
        XCTAssertEqual(store.breadcrumb().map(\.title), ["1 Least Squares"])

        provider.items(mode: .goTo, query: "(1.1)").first?.openToSide?()
        XCTAssertEqual(store.split?.title, "Equation (1.1)")
        XCTAssertEqual(store.split?.pageIndex, 1)
        store.toggleSplit()
        XCTAssertNil(store.split)
    }

    @MainActor
    func testReferencesIndexEntriesAndCitationsComeFromTheAnalysis() async throws {
        let fixture = try WorkbenchFixture(hosted: true)
        defer { fixture.close() }
        let store = fixture.store
        store.open(fixture.book)
        try await fixture.waitForAnalysis()
        try await fixture.settle()
        let analysis = try XCTUnwrap(store.analysis)
        let equation = ReferenceKey(kind: .equation, number: "1.1")
        XCTAssertEqual(analysis.mentionCounts[equation], 1)
        store.showReferences(to: equation)
        XCTAssertEqual(store.referencesQuery, .object(equation))
        XCTAssertTrue(store.showPanel)
        XCTAssertEqual(store.panelTab, .references)

        // A citation in the text is linked to its entry in the reference list.
        let mentions = try XCTUnwrap(store.references).mentions(onPage: 2)
        let citation = try XCTUnwrap(mentions.first { $0.key.kind == .citation })
        XCTAssertEqual(citation.key.title, "Hoerl and Kennard (1970)")
        let resolved = await store.references?.resolve(citation, from: 2)
        let target = try XCTUnwrap(resolved)
        XCTAssertEqual(target.pageIndex, 4)

        // An index entry lists its pages and selects the term on the first one.
        let entry = try XCTUnwrap(analysis.analysis?.index.first { $0.term == "Ridge regression" })
        store.openIndexEntry(entry)
        store.reader.updatePage()
        XCTAssertEqual(store.referencesQuery, .indexEntry(entry))
        XCTAssertEqual(store.reader.pageNumber, 4, "Printed page 3 is PDF page 4.")
        XCTAssertEqual(store.reader.view?.currentSelection?.string?.lowercased(), "ridge regression")
    }

    @MainActor
    func testExercisesTrackProgressAndOpenAWorkingNote() async throws {
        let fixture = try WorkbenchFixture()
        defer { fixture.close() }
        let store = fixture.store
        store.open(fixture.book)
        try await fixture.waitForAnalysis()
        let exercise = try XCTUnwrap(store.analysis?.definitionsByKey[ReferenceKey(kind: .exercise, number: "1.1")])
        XCTAssertEqual(store.exerciseStatus("1.1"), .todo)
        store.setExercise("1.1", status: .attempted)
        XCTAssertEqual(store.exerciseStatus("1.1"), .attempted)
        store.workOnExercise(exercise)
        let note = try XCTUnwrap(store.currentNote)
        XCTAssertEqual(note.title, "Exercise 1.1")
        XCTAssertEqual(store.workspace?.exercise("1.1")?.noteID, note.id)
        store.workOnExercise(exercise)
        XCTAssertEqual(store.workspace?.notes.count, 1, "The same exercise reopens its note.")
        store.flush()
        let reopened = try XCTUnwrap(try store.repository.load(id: store.workspace!.id))
        XCTAssertEqual(reopened.exercises.map(\.number), ["1.1"])
        XCTAssertEqual(reopened.exercises.first?.status, .attempted)
        XCTAssertEqual(reopened.exercises.first?.noteID, note.id, "Progress and the working note survive reopening.")
        XCTAssertEqual(reopened.schemaVersion, 10)
    }

    @MainActor
    func testMarginNotesStartBesideALineAndEmptyOnesAreDiscarded() async throws {
        let fixture = try WorkbenchFixture(hosted: true)
        defer { fixture.close() }
        let store = fixture.store
        store.open(fixture.book)
        try await fixture.settle()
        let view = try XCTUnwrap(store.reader.view)
        store.reader.goToPage(2); store.reader.updatePage()
        view.layoutDocumentView()
        let page = try XCTUnwrap(store.document?.page(at: 1))
        // The left margin, level with the first line of text.
        let local = view.convert(CGPoint(x: 40, y: 684), from: page)
        let line = try XCTUnwrap(view.marginLine(at: local))
        XCTAssertEqual(line.pageIndex, 1)
        XCTAssertTrue(line.quote.contains("We fit a linear model"), line.quote)
        XCTAssertNil(view.marginLine(at: view.convert(CGPoint(x: 200, y: 684), from: page)), "Inside the text column is not the margin.")

        store.addMarginNote(pageIndex: line.pageIndex, region: line.region, quote: line.quote)
        let first = try XCTUnwrap(store.currentNote)
        XCTAssertEqual(first.kind, .comment)
        XCTAssertFalse(first.kind.isGlossary)
        store.finishMarginNote(first.id)
        XCTAssertNil(store.workspace?.notes.first { $0.id == first.id }, "An empty margin note is discarded.")

        store.addMarginNote(pageIndex: line.pageIndex, region: line.region, quote: line.quote)
        let second = try XCTUnwrap(store.currentNote)
        store.updateNote(id: second.id) { $0.body = "Why is this unique?\nBecause X has full column rank." }
        store.finishMarginNote(second.id)
        XCTAssertEqual(store.workspace?.notes.first { $0.id == second.id }?.title, "Why is this unique?")
        store.studySection = .glossary
        XCTAssertFalse(store.visibleNotes.contains { $0.id == second.id }, "Margin notes are not glossary entries.")
    }

    /// Help › Report How Lemma Read This Book… opens GitHub's book report form with the book and what Lemma found
    /// already filled in, under the field ids of `.github/ISSUE_TEMPLATE/book_report.yml`.
    func testBookReportOpensTheFormWithTheBookAndWhatLemmaFound() throws {
        let url = LemmaLinks.bookReport(book: "The Elements of Statistical Learning", found: "Lemma found 891 numbered equations in 764 pages.")
        let items = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).reduce(into: [String: String]()) { $0[$1.name] = $1.value }
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/\(LemmaLinks.repository)/issues/new")
        XCTAssertEqual(items["template"], "book_report.yml")
        XCTAssertEqual(items["title"], "Book report: The Elements of Statistical Learning")
        XCTAssertEqual(items["book"], "The Elements of Statistical Learning")
        XCTAssertEqual(items["right"], "Lemma found 891 numbered equations in 764 pages.")
        XCTAssertFalse((items["version"] ?? "").isEmpty)
    }
}

/// Two small PDFs: a book with running heads, an equation, an exercise, citations, references and an index;
/// and a two-page paper for a second tab.
@MainActor
final class WorkbenchFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let book: URL
    let paper: URL
    let store: StudyStore
    let window: NSWindow
    private let previous = UserDefaults.standard.object(forKey: "lastWorkspaceID")
    private let previousTabs = UserDefaults.standard.object(forKey: "openTabs")

    init(hosted: Bool = false) throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        book = root.appendingPathComponent("Synthetic_Book.pdf")
        paper = root.appendingPathComponent("Paper.pdf")
        try Self.writeBook(to: book)
        try Self.writePaper(to: paper)
        store = StudyStore(root: root.appendingPathComponent("support"))
        store.urlOpener = { _ in }
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1300, height: 860), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if hosted {
            window.contentView = NSHostingView(rootView: ReaderWindow(store: store))
            window.orderFront(nil)
        }
    }

    /// Lets SwiftUI host the reader and PDFKit lay out the document.
    func settle(_ milliseconds: Int = 200) async throws {
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(milliseconds))
        window.contentView?.layoutSubtreeIfNeeded()
        store.reader.view?.layoutDocumentView()
    }

    func waitForAnalysis(timeout: TimeInterval = 30) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while store.analysis?.analysis == nil, Date.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotNil(store.analysis?.analysis, "The book was read in the background.")
    }

    func close() {
        store.referencePeek = nil; store.palette = nil
        window.close()
        UserDefaults.standard.set(previous, forKey: "lastWorkspaceID")
        UserDefaults.standard.set(previousTabs, forKey: "openTabs")
        try? FileManager.default.removeItem(at: root)
    }

    private static func draw(pages: [() -> Void], to url: URL, outline: [(String, Int)]) throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 594, height: 792)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        for page in pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSColor.white.setFill(); box.fill()
            page()
            NSGraphicsContext.restoreGraphicsState(); context.endPDFPage()
        }
        context.closePDF()
        guard let document = PDFDocument(data: data as Data) else { throw CocoaError(.fileWriteUnknown) }
        let root = PDFOutline()
        for (offset, entry) in outline.enumerated() {
            let item = PDFOutline(); item.label = entry.0
            if let page = document.page(at: entry.1) { item.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: 792)) }
            root.insertChild(item, at: offset)
        }
        document.outlineRoot = root
        guard document.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func text(_ string: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 10, right: Bool = false) {
        let font = NSFont(name: "Times New Roman", size: size) ?? .systemFont(ofSize: size)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let width = (string as NSString).size(withAttributes: attributes).width
        (string as NSString).draw(at: CGPoint(x: right ? x - width : x, y: y), withAttributes: attributes)
    }

    private static func head(_ number: Int, _ title: String) {
        if number % 2 == 0 { text("\(number)    \(title)", 72, 740, size: 9) } else { text("\(title)    \(number)", 522, 740, size: 9, right: true) }
    }

    static func writeBook(to url: URL) throws {
        try draw(pages: [
            { text("A Synthetic Book on Linear Models", 72, 600, size: 20) },
            {
                head(1, "1. Least Squares")
                text("We fit a linear model by least squares. The residual sum of squares is minimised", 72, 680)
                text("over the coefficients, which leads to the normal equations", 72, 666)
                text("X^T (y - X b) = 0.", 250, 630)
                text("(1.1)", 522, 630, right: true)
                text("The solution is unique when the design has full column rank, as discussed below.", 72, 590)
            },
            {
                head(2, "1.1 Regularisation")
                text("Returning to the model (1.1), ridge regression adds a penalty to the residual sum", 72, 680)
                text("of squares; it was introduced by Hoerl and Kennard (1970) for nonorthogonal problems", 72, 666)
                text("and appears in additive models as well (Hastie and Tibshirani, 1990) with smoothing.", 72, 652)
            },
            {
                head(3, "Exercises")
                text("Ridge regression shrinks the coefficients towards zero as the penalty grows.", 72, 680)
                text("Exercises", 72, 640, size: 12)
                text("Ex. 1.1 Show that the ridge solution is unique for every positive penalty.", 72, 610)
            },
            {
                text("References", 72, 700, size: 18)
                text("Hastie, T. and Tibshirani, R. (1990). Generalized Additive Models, Chapman", 72, 640)
                text("and Hall, London.", 93, 628)
                text("Hoerl, A. E. and Kennard, R. (1970). Ridge regression: biased estimation for", 72, 609)
                text("nonorthogonal problems, Technometrics 12: 55–67.", 93, 597)
            },
            {
                head(5, "Index")
                text("Index", 72, 700, size: 18)
                text("Least squares, 1–2", 72, 640)
                text("normal equations, 1", 92, 628)
                text("Ridge regression, 3", 72, 616)
            }
        ], to: url, outline: [("1 Least Squares", 1), ("References", 4), ("Index", 5)])
    }

    static func writePaper(to url: URL) throws {
        try draw(pages: [
            { text("A Short Paper", 72, 700, size: 18); text("Sparse estimates set coefficients exactly to zero [1].", 72, 660) },
            { text("References", 72, 700, size: 14); text("[1] R. Tibshirani. Regression shrinkage and selection via the lasso. 1996.", 72, 680) }
        ], to: url, outline: [("1 Introduction", 0), ("References", 1)])
    }
}
