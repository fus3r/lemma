import AppKit
import LemmaCore
import Observation

/// The library and services shared by the reader windows. Each StudyStore owns only its window's workbench.
/// Open books share their content while each window retains its own reading position.
@MainActor @Observable
final class AppModel {
    static let primaryWindowID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let repository: WorkspaceRepository
    let workspaceFileRepository: WorkspaceFileRepository
    var workspaceFiles: [String] = []
    var fileBuffers: [String: WorkspaceFileBuffer] = [:]
    let mailbox: BrowserMailbox
    let questions: QuestionRuntime
    let libraries: DynamicLibraries
    let highlightPalette: HighlightPalette
    @ObservationIgnored let covers: LibraryCovers
    @ObservationIgnored let fingerprints: FingerprintCache
    @ObservationIgnored let lab: LabRuntime
    let downloads = PDFDownloads()
    @ObservationIgnored let libraryGlossary = LibraryGlossary()
    @ObservationIgnored lazy var librarySearch = LibraryTextSearch(cacheFolder: repository.root.appendingPathComponent("Indexes"))
    var library: [StudyWorkspace] = []
    var projects: [ResearchProject] = []
    var projectsDirty = false
    @ObservationIgnored var projectsWritable = true
    @ObservationIgnored var projectSaveTask: Task<Void, Never>?
    @ObservationIgnored var unreadableWorkspaces: [WorkspaceLoadFailure] = []
    @ObservationIgnored var passwords: [String: String] = [:]
    @ObservationIgnored var lockedFingerprints: Set<String> = []
    @ObservationIgnored var startupError: String?
    @ObservationIgnored var libraryReadable = true
    @ObservationIgnored let newLibrarySources: Bool
    @ObservationIgnored private var buffers: [String: WorkspaceBuffer] = [:]

    func buffer(for book: StudyWorkspace) -> WorkspaceBuffer {
        if let buffer = buffers[book.id] {
            if !windows.contains(where: { $0.workspace?.id == book.id }), buffer.book != book { buffer.book = book }
            return buffer
        }
        let buffer = WorkspaceBuffer(book)
        buffers[book.id] = buffer
        return buffer
    }

    func currentWorkspace(_ id: String) -> StudyWorkspace? { windows.lazy.compactMap(\.workspace).first { $0.id == id } }

    var windows: [StudyStore] { registered.compactMap(\.store) }
    @ObservationIgnored private var registered: [WeakWorkbench] = []
    /// Retains workbenches until SwiftUI claims them, and the last closed window until it is reopened.
    @ObservationIgnored private var waiting: [StudyStore] = []
    @ObservationIgnored private(set) var restored = false
    @ObservationIgnored private var restoring = false
    @ObservationIgnored var quitting = false
    @ObservationIgnored var openWindow: ((UUID) -> Void)?
    private var frontID: UUID? {
        didSet { if oldValue != frontID { for store in windows { store.tracker?.frontChanged() } } }
    }
    var front: StudyStore {
        if let id = frontID, let store = window(id) { return store }
        return windows.first ?? keep(StudyStore(app: self, windowID: savedWindows.first?.id ?? Self.primaryWindowID))
    }

    private var savedWindows: [ReaderWindowRecord] = [ReaderWindowRecord(id: primaryWindowID)]
    @ObservationIgnored private var manifestWritable = true
    @ObservationIgnored private var lastManifestData: Data?
    var manifestURL: URL { repository.root.appendingPathComponent("windows.json") }

