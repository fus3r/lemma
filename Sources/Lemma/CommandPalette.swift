import SwiftUI
import AppKit
import PDFKit
import LemmaCore

/// One row of the command palette or Go to list.
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    var detail = ""
    var symbol: String
    var category: String
    var shortcut: String?
    var perform: @MainActor () -> Void
    /// Opens the destination in the secondary editor instead (⌥↩).
    var openToSide: (@MainActor () -> Void)?
    /// A separator above the row, labelled on the right as VS Code labels “recently used” or “dark themes”.
    var separator: String? = nil
    /// A colour theme the row previews while it is selected.
    var previewThemeID: String? = nil
}

/// Builds palette rows. Go to understands printed pages (“124”, “pdf 143”), labels (“(3.41)”, “fig 3.8”, “ex 2.8”, “3.4.1”),
/// and otherwise searches sections, numbered objects, the book's index, notes, books and commands.
@MainActor
struct PaletteProvider {
    let store: StudyStore

    /// The rows for `query`. Each call gathers and folds the candidates again: a palette that stays open keeps a
    /// `PaletteSession`, which does that once.
    func items(mode: PaletteMode, query raw: String) -> [PaletteItem] { PaletteSession(store: store).items(mode: mode, query: raw) }

    // MARK: Colour themes

