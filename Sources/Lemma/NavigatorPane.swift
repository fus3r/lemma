import SwiftUI
import PDFKit
import LemmaCore

/// The sidebar's views, chosen from the activity bar as in an IDE.
enum NavigatorSection: String, Codable, CaseIterable, Identifiable {
    case library, projects, contents, results, symbols, index, lab, search, bookmarks, pages, catalog, debug, testing, timeline
    var id: String { rawValue }
    var title: String {
        switch self {
        case .library: "Books"; case .contents: "Outline"; case .results: "Results"; case .symbols: "Symbols"; case .index: "Index"; case .lab: "Lab"
        case .projects: "Projects"
        case .search: "Search"; case .bookmarks: "Marks"; case .pages: "Pages"; case .catalog: "Catalog"
        case .debug: "Run and Debug"; case .testing: "Testing"; case .timeline: "Timeline"
        }
    }
    var symbol: String {
        switch self {
        case .library: "books.vertical"; case .contents: "list.bullet.indent"; case .results: "checkmark.seal"; case .symbols: "function"; case .index: "character.book.closed"
        case .projects: "folder"
        case .lab: "flask"; case .search: "magnifyingglass"; case .bookmarks: "bookmark"; case .pages: "rectangle.grid.1x2"; case .catalog: "square.grid.2x2"
        case .debug: "ladybug"; case .testing: "checkmark.circle"; case .timeline: "clock"
        }
    }
    /// What the view is for, shown as the activity bar's help tag.
    var help: String {
        switch self {
        case .library: "Books: your library and open books"
        case .projects: "Projects: research questions, books, collected passages and your synthesis"
        case .contents: "Outline: the book's contents, following your reading position"
        case .results: "Results: definitions, theorems and lemmas with their proofs, what they use and what uses them"
        case .symbols: "Symbols: equations, figures, tables, algorithms and exercises · ⌘T"
        case .index: "Index: the book's own back-of-book index"
        case .lab: "Lab: Python notebooks beside the book, to try an equation or recreate a figure"
        case .search: "Search: the PDF, your notes, or indexed pages · ⌘F"
        case .bookmarks: "Marks: bookmarks, highlights and underlines"
        case .pages: "Pages: thumbnails"
        case .catalog: "Catalog: free textbooks to download, and arXiv papers by number"
        case .debug: "Run and Debug: step through a proof line by line with what is in scope"
        case .testing: "Testing: recall definitions and results as tests"
        case .timeline: "Timeline: your sessions, notes and work on this book"
        }
    }
}

/// PDFKit's own page thumbnails, driving the reader's PDF view.
struct PageThumbnails: NSViewRepresentable {
    let controller: ReaderController
    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.thumbnailSize = CGSize(width: 140, height: 190)
        view.maximumNumberOfColumns = 1
        view.backgroundColor = .clear
        view.allowsDragging = false
        view.allowsMultipleSelection = false
        view.pdfView = controller.view
        view.setAccessibilityLabel("Page thumbnails")
        return view
    }
    func updateNSView(_ view: PDFThumbnailView, context: Context) {
        if view.pdfView !== controller.view { view.pdfView = controller.view }
    }
}
enum StudySection: String, Codable, CaseIterable, Identifiable {
    case page, notes, glossary, references, review
    var id: String { rawValue }
    var title: String { switch self { case .page: "Page"; case .notes: "Notes"; case .glossary: "Glossary"; case .references: "Context"; case .review: "Review" } }
}
enum NoteFilter: String, CaseIterable, Identifiable {
    case all, open, understood, revisit
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    func includes(_ note: StudyNote) -> Bool { self == .all || note.state.rawValue == rawValue }
}

