import SwiftUI
import AppKit
import PDFKit
import LemmaCore

/// The editor's find widget, as VS Code's: a box at the top right of the page with the query, Match Case, the match
/// count and previous/next. ⌘F shows it (with a short selection as the query), ⌘G and ⇧⌘G move between matches,
/// Return and ⇧Return too, Escape closes it. Every match is highlighted on the page while it is open; the Search view
/// (⇧⌘F) remains the place to search the whole library.
///
/// Each book keeps its own query. "Theorem 1" in one paper has nothing to do with "Theorem 1" in another, so a search
/// never follows the reader into another tab: there the field shows that book's own query, and nothing is searched
/// until the reader asks, so the page stays where they left it.
@MainActor @Observable
final class FindController {
    static let shared = FindController()

    var isVisible = false
    /// The query of the current book (`bookID`).
    var query = ""
    var matchCase = false
    /// Keeps only matches that are whole words ("the" without "theorem"); PDFKit has no such option, so the results
    /// are filtered against the page text once the search ends.
    var wholeWord = false
    /// Incremented to move the keyboard focus into the field.
    private(set) var focusRequest = 0
    @ObservationIgnored private(set) weak var store: StudyStore?
    /// The book whose query is in the field, and the queries left in the other books.
    @ObservationIgnored private var bookID: String?
    @ObservationIgnored private var queries: [String: String] = [:]
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// The page the current search began on, for Whole Word's filtering.
    @ObservationIgnored private(set) var searchStartPage: Int?
    /// The PDF view whose matches are highlighted, so they can be cleared even after the book changed.
    @ObservationIgnored private weak var highlightedView: PDFView?

    func show(_ store: StudyStore) {
        attach(store)
        if let selected = store.reader.view?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selected.isEmpty, selected.count <= 80, !selected.contains("\n") {
            query = selected
            search()
        } else if query.isEmpty, !store.reader.searchText.isEmpty {
            // This book's own search, from the Search view or Find in this PDF.
            query = store.reader.searchText
            queryChanged()
        }
        isVisible = true
        focusRequest += 1
    }

    /// Makes the field this book's: the query left in the previous book stays with it, and this book's own query (or
    /// none) comes back without a search, so the page does not move.
    func attach(_ store: StudyStore) {
        let id = store.workspace?.id
        guard store !== self.store || id != bookID else { return }
        if let bookID { queries[bookID] = query.isEmpty ? nil : query }
        pending?.cancel()
        clearHighlights()
        self.store = store; bookID = id
        query = id.flatMap { queries[$0] } ?? ""
    }

    func hide() {
        isVisible = false
        pending?.cancel()
        clearHighlights()
        if let view = store?.reader.view { view.window?.makeFirstResponder(view) }
    }

    /// Searches shortly after typing stops, as VS Code does.
    func queryChanged() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            self?.search()
        }
    }

    func search() {
        guard let reader = store?.reader else { return }
        pending?.cancel()
        clearHighlights()
        reader.searchText = query
        reader.findOptions = matchCase ? [] : .caseInsensitive
        searchStartPage = reader.view?.currentPage.flatMap { page in reader.view?.document?.index(for: page) }
        reader.findStartPage = searchStartPage
        reader.find()
    }

    func next() {
        guard let reader = store?.reader else { return }
        if !isCurrent(reader) { search() } else { reader.nextMatch() }
    }

    func previous() {
        guard let reader = store?.reader else { return }
        if !isCurrent(reader) { search() } else { reader.previousMatch() }
    }

    /// Drops the matches that are part of a longer word, then goes to the first one from the page the search began on.
    /// Each match is widened by one character on both sides through PDFKit itself (its character indices and the page
    /// string's disagree on some pages, so the page string can't be indexed with the selection's range).
    func applyWholeWord(startPage: Int?) {
        guard wholeWord, let reader = store?.reader, let document = reader.view?.document, !reader.searchResults.isEmpty else { return }
        let kept = reader.searchResults.filter { selection in
            guard let original = selection.string else { return false }
            let lines = selection.selectionsByLine().count
            /// The character just outside the match on one side, or nil at a page edge or across a line break (a word
            /// boundary either way: PDFKit gives no separator between the last word of a line and the first of the next).
            func neighbour(atStart: Bool) -> Character? {
                guard let widened = selection.copy() as? PDFSelection else { return nil }
                if atStart { widened.extend(atStart: 1) } else { widened.extend(atEnd: 1) }
                guard let text = widened.string, text.count > original.count, widened.selectionsByLine().count == lines else { return nil }
                return atStart ? text.first : text.last
            }
            func isWordCharacter(_ character: Character?) -> Bool { character.map { $0.isLetter || $0.isNumber } ?? false }
            return !isWordCharacter(neighbour(atStart: true)) && !isWordCharacter(neighbour(atStart: false))
        }
        reader.searchResults = kept
        let start = startPage.flatMap { page in kept.firstIndex { selection in selection.pages.first.map { document.index(for: $0) >= page } ?? false } }
        if !kept.isEmpty { reader.goToMatch(start ?? 0) } else { reader.searchIndex = 0 }
    }

    /// Whether the reader's results are this query's (the Search view and other callers search too).
    private func isCurrent(_ reader: ReaderController) -> Bool {
        reader.hasSearched && reader.searchText == query && reader.findOptions == (matchCase ? [] : .caseInsensitive)
    }

    /// Highlights the matches on the page (PDFKit draws them under the text), at most a few thousand.
    func highlight(_ results: [PDFSelection], in view: PDFView?, color: NSColor) {
        guard isVisible, let view else { return }
        let shown = Array(results.prefix(3000))
        for selection in shown { selection.color = color }
        view.highlightedSelections = shown.isEmpty ? nil : shown
        highlightedView = view
    }

    func clearHighlights() {
        highlightedView?.highlightedSelections = nil
        highlightedView = nil
    }
}

