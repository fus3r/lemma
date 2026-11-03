import AppKit
import PDFKit
import LemmaCore
import Observation

enum LabPreferences {
    /// The interpreter the reader chose; empty for the best one found.
    static let interpreter = "lab.interpreter"
    /// Utility QoS and at most two math threads, to keep the Mac cool. On by default.
    static let gentle = "lab.gentle"
    /// Exporting a notebook also writes its code as a .py script beside the .ipynb. On by default.
    static let exportScript = "lab.exportScript"
}

enum LabKernelState: Equatable {
    case stopped, starting, idle, busy
    var label: String {
        switch self { case .stopped: "Not started"; case .starting: "Starting"; case .idle: "Idle"; case .busy: "Running" }
    }
}

/// One notebook's Python process and the cells waiting to run in it.
@MainActor @Observable
final class LabSession {
    let notebookID: UUID
    let workspaceID: String
    var state: LabKernelState = .stopped
    var python: String?
    var packages: [String: String] = [:]
    var runningCellID: UUID?
    var queued: [UUID] = []
    private(set) var message: String?
    /// The message is about Python missing or lacking packages: the notebook offers Set Up Python for the Lab.
    private(set) var offersSetup = false
    /// The message is about the running cell (“Interrupting…”) and goes when it ends; others stay until closed or the next run.
    @ObservationIgnored private(set) var messageIsTransient = false
    @ObservationIgnored var kernel: LabKernel?
    @ObservationIgnored var requests: [UUID: UUID] = [:]
    @ObservationIgnored var interruptedAt: Date?
    @ObservationIgnored var completionWaiters: [UUID: CheckedContinuation<[String], Never>] = [:]
    /// Console inputs waiting or running in this session, among the queued ids.
    @ObservationIgnored var consoleIDs: Set<UUID> = []
    /// The running cell's outputs, gathered here and shown once per batch of kernel events (at most ten times a second)
    /// in the open book; a notebook of a book in another tab gets them, saved once, when the cell ends.
    @ObservationIgnored var live: LiveOutput?
    /// `LabRuntime.environmentGeneration` when the kernel started.
    @ObservationIgnored var generation = 0

    struct LiveOutput {
        let cellID: UUID
        var outputs: [LabOutput] = []
        var changed = false
    }

    init(notebookID: UUID, workspaceID: String) { self.notebookID = notebookID; self.workspaceID = workspaceID }

    func isPending(_ cellID: UUID) -> Bool { queued.contains(cellID) }

    func show(_ message: String?, offeringSetup: Bool = false, transient: Bool = false) {
        self.message = message
        offersSetup = message != nil && offeringSetup
        messageIsTransient = transient
    }

    /// Completion requests get no answer from a kernel that is going away.
    func cancelWaiters() {
        for waiter in completionWaiters.values { waiter.resume(returning: []) }
        completionWaiters.removeAll()
    }
}

/// One line or block typed in the console and what it printed.
struct ConsoleEntry: Identifiable, Equatable {
    let id: UUID
    var code: String
    var outputs: [LabOutput] = []
    var count: Int?
}

/// What the main actor receives from a kernel: its events, with figures already written to disk.
enum LabDelivery: Sendable {
    case event(LabKernelEvent)
    case figure(requestID: UUID?, name: String?, failure: String?)

    /// Runs on the kernel's own queue, so saving PNGs never holds up the main thread.
    static func prepare(_ events: [LabKernelEvent], repository: WorkspaceRepository, workspaceID: String) -> [LabDelivery] {
        events.map { event in
            guard case let .image(request, png) = event else { return .event(event) }
            let name = "lab-\(UUID().uuidString).png"
            do {
                try repository.saveImage(png, workspaceID: workspaceID, name: name)
                return .figure(requestID: request, name: name, failure: nil)
            } catch {
                return .figure(requestID: request, name: nil, failure: error.localizedDescription)
            }
        }
    }

    /// Figures written for a kernel whose notebook has let go of it are deleted again.
    static func discard(_ deliveries: [LabDelivery], repository: WorkspaceRepository, workspaceID: String) {
        for case let .figure(_, name?, _) in deliveries {
            try? FileManager.default.removeItem(at: repository.assetURL(workspaceID: workspaceID, name: name))
        }
    }
}

/// Python for the Lab: the interpreters on this Mac, and a kernel per open notebook.
@MainActor @Observable
final class LabRuntime {
    private(set) var interpreters: [LabInterpreter] = []
    private(set) var isDiscovering = false
    private(set) var hasDiscovered = false
    var sessions: [UUID: LabSession] = [:]
    /// The cell with keyboard focus in the open notebook.
    var selectedCellID: UUID?
    /// Changes when a cell should take keyboard focus.
    var focusRequest: (cellID: UUID, token: Int)?
    /// Settings › Lab › Python Path, as used: empty for the best interpreter found.
    private(set) var preferredPath: String
    /// Why the chosen Python Path is not used (the Lab falls back to the best interpreter found); nil when it is.
    private(set) var interpreterProblem: String?
    /// Bumped when Lemma's own environment is made again at the same path: idle kernels started before it restart
    /// at their next run, as they do when the interpreter changes.
    private(set) var environmentGeneration = 0
    /// Lemma's support folder: its own Python environment lives in `Lab/python` there.
    @ObservationIgnored var supportRoot: URL
    /// Set Up Python for the Lab.
    let setup = LabPythonSetup()
    /// Writes what a running cell gathered, with a note, when its kernel is stopped from here (its book closed, Lemma
    /// quitting): only the store can reach the notebook, so it sets this.
    @ObservationIgnored var saveStoppedOutput: ((LabSession, String) -> Void)?
    @ObservationIgnored private var discovery: Task<[LabInterpreter], Never>?
    @ObservationIgnored private var interpreterCheck: Task<Void, Never>?
    @ObservationIgnored let images = NSCache<NSString, NSImage>()
    /// The console's inputs and outputs for each session, for this launch only.
    var consoles: [UUID: [ConsoleEntry]] = [:]
    /// Lines entered in any console, oldest first, for ↑ and ↓.
    var history: [String] = []
    /// A scratch session per book, for the console when no notebook is open.
    @ObservationIgnored private var scratch: [String: UUID] = [:]

