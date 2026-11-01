import XCTest
import AppKit
import SwiftUI
import LemmaCore
@testable import Lemma

/// The 2.4 Library: whole-row clicks, the keyboard, renames in Lemma and on disk, moves between libraries and
/// folders, drops, Undo, and the tree drawn in both interface styles.
final class LibraryTreeTests: XCTestCase {
    private var root: URL!
    private var saved: [String: Any] = [:]
    private let keys = ["workbench.panes", "lastWorkspaceID", "openTabs", "library.sort", "library.renameMode", "library.confirmDragMove"]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryTree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key); UserDefaults.standard.removeObject(forKey: key) }
    }

    override func tearDownWithError() throws {
        for key in keys { UserDefaults.standard.set(saved[key], forKey: key) }
        LibraryFileSystem.trash = { url in
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return resulting as URL?
        }
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor @discardableResult
    private func file(_ relative: String, book: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if book { try WorkbenchFixture.writeBook(to: url) } else { try Data("%PDF-1.4 metadata-only fixture".utf8).write(to: url) }
        return url
    }

    @MainActor private func store(_ collections: [LibraryCollection]) async throws -> StudyStore {
        _ = NSApplication.shared
        let store = StudyStore(root: root.appendingPathComponent("support"))
        try store.libraries.replace(collections)
        store.libraries.start()
        try await settle(store)
        let undo = UndoManager(); undo.groupsByEvent = false
        store.libraryTree.undoManager = undo
        return store
    }

    @MainActor private func settle(_ store: StudyStore) async throws {
        try await Task.sleep(for: .milliseconds(150))
        let deadline = Date().addingTimeInterval(10)
        while (store.libraries.isScanning || store.libraries.updatedAt == nil) && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(100))
    }

    /// Runs a library action as one Undo step.
    @MainActor private func step(_ store: StudyStore, _ action: () throws -> Void) rethrows {
        let undo = store.libraryTree.undoManager!
        undo.beginUndoGrouping(); defer { undo.endUndoGrouping() }
        try action()
    }

    @MainActor private func row(_ store: StudyStore, _ title: String) throws -> LibraryRow {
        try XCTUnwrap(store.libraryRows().first { $0.title == title }, "No row “\(title)” in \(store.libraryRows().map(\.title))")
    }

    // MARK: The tree

    @MainActor
    func testTreeNestsSectionsAndSubLibrariesAndListsFoldersBeforePDFs() throws {
        let books = root.appendingPathComponent("books"), math = root.appendingPathComponent("math"), csd = root.appendingPathComponent("school/csd")
        try file("books/Novel.pdf"); try file("math/Calculus.pdf"); try file("math/poker/Theory.pdf"); try file("math/b_Algebra.pdf")
        try file("school/csd/Chapter 1.pdf")
        let collections = [
            LibraryCollection(id: "books", title: "Books / Novels", kind: .books, sources: [LibrarySource(path: books.path)]),
            LibraryCollection(id: "quant", title: "Quant", kind: .studying, sources: [LibrarySource(path: math.path)]),
            LibraryCollection(id: "csd", title: "CSD", kind: .studying, parent: "School", sources: [LibrarySource(path: csd.path)]),
            LibraryCollection(id: "papers", title: "Papers", kind: .papers, sources: []),
            LibraryCollection(id: "poker", title: "Poker", kind: .studying, parent: "Quant", sources: [])
        ]
        let scan = LibraryScanner.scan(collections)
        let studied = StudyWorkspace(id: "esl", title: "The Elements of Statistical Learning", sourcePath: root.appendingPathComponent("ESL.pdf").path,
                                     sourceBookmark: nil, fingerprint: "esl")
        var input = LibraryTreeInput(collections: collections, entries: scan.entries, books: [studied])
        // A new reader's Books library starts open (3.0); this test reads the tree with it closed.
        XCTAssertEqual(LibraryTreeBuilder(input).rows().first { $0.title == "Books / Novels" }?.expanded, true)
        input.expanded = ["collection-books": false, "collection-quant": true, "collection-parent-School": true, "library-folder-quant:poker": true]
        let rows = LibraryTreeBuilder(input).rows()
        XCTAssertEqual(rows.map(\.title), ["Books / Novels", "Quant", "Poker", "poker", "Theory", "b Algebra", "Calculus",
                                           "School", "CSD", "Papers", "Other PDFs", "The Elements of Statistical Learning"])
        XCTAssertEqual(rows.map(\.depth), [0, 0, 1, 1, 2, 1, 1, 0, 1, 0, 0, 1])
        XCTAssertEqual(rows.first { $0.title == "Quant" }?.count, 3)
        XCTAssertEqual(rows.first { $0.title == "School" }?.count, 1, "Sections count their PDFs too")
        XCTAssertEqual(rows.first { $0.title == "poker" }?.icon, "folder-opened")
        XCTAssertEqual(rows.first { $0.title == "Theory" }?.parentID, rows.first { $0.title == "poker" }?.id)
        XCTAssertEqual(rows.first { $0.title == "Other PDFs" }?.count, 1)
        XCTAssertEqual(rows.first { $0.title == "Papers" }?.expanded, false)
        XCTAssertEqual(rows.first { $0.title == "Poker" }?.icon, "mortar-board")
        XCTAssertEqual(rows.first { $0.title == "Books / Novels" }?.icon, "library")

        input.query = "theory"
        XCTAssertEqual(LibraryTreeBuilder(input).rows().map(\.title), ["Quant", "poker", "Theory"], "A filter keeps matches and the way to them")
        input.query = ""
        input.titles = [LibraryPaths.key(math.appendingPathComponent("Calculus.pdf").path): "Spivak's Calculus"]
        let renamed = LibraryTreeBuilder(input).rows().first { $0.title == "Spivak's Calculus" }
        XCTAssertEqual(renamed?.detail, "Calculus.pdf", "A name given in Lemma shows the filename beside it")
        input.creatingIn = "Quant"
        let creating = LibraryTreeBuilder(input).rows()
        XCTAssertEqual(creating.firstIndex { $0.isNewLibraryRow }, creating.firstIndex { $0.title == "Poker" }.map { $0 + 1 },
                       "A new library's name field stands after the libraries already inside")
    }

    @MainActor
    func testAClickAnywhereOnARowOpensItAndTheKeyboardWalksTheTree() async throws {
        let math = root.appendingPathComponent("math")
        let calculus = try file("math/Calculus.pdf", book: true)
        try file("math/Algebra.pdf"); try file("math/poker/Theory.pdf")
        let store = try await store([
            LibraryCollection(id: "quant", title: "Quant", kind: .studying, sources: [LibrarySource(path: math.path)]),
            LibraryCollection(id: "papers", title: "Papers", kind: .papers, sources: [])
        ])
        let quant = try row(store, "Quant")
        XCTAssertFalse(quant.expanded)
        store.clickLibraryRow(quant)
        XCTAssertTrue(try row(store, "Quant").expanded, "A click on the name opens the library, not only on the chevron")
        XCTAssertEqual(store.libraryTree.selection, [quant.id])
        store.clickLibraryRow(try row(store, "poker"))
        XCTAssertTrue(try row(store, "poker").expanded)

        store.clickLibraryRow(try row(store, "Calculus"))
        XCTAssertEqual(store.workspace.map { LibraryPaths.key($0.sourcePath) }, LibraryPaths.key(calculus.path), "A click on a PDF opens it")
        XCTAssertTrue(try row(store, "Calculus").isActive)

        store.clickLibraryRow(try row(store, "Algebra"), modifiers: .command)
        XCTAssertEqual(store.libraryTree.selection.count, 2, "⌘-click adds to the selection without opening")
        store.clickLibraryRow(try row(store, "Quant"), modifiers: .shift)
        XCTAssertEqual(store.libraryTree.selection.count, 4, "⇧-click selects the range from the last clicked row")

        store.libraryTree.selection = [quant.id]; store.libraryTree.cursor = quant.id
        store.handleLibraryKey(.down)
        XCTAssertEqual(store.libraryTree.cursor, try row(store, "poker").id)
        store.handleLibraryKey(.left)
        XCTAssertFalse(try row(store, "poker").expanded, "← closes an open folder")
        store.handleLibraryKey(.left)
        XCTAssertEqual(store.libraryTree.cursor, quant.id, "← again goes to the parent")
        store.handleLibraryKey(.character("p"))
        XCTAssertEqual(store.libraryTree.cursor, try row(store, "poker").id, "Typing jumps to a name")
        store.handleLibraryKey(.rename)
        XCTAssertEqual(store.libraryTree.editor?.rowID, try row(store, "poker").id, "↩ renames, as in Finder and VS Code on the Mac")
        XCTAssertEqual(store.libraryTree.editor?.text, "poker")
        XCTAssertFalse(store.handleLibraryKey(.down), "Keys go to the name field while it is open")
        store.handleLibraryKey(.escape)
        XCTAssertNil(store.libraryTree.editor)
        store.collapseLibrary()
        XCTAssertEqual(store.libraryRows().filter { $0.depth > 0 && !$0.isPDF }.count, 0)
    }

    // MARK: Renaming

    @MainActor
    func testRenamingInLemmaOnDiskOrBothKeepsTheBookAndUndoes() async throws {
        let math = root.appendingPathComponent("math")
        let poker = try file("math/The_mathematics_of_poker.pdf", book: true)
        let algebra = try file("math/algebra.pdf")
        try file("math/Taken.pdf")
        let store = try await store([LibraryCollection(id: "quant", title: "Quant", kind: .studying, sources: [LibrarySource(path: math.path)])])
        store.paneExpanded["collection-quant"] = true

        // A PDF never opened: its name in Lemma is kept by path, and becomes its title when it is opened.
        try step(store) {
            store.beginLibraryRename(try row(store, "algebra"), mode: .lemma)
            store.updateLibraryEditText("Linear Algebra Done Right")
            XCTAssertTrue(store.commitLibraryEdit())
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: algebra.path), "In Lemma only: the file keeps its name")
        XCTAssertEqual(try row(store, "Linear Algebra Done Right").detail, "algebra.pdf")
        XCTAssertEqual(store.libraries.titles[LibraryPaths.key(algebra.path)], "Linear Algebra Done Right")
        store.libraryTree.undoManager?.undo()
        XCTAssertNil(store.libraries.titles[LibraryPaths.key(algebra.path)], "Undo gives the filename back")
        store.libraryTree.undoManager?.redo()
        XCTAssertEqual(store.libraries.titles[LibraryPaths.key(algebra.path)], "Linear Algebra Done Right", "Redo")

        // A studied book: renaming the file keeps its notes; a title that was its filename follows.
        store.open(poker)
        store.reader.selection = (0, CGRect(x: 20, y: 20, width: 60, height: 60), "source")
        store.addNote()
        store.flush()
        let id = try XCTUnwrap(store.workspace?.id)
        XCTAssertEqual(store.tabs.first?.title, "The mathematics of poker")
        let renamed = math.appendingPathComponent("Mathematics of Poker (Chen).pdf")
        try step(store) {
            store.beginLibraryRename(try row(store, "The mathematics of poker"), mode: .file)
            XCTAssertEqual(store.libraryTree.editor?.text, "The_mathematics_of_poker")
            store.updateLibraryEditText("Taken")
            XCTAssertNotNil(store.libraryTree.editor?.problem, "An existing file is refused before anything moves")
            XCTAssertFalse(store.commitLibraryEdit())
            store.updateLibraryEditText("Mathematics of Poker (Chen)")
            XCTAssertNil(store.libraryTree.editor?.problem)
            XCTAssertTrue(store.commitLibraryEdit())
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: poker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertEqual(store.workspace?.id, id)
        XCTAssertEqual(store.workspace.map { LibraryPaths.key($0.sourcePath) }, LibraryPaths.key(renamed.path))
        XCTAssertEqual(store.workspace?.notes.count, 1)
        XCTAssertEqual(store.workspace?.title, "Mathematics of Poker (Chen)", "The title was the filename, so it follows")
        XCTAssertEqual(store.tabs.first?.title, "Mathematics of Poker (Chen)")
        XCTAssertEqual(try store.repository.load(id: id).map { LibraryPaths.key($0.sourcePath) }, LibraryPaths.key(renamed.path))
        XCTAssertTrue(store.libraryTree.selection.contains(try row(store, "Mathematics of Poker (Chen)").id), "The renamed row stays selected")

        store.libraryTree.undoManager?.undo()
        XCTAssertTrue(FileManager.default.fileExists(atPath: poker.path), "Undo renames the file back")
        XCTAssertEqual(store.workspace?.title, "The mathematics of poker")
        XCTAssertEqual(store.workspace.map { LibraryPaths.key($0.sourcePath) }, LibraryPaths.key(poker.path))
        store.libraryTree.undoManager?.redo()
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))

        // Both at once; then a name in Lemma only, which the file keeps.
        try step(store) {
            store.beginLibraryRename(try row(store, "Mathematics of Poker (Chen)"), mode: .both)
            store.updateLibraryEditText("Poker: Theory")
            XCTAssertTrue(store.commitLibraryEdit())
        }
        let both = math.appendingPathComponent("Poker- Theory.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: both.path), "“:” cannot be in a filename")
        XCTAssertEqual(store.workspace?.title, "Poker: Theory")
        try step(store) {
            store.beginLibraryRename(try row(store, "Poker: Theory"), mode: .lemma)
            store.updateLibraryEditText("Chen & Ankenman")
            XCTAssertTrue(store.commitLibraryEdit())
        }
        XCTAssertEqual(store.workspace?.title, "Chen & Ankenman")
        XCTAssertTrue(FileManager.default.fileExists(atPath: both.path))
        XCTAssertEqual(try row(store, "Chen & Ankenman").detail, "Poker- Theory.pdf")
        try step(store) {
            store.beginLibraryRename(try row(store, "Chen & Ankenman"), mode: .file)
            store.updateLibraryEditText("chen")
            XCTAssertTrue(store.commitLibraryEdit())
        }
        XCTAssertEqual(store.workspace?.title, "Chen & Ankenman", "A name given in Lemma stays when only the file changes")

        // Changing only the case of a name works on case-insensitive volumes.
        try step(store) {
            store.beginLibraryRename(try row(store, "Chen & Ankenman"), mode: .file)
            store.updateLibraryEditText("Chen")
            XCTAssertNil(store.libraryTree.editor?.problem)
            XCTAssertTrue(store.commitLibraryEdit())
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: math.path).filter { $0.hasPrefix("Chen") || $0.hasPrefix("chen") }, ["Chen.pdf"])
    }

    @MainActor
    func testRenamingAFolderAndMovingFilesIntoItKeepBooksLinked() async throws {
        let math = root.appendingPathComponent("math")
        let theory = try file("math/poker/Theory.pdf", book: true)
        let odds = try file("math/Odds.pdf")
        let store = try await store([LibraryCollection(id: "quant", title: "Quant", kind: .studying, sources: [LibrarySource(path: math.path)])])
        store.paneExpanded["collection-quant"] = true
        store.paneExpanded["library-folder-quant:poker"] = true
        store.open(theory)
        store.flush()
        let id = try XCTUnwrap(store.workspace?.id)
        try step(store) {
            store.beginLibraryRename(try row(store, "poker"))
            XCTAssertEqual(store.libraryTree.editor?.caption, "Renames the folder on disk")
            store.updateLibraryEditText("Poker theory")
            XCTAssertTrue(store.commitLibraryEdit())
        }
        let folder = math.appendingPathComponent("Poker theory")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Theory.pdf").path))
        XCTAssertEqual(store.workspace.map { LibraryPaths.key($0.sourcePath) }, LibraryPaths.key(folder.appendingPathComponent("Theory.pdf").path),
                       "The open book inside the folder follows it")
        try await settle(store)
        XCTAssertTrue(try row(store, "Poker theory").expanded, "The folder stays open under its new name")

        let planner = LibraryDropPlanner(collections: store.libraries.collections, rows: store.libraryRows())
        let plan = planner.plan(dragged: [try row(store, "Odds")], urls: [], target: try row(store, "Poker theory"), placement: .into, option: false)
        guard case let .moveIntoFolder(paths, destination) = plan.action else { return XCTFail("\(plan.action)") }
        XCTAssertEqual(paths.map(LibraryPaths.key), [LibraryPaths.key(odds.path)])
        XCTAssertEqual(LibraryPaths.key(destination), LibraryPaths.key(folder.path))
        XCTAssertTrue(plan.message.contains("on disk"))
        try step(store) { store.performLibraryDrop(plan.action, confirmDiskMoves: false) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Odds.pdf").path))
        store.libraryTree.undoManager?.undo()
        XCTAssertTrue(FileManager.default.fileExists(atPath: odds.path), "Undo moves the file back")
        store.libraryTree.undoManager?.undo()
        XCTAssertTrue(FileManager.default.fileExists(atPath: theory.path), "and the folder takes its name back")
        XCTAssertEqual(store.workspace?.id, id)
        XCTAssertEqual(store.workspace.map { LibraryPaths.key($0.sourcePath) }, LibraryPaths.key(theory.path))
    }

    // MARK: Organising

    @MainActor
    func testDraggingBetweenLibrariesSectionsAndFromFinder() async throws {
        let math = root.appendingPathComponent("math")
        let isl = try file("math/ISL.pdf")
        try file("math/Calculus.pdf")
        let finder = try file("Downloads/Attention.pdf")
        let downloads = root.appendingPathComponent("Downloads")
        let store = try await store([
            LibraryCollection(id: "quant", title: "Quant", kind: .studying, sources: [LibrarySource(path: math.path)]),
            LibraryCollection(id: "stats", title: "Stats", kind: .studying, sources: []),
            LibraryCollection(id: "csd", title: "CSD", kind: .studying, parent: "School", sources: []),
            LibraryCollection(id: "papers", title: "Papers", kind: .papers, sources: [])
        ])
        store.paneExpanded["collection-quant"] = true
        func planner() -> LibraryDropPlanner { LibraryDropPlanner(collections: store.libraries.collections, rows: store.libraryRows()) }

        // A PDF onto another library: listed there, the file stays; ⌥ keeps it in both.
        var plan = planner().plan(dragged: [try row(store, "ISL")], urls: [], target: try row(store, "Stats"), placement: .into, option: false)
        XCTAssertTrue(plan.message.hasPrefix("Move “ISL” to Stats"))
        try step(store) { store.performLibraryDrop(plan.action) }
        try await settle(store)
        XCTAssertEqual(store.libraries.entries.filter { $0.collectionID == "stats" }.map { LibraryPaths.key($0.path) }, [LibraryPaths.key(isl.path)])
        XCTAssertFalse(store.libraries.entries.contains { $0.collectionID == "quant" && $0.path.hasSuffix("ISL.pdf") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: isl.path))
        store.libraryTree.undoManager?.undo()
        try await settle(store)
        XCTAssertTrue(store.libraries.entries.contains { $0.collectionID == "quant" && $0.path.hasSuffix("ISL.pdf") }, "Undo lists it back")
        XCTAssertFalse(store.libraries.entries.contains { $0.collectionID == "stats" })
        plan = planner().plan(dragged: [try row(store, "ISL")], urls: [], target: try row(store, "Stats"), placement: .into, option: true)
        XCTAssertTrue(plan.message.hasPrefix("Also list"))

        // Libraries: into a library (nest), before another (order), into a section.
        plan = planner().plan(dragged: [try row(store, "Papers")], urls: [], target: try row(store, "Quant"), placement: .into, option: false)
        XCTAssertEqual(plan.action, .moveLibraries(ids: ["papers"], parent: "Quant", before: nil))
        try step(store) { store.performLibraryDrop(plan.action) }
        XCTAssertEqual(try row(store, "Papers").depth, 1)
        XCTAssertEqual(try row(store, "Papers").parentID, "library:quant")
        plan = planner().plan(dragged: [try row(store, "Stats")], urls: [], target: try row(store, "Quant"), placement: .before, option: false)
        try step(store) { store.performLibraryDrop(plan.action) }
        XCTAssertEqual(store.libraries.collections.map(\.id).prefix(2), ["stats", "quant"])
        plan = planner().plan(dragged: [try row(store, "Stats")], urls: [], target: try row(store, "School"), placement: .into, option: false)
        try step(store) { store.performLibraryDrop(plan.action) }
        XCTAssertEqual(store.libraries.collections.first { $0.id == "stats" }?.parent, "School")
        plan = planner().plan(dragged: [try row(store, "Quant")], urls: [], target: try row(store, "School"), placement: .into, option: false)
        XCTAssertEqual(plan.action, .none, "A library with libraries inside stays at the top level")

        // From Finder: PDFs onto a library are added where they are; a folder onto empty space becomes a library.
        plan = planner().plan(dragged: [], urls: [finder], target: try row(store, "CSD"), placement: .into, option: false)
        try step(store) { store.performLibraryDrop(plan.action) }
        try await settle(store)
        XCTAssertEqual(store.libraries.entries.filter { $0.collectionID == "csd" }.map { LibraryPaths.key($0.path) }, [LibraryPaths.key(finder.path)])
        plan = planner().plan(dragged: [], urls: [downloads], target: nil, placement: .into, option: false)
        XCTAssertEqual(plan.message, "New library from “Downloads”")
        try step(store) { store.performLibraryDrop(plan.action) }
        XCTAssertEqual(store.libraries.collections.last?.title, "Downloads")
        XCTAssertEqual(store.libraries.collections.last?.sources.first?.kind, .folder)
        plan = planner().plan(dragged: [], urls: [finder], target: nil, placement: .into, option: false)
        XCTAssertEqual(plan.action, .none, "PDFs need a library or a folder")
    }

    @MainActor
    func testSectionsMoveAsAWholeAndOtherPDFsAreFiledAtOnce() async throws {
        let loose = try file("Downloads/Loose notes.pdf", book: true)
        let store = try await store([
            LibraryCollection(id: "a", title: "Algebra", kind: .studying, sources: []),
            LibraryCollection(id: "s1", title: "CSD", kind: .studying, parent: "School", sources: []),
            LibraryCollection(id: "b", title: "Books", kind: .books, sources: []),
            LibraryCollection(id: "s2", title: "Economics", kind: .studying, parent: "School", sources: [])
        ])
        XCTAssertEqual(store.libraryRows().map(\.title), ["Algebra", "School", "Books"], "A section stands where its first library is")
        func planner() -> LibraryDropPlanner { LibraryDropPlanner(collections: store.libraries.collections, rows: store.libraryRows()) }
        var plan = planner().plan(dragged: [try row(store, "School")], urls: [], target: try row(store, "Algebra"), placement: .before, option: false)
        XCTAssertEqual(plan.action, .moveSections(names: ["School"], before: "a"))
        try step(store) { store.performLibraryDrop(plan.action) }
        XCTAssertEqual(store.libraries.collections.map(\.id), ["s1", "s2", "a", "b"], "Its libraries move together, in order")
        plan = planner().plan(dragged: [try row(store, "School")], urls: [], target: try row(store, "Books"), placement: .after, option: false)
        try step(store) { store.performLibraryDrop(plan.action) }
        XCTAssertEqual(store.libraryRows().map(\.title), ["Algebra", "Books", "School"])
        store.libraryTree.undoManager?.undo()
        XCTAssertEqual(store.libraryRows().map(\.title), ["School", "Algebra", "Books"], "Undo")

        // Other PDFs drags every book in it: dropped on a library, they are all filed there.
        store.open(loose)
        store.flush()
        let unfiled = try row(store, "Other PDFs")
        _ = store.libraryDragProvider(for: unfiled)
        XCTAssertEqual(store.libraryTree.dragged.map(\.title), ["Loose notes"])
        plan = planner().plan(dragged: store.libraryTree.dragged, urls: [], target: try row(store, "Books"), placement: .into, option: false)
        try step(store) { store.performLibraryDrop(plan.action) }
        try await settle(store)
        XCTAssertNil(store.libraryRows().first { $0.title == "Other PDFs" }, "Nothing is left outside the libraries")
        store.paneExpanded["collection-b"] = true
        XCTAssertEqual(try row(store, "Loose notes").parentID, "library:b")
    }

    @MainActor
    func testRemoveLibraryConfirmationAppearsAboveSourcesSheet() async throws {
        let pdf = try file("Reading.pdf", book: true)
        let originalPDF = try Data(contentsOf: pdf)
        let collection = LibraryCollection(id: "reading", title: "Reading", kind: .studying,
                                           sources: [LibrarySource(path: pdf.path, kind: .file)])
        let store = try await store([collection])
        let expected = store.libraries.collections
        let frame = NSRect(x: 100, y: 100, width: 900, height: 750)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let sources = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; sources.isReleasedWhenClosed = false
        sources.contentView = NSHostingView(rootView: LibrarySourcesSheet(store: store))
        store.mainWindow = window
        defer { store.mainWindow = nil; sources.close(); window.close() }
        window.orderFront(nil)
        window.beginSheet(sources, completionHandler: nil)

        store.confirmRemoveLibrary(collection.id)
        try await Task.sleep(for: .milliseconds(150))
        guard let confirmation = sources.attachedSheet else {
            XCTFail("Remove Library must present its confirmation above Library Sources, rather than queue it behind that sheet")
            window.endSheet(sources)
            try await Task.sleep(for: .milliseconds(100))
            if let queued = window.attachedSheet { window.endSheet(queued, returnCode: .alertSecondButtonReturn) }
            try await Task.sleep(for: .milliseconds(100))
            return
        }
        XCTAssertTrue(window.attachedSheet === sources)
        sources.endSheet(confirmation, returnCode: .alertSecondButtonReturn)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.libraries.collections, expected, "Cancel keeps the library")

        store.confirmRemoveLibrary(collection.id)
        try await Task.sleep(for: .milliseconds(100))
        let removal = try XCTUnwrap(sources.attachedSheet)
        sources.endSheet(removal, returnCode: .alertFirstButtonReturn)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(store.libraries.collections.isEmpty)
        XCTAssertEqual(try LibraryCollectionRepository(root: store.repository.root).load(), [], "The removal is saved")
        XCTAssertEqual(try Data(contentsOf: pdf), originalPDF, "Removing a library leaves its PDF in place")
        XCTAssertTrue(window.attachedSheet === sources, "Library Sources stays open")
        window.endSheet(sources)
    }

    @MainActor
    func testNewLibrariesRemovalAndTheTrashAreUndoable() async throws {
        let math = root.appendingPathComponent("math")
        let calculus = try file("math/Calculus.pdf")
        let trash = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        LibraryFileSystem.trash = { url in
            let destination = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        let store = try await store([LibraryCollection(id: "quant", title: "Quant", kind: .studying, sources: [LibrarySource(path: math.path)])])

        try step(store) {
            store.beginNewLibrary(in: "Quant")
            XCTAssertEqual(store.libraryRows().first { $0.isNewLibraryRow }?.depth, 1, "The name field opens inside Quant")
            store.updateLibraryEditText("Poker")
            XCTAssertTrue(store.commitLibraryEdit())
        }
        let poker = try XCTUnwrap(store.libraries.collections.first { $0.title == "Poker" })
        XCTAssertEqual(poker.parent, "Quant")
        XCTAssertEqual(try row(store, "Poker").depth, 1)
        XCTAssertEqual(store.libraryTree.selection, ["library:" + poker.id])

        try step(store) { store.removeLibraryCollection(poker.id) }
        XCTAssertFalse(store.libraries.collections.contains { $0.id == poker.id })
        store.libraryTree.undoManager?.undo()
        XCTAssertTrue(store.libraries.collections.contains { $0.id == poker.id }, "Undo brings the library back")

        store.paneExpanded["collection-quant"] = true
        try step(store) { XCTAssertEqual(store.trashLibraryItems([calculus.path]), 1) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: calculus.path))
        store.libraryTree.undoManager?.undo()
        XCTAssertTrue(FileManager.default.fileExists(atPath: calculus.path), "Undo puts the file back from the Trash")
        store.libraryTree.undoManager?.redo()
        XCTAssertFalse(FileManager.default.fileExists(atPath: calculus.path), "Redo moves it to the Trash again")
        store.libraryTree.undoManager?.undo()
        XCTAssertTrue(FileManager.default.fileExists(atPath: calculus.path))

        let menu = store.libraryMenu(for: try row(store, "Quant")).map(\.title)
        XCTAssertTrue(menu.contains("Rename…") && menu.contains("Remove Library…") && menu.contains("Move To"))
        try await settle(store)
        let pdfMenu = store.libraryMenu(for: try row(store, "Calculus")).map(\.title)
        XCTAssertEqual(Array(pdfMenu.prefix(3)), ["Open", "Open to the Side", "Open in Preview"])
        XCTAssertTrue(pdfMenu.contains("Rename File on Disk…") && pdfMenu.contains("Move to Library") && pdfMenu.contains("Move to Trash…"))
    }

    @MainActor
    func testTheTreeDrawsInBothStylesWithANameBeingTyped() async throws {
        let math = root.appendingPathComponent("math")
        try file("math/Calculus.pdf"); try file("math/poker/Theory.pdf")
        let store = try await store([
            LibraryCollection(id: "quant", title: "Quant", kind: .studying, sources: [LibrarySource(path: math.path)]),
            LibraryCollection(id: "csd", title: "CSD", kind: .studying, parent: "School", sources: [])
        ])
        store.paneExpanded["collection-quant"] = true
        let manager = ThemeManager.shared, style = manager.style
        defer { manager.style = style }
        let host = NSHostingView(rootView: LibraryCollectionsView(store: store).environment(\.theme, manager.colors))
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 500)
        for interface in [WorkbenchStyle.vscode, .classic] {
            manager.style = interface
            host.rootView = LibraryCollectionsView(store: store).environment(\.theme, manager.colors)
            host.layoutSubtreeIfNeeded()
            store.beginLibraryRename(try row(store, "Calculus"), mode: .both)
            host.layoutSubtreeIfNeeded()
            store.libraryTree.drop = LibraryDropFeedback(rowID: "library:quant", message: "Move “Theory” to Quant")
            host.layoutSubtreeIfNeeded()
            store.cancelLibraryEdit(); store.libraryTree.drop = nil
            host.layoutSubtreeIfNeeded()
        }
    }
}
