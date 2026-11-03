import AppKit
import Foundation
import Observation
import CoreServices
import LemmaCore

/// Decides off the main thread whether file-system events can change what the libraries list: a PDF or a folder
/// created, removed or renamed (hidden items are never listed), or FSEvents losing track. Other changes (a document
/// saved, a sync client's temporary files, downloads in progress) cost a string comparison and nothing else.
private final class LibraryEventFilter: Sendable {
    /// Watched folders (path keys), with a trailing “/”.
    let roots: [String]
    let notify: @Sendable () -> Void
    init(roots: [String], notify: @escaping @Sendable () -> Void) {
        self.roots = roots.map { $0.hasSuffix("/") ? $0 : $0 + "/" }; self.notify = notify
    }

    func isRelevant(_ eventPath: String, _ eventFlags: FSEventStreamEventFlags) -> Bool {
        let flags = Int(eventFlags)
        let lostTrack = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount
        if flags & lostTrack != 0 { return true }
        guard flags & (kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) != 0 else { return false }
        let path = eventPath.precomposedStringWithCanonicalMapping
        let relative = roots.first(where: { path.hasPrefix($0) }).map { path.dropFirst($0.count) } ?? Substring(path)
        if relative.hasPrefix(".") || relative.contains("/.") { return false }
        if flags & kFSEventStreamEventFlagItemIsDir != 0 { return true }
        return relative.lowercased().hasSuffix(".pdf")
    }
}

/// FSEvents calls this on the watcher's utility queue, with the event paths as a CFArray of CFStrings.
private let libraryEventCallback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
    guard let info else { return }
    let filter = Unmanaged<LibraryEventFilter>.fromOpaque(info).takeUnretainedValue()
    let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
    for index in 0..<min(count, list.count) where filter.isRelevant(list[index] as? String ?? "", flags[index]) {
        filter.notify()
        return
    }
}

/// Releases the filter when its stream goes; FSEvents calls it on the watch queue, so it lives outside any actor.
private let releaseLibraryEventFilter: CFAllocatorReleaseCallBack = { info in
    if let info { Unmanaged<LibraryEventFilter>.fromOpaque(info).release() }
}

/// What makes the libraries be scanned again. Watched folders are followed as trees through FSEvents (events
/// delivered and filtered on a utility queue, so the main thread hears only of changes to the listing). Single PDFs
/// (a library's PDFs added one by one, studied books outside every watched folder) are followed through their own
/// vnodes, for a rename, a move or a deletion: the folders they sit in (Downloads, Documents…) are not watched.
@MainActor
private final class LibraryFolderWatcher {
    var changed: (() -> Void)?
    /// Single PDFs followed at most (each holds a file descriptor); the others are found again at the next scan.
    static let fileLimit = 128
    // The stream and the file sources are made, changed and ended on `queue` only. Making them opens the watched
    // folders, every folder above them and the PDFs, and an open can wait: on macOS asking the reader whether Lemma may
    // read Documents or Desktop, on a disk waking up, on a network volume. The main thread must not wait with it.
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    nonisolated(unsafe) private var files: [String: DispatchSourceFileSystemObject] = [:]
    private var folders: [String] = []
    /// A stream was asked for and has not failed (the queue says so if it does).
    private var streaming = false
    nonisolated private let queue = DispatchQueue(label: "com.lemma.library-watch", qos: .utility)

    /// `folders` are path keys; `files` are paths, most important first.
    func watch(folders wanted: [String], files paths: [String]) {
        let folders = Array(Set(wanted)).sorted()
        let restart = folders != self.folders || (!streaming && !folders.isEmpty)
        self.folders = folders
        if restart { streaming = !folders.isEmpty }
        let wantedFiles = Set(paths.prefix(Self.fileLimit))
        queue.async { [weak self] in
            guard let self else { return }
            if restart {
                self.stopStream()
                if !folders.isEmpty, !self.startStream(folders) {
                    Task { @MainActor [weak self] in if self?.folders == folders { self?.streaming = false } }
                }
            }
            for (path, source) in self.files where !wantedFiles.contains(path) { source.cancel(); self.files[path] = nil }
            for path in wantedFiles where self.files[path] == nil { self.files[path] = self.watchFile(path) }
        }
    }

