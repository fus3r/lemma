import AppKit
import PDFKit
import LemmaCore
import Synchronization

// How books are opened, kept in memory and saved: the pieces StudyStore's open and save paths share.

/// The outcome of asking for a book: in front now, on its way (its fingerprint is being read off the main thread),
/// or not opened.
enum OpenOutcome { case opened, pending, failed }

/// A PDF whose fingerprint is being read off the main thread: a long book, a file on a network volume or in the cloud.
@MainActor
final class OpeningFile {
    let url: URL
    let started = Date.now
    var task: Task<Void, Never>?
    /// Keeps the status bar's message alive while a long read (a large file in the cloud) goes on.
    var reminder: Task<Void, Never>?
    init(url: URL) { self.url = url }
    var title: String { url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ") }
    /// “Opening …”, then with the seconds elapsed: status messages fade after a few seconds unless they change.
    var message: String {
        let elapsed = Int(Date.now.timeIntervalSince(started))
        return elapsed < 3 ? "Opening “\(title)”…" : "Opening “\(title)”… \(elapsed) s"
    }
    func cancel() { task?.cancel(); reminder?.cancel() }
}

/// One timer behind every debounced save: edits and scrolling move its fire date rather than creating a task each time.
/// A content save keeps its deadline while the reader scrolls; a reading-position save waits for scrolling to pause.
@MainActor
final class SaveTimer {
    private var timer: Timer?
    /// What a save does; set once, so scrolling allocates nothing per tick.
    var action: (() -> Void)?
    /// A content change is waiting to be saved.
    private(set) var contentPending = false

    func schedule(after delay: Duration, content: Bool) {
        let date = Date.now.addingTimeInterval(Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18)
        if let timer, timer.isValid {
            // Scrolling must not postpone a pending content save; edits and scrolling otherwise push the save back.
            if content || !contentPending { timer.fireDate = date }
        } else {
            let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.cancel()
                    self.action?()
                }
            }
            timer.tolerance = 0.05
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        if content { contentPending = true }
    }

    func cancel() {
        timer?.invalidate(); timer = nil; contentPending = false
    }
}

/// Saves finished on the writer's queue, waiting for the main actor.
final class SaveOutcomes: Sendable {
    struct Outcome: Sendable { let id: String; let content: Bool; let error: (any Error)? }
    private let outcomes = Mutex<[Outcome]>([])
    func record(id: String, content: Bool, error: (any Error)?) { outcomes.withLock { $0.append(Outcome(id: id, content: content, error: error)) } }
    func take() -> [Outcome] { outcomes.withLock { outcomes in defer { outcomes = [] }; return outcomes } }
}

/// A document's outline, walked once: reference resolution, the analysis and the Outline view all use it.
struct OutlineCacheEntry {
    let document: ObjectIdentifier
    let items: [OutlineItem]
    var entries: [OutlineEntry]?
}

/// What the notebook shows about a saved explanation, derived once per text rather than on every redraw.
struct ExplanationSummary {
    let body: String
    let steps: Int
    let codeBlocks: Int
}

extension StudyWorkspace {
    /// Equal apart from what changes while reading (the position, the time it was opened, the reading time) and the
    /// schema version written: such changes are saved beside the workspace without writing its notes, ink and notebooks.
    func hasSameContent(as other: StudyWorkspace) -> Bool {
        var mine = self
        mine.reading = other.reading; mine.lastOpenedAt = other.lastOpenedAt; mine.readingLog = other.readingLog
        mine.schemaVersion = other.schemaVersion
        return mine == other
    }

    /// Whether what changes while reading differs.
    func hasSameReading(as other: StudyWorkspace) -> Bool {
        reading == other.reading && lastOpenedAt == other.lastOpenedAt && readingLog == other.readingLog
    }
}

@MainActor
extension StudyStore {
    /// How many open books besides the one in front keep their document, analysis and reference index in memory; the
    /// others are read again from their files (quickly, their fingerprints being known) when shown.
    static let documentsKeptInMemory = 2

    /// Marks a book's document as just shown, and lets go of the documents of tabs not shown for longest.
    func keepDocumentInMemory(_ id: String) {
        recentDocuments.removeAll { $0 == id }
        recentDocuments.append(id)
        var excess = recentDocuments.count - (Self.documentsKeptInMemory + 1)
        var index = 0
        while excess > 0, index < recentDocuments.count - 1 {
            let old = recentDocuments[index]
            // A book still being analysed keeps its model until the analysis is done.
            if old != workspace?.id, analyses[old]?.isAnalyzing != true {
                recentDocuments.remove(at: index)
                documents[old] = nil
                referenceIndexes.removeValue(forKey: old)?.saveIfNeeded()
                analyses.removeValue(forKey: old)?.cancel()
                outlineCache[old] = nil
                excess -= 1
            } else { index += 1 }
        }
    }

