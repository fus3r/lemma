import AppKit
import PDFKit
import UniformTypeIdentifiers
import LemmaCore
import Observation

@MainActor @Observable
final class StudyStore {
    let app: AppModel
    let windowID: UUID
    @ObservationIgnored var hasWindow = false
    @ObservationIgnored var windowRequested = false
    @ObservationIgnored var windowFrame: CGRect?
    @ObservationIgnored let fallbackUndoManager: UndoManager = { let manager = UndoManager(); manager.groupsByEvent = false; return manager }()
    @ObservationIgnored let find = FindController()
    @ObservationIgnored let titleBar = TitleBarCoordinator()
    let repository: WorkspaceRepository
    let mailbox: BrowserMailbox
    let questions: QuestionRuntime
    @ObservationIgnored let covers: LibraryCovers
    let libraries: DynamicLibraries
    /// The Library tree's selection, keyboard cursor, names being typed and drag feedback.
    @ObservationIgnored let libraryTree = LibraryTreeState()
    var showLibrarySources = false
    var showHighlightColors = false
    var showNewFile = false
    var addHighlightColor = false
    var showAcknowledgements = false
    var reader = ReaderController()
    var library: [StudyWorkspace] {
        get { app.library }
        set { app.library = newValue }
        _modify { yield &app.library }
    }
    private var workspaceBuffer: WorkspaceBuffer?
    private var windowReading: ReadingState?
    var workspace: StudyWorkspace? {
        get {
            guard var book = workspaceBuffer?.book else { return nil }
            if let windowReading { book.reading = windowReading }
            return book
        }
        set {
            guard let book = newValue else { workspaceBuffer = nil; windowReading = nil; return }
            let buffer = app.buffer(for: book)
            var content = book
            // Scrolling one window must neither move another window nor redraw its notebook.
            content.reading = buffer.book.reading
            if buffer.book != content { buffer.book = content }
            if workspaceBuffer !== buffer { workspaceBuffer = buffer }
            if windowReading != book.reading { windowReading = book.reading }
        }
    }
    /// Multi-book research and the durable editor session live alongside the per-PDF workspaces.
    var projects: [ResearchProject] {
        get { app.projects }
        set { app.projects = newValue }
        _modify { yield &app.projects }
    }
    var selectedProjectID: UUID?
    var projectQuery = ""
    var showCustomization = false
    /// Editors that are not books, open as tabs in the main editor group (Welcome, Settings, Keyboard Shortcuts…).
    var specialTabs: [SpecialEditor] = []
    /// The special editor in front of the book, if any.
    var activeSpecial: SpecialEditor? {
        didSet { if activeSpecial != nil { activeFileName = nil } }
    }
    var fileTabs: [String] = []
    var activeFileName: String?
    /// Page miniatures beside the page, as an editor's minimap.
    var showMinimap = UserDefaults.standard.object(forKey: "editor.minimap.enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showMinimap, forKey: "editor.minimap.enabled") }
    }
    /// The toast under the pointer, which stays until the pointer leaves it.
    @ObservationIgnored var hoveredToast: UUID?
    /// Regions of pages drawn as images (the debugger's goal), kept while they are shown again and again.
    @ObservationIgnored let regionImages: NSCache<NSString, NSImage> = { let cache = NSCache<NSString, NSImage>(); cache.countLimit = 24; return cache }()
    /// Opens SwiftUI's Settings window (the Classic style's settings), set by the window that can open it.
    @ObservationIgnored var openSettingsScene: (() -> Void)?
    /// The minimap's slider all the time, or only under the pointer as VS Code does by default.
    var minimapSliderAlways = UserDefaults.standard.string(forKey: "editor.minimap.showSlider") == "always" {
        didSet { UserDefaults.standard.set(minimapSliderAlways ? "always" : "mouseover", forKey: "editor.minimap.showSlider") }
    }
    /// Toasts at the bottom right and the notification center, as an editor's notifications.
    var notifications: [LemmaNotification] = []
    var showNotificationCenter = false
    /// The proof being stepped through in Run and Debug.
    var debug: ProofDebugSession?
    /// Which panes of the side bar views are open (“OUTLINE”, “TIMELINE”…).
    var paneExpanded: [String: Bool] = (UserDefaults.standard.dictionary(forKey: "workbench.panes") as? [String: Bool]) ?? [:] {
        didSet {
            if windowID == AppModel.primaryWindowID { UserDefaults.standard.set(paneExpanded, forKey: "workbench.panes") }
            if restored { saveWorkbench() }
        }
    }
    /// The panel fills the editor area (VS Code's Maximize Panel Size).
    var panelMaximized = false
    /// What's New, as a sheet in the Classic style.
    var showReleaseNotes = false
    /// Full-text search across the library (the VS Code style's Search view).
    var librarySearch: LibraryTextSearch { app.librarySearch }
    /// Outline entries the reader opened; the path to the reading position opens by itself while `outlineFollows`.
    var outlineExpanded: Set<String> = []
    /// Lines the reader marked to stop at while debugging a proof (F9), in this book.
    var breakpoints: [LineBreakpoint] = [] { didSet { reader.breakpoints = breakpoints } }
    /// Expressions kept in Run and Debug's Watch pane, in this book.
    var watchExpressions: [String] = []
    var outlineFollows = true
    /// Documents of other books shown in side editors, by fingerprint.
    @ObservationIgnored var sideDocuments: [String: PDFDocument] = [:]
    var mainPDFDropDestination: EditorDropDestination?
    var sidePDFDropDestination: EditorDropDestination?
    var formulaRequest: FormulaRequest?
    var workbenchLayout = WorkbenchLayout()
    @ObservationIgnored var workbench = WorkbenchSession()
    @ObservationIgnored var hasSavedSession = false
    @ObservationIgnored var sessionWritable = true
    var projectsWritable: Bool { app.projectsWritable }
    var projectsDirty: Bool { get { app.projectsDirty } set { app.projectsDirty = newValue } }
    var projectSaveTask: Task<Void, Never>? { get { app.projectSaveTask } set { app.projectSaveTask = newValue } }
    var document: PDFDocument?
    var selectedNoteID: UUID?
    var error: String?
    /// A message in the status bar; it fades after a few seconds, as VS Code's status messages do.
    var status = "" {
        didSet {
            guard !status.isEmpty, status != oldValue else { return }
            let shown = status
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                MainActor.assumeIsolated { if self?.status == shown { self?.status = "" } }
            }
        }
    }
    var browserStatus = ""
    var showLibrary = true
    var showStudy = true
    var showBrowserSetup = false
    var showQuestion = false
    var showDependencyMap = false
    var showShortcuts = false
    /// IDE workbench: the bottom panel, the command palette, the secondary editor and open book tabs.
    var showPanel = false
    var panelTab: PanelTab = .references
    var referencesQuery: ReferencesQuery?
    var palette: PaletteRequest? {
        // However the theme picker goes away (Escape, ⌘, another palette, a tab), the theme it was previewing goes too.
        didSet { if oldValue?.mode == .themes, palette?.mode != .themes { ThemeManager.shared.preview(nil) } }
    }
    /// The side editor group beside the reader: pages of the book, notebooks, maps and derivations, as tabs.
    var sideEditors: [SideEditor] = [] { didSet { trimSideDocuments() } }
    var activeSideEditorID: String?
    /// The latest check of each derivation, refreshed as it is edited.
    var derivationReports: [UUID: DerivationReport] = [:]
    @ObservationIgnored var derivationChecks: [UUID: Task<Void, Never>] = [:]
    /// A request to move the caret of a derivation's editor to a line (from the Problems panel).
    var derivationFocus: (id: UUID, line: Int, token: UUID)?
    /// Bumped when the page theme changes, so views drawn over the page refresh.
    var pageThemeRevision = 0
    /// Books, papers and cited works the reader asked to download.
    let downloads: PDFDownloads
    var catalogMode = CatalogMode.books
    var arxivQuery = ""
    var arxivSort = ArxivSort.relevance
    var arxivResults: [ArxivPaper] = []
    var arxivPage: ArxivSearchPage?
    var arxivSearching = false
    var arxivSearchError: String?
    @ObservationIgnored var arxivSearchTask: Task<Void, Never>?
    @ObservationIgnored var arxivSubmittedQuery = ""
    @ObservationIgnored var arxivSubmittedSort = ArxivSort.relevance
    @ObservationIgnored var arxivImports = Set<String>()
    /// Searches for cited works, by bibliography entry.
    var paperLookups: [Int: PaperLookupState] = [:]
    @ObservationIgnored private var windowFitted = false

    /// A window restored larger than the screen, or partly off it, is brought back inside the visible frame once.
    func fitWindowToScreen() {
        guard !windowFitted, let window = mainWindow, let screen = window.screen ?? NSScreen.main else { return }
        windowFitted = true
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        if frame != window.frame { window.setFrame(frame, display: true, animate: false) }
    }
    /// The object whose uses and users the Hierarchy panel shows, and which way it looks.
    var hierarchyKey: ReferenceKey?
    var hierarchyDirection: HierarchyDirection = .uses
    /// The statement under the reading position, computed once per position (the breadcrumb and header both ask).
    @ObservationIgnored var readingStatementCache: (key: String, value: ReadingStatement?)?
    @ObservationIgnored var pageTextMaps: [String: PageTextMap] = [:]
    /// Terms and index entries of the other books in the library, for Look Up across books.
    @ObservationIgnored let libraryGlossary: LibraryGlossary
    /// Python notebooks: interpreters and one kernel per running notebook.
    @ObservationIgnored let lab: LabRuntime
    /// Set when opening a notebook hid the inspector to make room; closing the notebook shows it again.
    @ObservationIgnored var labHidInspector = false
    /// Reading time per page and day, while the reader window is in use.
    @ObservationIgnored private(set) var tracker: ReadingTracker?
    var tabs: [BookTab] = []
    var analysis: BookAnalysisModel?
    @ObservationIgnored var documents: [String: PDFDocument] = [:]
    @ObservationIgnored var referenceIndexes: [String: ReferenceIndex] = [:]
    @ObservationIgnored var analyses: [String: BookAnalysisModel] = [:]
    /// The reader window, so ⌘W closes a book there and a window elsewhere.
    @ObservationIgnored weak var mainWindow: NSWindow?
    var navigatorSection: NavigatorSection = .contents
    var studySection: StudySection = .notes
    var libraryQuery = ""
    var noteQuery = ""
    var noteFilter: NoteFilter = .all
    var libraryNoteQuery = ""
    var noteSearchByMeaning = false
    var noteSearchScope: PageSearchScope = .library
    var noteMeaningHits: [NoteSearchHit] = []
    var isSearchingNoteMeaning = false
    var noteSemanticAvailable = false
    @ObservationIgnored var noteMeaningTask: Task<Void, Never>?
    var searchNotes = false
    var searchIndexed = false
    var pageSearchScope: PageSearchScope = .current
    var pageSearchQuery = ""
    var searchByMeaning = false
    var pageSearchResults: [PassageSearchResult] = []
    var isSearchingPages = false
    var semanticSearchAvailable = false
    var indexProgress: IndexProgress?
    var isLaunchingIndex = false
    var indexedWorkspaceID: String?
    @ObservationIgnored var pageSearchTask: Task<Void, Never>?
    var outline: [OutlineEntry] = []
    var focusMode = false
    var isSaving = false
    var saveFailed = false
    var lastExportURL: URL?
    var ocrCapture: OCRCapture?
    var definitionLookup: DefinitionLookupRequest? {
        didSet { if definitionLookup == nil { reader.view?.dismissDefinitionLookup() } }
    }
    var referencePeek: ReferencePeekRequest? {
        didSet { if referencePeek == nil { reader.view?.dismissReferencePeek() } }
    }
    @ObservationIgnored var references: ReferenceIndex?
    var quickAsk: QuickAskRequest? {
        didSet { if quickAsk == nil { reader.view?.dismissQuickAsk() } }
    }
    @ObservationIgnored var questionPreset: QuestionPreset?
    /// Replaces opening Chrome, for tests and previews.
    @ObservationIgnored var urlOpener: ((URL) -> Void)?
    /// PDFs the system asked Lemma to open before the last session was restored; opened right after it.
    @ObservationIgnored var pendingFileOpens: [URL] = []
    @ObservationIgnored private(set) var restored = false
    /// Set once restore() has begun: reopening the window from the Dock runs the window's onAppear again.
    @ObservationIgnored var restoreStarted = false
    private var previousPanels: (Bool, Bool, Bool)?
    @ObservationIgnored var accessedSources: [String: URL] = [:]
    private var lastResults: [UUID: String] = [:]
    /// Fingerprints of PDFs already read, by file, so opening a known and unchanged file reads none of its bytes.
    @ObservationIgnored let fingerprints: FingerprintCache
    /// A PDF whose fingerprint is being read off the main thread (large, remote or in the cloud), shown in the status bar.
    var openingFile: OpeningFile?
    /// Files up to this size are hashed at once when unknown; tests lower it to exercise the background path.
    @ObservationIgnored var immediateHashLimit = SourceFingerprint.immediateLimit
    /// The one timer behind debounced saves (typing, scrolling): moved, never recreated, while edits keep coming.
    @ObservationIgnored let saveTimer = SaveTimer()
    /// The version of the book in front last handed to the writer: what changed since decides what is written.
    @ObservationIgnored var savedSnapshot: StudyWorkspace?
    /// Saves finished on the writer's queue, collected for the main actor.
    @ObservationIgnored let saveOutcomes = SaveOutcomes()
    @ObservationIgnored var contentSavesInFlight = 0
    /// The editor session as last written, so an unchanged session is not written again.
    @ObservationIgnored var lastSessionData: Data?
    /// workbench.json stays pretty-printed: it is small and people read it.
    @ObservationIgnored let sessionEncoder: JSONEncoder = { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder }()
    /// Saved books that could not be read at launch: their files are kept, and their tabs stay in the saved session.
    var unreadableWorkspaces: [WorkspaceLoadFailure] { app.unreadableWorkspaces }
    @ObservationIgnored var preservedTabIDs: [String] = []
    /// Passwords of locked PDFs opened in this session, by fingerprint; never written anywhere.
    var passwords: [String: String] { get { app.passwords } set { app.passwords = newValue } }
    /// Books opened with a password: the analysis helper cannot read them, so they are not sent to it.
    var lockedFingerprints: Set<String> { get { app.lockedFingerprints } set { app.lockedFingerprints = newValue } }
    /// Replaces the password dialog, for tests: the file's name and whether a password was just refused.
    @ObservationIgnored var passwordPrompt: ((String, Bool) -> String?)?
    /// Open tabs' documents, least recently shown first: only the book in front and a few others stay in memory.
    @ObservationIgnored var recentDocuments: [String] = []
    /// Each document's outline, walked once (reference resolution, the analysis and the Outline view share it).
    @ObservationIgnored var outlineCache: [String: OutlineCacheEntry] = [:]
    /// Source crops and figures shown in the notebook, decoded once.
    @ObservationIgnored let assetImages: NSCache<NSString, NSImage> = { let cache = NSCache<NSString, NSImage>(); cache.countLimit = 64; return cache }()
    /// Counts derived from saved explanations (steps to check, code blocks), by note, while the text is unchanged.
    @ObservationIgnored var explanationSummaries: [UUID: ExplanationSummary] = [:]
    @ObservationIgnored var terminating = false

    convenience init(root supportRoot: URL? = nil) { self.init(app: AppModel(root: supportRoot)) }

    init(app: AppModel, windowID: UUID = AppModel.primaryWindowID) {
        self.app = app; self.windowID = windowID
        repository = app.repository; mailbox = app.mailbox; questions = app.questions
        covers = app.covers; fingerprints = app.fingerprints; libraries = app.libraries
        lab = app.lab; downloads = app.downloads; libraryGlossary = app.libraryGlossary
        sessionWritable = app.libraryReadable
        error = app.startupError
        // Only the original window reads the legacy openTabs/lastWorkspaceID defaults. Every new window starts empty.
        hasSavedSession = windowID != AppModel.primaryWindowID
        if FileManager.default.fileExists(atPath: sessionURL.path) {
            do {
                let data = try Data(contentsOf: sessionURL)
                workbench = try JSONDecoder().decode(WorkbenchSession.self, from: data); hasSavedSession = true
                lastSessionData = data
            }
            catch { sessionWritable = false; self.error = "Could not restore the editor session. Its saved file has been kept: \(error.localizedDescription)" }
        }
        // The earlier one-book list could be only one row tall. Make the new collection tree visible once,
        // when its sources are first installed; subsequent user resizing remains fully persistent.
        if app.newLibrarySources, libraries.collections.count > 1,
           (workbench.layout.explorerHeights?[ExplorerPane.library.id] ?? 220) < 120 {
            var heights = workbench.layout.explorerHeights ?? [:]
            heights[ExplorerPane.library.id] = 220
            workbench.layout.explorerHeights = heights
        }
        reader.onReadingChanged = { [weak self] page, scale in
            guard let self, self.workspace != nil else { return }
            let moved = self.workspace?.reading.pageIndex != page
            // Bounds notifications arrive throughout a scroll. Reassigning the workspace even when its
            // page and zoom are unchanged invalidates the notebook, explorer and PDF surface on every tick.
            if moved { self.workspace?.reading.pageIndex = page }
            if self.workspace?.reading.scale != scale { self.workspace?.reading.scale = scale }
            // The exact viewport still needs saving, including scrolling within the same page: a few hundred bytes,
            // written once scrolling pauses.
            self.scheduleViewportSave()
            if moved, !self.reader.isScrubbing, self.reader.showReferenceLinks { self.references?.prefetch(around: page) }
        }
        reader.onLayoutChanged = { [weak self] layout in
            // Applying the book's own layout reports it too: only another one is saved.
            guard let self, self.workspace != nil, (self.workspace?.reading.layout ?? .standard) != layout else { return }
            self.updateLayout(layout)
        }
        saveTimer.action = { [weak self] in self?.save(wait: false) }
        reader.onSelectNote = { [weak self] id in self?.selectNote(id) }
        reader.onInk = { [weak self] stroke in self?.addInk(stroke, undoManager: self?.pdfUndoManager) }
        reader.onEraseInk = { [weak self] id in self?.removeInk(id: id, undoManager: self?.pdfUndoManager) }
        reader.onLookup = { [weak self] page, region, text in self?.lookupDefinition(text, pageIndex: page, region: region) }
        reader.onReference = { [weak self] mention, page, keep in self?.peekReference(mention, pageIndex: page, keep: keep) }
        reader.onReferenceToSide = { [weak self] mention, page in self?.openReferenceToSide(mention, pageIndex: page) }
        reader.onContextAction = { [weak self] action in self?.perform(action) }
        reader.onShowReferences = { [weak self] key in self?.showReferences(.object(key)) }
        reader.onMarginNote = { [weak self] page, region, quote in self?.addMarginNote(pageIndex: page, region: region, quote: quote) }
        reader.onEditMarginNote = { [weak self] id in self?.editMarginNote(id) }
        reader.onToggleProof = { [weak self] id in self?.toggleProof(id) }
        reader.onSelectStatement = { [weak self] key in self?.showHierarchy(key) }
        reader.showReferenceCounts = UserDefaults.standard.object(forKey: LemmaPreferences.referenceCounts) as? Bool ?? true
        reader.showReferenceLinks = UserDefaults.standard.object(forKey: LemmaPreferences.referenceLinks) as? Bool ?? true
        tracker = ReadingTracker(store: self)
        reader.owner = self
        reader.figureImage = { [weak self] name in
            guard let self, let workspace = self.workspace else { return nil }
            return self.lab.image(named: name, workspaceID: workspace.id, repository: self.repository)
        }
        app.register(self)
    }

    var currentNote: StudyNote? { workspace?.notes.first { $0.id == selectedNoteID } }
    var currentImage: NSImage? {
        guard let workspace, let note = currentNote else { return nil }
        return assetImage(workspaceID: workspace.id, name: note.anchor.imageName)
    }

    func choosePDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a book or paper to study."
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL, toSide: Bool = false) { openFile(url, toSide: toSide) }

    /// Opens a PDF in front, or beside the reader. Its identity (the SHA-256 of its bytes) comes from the fingerprint cache
    /// when the file is known and unchanged, is read at once for a small local file, and otherwise off the main thread
    /// while the status bar says so (a long book, a network volume, a file in iCloud Drive). `then` runs once the book is
    /// in front (true) or could not be opened (false); a request replaced by a newer one runs neither.
    @discardableResult
    func openFile(_ url: URL, toSide: Bool = false, quiet: Bool = false, then: ((Bool) -> Void)? = nil) -> OpenOutcome {
        flush()
        if let pending = openingFile { openingFile = nil; pending.cancel() }
        let scoped = url.startAccessingSecurityScopedResource()
        guard let stamp = FileStamp(url) else {
            // Moved, deleted, on a disk that is not connected: said at once, so closing a tab can try the next one.
            let missing = !FileManager.default.fileExists(atPath: url.path)
            return failOpen(url, CocoaError(missing ? .fileReadNoSuchFile : .fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path]),
                            scoped: scoped, quiet: quiet, then: then)
        }
        if let known = fingerprints.fingerprint(for: stamp) {
            return finishOpen(url, fingerprint: known, scoped: scoped, toSide: toSide, quiet: quiet, then: then)
        }
        guard SourceFingerprint.wantsBackground(url, limit: immediateHashLimit) else {
            do {
                let read = try SourceFingerprint.read(url, coordinated: false)
                if let stamp = read.stamp { fingerprints.record(read.fingerprint, for: stamp) }
                return finishOpen(url, fingerprint: read.fingerprint, scoped: scoped, toSide: toSide, quiet: quiet, then: then)
            } catch { return failOpen(url, error, scoped: scoped, quiet: quiet, then: then) }
        }
        let opening = OpeningFile(url: url)
        openingFile = opening
        status = opening.message
        opening.reminder = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled, self.openingFile === opening else { return }
                self.status = opening.message
            }
        }
        let fingerprints = fingerprints
        opening.task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, any Error> in
                Result {
                    let read = try SourceFingerprint.read(url, coordinated: true)
                    if let stamp = read.stamp { fingerprints.record(read.fingerprint, for: stamp) }
                    return read.fingerprint
                }
            }.value
            opening.reminder?.cancel()
            guard let self, self.openingFile === opening else {
                if scoped { url.stopAccessingSecurityScopedResource() }
                return
            }
            self.openingFile = nil
            if self.status.hasPrefix("Opening “\(opening.title)”") { self.status = "" }
            switch result {
            case let .success(fingerprint): self.finishOpen(url, fingerprint: fingerprint, scoped: scoped, toSide: toSide, quiet: quiet, then: then)
            case let .failure(error): self.failOpen(url, error, scoped: scoped, quiet: quiet, then: then)
            }
        }
        return .pending
    }

    /// Opens a PDF whose fingerprint is known: its workspace (or a new one), its document (shared with any other view of
    /// the same bytes), a password when it is locked.
    @discardableResult
    private func finishOpen(_ url: URL, fingerprint: String, scoped: Bool, toSide: Bool, quiet: Bool, then: ((Bool) -> Void)?) -> OpenOutcome {
        do {
            // The workspace named by these bytes, or one that follows them since its PDF changed on disk.
            let id = library.first(where: { $0.id == fingerprint })?.id ?? library.first(where: { $0.fingerprint == fingerprint })?.id ?? fingerprint
            let pdf: PDFDocument
            if let cached = documents[id] ?? sideDocuments[id] {
                // The same bytes are open already, perhaps from another path: one document, so its reference index,
                // which holds the document weakly, keeps working.
                pdf = cached
            } else {
                guard let loaded = PDFDocument(url: url) else { throw CocoaError(.fileReadCorruptFile) }
                // Pages draw themselves in the reader's theme; the delegate must be set before any page is read.
                loaded.delegate = ThemedPageProvider.shared
                if loaded.isLocked {
                    guard unlock(loaded, fingerprint: fingerprint, name: url.lastPathComponent) else {
                        if scoped { url.stopAccessingSecurityScopedResource() }
                        status = "“\(url.lastPathComponent)” needs its password to open."
                        then?(false)
                        return .failed
                    }
                    lockedFingerprints.insert(fingerprint)
                }
                guard loaded.pageCount > 0 else { throw CocoaError(.fileReadCorruptFile) }
                pdf = loaded
            }
            let current = self.workspace?.id == id ? self.workspace : app.currentWorkspace(id)
            // An unreadable workspace file throws here rather than being replaced by an empty one.
            var onDisk = self.workspace?.id != id ? try repository.load(id: id) : savedSnapshot
            var carried: (pages: Int?, title: String)?
            var workspace: StudyWorkspace
            if let current { workspace = current }
            else if let onDisk { workspace = onDisk }
            else if let previous = try carryOverCandidate(for: url, fingerprint: fingerprint) {
                // The PDF changed on disk (annotated in another app, downloaded again, synced): the notes follow it under
                // their id, which projects, links and tabs name; what was made from the old bytes is made again.
                workspace = previous.workspace
                onDisk = previous.onDisk
                carried = (previous.workspace.pageCount, previous.workspace.title)
                workspace.fingerprint = fingerprint
                forgetDerivedData(workspace.id)
            } else {
                workspace = StudyWorkspace(
                    id: fingerprint,
                    // A name given in the Library before the PDF was first opened becomes the book's title; then the
                    // PDF's own title when it is a real one ("Attention Is All You Need" for 1706.03762v7.pdf); then the file name.
                    title: libraries.titles[LibraryPaths.key(url.path)]
                        ?? DocumentTitle.fromMetadata(pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, fileName: url.lastPathComponent)
                        ?? url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " "),
                    sourcePath: url.path, sourceBookmark: nil, fingerprint: fingerprint)
            }
            if workspace.sourcePath != url.path { workspace.sourcePath = url.path }
            // The bookmark must follow the file actually opened; an older one could reopen a stale copy.
            if !bookmark(workspace.sourceBookmark, leadsTo: url),
               let bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                workspace.sourceBookmark = bookmark
            }
            workspace.lastOpenedAt = .now
            if workspace.pageCount != pdf.pageCount { workspace.pageCount = pdf.pageCount }
            if scoped {
                if pdf.documentURL?.standardizedFileURL == url.standardizedFileURL {
                    accessedSources[workspace.id]?.stopAccessingSecurityScopedResource()
                    accessedSources[workspace.id] = url
                } else { url.stopAccessingSecurityScopedResource() }
            }
            if toSide, let front = self.workspace {
                // Opening a discovered PDF beside the reader must not switch books or reset the notebook.
                if front.id == workspace.id { self.workspace = workspace }
                else {
                    var snapshot = workspace; snapshot.schemaVersion = 10
                    repository.saveLater(snapshot, completion: saveCompletion(for: workspace.id))
                    contentSavesInFlight += 1
                    library.removeAll { $0.id == workspace.id }
                    library.insert(workspace, at: 0)
                    sideDocuments[workspace.id] = pdf
                }
                openBookToTheSide(workspace.id)
            } else {
                present(workspace, document: pdf, onDisk: onDisk)
            }
            libraries.watchWorkspace(url.path)
            if let carried {
                if let pages = carried.pages, pages != pdf.pageCount {
                    notify("“\(carried.title)” changed on disk and now has \(pdf.pageCount) pages instead of \(pages). Your notes moved with it: check that they still point to the right places.",
                           severity: .warning, source: "Library", timeout: 20)
                } else {
                    notify("This PDF changed on disk; your notes moved with it.", source: "Library")
                }
            }
            then?(true)
            return .opened
        } catch { return failOpen(url, error, scoped: scoped, quiet: quiet, then: then) }
    }

    @discardableResult
    private func failOpen(_ url: URL, _ error: Error, scoped: Bool, quiet: Bool, then: ((Bool) -> Void)?) -> OpenOutcome {
        if scoped { url.stopAccessingSecurityScopedResource() }
        if !quiet { self.error = "Could not open this PDF: \(error.localizedDescription)" }
        then?(false)
        return .failed
    }

    /// A library book whose PDF is this file with other bytes: at the same path, or moved as well, with a bookmark that
    /// now leads here. The most recently read one wins.
    private func carryOverCandidate(for url: URL, fingerprint: String) throws -> (workspace: StudyWorkspace, onDisk: StudyWorkspace?)? {
        let key = LibraryPaths.key(url.path)
        let others = library.filter { $0.id != fingerprint && $0.fingerprint != fingerprint }
        var match = others.filter { LibraryPaths.key($0.sourcePath) == key }.max { $0.lastOpenedAt < $1.lastOpenedAt }
        if match == nil {
            let stamp = FileStamp(url)
            // Only books whose recorded file is gone are worth resolving.
            match = others.filter { $0.sourceBookmark != nil && !FileManager.default.fileExists(atPath: $0.sourcePath) }.first { book in
                var stale = false
                guard let data = book.sourceBookmark, let resolved = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                                                               relativeTo: nil, bookmarkDataIsStale: &stale) else { return false }
                if LibraryPaths.key(resolved.path) == key { return true }
                guard let stamp, let other = FileStamp(resolved) else { return false }
                return other.device == stamp.device && other.inode == stamp.inode
            }
        }
        guard let match else { return nil }
        if let front = self.workspace, front.id == match.id { return (front, savedSnapshot) }
        let saved = try repository.load(id: match.id)
        return (saved ?? match, saved)
    }

    /// What was made from a book's old bytes: its analysis, reference and page-text caches, its search index and cover.
    private func forgetDerivedData(_ id: String) {
        analyses.removeValue(forKey: id)?.cancel()
        referenceIndexes.removeValue(forKey: id)
        documents[id] = nil; sideDocuments[id] = nil
        recentDocuments.removeAll { $0 == id }
        outlineCache[id] = nil
        pageTextMaps = pageTextMaps.filter { !$0.key.hasPrefix(id + "#") }
        if indexedWorkspaceID == id { indexProgress = nil; indexedWorkspaceID = nil }
        repository.discardDerivedData(id: id)
        CoverThumbnails.shared.forget(id)
    }

    /// Whether a saved bookmark still leads to this very file, so it is kept (and the workspace left unchanged).
    private func bookmark(_ data: Data?, leadsTo url: URL) -> Bool {
        guard let data else { return false }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
              !stale else { return false }
        return resolved.standardizedFileURL.path == url.standardizedFileURL.path
    }

    /// Unlocks a PDF protected by a password, asking for it with the system's secure field. The password stays in memory
    /// for this session only, so the book can be shown again without asking; it is never written anywhere.
    private func unlock(_ document: PDFDocument, fingerprint: String, name: String) -> Bool {
        if let known = passwords[fingerprint], document.unlock(withPassword: known) { return true }
        var refused = false
        for _ in 0..<5 {
            guard let password = askPassword(for: name, refused: refused) else { return false }
            if document.unlock(withPassword: password) { passwords[fingerprint] = password; return true }
            refused = true
        }
        return false
    }

    private func askPassword(for name: String, refused: Bool) -> String? {
        if let passwordPrompt { return passwordPrompt(name, refused) }
        let alert = NSAlert()
        alert.messageText = refused ? "That password does not open “\(name)”" : "“\(name)” is protected by a password"
        alert.informativeText = "Enter its password to read it in Lemma. The password is kept only until Lemma quits and is never saved."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Password"
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// Shows a book in the reader. Other open books keep their tabs; the last few shown keep their documents in memory.
    /// `onDisk` is the version saved before this opening, so only what changed is written.
    private func present(_ workspace: StudyWorkspace, document pdf: PDFDocument, onDisk: StudyWorkspace?) {
        references?.saveIfNeeded()
        rememberBookEditors()
        // A debug session belongs to the book it was started in; the book opened comes to the front of the editor.
        if debug != nil { stopDebugging() }
        activeSpecial = nil; activeFileName = nil
        let projectEditor: UUID? = if case let .project(id)? = activeSideEditor { id } else { nil }
        if labHidInspector && !showStudy { showStudy = true }
        self.workspace = workspace
        savedSnapshot = onDisk
        self.document = pdf
        documents[workspace.id] = pdf
        keepDocumentInMemory(workspace.id)
        if let index = tabs.firstIndex(where: { $0.id == workspace.id }) {
            if tabs[index].title != workspace.title { tabs[index].title = workspace.title }
        } else { tabs.append(BookTab(id: workspace.id, title: workspace.title)) }
        self.selectedNoteID = workspace.notes.first?.id
        studySection = workspace.notes.isEmpty ? .page : workspace.notes.first?.kind.isGlossary == true ? .glossary : .notes
        resetReaderModes()
        referencePeek = nil; quickAsk = nil; definitionLookup = nil; ocrCapture = nil; paperLookups = [:]
        sideEditors = []; activeSideEditorID = nil; referencesQuery = nil
        hierarchyKey = nil; readingStatementCache = nil
        reader.rulerMode = false
        let outline = outlineCacheEntry(workspaceID: workspace.id, document: pdf)
        var index = referenceIndexes[workspace.id]
        if index?.document !== pdf {
            // An index built for another document of the same bytes (closed since, or opened from another path) holds
            // that document weakly: the page would show no links and peeks would fail.
            index = ReferenceIndex(workspaceID: workspace.id, document: pdf, outline: outline.items, repository: indexRepository)
        }
        guard let index else { return }
        referenceIndexes[workspace.id] = index
        let model = analyses[workspace.id] ?? BookAnalysisModel(workspaceID: workspace.id, repository: indexRepository)
        analyses[workspace.id] = model
        index.analysis = model
        model.onReady = { [weak self, weak index, weak model] in
            index?.invalidateMentions()
            self?.reader.view?.refreshCaptureOverlay()
            if self?.analysis === model { self?.refreshOutline() }
        }
        references = index; reader.references = index; analysis = model
        refreshOutline()
        if lockedFingerprints.contains(workspace.fingerprint) {
            model.skip("This PDF is protected by a password, so Lemma does not read its structure: references, statements and the index are not linked. Reading, notes and search on the page work.")
        } else {
            model.start(url: URL(fileURLWithPath: workspace.sourcePath), outline: outline.items)
        }
        reader.resetSearch()
        noteQuery = ""; noteFilter = .all
        browserStatus = ""
        indexProgress = nil; indexedWorkspaceID = nil
        refreshIndex()
        status = ""
        restoreBookEditors(workspace)
        if let projectEditor, project(projectEditor)?.archived == false { showSideEditor(.project(projectEditor)) }
        bringToFrontOfLibrary(workspace)
        // Written in the background: a reopened book usually changes only its reading position and the time it was opened.
        save(wait: false)
        saveTabs()
        if windowID == AppModel.primaryWindowID { UserDefaults.standard.set(workspace.id, forKey: "lastWorkspaceID") }
        tracker?.start()
    }

    /// Leaves recall, drawing and region modes and the selection, assigning only what is set: each of these redraws the
    /// page's overlays (notes, marks, ink) when assigned, even with the value it already has.
    private func resetReaderModes() {
        if reader.recallMask != nil { reader.recallMask = nil }
        if !reader.recallMaskRegions.isEmpty { reader.recallMaskRegions = [] }
        if reader.inkMode { reader.inkMode = false }
        if reader.regionMode { reader.regionMode = false }
        if reader.selection != nil { reader.selection = nil }
        if reader.hasSelection { reader.hasSelection = false }
    }

    /// Recent books come first in the library; a book takes its place there once, when it is opened.
    private func bringToFrontOfLibrary(_ workspace: StudyWorkspace) {
        if let index = library.firstIndex(where: { $0.id == workspace.id }) {
            if index == 0 { if library[0] != workspace { library[0] = workspace } }
            else { library.remove(at: index); library.insert(workspace, at: 0) }
        } else { library.insert(workspace, at: 0) }
    }

    /// Switches the editor to another open book, restoring its own reading position.
    func activateTab(_ id: String) { activateBook(id) }

    /// Brings an open book to the front: from memory when its document is still loaded, by opening its file otherwise.
    @discardableResult
    func activateBook(_ id: String, quiet: Bool = false, then: ((Bool) -> Void)? = nil) -> OpenOutcome {
        guard workspace?.id != id else { activeSpecial = nil; activeFileName = nil; saveWorkbench(); then?(true); return .opened }
        if let pdf = documents[id] {
            flush()
            // The saved workspace is decoded again only if its file changed since it was last read or saved.
            if let saved = app.currentWorkspace(id) ?? (try? repository.load(id: id)) ?? library.first(where: { $0.id == id }) {
                var workspace = saved
                workspace.lastOpenedAt = .now
                present(workspace, document: pdf, onDisk: saved)
                then?(true)
                return .opened
            }
        }
        if let item = library.first(where: { $0.id == id }) { return reopenBook(item, quiet: quiet, then: then) }
        then?(false)
        return .failed
    }

    /// Opens a library book in its tab, or switches to it when already open.
    func openBook(_ id: String) { activateTab(id) }

    /// Closes the current book's tab; the neighbouring tab takes its place, or the welcome page when none remains.
    func closeBook() {
        guard let id = workspace?.id else { return }
        closeTab(id)
    }

    func closeTab(_ id: String) { closeTabs([id]) }

    /// Closes every book tab (Close All Books).
    func closeAllBooks() { closeTabs(Set(tabs.map(\.id) + (workspace.map { [$0.id] } ?? []))) }

    /// Closes several book tabs at once. Only the book left in front is opened: the books closed with it are never
    /// opened on the way (reading, analysing and moving up in Recent), and a tab whose PDF no longer opens is closed too.
    func closeTabs(_ ids: Set<String>, preferring preferred: String? = nil) {
        let isCurrent = workspace.map { ids.contains($0.id) } ?? false
        let closing = tabs.map(\.id).filter { ids.contains($0) }
        guard isCurrent || !closing.isEmpty else { return }
        if isCurrent { flush() }
        let position = workspace.flatMap { front in tabs.firstIndex { $0.id == front.id } }
        tabs.removeAll { ids.contains($0.id) }
        for id in Set(closing + (isCurrent ? [workspace!.id] : [])) { release(id) }
        if isCurrent {
            // The tab that took the closed one's place, then those after it, then those before.
            let start = min(position ?? 0, max(tabs.count - 1, 0))
            var order = Array(tabs[start...].map(\.id)) + Array(tabs[..<start].reversed().map(\.id))
            if let preferred, let index = order.firstIndex(of: preferred) { order.insert(order.remove(at: index), at: 0) }
            showFirstOpenable(order)
        }
        saveTabs()
    }

    /// Lets go of what an open book holds: its document, analysis, reference index, notebooks' kernels and file access.
    private func release(_ id: String) {
        referenceIndexes.removeValue(forKey: id)?.saveIfNeeded()
        analyses.removeValue(forKey: id)?.cancel()
        lab.shutdown(workspaceID: id)
        documents[id] = nil
        recentDocuments.removeAll { $0 == id }
        outlineCache[id] = nil
        accessedSources.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
    }

    /// Shows the first of these tabs whose book opens. Tabs whose PDF cannot be opened (moved, deleted, on a disk that is
    /// not connected) are closed as well, with one notification, so ⌘W never sticks on them.
    private func showFirstOpenable(_ candidates: [String], skipped: [String] = []) {
        var skipped = skipped
        var remaining = candidates[...]
        while let id = remaining.popFirst() {
            let title = tabs.first { $0.id == id }?.title ?? library.first { $0.id == id }?.title ?? "A book"
            let rest = Array(remaining)
            var synchronous = true
            let outcome = activateBook(id, quiet: true) { [weak self] opened in
                guard !synchronous, let self else { return }
                if opened { self.reportClosedTabs(skipped) }
                else { self.dropTab(id); self.showFirstOpenable(rest, skipped: skipped + [title]) }
            }
            synchronous = false
            switch outcome {
            case .opened: reportClosedTabs(skipped); return
            case .pending:
                // The closed book leaves the editor while the next one is read from its file.
                unloadBook(keepingSideBar: true)
                return
            case .failed: skipped.append(title); dropTab(id)
            }
        }
        unloadBook()
        reportClosedTabs(skipped)
    }

    private func dropTab(_ id: String) {
        tabs.removeAll { $0.id == id }
        release(id)
        saveTabs()
    }

    private func reportClosedTabs(_ titles: [String]) {
        guard !titles.isEmpty else { return }
        let list = titles.map { "“\($0)”" }.joined(separator: ", ")
        notify(titles.count == 1 ? "Closed the tab of \(list): its PDF could not be opened. Open it again from the Library once the file is back."
                                 : "Closed \(titles.count) tabs whose PDFs could not be opened: \(list). Open them again from the Library once the files are back.",
               severity: .warning, source: "Lemma", timeout: 20)
    }

    /// Saves and closes the current book, returning to the welcome page. Closing tabs keeps the side bar's view.
    private func unloadBook(keepingSideBar: Bool = false) {
        guard workspace != nil else { return }
        if debug != nil { stopDebugging() }
        let projectEditor: UUID? = if case let .project(id)? = activeSideEditor { id } else { nil }
        flush()
        references?.saveIfNeeded()
        referencePeek = nil; quickAsk = nil; definitionLookup = nil; ocrCapture = nil
        reader.resetSearch()
        resetReaderModes()
        references = nil; reader.references = nil; analysis = nil
        workspace = nil; document = nil; selectedNoteID = nil; outline = []
        savedSnapshot = nil
        sideEditors = []; activeSideEditorID = nil; referencesQuery = nil
        if let projectEditor { showSideEditor(.project(projectEditor)) }
        status = ""; browserStatus = ""
        if !keepingSideBar, navigatorSection != .search { navigatorSection = .library }
        if windowID == AppModel.primaryWindowID { UserDefaults.standard.removeObject(forKey: "lastWorkspaceID") }
    }

    private func saveTabs() {
        if windowID == AppModel.primaryWindowID { UserDefaults.standard.set(tabs.map(\.id), forKey: "openTabs") }
        saveWorkbench()
    }

    func reopen(_ item: StudyWorkspace) { reopenBook(item) }

    /// Opens a library book from its file (found again through its bookmark when it moved), or switches to its tab.
    @discardableResult
    func reopenBook(_ item: StudyWorkspace, quiet: Bool = false, then: ((Bool) -> Void)? = nil) -> OpenOutcome {
        if documents[item.id] != nil { return activateBook(item.id, quiet: quiet, then: then) }
        var url = URL(fileURLWithPath: item.sourcePath)
        if let bookmark = item.sourceBookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale) { url = resolved }
        }
        return openFile(url, quiet: quiet, then: then)
    }

    func restore() {
        // The window's onAppear runs again when the window is reopened from the Dock: the session is restored once, or
        // the book's side tabs would be replaced by the home editors (and saved that way).
        guard !restoreStarted else { return }
        restoreStarted = true
        // Quitting saves and stops helpers even once this window is closed, and works while a sheet is shown.
        AppLifecycle.shared.attach(app)
        PageThemeState.shared.theme = pageTheme
        // Reopening the book saves its session, including clearing any special editor in front.
        let savedActiveSpecial = workbench.activeSpecial
        let savedActiveFile = workbench.activeFileName
        if hasSavedSession {
            workbenchLayout = workbench.layout; selectedProjectID = workbench.projectID
            if let expanded = workbench.paneExpanded { paneExpanded = expanded }
            showLibrary = workbench.showLibrary; showStudy = workbench.showStudy; showPanel = workbench.showPanel
            panelTab = workbench.panelTab; navigatorSection = workbench.navigator
            sideEditors = workbench.homeEditors.filter { if case let .project(id) = $0 { projects.contains { $0.id == id && !$0.archived } } else { false } }
            activeSideEditorID = workbench.activeHomeEditorID
            specialTabs = workbench.specialTabs ?? []
            fileTabs = workbench.fileTabs ?? []
        }
        // Tabs from the last session come back without loading their documents until they are shown. A book whose
        // workspace could not be read keeps its place in the saved session, for when its file is readable again.
        let ids = hasSavedSession ? workbench.bookIDs : (UserDefaults.standard.stringArray(forKey: "openTabs") ?? [])
        let unreadable = Set(unreadableWorkspaces.map(\.id))
        preservedTabIDs = ids.filter { unreadable.contains($0) }
        tabs = ids.compactMap { id in
            library.first { $0.id == id }.map { BookTab(id: id, title: $0.title) }
        }
        let args = CommandLine.arguments
        if windowID == AppModel.primaryWindowID, let index = args.firstIndex(of: "--open"), args.indices.contains(index + 1) {
            let page = args.firstIndex(of: "--page").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil }
            openFile(URL(fileURLWithPath: args[index + 1])) { [weak self] opened in
                guard opened, let self, let page else { return }
                self.workspace?.reading.pageIndex = max(0, page - 1)
                self.workspace?.reading.positionX = nil; self.workspace?.reading.positionY = nil
                if let id = self.workspace?.id { self.whenShowing(id) { $0.reader.goToPage(page) } }
            }
        } else if let id = hasSavedSession ? workbench.activeBookID : UserDefaults.standard.string(forKey: "lastWorkspaceID"), let item = library.first(where: { $0.id == id }) {
            reopen(item)
        }
        // A special editor in front stays in front; with nothing open, the Welcome page greets the reader, as in VS Code.
        if let special = savedActiveSpecial, specialTabs.contains(special) {
            activeSpecial = special
            saveWorkbench()
        }
        if let name = savedActiveFile, fileTabs.contains(name) { openWorkspaceFile(name) }
        restored = true
        let requested = pendingFileOpens; pendingFileOpens = []
        for url in requested { open(url) }
        if workspace == nil, activeSpecial == nil, activeFileName == nil, openingFile == nil, (UserDefaults.standard.string(forKey: "workbench.startupEditor") ?? "welcomePage") == "welcomePage" {
            openSpecial(.welcome)
        }
        if let message = error { error = nil; notify(message, severity: .error) }
    }

    func capture() throws -> SourceAnchor {
        guard let workspace, let document, let (index, rectangle, quote) = reader.selection,
              let page = document.page(at: index) else { throw BridgeError.invalidImage }
        let region = PageRegion(x: rectangle.minX, y: rectangle.minY, width: rectangle.width, height: rectangle.height)
        let data = try PDFRegionRenderer.png(page: page, region: region)
        let name = "\(UUID().uuidString).png"
        try repository.saveImage(data, workspaceID: workspace.id, name: name)
        return SourceAnchor(pageIndex: index, pageLabel: page.label ?? String(index + 1), region: region, quote: quote, imageName: name)
    }

    func addNote() { addNote(kind: .question) }
    func addNote(kind: NoteKind) {
        if kind == .comment { addMarginNote(); return }
        do {
            let anchor = try capture()
            let title = kind.isGlossary ? String(anchor.quote.replacingOccurrences(of: "\n", with: " ").prefix(100)) : ""
            let note = StudyNote(anchor: anchor, question: title, kind: kind)
            workspace?.notes.insert(note, at: 0)
            if let bookID = workspace?.id { registerNoteCreationUndo(note, bookID: bookID) }
            selectedNoteID = note.id
            revealStudy(); studySection = kind.isGlossary ? .glossary : .notes
            noteQuery = ""; noteFilter = .all
            flush()
        } catch { self.error = "Select text or draw a region on one page before adding a note." }
    }

    func pinSelection() {
        do {
            let anchor = try capture()
            workspace?.pins.append(ContextPin(label: "Reference · page \(anchor.pageLabel)", anchor: anchor))
            revealStudy(); studySection = .references
            flush()
        } catch { self.error = "Select text or draw a region on one page before pinning it." }
    }

    func prepareOCR(useSelection: Bool) {
        guard let workspace, let document else { return }
        let index: Int
        let rectangle: CGRect
        if useSelection {
            guard let selection = reader.selection else { return }
            index = selection.0; rectangle = selection.1
        } else {
            index = reader.pageNumber - 1
            guard let page = document.page(at: index) else { return }
            rectangle = page.bounds(for: .cropBox)
        }
        guard let page = document.page(at: index) else { return }
        do {
            let region = PageRegion(x: rectangle.minX, y: rectangle.minY, width: rectangle.width, height: rectangle.height)
            let png = try PDFRegionRenderer.png(page: page, region: region)
            let anchor = SourceAnchor(pageIndex: index, pageLabel: page.label ?? String(index + 1), region: region,
                quote: "", imageName: "\(UUID().uuidString).png")
            ocrCapture = OCRCapture(workspaceID: workspace.id, anchor: anchor, pngData: png,
                sourceLabel: useSelection ? "Selected region" : "Whole page")
        } catch { self.error = "Could not prepare this page for text recognition: \(error.localizedDescription)" }
    }

    func createNoteFromOCR(_ capture: OCRCapture, text: String) {
        guard workspace?.id == capture.workspaceID,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try repository.saveImage(capture.pngData, workspaceID: capture.workspaceID, name: capture.anchor.imageName)
            var anchor = capture.anchor; anchor.quote = text
            var note = StudyNote(id: capture.id, anchor: anchor)
            note.sourceTextOrigin = .ocr
            if let index = workspace?.notes.firstIndex(where: { $0.id == note.id }) { workspace?.notes[index] = note }
            else {
                workspace?.notes.insert(note, at: 0)
                registerNoteCreationUndo(note, bookID: capture.workspaceID)
            }
            selectedNoteID = note.id
            revealStudy(); studySection = .notes; noteQuery = ""; noteFilter = .all
            flush()
            if !saveFailed { ocrCapture = nil; status = "Recognized source text saved. Add your question or reasoning." }
        } catch { self.error = "Could not save the recognized source: \(error.localizedDescription)" }
    }

    @discardableResult
    func saveExperiment(_ record: ExperimentRecord, workspaceID: String) -> Bool {
        guard workspace?.id == workspaceID,
              let note = workspace?.notes.first(where: { $0.id == record.noteID }), note.anchor == record.source else { return false }
        updateNote(id: record.noteID) { note in
            if let index = note.experiments.firstIndex(where: { $0.id == record.id }) { note.experiments[index] = record }
            else { note.experiments.append(record) }
        }
        flush()
        if !saveFailed { status = "Experiment recorded with its source note." }
        return !saveFailed
    }

    func updateNote(_ edit: (inout StudyNote) -> Void) {
        guard let id = selectedNoteID else { return }
        updateNote(id: id, edit)
    }
    func updateNote(id: UUID, _ edit: (inout StudyNote) -> Void) {
        guard let index = workspace?.notes.firstIndex(where: { $0.id == id }) else { return }
        edit(&workspace!.notes[index])
        scheduleSave()
    }

    var visibleNotes: [StudyNote] {
        (workspace?.notes ?? []).filter {
            (studySection != .glossary || $0.kind.isGlossary) && $0.matches(noteQuery) && noteFilter.includes($0)
        }.sorted { $0.anchor.pageIndex == $1.anchor.pageIndex ? $0.createdAt > $1.createdAt : $0.anchor.pageIndex < $1.anchor.pageIndex }
    }
    /// Notes due for recall now, earliest first.
    var reviewNotes: [StudyNote] { (workspace?.notes ?? []).filter { $0.isDue() }.sorted { ($0.reviewDueAt ?? .distantPast) < ($1.reviewDueAt ?? .distantPast) } }
    /// Every note in the review deck, due or scheduled later.
    var reviewDeck: [StudyNote] { (workspace?.notes ?? []).filter(\.isInReview) }
    func selectNote(_ id: UUID) {
        selectedNoteID = id; revealStudy()
        studySection = currentNote?.kind.isGlossary == true ? .glossary : .notes
    }
    func revealStudy() {
        if focusMode { toggleFocus() }
        showStudy = true
    }
    func toggleFocus() {
        if focusMode {
            showLibrary = previousPanels?.0 ?? true; showStudy = previousPanels?.1 ?? true; showPanel = previousPanels?.2 ?? false
            previousPanels = nil
        } else {
            previousPanels = (showLibrary, showStudy, showPanel); showLibrary = false; showStudy = false; showPanel = false
        }
        focusMode.toggle()
    }
    func toggleLibrary() { if focusMode { toggleFocus() }; showLibrary.toggle() }
    func toggleStudy() { if focusMode { toggleFocus() }; showStudy.toggle() }
    func pinNote(_ note: StudyNote) {
        guard workspace?.pins.contains(where: { $0.anchor == note.anchor }) != true else {
            revealStudy(); studySection = .references; return
        }
        workspace?.pins.append(ContextPin(label: note.title, anchor: note.anchor))
        flush(); status = "Reference pinned."
    }
    func recordReview(id: UUID, understood: Bool) { grade(id: id, understood ? .good : .again) }

    /// Schedules the next recall from the reader's own grade.
    func grade(id: UUID, _ grade: ReviewGrade, now: Date = .now) {
        updateNote(id: id) { $0.grade(grade, now: now) }
        flush()
    }

    func addToReview(id: UUID) {
        updateNote(id: id) { note in
            if note.review == nil { note.review = ReviewSchedule(dueAt: .now) }
            note.state = .revisit
        }
        flush()
    }

    func removeFromReview(id: UUID) {
        updateNote(id: id) { note in
            note.review = nil
            if note.state == .revisit { note.state = .open }
        }
        flush()
    }
    var pageIsBookmarked: Bool { workspace?.bookmarks.contains { $0.pageIndex == reader.pageNumber - 1 } == true }
    func toggleBookmark() {
        guard let document, workspace != nil, let page = document.page(at: reader.pageNumber - 1) else { return }
        if pageIsBookmarked { workspace?.bookmarks.removeAll { $0.pageIndex == reader.pageNumber - 1 } }
        else {
            let section = outline.flatMap(\.flattened).last { ($0.pageIndex ?? Int.max) <= reader.pageNumber - 1 }?.title
            let destination = reader.view?.currentDestination
            workspace?.bookmarks.append(ReadingBookmark(pageIndex: reader.pageNumber - 1, pageLabel: page.label ?? String(reader.pageNumber),
                title: section ?? "Page \(reader.pageNumber)", positionX: destination.map { Double($0.point.x) }, positionY: destination.map { Double($0.point.y) }))
            workspace?.bookmarks.sort { $0.pageIndex < $1.pageIndex }
        }
        flush()
    }
    func updateBookmark(id: UUID, title: String) {
        guard let index = workspace?.bookmarks.firstIndex(where: { $0.id == id }) else { return }
        workspace?.bookmarks[index].title = title; scheduleSave()
    }
    func removeBookmark(id: UUID) { workspace?.bookmarks.removeAll { $0.id == id }; flush() }
    func highlightSelection(color: HighlightColor? = nil, style: HighlightStyle = .highlight) {
        highlightSelection(swatch: color.map(HighlightSwatch.init) ?? app.highlightPalette.defaultColor(for: style), style: style)
    }

    func highlightSelection(swatch: HighlightSwatch, style: HighlightStyle = .highlight) {
        guard let (index, rectangle, quote) = reader.selection, let page = document?.page(at: index) else { return }
        let lines = reader.regionMode ? [rectangle] : (reader.view?.currentSelection?.selectionsByLine().map { $0.bounds(for: page) } ?? [rectangle])
        let regions = lines.filter { !$0.isEmpty && !$0.isNull }.map { PageRegion(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) }
        guard !regions.isEmpty else { return }
        let highlight = StudyHighlight(pageIndex: index, regions: regions, quote: quote, color: swatch.color, style: style, colorHex: swatch.hex)
        workspace?.highlights.append(highlight)
        if let bookID = workspace?.id { registerHighlightCreationUndo(highlight, bookID: bookID) }
        reader.activeHighlightID = highlight.id
        flush(); status = style == .underline ? "Underline saved." : "Highlight saved."
    }
    func updateLayout(_ layout: ReadingLayout) { workspace?.reading.layout = layout; scheduleSave() }
    func lookupSelection() {
        if let (page, region, text) = reader.selection, reader.hasSelection {
            lookupDefinition(text, pageIndex: page, region: region)
        } else {
            lookupDefinition("", pageIndex: reader.pageNumber - 1, region: nil)
        }
    }
    func lookupDefinition(_ text: String, pageIndex: Int, region: CGRect?) {
        guard let workspace else { return }
        definitionLookup = DefinitionLookupRequest(workspaceID: workspace.id, query: text.trimmingCharacters(in: .whitespacesAndNewlines),
            pageIndex: pageIndex, region: region)
        if let definitionLookup { reader.view?.presentDefinitionLookup(definitionLookup, store: self) }
    }

    /// Opens the reference's peek. `keep` (a Shift-click) opens it beside the peeks already open, all kept open until
    /// the reader closes them.
    func peekReference(_ mention: PageMention, pageIndex: Int, keep: Bool = false) {
        guard let workspace else { return }
        definitionLookup = nil
        let request = ReferencePeekRequest(workspaceID: workspace.id, mention: mention, pageIndex: pageIndex)
        if keep { reader.view?.presentReferencePeek(request, store: self, keep: true); return }
        referencePeek = request
        reader.view?.presentReferencePeek(request, store: self)
    }

    func goToReference(_ target: ReferenceTarget) {
        reader.go(to: target)
    }

    /// Keeps a referenced equation, figure or statement in Context, rendered from the original page.
    func pinReference(_ target: ReferenceTarget) {
        guard let workspace, let document, let page = document.page(at: target.pageIndex) else { return }
        if workspace.pins.contains(where: { $0.anchor.pageIndex == target.pageIndex && $0.anchor.region == target.region }) {
            revealStudy(); studySection = .references; return
        }
        do {
            let data = try PDFRegionRenderer.png(page: page, region: target.region)
            let name = "\(UUID().uuidString).png"
            try repository.saveImage(data, workspaceID: workspace.id, name: name)
            let label = page.label ?? String(target.pageIndex + 1)
            let anchor = SourceAnchor(pageIndex: target.pageIndex, pageLabel: label, region: target.region,
                                      quote: page.selection(for: target.region.rect)?.string ?? "", imageName: name)
            self.workspace?.pins.append(ContextPin(label: "\(target.key.spokenTitle) · page \(label)", anchor: anchor))
            flush()
            if !saveFailed { status = "\(target.key.spokenTitle) pinned to Context." }
        } catch { self.error = "Could not pin \(target.key.title): \(error.localizedDescription)" }
    }

    /// Lists the passages that mention a reference, using ordinary PDF search.
    func findMentions(of key: ReferenceKey) {
        if focusMode { toggleFocus() }
        showLibrary = true; navigatorSection = .search
        searchNotes = false; searchIndexed = false
        reader.searchText = key.searchText
        reader.find()
    }

    var libraryNoteResults: [(workspace: StudyWorkspace, note: StudyNote)] {
        guard !libraryNoteQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        if noteSearchByMeaning {
            return noteMeaningHits.compactMap { hit in
                guard let book = hit.workspaceID == workspace?.id ? workspace : library.first(where: { $0.id == hit.workspaceID }),
                      let note = book.notes.first(where: { $0.id == hit.noteID }) else { return nil }
                return (book, note)
            }
        }
        return booksForSearch(noteSearchScope).flatMap { book in book.notes.filter { $0.matches(libraryNoteQuery) }.map { (book, $0) } }
    }
    /// Opens a note found across the library: its book, the note selected, the page at its source. The page view is
    /// asked to move only once it shows that book; a book that does not open leaves the reader where it was.
    func openSearchResult(workspace book: StudyWorkspace, note: StudyNote) {
        reader.cancelSearch()
        let show = { [weak self] in
            guard let self, self.workspace?.id == book.id else { return }
            self.selectNote(note.id); self.noteQuery = ""; self.noteFilter = .all
            self.whenShowing(book.id) { $0.reader.go(to: note.anchor) }
        }
        if workspace?.id == book.id { show(); return }
        reopenBook(book) { [weak self] opened in
            guard opened, let self, self.workspace?.id == book.id else { return }
            // A book shown for the first time opens straight at the note rather than at its last position.
            if self.reader.view?.document !== self.document {
                self.workspace?.reading.pageIndex = note.anchor.pageIndex
                self.workspace?.reading.positionX = nil; self.workspace?.reading.positionY = nil
            }
            show()
        }
    }

    func updatePin(id: UUID, label: String) {
        guard let index = workspace?.pins.firstIndex(where: { $0.id == id }) else { return }
        workspace?.pins[index].label = label
        scheduleSave()
    }
    func removePin(id: UUID) { workspace?.pins.removeAll { $0.id == id }; flush() }

    func pasteExplanation() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Copy an explanation first, then paste it into this note."; return
        }
        updateNote { $0.explanation = SavedExplanation(body: text) }
        flush(); status = "Explanation saved beside its source."
    }

    /// A change to the book's content (a note, a highlight, ink…): saved once edits pause for 300 ms.
    func scheduleSave() {
        if !isSaving { isSaving = true }
        saveTimer.schedule(after: .milliseconds(300), content: true)
    }

    /// The reading position moved: saved once scrolling pauses for 300 ms, as a few hundred bytes beside the workspace.
    func scheduleViewportSave() {
        if !isSaving { isSaving = true }
        saveTimer.schedule(after: .milliseconds(300), content: false)
    }

    /// Saves everything now and returns once it is on disk: reading time, the reference cache, the projects, the editor
    /// session and the book in front (closing, switching books, quitting, and callers that report a failed save).
    func flush() {
        tracker?.commit(save: false)
        references?.saveIfNeeded()
        save(wait: true)
    }

    /// Saves what changed since the last save: the whole workspace when its content changed (encoded and written on the
    /// writer's queue), only its reading position and opening time when that is all, and the session when it changed.
    /// `wait` returns once everything queued is on disk and reports a failure at once.
    func save(wait: Bool) {
        saveTimer.cancel()
        for file in app.fileBuffers.values { file.save(in: workspaceFileRepository) }
        flushProjects()
        captureViewport()
        saveWorkbench()
        if let workspace { persist(workspace, final: wait) }
        if wait { repository.writer.waitUntilIdle() }
        collectSaveOutcomes()
    }

    /// Reads the exact viewport from the page view into the workspace, assigning only what changed: an equal assignment
    /// would still redraw everything that shows the workspace.
    func captureViewport() {
        guard let view = reader.view, let document, view.document === document, let destination = view.currentDestination,
              let page = destination.page, var reading = workspace?.reading else { return }
        reading.pageIndex = document.index(for: page)
        reading.scale = Double(view.scaleFactor)
        reading.positionX = Double(destination.point.x)
        reading.positionY = Double(destination.point.y)
        if workspace?.reading != reading { workspace?.reading = reading }
    }

    /// `final` saves (closing, switching, quitting) also bring the library's row fully up to date.
    private func persist(_ workspace: StudyWorkspace, final: Bool) {
        let previous = savedSnapshot?.id == workspace.id ? savedSnapshot : nil
        if let previous, previous.hasSameContent(as: workspace) {
            // Scrolling, zooming, switching tabs, the reading clock: the notes, ink and notebooks are not written again.
            if !previous.hasSameReading(as: workspace) {
                savedSnapshot = workspace
                repository.saveReadingLater(workspace.reading, lastOpenedAt: workspace.lastOpenedAt, readingLog: workspace.readingLog,
                                            id: workspace.id, completion: saveCompletion(for: workspace.id, content: false))
            }
            if let index = library.firstIndex(where: { $0.id == workspace.id }) {
                if final { if library[index] != workspace { library[index] = workspace } }
                else if library[index].reading.pageIndex != workspace.reading.pageIndex || library[index].reading.returnNote != workspace.reading.returnNote {
                    // While reading, lists follow the page reached and the note for next time, not the exact position.
                    library[index].reading = workspace.reading
                }
            }
            if isSaving, contentSavesInFlight == 0 { isSaving = false }
            return
        }
        var snapshot = workspace
        snapshot.schemaVersion = 10
        savedSnapshot = workspace
        contentSavesInFlight += 1
        if !isSaving { isSaving = true }
        repository.saveLater(snapshot, completion: saveCompletion(for: workspace.id))
        if let index = library.firstIndex(where: { $0.id == workspace.id }) {
            // Typing in a note redraws no list: the row is replaced when something a list shows changed, or the book is left.
            if final ? library[index] != workspace : Self.listsShowChanges(library[index], workspace) { library[index] = workspace }
        } else { library.insert(workspace, at: 0) }
    }

    /// Whether anything the library's lists show (title, file, progress, counts of notes, due recalls and labs, the
    /// note for next time, reading time) differs between two versions of a book.
    static func listsShowChanges(_ old: StudyWorkspace, _ new: StudyWorkspace) -> Bool {
        old.title != new.title || old.sourcePath != new.sourcePath || old.pageCount != new.pageCount
            || old.notes.count != new.notes.count || old.labs.count != new.labs.count || old.reading.pageIndex != new.reading.pageIndex
            || old.reading.returnNote != new.reading.returnNote || old.readingLog != new.readingLog
            || old.notes.lazy.filter({ $0.isDue() }).count != new.notes.lazy.filter({ $0.isDue() }).count
    }

    /// Runs on the writer's queue: records the outcome, and has the main actor apply it (at once when it waited).
    func saveCompletion(for id: String, content: Bool = true) -> @Sendable (Error?) -> Void {
        let outcomes = saveOutcomes
        return { [weak self] error in
            outcomes.record(id: id, content: content, error: error)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.collectSaveOutcomes() } }
        }
    }

    func collectSaveOutcomes() {
        for outcome in saveOutcomes.take() {
            if outcome.content { contentSavesInFlight = max(0, contentSavesInFlight - 1) }
            if let error = outcome.error {
                // Not on disk: the next save writes the whole workspace again.
                if savedSnapshot?.id == outcome.id { savedSnapshot = nil }
                saveFailed = true
                self.error = "Your latest changes could not be saved: \(error.localizedDescription)"
            } else if outcome.content, contentSavesInFlight == 0 { saveFailed = false }
        }
        if isSaving, contentSavesInFlight == 0, !saveTimer.contentPending { isSaving = false }
    }

    func exportNotes() {
        guard let workspace else { return }
        flush()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Export here"
        panel.message = "Export your notes, source crops, and the readable workspace."
        if panel.runModal() == .OK, let folder = panel.url {
            let destination = folder.appendingPathComponent("Lemma export \(Date.now.formatted(.iso8601).replacingOccurrences(of: ":", with: "-"))")
            do { try repository.export(workspace, to: destination); lastExportURL = destination; status = "Study notes exported." }
            catch { self.error = "Export failed: \(error.localizedDescription)" }
        }
    }

    /// The review deck as a file Anki imports (File → Import), with each source crop inside its card.
    func exportAnkiDeck() {
        guard let workspace else { return }
        flush()
        let cards = AnkiExport.cards(for: workspace) { note in
            try? Data(contentsOf: self.repository.assetURL(workspaceID: workspace.id, name: note.anchor.imageName))
        }
        guard !cards.isEmpty else { status = "The review deck is empty: add notes or statements to Review first."; return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(workspace.title) · Lemma cards.txt"
        panel.allowedContentTypes = [.plainText]
        panel.message = "Anki: File → Import this file. Cards keep their source image."
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try AnkiExport.text(cards, deck: "Lemma::\(workspace.title)").write(to: url, atomically: true, encoding: .utf8)
                status = "\(cards.count) cards exported for Anki."
            } catch { self.error = "Could not export the cards: \(error.localizedDescription)" }
        }
    }

    var preparedPrompt: String { prompt(style: .explanation, pinIDs: Set(workspace?.pins.map(\.id) ?? [])) }
    /// The current note's question as Ask composes it, with its passage, its section and the chosen pins (the cited
    /// equations, found as the question opens, are left out).
    func prompt(style: QuestionStyle, pinIDs: Set<UUID>) -> String {
        guard let workspace, let note = currentNote else { return "" }
        var candidates = QuestionContextCandidates(sourceText: note.anchor.quote.trimmingCharacters(in: .whitespacesAndNewlines), pins: workspace.pins)
        if let index = references {
            candidates.section = OutlineMap.section(containing: note.anchor.pageIndex, y: note.anchor.region.y + note.anchor.region.height, in: index.outline)?.title
        }
        var selection = ContextSelection.defaults(for: candidates)
        selection.pins = pinIDs.intersection(Set(workspace.pins.map(\.id)))
        return composition(note: note, style: style, candidates: candidates, selection: selection).prompt
    }

    func copyPrompt() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(preparedPrompt, forType: .string); status = "Question copied." }
    func copySource() {
        guard let workspace, let note = currentNote,
              let data = try? Data(contentsOf: repository.assetURL(workspaceID: workspace.id, name: note.anchor.imageName)) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data, forType: .png); status = "Source image copied."
    }

    func questionAssets(pinIDs: Set<UUID>? = nil) throws -> (images: [BrowserImage], data: [String: Data]) {
        guard let workspace, let note = currentNote else { throw BridgeError.invalidImage }
        let pins = workspace.pins.filter { pinIDs?.contains($0.id) ?? true }
        let anchors = [("Source A", note.anchor)] + pins.enumerated().map { ("Reference \($0.offset + 1): \($0.element.label)", $0.element.anchor) }
        var images: [BrowserImage] = []
        var data: [String: Data] = [:]
        for (index, item) in anchors.enumerated() {
            let bytes = try Data(contentsOf: repository.assetURL(workspaceID: workspace.id, name: item.1.imageName))
            let name = "source-\(index + 1).png"
            data[name] = bytes
            images.append(BrowserImage(name: name, label: item.0, byteCount: bytes.count))
        }
        return (images, data)
    }

    func askWeb(mode: WebQuestionMode, prompt: String? = nil, pinIDs: Set<UUID>? = nil, provider: QuestionProvider? = nil) {
        guard workspace != nil, let note = currentNote, note.pendingRequestID == nil, !note.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let assets = try questionAssets(pinIDs: pinIDs)
            handOff(BrowserPacket(noteID: note.id, mode: mode, prompt: prompt ?? preparedPrompt, images: assets.images, provider: provider ?? questions.provider, workspaceID: workspace?.id), imageData: assets.data)
        } catch { self.error = "Could not prepare the Web question: \(error.localizedDescription)" }
    }

    /// Persists the source correlation before any provider receives the question.
    func handOff(_ packet: BrowserPacket, imageData: [String: Data], replacingDraft: Bool = false) {
        if (packet.provider ?? .chatGPTWeb) == .chatGPTWeb, questions.webBusy {
            error = "ChatGPT is already answering a question. Wait for it or cancel it in Assistants."; return
        }
        do {
            try mailbox.prepare(packet, imageData: imageData)
            updateNote(id: packet.noteID) { $0.pendingRequestID = packet.id }
            flush()
            guard !saveFailed else { return }
            lastResults[packet.id] = nil
            browserStatus = "\((packet.provider ?? .chatGPTWeb).label) is preparing your question…"
            if let urlOpener, (packet.provider ?? .chatGPTWeb) == .chatGPTWeb {
                urlOpener(URL(string: "https://chatgpt.com/#lemma=\(packet.id.uuidString)")!)
            } else {
                questions.start(packet, store: self, replacingDraft: replacingDraft)
                DispatchQueue.main.async { [weak self] in self?.showBrowserSetup = true }
            }
        } catch { self.error = "Could not prepare the Web question: \(error.localizedDescription)" }
    }

    /// Sends a question again as a new request: the same draft and images, to the same note, which must be in the open
    /// book and not already waiting.
    func askAgain(_ packet: BrowserPacket, replacingDraft: Bool = false) {
        if let id = packet.workspaceID, workspace?.id != id, let book = library.first(where: { $0.id == id }) { reopen(book) }
        guard let workspace, packet.workspaceID == nil || packet.workspaceID == workspace.id,
              let note = workspace.notes.first(where: { $0.id == packet.noteID }) else {
            error = "The question's note is no longer in its book. Ask from the passage again."; return
        }
        guard note.pendingRequestID == nil else { error = "This note is already waiting for an answer."; return }
        do {
            let directory = mailbox.directory(packet.id)
            var data: [String: Data] = [:]
            for image in packet.images { data[image.name] = try Data(contentsOf: directory.appendingPathComponent(image.name)) }
            handOff(BrowserPacket(noteID: packet.noteID, mode: packet.mode, prompt: packet.prompt, images: packet.images,
                                  provider: packet.provider, workspaceID: packet.workspaceID), imageData: data, replacingDraft: replacingDraft)
        } catch { self.error = "Could not ask again: \(error.localizedDescription)" }
    }

    func openChrome(_ url: URL) {
        if let urlOpener { urlOpener(url); return }
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            error = "Google Chrome is not installed."; return
        }
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Task { @MainActor [weak self] in self?.error = error.localizedDescription } }
        }
    }

    func pollBrowser() {
        // A response belongs to its original book, even while the reader studies another tab.
        let books = (workspace.map { [$0] } ?? []) + library.filter { $0.id != workspace?.id && $0.notes.contains { $0.pendingRequestID != nil } }
        for book in books where collectsResponses(for: book.id) {
        for note in book.notes {
            guard let id = note.pendingRequestID else { continue }
            do {
                guard let result = try mailbox.result(id), result.requestID == id else {
                    if let job = questions.jobs.first(where: { $0.id == id }) {
                        browserStatus = job.message
                    } else if let packet = try? mailbox.packet(id), Date.now.timeIntervalSince(packet.createdAt) > 12 {
                        browserStatus = "The earlier question is no longer running. Cancel it from its note and ask again."
                    }
                    continue
                }
                let signature = "\(result.status):\(result.createdAt.timeIntervalSince1970)"
                guard lastResults[id] != signature else { continue }
                browserStatus = result.message ?? result.status.capitalized
                guard ["complete", "error"].contains(result.status) else { lastResults[id] = signature; continue }
                let packet = try? mailbox.packet(id, maximumAge: .infinity)
                var updated = try workspace?.id == book.id ? workspace! : (app.currentWorkspace(book.id) ?? repository.load(id: book.id) ?? book)
                guard let index = updated.notes.firstIndex(where: { $0.id == note.id && $0.pendingRequestID == id }) else { continue }
                if result.status == "complete", let answer = result.answer, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    updated.notes[index].explanation = SavedExplanation(body: answer, conversationURL: result.conversationURL, provider: packet?.provider ?? .chatGPTWeb, model: result.model)
                    status = "\((packet?.provider ?? .chatGPTWeb).label) explanation saved beside its source."
                } else if result.status == "complete" { continue }
                updated.notes[index].pendingRequestID = nil
                // Commit before marking this receipt collected, so a save failure remains retryable.
                try repository.save(updated)
                if workspace?.id == book.id { workspace = updated }
                library.removeAll { $0.id == book.id }; library.append(updated)
                lastResults[id] = signature
                if let job = questions.jobs.first(where: { $0.id == id }), result.status == "complete" {
                    job.message = "Saved beside its source in \(updated.title)."
                }
            } catch {
                self.error = "Could not save the assistant response: \(error.localizedDescription)"
                if let job = questions.jobs.first(where: { $0.id == id }) { job.message = "Answer received; saving to the source note failed. Lemma will retry." }
            }
        }
        }
    }

    func cancelQuestion(noteID: UUID) {
        guard let id = workspace?.notes.first(where: { $0.id == noteID })?.pendingRequestID else { return }
        questions.cancel(id)
        updateNote(id: noteID) { $0.pendingRequestID = nil }; flush(); browserStatus = "Question cancelled."
    }

    func installChromeHost() {
        do {
            guard let resources = Bundle.main.resourceURL else { throw CocoaError(.fileNoSuchFile) }
            let companion = resources.appendingPathComponent("Chrome Companion")
            let identity = try JSONSerialization.jsonObject(with: Data(contentsOf: companion.appendingPathComponent("identity.json"))) as? [String: String]
            guard let id = identity?["extensionID"], let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("LemmaBrowserHost"), FileManager.default.isExecutableFile(atPath: executable.path) else { throw CocoaError(.fileNoSuchFile) }
            let manifest: [String: Any] = ["name": "com.lemma.browser", "description": "Lemma study questions", "path": executable.path, "type": "stdio", "allowed_origins": ["chrome-extension://\(id)/"]]
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("com.lemma.browser.json"), options: .atomic)
            status = "Chrome connection prepared. Load the companion in Chrome once."
        } catch { self.error = "Could not prepare the Chrome companion: \(error.localizedDescription)" }
    }

    var companionURL: URL? {
        let visible = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Chrome Companion")
        if FileManager.default.fileExists(atPath: visible.path) { return visible }
        return Bundle.main.resourceURL?.appendingPathComponent("Chrome Companion")
    }

    func updateReturnNote(_ text: String) { workspace?.reading.returnNote = text; scheduleSave() }
}

struct OCRCapture: Identifiable {
    let id = UUID()
    let workspaceID: String
    let anchor: SourceAnchor
    let pngData: Data
    let sourceLabel: String
    var indexedPage: IndexedPage? = nil
}
