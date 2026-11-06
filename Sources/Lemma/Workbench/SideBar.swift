import SwiftUI
import AppKit
import PDFKit
import LemmaCore

/// The primary side bar: the active view container under its VS Code title.
struct VSSideBar: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme

    var body: some View {
        let container = ViewContainer.of(store.navigatorSection)
        VStack(spacing: 0) {
            VSViewTitle(title: container.title) { titleActions(container) }
            content(container).frame(maxWidth: .infinity, maxHeight: .infinity)
                .buttonStyle(.vsPrimary)
        }
        .background(theme[.sideBarBackground])
        .foregroundStyle(theme[.sideBarForeground])
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(container.title) side bar")
    }

    @ViewBuilder private func content(_ container: ViewContainer) -> some View {
        switch container {
        case .explorer: ExplorerView(store: store)
        case .structure: StructureView(store: store)
        case .search: VSSearchView(store: store)
        case .debug: DebugSidebar(store: store)
        case .testing: TestingSidebar(store: store)
        case .lab: NavigatorPane(store: store, section: .lab, showsHeader: false)
        case .projects: NavigatorPane(store: store, section: .projects, showsHeader: false)
        case .marks: NavigatorPane(store: store, section: .bookmarks, showsHeader: false)
        case .catalog: NavigatorPane(store: store, section: .catalog, showsHeader: false)
        }
    }

    @ViewBuilder private func titleActions(_ container: ViewContainer) -> some View {
        switch container {
        case .explorer:
            VSIconButton(icon: "new-file", help: "Add New File… (⌃⌥⌘N)") { store.beginNewFile() }
            VSIconButton(icon: "folder-opened", help: "Open PDF… (⌘O)") { store.choosePDF() }
            VSIconButton(icon: "new-folder", help: "New Research Project") { store.newProject() }
            VSIconButton(icon: "collapse-all", help: "Collapse Outline") { store.outlineExpanded = [] }
        case .search:
            VSIconButton(icon: "refresh", help: "Search Again", enabled: !store.librarySearch.query.isEmpty) { store.runLibrarySearch() }
            VSIconButton(icon: "clear-all", help: "Clear Search Results", enabled: !store.librarySearch.results.isEmpty || !store.reader.searchResults.isEmpty) {
                store.librarySearch.clear(); store.reader.resetSearch()
            }
        case .structure:
            VSIconButton(icon: store.allProofsFolded ? "unfold" : "fold", help: store.allProofsFolded ? "Unfold All Proofs (⌥⌘[)" : "Fold All Proofs (⌥⌘[)",
                         enabled: !store.proofs.isEmpty) { store.toggleAllProofs() }
            VSIconButton(icon: "type-hierarchy", help: "Show Hierarchy of the Statement in View (⇧⌥⌘H)", enabled: store.analysis?.analysis != nil) { store.showHierarchyAtFocus() }
            VSIconButton(icon: "graph", help: "Dependency Map of This Chapter (⌥⌘G)", enabled: store.analysis?.analysis != nil) { store.showMap() }
        case .debug:
            VSIconButton(icon: "debug-start", help: "Start Debugging the Statement in View (F5)", tint: theme[.debugIconStartForeground],
                         enabled: store.document != nil) { store.startDebugging() }
        case .testing:
            VSIconButton(icon: "run-all", help: "Run Due Tests", tint: theme[.testingRunAction], enabled: !store.reviewNotes.isEmpty) { store.runDueTests() }
            VSIconButton(icon: "debug-rerun", help: "Run All Tests in This Chapter", enabled: store.workspace != nil) { store.runChapterTests() }
        case .lab:
            VSIconButton(icon: "new-file", help: "New Notebook", enabled: store.workspace != nil) { store.newLab() }
            VSIconButton(icon: "symbol-operator", help: "New Derivation", enabled: store.workspace != nil) { store.newDerivation() }
        case .projects:
            VSIconButton(icon: "new-folder", help: "New Research Project") { store.newProject() }
        case .marks:
            VSIconButton(icon: store.pageIsBookmarked ? "bookmark" : "add", help: store.pageIsBookmarked ? "Remove Bookmark (⌘D)" : "Bookmark Page (⌘D)",
                         enabled: store.document != nil) { store.toggleBookmark() }
        case .catalog:
            VSIconButton(icon: "folder-opened", help: "Open PDF… (⌘O)") { store.choosePDF() }
        }
        VSMenuButton(icon: "ellipsis", help: "Views and More Actions…") {
            var items: [VSMenuItem] = [.action("Add New File…", shortcut: "⌃⌥⌘N") { store.beginNewFile() },
                                     .action("Open PDF…", shortcut: "⌘O") { store.choosePDF() }]
            if let book = store.workspace {
                items += [.action("Reveal Source in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: book.sourcePath)]) },
                          .action("Export Study Notes…") { store.exportNotes() },
                          .action("Analyze Book Again", enabled: store.analysis?.isAnalyzing != true) { store.reanalyze() }]
            }
            items += [.separator,
                      .action(store.workbenchLayout.sidebarPosition == .left ? "Move Side Bar Right" : "Move Side Bar Left") {
                          store.workbenchLayout.sidebarPosition = store.workbenchLayout.sidebarPosition == .left ? .right : .left; store.saveWorkbench()
                      },
                      .action("Hide Side Bar", shortcut: "⌘B") { store.toggleLibrary() }]
            return items
        }
    }
}