    /// `supportRoot` defaults to the folder Lemma's store uses (LEMMA_SUPPORT_DIR or Application Support).
    init(supportRoot: URL? = nil) {
        self.supportRoot = supportRoot ?? ProcessInfo.processInfo.environment["LEMMA_SUPPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? WorkspaceRepository.defaultRoot
        preferredPath = UserDefaults.standard.string(forKey: LabPreferences.interpreter) ?? ""
        setup.lab = self
    }

    func scratchID(for workspaceID: String) -> UUID {
        if let id = scratch[workspaceID] { return id }
        let id = UUID(); scratch[workspaceID] = id
        return id
    }

    /// Lemma's own environment, made by Set Up Python for the Lab.
    var environmentDirectory: URL { LabEnvironment.directory(support: supportRoot) }
    var environmentInterpreter: String { LabEnvironment.interpreter(in: environmentDirectory).path }

    var interpreter: LabInterpreter? {
        interpreters.first { $0.path == preferredPath } ?? interpreters.first
    }

    var gentle: Bool { UserDefaults.standard.object(forKey: LabPreferences.gentle) as? Bool ?? true }

    /// Finds the interpreters once per launch (or again when asked); about a second.
    @discardableResult
    func discover(force: Bool = false) async -> [LabInterpreter] {
        if hasDiscovered && !force { return interpreters }
        let task: Task<[LabInterpreter], Never>
        if let discovery, !force {
            task = discovery
        } else {
            isDiscovering = true
            let preferred = preferredPath.isEmpty ? nil : preferredPath
            let managed = environmentDirectory
            task = Task.detached(priority: .userInitiated) { LabInterpreterFinder.discover(preferred: preferred, managed: managed) }
            discovery = task
        }
        // Every caller records the result, so none can look at the list before it is set.
        let found = await task.value
        interpreters = found
        isDiscovering = false; hasDiscovered = true; discovery = nil
        interpreterProblem = preferredPath.isEmpty || found.contains(where: { $0.path == preferredPath }) ? nil : problem(with: preferredPath)
        return found
    }

    /// Adds an interpreter chosen by the reader and makes it the default.
    func choose(path: String) async -> LabInterpreter? {
        let probed = await Task.detached { LabInterpreterFinder.probe(path) }.value
        guard let probed else { return nil }
        interpreters.removeAll { $0.path == path }
        interpreters.insert(probed, at: 0)
        setPreferredPath(path)
        return probed
    }

    /// Applies Settings › Lab › Python Path at once. Empty means the best interpreter found; another path is checked
    /// after a pause (it may still be being typed) and, when Python runs there, used from the next run: an idle kernel
    /// on another interpreter restarts then. A path that does not work leaves the best interpreter in use and says why.
    func setPreferredInterpreter(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = trimmed.isEmpty ? "" : (trimmed as NSString).expandingTildeInPath
        setPreferredPath(expanded)
        guard !expanded.isEmpty, !interpreters.contains(where: { $0.path == expanded }) else { return }
        interpreterCheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            let found = await Task.detached { LabInterpreterFinder.probe(expanded) }.value
            guard let self, !Task.isCancelled, self.preferredPath == expanded else { return }
            if let found {
                self.interpreters.removeAll { $0.path == found.path }
                self.interpreters.insert(found, at: 0)
            } else {
                self.interpreterProblem = self.problem(with: expanded)
            }
        }
    }

    private func setPreferredPath(_ path: String) {
        interpreterCheck?.cancel(); interpreterCheck = nil
        UserDefaults.standard.set(path, forKey: LabPreferences.interpreter)
        if preferredPath != path { preferredPath = path }
        interpreterProblem = nil
    }

    private func problem(with path: String) -> String {
        let fallback = interpreters.first(where: { $0.path != path }).map { "Python \($0.version) (\($0.path))" } ?? "no Python"
        if !LabInterpreterFinder.isSafeToRun(path) {
            return "\(path) needs Apple's Command Line Tools, which are not installed. The Lab uses \(fallback) meanwhile."
        }
        if !FileManager.default.fileExists(atPath: path) { return "There is no Python at \(path). The Lab uses \(fallback) meanwhile." }
        return "\(path) did not run as Python 3. The Lab uses \(fallback) meanwhile."
    }

    /// Set Up Python for the Lab finished: notebooks use the new environment from their next run.
    func adoptEnvironment(_ interpreter: LabInterpreter) {
        interpreters.removeAll { $0.path == interpreter.path }
        interpreters.insert(interpreter, at: 0)
        setPreferredPath(interpreter.path)
        environmentGeneration += 1
    }

    /// Lemma's environment was removed (or a setup did not finish): the best other interpreter takes over, and kernels
    /// that ran in the environment restart at their next run.
    func forgetEnvironment() {
        interpreters.removeAll { $0.path == environmentInterpreter }
        if preferredPath == environmentInterpreter { setPreferredPath("") }
    }

    func session(_ notebookID: UUID) -> LabSession? { sessions[notebookID] }

    func image(named name: String, workspaceID: String, repository: WorkspaceRepository) -> NSImage? {
        let key = "\(workspaceID)/\(name)" as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: repository.assetURL(workspaceID: workspaceID, name: name)) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }

    func requestFocus(_ cellID: UUID) {
        selectedCellID = cellID
        focusRequest = (cellID, (focusRequest?.token ?? 0) + 1)
    }

    /// Stops every kernel, and a Python setup in progress, before returning: Lemma calls this as it quits, when nothing
    /// scheduled for later would run any more. A busy kernel is interrupted, then terminated, then killed; about a
    /// second at most in all.
    func shutdownAll() {
        setup.stopForQuit(force: false)
        LabKernel.shutdownAll(timeout: 1)
        setup.stopForQuit(force: true)
        for session in sessions.values where session.live != nil { saveStoppedOutput?(session, "Stopped: Lemma quit") }
        for session in sessions.values {
            session.kernel = nil
            session.live = nil
            session.cancelWaiters()
            session.state = .stopped
        }
        sessions.removeAll()
    }

    /// The book closed: its notebooks' kernels (and its console's) stop.
    func shutdown(workspaceID: String) {
        for (id, session) in sessions where session.workspaceID == workspaceID {
            session.kernel?.shutdown(); session.kernel = nil
            if session.live != nil { saveStoppedOutput?(session, "Stopped: the book was closed") }
            session.live = nil
            session.cancelWaiters()
            session.state = .stopped
            sessions[id] = nil
        }
    }
}

