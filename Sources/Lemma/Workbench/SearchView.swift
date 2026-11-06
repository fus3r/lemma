import SwiftUI
import AppKit
import PDFKit
import LemmaCore

/// Full-text search across the library's PDFs, as VS Code searches every file of a workspace: matches grouped by
/// book with the words around them. Runs at utility priority, off the main thread; page texts are kept for the next
/// search of the same books.
@MainActor @Observable
final class LibraryTextSearch {
    struct Hit: Identifiable, Sendable, Equatable {
        let id: String
        let bookID: String
        let pageIndex: Int
        let pageLabel: String
        let range: NSRange
        let before: String
        let match: String
        let after: String
    }
    /// Where a match is in a book: its page and its range in the page's text, as PDFKit's `PDFPage.string` gives it.
    struct PageRange: Sendable, Equatable { let pageIndex: Int; let range: NSRange }
    /// One book's outcome: the matches listed (at most `limit`), whether there were more, whether the book's text
    /// could be read, and, for the book being read, where every match is (at most `markLimit`).
    struct BookMatches: Sendable {
        var hits: [Hit] = []
        var truncated = false
        var readable = true
        var ranges: [PageRange] = []
    }
    struct BookResult: Identifiable, Equatable {
        let id: String
        let title: String
        var hits: [Hit]
        var truncated: Bool
    }
    enum Scope: String, CaseIterable, Identifiable { case book, library
        var id: String { rawValue }
        var label: String { self == .book ? "This Book" : "All Books" }
    }

    var query = ""
    var matchCase = false
    var wholeWord = false
    var scope: Scope = .library
    private(set) var results: [BookResult] = []
    private(set) var isSearching = false
    private(set) var searchedBooks = 0
    private(set) var totalBooks = 0
    /// Books whose text could not be read, which the summary reports rather than counting them as having no matches.
    private(set) var unreadableBooks = 0
    private(set) var lastQuery = ""
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let texts: PageTextCache

    init(cacheFolder: URL? = nil, helper: URL? = BookAnalysisModel.helperURL) { texts = PageTextCache(folder: cacheFolder, helper: helper) }

    var hitCount: Int { results.reduce(0) { $0 + $1.hits.count } }

    /// Searches `books` in order. When `marking` names one of them, `onMarks` receives where all its matches are, so
    /// the reader can show them without asking PDFKit to search the whole book again.
    func run(books: [(id: String, title: String, path: String)], marking: String? = nil,
             onMarks: (@MainActor (String, [PageRange]) -> Void)? = nil) {
        task?.cancel()
        let query = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
        results = []; lastQuery = query; searchedBooks = 0; unreadableBooks = 0; totalBooks = books.count
        guard query.count >= 2 else { isSearching = false; return }
        isSearching = true
        let options = (matchCase, wholeWord)
        let cache = texts
        task = Task { [weak self] in
            for book in books {
                if Task.isCancelled { return }
                // The reading and matching run off the main thread, at utility priority.
                await cache.prepare(id: book.id, path: book.path)
                if Task.isCancelled { return }
                let marks = book.id == marking
                let found = await Task.detached(priority: .utility) {
                    LibraryTextSearch.search(book: book, query: query, matchCase: options.0, wholeWord: options.1, cache: cache, ranges: marks)
                }.value
                guard let self, self.lastQuery == query, !Task.isCancelled else { return }
                self.searchedBooks += 1
                if !found.readable { self.unreadableBooks += 1 }
                if !found.hits.isEmpty { self.results.append(BookResult(id: book.id, title: book.title, hits: found.hits, truncated: found.truncated)) }
                if marks { onMarks?(query, found.ranges) }
            }
            if self?.lastQuery == query { self?.isSearching = false }
        }
    }

    func clear() { task?.cancel(); results = []; query = ""; lastQuery = ""; unreadableBooks = 0; isSearching = false }