// MARK: - Explorer

/// VS Code's Explorer for books: open editors, the library, the book's outline, its timeline and its pages.
struct ExplorerView: View {
    @Bindable var store: StudyStore

    private var openCount: Int { store.tabs.count + store.fileTabs.count + store.specialTabs.count + store.sideEditors.count }
    private var panes: [SidebarPane] {
        ExplorerPane.allCases.map { pane in
            let height: Double
            switch pane {
            case .open: height = min(Double(max(openCount, 1)) * 22 + (store.sideEditors.isEmpty ? 0 : 22), 220)
            case .files: height = store.workspaceFiles.isEmpty ? 90 : min(Double(store.workspaceFiles.count) * 22, 180)
            case .library: height = store.libraries.collections.isEmpty ? 110 : 220
            case .outline: height = 22
            case .timeline: height = 200
            case .pages: height = store.document == nil ? 60 : 260
            }
            return SidebarPane(id: pane.id, title: pane == .outline ? store.workspace.map { "Outline · \($0.title)" } ?? "Outline" : pane.title,
                               initiallyExpanded: pane.initiallyExpanded, preferredHeight: height,
                               count: pane == .open ? openCount : pane == .files ? store.workspaceFiles.count : pane == .library ? store.libraryPDFCount : nil)
        }
    }
    var body: some View {
        ResizableSidebarPanes(store: store, panes: panes, fill: ExplorerPane.outline.id) { pane in
            switch pane.id {
            case ExplorerPane.open.id: VSIconButton(icon: "close-all", help: "Close All Editors", size: 16) { store.closeAllEditors() }
            case ExplorerPane.files.id:
                VSIconButton(icon: "new-file", help: "Add New File…", size: 16) { store.beginNewFile() }
                VSMenuButton(icon: "ellipsis", help: "Workspace File Actions") {
                    [.action("New File…") { store.beginNewFile() },
                     .action("Refresh Files") { store.refreshWorkspaceFiles() },
                     .separator,
                     .action("Show in Finder") { store.revealWorkspaceFiles() }]
                }
            case ExplorerPane.library.id:
                VSIconButton(icon: "new-folder", help: "New Library…", size: 16) { store.beginNewLibrary() }
                VSIconButton(icon: "refresh", help: "Refresh Libraries", size: 16) { store.libraries.refresh() }
                VSIconButton(icon: "collapse-all", help: "Collapse All", size: 16) { store.collapseLibrary() }
                VSMenuButton(icon: "ellipsis", help: "More Library Actions…") { store.libraryViewMenu() }
            case ExplorerPane.outline.id: VSIconButton(icon: "collapse-all", help: "Collapse All", size: 16) { store.outlineExpanded = [] }
            default: EmptyView()
            }
        } content: { pane in
            switch pane.id {
            case ExplorerPane.open.id: OpenEditorsList(store: store)
            case ExplorerPane.files.id: WorkspaceFilesList(store: store)
            case ExplorerPane.library.id: LibraryCollectionsView(store: store)
            case ExplorerPane.outline.id: OutlineTree(store: store)
            case ExplorerPane.timeline.id: TimelineList(store: store)
            case ExplorerPane.pages.id:
                if store.document != nil { PageThumbnails(controller: store.reader) }
                else { VSWelcomeView(message: "Open a PDF to browse its pages.") { EmptyView() } }
            default: EmptyView()
            }
        }
    }
}

