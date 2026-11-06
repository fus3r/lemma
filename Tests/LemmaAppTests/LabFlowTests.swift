import XCTest
import AppKit
import PDFKit
import LemmaCore
@testable import Lemma

/// 0.8: the Lab beside the page, reading time, the page inspector and hover previews.
final class LabFlowTests: XCTestCase {
    @MainActor
    func testOpeningLabFromPageInspectorRevealsItOverAWorkspaceFile() async throws {
        let previousStyle = ThemeManager.shared.style
        ThemeManager.shared.style = .classic
        defer { ThemeManager.shared.style = previousStyle }
        let fixture = try WorkbenchFixture(hosted: true), store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        store.open(fixture.book)
        try await fixture.settle(150)
        let name = try store.createWorkspaceFile(name: "Working notes", kind: .text)
        let file = try XCTUnwrap(store.activeFile)
        store.updateWorkspaceFile(file, text: "Keep these notes")
        store.showPanel = false
        try await fixture.settle(100)

        // The retained Page inspector's Lab button uses this exact action for its source page.
        let notebookID = try XCTUnwrap(store.newLab(source: store.pageSource(2)))
        try await fixture.settle(200)
        func hasNotebookEditor(_ view: NSView) -> Bool {
            view is LabTextView || view.subviews.contains(where: hasNotebookEditor)
        }
        XCTAssertNil(store.activeFileName, "Explicitly opening a notebook reveals the PDF and side editor group")
        XCTAssertEqual(store.openLabID, notebookID)
        XCTAssertEqual(store.openLab?.source?.pageIndex, 2)
        XCTAssertTrue(hasNotebookEditor(try XCTUnwrap(fixture.window.contentView)), "The notebook must actually be hosted, not merely selected behind the file")
        XCTAssertTrue(store.fileTabs.contains(name))
        XCTAssertEqual(file.text, "Keep these notes")

        store.openWorkspaceFile(name)
        try await fixture.settle(100)
        XCTAssertEqual(store.activeFileName, name)
        store.activateSideEditor("lab:\(notebookID)")
        try await fixture.settle(200)
        XCTAssertNil(store.activeFileName, "Selecting an existing side tab also reveals its editor")
        XCTAssertTrue(hasNotebookEditor(try XCTUnwrap(fixture.window.contentView)))
        XCTAssertNil(store.lab.sessions[notebookID], "Revealing a notebook never runs its cells")
    }

    @MainActor
    func testAddingPassagesAndExplanationCodeRevealsTheExistingNotebook() async throws {
        let previousStyle = ThemeManager.shared.style
        ThemeManager.shared.style = .classic
        defer { ThemeManager.shared.style = previousStyle }
        let fixture = try WorkbenchFixture(hosted: true), store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        store.open(fixture.book)
        try await fixture.settle(100)
        let notebookID = try XCTUnwrap(store.newLab(title: "Existing notebook"))
        let initialCells = try XCTUnwrap(store.lab(notebookID)).cells.count
        let fileName = try store.createWorkspaceFile(name: "Working notes", kind: .text)
        let file = try XCTUnwrap(store.activeFile)
        store.updateWorkspaceFile(file, text: "Keep these notes")
        store.reader.selection = (1, CGRect(x: 70, y: 660, width: 400, height: 30), "A passage to investigate.")
        store.reader.hasSelection = true
        store.addNote()
        let note = try XCTUnwrap(store.currentNote)
        store.updateNote(id: note.id) { $0.explanation = SavedExplanation(body: "```python\nprint(42)\n```") }

        store.sendSelectionToLab()
        try await fixture.settle(150)
        XCTAssertNil(store.activeFileName, "Sending a passage reveals the existing notebook receiving it")
        XCTAssertEqual(store.openLabID, notebookID)
        XCTAssertGreaterThan(try XCTUnwrap(store.lab(notebookID)).cells.count, initialCells)
        func hasNotebookEditor(_ view: NSView) -> Bool {
            view is LabTextView || view.subviews.contains(where: hasNotebookEditor)
        }
        XCTAssertTrue(hasNotebookEditor(try XCTUnwrap(fixture.window.contentView)))

        store.openWorkspaceFile(fileName)
        XCTAssertEqual(store.activeFileName, fileName)
        store.openExplanationCode(noteID: note.id)
        try await fixture.settle(150)
        XCTAssertNil(store.activeFileName, "Opening explanation code reveals the notebook receiving it")
        XCTAssertEqual(store.openLabID, notebookID)
        XCTAssertEqual(store.lab(notebookID)?.cells.last?.source, "print(42)")
        XCTAssertTrue(hasNotebookEditor(try XCTUnwrap(fixture.window.contentView)))
        XCTAssertEqual(store.workspace?.labs.count, 1)
        XCTAssertTrue(store.fileTabs.contains(fileName))
        XCTAssertEqual(file.text, "Keep these notes")
        XCTAssertNil(store.lab.sessions[notebookID], "Adding content never runs code")
    }