// MARK: - Notebooks in the store

@MainActor
extension StudyStore {
    var openLab: LabNotebook? { openLabID.flatMap { id in workspace?.labs.first { $0.id == id } } }

    /// Starts a notebook, optionally from a passage, and opens it beside the page.
    @discardableResult
    func newLab(title: String? = nil, source: LabSource? = nil, cells: [LabCell]? = nil) -> UUID? {
        guard let workspace else { return nil }
        let section = source.flatMap { source in references.flatMap { OutlineMap.section(containing: source.pageIndex, y: source.region.map { CGFloat($0.y + $0.height) }, in: $0.outline)?.title } }.map(repairedTitle)
        // The source card shows a passage with a region, so its words are not repeated in a text cell.
        let notebook = LabNotebook(title: title ?? source?.label ?? "Untitled lab",
                                   source: source,
                                   cells: cells ?? LabTemplate.cells(for: source, sectionTitle: section, bookTitle: workspace.title, quoteSource: source?.region == nil))
        self.workspace?.labs.insert(notebook, at: 0)
        flush()
        openLabNotebook(notebook.id)
        if let code = notebook.cells.last(where: { $0.kind == .code }) { lab.requestFocus(code.id) }
        status = "Lab notebook started. Run a cell with ⇧↩."
        Task { await discoverPython() }
        return notebook.id
    }

    func openLabNotebook(_ id: UUID) {
        if focusMode { toggleFocus() }
        openLabID = id
        fitPageIfOverflowing()
        Task { await discoverPython() }
    }

    /// Finds the Mac's Pythons, Lemma's own environment in this store's support folder among them.
    @discardableResult
    func discoverPython(force: Bool = false) async -> [LabInterpreter] {
        if lab.supportRoot != repository.root { lab.supportRoot = repository.root }
        return await lab.discover(force: force)
    }

    /// Set Up Python for the Lab: a window with progress and Cancel, beside the book.
    func showPythonSetup() {
        if lab.supportRoot != repository.root { lab.supportRoot = repository.root }
        LabPythonSetupWindow.show(store: self)
    }

    func closeLabEditor() {
        openLabID = nil
    }

    /// Sends the selected passage to the open notebook, or starts one from it.
    func sendSelectionToLab() {
        guard let document, let (pageIndex, rectangle, quote) = reader.selection, let page = document.page(at: pageIndex) else {
            if workspace != nil { newLab() }
            return
        }
        let region = PageRegion(rectangle)
        let label = labLabel(pageIndex: pageIndex, region: rectangle, page: page)
        sendToLab(LabSource(pageIndex: pageIndex, region: region, label: label, quote: quote))
    }

    /// Sends a referenced equation, algorithm or figure to the Lab.
    func sendTargetToLab(_ target: ReferenceTarget) {
        guard let page = document?.page(at: target.pageIndex) else { return }
        let quote = page.selection(for: target.region.rect)?.string ?? ""
        sendToLab(LabSource(pageIndex: target.pageIndex, region: target.region, label: target.key.spokenTitle, quote: quote))
    }

    private func sendToLab(_ source: LabSource) {
        if let id = openLabID, workspace?.labs.contains(where: { $0.id == id }) == true {
            let section = references.flatMap { OutlineMap.section(containing: source.pageIndex, in: $0.outline)?.title }.map(repairedTitle)
            let added = LabTemplate.cells(for: source, sectionTitle: section, bookTitle: workspace?.title ?? "", quoteSource: true)
            let code = LabCell(kind: .code, source: "# \(source.label), \(shortPageText(source.pageIndex))\n")
            let cells = Array(added.filter { $0.kind == .text }) + [code]
            updateLab(id) { $0.cells += cells }
            lab.requestFocus(code.id)
            status = "\(source.label) added to the open notebook."
        } else {
            newLab(source: source)
        }
    }

    /// “Equation (3.44)” when the selection covers a numbered object, otherwise the section it is in (or the page).
    func labLabel(pageIndex: Int, region: CGRect, page: PDFPage) -> String {
        if let target = analysis?.definitionsByPage[pageIndex]?.first(where: { $0.key.kind != .section && $0.region.rect.insetBy(dx: -4, dy: -4).intersects(region) && ($0.anchor.rect.intersects(region.insetBy(dx: -40, dy: -6)) || region.contains(CGPoint(x: $0.region.rect.midX, y: $0.region.rect.midY))) }) {
            return target.key.spokenTitle
        }
        let section = references.flatMap { OutlineMap.section(containing: pageIndex, y: region.maxY, in: $0.outline)?.title }
        return section.map(repairedTitle) ?? "Page \(printedLabel(for: pageIndex) ?? String(pageIndex + 1))"
    }

    /// Opens the Python code blocks of a note's saved explanation in the open notebook, or in a new one.
    func openExplanationCode(noteID: UUID) {
        guard let note = workspace?.notes.first(where: { $0.id == noteID }), let explanation = note.explanation else { return }
        let blocks = LabTemplate.codeBlocks(in: explanation.body)
        guard !blocks.isEmpty else { status = "This explanation has no Python code block."; return }
        let header = LabCell(kind: .text, source: "### \(note.title)\n\nCode from the saved explanation (\(explanation.savedAt.formatted(date: .abbreviated, time: .omitted))). Read it before running it.")
        let code = blocks.map { LabCell(kind: .code, source: $0) }
        if let id = openLabID, lab(id) != nil {
            updateLab(id) { $0.cells += [header] + code }
            if let first = code.first { lab.requestFocus(first.id) }
            status = "The answer's code was added to the open notebook. Nothing runs until you run a cell."
            return
        }
        let source = LabSource(pageIndex: note.anchor.pageIndex, region: note.anchor.region, label: note.title, quote: note.anchor.quote)
        newLab(title: note.title, source: source, cells: [header] + code)
    }