/// The open editors, grouped as VS Code groups them when the editor is split.
struct OpenEditorsList: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if !store.sideEditors.isEmpty { groupHeader("Group 1") }
                ForEach(store.tabs) { tab in
                    editorRow(icon: "file-pdf", title: tab.title, description: store.library.first { $0.id == tab.id }.map { "p. \($0.reading.pageIndex + 1)" } ?? "",
                              selected: store.activeMainTabID == tab.id, select: { store.activateMainTab(tab.id) }, close: { store.closeTab(tab.id) })
                }
                ForEach(store.specialTabs) { editor in
                    editorRow(icon: editor.icon, title: editor.title, description: "", selected: store.activeSpecial == editor,
                              select: { store.openSpecial(editor) }, close: { store.closeSpecial(editor) })
                }
                ForEach(store.fileTabs, id: \.self) { name in
                    editorRow(icon: (name as NSString).pathExtension.lowercased() == "md" ? "markdown" : "file-text", title: name, description: "",
                              selected: store.activeFileName == name, select: { store.openWorkspaceFile(name) }, close: { store.closeWorkspaceFile(name) })
                }
                if !store.sideEditors.isEmpty {
                    groupHeader("Group 2")
                    ForEach(store.sideEditors) { editor in
                        editorRow(icon: editor.codicon, title: store.sideTitle(editor), description: editor.kindLabel,
                                  selected: editor.id == store.activeSideEditor?.id, select: { store.activateSideEditor(editor.id) },
                                  close: { store.closeSideEditor(editor.id) })
                    }
                }
            }
        }
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title.uppercased()).font(.ui(11, weight: .bold)).foregroundStyle(theme[.descriptionForeground])
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading).padding(.leading, 20)
    }

    private func editorRow(icon: String, title: String, description: String, selected: Bool, select: @escaping () -> Void, close: @escaping () -> Void) -> some View {
        OpenEditorRow(icon: icon, title: title, description: description, selected: selected, select: select, close: close)
    }
}

private struct OpenEditorRow: View {
    @Environment(\.theme) private var theme
    let icon: String
    let title: String
    let description: String
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false
    var body: some View {
        VSRow(selected: selected, depth: 0, action: select) {
            ZStack {
                if hovering || selected { Codicon("close", size: 14).onTapGesture(perform: close).help("Close") }
            }.frame(width: 16, height: 16)
            FileIcon(kind: icon).padding(.leading, 2).padding(.trailing, 6)
            Text(title).font(.ui(13)).lineLimit(1)
            if !description.isEmpty {
                Text(description).font(.ui(12)).foregroundStyle(theme[selected ? .listActiveSelectionForeground : .descriptionForeground].opacity(0.85))
                    .lineLimit(1).padding(.leading, 6)
            }
            Spacer(minLength: 0)
        }
        .onHover { hovering = $0 }
        .contextMenu { Button("Close", action: close) }
    }
}

/// Coloured file-type icons, as VS Code's Seti icon theme draws them.
struct FileIcon: View {
    @Environment(\.theme) private var theme
    let kind: String
    var size: CGFloat = 16
    var body: some View {
        let (icon, color): (String, Color) = switch kind {
        case "file-pdf": ("file-pdf", Color(red: 0.89, green: 0.30, blue: 0.24))
        case "notebook": ("notebook", Color(red: 0.95, green: 0.55, blue: 0.20))
        case "symbol-operator", "derivation": ("symbol-operator", Color(red: 0.64, green: 0.46, blue: 0.90))
        case "graph", "map": ("graph", Color(red: 0.30, green: 0.69, blue: 0.69))
        case "folder-library", "project": ("folder-library", Color(red: 0.85, green: 0.72, blue: 0.33))
        case "settings-gear": ("settings-gear", theme[.iconForeground])
        case "keyboard": ("keyboard", theme[.iconForeground])
        case "home": ("lemma", theme[.focusBorder])
        case "info": ("info", Color(red: 0.25, green: 0.56, blue: 0.95))
        default: (kind, theme[.iconForeground])
        }
        if icon == "lemma" { LemmaGlyph(size: size).foregroundStyle(color) }
        else { Codicon(icon, size: size).foregroundStyle(color) }
    }
}