    @MainActor
    func testSelectionStartsANotebookBesideThePageAndLaterPassagesAreAppended() async throws {
        let fixture = try WorkbenchFixture()
        defer { fixture.close() }
        let store = fixture.store
        store.open(fixture.book)
        try await fixture.waitForAnalysis()
        // The normal equations, labelled (1.1), on PDF page 2.
        store.reader.selection = (1, CGRect(x: 240, y: 624, width: 290, height: 22), "X^T (y - X b) = 0. (1.1)")
        store.reader.hasSelection = true
        store.sendSelectionToLab()
        let notebook = try XCTUnwrap(store.workspace?.labs.first)
        XCTAssertEqual(notebook.title, "Equation (1.1)", "A selection over a numbered equation names the notebook after it.")
        XCTAssertEqual(store.openLabID, notebook.id)
        XCTAssertEqual(notebook.source?.pageIndex, 1)
        XCTAssertEqual(notebook.cells.map(\.kind), [.code], "The source card shows the passage; the notebook starts with code.")
        XCTAssertTrue(notebook.cells[0].source.contains("import numpy as np"))
        XCTAssertEqual(store.lab.focusRequest?.cellID, notebook.cells[0].id, "The code cell takes focus.")

        store.reader.selection = (2, CGRect(x: 70, y: 660, width: 400, height: 30), "Returning to the model (1.1), ridge regression adds a penalty")
        store.sendSelectionToLab()
        let appended = try XCTUnwrap(store.lab(notebook.id))
        XCTAssertEqual(store.workspace?.labs.count, 1, "A second passage goes to the open notebook.")
        XCTAssertEqual(appended.cells.map(\.kind), [.code, .text, .code])
        XCTAssertTrue(appended.cells[1].source.contains("> Returning to the model (1.1)"))

        store.openToSide(page: 2)
        XCTAssertNil(store.openLabID, "The page comes to the front of the side editors; the notebook keeps its tab.")
        store.openLabNotebook(notebook.id)
        XCTAssertNil(store.split)
        store.closeLabEditor()
        XCTAssertNil(store.openLabID)

        store.flush()
        let reopened = try XCTUnwrap(try store.repository.load(id: store.workspace!.id))
        XCTAssertEqual(reopened.labs.first?.cells.count, 3, "Notebooks are saved with the book.")
        store.deleteLab(notebook.id)
        XCTAssertTrue(store.workspace?.labs.isEmpty == true)
    }

    @MainActor
    func testExplanationCodeOpensInTheLabWithoutRunning() async throws {
        let fixture = try WorkbenchFixture()
        defer { fixture.close() }
        let store = fixture.store
        store.open(fixture.book)
        store.reader.selection = (1, CGRect(x: 70, y: 660, width: 400, height: 30), "We fit a linear model by least squares.")
        store.reader.hasSelection = true
        store.addNote()
        let note = try XCTUnwrap(store.currentNote)
        store.updateNote(id: note.id) { $0.question = "Why least squares?"; $0.explanation = SavedExplanation(body: "Try this:\n\n```python\nimport numpy as np\nprint(np.ones(2))\n```\n") }
        store.openExplanationCode(noteID: note.id)
        let notebook = try XCTUnwrap(store.openLab)
        XCTAssertEqual(notebook.title, "Why least squares?")
        XCTAssertEqual(notebook.cells.map(\.kind), [.text, .code])
        XCTAssertEqual(notebook.cells[1].source, "import numpy as np\nprint(np.ones(2))")
        XCTAssertTrue(notebook.cells[1].outputs.isEmpty)
        XCTAssertNil(store.lab.sessions[notebook.id], "Opening code never runs it.")
    }

