import SwiftUI
import AppKit
import LemmaCore

/// The library as one workspace: where the other books define or index a term, as an editor's Go to Symbol in
/// Workspace searches every file. Terms and index entries are read from each book's cached analysis, in the background,
/// and folded there once: a search as the reader types only compares.
@MainActor @Observable
final class LibraryGlossary {
    struct Book: Sendable {
        let id: String
        let title: String
        let terms: PreparedTerms
        let index: PreparedBookIndex
        let numbering: PageNumbering?
    }

    struct Hit: Identifiable, Equatable, Sendable {
        let id: String
        let bookID: String
        let bookTitle: String
        let title: String
        let detail: String
        let pageIndex: Int
        let definitional: Bool
    }

    private(set) var books: [String: Book] = [:]
    @ObservationIgnored private var loading = false
    /// The book in front's terms and index, prepared once per analysis (Look Up and the palette search them).
    @ObservationIgnored private var current: (key: String, terms: PreparedTerms, index: PreparedBookIndex)?

    /// Reads the other books' analyses once (they are cached on disk by each book's first reading).
    func load(library: [StudyWorkspace], root: URL) {
        guard !loading else { return }
        let missing = library.filter { books[$0.id] == nil }.map { ($0.id, $0.title) }
        guard !missing.isEmpty else { return }
        loading = true
        Task {
            let loaded = await Task.detached(priority: .utility) { () -> [Book] in
                let repository = DocumentIndexRepository(root: root)
                return missing.compactMap { id, title in
                    guard let analysis = repository.bookAnalysis(id) else { return nil }
                    return Book(id: id, title: title, terms: PreparedTerms(analysis.terms), index: PreparedBookIndex(analysis.index),
                                numbering: analysis.numbering)
                }
            }.value
            for book in loaded { books[book.id] = book }
            loading = false
        }
    }

    /// The terms and index of a book's analysis, folded once and kept while it stays the same.
    func prepared(_ analysis: BookAnalysis, id: String) -> (terms: PreparedTerms, index: PreparedBookIndex) {
        let key = "\(id):\(analysis.terms.count):\(analysis.index.count)"
        if let current, current.key == key { return (current.terms, current.index) }
        let terms = PreparedTerms(analysis.terms), index = PreparedBookIndex(analysis.index)
        current = (key, terms, index)
        return (terms, index)
    }

    /// Definitions and index entries for `query` in every book but `excluding`, defining occurrences first.
    func hits(for query: String, excluding: String?) -> [Hit] { Self.hits(for: query, in: Array(books.values), excluding: excluding) }

    /// The same, off the main thread (Look Up runs it as the reader types).
    nonisolated static func hits(for query: String, in books: [Book], excluding: String?) -> [Hit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return [] }
        var result: [Hit] = []
        for book in books.sorted(by: { $0.title < $1.title }) where book.id != excluding {
            if Task.isCancelled { return [] }
            func page(_ index: Int) -> String { book.numbering?.label(for: index).map { "p. \($0)" } ?? "PDF \(index + 1)" }
            for term in BookTermSearch.find(trimmed, in: book.terms, limit: 2) {
                result.append(Hit(id: "\(book.id)-t-\(term.id)", bookID: book.id, bookTitle: book.title, title: term.surface,
                                  detail: "…\(term.before.suffix(40))\(term.surface)\(term.after.prefix(40))…", pageIndex: term.pageIndex,
                                  definitional: term.definitional))
            }
            for match in BookIndexSearch.find(trimmed, in: book.index, limit: 2) {
                guard let first = match.entry.locators.first, let pageIndex = book.numbering?.pageIndex(forLabel: first.first) ?? Int(first.first).map({ $0 - 1 }) else { continue }
                result.append(Hit(id: "\(book.id)-i-\(match.entry.id)", bookID: book.id, bookTitle: book.title, title: match.entry.title,
                                  detail: "Index: " + match.entry.locators.map(\.text).joined(separator: ", "), pageIndex: pageIndex, definitional: false))
            }
        }
        return Array(result.sorted { $0.definitional && !$1.definitional }.prefix(6))
    }
}

/// “In your other books”: a section of Look Up listing where the rest of the library treats a term.
struct LibraryLookupSection: View {
    @Bindable var store: StudyStore
    let hits: [LibraryGlossary.Hit]

    var body: some View {
        if !hits.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("In your other books", systemImage: "books.vertical").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(hits) { hit in
                    Button { store.definitionLookup = nil; store.openBook(hit.bookID, atPage: hit.pageIndex) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(hit.bookTitle).font(.caption.weight(.semibold)).lineLimit(1)
                                Text(hit.title).italic().font(.callout).lineLimit(1)
                                if hit.definitional {
                                    Text("definition").font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                                        .padding(.horizontal, 4).background(Color.primary.opacity(0.07), in: Capsule())
                                }
                                Spacer(minLength: 0)
                            }
                            Text(hit.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(hit.bookTitle) in its tab at this page")
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
        }
    }
}

@MainActor
extension StudyStore {
    /// Opens a library book in its tab at a page. A book brought to the front is not in the PDF view yet: the view
    /// takes it on its next update and opens it at the reading position, so the page goes there first (going to the
    /// page at once would move the book still on screen).
    func openBook(_ id: String, atPage pageIndex: Int) {
        guard let item = library.first(where: { $0.id == id }) else { return }
        if workspace?.id == id, activeSpecial == nil, activeFileName == nil, let view = reader.view, view.document === document, view.window != nil {
            reader.goToPage(pageIndex + 1)
            return
        }
        if workspace?.id == id { activeSpecial = nil; activeFileName = nil } else { reopen(item) }
        guard workspace?.id == id else { return }
        workspace?.reading.pageIndex = pageIndex
        workspace?.reading.positionX = nil; workspace?.reading.positionY = nil
    }
}