struct OutlineEntry: Identifiable {
    let id: String
    let title: String
    let pageIndex: Int?
    /// Where the entry starts on its page, in PDF page space, when the outline says.
    var point: CGPoint? = nil
    let children: [OutlineEntry]?
    var flattened: [OutlineEntry] { [self] + (children ?? []).flatMap(\.flattened) }
    /// The same entry and its children with titles passed through `title`, for repaired spacing.
    func retitled(_ title: (String) -> String) -> OutlineEntry {
        OutlineEntry(id: id, title: title(self.title), pageIndex: pageIndex, point: point, children: children?.map { $0.retitled(title) })
    }
    /// A tree from flat headings with levels (“1 Introduction”, “1.1 Setting”), for PDFs without an outline.
    static func entries(from headings: [OutlineItem]) -> [OutlineEntry] {
        func build(_ items: ArraySlice<(offset: Int, element: OutlineItem)>, level: Int) -> [OutlineEntry] {
            var result: [OutlineEntry] = []
            var index = items.startIndex
            while index < items.endIndex {
                let item = items[index]
                var end = items.index(after: index)
                while end < items.endIndex, items[end].element.level > item.element.level { end = items.index(after: end) }
                let children = build(items[items.index(after: index)..<end], level: level + 1)
                result.append(OutlineEntry(id: "heading.\(item.offset)", title: item.element.title, pageIndex: item.element.pageIndex,
                                           point: item.element.point, children: children.isEmpty ? nil : children))
                index = end
            }
            return result
        }
        return build(ArraySlice(Array(headings.enumerated())), level: 0)
    }

    static func entries(in document: PDFDocument) -> [OutlineEntry] {
        guard let root = document.outlineRoot else { return [] }
        func children(of item: PDFOutline, path: String) -> [OutlineEntry] {
            (0..<item.numberOfChildren).compactMap { index in
                guard let child = item.child(at: index) else { return nil }
                let id = "\(path).\(index)"
                let nested = children(of: child, path: id)
                let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                let point = destination.map(\.point).flatMap { abs($0.x) < 1e6 && abs($0.y) < 1e6 ? $0 : nil }
                return OutlineEntry(id: id, title: child.label ?? "Section",
                                    pageIndex: destination?.page.map { document.index(for: $0) }, point: point, children: nested.isEmpty ? nil : nested)
            }
        }
        return children(of: root, path: "root")
    }
}

struct NavigatorPane: View {
    @Bindable var store: StudyStore
    /// The view to show; the store's current view when nil.
    var section: NavigatorSection? = nil
    /// The 2.0 side bar draws its own VS Code title; the old header stays for standalone use.
    var showsHeader = true
    @State private var editingTitle = false
    @State private var bookTitle = ""