    @MainActor
    func testAFailingCellCanBeAskedAboutAndTheAnswerReturnsToTheNotebook() async throws {
        let fixture = try WorkbenchFixture()
        defer { fixture.close() }
        let store = fixture.store
        var opened: [URL] = []
        store.urlOpener = { opened.append($0) }
        UserDefaults.standard.removeObject(forKey: LemmaPreferences.quickAskMode)
        store.open(fixture.book)
        try await fixture.waitForAnalysis()
        store.reader.selection = (1, CGRect(x: 240, y: 624, width: 290, height: 22), "X^T (y - X b) = 0. (1.1)")
        store.reader.hasSelection = true
        store.sendSelectionToLab()
        let id = try XCTUnwrap(store.openLabID)
        let cell = try XCTUnwrap(store.lab(id)?.cells.first)
        store.updateLab(id) { notebook in
            notebook.cells[0].source = "b = np.linalg.solve(X.T @ X, X.T @ y)"
            notebook.cells[0].outputs = [LabOutput(kind: .error, text: "NameError: name 'X' is not defined", detail: "  File \"<cell 1>\", line 1\nNameError: name 'X' is not defined")]
        }
        store.askAboutLabError(id, cellID: cell.id)
        let note = try XCTUnwrap(store.currentNote)
        XCTAssertEqual(note.question, "Why does my code for Equation (1.1) fail?")
        XCTAssertTrue(note.body.contains("np.linalg.solve") && note.body.contains("NameError"), "The note keeps the code and the error.")
        XCTAssertEqual(note.anchor.pageIndex, 1)
        // “Ask an assistant…” opens the prepared question for review; nothing is sent yet.
        XCTAssertTrue(store.showQuestion); XCTAssertNil(note.pendingRequestID); XCTAssertTrue(opened.isEmpty)
        let preset = try XCTUnwrap(store.questionPreset)
        XCTAssertEqual(preset.noteID, note.id)
        let draft = try XCTUnwrap(preset.prompt)
        // The reader reviews the draft in the question sheet, then sends it with ChatGPT's Review in Lemma.
        store.askWeb(mode: .draft, content: try store.questionContent(note: note, style: preset.style, candidates: preset.candidates, selection: preset.selection, prompt: draft),
                     noteID: note.id, provider: .chatGPTWeb)
        let requestID = try XCTUnwrap(store.currentNote?.pendingRequestID)
        XCTAssertEqual(opened.map(\.absoluteString), ["https://chatgpt.com/#lemma=\(requestID.uuidString)"])
        let packet = try store.mailbox.packet(requestID)
        XCTAssertEqual(packet.mode, .draft)
        XCTAssertEqual(packet.images.count, 1)
        for expected in ["implementing Equation (1.1)", "```python\nb = np.linalg.solve", "NameError: name 'X' is not defined", "corrected cell"] {
            XCTAssertTrue(packet.prompt.contains(expected), expected)
        }
        // The answer comes back to the note; its corrected cell goes to the open notebook.
        store.updateNote(id: note.id) { $0.pendingRequestID = nil; $0.explanation = SavedExplanation(body: "Define X first.\n```python\nX = np.ones((3, 2))\n```") }
        store.openExplanationCode(noteID: note.id)
        XCTAssertEqual(store.workspace?.labs.count, 1)
        XCTAssertEqual(store.lab(id)?.cells.last?.source, "X = np.ones((3, 2))")
    }