/// Lemma's λ mark, drawn as text so it takes the theme's colours.
struct LemmaGlyph: View {
    var size: CGFloat = 16
    var body: some View {
        Text("λ").font(.system(size: size * 0.95, weight: .semibold, design: .serif)).frame(width: size, height: size)
    }
}

extension SideEditor {
    var codicon: String {
        switch self {
        case .page: "file-pdf"; case .lab: "notebook"; case .map: "graph"; case .derivation: "symbol-operator"; case .project: "folder-library"
        }
    }
    var kindLabel: String {
        switch self { case .page: "page"; case .lab: "notebook"; case .map: "map"; case .derivation: "derivation"; case .project: "project" }
    }
}

/// The library as an explorer tree: books with their reading position; the open book in bold.
struct LibraryList: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme

    var body: some View {
        if store.library.isEmpty {
            VSWelcomeView(message: "Your library is empty. Open a book or paper, or get a free textbook from the Catalog.") {
                Button("Open PDF") { store.choosePDF() }.buttonStyle(.vsPrimary)
                Button("Browse the Catalog") { store.reveal(.catalog) }.buttonStyle(.vsSecondary)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.library) { book in
                        let available = FileManager.default.fileExists(atPath: book.sourcePath)
                        VSRow(selected: book.id == store.workspace?.id && store.activeSpecial == nil, action: { store.reopen(book) }) {
                            FileIcon(kind: "file-pdf").padding(.leading, 16).padding(.trailing, 6)
                            Text(book.title).font(.ui(13, weight: store.tabs.contains { $0.id == book.id } ? .medium : .regular)).lineLimit(1)
                                .strikethrough(!available)
                            if let progress = book.progress {
                                Text("\(Int((progress * 100).rounded())) %").font(.ui(12)).monospacedDigit()
                                    .foregroundStyle(theme[.descriptionForeground]).padding(.leading, 6)
                            }
                            Spacer(minLength: 0)
                            let due = book.notes.filter { $0.isDue() }.count
                            if due > 0 { VSBadge(count: due).help("\(due) notes due for recall") }
                        }
                        .help(available ? "\(book.title) · \(book.sourcePath)" : "Source moved · open it again")
                        .contextMenu {
                            Button("Open") { store.reopen(book) }.disabled(!available)
                            Button("Open to the Side") { store.openBookToTheSide(book.id) }.disabled(!available)
                            Menu("Add to Project") {
                                ForEach(store.activeProjects) { project in Button(project.title) { store.addBookToProject(book.id, projectID: project.id) } }
                                Button("New Project…") { if let id = store.newProject() { store.addBookToProject(book.id, projectID: id) } }
                            }
                            Divider()
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: book.sourcePath)]) }.disabled(!available)
                            Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(book.sourcePath, forType: .string) }
                        }
                        .draggable("lemma-book:\(book.id)")
                    }
                }
            }
        }
    }
}