    var body: some View {
        let current = section ?? store.navigatorSection
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
            SidebarHeader(title: current.title, subtitle: current == .library ? nil : current == .catalog ? "\(BookCatalog.books.count) free books" : store.workspace?.title) {
                if store.navigatorSection == .projects {
                    Button { store.newProject() } label: { Image(systemName: "plus") }.help("New research project").accessibilityLabel("New research project")
                } else if store.navigatorSection == .library {
                    Button(action: store.choosePDF) { Image(systemName: "plus") }.help("Open a PDF · ⌘O").accessibilityLabel("Open a PDF")
                } else if let book = store.workspace {
                    Menu {
                        Button("Rename Book…") { bookTitle = book.title; editingTitle = true }
                        Button("Reveal Source in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: book.sourcePath)]) }
                        Button("Export Study Notes…", action: store.exportNotes)
                        Divider()
                        Button("Analyze Book Again", action: store.reanalyze).disabled(store.analysis?.isAnalyzing == true)
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22).accessibilityLabel("Book actions")
                }
            }
            Divider()
            }
            Group {
                switch current {
                case .library: library
                case .projects: ProjectsSidebar(store: store)
                case .contents: contents
                case .results: ResultsSidebar(store: store)
                case .symbols: SymbolsSidebar(store: store)
                case .index: BookIndexSidebar(store: store)
                case .lab: LabSidebar(store: store)
                case .pages:
                    if store.document == nil { PaneEmptyState(symbol: "rectangle.grid.1x2", title: "Pages at a glance", message: "Open a PDF to browse its pages.") }
                    else { PageThumbnails(controller: store.reader).padding(.top, 6) }
                case .bookmarks: marks
                case .search: search
                case .catalog: CatalogSidebar(store: store)
                case .debug: DebugSidebar(store: store)
                case .testing: TestingSidebar(store: store)
                case .timeline: TimelineList(store: store)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.lemmaSidebar)
        .sheet(isPresented: $editingTitle) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Book title").font(.title2.weight(.semibold))
                TextField("Title", text: $bookTitle).textFieldStyle(.roundedBorder)
                HStack { Spacer(); Button("Cancel") { editingTitle = false }.keyboardShortcut(.cancelAction)
                    Button("Save") { store.workspace?.title = bookTitle.trimmingCharacters(in: .whitespacesAndNewlines); store.flush(); editingTitle = false }.keyboardShortcut(.defaultAction).disabled(bookTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 360)
        }
    }
    private var library: some View {
        VStack(spacing: 0) {
            DisclosureGroup("Workspace Files", isExpanded: store.paneBinding(ExplorerPane.files.id)) {
                WorkspaceFilesList(store: store).frame(height: store.workspaceFiles.isEmpty ? 95 : 140)
            }.padding(.horizontal, 12).padding(.vertical, 8)
            Button("Add New File…") { store.beginNewFile() }.padding(.bottom, 8)
            Divider()
            LibraryCollectionsView(store: store)
        }
    }
    private var contents: some View {
        Group {
            if store.document == nil { PaneEmptyState(symbol: "list.bullet.indent", title: "The route through a book", message: "Open a PDF to browse its table of contents.") }
            else if store.outline.isEmpty { PaneEmptyState(symbol: "doc.text", title: "No embedded contents", message: "This PDF has no outline. Use page navigation, search, or your own bookmarks.") }
            else {
                let current = Set(store.breadcrumb().map(\.id))
                List {
                    OutlineGroup(store.outline, children: \.children) { entry in
                        Button { store.go(to: entry) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(entry.title).font(.system(size: 12, weight: current.contains(entry.id) ? .semibold : .regular)).lineLimit(2)
                                    .foregroundStyle(current.contains(entry.id) ? Color.lemmaOlive : Color.primary)
                                Spacer(minLength: 0)
                                if let progress = store.chapterProgress(of: entry), progress > 0 {
                                    ProgressRing(value: progress).help("\(Int((progress * 100).rounded())) % of this chapter read")
                                }
                                if let page = entry.pageIndex { Text(store.printedLabel(for: page) ?? String(page + 1)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                            }.padding(.vertical, 2).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(entry.pageIndex.map { "\(entry.title) · \(store.pageText($0)) · PDF page \($0 + 1)" } ?? entry.title)
                            .contextMenu {
                                if let page = entry.pageIndex {
                                    Button("Go to Section") { store.go(to: entry) }
                                    Button("Open to the Side") { store.openToSide(page: page, title: entry.title) }
                                }
                            }
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden).environment(\.defaultMinListRowHeight, 22)
            }
        }
    }
    private var marks: some View {
        VStack(spacing: 0) {
            Button(action: store.toggleBookmark) { Label(store.pageIsBookmarked ? "Remove current bookmark" : "Bookmark this page", systemImage: store.pageIsBookmarked ? "bookmark.fill" : "bookmark") }
                .buttonStyle(.borderless).disabled(store.document == nil).padding(14)
            if store.workspace?.bookmarks.isEmpty != false && store.workspace?.highlights.isEmpty != false {
                PaneEmptyState(symbol: "bookmark", title: "Leave a trail", message: "Bookmark a useful page or highlight a passage. Your marks stay separate from the original PDF.")
            } else {
                List {
                    Section("Bookmarks") {
                        ForEach(store.workspace?.bookmarks ?? []) { mark in
                            VStack(alignment: .leading, spacing: 5) {
                                TextField("Bookmark title", text: Binding(get: { store.workspace?.bookmarks.first { $0.id == mark.id }?.title ?? "" }, set: { store.updateBookmark(id: mark.id, title: $0) })).textFieldStyle(.plain).font(.callout.weight(.medium))
                                Button(store.pageText(mark.pageIndex)) { store.reader.go(to: mark) }.buttonStyle(.link).font(.caption)
                            }.padding(.vertical, 5).contextMenu { Button("Go to bookmark") { store.reader.go(to: mark) }; Button("Remove bookmark") { store.removeBookmark(id: mark.id) } }
                        }
                    }
                    Section("Highlights") {
                        ForEach(store.workspace?.highlights ?? []) { mark in
                            Button { store.reader.goToPage(mark.pageIndex + 1) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    if mark.style == .underline {
                                        Rectangle().fill(Color(nsColor: mark.nativeColor).opacity(1)).frame(width: 10, height: 2).padding(.top, 8)
                                    } else {
                                        Circle().fill(Color(nsColor: mark.nativeColor).opacity(1)).frame(width: 8, height: 8).padding(.top, 4)
                                    }
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(mark.quote.isEmpty ? "Selected region" : mark.quote).lineLimit(3).font(.callout)
                                        Text("\(mark.style.label) · \(store.pageText(mark.pageIndex))").font(.caption).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 4)
                            }.buttonStyle(.plain).contextMenu { Button("Remove highlight") { store.removeHighlight(id: mark.id) } }
                        }
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
            }
        }
    }
    private var search: some View {
        VStack(spacing: 0) {
            Picker("Search scope", selection: Binding(get: { store.searchIndexed ? 2 : store.searchNotes ? 1 : 0 }, set: { value in
                store.searchIndexed = value == 2; store.searchNotes = value == 1
                if value != 0 { store.reader.cancelSearch() }
            })) { Text("PDF text").tag(0); Text("All notes").tag(1); Text("Pages").tag(2) }.pickerStyle(.segmented).labelsHidden().padding(14)
                .onChange(of: store.searchNotes) { _, notes in if notes { store.reader.cancelSearch() } }
            if store.searchIndexed { PageSearchPane(store: store) }
            else if store.searchNotes {
                Picker("Note search scope", selection: $store.noteSearchScope) {
                    ForEach(PageSearchScope.allCases) { scope in Text(scope.label).tag(scope).disabled(scope == .project && store.currentProject == nil) }
                }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 14).padding(.bottom, 12)
                    .onChange(of: store.noteSearchScope) { _, _ in store.searchNoteMeaning() }
                searchField("Search your library notes", text: $store.libraryNoteQuery).padding(.horizontal, 14).padding(.bottom, 12)
                    .onChange(of: store.libraryNoteQuery) { _, _ in store.searchNoteMeaning() }
                Toggle("Related meaning", isOn: $store.noteSearchByMeaning).toggleStyle(.checkbox).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 10)
                    .onChange(of: store.noteSearchByMeaning) { _, _ in store.searchNoteMeaning() }
                if store.noteSearchByMeaning {
                    Text("Local similarity in the query’s language. These are source suggestions, not verified mathematical equivalences.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 10)
                }
                if store.isSearchingNoteMeaning { HStack { ProgressView().controlSize(.small); Text("Finding related notes…").font(.caption); Spacer() }.padding(14) }
                if store.noteSearchByMeaning && !store.libraryNoteQuery.isEmpty && !store.isSearchingNoteMeaning && !store.noteSemanticAvailable {
                    Text("No local sentence model for this query. Showing text matches.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 10)
                }
                if store.libraryNoteQuery.isEmpty { PaneEmptyState(symbol: "text.magnifyingglass", title: "Find the thought again", message: "Search questions, reasoning, definitions, and saved explanations across your library.") }
                else if store.libraryNoteResults.isEmpty && !store.isSearchingNoteMeaning { PaneEmptyState(symbol: "magnifyingglass", title: "No matching notes", message: "Try another term or a shorter phrase.") }
                else {
                    List {
                        ForEach(store.libraryNoteResults, id: \.note.id) { result in
                            Button { store.openSearchResult(workspace: result.workspace, note: result.note) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(result.note.title).font(.callout.weight(.medium)).lineLimit(3)
                                    Text("\(result.workspace.title) · p. \(result.note.anchor.pageIndex + 1)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    if store.noteSearchByMeaning {
                                        Text(store.noteMeaningHits.first { $0.workspaceID == result.workspace.id && $0.noteID == result.note.id }?.exact == true ? "Text match" : "Related meaning")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    }.listStyle(.sidebar).scrollContentBackground(.hidden)
                }
            } else {
                HStack(spacing: 6) {
                    searchField("Find in this PDF", text: $store.reader.searchText).onSubmit { store.reader.find() }
                    Button(action: store.reader.find) { Image(systemName: "arrow.right") }.buttonStyle(.borderless).accessibilityLabel("Find in PDF")
                }.padding(.horizontal, 14).padding(.bottom, 12)
                if store.reader.isSearching {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Searching… \(store.reader.searchResults.count) matches").font(.caption).foregroundStyle(.secondary); Spacer() }.padding(.horizontal, 14).padding(.bottom, 10)
                }
                if !store.reader.searchResults.isEmpty {
                    HStack {
                        Text("\(store.reader.searchIndex + 1) of \(store.reader.searchResults.count) matches").font(.caption).foregroundStyle(.secondary)
                        Spacer(); Button(action: store.reader.previousMatch) { Image(systemName: "chevron.up") }; Button(action: store.reader.nextMatch) { Image(systemName: "chevron.down") }
                    }.buttonStyle(.borderless).padding(.horizontal, 14).padding(.bottom, 8)
                    List(Array(store.reader.searchResults.enumerated()), id: \.offset) { index, match in
                        Button { store.reader.goToMatch(index) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(match.string ?? "Match").font(.callout).lineLimit(3)
                                if let page = match.pages.first, let doc = store.document { Text(store.pageText(doc.index(for: page))).font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).listRowBackground(store.reader.searchIndex == index ? Color.lemmaOlive.opacity(0.12) : Color.clear)
                    }.listStyle(.sidebar).scrollContentBackground(.hidden)
                } else if !store.reader.isSearching {
                    VStack(alignment: .leading, spacing: 0) {
                        if store.reader.hasSearched {
                            Button("Search scans and indexed pages") { store.pageSearchQuery = store.reader.searchText; store.searchIndexed = true; store.searchIndexedPages() }
                                .buttonStyle(.link).font(.callout).padding(.horizontal, 20).padding(.top, 12)
                        }
                        PaneEmptyState(symbol: "magnifyingglass", title: store.reader.hasSearched ? "No matches in the PDF text" : "Find a passage", message: store.reader.hasSearched ? "Image-only pages need a local OCR index. Choose Pages to index them." : "Search the document’s text, then jump between matching passages.")
                    }
                }
                else { Spacer() }
            }
        }
    }
}

/// The title row of a sidebar view: its name, the book it shows, and a few actions.
struct SidebarHeader<Actions: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            Spacer(minLength: 4)
            actions.buttonStyle(.borderless)
        }
        .padding(.leading, 14).padding(.trailing, 10).frame(height: 46)
    }
}

@MainActor @ViewBuilder func searchField(_ placeholder: String, text: Binding<String>, onDownArrow: (() -> Void)? = nil) -> some View {
    if ThemeManager.shared.style == .vscode {
        VSTextField(placeholder: placeholder, text: text, icon: "search", onDownArrow: onDownArrow)
    } else {
        classicSearchField(placeholder, text: text, onDownArrow: onDownArrow)
    }
}

@MainActor private func classicSearchField(_ placeholder: String, text: Binding<String>, onDownArrow: (() -> Void)? = nil) -> some View {
    HStack(spacing: 7) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField(placeholder, text: text).textFieldStyle(.plain).accessibilityLabel(placeholder)
            .onKeyPress(.downArrow) {
                guard let onDownArrow else { return .ignored }
                onDownArrow(); return .handled
            }
        if !text.wrappedValue.isEmpty { Button { text.wrappedValue = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.borderless).accessibilityLabel("Clear search") }
    }.font(.callout).padding(8).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
}

struct PaneEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    /// A button right under the message, as VS Code's welcome views place theirs.
    var action: (title: String, perform: () -> Void)? = nil
    @Environment(\.theme) private var theme
    var body: some View {
        if ThemeManager.shared.style == .vscode {
            // VS Code's welcome views: a short paragraph, no illustration.
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.ui(13, weight: .semibold)).foregroundStyle(theme[.foreground])
                Text(message).font(.ui(13)).foregroundStyle(theme[.descriptionForeground]).fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                if let action { Button(action.title, action: action.perform).buttonStyle(.vsPrimary).padding(.top, 8) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20).padding(.top, 13)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            classic
        }
    }
    private var classic: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 25, weight: .light)).foregroundStyle(.secondary).padding(.bottom, 4)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            if let action { Button(action.title, action: action.perform).controlSize(.small).padding(.top, 2) }
            Spacer(minLength: 0)
        }.padding(20).padding(.top, 14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