    /// On the queue. False when FSEvents refused the roots; the next scan asks again.
    nonisolated private func startStream(_ roots: [String]) -> Bool {
        let filter = LibraryEventFilter(roots: roots) { [weak self] in
            Task { @MainActor in self?.changed?() }
        }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passRetained(filter).toOpaque(), retain: nil,
                                           release: releaseLibraryEventFilter, copyDescription: nil)
        // File-level events, so the filter can tell a PDF from a temporary file; one batch a second at most.
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, libraryEventCallback, &context, roots as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return false }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
        return true
    }

    /// On the queue.
    nonisolated private func stopStream() {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        stream = nil
    }

    /// On the queue.
    nonisolated private func watchFile(_ path: String) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.delete, .rename, .revoke], queue: queue)
        // Both handlers run on the watch queue: they must not inherit this class's main-actor isolation.
        source.setEventHandler { @Sendable [weak self] in
            Task { @MainActor in self?.fileChanged(path) }
        }
        source.setCancelHandler { @Sendable in close(descriptor) }
        source.resume()
        return source
    }

    /// The file moved or went: this watch ends, and the scan that follows watches it again where it is now.
    private func fileChanged(_ path: String) {
        queue.async { [weak self] in self?.files.removeValue(forKey: path)?.cancel() }
        changed?()
    }

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        for source in files.values { source.cancel() }
    }
}

@MainActor @Observable
final class DynamicLibraries {
    private(set) var collections: [LibraryCollection] = [] { didSet { revision &+= 1 } }
    private(set) var entries: [LibraryPDF] = [] { didSet { revision &+= 1 } }
    private(set) var issues: [String: String] = [:] { didSet { revision &+= 1 } }
    private(set) var isScanning = false { didSet { revision &+= 1 } }
    private(set) var updatedAt: Date?
    /// Names given in Lemma to PDFs not opened yet, by path key (studied books keep theirs in their workspace).
    private(set) var titles: [String: String] = [:] { didSet { revision &+= 1 } }
    /// Studied books whose PDF is neither where it was nor where its bookmark leads, as of the last scan.
    private(set) var missingPaths: Set<String> = [] { didSet { revision &+= 1 } }
    /// Bumped whenever something the Library shows changes, so the tree can keep its rows otherwise.
    private(set) var revision = 0
    var error: String?
    @ObservationIgnored private let repository: LibraryCollectionRepository
    @ObservationIgnored private let titleRepository: LibraryTitleRepository
    @ObservationIgnored private let watcher = LibraryFolderWatcher()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var writable = true
    @ObservationIgnored private var started = false
    @ObservationIgnored private var workspacePaths: [String] = []
    /// Path keys from the last scan, and those worked out since (each resolves the path on disk).
    @ObservationIgnored private var keys: [String: String] = [:]
    @ObservationIgnored private var countMemo: (revision: Int, books: [String], count: Int)?
    @ObservationIgnored private var activation: NSObjectProtocol?
    /// The folders watched as trees, by key; nil until watching starts.
    @ObservationIgnored private var watchedFolders: Set<String>?
    @ObservationIgnored var sourcesResolved: (([String: LibrarySourceResolution]) -> Void)?
    /// The studied books, from memory (the store's library); without it, scans read them from disk.
    @ObservationIgnored var workspaceReferences: (@MainActor () -> [LibraryWorkspaceRef])?

    init(root: URL, defaults: [LibraryCollection]) {
        repository = LibraryCollectionRepository(root: root)
        titleRepository = LibraryTitleRepository(root: root)
        titles = titleRepository.load()
        do {
            if let saved = try repository.load() { collections = saved }
            else { collections = defaults; try repository.save(defaults) }
        } catch {
            writable = false
            self.error = "Could not read library sources. The saved file has been kept: \(error.localizedDescription)"
        }
        watcher.changed = { [weak self] in self?.refresh(debounce: true) }
    }