    /// Prepares a question about a failing cell, with its code, the error and the passage it implements, for review in
    /// the question sheet. The question is saved as a note; the answer (and its corrected cell) returns there.
    func askAboutLabError(_ notebookID: UUID, cellID: UUID) {
        guard let workspace, let notebook = lab(notebookID), let cell = notebook.cells.first(where: { $0.id == cellID }),
              let failure = cell.outputs.first(where: { $0.kind == .error }) else { return }
        let pageIndex = notebook.source?.pageIndex ?? (reader.pageNumber - 1)
        guard let page = document?.page(at: pageIndex) else { return }
        let box = page.bounds(for: .cropBox)
        let region = notebook.source?.region ?? PageRegion(box)
        do {
            let png = try PDFRegionRenderer.png(page: page, region: region)
            let name = "\(UUID().uuidString).png"
            try repository.saveImage(png, workspaceID: workspace.id, name: name)
            let anchor = SourceAnchor(pageIndex: pageIndex, pageLabel: page.label ?? String(pageIndex + 1), region: region,
                                      quote: notebook.source?.quote ?? "", imageName: name)
            let trace = (failure.detail ?? failure.text).trimmingCharacters(in: .whitespacesAndNewlines)
            var note = StudyNote(anchor: anchor, question: "Why does my code for \(notebook.title) fail?",
                                 body: "```python\n\(cell.source)\n```\n\n```\n\(trace)\n```")
            note.kind = .question
            self.workspace?.notes.insert(note, at: 0)
            if let bookID = self.workspace?.id { registerNoteCreationUndo(note, bookID: bookID) }
            selectedNoteID = note.id
            flush()
            let label = notebook.source.map { "\($0.label) (\(pageText($0.pageIndex)))" } ?? notebook.title
            let prompt = """
            I am studying \(workspace.title). I am implementing \(label) in Python with NumPy and Matplotlib in a local notebook, and this cell fails. The attached image is the passage I am implementing.

            Code:
            ```python
            \(cell.source)
            ```

            Error:
            ```
            \(trace)
            ```

            Explain briefly what is wrong in the code, or in how I read the book's notation, and give the corrected cell in a single ```python block. Keep my variable names where possible.
            """
            // “Ask an assistant…” promises a review: the prepared question opens in the question sheet, where the reader
            // checks the code, the error and the passage image, chooses an assistant and sends it.
            questionPreset = QuestionPreset(noteID: note.id, style: .explanation, candidates: QuestionContextCandidates(sourceText: anchor.quote),
                                            selection: ContextSelection(sourceText: false, section: false), prompt: prompt)
            showQuestion = true
        } catch { self.error = "Could not prepare the question: \(error.localizedDescription)" }
    }

    // MARK: Editing

    /// Edits a notebook in the open book, or in its saved workspace when it belongs to another book. The second case
    /// loads and saves that workspace whatever `save` says, so running cells do not come here for each piece of output:
    /// they gather it in their session and write it once when the cell ends.
    func updateLab(_ id: UUID, workspaceID: String? = nil, save: Bool = true, _ edit: (inout LabNotebook) -> Void) {
        let owner = workspaceID ?? workspace?.id
        if let owner, owner != workspace?.id, let showing = app.windows.first(where: { $0.workspace?.id == owner }) {
            showing.updateLab(id, workspaceID: owner, save: save, edit); return
        }
        if owner == workspace?.id, let index = workspace?.labs.firstIndex(where: { $0.id == id }) {
            edit(&workspace!.labs[index])
            workspace!.labs[index].updatedAt = .now
            if save { scheduleSave() }
        } else if let owner, var stored = try? repository.load(id: owner), let index = stored.labs.firstIndex(where: { $0.id == id }) {
            edit(&stored.labs[index])
            stored.labs[index].updatedAt = .now
            try? repository.save(stored)
        }
    }

    func lab(_ id: UUID) -> LabNotebook? { workspace?.labs.first { $0.id == id } }

    func addLabCell(_ notebookID: UUID, kind: LabCell.Kind, after cellID: UUID? = nil, source: String = "") {
        let cell = LabCell(kind: kind, source: source)
        updateLab(notebookID) { notebook in
            if let cellID, let index = notebook.cells.firstIndex(where: { $0.id == cellID }) { notebook.cells.insert(cell, at: index + 1) }
            else { notebook.cells.append(cell) }
        }
        lab.requestFocus(cell.id)
    }

    func deleteLabCell(_ notebookID: UUID, cellID: UUID) {
        guard let notebook = lab(notebookID), let index = notebook.cells.firstIndex(where: { $0.id == cellID }) else { return }
        removeLabImages(notebook.cells[index].outputs)
        if let session = lab.sessions[notebookID], session.live?.cellID == cellID { dropLiveOutput(session) }
        updateLab(notebookID) { $0.cells.removeAll { $0.id == cellID } }
        let remaining = lab(notebookID)?.cells ?? []
        if !remaining.isEmpty { lab.selectedCellID = remaining[min(index, remaining.count - 1)].id }
    }

    func moveLabCell(_ notebookID: UUID, cellID: UUID, by offset: Int) {
        updateLab(notebookID) { notebook in
            guard let index = notebook.cells.firstIndex(where: { $0.id == cellID }) else { return }
            let target = index + offset
            guard notebook.cells.indices.contains(target) else { return }
            notebook.cells.swapAt(index, target)
        }
    }

    func clearLabOutputs(_ notebookID: UUID) {
        guard let notebook = lab(notebookID) else { return }
        for cell in notebook.cells { removeLabImages(cell.outputs) }
        // A running cell goes on from nothing rather than bringing back what was cleared with its next output.
        if let session = lab.sessions[notebookID] { dropLiveOutput(session) }
        updateLab(notebookID) { notebook in
            for index in notebook.cells.indices { notebook.cells[index].outputs = []; notebook.cells[index].executionCount = nil }
        }
    }

    func deleteLab(_ notebookID: UUID) {
        guard lab(notebookID) != nil else { return }
        stopLabKernel(notebookID)
        // After stopping: a running cell's figures are in the notebook by then.
        for cell in lab(notebookID)?.cells ?? [] { removeLabImages(cell.outputs) }
        workspace?.labs.removeAll { $0.id == notebookID }
        closeSideEditor("lab:\(notebookID)")
        flush()
    }

    /// Forgets what a running cell has gathered so far, figures included.
    private func dropLiveOutput(_ session: LabSession) {
        guard let live = session.live else { return }
        removeLabImages(live.outputs, workspaceID: session.workspaceID)
        session.live?.outputs = []
        session.live?.changed = false
    }

    private func removeLabImages(_ outputs: [LabOutput], workspaceID: String? = nil) {
        removeLabImages(named: outputs.compactMap(\.imageName), workspaceID: workspaceID)
    }