struct FindWidget: View {
    @Bindable var store: StudyStore
    @State private var find = FindController.shared
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        let reader = store.reader
        HStack(spacing: 2) {
            HStack(spacing: 4) {
                // Typing searches; a query put in the field for the reader (another book's, say) does not.
                TextField("", text: Binding(get: { find.query }, set: { text in
                    guard text != find.query else { return }
                    find.query = text; find.queryChanged()
                }), prompt: Text("Find").foregroundColor(theme[.inputPlaceholderForeground]))
                    .textFieldStyle(.plain).font(.ui(13)).foregroundStyle(theme[.inputForeground])
                    .focused($focused)
                    .onSubmit { find.next() }
                    .onExitCommand { find.hide() }
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        guard press.modifiers.contains(.shift) else { return .ignored }
                        find.previous(); return .handled
                    }
                    .accessibilityLabel("Find in this book")
                VSIconButton(icon: "case-sensitive", help: "Match Case", size: 14, toggled: find.matchCase) {
                    find.matchCase.toggle(); find.search()
                }
                VSIconButton(icon: "whole-word", help: "Match Whole Word", size: 14, toggled: find.wholeWord) {
                    find.wholeWord.toggle(); find.search()
                }
            }
            .padding(.leading, 7).padding(.trailing, 2)
            .frame(width: 258, height: 24)
            .background(RoundedRectangle(cornerRadius: 4).fill(theme[.inputBackground]))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(focused ? theme[.focusBorder] : theme.border(.inputBorder), lineWidth: 1))
            Text(status(reader))
                .font(.ui(12)).monospacedDigit().lineLimit(1)
                .foregroundStyle(noResults(reader) ? theme[.errorForeground] : theme[.descriptionForeground])
                .frame(minWidth: 78, alignment: .leading).padding(.leading, 6)
            // VS Code's find widget has arrows; the Classic interface steps with chevrons, as its page buttons and Mac find bars do.
            let classic = ThemeManager.shared.style == .classic
            VSIconButton(icon: classic ? "chevron-up" : "arrow-up", help: "Previous Match (⇧⌘G)", enabled: !find.query.isEmpty) { find.previous() }
            VSIconButton(icon: classic ? "chevron-down" : "arrow-down", help: "Next Match (⌘G)", enabled: !find.query.isEmpty) { find.next() }
            VSIconButton(icon: "close", help: "Close (Escape)") { find.hide() }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme[.editorWidgetBackground]))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.border(.editorWidgetBorder), lineWidth: 1))
        .shadow(color: theme[.widgetShadow], radius: 8, y: 2)
        .onKeyPress(.escape) { find.hide(); return .handled }
        // On the first ⌘F the field is not in the window yet when this runs: ask for the keyboard once it is.
        .onChange(of: find.focusRequest, initial: true) { _, _ in DispatchQueue.main.async { focused = true } }
        // PDFKit reports matches one by one: highlight the first ones at once, then every few hundred, and all at the end.
        .onChange(of: reader.searchResults.count) { _, count in if count <= 40 || count % 250 == 0 { refreshHighlights() } }
        .onChange(of: reader.isSearching) { _, searching in
            guard !searching else { return }
            find.applyWholeWord(startPage: find.searchStartPage)
            refreshHighlights()
        }
        .onChange(of: store.workspace?.id) { _, _ in find.attach(store) }
        .onDisappear { find.clearHighlights() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find")
    }

    /// Matches are marked on the paper itself, so they take a highlighter's yellow whatever the workbench theme.
    private func refreshHighlights() {
        find.highlight(store.reader.searchResults, in: store.reader.view, color: NSColor(srgbRed: 1, green: 0.84, blue: 0.2, alpha: 0.45))
    }

    private func noResults(_ reader: ReaderController) -> Bool {
        reader.hasSearched && !reader.isSearching && reader.searchResults.isEmpty && reader.searchText == find.query && !find.query.isEmpty
    }

    private func status(_ reader: ReaderController) -> String {
        guard !find.query.isEmpty, reader.searchText == find.query, reader.hasSearched else { return "" }
        if reader.searchResults.isEmpty { return reader.isSearching ? "Searching…" : "No results" }
        let count = reader.searchResults.count
        return "\(min(reader.searchIndex + 1, count)) of \(count)\(reader.isSearching ? "+" : "")"
    }
}