    /// Begin after the window appears: watching a protected folder can ask macOS for access.
    /// Doing that in App.init blocks first launch before macOS can present the app's window.
    func start() {
        guard !started else { return }
        started = true
        watchSources()
        refresh()
        // A missing source (an unplugged drive, a folder made again) may be back when the reader returns to Lemma.
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.issues.isEmpty else { return }
                self.refresh(debounce: true)
            }
        }
    }

    /// A path's key: from the last scan, or worked out once. The tree, the palette and the counts ask for the same
    /// keys at every redraw, and each one resolves the path on disk.
    func key(of path: String) -> String {
        if let key = keys[path] { return key }
        let key = LibraryPaths.key(path)
        keys[path] = key
        return key
    }

    /// PDFs listed or studied, each counted once.
    func pdfCount(bookPaths: [String]) -> Int {
        if let memo = countMemo, memo.revision == revision, memo.books == bookPaths { return memo.count }
        var all = Set(entries.map(\.key))
        for path in bookPaths { all.insert(key(of: path)) }
        countMemo = (revision, bookPaths, all.count)
        return all.count
    }

    func replace(_ collections: [LibraryCollection]) throws {
        guard writable else { throw CocoaError(.fileWriteNoPermission) }
        try repository.save(collections)
        self.collections = collections
        if started { watchSources(); refresh() }
    }

    /// Labels change independently of source watching, PDF identity and the reader's workspace.
    /// Sub-libraries shown inside a renamed library keep following it.
    @discardableResult
    func rename(_ id: String, to title: String) throws -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, collections.contains(where: { $0.id == id }) else { return false }
        try saveLabels(LibraryEditing.renaming(collection: id, to: title, in: collections))
        return true
    }

    /// Order, nesting and kinds are labels too: the same sources are watched, so nothing is scanned again.
    func reorganize(_ collections: [LibraryCollection]) throws {
        guard collections != self.collections else { return }
        try saveLabels(collections)
    }

    /// The name of a PDF in Lemma, or nil to use its filename again.
    func setTitle(_ title: String?, for path: String) throws {
        var updated = titles
        let key = key(of: path)
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty, title != LibraryPaths.title(of: path) { updated[key] = title } else { updated[key] = nil }
        try saveTitles(updated)
    }

    /// Names follow a file or folder that Lemma renamed or moved.
    func relocateTitles(from old: String, to new: String) throws {
        try saveTitles(LibraryEditing.relocating(keys: titles, from: old, to: new))
    }

    /// Shows a file or folder that Lemma just renamed or moved at its new place at once; the scan that follows agrees.
    func relocateEntries(from old: String, to new: String) {
        let oldKey = LibraryPaths.key(old)
        var changed = false
        let relocated = entries.map { entry -> LibraryPDF in
            let path: String
            if entry.key == oldKey { path = new }
            else if entry.key.hasPrefix(oldKey + "/") { path = new + entry.key.dropFirst(oldKey.count) }
            else { return entry }
            changed = true
            // The folder shown is relative to the watched folder, which stays put unless it is what moved.
            var url = URL(fileURLWithPath: entry.path).deletingLastPathComponent()
            let depth = entry.folder.split(separator: "/").count
            for _ in 0..<depth { url = url.deletingLastPathComponent() }
            let rootKey = LibraryPaths.key(url.path)
            if rootKey == oldKey || rootKey.hasPrefix(oldKey + "/") { return LibraryPDF(collectionID: entry.collectionID, path: path, folder: entry.folder) }
            let rootComponents = URL(fileURLWithPath: rootKey).pathComponents.count
            let folder = URL(fileURLWithPath: LibraryPaths.key(URL(fileURLWithPath: path).deletingLastPathComponent().path)).pathComponents
                .dropFirst(rootComponents).joined(separator: "/")
            return LibraryPDF(collectionID: entry.collectionID, path: path, folder: folder)
        }
        if changed { entries = relocated }
    }

    /// Files sent to the Trash leave the list at once.
    func removeEntries(_ paths: [String]) {
        let keys = Set(paths.map(LibraryPaths.key))
        let kept = entries.filter { entry in !keys.contains(entry.key) && !keys.contains { entry.key.hasPrefix($0 + "/") } }
        if kept.count != entries.count { entries = kept }
    }

    private func saveTitles(_ updated: [String: String]) throws {
        guard updated != titles else { return }
        try titleRepository.save(updated)
        titles = updated
    }

    @discardableResult
    func renameSection(_ parent: String, to title: String) throws -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, collections.contains(where: { $0.parent == parent }) else { return false }
        var renamed = collections
        for index in renamed.indices where renamed[index].parent == parent { renamed[index].parent = title }
        try saveLabels(renamed)
        return true
    }

    private func saveLabels(_ renamed: [LibraryCollection]) throws {
        guard writable else { throw CocoaError(.fileWriteNoPermission) }
        try repository.save(renamed)
        collections = renamed
    }

    /// Scans the sources again at utility priority. A newer scan cancels this one, worker included, so scans never
    /// pile up while files keep changing. The Library counts as scanning from the request on, through the debounce
    /// and any scan this one replaces.
    func refresh(debounce: Bool = false) {
        scanTask?.cancel()
        if !isScanning { isScanning = true }
        let collections = collections
        let root = repository.root
        let references = workspaceReferences?()
        scanTask = Task { [weak self] in
            if debounce {
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .utility) {
                LibraryScanner.scan(collections, references: references ?? DynamicLibraries.storedReferences(root: root))
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, let self else { return }
            // A label edit while scanning must not be replaced by the scan's older collection snapshot.
            guard self.collections == collections else { self.refresh(); return }
            if self.collections != result.collections {
                if writable {
                    do { try repository.save(result.collections) }
                    catch { self.error = "Could not save updated library sources: \(error.localizedDescription)" }
                }
                self.collections = result.collections
            }
            workspacePaths = result.workspacePaths
            var keys = result.workspaceKeys
            for entry in result.entries { keys[entry.path] = entry.key }
            self.keys = keys
            sourcesResolved?(result.workspaceSources)
            if entries != result.entries { entries = result.entries }
            if issues != result.issues { issues = result.issues }
            if missingPaths != result.missingWorkspacePaths { missingPaths = result.missingWorkspacePaths }
            if started { watchSources() }
            updatedAt = .now
            if isScanning { isScanning = false }
        }
    }

    /// The studied books as saved on disk, when no store gives them from memory (tests of the libraries alone).
    nonisolated static func storedReferences(root: URL) -> [LibraryWorkspaceRef] {
        ((try? WorkspaceRepository(root: root).list()) ?? []).map(LibraryWorkspaceRef.init)
    }

    func watchWorkspace(_ path: String) {
        let key = key(of: path)
        guard !workspacePaths.contains(where: { self.key(of: $0) == key }) else { return }
        // The book just opened is the first to follow.
        workspacePaths.insert(path, at: 0)
        if started { watchSources() }
    }

    /// Watched folders that exist are followed as trees; single PDFs (added one by one, or studied outside every
    /// watched folder) are followed file by file, most recently opened first.
    private func watchSources() {
        var folders: [String] = [], files: [String] = []
        var followed = Set<String>()
        for source in collections.flatMap(\.sources) {
            switch source.kind {
            case .folder:
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue { folders.append(source.id) }
            case .file:
                if followed.insert(source.id).inserted { files.append(source.path) }
            }
        }
        let roots = folders.map { $0 + "/" }
        for path in workspacePaths {
            let key = key(of: path)
            guard !roots.contains(where: { key.hasPrefix($0) }), followed.insert(key).inserted else { continue }
            files.append(path)
        }
        watcher.watch(folders: folders, files: files)
        // A watched folder that has just appeared (Books and Papers are made by the first download into them) may
        // already hold PDFs that no event will announce: look at it now.
        let appeared = watchedFolders.map { !Set(folders).isSubset(of: $0) } ?? false
        watchedFolders = Set(folders)
        if appeared { refresh(debounce: true) }
    }
}

@MainActor
extension StudyStore {
    /// Relink just the source fields; the current PDF, notes, selection and reading position stay in place.
    func relinkSources(_ sources: [String: LibrarySourceResolution]) { app.relinkSources(sources) }
}
