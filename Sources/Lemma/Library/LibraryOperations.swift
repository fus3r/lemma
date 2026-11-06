import AppKit
import LemmaCore

/// What a rename changes: the name Lemma shows, the file on disk, or both at once.
enum LibraryRenameMode: String, CaseIterable, Identifiable {
    case lemma, file, both
    var id: String { rawValue }
    var label: String { switch self { case .lemma: "Lemma"; case .file: "File"; case .both: "Both" } }
    var help: String {
        switch self {
        case .lemma: "Rename in Lemma only; the file keeps its name"
        case .file: "Rename the PDF file on disk"
        case .both: "Give the file and Lemma the same new name"
        }
    }
    /// The last choice, offered again.
    static var remembered: LibraryRenameMode {
        get { UserDefaults.standard.string(forKey: "library.renameMode").flatMap(LibraryRenameMode.init(rawValue:)) ?? .lemma }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "library.renameMode") }
    }
}

/// A PDF or folder of the tree, as library actions take it: where it is, and which library lists it (nil outside every library).
struct LibraryItemRef: Equatable {
    var path: String
    var collectionID: String?
    var isFolder = false
    var bookID: String? = nil
}

enum LibraryOperationError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { text } else { nil } }
}

/// The file operations library actions use; tests replace the Trash with a folder of their own.
enum LibraryFileSystem {
    nonisolated(unsafe) static var trash: (URL) throws -> URL? = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    /// Renames or moves an item; a change of letter case alone goes through a temporary name, as macOS volumes ignore case.
    static func move(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let caseOnly = source.path.precomposedStringWithCanonicalMapping.lowercased() == destination.path.precomposedStringWithCanonicalMapping.lowercased()
        if caseOnly {
            let temporary = source.deletingLastPathComponent().appendingPathComponent(".lemma-rename-\(UUID().uuidString)")
            try fm.moveItem(at: source, to: temporary)
            do { try fm.moveItem(at: temporary, to: destination) } catch { try? fm.moveItem(at: temporary, to: source); throw error }
            return
        }
        if fm.fileExists(atPath: destination.path) {
            throw LibraryOperationError.message("“\(destination.lastPathComponent)” already exists in “\(destination.deletingLastPathComponent().lastPathComponent)”.")
        }
        try fm.moveItem(at: source, to: destination)
    }

    /// A destination that does not exist yet: “name 2.pdf”, “name 3.pdf”…
    static func available(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension, folder = url.deletingLastPathComponent()
        for number in 2... {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    /// A filename made from a name typed for Lemma: “/” and “:” become “-”.
    static func fileName(fromTitle title: String) -> String {
        var name = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        return name
    }

    static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}

@MainActor
extension StudyStore {
    // MARK: Undo

    var libraryUndoManager: UndoManager? { mainWindow?.undoManager ?? libraryTree.undoManager }

    /// Library edits go on the window's undo stack, so ⌘Z puts a renamed, moved or trashed PDF back.
    /// `undo` and `redo` undo each other and register nothing themselves.
    func registerLibraryUndo(_ name: String, undo: @escaping @MainActor (StudyStore) -> Void, redo: @escaping @MainActor (StudyStore) -> Void) {
        guard let manager = libraryUndoManager else { return }
        manager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                undo(store)
                store.registerLibraryUndo(name, undo: redo, redo: undo)
            }
        }
        manager.setActionName(name)
    }