    /// Every theme, grouped light, dark and high contrast as VS Code's picker groups them; the selected row is previewed.
    func themeItems(_ query: String) -> [PaletteItem] {
        let manager = ThemeManager.shared
        var items: [PaletteItem] = []
        if query.isEmpty, let label = manager.vscodeThemeLabel {
            items.append(PaletteItem(id: "theme-vscode", title: "Use My VS Code Theme: \(label)", symbol: "", category: "",
                                     perform: { [store] in
                                         do { if try manager.useVSCodeTheme() == nil { store.notify("Lemma could not find VS Code's theme “\(label)”.", severity: .warning, source: "Color Theme") } }
                                         catch { store.notify("Could not use VS Code's theme: \(error.localizedDescription)", severity: .error, source: "Color Theme") }
                                     }, previewThemeID: manager.vscodeThemeID))
        }
        let groups: [(String, (ThemeEntry) -> Bool)] = [
            ("light themes", { $0.kind == .light }), ("dark themes", { $0.kind == .dark }), ("high contrast themes", { $0.kind.isHighContrast })
        ]
        for (label, filter) in groups {
            var entries = manager.entries.filter(filter)
            if !query.isEmpty {
                entries = entries.compactMap { entry in Self.score(entry.label, query).map { (entry, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
            }
            for (offset, entry) in entries.enumerated() {
                let group = entry.group == "VS Code" ? "" : entry.group
                items.append(PaletteItem(id: "theme-\(entry.id)", title: entry.label, detail: group, symbol: "", category: "",
                                         perform: { manager.choose(entry.id) }, separator: offset == 0 ? label : nil, previewThemeID: entry.id))
            }
        }
        items.append(PaletteItem(id: "theme-install", title: "Install Color Theme from File…", detail: ".json or .vsix", symbol: "", category: "",
                                 perform: { [store] in store.installThemeFromFile() }, separator: "more"))
        return items
    }

    // MARK: Explicit forms
    private func projectItems() -> [PaletteItem] {
        store.activeProjects.map { project in
            PaletteItem(id: "project-\(project.id)", title: project.title, detail: project.question,
                symbol: "folder", category: "Project", perform: { [store] in store.openProject(project.id) })
        }
    }

    private static let labelled = try! NSRegularExpression(pattern: #"^(fig(?:ure)?s?|tab(?:le)?s?|alg(?:orithm)?s?|ex(?:ercise)?s?|eqs?|equations?|sec(?:tion)?s?|§|ch(?:apter)?s?|thm|theorem|lemma|prop(?:osition)?|cor(?:ollary)?|def(?:inition)?)\.?\s*\(?(\d+(?:\.\d+)*[a-z]?)\)?$"#, options: .caseInsensitive)
    private static let bareLabel = try! NSRegularExpression(pattern: #"^\(?(\d+(?:\.\d+)+[a-z]?)\)?$"#)

    func explicit(_ query: String) -> [PaletteItem] {
        var items: [PaletteItem] = []
        let string = query as NSString, whole = NSRange(location: 0, length: string.length)
        // “64:12”: page 64, line 12, as an editor's “file:line”.
        if let colon = query.firstIndex(of: ":"), let line = Int(query[query.index(after: colon)...].trimmingCharacters(in: .whitespaces)), line >= 1,
           let index = store.pageIndex(forTyped: String(query[..<colon])) {
            let page = store.printedLabel(for: index) ?? String(index + 1)
            items.append(PaletteItem(id: "line-\(index)-\(line)", title: "Go to line \(line) of page \(page)", detail: "PDF page \(index + 1)", symbol: "text.line.first.and.arrowtriangle.forward",
                                     category: "Line", perform: { [store] in store.reader.goToLine(line - 1, onPage: index) }))
        }
        if let index = store.pageIndex(forTyped: query), Int(query.filter(\.isNumber)) != nil || query.lowercased().hasPrefix("p") {
            items.append(pageItem(index))
        }
        if let match = Self.labelled.firstMatch(in: query, range: whole) {
            let word = string.substring(with: match.range(at: 1)).lowercased(), number = string.substring(with: match.range(at: 2))
            let kinds: [ReferenceKind]
            switch word.prefix(2) {
            case "fi": kinds = [.figure]
            case "ta": kinds = [.table]
            case "al": kinds = [.algorithm]
            case "ex": kinds = [.exercise]
            case "eq": kinds = [.equation]
            case "se", "§": kinds = [.section]
            case "ch": kinds = [.chapter]
            default: kinds = [.theorem]
            }
            items += objectItems(number: number, kinds: kinds)
        } else if let match = Self.bareLabel.firstMatch(in: query, range: whole) {
            let number = string.substring(with: match.range(at: 1))
            items += objectItems(number: number, kinds: query.hasPrefix("(") ? [.equation] : [.equation, .section, .figure, .table, .algorithm, .exercise])
        }
        return items
    }

    private func objectItems(number: String, kinds: [ReferenceKind]) -> [PaletteItem] {
        var items: [PaletteItem] = []
        for kind in kinds {
            if kind == .section || kind == .chapter {
                let entries = store.outline.flatMap(\.flattened).filter { OutlineMap.numberPrefix(of: $0.title) == number }
                items += entries.prefix(1).map(sectionItem)
                continue
            }
            let targets = (store.analysis?.analysis?.definitions ?? []).filter { $0.key.kind == kind && $0.key.number == number }
            if let target = targets.first { items.append(symbolItem(target)) }
        }
        return items
    }

    // MARK: Item factories

    private func pageItem(_ index: Int) -> PaletteItem {
        let printed = store.printedLabel(for: index)
        return PaletteItem(id: "page-\(index)", title: printed.map { "Go to page \($0)" } ?? "Go to PDF page \(index + 1)",
                           detail: printed != nil ? "PDF page \(index + 1)" : "", symbol: "doc.text", category: "Page",
                           perform: { [store] in store.reader.goToPage(index + 1) },
                           openToSide: { [store] in store.openToSide(page: index) })
    }

    private func sectionItem(_ entry: OutlineEntry) -> PaletteItem {
        let store = store
        let detail: String = entry.pageIndex.map { store.shortPageText($0) } ?? ""
        var side: (@MainActor () -> Void)?
        if let page = entry.pageIndex { side = { store.openToSide(page: page, title: entry.title) } }
        return PaletteItem(id: "section-\(entry.id)", title: entry.title, detail: detail, symbol: "list.bullet.indent", category: "Section",
                           perform: { store.go(to: entry) }, openToSide: side)
    }

    func sectionItems() -> [PaletteItem] { store.outline.flatMap(\.flattened).map(sectionItem) }

    private func symbolItem(_ target: ReferenceTarget) -> PaletteItem {
        let count = store.analysis?.mentionCounts[target.key] ?? 0
        let section = store.references.flatMap { OutlineMap.section(containing: target.pageIndex, y: target.anchor.rect.maxY, in: $0.outline)?.title }
        return PaletteItem(id: Self.symbolID(target), title: target.key.spokenTitle,
                           detail: [store.shortPageText(target.pageIndex), section, count > 0 ? "\(count) \(count == 1 ? "reference" : "references")" : nil].compactMap { $0 }.joined(separator: " · "),
                           symbol: target.key.kind.symbol, category: target.key.kind.label,
                           perform: { [store] in store.goToReference(target) },
                           openToSide: { [store] in store.openToSide(target) })
    }

    func symbolItems() -> [PaletteItem] { symbolCandidates().map { $0.make() } }

    /// Numbered objects in reading order. A row's detail (its page, section and reference count) is worked out only
    /// when the row is listed: finding the section of each of a book's thousand equations took most of a keystroke.
    func symbolCandidates() -> [PaletteCandidate] {
        guard let analysis = store.analysis?.analysis else { return [] }
        var seen = Set<ReferenceKey>()
        return analysis.definitions.filter { $0.key.kind != .section && seen.insert($0.key).inserted }
            .sorted { $0.pageIndex == $1.pageIndex ? $0.anchor.y > $1.anchor.y : $0.pageIndex < $1.pageIndex }
            .map { target in PaletteCandidate(id: Self.symbolID(target), title: target.key.spokenTitle) { symbolItem(target) } }
    }

    private static func symbolID(_ target: ReferenceTarget) -> String {
        "symbol-\(target.key.kind.rawValue)-\(target.key.number)-\(target.key.name ?? "")"
    }

    func sectionCandidates() -> [PaletteCandidate] {
        store.outline.flatMap(\.flattened).map { entry in PaletteCandidate(id: "section-\(entry.id)", title: entry.title) { sectionItem(entry) } }
    }

    /// The book's index entries for the query, over the index folded once (`LibraryGlossary.prepared`).
    func indexCandidates(_ query: String) -> [PaletteCandidate] {
        guard let id = store.workspace?.id, let analysis = store.analysis?.analysis, !analysis.index.isEmpty else { return [] }
        let index = store.libraryGlossary.prepared(analysis, id: id).index
        return BookIndexSearch.find(query, in: index, limit: 6).map { match in
            let entry = match.entry
            let pages = entry.locators.prefix(4).map(\.text).joined(separator: ", ") + (entry.locators.count > 4 ? "…" : "")
            return PaletteCandidate(item: PaletteItem(id: "index-\(entry.id)", title: entry.title,
                                                      detail: entry.see.isEmpty ? "Index · p. \(pages)" : "Index · see \(entry.see.joined(separator: "; "))",
                                                      symbol: "character.book.closed", category: "Index",
                                                      perform: { [store] in store.openIndexEntry(entry) }))
        }
    }

    /// Terms the book introduces in italic or bold: Return goes to the defining sentence.
    func termCandidates() -> [PaletteCandidate] {
        (store.analysis?.analysis?.terms ?? []).map { term in
            PaletteCandidate(id: "term-\(term.term)", title: term.surface) { [store] in
                PaletteItem(id: "term-\(term.term)", title: term.surface,
                            detail: "\(term.definitional ? "Defined" : "Introduced") · \(store.shortPageText(term.pageIndex))",
                            symbol: "text.book.closed", category: "Term",
                            perform: { store.goToDefinedTerm(term) },
                            openToSide: { store.goToDefinedTerm(term, side: true) })
            }
        }
    }

    func noteCandidates() -> [PaletteCandidate] {
        (store.workspace?.notes ?? []).map { note in
            PaletteCandidate(id: "note-\(note.id)", title: note.title) { [store] in
                PaletteItem(id: "note-\(note.id)", title: note.title, detail: "\(note.kind.label) · \(store.shortPageText(note.anchor.pageIndex))",
                            symbol: note.kind.symbol, category: "Note",
                            perform: { store.selectNote(note.id); store.reader.go(to: note.anchor) })
            }
        }
    }

    /// Studied books, then the libraries' PDFs not opened yet (by their keys from the scan: nothing asks the disk).
    func bookCandidates() -> [PaletteCandidate] {
        let current = store.workspace?.id
        let opened = store.library.map { book in
            PaletteCandidate(id: "book-\(book.id)", title: book.title) { [store] in
                PaletteItem(id: "book-\(book.id)", title: book.title, detail: book.id == current ? "Open" : "Library",
                            symbol: "book.closed", category: "Book", perform: { store.openBook(book.id) })
            }
        }
        let libraries = store.libraries
        let known = Set(store.library.map { libraries.key(of: $0.sourcePath) })
        let discovered = libraries.entries.filter { !known.contains($0.key) }.map { entry in
            let title = libraries.titles[entry.key] ?? entry.title
            return PaletteCandidate(id: "library-" + entry.id, title: title) { [store] in
                PaletteItem(id: "library-" + entry.id, title: title,
                            detail: libraries.collections.first { $0.id == entry.collectionID }?.displayTitle ?? entry.folder,
                            symbol: "doc.richtext", category: "PDF") { store.openLibraryPDF(entry) }
            }
        }
        return opened + discovered
    }

    func projectCandidates() -> [PaletteCandidate] { projectItems().map(PaletteCandidate.init(item:)) }

    func fileCandidates() -> [PaletteCandidate] {
        store.workspaceFiles.map { name in
            PaletteCandidate(id: StudyStore.fileTabID(name), title: name) { [store] in
                PaletteItem(id: StudyStore.fileTabID(name), title: name, detail: "Workspace Files", symbol: "doc.text", category: "File") {
                    store.openWorkspaceFile(name)
                }
            }
        }
    }

    /// With nothing typed: open books, then the sections around the reading position and recent notes.
    func suggestions(notes: [PaletteCandidate], books: [PaletteCandidate]) -> [PaletteItem] {
        var items: [PaletteItem] = fileCandidates().prefix(6).map { $0.make() }
        if let current = store.breadcrumb().last, let siblings = siblings(of: current) { items += siblings.map(sectionItem) }
        items += notes.prefix(5).map { $0.make() }
        items += projectItems().prefix(3)
        let open = "book-\(store.workspace?.id ?? "")"
        items += books.lazy.filter { $0.id != open }.prefix(4).map { $0.make() }
        return items
    }

    private func siblings(of entry: OutlineEntry) -> [OutlineEntry]? {
        func search(_ entries: [OutlineEntry]) -> [OutlineEntry]? {
            if entries.contains(where: { $0.id == entry.id }) { return entries }
            for child in entries { if let found = search(child.children ?? []) { return found } }
            return nil
        }
        return search(store.outline).map { Array($0.prefix(12)) }
    }

    // MARK: Ranking

    static func score(_ candidate: String, _ query: String) -> Int? { score(PaletteMatchKey(candidate), PaletteQuery(query)) }

    /// Lower is better: exact, prefix, word prefix, substring, every word a word prefix (“lin reg”), then, for short
    /// queries only, initials in order (“lar” for Least Angle Regression). Both sides come folded already.
    static func score(_ key: PaletteMatchKey, _ query: PaletteQuery) -> Int? {
        let text = key.text, needle = query.needle
        guard !needle.isEmpty else { return 0 }
        if text == needle { return 0 }
        if text.hasPrefix(needle) { return 1 }
        if text.contains(query.afterSpace) || text.contains(query.afterParenthesis) || text.contains(query.afterChevron) { return 2 }
        if text.contains(needle) { return 3 }
        if query.parts.count > 1, query.parts.allSatisfy({ part in key.words.contains { $0.hasPrefix(part) } }) { return 4 }
        if query.byInitials {
            var remaining = key.initials[...]
            for character in needle {
                guard let index = remaining.firstIndex(of: character) else { return nil }
                remaining = remaining[remaining.index(after: index)...]
            }
            return 5
        }
        return nil
    }
}

/// A title in the form the palette compares: folded once (case, accents, ligatures, dashes), with its words and
/// their initials.
struct PaletteMatchKey: Sendable {
    let text: String
    let words: [String]
    let initials: String
    init(_ title: String) {
        text = TextRepair.folded(title)
        words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        initials = String(words.compactMap(\.first))
    }
}

/// What is typed, folded once per keystroke.
struct PaletteQuery: Sendable {
    let needle: String
    let parts: [String]
    let afterSpace: String, afterParenthesis: String, afterChevron: String
    /// Short single words also match initials in order.
    let byInitials: Bool
    init(_ query: String) {
        needle = TextRepair.folded(query)
        parts = needle.split(separator: " ").map(String.init)
        afterSpace = " " + needle; afterParenthesis = "(" + needle; afterChevron = "›" + needle
        byInitials = needle.count <= 4 && !needle.contains(" ")
    }
}

/// A row the palette may list: ranked by its folded title, and built in full only when listed.
struct PaletteCandidate {
    let id: String
    let title: String
    let length: Int
    let key: PaletteMatchKey
    let make: @MainActor () -> PaletteItem

    init(id: String, title: String, make: @escaping @MainActor () -> PaletteItem) {
        self.id = id; self.title = title; self.make = make
        length = title.count
        key = PaletteMatchKey(title)
    }

    init(item: PaletteItem) { self.init(id: item.id, title: item.title) { item } }
}

/// One opening of the palette: each kind of candidate is gathered and folded the first time it is needed, and every
/// keystroke after that only ranks. (The palette used to gather, fold and rank everything again at each keystroke,
/// arrow key and pointer move.)
@MainActor
final class PaletteSession {
    let provider: PaletteProvider
    init(store: StudyStore) { provider = PaletteProvider(store: store) }

    private lazy var commands: [PaletteCandidate] = provider.store.commandCatalog().map(PaletteCandidate.init(item:))
    private lazy var symbols: [PaletteCandidate] = provider.symbolCandidates()
    private lazy var sections: [PaletteCandidate] = provider.sectionCandidates()
    private lazy var terms: [PaletteCandidate] = provider.termCandidates()
    private lazy var notes: [PaletteCandidate] = provider.noteCandidates()
    private lazy var books: [PaletteCandidate] = provider.bookCandidates()
    private lazy var projects: [PaletteCandidate] = provider.projectCandidates()
    private lazy var files: [PaletteCandidate] = provider.fileCandidates()

    /// Gathers what typing will search, right after the palette appears rather than at the first keystroke.
    func prepare(mode: PaletteMode) {
        switch mode {
        case .goTo: _ = (terms, symbols, sections, notes, books, projects, commands, files)
        case .commands: _ = commands
        case .symbols: _ = symbols
        case .themes: break
        }
    }

    func items(mode: PaletteMode, query raw: String) -> [PaletteItem] {
        let query = raw.trimmingCharacters(in: .whitespaces)
        if mode == .themes { return provider.themeItems(query) }
        if mode == .commands || query.hasPrefix(">") {
            let text = query.hasPrefix(">") ? String(query.dropFirst()).trimmingCharacters(in: .whitespaces) : query
            guard text.isEmpty else { return ranked(commands, query: text, limit: 80) }
            // As VS Code does: recently used commands first, then the others.
            let all = commands.map { $0.make() }
            let recent = PaletteHistory.recent.compactMap { id in all.first { $0.id == id } }
            var items = recent.enumerated().map { offset, item in var copy = item; if offset == 0 { copy.separator = "recently used" }; return copy }
            let recentIDs = Set(recent.map(\.id))
            let others = all.filter { !recentIDs.contains($0.id) }
            items += others.enumerated().map { offset, item in var copy = item; if offset == 0 && !recent.isEmpty { copy.separator = "other commands" }; return copy }
            return items
        }
        if mode == .symbols || query.hasPrefix("@") {
            return ranked(symbols, query: query.hasPrefix("@") ? String(query.dropFirst()) : query, limit: 80)
        }
        guard !query.isEmpty else { return provider.suggestions(notes: notes, books: books) }
        var items = provider.explicit(query)
        let seen = Set(items.map(\.id))
        let prepared = PaletteQuery(query)
        // One ranking across kinds: the closest title wins; on ties, index terms and numbered objects come before notes and commands.
        var scored: [(item: PaletteItem, score: Int, weight: Int, length: Int)] = []
        func add(_ candidates: [PaletteCandidate], weight: Int, limit: Int) {
            var kept: [(candidate: PaletteCandidate, score: Int)] = []
            for candidate in candidates where !seen.contains(candidate.id) {
                if let score = PaletteProvider.score(candidate.key, prepared) { kept.append((candidate, score)) }
            }
            kept.sort { $0.score == $1.score ? $0.candidate.length < $1.candidate.length : $0.score < $1.score }
            scored += kept.prefix(limit).map { ($0.candidate.make(), $0.score, weight, $0.candidate.length) }
        }
        add(provider.indexCandidates(query), weight: 0, limit: 6)
        add(terms, weight: 0, limit: 4)
        add(symbols, weight: 1, limit: 6)
        add(sections, weight: 1, limit: 8)
        add(notes, weight: 2, limit: 6)
        add(files, weight: 2, limit: 8)
        add(books, weight: 3, limit: 4)
        add(projects, weight: 2, limit: 4)
        add(commands, weight: 4, limit: 4)
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            if lhs.weight != rhs.weight { return lhs.weight < rhs.weight }
            return lhs.length < rhs.length
        }
        items += scored.map(\.item)
        return items
    }

    private func ranked(_ candidates: [PaletteCandidate], query: String, limit: Int) -> [PaletteItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return candidates.prefix(limit).map { $0.make() } }
        let prepared = PaletteQuery(query)
        var scored: [(candidate: PaletteCandidate, score: Int)] = []
        for candidate in candidates { if let score = PaletteProvider.score(candidate.key, prepared) { scored.append((candidate, score)) } }
        scored.sort { lhs, rhs in lhs.score == rhs.score ? lhs.candidate.length < rhs.candidate.length : lhs.score < rhs.score }
        return scored.prefix(limit).map { $0.candidate.make() }
    }
}

/// Recently run commands, most recent first, as VS Code remembers them.
enum PaletteHistory {
    private static let key = "palette.recentCommands"
    static var recent: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func record(_ id: String) {
        var list = recent.filter { $0 != id }
        list.insert(id, at: 0)
        UserDefaults.standard.set(Array(list.prefix(8)), forKey: key)
    }
}

/// VS Code's quick input: 600 pt wide at most, 6 pt from the top over the title bar, a filter box, 22 pt rows with
/// matched characters in bold, separators labelled on the right and key caps for shortcuts. The rows are worked out
/// when the text changes and kept: arrow keys and the pointer only move the selection and the hover.
struct CommandPaletteView: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme
    let request: PaletteRequest
    @State private var text: String
    @State private var selection = 0
    @State private var items: [PaletteItem] = []
    @State private var session: PaletteSession?

    init(store: StudyStore, request: PaletteRequest) {
        self.store = store; self.request = request
        _text = State(initialValue: request.mode == .commands && request.text.isEmpty ? "" : request.text)
    }

    /// Ranks the candidates for the text; the session gathers and folds them once per opening.
    private func refresh() {
        let session = self.session ?? PaletteSession(store: store)
        if self.session == nil { self.session = session }
        items = session.items(mode: request.mode, query: text)
    }

    private var placeholder: String {
        switch request.mode {
        case .commands: "Type the name of a command to run."
        case .symbols: "Go to an equation, figure, table, algorithm, exercise or statement"
        case .themes: "Select Color Theme (Up/Down Keys to Preview)"
        case .goTo: store.document == nil ? "Search files and books, or type > for commands" : "Search files, pages (64), labels ((3.41), fig 3.8), lines (64:12), terms, notes · > commands · @ symbols"
        }
    }

    var body: some View {
        let items = items
        let query = text.hasPrefix(">") || text.hasPrefix("@") ? String(text.dropFirst()) : text
        GeometryReader { geometry in
            let width = min(600, geometry.size.width * 0.62)
            VStack(spacing: 0) {
                if request.mode == .themes {
                    Text("Select Color Theme").font(.ui(13)).foregroundStyle(theme[.quickInputForeground])
                        .frame(maxWidth: .infinity).padding(.vertical, 3)
                        .background(theme.has(.quickInputTitleBackground) ? theme[.quickInputTitleBackground] : .clear)
                }
                HStack(spacing: 6) {
                    PaletteField(text: $text, placeholder: placeholder, prefix: request.mode == .commands ? ">" : "",
                                 onMove: { delta in move(delta, items: items) },
                                 onSubmit: { side in run(items, side: side) },
                                 onCancel: { store.closePalette() })
                        .frame(height: 20)
                    if !text.isEmpty || request.mode == .commands {
                        Text("\(items.count) results").font(.ui(11)).foregroundStyle(theme[.badgeForeground])
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 2).fill(theme[.badgeBackground]))
                            .opacity(items.isEmpty ? 0 : 1)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme[.inputBackground]))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme[.focusBorder], lineWidth: 1))
                .padding(.top, 6).padding(.horizontal, 6).padding(.bottom, 4)
                if items.isEmpty {
                    Text(emptyMessage).font(.ui(13)).foregroundStyle(theme[.descriptionForeground])
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 11).padding(.vertical, 5).padding(.bottom, 4)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                                    PaletteRow(item: item, offset: offset, query: query, selected: offset == selection) {
                                        selection = offset; run(items, side: NSEvent.modifierFlags.contains(.option))
                                    }
                                    .id(offset)
                                }
                            }.padding(.horizontal, 6).padding(.bottom, 7)
                        }
                        .frame(maxHeight: min(CGFloat(items.count) * 22 + CGFloat(items.filter { $0.separator != nil }.count) * 1 + 8, 440))
                        .onChange(of: selection) { _, value in
                            proxy.scrollTo(value)
                            preview(items, value)
                        }
                    }
                }
            }
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme[.quickInputBackground]))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border(.widgetBorder), lineWidth: theme.isHighContrast ? 1 : 0))
            .shadow(color: .black.opacity(0.15), radius: 10)
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
        }
        .onChange(of: text) { _, _ in refresh(); selection = 0; preview(self.items, 0) }
        .onAppear {
            refresh()
            if request.mode == .themes, let index = self.items.firstIndex(where: { $0.previewThemeID == ThemeManager.shared.effectiveID && $0.id != "theme-vscode" }) {
                selection = index
            }
        }
        .task {
            // Once the palette is on screen, gather what typing will search, so the first keystroke only ranks.
            try? await Task.sleep(for: .milliseconds(40))
            session?.prepare(mode: request.mode)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(request.mode == .commands ? "Command palette" : request.mode == .themes ? "Color theme picker" : "Go to")
    }

    private var emptyMessage: String {
        if store.document == nil && request.mode == .goTo { return "No matching files, books or commands." }
        if request.mode == .symbols && store.analysis?.analysis == nil { return store.analysis?.isAnalyzing == true ? "Lemma is still reading this book…" : "No numbered objects found yet." }
        if request.mode == .commands { return "No matching commands" }
        return "No matching results. Try a page number, “(3.41)”, “fig 3.8” or a term from the index."
    }

    private func preview(_ items: [PaletteItem], _ index: Int) {
        guard request.mode == .themes, items.indices.contains(index) else { return }
        ThemeManager.shared.preview(items[index].previewThemeID)
    }

    private func move(_ delta: Int, items: [PaletteItem]) {
        guard !items.isEmpty else { return }
        selection = (selection + delta + items.count) % items.count
    }

    private func run(_ items: [PaletteItem], side: Bool) {
        guard items.indices.contains(selection) else { return }
        let item = items[selection]
        if request.mode == .commands || text.hasPrefix(">") { PaletteHistory.record(item.id) }
        if request.mode == .themes { ThemeManager.shared.preview(nil) }
        store.palette = nil
        if side, let openToSide = item.openToSide { openToSide() } else { item.perform() }
    }
}