    /// Finds `query` in the book's page texts. Lists at most `limit` matches; with `ranges`, also notes where every
    /// match is, up to `markLimit` (the minimap and the overview ruler draw at most that many).
    nonisolated static func search(book: (id: String, title: String, path: String), query: String, matchCase: Bool, wholeWord: Bool,
                                   cache: PageTextCache, limit: Int = 200, ranges: Bool = false, markLimit: Int = 2000) -> BookMatches {
        var outcome = BookMatches()
        guard let pages = cache.pages(for: book.id, path: book.path) else { outcome.readable = false; return outcome }
        var options: NSString.CompareOptions = [.diacriticInsensitive]
        if !matchCase { options.insert(.caseInsensitive) }
        for (pageIndex, page) in pages.enumerated() {
            let text = page.text as NSString
            var searchRange = NSRange(location: 0, length: text.length)
            while searchRange.length > 0 {
                let found = text.range(of: query, options: options, range: searchRange)
                guard found.location != NSNotFound else { break }
                searchRange = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
                if wholeWord {
                    let before = found.location > 0 ? text.character(at: found.location - 1) : 32
                    let after = NSMaxRange(found) < text.length ? text.character(at: NSMaxRange(found)) : 32
                    if isWordCharacter(before) || isWordCharacter(after) { continue }
                }
                if ranges, outcome.ranges.count < markLimit { outcome.ranges.append(PageRange(pageIndex: pageIndex, range: found)) }
                if outcome.hits.count >= limit {
                    outcome.truncated = true
                    if !ranges || outcome.ranges.count >= markLimit { return outcome }
                    continue
                }
                let start = max(0, found.location - 48), end = min(text.length, NSMaxRange(found) + 72)
                func clean(_ string: String) -> String { string.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: " ") }
                outcome.hits.append(Hit(id: "\(book.id)#\(pageIndex)#\(found.location)", bookID: book.id, pageIndex: pageIndex, pageLabel: page.label, range: found,
                                        before: clean(text.substring(with: NSRange(location: start, length: found.location - start))),
                                        match: text.substring(with: found),
                                        after: clean(text.substring(with: NSRange(location: NSMaxRange(found), length: end - NSMaxRange(found))))))
            }
        }
        return outcome
    }

    nonisolated private static func isWordCharacter(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }
}

/// Each book's page texts and printed labels for search: kept in memory for a handful of books, and on disk beside
/// the book's analysis (`Indexes/<fingerprint>/pagetext.json`) so the next session's first search is immediate.
/// The packaged app reads a book's text in the `LemmaIndexer` helper: PDFKit's text extraction can take hundreds of
/// megabytes for a long book, which the helper gives back when it exits and the reader never holds.
final class PageTextCache: @unchecked Sendable {
    typealias Page = PageText
    private let lock = NSLock()
    private var books: [String: [Page]] = [:]
    private var order: [String] = []
    private var reading: [String: Task<Void, Never>] = [:]
    /// Books the helper could not read this session, not tried again until the next launch.
    private var failed: Set<String> = []
    let folder: URL?
    /// The helper that reads PDFs out of process; nil reads them here (tests, `swift run`).
    let helper: URL?

    init(folder: URL? = nil, helper: URL? = BookAnalysisModel.helperURL) { self.folder = folder; self.helper = helper }

    private func file(for id: String) -> URL? {
        folder?.appendingPathComponent(id, isDirectory: true).appendingPathComponent(PageTextFile.name)
    }

    /// Has the helper write the book's page texts unless they are already at hand. One reading per book at a time:
    /// a new query while a book is being read waits for that reading.
    func prepare(id: String, path: String) async {
        guard let helper, let file = file(for: id) else { return }
        if lock.withLock({ books[id] != nil || failed.contains(id) }) || FileManager.default.fileExists(atPath: file.path) { return }
        let task: Task<Void, Never> = lock.withLock {
            if let running = reading[id] { return running }
            let task = Task.detached(priority: .utility) { await Self.read(path, into: file, helper: helper) }
            reading[id] = task
            return task
        }
        await task.value
        let written = FileManager.default.fileExists(atPath: file.path)
        lock.withLock {
            reading.removeValue(forKey: id)
            if !written { failed.insert(id) }
        }
    }