    private func removeLabImages(named names: [String], workspaceID: String? = nil) {
        guard let owner = workspaceID ?? workspace?.id else { return }
        for name in names {
            try? FileManager.default.removeItem(at: repository.assetURL(workspaceID: owner, name: name))
            lab.images.removeObject(forKey: "\(owner)/\(name)" as NSString)
        }
    }

    // MARK: Running

    /// Queues a code cell and starts Python if needed. Outputs replace the cell's previous ones.
    func runLabCell(_ notebookID: UUID, cellID: UUID) {
        guard let workspace, let notebook = lab(notebookID), let cell = notebook.cells.first(where: { $0.id == cellID }), cell.kind == .code else { return }
        var session = lab.sessions[notebookID] ?? LabSession(notebookID: notebookID, workspaceID: workspace.id)
        lab.sessions[notebookID] = session
        guard !session.queued.contains(cellID), session.runningCellID != cellID else { return }
        session.show(nil)
        session = restartIfInterpreterChanged(session)
        session.queued.append(cellID)
        startLabKernelIfNeeded(session)
        dispatchLab(session)
    }

    func runAllLabCells(_ notebookID: UUID) {
        for cell in lab(notebookID)?.cells ?? [] where cell.kind == .code && !cell.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            runLabCell(notebookID, cellID: cell.id)
        }
    }

    /// Runs the cell, then selects the next one (adding a cell at the end), as ⇧↩ does.
    func runLabCell(_ notebookID: UUID, cellID: UUID, action: LabRunAction) {
        if lab(notebookID)?.cells.first(where: { $0.id == cellID })?.kind == .code { runLabCell(notebookID, cellID: cellID) }
        guard let cells = lab(notebookID)?.cells, let index = cells.firstIndex(where: { $0.id == cellID }) else { return }
        switch action {
        case .run: break
        case .runAndAdvance:
            if index + 1 < cells.count { lab.requestFocus(cells[index + 1].id) } else { addLabCell(notebookID, kind: .code, after: cellID) }
        case .runAndInsert: addLabCell(notebookID, kind: .code, after: cellID)
        }
    }

    func interruptLab(_ notebookID: UUID) {
        guard let session = lab.sessions[notebookID] else { return }
        session.queued.removeAll()
        guard session.state == .busy, let kernel = session.kernel else { return }
        session.interruptedAt = .now
        kernel.interrupt()
        session.show("Interrupting…", transient: true)
        // A cell stuck in native code may ignore the interrupt; offer a restart after a moment.
        Task { @MainActor [weak session] in
            try? await Task.sleep(for: .seconds(4))
            guard let session, session.state == .busy, let interrupted = session.interruptedAt, Date.now.timeIntervalSince(interrupted) >= 3.5 else { return }
            session.show("Python is not responding to the interrupt. Restart it to stop the cell.", transient: true)
        }
    }

    func restartLabKernel(_ notebookID: UUID) {
        stopLabKernel(notebookID)
        guard let workspace else { return }
        let session = LabSession(notebookID: notebookID, workspaceID: workspace.id)
        lab.sessions[notebookID] = session
        startLabKernelIfNeeded(session)
    }

    /// Stops the notebook's Python. A cell still running keeps what it printed, with a note that it was stopped.
    func stopLabKernel(_ notebookID: UUID) {
        guard let session = lab.sessions[notebookID] else { return }
        session.queued.removeAll()
        session.kernel?.shutdown()
        session.kernel = nil
        session.cancelWaiters()
        if let running = session.runningCellID, !session.consoleIDs.contains(running) {
            let note = LabOutput(kind: .error, text: "Stopped: Python was restarted")
            if session.live?.cellID == running {
                session.live?.outputs.append(note)
                finishLiveOutput(session, cellID: running)
            } else {
                updateLab(notebookID, workspaceID: session.workspaceID) { notebook in
                    if let index = notebook.cells.firstIndex(where: { $0.id == running }) { notebook.cells[index].outputs.append(note) }
                }
            }
        }
        session.live = nil
        session.runningCellID = nil
        session.state = .stopped
        lab.sessions[notebookID] = nil
    }

    /// A kernel started on another interpreter than the one now chosen (Settings › Lab, or Lemma's environment made
    /// again) restarts when code next runs in it, if it is idle: a running cell finishes on the old one first.
    private func restartIfInterpreterChanged(_ session: LabSession) -> LabSession {
        guard let kernel = session.kernel, session.state == .idle, session.runningCellID == nil, session.queued.isEmpty,
              let chosen = lab.interpreter else { return session }
        let path = kernel.configuration.interpreter.path
        let rebuilt = path == lab.environmentInterpreter && session.generation != lab.environmentGeneration
        guard path != chosen.path || rebuilt else { return session }
        kernel.shutdown()
        session.kernel = nil
        session.cancelWaiters()
        session.state = .stopped
        let fresh = LabSession(notebookID: session.notebookID, workspaceID: session.workspaceID)
        fresh.show("Now using Python \(chosen.version) at \(chosen.path); variables were cleared.")
        lab.sessions[session.notebookID] = fresh
        return fresh
    }

    private func startLabKernelIfNeeded(_ session: LabSession) {
        guard session.kernel == nil, session.state == .stopped else { return }
        session.state = .starting
        lab.saveStoppedOutput = { [weak self] session, note in
            guard let self, let live = session.live else { return }
            session.live?.outputs.append(LabOutput(kind: .error, text: note))
            self.finishLiveOutput(session, cellID: live.cellID)
            if session.workspaceID == self.workspace?.id { self.flush() }
        }
        let notebookID = session.notebookID
        Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            await self.discoverPython()
            // While Python was being found the notebook may have been restarted, stopped or closed with its book:
            // a kernel started for a session nobody holds would run on unseen.
            guard self.lab.sessions[notebookID] === session, session.state == .starting, session.kernel == nil else { return }
            guard let interpreter = self.lab.interpreter else {
                session.state = .stopped
                session.show("No Python 3 found on this Mac. Set Up Python for the Lab shows how to get one.", offeringSetup: true)
                self.failQueuedCells(session, message: "Python is not available")
                return
            }
            if self.lab.setup.isRunning, interpreter.path == self.lab.environmentInterpreter {
                session.state = .stopped
                session.show("Lemma's Python is being set up. Run the cell again when it is ready.")
                self.failQueuedCells(session, message: "Python is being set up")
                return
            }
            do {
                let script = try LabKernel.installScript(in: self.repository.root.appendingPathComponent("Lab", isDirectory: true))
                let directory = self.repository.directory(for: session.workspaceID).appendingPathComponent("labs/\(notebookID.uuidString)", isDirectory: true)
                let kernel = LabKernel(configuration: .init(interpreter: URL(fileURLWithPath: interpreter.path), workingDirectory: directory,
                                                            scriptURL: script, gentle: self.lab.gentle))
                session.kernel = kernel
                session.python = interpreter.version
                session.generation = self.lab.environmentGeneration
                let repository = self.repository, workspaceID = session.workspaceID
                // Output comes in batches, at most ten a second; the kernel is held weakly, so one that loses its
                // session is released (and stopped) rather than kept alive by its own events.
                try kernel.start(every: 0.1) { [weak self, weak kernel] events in
                    let deliveries = LabDelivery.prepare(events, repository: repository, workspaceID: workspaceID)
                    Task { @MainActor in
                        guard let self, let kernel else {
                            LabDelivery.discard(deliveries, repository: repository, workspaceID: workspaceID)
                            return
                        }
                        self.handleLab(deliveries, notebookID: notebookID, workspaceID: workspaceID, kernel: kernel)
                    }
                }
            } catch {
                session.kernel = nil
                session.state = .stopped
                session.show("Could not start Python: \(error.localizedDescription)")
                self.failQueuedCells(session, message: "Python could not start")
            }
        }
    }

    private func failQueuedCells(_ session: LabSession, message: String) {
        let cells = session.queued
        session.queued.removeAll()
        for cellID in cells {
            if session.consoleIDs.contains(cellID) {
                editConsole(session.notebookID, entry: cellID) { $0.outputs = [LabOutput(kind: .error, text: message)] }
                continue
            }
            updateLab(session.notebookID, workspaceID: session.workspaceID) { notebook in
                if let index = notebook.cells.firstIndex(where: { $0.id == cellID }) { notebook.cells[index].outputs = [LabOutput(kind: .error, text: message)] }
            }
        }
    }

    private func dispatchLab(_ session: LabSession) {
        guard session.state == .idle, session.runningCellID == nil, let kernel = session.kernel else { return }
        while let cellID = session.queued.first {
            session.queued.removeFirst()
            if session.consoleIDs.contains(cellID), let entry = lab.consoles[session.notebookID]?.first(where: { $0.id == cellID }) {
                let request = UUID()
                session.requests[request] = cellID
                session.runningCellID = cellID
                session.state = .busy
                kernel.execute(id: request, code: entry.code)
                return
            }
            let open = session.workspaceID == workspace?.id
            let notebook: LabNotebook? = open ? lab(session.notebookID)
                : (try? repository.load(id: session.workspaceID))?.labs.first { $0.id == session.notebookID }
            guard let cell = notebook?.cells.first(where: { $0.id == cellID }), cell.kind == .code else { continue }
            if open {
                removeLabImages(cell.outputs)
                updateLab(session.notebookID, save: false) { notebook in
                    if let index = notebook.cells.firstIndex(where: { $0.id == cellID }) { notebook.cells[index].outputs = [] }
                }
            }
            // Another book's notebook keeps its saved outputs until the cell ends and replaces them in one save.
            session.live = LabSession.LiveOutput(cellID: cellID)
            let request = UUID()
            session.requests[request] = cellID
            session.runningCellID = cellID
            session.state = .busy
            kernel.execute(id: request, code: cell.source)
            return
        }
    }

    /// One batch of a kernel's events, in order; the running cell's output then shows once for the whole batch.
    private func handleLab(_ deliveries: [LabDelivery], notebookID: UUID, workspaceID: String, kernel: LabKernel) {
        guard let session = lab.sessions[notebookID], session.kernel === kernel else {
            LabDelivery.discard(deliveries, repository: repository, workspaceID: workspaceID)
            return
        }
        for delivery in deliveries {
            guard session.kernel === kernel else { break }
            switch delivery {
            case let .event(event):
                handleLab(event, session: session)
            case let .figure(request, name?, _):
                output(session, request) { $0.append(LabOutput(kind: .image, imageName: name)) }
            case let .figure(request, nil, failure):
                output(session, request) { LabOutput.append("Could not save a figure: \(failure ?? "")\n", stream: .stderr, to: &$0) }
            }
        }
        showLiveOutput(session)
    }

    /// The cell or console entry a request belongs to.
    private func cellID(_ request: UUID?, in session: LabSession) -> UUID? {
        request.flatMap { session.requests[$0] } ?? session.runningCellID
    }

    /// Changes the outputs of the cell or console entry a request belongs to: the running cell's gathered outputs,
    /// a console entry, or (for a cell that is not the one running, which should not happen) the notebook itself.
    private func output(_ session: LabSession, _ request: UUID?, _ change: (inout [LabOutput]) -> Void) {
        guard let id = cellID(request, in: session) else { return }
        if session.consoleIDs.contains(id) { editConsole(session.notebookID, entry: id) { change(&$0.outputs) }; return }
        if session.live?.cellID == id {
            change(&session.live!.outputs)
            session.live!.changed = true
            return
        }
        updateLab(session.notebookID, workspaceID: session.workspaceID, save: false) { notebook in
            if let index = notebook.cells.firstIndex(where: { $0.id == id }) { change(&notebook.cells[index].outputs) }
        }
    }

    /// Shows the running cell's new output in the open book, without saving; the cell's end saves it.
    private func showLiveOutput(_ session: LabSession) {
        guard let live = session.live, live.changed, session.workspaceID == workspace?.id else { return }
        session.live?.changed = false
        updateLab(session.notebookID, save: false) { notebook in
            if let index = notebook.cells.firstIndex(where: { $0.id == live.cellID }) { notebook.cells[index].outputs = live.outputs }
        }
    }

    /// Writes a cell's gathered outputs to its notebook for good, with `edit` (its count and time): in memory and saved
    /// soon for the open book, loaded, changed and saved once for a notebook of a book in another tab.
    private func finishLiveOutput(_ session: LabSession, cellID: UUID, _ edit: ((inout LabCell) -> Void)? = nil) {
        let live = session.live?.cellID == cellID ? session.live : nil
        session.live = nil
        var replaced: [String] = []
        updateLab(session.notebookID, workspaceID: session.workspaceID) { notebook in
            guard let index = notebook.cells.firstIndex(where: { $0.id == cellID }) else { return }
            if let live {
                let kept = Set(live.outputs.compactMap(\.imageName))
                replaced = notebook.cells[index].outputs.compactMap(\.imageName).filter { !kept.contains($0) }
                notebook.cells[index].outputs = live.outputs
            }
            edit?(&notebook.cells[index])
        }
        if !replaced.isEmpty { removeLabImages(named: replaced, workspaceID: session.workspaceID) }
    }

    private func handleLab(_ event: LabKernelEvent, session: LabSession) {
        let notebookID = session.notebookID
        switch event {
        case let .ready(python, _, packages):
            session.python = python; session.packages = packages
            session.state = .idle
            if packages["numpy"] == nil {
                let numpy = "This Python has no NumPy: set up Lemma's own Python, or choose another in Settings › Lab."
                session.show([session.message, numpy].compactMap { $0 }.joined(separator: " "), offeringSetup: true)
            }
            dispatchLab(session)
        case let .stream(request, name, text):
            output(session, request) { LabOutput.append(text, stream: name == "stderr" ? .stderr : .stdout, to: &$0) }
        case let .log(text):
            guard session.runningCellID != nil else { return }
            output(session, nil) { LabOutput.append(text, stream: .stderr, to: &$0) }
        case .image:
            // Figures arrive already saved, as `LabDelivery.figure`.
            break
        case let .result(request, text):
            output(session, request) { $0.append(LabOutput(kind: .result, text: text)) }
        case let .error(request, name, value, traceback):
            output(session, request) { $0.append(LabOutput(kind: .error, text: value.isEmpty ? name : "\(name): \(value)", detail: traceback.isEmpty ? nil : traceback)) }
        case let .done(request, status, count, duration):
            if let id = cellID(request, in: session), session.consoleIDs.contains(id) {
                editConsole(notebookID, entry: id) { $0.count = count }
                session.consoleIDs.remove(id)
            } else if let id = cellID(request, in: session) {
                finishLiveOutput(session, cellID: id) { cell in cell.executionCount = count; cell.lastRunAt = .now; cell.duration = duration }
            }
            if let request { session.requests[request] = nil }
            session.runningCellID = nil
            session.state = .idle
            session.interruptedAt = nil
            if status != "ok" { session.queued.removeAll() }
            if status == "interrupted" { session.show("Interrupted.", transient: true) } else if session.messageIsTransient { session.show(nil) }
            dispatchLab(session)
            if session.workspaceID == workspace?.id { scheduleSave() }
        case let .completions(request, _, matches):
            if let request { session.completionWaiters.removeValue(forKey: request)?.resume(returning: matches) }
        case let .exited(code):
            session.cancelWaiters()
            if let running = session.runningCellID {
                let note = LabOutput(kind: .error, text: "Python stopped (exit status \(code))")
                if session.consoleIDs.contains(running) {
                    editConsole(notebookID, entry: running) { $0.outputs.append(note) }
                } else if session.live?.cellID == running {
                    session.live?.outputs.append(note)
                    finishLiveOutput(session, cellID: running)
                } else {
                    updateLab(notebookID, workspaceID: session.workspaceID) { notebook in
                        if let index = notebook.cells.firstIndex(where: { $0.id == running }) { notebook.cells[index].outputs.append(note) }
                    }
                }
            }
            session.kernel = nil
            session.live = nil
            session.runningCellID = nil
            session.queued.removeAll()
            session.consoleIDs.removeAll()
            session.state = .stopped
            if code != 0 && code != 15 && code != 2 { session.show("Python stopped unexpectedly (exit status \(code)). Run a cell to start it again.") }
        }
    }

    // MARK: Console

    /// The session the console talks to: the open notebook's Python, or the book's scratch session.
    var consoleTarget: UUID? {
        guard let workspace else { return nil }
        if let id = openLabID, lab(id) != nil { return id }
        return lab.scratchID(for: workspace.id)
    }

    /// Runs a line or block in the console's session, after any cells already queued there.
    func runConsole(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workspace, let sessionID = consoleTarget, !trimmed.isEmpty else { return }
        var session = lab.sessions[sessionID] ?? LabSession(notebookID: sessionID, workspaceID: workspace.id)
        lab.sessions[sessionID] = session
        session.show(nil)
        let fresh = restartIfInterpreterChanged(session)
        if fresh !== session {
            session = fresh
            let note = "Now using Python \(lab.interpreter?.version ?? "another version"); variables were cleared."
            lab.consoles[sessionID, default: []].append(ConsoleEntry(id: UUID(), code: "", outputs: [LabOutput(kind: .stdout, text: note)]))
        }
        let entry = ConsoleEntry(id: UUID(), code: code.trimmingCharacters(in: .newlines))
        lab.consoles[sessionID, default: []].append(entry)
        if lab.history.last != entry.code { lab.history.append(entry.code) }
        session.consoleIDs.insert(entry.id)
        session.queued.append(entry.id)
        startLabKernelIfNeeded(session)
        dispatchLab(session)
    }

    /// Console input: as in Python 3.13's REPL, `clear` and `exit` are console commands rather than Python.
    func submitConsole(_ code: String) {
        let command = code.trimmingCharacters(in: .whitespacesAndNewlines)
        switch command {
        case "clear", "clear()", "cls":
            if lab.history.last != command { lab.history.append(command) }
            clearConsole()
        case "exit", "exit()", "quit", "quit()":
            if lab.history.last != command { lab.history.append(command) }
            endConsoleSession(echo: command)
        default:
            runConsole(code)
        }
    }

    /// `exit()` in the console: Python stops and its variables go; the next command starts a fresh session.
    func endConsoleSession(echo: String?) {
        guard let sessionID = consoleTarget else { return }
        let shared = openLab != nil
        stopLabKernel(sessionID)
        let note = shared
            ? "Python stopped; the notebook's variables were cleared. The next command starts a new session."
            : "Python stopped; variables were cleared. The next command starts a new session."
        lab.consoles[sessionID, default: []].append(ConsoleEntry(id: UUID(), code: echo ?? "", outputs: [LabOutput(kind: .stdout, text: note)]))
    }

    func clearConsole() {
        guard let sessionID = consoleTarget, let workspace else { return }
        for name in (lab.consoles[sessionID] ?? []).flatMap(\.outputs).compactMap(\.imageName) {
            try? FileManager.default.removeItem(at: repository.assetURL(workspaceID: workspace.id, name: name))
        }
        lab.consoles[sessionID] = []
    }

    private func editConsole(_ sessionID: UUID, entry entryID: UUID, _ change: (inout ConsoleEntry) -> Void) {
        guard let index = lab.consoles[sessionID]?.firstIndex(where: { $0.id == entryID }) else { return }
        change(&lab.consoles[sessionID]![index])
    }

    // MARK: Figures in the margin

    /// Pins a figure made in the Lab beside the passage its notebook came from, as a margin note with the image.
    /// The figure is copied, so clearing the notebook's outputs keeps it.
    func pinLabFigure(_ imageName: String, notebookID: UUID) {
        guard let workspace, let notebook = lab(notebookID) else { return }
        let pageIndex = notebook.source?.pageIndex ?? (reader.pageNumber - 1)
        guard let page = document?.page(at: pageIndex) else { return }
        do {
            let figure = "figure-\(UUID().uuidString).png"
            try FileManager.default.copyItem(at: repository.assetURL(workspaceID: workspace.id, name: imageName),
                                             to: repository.assetURL(workspaceID: workspace.id, name: figure))
            // Beside the source passage, or the top of the page when the notebook has no region.
            let box = page.bounds(for: .cropBox)
            let region = notebook.source?.region.flatMap { $0.width < box.width * 0.95 || $0.height < box.height * 0.9 ? $0 : nil }
                ?? PageRegion(x: box.minX + 72, y: box.maxY - 120, width: box.width - 144, height: 40)
            let crop = try PDFRegionRenderer.png(page: page, region: region)
            let name = "\(UUID().uuidString).png"
            try repository.saveImage(crop, workspaceID: workspace.id, name: name)
            let anchor = SourceAnchor(pageIndex: pageIndex, pageLabel: printedLabel(for: pageIndex) ?? page.label ?? String(pageIndex + 1),
                                      region: region, quote: notebook.source?.quote ?? "", imageName: name)
            var note = StudyNote(anchor: anchor, question: notebook.title, body: "Figure from the Lab notebook “\(notebook.title)”.", kind: .comment)
            note.figureName = figure
            self.workspace?.notes.insert(note, at: 0)
            if let bookID = self.workspace?.id { registerNoteCreationUndo(note, bookID: bookID) }
            flush()
            if !saveFailed { status = "Figure pinned beside \(shortPageText(pageIndex)). It shows as a card in the margin of a wide window." }
        } catch { self.error = "Could not pin the figure: \(error.localizedDescription)" }
    }

    // MARK: Completion

    /// Completions for a dotted name: from the running kernel's namespace when Python is idle, otherwise keywords and built-ins.
    func labCompletions(_ notebookID: UUID, prefix: String) async -> [String] {
        let local = PythonSyntax.staticCompletions(prefix)
        guard let session = lab.sessions[notebookID], session.state == .idle, let kernel = session.kernel else { return local }
        let id = UUID()
        let matches: [String] = await withCheckedContinuation { continuation in
            session.completionWaiters[id] = continuation
            kernel.complete(id: id, text: prefix)
            Task { @MainActor [weak session] in
                try? await Task.sleep(for: .milliseconds(1500))
                session?.completionWaiters.removeValue(forKey: id)?.resume(returning: [])
            }
        }
        return matches.isEmpty ? local : matches
    }

    // MARK: Export

    /// Exports a notebook as .ipynb and, when the panel's checkbox is on (it remembers), its code as a .py beside it.
    /// The panel asks before replacing the notebook file; an existing script is another file, so Lemma asks too.
    func exportLab(_ notebookID: UUID) {
        guard let workspace, let notebook = lab(notebookID) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "ipynb") ?? .json]
        panel.nameFieldStringValue = LabExport.fileName(for: notebook, extension: "ipynb")
        panel.message = "Export this notebook for Jupyter or VS Code, with its outputs."
        let scriptBox = NSButton(checkboxWithTitle: "Also save the code as a Python script (.py) beside it", target: nil, action: nil)
        scriptBox.state = (UserDefaults.standard.object(forKey: LabPreferences.exportScript) as? Bool ?? true) ? .on : .off
        scriptBox.sizeToFit()
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: scriptBox.frame.width + 40, height: scriptBox.frame.height + 20))
        scriptBox.setFrameOrigin(NSPoint(x: 20, y: 10))
        accessory.addSubview(scriptBox)
        panel.accessoryView = accessory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var script = scriptBox.state == .on
        UserDefaults.standard.set(script, forKey: LabPreferences.exportScript)
        let scriptURL = LabExport.scriptURL(beside: url)
        if script, FileManager.default.fileExists(atPath: scriptURL.path) {
            let alert = NSAlert()
            alert.messageText = "“\(scriptURL.lastPathComponent)” already exists"
            alert.informativeText = "Replace it with this notebook's code, or keep it and export only the notebook."
            alert.addButton(withTitle: "Keep the Script")
            alert.addButton(withTitle: "Replace").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: script = false
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        do {
            try LabExport.write(notebook, to: url, bookTitle: workspace.title, python: lab.session(notebookID)?.python ?? lab.interpreter?.version,
                                script: script) { [repository] name in
                try? Data(contentsOf: repository.assetURL(workspaceID: workspace.id, name: name))
            }
            status = script ? "Notebook exported as .ipynb and .py." : "Notebook exported as .ipynb."
        } catch { self.error = "Could not export the notebook: \(error.localizedDescription)" }
    }

    /// Saves a figure from a cell or the console where the reader chooses, under a name that says where it came from.
    func saveLabFigure(_ imageName: String, notebookID: UUID?) {
        guard let workspace else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = notebookID.flatMap { lab($0) }.map { LabExport.figureFileName(for: $0, imageName: imageName) } ?? "Console figure.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // The panel has already asked before replacing a file; the atomic write then replaces it in one step.
            try Data(contentsOf: repository.assetURL(workspaceID: workspace.id, name: imageName)).write(to: url, options: .atomic)
            status = "Figure saved as \(url.lastPathComponent)."
        } catch { self.error = "Could not save the figure: \(error.localizedDescription)" }
    }
}