    @MainActor
    func testRunningACellRecordsOutputsFiguresAndExports() async throws {
        let interpreters = await LabRuntime().discover()
        guard interpreters.first?.isScientific == true else { throw XCTSkip("Needs Python with NumPy and Matplotlib") }
        let fixture = try WorkbenchFixture()
        defer { fixture.close(); fixture.store.lab.shutdownAll() }
        let store = fixture.store
        store.open(fixture.book)
        let id = try XCTUnwrap(store.newLab(title: "Check"))
        let cell = try XCTUnwrap(store.lab(id)?.cells.first)
        store.updateLab(id) { $0.cells[0].source = "import matplotlib.pyplot as plt\nplt.plot([1, 3, 2])\nprint('ok')\n6 * 7" }
        store.runLabCell(id, cellID: cell.id)
        let deadline = Date.now.addingTimeInterval(40)
        while store.lab(id)?.cells.first?.executionCount == nil, Date.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        let outputs = try XCTUnwrap(store.lab(id)?.cells.first?.outputs)
        XCTAssertEqual(outputs.map(\.kind), [.stdout, .result, .image])
        guard outputs.count == 3 else { return }
        XCTAssertEqual(outputs[0].text, "ok\n")
        XCTAssertEqual(outputs[1].text, "42")
        let image = try XCTUnwrap(outputs[2].imageName)
        let imageURL = store.repository.assetURL(workspaceID: store.workspace!.id, name: image)
        XCTAssertNotNil(NSImage(contentsOf: imageURL), "Figures are saved as PNG beside the book's crops.")
        XCTAssertEqual(store.lab.sessions[id]?.state, .idle)

        store.flush()
        let export = fixture.root.appendingPathComponent("export")
        try store.repository.export(try XCTUnwrap(store.workspace), to: export)
        let notebookData = try Data(contentsOf: export.appendingPathComponent("labs/Check.ipynb"))
        XCTAssertTrue(String(decoding: notebookData, as: UTF8.self).contains("image/png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.appendingPathComponent("labs/Check.py").path))
        XCTAssertTrue(try String(contentsOf: export.appendingPathComponent("Study notes.md"), encoding: .utf8).contains("[Check](labs/Check.ipynb)"))

        store.pinLabFigure(image, notebookID: id)
        let pinned = try XCTUnwrap(store.workspace?.notes.first { $0.figureName != nil })
        XCTAssertEqual(pinned.kind, .comment, "A pinned figure is a margin note.")
        XCTAssertEqual(pinned.question, "Check")
        let figureURL = store.repository.assetURL(workspaceID: store.workspace!.id, name: try XCTUnwrap(pinned.figureName))
        store.clearLabOutputs(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path), "Clearing outputs removes their figures.")
        XCTAssertNotNil(NSImage(contentsOf: figureURL), "A figure pinned beside the page is a copy and stays.")
        let second = fixture.root.appendingPathComponent("export-2")
        try store.repository.export(try XCTUnwrap(store.workspace), to: second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.appendingPathComponent("assets/\(pinned.figureName!)").path))
        store.restartLabKernel(id)
        XCTAssertEqual(store.lab.sessions[id]?.state, .starting)
    }

    @MainActor
    func testConsoleRunsBesideTheBookAndSharesTheOpenNotebook() async throws {
        let interpreters = await LabRuntime().discover()
        guard !interpreters.isEmpty else { throw XCTSkip("Needs Python 3") }
        let fixture = try WorkbenchFixture()
        defer { fixture.close(); fixture.store.lab.shutdownAll() }
        let store = fixture.store
        store.open(fixture.book)
        let scratch = try XCTUnwrap(store.consoleTarget)
        store.runConsole("x = 21")
        store.runConsole("x * 2")
        func wait(_ id: UUID, entries count: Int) async throws {
            let deadline = Date.now.addingTimeInterval(30)
            while (store.lab.consoles[id] ?? []).filter({ $0.count != nil }).count < count, Date.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        }
        try await wait(scratch, entries: 2)
        XCTAssertEqual(store.lab.consoles[scratch]?.last?.outputs.map(\.text), ["42"], "Without a notebook the console has a scratch session.")
        XCTAssertEqual(store.lab.history, ["x = 21", "x * 2"])

        let notebook = try XCTUnwrap(store.newLab(title: "Shared"))
        XCTAssertEqual(store.consoleTarget, notebook, "With a notebook open, the console uses its Python.")
        store.updateLab(notebook) { $0.cells[0].source = "y = 5" }
        store.runLabCell(notebook, cellID: try XCTUnwrap(store.lab(notebook)?.cells.first?.id))
        store.runConsole("y + 1")
        try await wait(notebook, entries: 1)
        XCTAssertEqual(store.lab.consoles[notebook]?.first?.outputs.map(\.text), ["6"], "The console sees the notebook's variables.")
        XCTAssertEqual(store.lab(notebook)?.cells.first?.executionCount, 1, "The cell ran first; the console waited its turn.")
        store.clearConsole()
        XCTAssertEqual(store.lab.consoles[notebook]?.count, 0)
    }