    init(root supportRoot: URL? = nil) {
        let root = supportRoot ?? ProcessInfo.processInfo.environment["LEMMA_SUPPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? WorkspaceRepository.defaultRoot
        repository = WorkspaceRepository(root: root)
        workspaceFileRepository = WorkspaceFileRepository(root: root)
        do { workspaceFiles = try workspaceFileRepository.list() }
        catch { startupError = "Could not read Workspace Files: \(error.localizedDescription)" }
        highlightPalette = HighlightPalette(url: root.appendingPathComponent("HighlightColors.json"))
        mailbox = BrowserMailbox(root: root)
        questions = QuestionRuntime(root: root.appendingPathComponent("Assistants", isDirectory: true))
        covers = LibraryCovers(root: root)
        fingerprints = FingerprintCache(root: root)
        lab = LabRuntime(supportRoot: root)
        newLibrarySources = !FileManager.default.fileExists(atPath: root.appendingPathComponent("Libraries.json").path)
        libraries = DynamicLibraries(root: root, defaults: LibraryCollection.publicDefaults(support: root))
        do {
            let listing = try repository.listing()
            library = listing.workspaces; unreadableWorkspaces = listing.failures
            if !listing.failures.isEmpty { startupError = StudyStore.unreadableMessage(listing.failures) }
        } catch {
            libraryReadable = false
            startupError = "Could not read the study library: \(error.localizedDescription)"
        }
        do { projects = try ProjectRepository(root: root).load() }
        catch { projectsWritable = false; startupError = "Could not read the projects. Their saved file has been kept: \(error.localizedDescription)" }
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            do {
                let data = try Data(contentsOf: manifestURL)
                savedWindows = try JSONDecoder().decode([ReaderWindowRecord].self, from: data)
                lastManifestData = data
            } catch {
                manifestWritable = false
                startupError = "Could not restore the windows. Their saved file has been kept: \(error.localizedDescription)"
            }
        }
        libraries.sourcesResolved = { [weak self] sources in self?.relinkSources(sources) }
        libraries.workspaceReferences = { [weak self] in self?.library.map(LibraryWorkspaceRef.init) ?? [] }
    }

    func register(_ store: StudyStore) {
        registered.removeAll { $0.store == nil }
        registered.append(WeakWorkbench(store: store))
    }

    private func keep(_ store: StudyStore) -> StudyStore { waiting.append(store); return store }
    func window(_ id: UUID) -> StudyStore? { windows.first { $0.windowID == id } }
    func owner(of bookID: String) -> StudyStore? {
        windows.first { $0.workspace?.id == bookID } ?? windows.first { $0.tabs.contains { $0.id == bookID } }
    }

    /// Restores existing workbench.json as the first window, without changing its format or copying its tabs into new ones.
    func restoreWindows() {
        guard !restored else { return }
        restored = true; restoring = true
        let records = savedWindows.isEmpty ? [ReaderWindowRecord(id: Self.primaryWindowID)] : savedWindows
        for record in records where window(record.id)?.restoreStarted != true {
            let store = window(record.id) ?? keep(StudyStore(app: self, windowID: record.id))
            store.windowFrame = record.frame
            store.restore()
        }
        restoring = false
        AppLifecycle.shared.attach(self)
    }

    func claimWindow(_ id: UUID?) -> StudyStore {
        restoreWindows()
        let store = id.flatMap(window) ?? windows.first { !$0.hasWindow && !$0.windowRequested }
            ?? keep(StudyStore(app: self, windowID: UUID()))
        if !store.restoreStarted { store.restore() }
        store.hasWindow = true; store.windowRequested = false
        waiting.removeAll { $0 === store }
        frontID = store.windowID
        saveWindows()
        return store
    }

    func openRestoredWindows() {
        for store in windows where !store.hasWindow && !store.windowRequested { requestWindow(store) }
    }

    @discardableResult
    func newWindow() -> StudyStore {
        restoreWindows()
        let source = front
        // File > New Window starts empty even if the last closed window is waiting to be reopened from the Dock.
        for store in windows where restored && !store.hasWindow && !store.windowRequested {
            registered.removeAll { $0.store === store }; waiting.removeAll { $0 === store }
        }
        let store = keep(StudyStore(app: self, windowID: UUID()))
        store.workbench.layout = source.workbenchLayout
        store.workbench.showLibrary = source.workbench.showLibrary
        store.workbench.showStudy = source.workbench.showStudy
        store.restore()
        if let frame = source.mainWindow?.frame {
            store.windowFrame = frame.offsetBy(dx: 24, dy: -24)
        }
        requestWindow(store)
        saveWindows()
        return store
    }

    private func requestWindow(_ store: StudyStore) {
        guard !store.windowRequested else { return }
        store.windowRequested = true
        openWindow?(store.windowID)
    }