/// One row of the palette. It keeps its own hover, so moving the pointer redraws this row only.
private struct PaletteRow: View {
    let item: PaletteItem
    let offset: Int
    let query: String
    let selected: Bool
    let activate: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 0) {
            if let separator = item.separator {
                HStack {
                    Spacer()
                    Text(separator).font(.ui(11)).foregroundStyle(theme[.pickerGroupForeground]).padding(.trailing, 4)
                }
                .frame(height: 0).offset(y: 11)
                .overlay(alignment: .top) { if offset > 0 { Rectangle().fill(theme[.pickerGroupBorder]).frame(height: 1) } }
                .zIndex(1)
            }
            HStack(spacing: 0) {
                if let icon = PaletteItem.codicon(for: item) {
                    Codicon(icon, size: 16).foregroundStyle(selected ? theme[.quickInputListFocusIconForeground] : theme[.iconForeground]).padding(.trailing, 6)
                }
                VSHighlightedText(text: item.title, matches: FuzzyMatch.ranges(of: query, in: item.title),
                                  highlight: selected ? .listFocusHighlightForeground : .listHighlightForeground)
                    .font(.ui(13)).lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail).font(.ui(12)).lineLimit(1).opacity(selected ? 1 : 0.7).padding(.leading, 6)
                }
                Spacer(minLength: 8)
                if let shortcut = item.shortcut, !shortcut.isEmpty { VSKeybinding(shortcut: shortcut).padding(.trailing, 2) }
            }
            .foregroundStyle(selected ? theme[.quickInputListFocusForeground] : theme[.quickInputForeground])
            .padding(.horizontal, 6).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 3).fill(selected ? theme[.quickInputListFocusBackground] : (hovered ? theme[.listHoverBackground] : .clear)))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(selected && theme.has(.listFocusOutline) ? theme[.listFocusOutline] : .clear, lineWidth: 1))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture(perform: activate)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