    @MainActor
    func testClearingConsoleKeepsCommandsAlreadyQueuedForPython() async throws {
        guard !(await LabRuntime().discover()).isEmpty else { throw XCTSkip("Needs Python 3") }
        let fixture = try WorkbenchFixture()
        defer { fixture.close(); fixture.store.lab.shutdownAll() }
        let store = fixture.store
        store.open(fixture.book)
        let sessionID = try XCTUnwrap(store.consoleTarget)
        // All three commands wait for the new kernel. Clearing the display must not cancel the first two.
        store.runConsole("x = 21")
        store.runConsole("x *= 2")
        store.clearConsole()
        XCTAssertTrue(store.lab.consoles[sessionID]?.isEmpty == true)
        store.runConsole("x")
        let deadline = Date.now.addingTimeInterval(30)
        while store.lab.consoles[sessionID]?.last?.count == nil, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(store.lab.consoles[sessionID]?.count, 1)
        XCTAssertEqual(store.lab.consoles[sessionID]?.last?.outputs.map(\.text), ["42"])
        XCTAssertEqual(store.lab.consoles[sessionID]?.last?.count, 3)
    }

    /// Lemma calls shutdownAll as it quits: a kernel stuck in `while True: pass` must be gone when it returns.
    @MainActor
    func testQuittingStopsABusyKernelBeforeReturning() async throws {
        guard !(await LabRuntime().discover()).isEmpty else { throw XCTSkip("Needs Python 3") }
        let fixture = try WorkbenchFixture()
        defer { fixture.close(); fixture.store.lab.shutdownAll() }
        let store = fixture.store
        store.open(fixture.book)
        let id = try XCTUnwrap(store.newLab(title: "Forever"))
        let cell = try XCTUnwrap(store.lab(id)?.cells.first)
        store.updateLab(id) { $0.cells[0].source = "while True:\n    pass" }
        store.runLabCell(id, cellID: cell.id)
        let deadline = Date.now.addingTimeInterval(30)
        while store.lab.sessions[id]?.state != .busy, Date.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(300))
        let pid = try XCTUnwrap(store.lab.sessions[id]?.kernel?.processIdentifier)
        XCTAssertTrue(LabKernel.isProcessAlive(pid))
        let started = Date.now
        store.lab.shutdownAll()
        XCTAssertLessThan(Date.now.timeIntervalSince(started), 1.3, "Quitting waits about a second at most.")
        XCTAssertFalse(LabKernel.isProcessAlive(pid), "The kernel has stopped when shutdownAll returns.")
        XCTAssertTrue(store.lab.sessions.isEmpty)
    }

    /// Restarted, stopped, or closed with its book while Python is still being looked for: no session that was let go
    /// may start a kernel afterwards.
    @MainActor
    func testNotebooksLetGoWhileStartingNeverLeaveAKernel() async throws {
        guard !(await LabRuntime().discover()).isEmpty else { throw XCTSkip("Needs Python 3") }
        let fixture = try WorkbenchFixture()
        defer { fixture.close(); fixture.store.lab.shutdownAll() }
        let store = fixture.store
        store.open(fixture.book)
        let before = Set(LabKernel.runningProcessIdentifiers)
        let id = try XCTUnwrap(store.newLab(title: "Let go"))
        let cell = try XCTUnwrap(store.lab(id)?.cells.first)
        store.updateLab(id) { $0.cells[0].source = "x = 1" }
        store.runLabCell(id, cellID: cell.id)
        XCTAssertEqual(store.lab.sessions[id]?.state, .starting, "This store's runtime has not found Python yet.")
        store.restartLabKernel(id)
        store.stopLabKernel(id)
        store.runLabCell(id, cellID: cell.id)
        store.closeBook()
        XCTAssertTrue(store.lab.sessions.isEmpty)
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(Set(LabKernel.runningProcessIdentifiers).subtracting(before), [], "No kernel was started for a session nobody holds.")
    }

    /// A notebook whose book went to another tab keeps running; its output is gathered in memory and saved once, when
    /// the cell ends, instead of the whole workspace being loaded and saved for every line.
    @MainActor
    func testANotebookInAnotherTabIsSavedOnceWhenItsCellEnds() async throws {
        guard !(await LabRuntime().discover()).isEmpty else { throw XCTSkip("Needs Python 3") }
        let fixture = try WorkbenchFixture()
        defer { fixture.close(); fixture.store.lab.shutdownAll() }
        let store = fixture.store
        store.open(fixture.book)
        let bookID = try XCTUnwrap(store.workspace?.id)
        let id = try XCTUnwrap(store.newLab(title: "Background"))
        let cell = try XCTUnwrap(store.lab(id)?.cells.first)
        store.updateLab(id) { $0.cells[0].source = "import time\nfor i in range(6):\n    print(i, flush=True)\n    time.sleep(0.25)" }
        store.runLabCell(id, cellID: cell.id)
        var deadline = Date.now.addingTimeInterval(30)
        while store.lab.sessions[id]?.state != .busy, Date.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        store.open(fixture.paper)
        XCTAssertNotEqual(store.workspace?.id, bookID)
        let file = store.repository.directory(for: bookID).appendingPathComponent("workspace.json")
        func modified() throws -> Date { try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) }
        let saved = try modified()
        var rewrites = 0
        deadline = Date.now.addingTimeInterval(30)
        while store.lab.sessions[id]?.runningCellID != nil, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(40))
            if try modified() != saved, store.lab.sessions[id]?.runningCellID != nil { rewrites += 1 }
        }
        XCTAssertEqual(rewrites, 0, "The book in the other tab is not rewritten while its cell prints.")
        XCTAssertNotEqual(try modified(), saved, "It is saved when the cell ends.")
        let reloaded = try XCTUnwrap(try store.repository.load(id: bookID)?.labs.first { $0.id == id }?.cells.first)
        XCTAssertEqual(reloaded.outputs.map(\.text).joined(), "0\n1\n2\n3\n4\n5\n", "Every line is kept.")
        XCTAssertEqual(reloaded.executionCount, 1)
    }

    /// Closing the tab of a book whose cell runs in the background keeps what the cell printed, with a note.
    @MainActor
    func testClosingOneBookTabKeepsPythonWhileAnotherWindowUsesTheBook() async throws {
        guard !(await LabRuntime().discover()).isEmpty else { throw XCTSkip("Needs Python 3") }
        let fixture = try WorkbenchFixture(), app = fixture.store.app
        defer { app.prepareForTermination(); fixture.close() }
        let first = app.claimWindow(nil)
        first.open(fixture.book)
        let bookID = try XCTUnwrap(first.workspace?.id)
        let notebookID = try XCTUnwrap(first.newLab(title: "Shared Python"))
        let cellID = try XCTUnwrap(first.lab(notebookID)?.cells.first?.id)
        first.updateLab(notebookID) { $0.cells[0].source = "x = 21" }
        first.runLabCell(notebookID, cellID: cellID)
        let deadline = Date.now.addingTimeInterval(30)
        while first.lab(notebookID)?.cells.first?.executionCount == nil, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let session = try XCTUnwrap(first.lab.sessions[notebookID])
        XCTAssertEqual(session.state, .idle)
        let second = app.newWindow()
        _ = app.claimWindow(second.windowID)
        second.open(fixture.book)
        second.openLabNotebook(notebookID)

        first.closeTab(bookID)

        XCTAssertTrue(second.lab.sessions[notebookID] === session, "Closing a duplicate book tab must keep the shared notebook's Python and variables")
        second.runConsole("x * 2")
        let answerDeadline = Date.now.addingTimeInterval(30)
        while second.lab.consoles[notebookID]?.last?.count == nil, Date.now < answerDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(second.lab.consoles[notebookID]?.last?.outputs.map(\.text), ["42"])
        second.closeTab(bookID)
        XCTAssertNil(app.lab.sessions[notebookID], "The last open tab still releases Python")
    }

    @MainActor
    func testPythonKeepsDeliveringAfterItsOriginalWindowCloses() async throws {
        guard !(await LabRuntime().discover()).isEmpty else { throw XCTSkip("Needs Python 3") }
        let fixture = try WorkbenchFixture(), app = fixture.store.app
        defer { app.prepareForTermination(); fixture.close() }
        var first: StudyStore? = app.newWindow()
        _ = app.claimWindow(first!.windowID)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 700), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        first!.mainWindow = window
        first!.open(fixture.book)
        let notebookID = try XCTUnwrap(first!.newLab(title: "Shared Python"))
        let cellID = try XCTUnwrap(first!.lab(notebookID)?.cells.first?.id)
        first!.updateLab(notebookID) { $0.cells[0].source = "x = 21" }
        first!.runLabCell(notebookID, cellID: cellID)
        let deadline = Date.now.addingTimeInterval(30)
        while first!.lab(notebookID)?.cells.first?.executionCount == nil, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let session = try XCTUnwrap(app.lab.sessions[notebookID])
        XCTAssertEqual(session.state, .idle)
        let second = app.newWindow()
        _ = app.claimWindow(second.windowID)
        second.open(fixture.book)
        second.openLabNotebook(notebookID)
        weak var original = first
        app.windowWillClose(window)
        first = nil
        let releaseDeadline = Date.now.addingTimeInterval(3)
        while original != nil, Date.now < releaseDeadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNil(original, "The closed workbench must not be retained by Python")

        second.runConsole("x * 2")
        let answerDeadline = Date.now.addingTimeInterval(5)
        while app.lab.consoles[notebookID]?.last?.count == nil, Date.now < answerDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(app.lab.sessions[notebookID] === session, "The surviving window keeps the same Python and its variables")
        XCTAssertEqual(app.lab.consoles[notebookID]?.last?.outputs.map(\.text), ["42"])
        XCTAssertEqual(session.state, .idle, "The kernel's completion must still reach the surviving window")
    }

    @MainActor
    func testClosingABookMidRunKeepsTheOutputSoFar() async throws {
        guard !(await LabRuntime().discover()).isEmpty else { throw XCTSkip("Needs Python 3") }
        let fixture = try WorkbenchFixture()
        defer { fixture.close(); fixture.store.lab.shutdownAll() }
        let store = fixture.store
        store.open(fixture.book)
        let bookID = try XCTUnwrap(store.workspace?.id)
        let id = try XCTUnwrap(store.newLab(title: "Closed"))
        let cell = try XCTUnwrap(store.lab(id)?.cells.first)
        store.updateLab(id) { $0.cells[0].source = "import time\nfor i in range(100):\n    print(i, flush=True)\n    time.sleep(0.1)" }
        store.runLabCell(id, cellID: cell.id)
        store.open(fixture.paper)
        let deadline = Date.now.addingTimeInterval(30)
        while (store.lab.sessions[id]?.live?.outputs.first?.text.count ?? 0) < 4, Date.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        store.closeTab(bookID)
        XCTAssertNil(store.lab.sessions[id])
        let outputs = try XCTUnwrap(try store.repository.load(id: bookID)?.labs.first { $0.id == id }?.cells.first?.outputs)
        XCTAssertTrue(outputs.first?.text.hasPrefix("0\n1\n") == true, "\(outputs)")
        XCTAssertEqual(outputs.last?.text, "Stopped: the book was closed")
    }

    /// Settings › Lab › Python Path applies without relaunching: an idle kernel on the old interpreter restarts at its
    /// next run, and a path that is not a Python leaves the best interpreter in use with a reason.
    @MainActor
    func testPythonPathAppliesAtOnce() async throws {
        let interpreters = await LabRuntime().discover()
        guard interpreters.count >= 2 else { throw XCTSkip("Needs two Pythons") }
        let saved = UserDefaults.standard.object(forKey: LabPreferences.interpreter)
        defer { UserDefaults.standard.set(saved, forKey: LabPreferences.interpreter) }
        let fixture = try WorkbenchFixture()
        defer { fixture.close(); fixture.store.lab.shutdownAll() }
        let store = fixture.store
        store.open(fixture.book)
        await store.discoverPython()
        let (first, second) = (interpreters[0], interpreters[1])
        store.lab.setPreferredInterpreter(first.path)
        XCTAssertEqual(store.lab.interpreter?.path, first.path)
        let id = try XCTUnwrap(store.newLab(title: "Switch"))
        let cell = try XCTUnwrap(store.lab(id)?.cells.first)
        store.updateLab(id) { $0.cells[0].source = "x = 1" }
        func run() async throws {
            store.updateLab(id) { $0.cells[0].executionCount = nil }
            store.runLabCell(id, cellID: cell.id)
            let deadline = Date.now.addingTimeInterval(30)
            while store.lab(id)?.cells.first?.executionCount == nil, Date.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        }
        try await run()
        let kernel = try XCTUnwrap(store.lab.sessions[id]?.kernel)
        XCTAssertEqual(kernel.configuration.interpreter.path, first.path)
        store.lab.setPreferredInterpreter(second.path)
        XCTAssertEqual(store.lab.interpreter?.path, second.path, "The choice applies at once.")
        try await run()
        XCTAssertFalse(store.lab.sessions[id]?.kernel === kernel, "The idle kernel restarted at the next run.")
        XCTAssertEqual(store.lab.sessions[id]?.kernel?.configuration.interpreter.path, second.path)
        XCTAssertTrue(store.lab.sessions[id]?.message?.contains("Now using Python \(second.version)") == true)

        store.lab.setPreferredInterpreter("/nonexistent/python3")
        let deadline = Date.now.addingTimeInterval(5)
        while store.lab.interpreterProblem == nil, Date.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotNil(store.lab.interpreterProblem, "A path that is not a Python says why it is not used.")
        XCTAssertNotNil(store.lab.interpreter)
        XCTAssertNotEqual(store.lab.interpreter?.path, "/nonexistent/python3")
    }

    @MainActor
    func testReadingTimeCountsOnlyWhileTheReaderIsActive() async throws {
        let fixture = try WorkbenchFixture()
        defer { fixture.close() }
        let store = fixture.store
        store.open(fixture.book)
        let tracker = try XCTUnwrap(store.tracker)
        var idle: TimeInterval = 5, front = true
        tracker.idleSeconds = { idle }
        tracker.isReaderInFront = { front }
        store.reader.focusPageIndex = 2
        let start = Date.now
        tracker.lastTick = start
        func recorded() -> Double { (store.workspace?.readingLog.seconds(onPage: 2) ?? 0) + tracker.pendingSeconds(for: store.workspace!.id) }
        tracker.tick(now: start.addingTimeInterval(5))
        tracker.tick(now: start.addingTimeInterval(10))
        idle = 300
        tracker.tick(now: start.addingTimeInterval(15))
        idle = 5; front = false
        tracker.tick(now: start.addingTimeInterval(20))
        front = true
        tracker.tick(now: start.addingTimeInterval(25))
        XCTAssertEqual(recorded(), 15, "Idle and background time is not counted.")
        store.flush()
        XCTAssertEqual(store.workspace?.readingLog.seconds(onPage: 2), 15)
        XCTAssertEqual(tracker.pendingSeconds(for: store.workspace!.id), 0)
        XCTAssertEqual(store.chapterProgress(of: try XCTUnwrap(store.outline.first)), 0, "Fifteen seconds is not yet a page read.")
        tracker.tick(now: start.addingTimeInterval(400))
        XCTAssertEqual(recorded(), 25, "A long gap counts at most ten seconds.")
        store.flush()
        let reopened = try XCTUnwrap(try store.repository.load(id: store.workspace!.id))
        XCTAssertEqual(reopened.readingLog.seconds(onPage: 2), 25, "Reading time is saved with the book.")
        XCTAssertEqual(store.chapterProgress(of: try XCTUnwrap(store.outline.first)) ?? 0, 1.0 / 3, accuracy: 0.001, "One of the chapter's three pages is read.")
    }

    @MainActor
    func testPageInspectorAndHoverPreviewUseTheBooksApparatus() async throws {
        let fixture = try WorkbenchFixture()
        defer { fixture.close() }
        let store = fixture.store
        store.open(fixture.book)
        try await fixture.waitForAnalysis()
        XCTAssertEqual(store.studySection, .page, "A book without notes opens on the page inspector.")
        XCTAssertEqual(store.indexEntries(onPage: 1).map(\.title).sorted(), ["Least squares", "Least squares › normal equations"])
        XCTAssertEqual(store.indexEntries(onPage: 3).map(\.title), ["Ridge regression"])
        let source = try XCTUnwrap(store.pageSource(2))
        XCTAssertEqual(source.label, "1 Least Squares")
        XCTAssertTrue(source.quote.contains("ridge regression adds a penalty"))

        let key = ReferenceKey(kind: .equation, number: "1.1")
        let target = try XCTUnwrap(store.references?.knownTarget(key))
        let content = HoverPreviewContent(store: store, key: key, target: target)
        let image = try XCTUnwrap(content.image, "The hover shows the equation rendered from its page.")
        XCTAssertGreaterThan(image.size.width, 40)
        XCTAssertEqual(content.count, 1, "Its reference count comes from the analysis.")
        let citation = try XCTUnwrap(store.analysis?.analysis?.citations.first.flatMap { store.analysis?.citationKey(for: $0) })
        let cited = HoverPreviewContent(store: store, key: citation, target: try XCTUnwrap(store.references?.knownTarget(citation)))
        XCTAssertTrue(cited.entryText?.contains("(19") == true, "A citation's hover shows its entry.")
    }
}