    /// The document's outline items, walked once per document.
    func outlineCacheEntry(workspaceID id: String, document: PDFDocument) -> OutlineCacheEntry {
        if let cached = outlineCache[id], cached.document == ObjectIdentifier(document) { return cached }
        let entry = OutlineCacheEntry(document: ObjectIdentifier(document), items: OutlineEntry.items(in: document))
        outlineCache[id] = entry
        return entry
    }

    /// The Outline view's entries for the document in front, walked once per document.
    func outlineEntries(for document: PDFDocument) -> [OutlineEntry] {
        guard let id = workspace?.id, self.document === document else { return OutlineEntry.entries(in: document) }
        var entry = outlineCacheEntry(workspaceID: id, document: document)
        if let entries = entry.entries { return entries }
        let entries = OutlineEntry.entries(in: document)
        entry.entries = entries
        outlineCache[id] = entry
        return entries
    }

    /// Side documents of other books are kept only while a side tab shows them.
    func trimSideDocuments() {
        guard !sideDocuments.isEmpty else { return }
        let shown = Set(sideEditors.compactMap { editor -> String? in if case let .page(state) = editor { state.bookID } else { nil } })
        for id in sideDocuments.keys where !shown.contains(id) { sideDocuments[id] = nil }
    }

    /// Runs `action` once the book is in front and the page view shows its document, after its open when it is on its way.
    /// Nothing runs when it could not be opened or another book took its place: a link or a search result never moves
    /// inside the wrong book.
    func whenShowing(_ id: String, timeout: Duration = .seconds(15), _ action: @escaping @MainActor (StudyStore) -> Void) {
        Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now + timeout
            while let store = self, ContinuousClock.now < deadline {
                let inFront = store.workspace?.id == id
                if inFront, store.activeSpecial == nil, store.activeFileName == nil, let document = store.document,
                   let view = store.reader.view, view.document === document, view.window != nil {
                    action(store); return
                }
                // Neither in front nor on its way: the open failed, or the reader chose another book meanwhile.
                if !inFront, store.openingFile == nil { return }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    /// The source crop or figure of a note or pin, decoded once.
    func assetImage(workspaceID: String, name: String) -> NSImage? {
        let key = "\(workspaceID)/\(name)" as NSString
        if let image = assetImages.object(forKey: key) { return image }
        guard let image = NSImage(contentsOf: repository.assetURL(workspaceID: workspaceID, name: name)) else { return nil }
        assetImages.setObject(image, forKey: key)
        return image
    }

    /// The steps to check and code blocks of a note's saved explanation, parsed again only when its text changes.
    func explanationSummary(noteID: UUID, body: String) -> ExplanationSummary {
        if let cached = explanationSummaries[noteID], cached.body == body { return cached }
        let summary = ExplanationSummary(body: body, steps: DerivationTemplate.steps(fromAnswer: body).filter { !$0.isEmpty }.count,
                                         codeBlocks: LabTemplate.codeBlocks(in: body).count)
        if explanationSummaries.count > 200 { explanationSummaries.removeAll() }
        explanationSummaries[noteID] = summary
        return summary
    }

    /// The error shown when some saved books cannot be read: which ones, and that their files are kept.
    static func unreadableMessage(_ failures: [WorkspaceLoadFailure]) -> String {
        let names = failures.prefix(4).map(\.label).joined(separator: ", ") + (failures.count > 4 ? " and \(failures.count - 4) more" : "")
        let reason = failures.first.map { " (\($0.message))" } ?? ""
        return failures.count == 1
            ? "Could not read the saved notes of \(names)\(reason). Its file is kept as it is; the rest of the library is available."
            : "Could not read the saved notes of \(failures.count) books: \(names)\(reason). Their files are kept as they are; the rest of the library is available."
    }

    /// Saves, stops notebooks, questions and analysis helpers, and waits for the last writes: quitting, whether or not
    /// the reader window is still open.
    func prepareForTermination() {
        app.prepareForTermination()
    }

    /// Closes the sheets the store presents, so quitting is not held up by one (AppKit does not quit under a sheet).
    func dismissSheets() {
        showQuestion = false; showBrowserSetup = false; showLibrarySources = false; showDependencyMap = false
        showShortcuts = false; showCustomization = false; showReleaseNotes = false; showAcknowledgements = false
        showHighlightColors = false; showNewFile = false
        ocrCapture = nil; formulaRequest = nil
    }

    /// Runs once the window has drawn its first frame: work the first frame does not need waits for it.
    func afterFirstFrame(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { work() } }
    }
}