extension PaletteItem {
    /// VS Code shows no icons for commands; files, symbols and notes carry theirs.
    static func codicon(for item: PaletteItem) -> String? {
        switch item.category {
        case "Command", "": return nil
        case "Page": return "file"
        case "Line": return "list-selection"
        case "Section": return "symbol-class"
        case "Index": return "book"
        case "Term": return "symbol-key"
        case "Note": return "note"
        case "Book": return "file-pdf"
        case "Project": return "folder-library"
        case "Equation": return "symbol-numeric"
        case "Figure": return "file-media"
        case "Table": return "table"
        case "Algorithm": return "symbol-method"
        case "Exercise": return "tasklist"
        default: return "symbol-misc"
        }
    }
}

@MainActor
extension StudyStore {
    /// Closes the palette; a theme being previewed gives way to the chosen one.
    func closePalette() {
        if palette?.mode == .themes { ThemeManager.shared.preview(nil) }
        palette = nil
    }
}

/// An AppKit text field, so arrow keys, Return, Option-Return and Escape reach the palette reliably.
struct PaletteField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var prefix = ""
    let onMove: (Int) -> Void
    let onSubmit: (Bool) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        if !prefix.isEmpty, text.isEmpty { field.stringValue = prefix + " " }
        field.delegate = context.coordinator
        field.setAccessibilityLabel(placeholder)
        DispatchQueue.main.async { [prefix] in
            field.window?.makeFirstResponder(field)
            // After “> ” the caret waits at the end, as in VS Code; otherwise the text is selected to be replaced.
            if prefix.isEmpty { field.currentEditor()?.selectAll(nil) }
            else { field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0) }
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        let shown = prefix.isEmpty ? text : prefix + " " + text
        if field.stringValue != shown && !(prefix.isEmpty == false && field.stringValue.hasPrefix(prefix) && field.stringValue.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces) == text) {
            field.stringValue = shown
        }
        field.placeholderString = placeholder
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteField
        init(_ parent: PaletteField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            var value = field.stringValue
            // The command palette's “>” stays in the box, as in VS Code; the query is what follows it.
            if !parent.prefix.isEmpty, value.hasPrefix(parent.prefix) { value = String(value.dropFirst(parent.prefix.count)).trimmingCharacters(in: .whitespaces) }
            parent.text = value
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1); return true
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1); return true
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(false); return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): parent.onSubmit(true); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
            default: return false
            }
        }
    }
}