    private static func read(_ path: String, into file: URL, helper: URL) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let process = Process()
            process.executableURL = helper
            process.arguments = ["--pagetext", path, "--output", file.path]
            process.qualityOfService = .utility
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume() }
        }
    }

    /// The book's pages, or nil when its text could not be read (the helper stopped on a malformed PDF, say).
    func pages(for id: String, path: String) -> [Page]? {
        if let cached = lock.withLock({ books[id] }) { return cached }
        let file = file(for: id)
        var pages = file.flatMap(PageTextFile.read)
        if pages == nil, helper == nil {
            pages = PageTextFile.extract(source: URL(fileURLWithPath: path))
            if let pages, let file { try? PageTextFile.write(pages, to: file) }
        }
        guard let pages else { return nil }
        lock.withLock {
            books[id] = pages; order.append(id)
            // A handful of books' texts are kept in memory; the others are read again from disk.
            if order.count > 12 { books.removeValue(forKey: order.removeFirst()) }
        }
        return pages
    }
}

@MainActor
extension StudyStore {
    func runLibrarySearch() {
        let search = librarySearch
        let books: [StudyWorkspace] = search.scope == .book ? (workspace.map { [$0] } ?? []) : library
        let current = workspace?.id
        if current != nil { reader.resetSearch() }
        // The current book's matches also mark the minimap and the overview ruler. They come from the search's own
        // page texts, so PDFKit only lays out the pages that have a match rather than searching the whole book again.
        search.run(books: books.filter { FileManager.default.fileExists(atPath: $0.sourcePath) }.map { ($0.id, $0.title, $0.sourcePath) },
                   marking: current) { [weak self] query, ranges in
            guard let self, self.workspace?.id == current else { return }
            self.reader.showMatches(ranges.map { ($0.pageIndex, $0.range) }, for: query)
        }
    }