    /// For an action whose Redo performs it again, with a new outcome (new Trash locations, new copies): the action
    /// registers its own Undo each time it runs.
    func registerLibraryUndo(_ name: String, undo: @escaping @MainActor (StudyStore) -> Void, performingAgain redo: @escaping @MainActor (StudyStore) -> Void) {
        guard let manager = libraryUndoManager else { return }
        manager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                undo(store)
                manager.registerUndo(withTarget: store) { store in MainActor.assumeIsolated { redo(store) } }
                manager.setActionName(name)
            }
        }
        manager.setActionName(name)
    }

    /// Saves an edit of the libraries with Undo. Changed sources are scanned again; order, nesting and names are not.
    func editLibraryCollections(_ name: String, _ change: ([LibraryCollection]) -> [LibraryCollection]) {
        let before = libraries.collections
        let after = change(before)
        guard after != before else { return }
        let rescan = before.map(\.sources) != after.map(\.sources) || Set(before.map(\.id)) != Set(after.map(\.id))
        guard applyLibraryCollections(after, rescan: rescan) else { return }
        registerLibraryCollectionsUndo(name, restoring: before, replacing: after, rescan: rescan)
    }

    /// Configuration is shared across windows, whose Undo stacks are separate. An older snapshot must never
    /// replace library edits made since then in another window; a rejected action has no Redo to register.
    private func registerLibraryCollectionsUndo(_ name: String, restoring previous: [LibraryCollection], replacing expected: [LibraryCollection], rescan: Bool) {
        guard let manager = libraryUndoManager else { return }
        manager.registerUndo(withTarget: self) { [weak manager] store in
            MainActor.assumeIsolated {
                guard store.libraryUndoConfiguration(store.libraries.collections) == store.libraryUndoConfiguration(expected) else {
                    let action = manager?.isRedoing == true ? "redo" : "undo"
                    store.error = "Could not \(action) “\(name)” because the libraries changed in another window. Your current libraries were kept."
                    return
                }
                guard store.applyLibraryCollections(previous, rescan: rescan) else { return }
                store.registerLibraryCollectionsUndo(name, restoring: expected, replacing: previous, rescan: rescan)
            }
        }
        manager.setActionName(name)
    }

    /// Scanning refreshes macOS bookmarks and resolves alternate spellings of the same path. Those are source
    /// bookkeeping, not library edits, and must not make an otherwise compatible Undo fail after a scan.
    private func libraryUndoConfiguration(_ collections: [LibraryCollection]) -> [LibraryCollection] {
        collections.map { collection in
            var collection = collection
            collection.sources = collection.sources.map {
                LibrarySource(path: $0.id, kind: $0.kind, excludedPaths: $0.excludedPaths.map(LibraryPaths.key))
            }
            return collection
        }
    }

    @discardableResult
    func applyLibraryCollections(_ collections: [LibraryCollection], rescan: Bool) -> Bool {
        do {
            if rescan { try libraries.replace(collections) } else { try libraries.reorganize(collections) }
            return true
        } catch {
            self.error = "Could not save the library: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: Names

    func libraryBook(atPath path: String) -> StudyWorkspace? {
        let key = libraries.key(of: path)
        if let workspace, libraries.key(of: workspace.sourcePath) == key { return workspace }
        return library.first { libraries.key(of: $0.sourcePath) == key }
    }

    /// The name a PDF has in Lemma: its book's title, a name given before it was opened, or its filename.
    func libraryTitle(forPath path: String) -> String {
        if let book = libraryBook(atPath: path) { return book.title }
        return libraries.titles[libraries.key(of: path)] ?? LibraryPaths.title(of: path)
    }

    /// Renames a studied book everywhere it shows: its workspace, its tab and its side tabs.
    func setBookTitle(_ id: String, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if let showing = app.windows.first(where: { $0.workspace?.id == id }) {
            showing.workspace?.title = title
            showing.flush()
        } else if var book = (try? repository.load(id: id)) ?? library.first(where: { $0.id == id }) {
            book.title = title
            do {
                try repository.save(book)
                if let index = library.firstIndex(where: { $0.id == id }) { library[index] = book }
            } catch { self.error = "Could not rename the book: \(error.localizedDescription)"; return }
        }
        for store in app.windows {
            for index in store.tabs.indices where store.tabs[index].id == id { store.tabs[index].title = title }
            for index in store.sideEditors.indices {
                if case var .page(state) = store.sideEditors[index], state.bookID == id { state.title = title; store.sideEditors[index] = .page(state) }
            }
            store.saveWorkbench()
        }
    }

    /// The name of a PDF in Lemma: a studied book's title, or the name kept for a PDF not opened yet.
    func setLibraryTitle(_ title: String, path: String, bookID: String?) {
        if let id = bookID ?? libraryBook(atPath: path)?.id { setBookTitle(id, to: title); return }
        do { try libraries.setTitle(title, for: path) } catch { self.error = "Could not rename this PDF: \(error.localizedDescription)" }
    }

    /// Renames a PDF in Lemma, on disk or both. A studied book whose name was its filename follows a renamed file.
    /// One Undo puts both names back.
    @discardableResult
    func renameLibraryPDF(path: String, bookID: String?, to text: String, mode: LibraryRenameMode) throws -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LibraryOperationError.message("A name is required.") }
        let bookID = bookID ?? libraryBook(atPath: path)?.id
        let oldTitle = libraryTitle(forPath: path)
        let titleWasFilename = oldTitle == LibraryPaths.title(of: path)
        var newPath = path
        if mode != .lemma {
            newPath = try moveLibraryItemOnDisk(path, renamedTo: mode == .both ? LibraryFileSystem.fileName(fromTitle: text) : text)
        }
        let newTitle: String? = switch mode {
        case .lemma, .both: text
        case .file: titleWasFilename && bookID != nil ? LibraryPaths.title(of: newPath) : nil
        }
        if let newTitle, newTitle != oldTitle { setLibraryTitle(newTitle, path: newPath, bookID: bookID) }
        guard newPath != path || (newTitle != nil && newTitle != oldTitle) else { return newPath }
        let renamedFile = newPath != path, renamedTitle = newTitle.map { $0 != oldTitle } ?? false
        let finalTitle = newTitle ?? oldTitle, finalPath = newPath
        registerPDFRenameUndo(renamedFile ? "Rename File" : "Rename", bookID: bookID,
                              restoring: (path, oldTitle), replacing: (finalPath, finalTitle),
                              movesFile: renamedFile, changesTitle: renamedTitle)
        status = renamedFile ? "Renamed “\(URL(fileURLWithPath: path).lastPathComponent)” to “\(URL(fileURLWithPath: finalPath).lastPathComponent)”." : "Renamed to “\(finalTitle)” in Lemma."
        return newPath
    }

    /// Rename histories belong to their windows, while the book's title is shared. Reject an older rename before
    /// moving its file or replacing a newer title, and keep Undo/Redo available for the latest compatible rename.
    private func registerPDFRenameUndo(_ name: String, bookID: String?,
                                       restoring previous: (path: String, title: String),
                                       replacing expected: (path: String, title: String),
                                       movesFile: Bool, changesTitle: Bool) {
        guard let manager = libraryUndoManager else { return }
        manager.registerUndo(withTarget: self) { [weak manager] store in
            MainActor.assumeIsolated {
                let action = manager?.isRedoing == true ? "redo" : "undo"
                guard !changesTitle || store.libraryTitle(forPath: expected.path) == expected.title else {
                    store.error = "Could not \(action) “\(name)” because this PDF was renamed again in another window. Its current name was kept."
                    return
                }
                if movesFile {
                    do {
                        try LibraryFileSystem.move(URL(fileURLWithPath: expected.path), to: URL(fileURLWithPath: previous.path))
                        store.followMovedItem(from: expected.path, to: previous.path)
                    } catch {
                        store.error = "Could not \(action) “\(name)”: \(error.localizedDescription)"
                        return
                    }
                }
                if changesTitle { store.setLibraryTitle(previous.title, path: previous.path, bookID: bookID) }
                store.registerPDFRenameUndo(name, bookID: bookID, restoring: expected, replacing: previous,
                                            movesFile: movesFile, changesTitle: changesTitle)
            }
        }
        manager.setActionName(name)
    }

    /// Renames a folder on disk, inside a library's watched folder. Books, sources and names inside it follow.
    @discardableResult
    func renameLibraryFolder(_ path: String, to name: String) throws -> String {
        let newPath = try moveLibraryItemOnDisk(path, renamedTo: name)
        guard newPath != path else { return path }
        renameFolderExpansion(from: path, to: newPath)
        registerLibraryUndo("Rename Folder", undo: { $0.undoMove(from: newPath, to: path) }, redo: { $0.undoMove(from: path, to: newPath) })
        status = "Renamed the folder to “\(URL(fileURLWithPath: newPath).lastPathComponent)”."
        return newPath
    }

    /// Renames a file or folder in place, without registering Undo. Returns its new path.
    func moveLibraryItemOnDisk(_ path: String, renamedTo name: String) throws -> String {
        var name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = LibraryEditing.problem(withFileName: name) { throw LibraryOperationError.message(problem) }
        let old = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw LibraryOperationError.message("“\(old.lastPathComponent)” is no longer in “\(old.deletingLastPathComponent().lastPathComponent)”.")
        }
        if !LibraryFileSystem.isDirectory(path) {
            let ext = old.pathExtension.isEmpty ? "pdf" : old.pathExtension
            if (name as NSString).pathExtension.lowercased() != ext.lowercased() { name += "." + ext }
        }
        let new = old.deletingLastPathComponent().appendingPathComponent(name)
        guard new.path != old.path else { return path }
        try LibraryFileSystem.move(old, to: new)
        followMovedItem(from: old.path, to: new.path)
        return new.path
    }

    /// Moves an item back (Undo) or again (Redo), quietly reporting a file that has since moved.
    func undoMove(from current: String, to original: String) {
        do {
            try LibraryFileSystem.move(URL(fileURLWithPath: current), to: URL(fileURLWithPath: original))
            followMovedItem(from: current, to: original)
        } catch { self.error = "Could not move “\(URL(fileURLWithPath: current).lastPathComponent)” back: \(error.localizedDescription)" }
    }

    /// After Lemma renamed or moved a file or folder: library sources and exclusions, names given in Lemma and studied
    /// books take the new path at once, then the libraries are scanned again.
    func followMovedItem(from old: String, to new: String) {
        let oldKey = LibraryPaths.key(old)
        var moved: [String: LibrarySourceResolution] = [:]
        for book in library + (workspace.map { [$0] } ?? []) where moved[book.id] == nil {
            let key = LibraryPaths.key(book.sourcePath)
            guard key == oldKey || key.hasPrefix(oldKey + "/") else { continue }
            let path = key == oldKey ? new : new + key.dropFirst(oldKey.count)
            let bookmark = try? URL(fileURLWithPath: path).bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            moved[book.id] = LibrarySourceResolution(originalPath: book.sourcePath, path: path, bookmark: bookmark)
        }
        if !moved.isEmpty { relinkSources(moved) }
        libraries.relocateEntries(from: old, to: new)
        do { try libraries.relocateTitles(from: old, to: new) } catch { self.error = "Could not save names in Lemma: \(error.localizedDescription)" }
        let relocated = LibraryEditing.relocating(old, to: new, in: libraries.collections)
        if relocated != libraries.collections { applyLibraryCollections(relocated, rescan: true) } else { libraries.refresh() }
        libraries.watchWorkspace(new)
    }

    /// Open folders stay open after a rename.
    private func renameFolderExpansion(from old: String, to new: String) {
        let oldName = URL(fileURLWithPath: old).lastPathComponent, newName = URL(fileURLWithPath: new).lastPathComponent
        for (key, value) in paneExpanded where key.hasPrefix("library-folder-") {
            guard let colon = key.firstIndex(of: ":") else { continue }
            let relative = key[key.index(after: colon)...].split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard relative.last == oldName || relative.contains(oldName) else { continue }
            let renamed = relative.map { $0 == oldName ? newName : $0 }.joined(separator: "/")
            paneExpanded[String(key[...colon]) + renamed] = value
        }
    }

    // MARK: Disk

    /// Moves PDFs or folders into a folder on disk (dragging onto a folder). Returns how many moved; Undo moves them back.
    @discardableResult
    func moveLibraryItems(_ paths: [String], intoFolder folder: String) -> Int {
        var moves: [(from: String, to: String)] = []
        var problems: [String] = []
        let folderKey = LibraryPaths.key(folder)
        for path in paths {
            let source = URL(fileURLWithPath: path)
            let key = LibraryPaths.key(path)
            if LibraryPaths.key(source.deletingLastPathComponent().path) == folderKey { continue }
            if key == folderKey || folderKey.hasPrefix(key + "/") { problems.append("“\(source.lastPathComponent)” cannot move into itself."); continue }
            let destination = URL(fileURLWithPath: folder).appendingPathComponent(source.lastPathComponent)
            do {
                try LibraryFileSystem.move(source, to: destination)
                followMovedItem(from: source.path, to: destination.path)
                moves.append((source.path, destination.path))
            } catch { problems.append(error.localizedDescription) }
        }
        if !problems.isEmpty { self.error = problems.joined(separator: "\n") }
        guard !moves.isEmpty else { return 0 }
        registerLibraryUndo(moves.count == 1 ? "Move" : "Move \(moves.count) Items", undo: { store in
            for move in moves.reversed() { store.undoMove(from: move.to, to: move.from) }
        }, redo: { store in
            for move in moves { store.undoMove(from: move.from, to: move.to) }
        })
        status = moves.count == 1 ? "Moved “\(URL(fileURLWithPath: moves[0].to).lastPathComponent)” to “\(URL(fileURLWithPath: folder).lastPathComponent)”."
            : "Moved \(moves.count) items to “\(URL(fileURLWithPath: folder).lastPathComponent)”."
        return moves.count
    }

    /// Copies PDFs dropped from Finder into a library folder; the originals stay where they were.
    @discardableResult
    func copyIntoLibraryFolder(_ urls: [URL], folder: String) -> Int {
        var copies: [URL] = []
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            let destination = LibraryFileSystem.available(URL(fileURLWithPath: folder).appendingPathComponent(url.lastPathComponent))
            do { try FileManager.default.copyItem(at: url, to: destination); copies.append(destination) }
            catch { self.error = "Could not copy “\(url.lastPathComponent)”: \(error.localizedDescription)" }
        }
        guard !copies.isEmpty else { return 0 }
        libraries.refresh()
        registerLibraryUndo(copies.count == 1 ? "Copy" : "Copy \(copies.count) PDFs", undo: { store in
            for copy in copies { _ = try? LibraryFileSystem.trash(copy) }
            store.libraries.refresh()
        }, performingAgain: { store in store.copyIntoLibraryFolder(urls, folder: folder) })
        status = copies.count == 1 ? "Copied “\(copies[0].lastPathComponent)” into “\(URL(fileURLWithPath: folder).lastPathComponent)”."
            : "Copied \(copies.count) PDFs into “\(URL(fileURLWithPath: folder).lastPathComponent)”."
        return copies.count
    }

    /// Moves PDFs or folders to the Trash. Their notes stay in Lemma; Undo puts the files back.
    @discardableResult
    func trashLibraryItems(_ paths: [String]) -> Int {
        var trashed: [(original: String, trash: URL)] = []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            do {
                if let location = try LibraryFileSystem.trash(URL(fileURLWithPath: path)) { trashed.append((path, location)) }
            } catch { self.error = "Could not move “\(URL(fileURLWithPath: path).lastPathComponent)” to the Trash: \(error.localizedDescription)" }
        }
        guard !trashed.isEmpty else { return 0 }
        libraries.removeEntries(trashed.map(\.original))
        libraries.refresh()
        registerLibraryUndo("Move to Trash", undo: { store in
            for item in trashed {
                // A scan may already have followed the book into the Trash.
                store.undoMove(from: item.trash.path, to: item.original)
            }
        }, performingAgain: { store in store.trashLibraryItems(trashed.map(\.original)) })
        status = trashed.count == 1 ? "Moved “\(URL(fileURLWithPath: trashed[0].original).lastPathComponent)” to the Trash." : "Moved \(trashed.count) items to the Trash."
        return trashed.count
    }

    // MARK: Membership

    /// Moves PDFs or folders to another library; the files stay where they are. Keeping lists them in both.
    func moveToLibrary(_ items: [LibraryItemRef], collectionID: String, keep: Bool = false) {
        guard let target = libraries.collections.first(where: { $0.id == collectionID }) else { return }
        let moving = items.filter { $0.collectionID != collectionID }
        guard !moving.isEmpty else { return }
        editLibraryCollections(keep ? "Add to Library" : "Move to Library") { collections in
            moving.reduce(collections) { result, item in
                LibraryEditing.moving(item.path, isFolder: item.isFolder, from: item.collectionID, to: collectionID, keepingSource: keep, in: result)
            }
        }
        status = "\(moving.count == 1 ? "“\(URL(fileURLWithPath: moving[0].path).lastPathComponent)”" : "\(moving.count) items") \(keep ? "added to" : "moved to") \(target.title)."
    }

    /// Stops listing PDFs or folders in their library; files, notes and reading positions stay.
    func removeFromLibrary(_ items: [LibraryItemRef]) {
        let listed = items.filter { $0.collectionID != nil }
        guard !listed.isEmpty else { return }
        editLibraryCollections("Remove from Library") { collections in
            listed.reduce(collections) { result, item in LibraryEditing.removing(item.path, from: item.collectionID!, in: result) }
        }
        status = listed.count == 1 ? "Removed “\(URL(fileURLWithPath: listed[0].path).lastPathComponent)” from the library; the file stays on disk."
            : "Removed \(listed.count) items from the library; the files stay on disk."
    }

    /// Adds PDFs and folders (from Finder or an Open panel) to a library: PDFs one by one, folders watched.
    func addToLibrary(_ urls: [URL], collectionID: String) {
        let usable = urls.filter { LibraryFileSystem.isDirectory($0.path) || $0.pathExtension.lowercased() == "pdf" }
        guard !usable.isEmpty else { return }
        editLibraryCollections("Add to Library") { collections in
            usable.reduce(collections) { result, url in
                LibraryEditing.adding(url.path, isFolder: LibraryFileSystem.isDirectory(url.path), to: collectionID, in: result)
            }
        }
    }

    /// Lists PDFs again that were moved out of or removed from a library's watched folders.
    func restoreLibraryExclusions(_ collectionID: String) {
        editLibraryCollections("List Removed PDFs Again") { collections in
            collections.map { collection in
                guard collection.id == collectionID else { return collection }
                var collection = collection
                for index in collection.sources.indices { collection.sources[index].excludedPaths = [] }
                return collection
            }
        }
    }

    // MARK: Libraries

    /// A new, empty library; PDFs and folders can be dropped on it. Returns its id.
    @discardableResult
    func createLibrary(title: String, kind: LibraryKind = .studying, parent: String? = nil, sources: [LibrarySource] = []) -> String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let collection = LibraryCollection(title: title, kind: kind, parent: parent, sources: sources)
        editLibraryCollections("New Library") { $0 + [collection] }
        guard libraries.collections.contains(where: { $0.id == collection.id }) else { return nil }
        paneExpanded["collection-" + collection.id] = true
        return collection.id
    }

    /// A library made from a folder of another library; that folder leaves the first library.
    @discardableResult
    func libraryFromFolder(_ path: String, collectionID: String?) -> String? {
        let source = LibrarySource(path: path, kind: .folder, bookmark: LibraryPaths.bookmark(path))
        let collection = LibraryCollection(title: URL(fileURLWithPath: path).lastPathComponent, kind: .studying,
                                           parent: collectionID.flatMap { id in libraries.collections.first { $0.id == id }?.parent }, sources: [source])
        editLibraryCollections("New Library from Folder") { collections in
            var result = collections
            if let collectionID { result = LibraryEditing.removing(path, from: collectionID, in: result) }
            if let index = collectionID.flatMap({ id in result.firstIndex { $0.id == id } }) { result.insert(collection, at: index + 1) } else { result.append(collection) }
            return result
        }
        paneExpanded["collection-" + collection.id] = true
        return collection.id
    }

    func removeLibraryCollection(_ id: String) {
        let title = libraries.collections.first { $0.id == id }?.title ?? "the library"
        editLibraryCollections("Remove Library") { $0.filter { $0.id != id } }
        status = "Removed \(title). Its PDFs, notes and reading positions stay on this Mac."
    }

    /// Puts a library into a group (a section, or the library of that name) or at the top level, before another library.
    func moveLibraryCollection(_ id: String, toParent parent: String?, before anchor: String? = nil) {
        guard LibraryEditing.canMove(id, toParent: parent, in: libraries.collections) else { return }
        editLibraryCollections("Move Library") { LibraryEditing.moving(collection: id, toParent: parent, before: anchor, in: $0) }
        if let parent { paneExpanded["collection-parent-" + parent] = true }
    }

    func setLibraryKind(_ id: String, _ kind: LibraryKind) {
        editLibraryCollections("Change Library Type") { collections in
            collections.map { collection in
                guard collection.id == id else { return collection }
                var collection = collection; collection.kind = kind; return collection
            }
        }
    }

    /// The libraries of a section go back to the top level.
    func ungroupSection(_ name: String) {
        editLibraryCollections("Ungroup") { collections in
            collections.map { collection in
                guard collection.parent?.localizedCaseInsensitiveCompare(name) == .orderedSame else { return collection }
                var collection = collection; collection.parent = nil; return collection
            }
        }
    }

    func renameLibraryCollection(_ id: String, to title: String) {
        editLibraryCollections("Rename Library") { LibraryEditing.renaming(collection: id, to: title, in: $0) }
    }

    func renameLibraryGroup(_ name: String, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != name else { return }
        editLibraryCollections("Rename Section") { collections in
            collections.map { collection in
                guard collection.parent?.localizedCaseInsensitiveCompare(name) == .orderedSame else { return collection }
                var collection = collection; collection.parent = title; return collection
            }
        }
        if let expanded = paneExpanded.removeValue(forKey: "collection-parent-" + name) { paneExpanded["collection-parent-" + title] = expanded }
    }

    // MARK: Confirmations

    /// Asks before moving to the Trash; ⌘Z or the Trash's Put Back undoes it.
    func confirmTrash(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let names = paths.map { URL(fileURLWithPath: $0).lastPathComponent }
        let alert = NSAlert()
        alert.messageText = names.count == 1 ? "Move “\(names[0])” to the Trash?" : "Move \(names.count) items to the Trash?"
        alert.informativeText = "Lemma keeps your notes and reading positions. Undo (⌘Z) or the Trash’s Put Back restores the files."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        if let window = mainWindow {
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.trashLibraryItems(paths) }
            }
        } else if alert.runModal() == .alertFirstButtonReturn { trashLibraryItems(paths) }
    }

    func confirmRemoveLibrary(_ id: String) {
        guard let collection = libraries.collections.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove the library “\(collection.title)”?"
        alert.informativeText = "Lemma stops listing its PDFs here. The files, your notes and reading positions stay on this Mac, and Undo (⌘Z) brings the library back."
        alert.addButton(withTitle: "Remove Library")
        alert.addButton(withTitle: "Cancel")
        if var window = mainWindow {
            // Library Sources is itself a sheet; presenting on its parent queues the alert behind it.
            while let sheet = window.attachedSheet { window = sheet }
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.removeLibraryCollection(id) }
            }
        } else if alert.runModal() == .alertFirstButtonReturn { removeLibraryCollection(id) }
    }

    /// Asks before moving files on disk by dragging, unless the reader chose not to be asked again.
    func confirmDiskMove(_ paths: [String], into folder: String) {
        let key = "library.confirmDragMove"
        guard !paths.isEmpty else { return }
        if UserDefaults.standard.object(forKey: key) as? Bool == false { moveLibraryItems(paths, intoFolder: folder); return }
        let alert = NSAlert()
        let name = URL(fileURLWithPath: folder).lastPathComponent
        alert.messageText = paths.count == 1 ? "Move “\(URL(fileURLWithPath: paths[0]).lastPathComponent)” into “\(name)”?" : "Move \(paths.count) items into “\(name)”?"
        alert.informativeText = "The files move on disk. Their notes and reading positions follow, and Undo (⌘Z) moves them back."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Do not ask again"
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            if alert.suppressionButton?.state == .on { UserDefaults.standard.set(false, forKey: key) }
            self?.moveLibraryItems(paths, intoFolder: folder)
        }
        if let window = mainWindow { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    // MARK: Choosing sources

    /// Asks for folders or PDFs to add to a library.
    func chooseLibrarySources(_ collectionID: String, folders: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folders; panel.canChooseFiles = !folders
        panel.allowsMultipleSelection = true
        if !folders { panel.allowedContentTypes = [.pdf] }
        panel.message = folders ? "Watch these folders for PDFs, including their subfolders." : "Add these PDFs to the library. They stay where they are."
        guard panel.runModal() == .OK else { return }
        addToLibrary(panel.urls, collectionID: collectionID)
    }
}