/// The book's outline as an editor's outline tree: twisties, the current section highlighted and revealed.
/// It follows the outline path the reader publishes when the section changes, not every scroll step.
struct OutlineTree: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme

    var body: some View {
        let _ = QAPerf.tick("OutlineTree")
        if store.document == nil {
            VSWelcomeView(message: "Open a book to see its outline.") { EmptyView() }
        } else if store.outline.isEmpty {
            VSWelcomeView(message: "This PDF has no outline. Lemma builds one from numbered headings once it has read the book.") { EmptyView() }
        } else {
            let current = store.reader.focusPath.map(\.id)
            let progress = ChapterProgress(store: store)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows(current: Set(current)), id: \.entry.id) { row in
                            OutlineRow(store: store, entry: row.entry, depth: row.depth, current: current.last == row.entry.id,
                                       onPath: current.contains(row.entry.id), expanded: store.outlineExpanded.contains(row.entry.id),
                                       progress: row.depth == 0 ? progress.fraction(of: row.entry) : nil)
                                .id(row.entry.id)
                        }
                    }
                }
                .onChange(of: current.last) { _, id in
                    // Follow the reading position, as VS Code's outline follows the cursor.
                    guard let id, !store.reader.isScrubbing else { return }
                    expandPath(current)
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: store.reader.isScrubbing) { _, dragging in
                    guard !dragging, let id = current.last else { return }
                    expandPath(current)
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    /// Opens the sections around the reading position, writing to the store only when one was closed, so following
    /// the reader does not redraw the outline for nothing.
    private func expandPath(_ current: [String]) {
        let path = Set(current.dropLast())
        if !path.isSubset(of: store.outlineExpanded) { store.outlineExpanded.formUnion(path) }
    }

    private func rows(current: Set<String>) -> [(entry: OutlineEntry, depth: Int)] {
        var rows: [(OutlineEntry, Int)] = []
        func walk(_ entries: [OutlineEntry], depth: Int) {
            for entry in entries {
                rows.append((entry, depth))
                if let children = entry.children, store.outlineExpanded.contains(entry.id) || (current.contains(entry.id) && store.outlineFollows) {
                    walk(children, depth: depth + 1)
                }
            }
        }
        walk(store.outline, depth: 0)
        return rows
    }
}

/// How much of each chapter has been read, from one pass over the reading log (rather than one pass per row).
@MainActor
private struct ChapterProgress {
    private let readPages: [Int]
    private let store: StudyStore

    init(store: StudyStore) {
        self.store = store
        let log = store.workspace?.readingLog
        readPages = (log?.pageSeconds ?? [:]).compactMap { $0.value >= ReadingLog.readThreshold ? Int($0.key) : nil }.sorted()
        hasLog = log?.pageSeconds.isEmpty == false
    }
    private let hasLog: Bool

    /// The same value as `StudyStore.chapterProgress(of:)`: the fraction of the chapter's pages read.
    func fraction(of entry: OutlineEntry) -> Double? {
        guard hasLog, let range = store.chapterRange(of: entry) else { return nil }
        let low = readPages.partitioningIndex { $0 >= range.lowerBound }, high = readPages.partitioningIndex { $0 >= range.upperBound }
        return Double(high - low) / Double(max(range.count, 1))
    }
}

private extension Array where Element == Int {
    /// The first index whose element satisfies `predicate`, for a predicate that is false then true along the array.
    func partitioningIndex(where predicate: (Int) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if predicate(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}

private struct OutlineRow: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme
    let entry: OutlineEntry
    let depth: Int
    let current: Bool
    let onPath: Bool
    let expanded: Bool
    /// The chapter's reading progress (top-level rows only).
    let progress: Double?

    var body: some View {
        let _ = QAPerf.tick("OutlineRow")
        let isExpanded = expanded || (onPath && store.outlineFollows)
        VSRow(selected: current, depth: depth, action: { store.go(to: entry) }) {
            VSTwistie(expandable: entry.children?.isEmpty == false, expanded: isExpanded) {
                if isExpanded { store.outlineExpanded.remove(entry.id); if onPath { store.outlineFollows = false } }
                else { store.outlineExpanded.insert(entry.id) }
            }
            Codicon(depth == 0 ? "symbol-namespace" : depth == 1 ? "symbol-class" : "symbol-method", size: 16)
                .foregroundStyle(theme[depth == 0 ? .symbolIconNamespaceForeground : depth == 1 ? .symbolIconClassForeground : .symbolIconMethodForeground])
                .padding(.trailing, 6)
            Text(entry.title).font(.ui(13, weight: onPath && !current ? .medium : .regular)).lineLimit(1)
            Spacer(minLength: 4)
            if let progress, progress > 0, depth == 0 {
                ProgressRing(value: progress).help("\(Int((progress * 100).rounded())) % of this chapter read")
            }
            if let page = entry.pageIndex {
                Text(store.printedLabel(for: page) ?? String(page + 1)).font(.ui(12)).monospacedDigit()
                    .foregroundStyle(current ? theme[.listActiveSelectionForeground].opacity(0.8) : theme[.descriptionForeground])
            }
        }
        .help(entry.pageIndex.map { "\(entry.title) · \(store.pageText($0))" } ?? entry.title)
        .contextMenu {
            if let page = entry.pageIndex {
                Button("Go to Section") { store.go(to: entry) }
                Button("Open to the Side") { store.openToSide(page: page, title: entry.title) }
                Button("Debug This Section") { store.go(to: entry); store.startDebugging() }
            }
        }
    }
}

// MARK: - Timeline

/// What happened with this book, newest first, as VS Code's Timeline: reading days, notes, answers, derivations, notebooks.
struct TimelineList: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme

    struct Event: Identifiable {
        let id: String
        let date: Date
        let icon: String
        let title: String
        let detail: String
        let open: @MainActor () -> Void
    }

    var body: some View {
        let events = events()
        if events.isEmpty {
            VSWelcomeView(message: store.workspace == nil ? "Open a book to see its timeline." : "Your reading sessions, notes and work on this book will appear here.") { EmptyView() }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(events) { event in
                        VSRow(action: event.open) {
                            Codicon(event.icon, size: 16).foregroundStyle(theme[.iconForeground]).padding(.leading, 16).padding(.trailing, 6)
                            Text(event.title).font(.ui(13)).lineLimit(1)
                            Text(event.detail).font(.ui(12)).foregroundStyle(theme[.descriptionForeground]).lineLimit(1).padding(.leading, 6)
                            Spacer(minLength: 4)
                            Text(Self.relative(event.date)).font(.ui(12)).foregroundStyle(theme[.descriptionForeground]).lineLimit(1)
                        }
                        .help("\(event.title) · \(event.date.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
            }
        }
    }

    static func relative(_ date: Date) -> String {
        let seconds = Date.now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) hrs" }
        if seconds < 86_400 * 30 { return "\(Int(seconds / 86_400)) days" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func events() -> [Event] {
        guard let book = store.workspace else { return [] }
        var events: [Event] = []
        let calendar = Calendar.current
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        for (day, seconds) in book.readingLog.daySeconds where seconds >= 60 {
            guard let date = formatter.date(from: day) else { continue }
            let end = calendar.date(byAdding: .hour, value: 20, to: date) ?? date
            events.append(Event(id: "day-\(day)", date: min(end, .now), icon: "history", title: "Read \(ReadingLog.describeShort(seconds))",
                                detail: date.formatted(.dateTime.weekday(.wide)), open: {}))
        }
        for note in book.notes {
            let kind = note.isQuickMark ? "“?” mark" : note.kind.label
            events.append(Event(id: "note-\(note.id)", date: note.createdAt, icon: note.isQuickMark ? "question" : "note",
                                title: note.title, detail: "\(kind) · p. \(note.anchor.pageLabel)", open: { [store] in store.selectNote(note.id); store.reader.go(to: note.anchor) }))
            if let explanation = note.explanation {
                events.append(Event(id: "answer-\(note.id)", date: explanation.savedAt, icon: "comment-discussion", title: "Answer saved",
                                    detail: note.title, open: { [store] in store.selectNote(note.id) }))
            }
        }
        for derivation in book.derivations {
            events.append(Event(id: "derivation-\(derivation.id)", date: derivation.updatedAt, icon: "symbol-operator", title: derivation.title,
                                detail: "derivation", open: { [store] in store.openDerivation(derivation.id) }))
        }
        for notebook in book.labs {
            events.append(Event(id: "lab-\(notebook.id)", date: notebook.updatedAt, icon: "notebook", title: notebook.title,
                                detail: "notebook", open: { [store] in store.openLabNotebook(notebook.id) }))
        }
        return events.sorted { $0.date > $1.date }.prefix(200).map { $0 }
    }
}

// MARK: - Structure

/// The book's structure: results with their proofs, numbered objects and the back-of-book index, as panes.
struct StructureView: View {
    @Bindable var store: StudyStore
    var body: some View {
        ResizableSidebarPanes(store: store, panes: [
            SidebarPane(id: "structure.results", title: "Results", preferredHeight: 260),
            SidebarPane(id: "structure.symbols", title: "Equations and Figures", preferredHeight: 260),
            SidebarPane(id: "structure.index", title: "Index", initiallyExpanded: false, preferredHeight: 180)
        ], fill: "structure.results") { _ in
            EmptyView()
        } content: { pane in
            NavigatorPane(store: store, section: pane.id == "structure.results" ? .results : pane.id == "structure.symbols" ? .symbols : .index,
                          showsHeader: false)
        }
    }
}