    func show(_ store: StudyStore) {
        frontID = store.windowID
        store.mainWindow?.deminiaturize(nil)
        store.mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidBecomeKey(_ window: NSWindow) {
        if let store = windows.first(where: { $0.mainWindow === window }) { frontID = store.windowID }
    }

    func windowWillClose(_ window: NSWindow) {
        guard let store = windows.first(where: { $0.mainWindow === window }), !quitting else { return }
        store.tracker?.stop()
        for tab in store.tabs where !windows.contains(where: { $0 !== store && $0.tabs.contains { $0.id == tab.id } }) {
            lab.shutdown(workspaceID: tab.id)
        }
        store.flush(); store.find.hide()
        store.windowFrame = window.frame; store.hasWindow = false; store.mainWindow = nil
        if windows.contains(where: { $0 !== store && ($0.hasWindow || $0.windowRequested) }) {
            registered.removeAll { $0.store === store }; waiting.removeAll { $0 === store }
        } else { waiting.append(store) }
        if frontID == store.windowID { frontID = windows.first?.windowID }
        saveWindows()
    }

    /// Workbenches save separately, so closing or saving one cannot replace another window's tabs and layout.
    func saveWindows() {
        guard restored, !restoring, manifestWritable, libraryReadable else { return }
        let records = windows.map { ReaderWindowRecord(id: $0.windowID, frame: $0.mainWindow?.frame ?? $0.windowFrame) }
        guard !records.isEmpty else { return }
        do {
            let data = try WorkspaceRepository.encoder.encode(records)
            guard data != lastManifestData else { return }
            try FileManager.default.createDirectory(at: repository.root, withIntermediateDirectories: true)
            try data.write(to: manifestURL, options: .atomic)
            lastManifestData = data
        } catch { front.error = "Could not save the windows: \(error.localizedDescription)" }
    }

    /// Source changes update the editing window before saving, preserving any unsaved notes there.
    func relinkSources(_ sources: [String: LibrarySourceResolution]) {
        for (id, source) in sources {
            guard let index = library.firstIndex(where: { $0.id == id }) else { continue }
            let showing = windows.first { $0.workspace?.id == id }
            do {
                let loaded = try showing?.workspace ?? repository.load(id: id)
                guard var book = loaded, LibraryPaths.key(book.sourcePath) == LibraryPaths.key(source.originalPath) else { continue }
                book.sourcePath = source.path; book.sourceBookmark = source.bookmark
                try repository.save(book)
                showing?.workspace?.sourcePath = source.path; showing?.workspace?.sourceBookmark = source.bookmark
                library[index] = book
            } catch { front.error = "Could not save the PDF's updated location: \(error.localizedDescription)" }
        }
    }

    func prepareForTermination() {
        guard !quitting else { return }
        quitting = true
        questions.shutdown()
        lab.shutdownAll()
        for store in windows {
            store.tracker?.stop(); store.flush(); store.fallbackUndoManager.removeAllActions()
        }
        saveWindows()
        BookAnalysisModel.terminateHelpers()
        repository.writer.waitUntilIdle()
    }

    func dismissSheets() { for store in windows { store.dismissSheets() } }
}

@MainActor
extension StudyStore {
    /// WindowReader can report the same window on redraw; placement and size restoration run only on first attachment.
    func attachWindow(_ window: NSWindow?) {
        guard let window else { return }
        let first = mainWindow !== window
        mainWindow = window
        titleBar.attach(window)
        if first, var frame = windowFrame, let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.size.width = min(max(960, frame.width), visible.width)
            frame.size.height = min(max(640, frame.height), visible.height)
            frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
            frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
            window.setFrame(frame, display: true)
        }
        fitWindowToScreen()
        if window.isKeyWindow { app.windowDidBecomeKey(window) }
    }

    /// One window collects a book's pending answers; the others display its shared editing buffer.
    func collectsResponses(for bookID: String) -> Bool {
        if let owner = app.owner(of: bookID) { return owner === self }
        return app.front === self
    }
}

private struct WeakWorkbench { weak var store: StudyStore? }
private struct ReaderWindowRecord: Codable {
    var id: UUID
    var frame: CGRect?
}

/// A shared editing buffer, like an editor's file: notes, ink and notebooks update in every window showing the book.
@MainActor @Observable
final class WorkspaceBuffer {
    var book: StudyWorkspace
    init(_ book: StudyWorkspace) { self.book = book }
}