    /// Opens a match: its book, its page, the words selected.
    func openSearchHit(_ hit: LibraryTextSearch.Hit) {
        // The retained book may be behind a text file: selecting its result also brings its PDF tab forward.
        openBook(hit.bookID)
        let select = { [weak self] in
            guard let self, self.workspace?.id == hit.bookID, let page = self.document?.page(at: hit.pageIndex), let view = self.reader.view else { return }
            if let selection = page.selection(for: hit.range) {
                view.setCurrentSelection(selection, animate: true)
                view.go(to: selection)
                self.reader.updateSelection()
            } else { self.reader.goToPage(hit.pageIndex + 1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { MainActor.assumeIsolated { select() } }
    }
}

/// VS Code's Search view for books: the query with its options, the scope, then matches grouped by book.
struct VSSearchView: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme
    @State private var collapsed: Set<String> = []
    @State private var mode: Mode = .text

    enum Mode: String, CaseIterable { case text, notes, pages
        var label: String { switch self { case .text: "Text"; case .notes: "Notes"; case .pages: "Indexed Pages" } }
    }

    var body: some View {
        let search = store.librarySearch
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Mode.allCases, id: \.self) { option in
                    InspectorTitleTab(title: option.label, active: mode == option) { mode = option }
                }
                Spacer()
            }.frame(height: 26).padding(.leading, 6)
            switch mode {
            case .text: textSearch(search)
            case .notes: NavigatorPane(store: store, section: .search, showsHeader: false).onAppear { store.searchNotes = true; store.searchIndexed = false }
            case .pages: NavigatorPane(store: store, section: .search, showsHeader: false).onAppear { store.searchIndexed = true; store.searchNotes = false }
            }
        }
    }

    @ViewBuilder private func textSearch(_ search: LibraryTextSearch) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VSTextField(placeholder: "Search", text: Binding(get: { search.query }, set: { search.query = $0 }), icon: nil,
                        onSubmit: { store.runLibrarySearch() },
                        trailing: AnyView(HStack(spacing: 1) {
                            VSInputOption(icon: "case-sensitive", help: "Match Case", isOn: Binding(get: { search.matchCase }, set: { search.matchCase = $0; store.runLibrarySearch() }))
                            VSInputOption(icon: "whole-word", help: "Match Whole Word", isOn: Binding(get: { search.wholeWord }, set: { search.wholeWord = $0; store.runLibrarySearch() }))
                        }))
            HStack(spacing: 6) {
                Text("in").font(.ui(12)).foregroundStyle(theme[.descriptionForeground])
                VSDropdown(options: LibraryTextSearch.Scope.allCases.map { ($0, $0.label) },
                           selection: Binding(get: { search.scope }, set: { search.scope = $0; if !search.query.isEmpty { store.runLibrarySearch() } }), width: 130)
                Spacer()
                if search.isSearching { ProgressView().controlSize(.small) }
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
        if search.isSearching { VSProgressLine() }
        if !search.lastQuery.isEmpty {
            Text(summary(search)).font(.ui(12)).foregroundStyle(theme[.descriptionForeground]).padding(.horizontal, 20).padding(.vertical, 4)
        }
        if search.lastQuery.isEmpty {
            VSWelcomeView(message: "Search the text of the book in front, or of every book in your library, as VS Code searches a workspace. Press Return to search.") { EmptyView() }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(search.results) { book in
                        VSRow(action: { toggle(book.id) }) {
                            VSTwistie(expandable: true, expanded: !collapsed.contains(book.id)) { toggle(book.id) }
                            FileIcon(kind: "file-pdf").padding(.trailing, 6)
                            Text(book.title).font(.ui(13)).lineLimit(1)
                            Spacer(minLength: 4)
                            VSBadge(count: book.hits.count)
                        }
                        if !collapsed.contains(book.id) {
                            ForEach(book.hits) { hit in
                                VSRow(depth: 3, action: { store.openSearchHit(hit) }) {
                                    (Text(Self.lead(hit.before)).foregroundColor(theme[.foreground].opacity(0.8))
                                     + Text(hit.match).bold().foregroundColor(theme[.listHighlightForeground])
                                     + Text(hit.after).foregroundColor(theme[.foreground].opacity(0.8)))
                                        .font(.ui(13)).lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text("p. \(hit.pageLabel)").font(.ui(12)).monospacedDigit().foregroundStyle(theme[.descriptionForeground])
                                }
                                .help("\(hit.before)\(hit.match)\(hit.after)")
                            }
                            if book.truncated {
                                Text("Showing the first \(book.hits.count) matches").font(.ui(12)).foregroundStyle(theme[.descriptionForeground]).padding(.leading, 40)
                            }
                        }
                    }
                }
            }
        }
    }

    private func toggle(_ id: String) { if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) } }

    /// A few words before the match, so the match itself stays visible in a narrow side bar (as VS Code trims them).
    static func lead(_ before: String) -> String {
        // Only the start is trimmed: the space just before the match separates it from the word before.
        let trimmed = String(before.drop(while: \.isWhitespace))
        guard trimmed.count > 14 else { return trimmed }
        let tail = trimmed.suffix(14)
        if let space = tail.firstIndex(of: " "), space < tail.index(before: tail.endIndex) { return "…" + tail[space...] }
        return "…" + tail
    }

    private func summary(_ search: LibraryTextSearch) -> String {
        let books = search.results.count
        if search.isSearching { return "\(search.hitCount) results so far · searched \(search.searchedBooks) of \(search.totalBooks) books" }
        let unreadable = search.unreadableBooks == 0 ? "" : " · \(search.unreadableBooks) \(search.unreadableBooks == 1 ? "book" : "books") could not be read"
        if search.hitCount == 0 { return "No results for “\(search.lastQuery)”" + (search.scope == .book ? " in this book." : " in \(search.totalBooks) books.") + unreadable }
        return "\(search.hitCount) \(search.hitCount == 1 ? "result" : "results") in \(books) \(books == 1 ? "book" : "books")" + unreadable
    }
}
