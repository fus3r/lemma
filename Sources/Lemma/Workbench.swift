import SwiftUI
import AppKit
import PDFKit
import LemmaCore

/// One open book in the editor's tab strip.
struct BookTab: Identifiable, Equatable {
    let id: String
    var title: String
}

/// The bottom panel's views, as in an IDE: references to the selected object, questions asked, and every note.
enum PanelTab: String, Codable, CaseIterable, Identifiable {
    case problems, references, hierarchy, questions, notes, console
    var id: String { rawValue }
    var title: String {
        switch self {
        case .problems: "Problems"; case .references: "References"; case .hierarchy: "Hierarchy"; case .questions: "Questions"; case .notes: "Notes"; case .console: "Console"
        }
    }
    var symbol: String {
        switch self {
        case .problems: "exclamationmark.triangle"
        case .references: "arrow.triangle.branch"; case .hierarchy: "point.3.connected.trianglepath.dotted"; case .questions: "text.bubble"
        case .notes: "list.bullet.rectangle"; case .console: "terminal"
        }
    }
}

/// What the References panel lists: the places that cite a numbered object or a work, or the pages an index term points to.
enum ReferencesQuery: Codable, Equatable {
    case object(ReferenceKey)
    case indexEntry(BookIndexEntry)

    var title: String {
        switch self {
        case let .object(key): key.kind == .citation ? "Citations of \(key.title)" : "References to \(key.spokenTitle)"
        case let .indexEntry(entry): "Index: \(entry.title)"
        }
    }
}

/// A second view of the same book beside the reader, opened on a reference or a page.
struct SplitEditorState: Codable, Equatable, Identifiable {
    var id = UUID()
    var pageIndex: Int
    var target: ReferenceTarget?
    var title: String
    /// The library PDF shown beside the reader; it may also be the main book. Nil for a reference in the main book.
    var bookID: String? = nil
    /// Each PDF view keeps its own viewport when changing side tabs or reopening the workbench.
    var scale: Double? = nil
    var positionX: Double? = nil
    var positionY: Double? = nil
}

/// One editor of the side group: another place in the book, a Lab notebook, a dependency map or a derivation.
enum SideEditor: Codable, Equatable, Identifiable {
    case page(SplitEditorState)
    case lab(UUID)
    case map(MapRequest)
    case derivation(UUID)
    case project(UUID)

    var id: String {
        switch self {
        case let .page(state): "page:\(state.id)"
        case let .lab(id): "lab:\(id)"
        case .map: "map"
        case let .derivation(id): "derivation:\(id)"
        case let .project(id): "project:\(id)"
        }
    }

    var symbol: String {
        switch self {
        case let .page(state): state.target?.key.kind.symbol ?? "doc.text"
        case .lab: "flask"
        case .map: "point.3.connected.trianglepath.dotted"
        case .derivation: "function"
        case .project: "folder"
        }
    }

    /// Editors that need width: the inspector steps aside for them in a laptop-sized window.
    var isWide: Bool { switch self { case .lab, .derivation, .project: true; case let .page(state): state.bookID != nil; case .map: false } }
}

enum PaletteMode: Equatable { case goTo, commands, symbols, themes }

/// The command palette (⌘⇧P) and Go to (⌘P) share one floating list.
struct PaletteRequest: Identifiable, Equatable {
    let id = UUID()
    var mode: PaletteMode
    var text = ""
}

@MainActor
extension StudyStore {
    // MARK: Page numbers

    /// The page number printed in the book, when it differs from the PDF's physical numbering.
    func printedLabel(for pageIndex: Int) -> String? {
        if let label = analysis?.printedLabel(for: pageIndex) { return label }
        guard let label = document?.page(at: pageIndex)?.label, label != String(pageIndex + 1) else { return nil }
        return label
    }

    /// “p. 12” when the book prints its own numbers, otherwise “PDF page 31”.
    func pageText(_ pageIndex: Int) -> String {
        printedLabel(for: pageIndex).map { "p. \($0)" } ?? "PDF page \(pageIndex + 1)"
    }

    /// The compact form used in lists and the status bar: “p. 12” or “p. 31” for books without printed numbers.
    func shortPageText(_ pageIndex: Int) -> String {
        "p. \(printedLabel(for: pageIndex) ?? String(pageIndex + 1))"
    }

    /// The physical page for a number the reader typed: a printed page when the book has its own numbering,
    /// or a PDF page when written “pdf 31”.
    func pageIndex(forTyped text: String) -> Int? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("pdf") {
            value = String(value.dropFirst(3)).trimmingCharacters(in: CharacterSet(charactersIn: " .:"))
            guard let number = Int(value), number >= 1, number <= (document?.pageCount ?? 0) else { return nil }
            return number - 1
        }
        for prefix in ["page", "p."] where value.hasPrefix(prefix) { value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        if value.hasPrefix("p"), Int(value.dropFirst()) != nil { value = String(value.dropFirst()) }
        if let numbering = analysis?.numbering, numbering.differsFromPhysical, let index = numbering.pageIndex(forLabel: value) { return index }
        if let document, let index = (0..<document.pageCount).first(where: { document.page(at: $0)?.label == value }), document.page(at: index)?.label != String(index + 1) { return index }
        guard let number = Int(value), number >= 1, number <= (document?.pageCount ?? 0) else { return nil }
        return number - 1
    }

    // MARK: Outline titles

    /// An outline title with the spacing printed on its page, once the book has been read.
    func repairedTitle(_ raw: String) -> String {
        analysis?.analysis?.outlineTitles[raw] ?? OutlineTitle.repaired(raw)
    }

    /// Rebuilds the outline with repaired titles.
    func refreshOutline() {
        guard let document else { outline = []; return }
        let entries = outlineEntries(for: document)
        if entries.isEmpty, let headings = analysis?.analysis?.headings, !headings.isEmpty {
            // A PDF without bookmarks gets the outline its numbered headings imply, as an editor outlines a file.
            outline = OutlineEntry.entries(from: headings)
        } else {
            outline = entries.map { $0.retitled(repairedTitle) }
        }
    }

    // MARK: Side editors

    var activeSideEditor: SideEditor? { sideEditors.first { $0.id == activeSideEditorID } ?? sideEditors.last }

    /// The page shown in the active side tab, when it is a page of the book.
    var split: SplitEditorState? {
        get { if case let .page(state)? = activeSideEditor { state } else { nil } }
        set {
            if let newValue { showSideEditor(.page(newValue)) }
            else if case .page? = activeSideEditor, let id = activeSideEditor?.id { closeSideEditor(id) }
        }
    }

    /// The notebook in the active side tab.
    var openLabID: UUID? {
        get { if case let .lab(id)? = activeSideEditor { id } else { nil } }
        set {
            if let newValue { showSideEditor(.lab(newValue)) }
            else if case .lab? = activeSideEditor, let id = activeSideEditor?.id { closeSideEditor(id) }
        }
    }

    /// The dependency map, in its own side tab.
    var openMap: MapRequest? {
        get { if case let .map(request)? = activeSideEditor { request } else { nil } }
        set {
            if let newValue { showSideEditor(.map(newValue)) }
            else { closeSideEditor("map") }
        }
    }

    /// The derivation in the active side tab.
    var openDerivationID: UUID? {
        get { if case let .derivation(id)? = activeSideEditor { id } else { nil } }
        set {
            if let newValue { showSideEditor(.derivation(newValue)) }
            else if case .derivation? = activeSideEditor, let id = activeSideEditor?.id { closeSideEditor(id) }
        }
    }

    /// Opens an editor in the side group: an existing tab for the same thing comes to the front, a map replaces the map,
    /// and a page with the same title is reused. At most eight tabs stay open.
    func showSideEditor(_ editor: SideEditor, reveal: Bool = true) {
        // Explicit side-editor actions reveal their group, which files and special editors otherwise cover.
        // Carrying a project across a background book change only restores its tab.
        if reveal { activeSpecial = nil; activeFileName = nil }
        if editor.isWide, !sideEditors.contains(where: \.isWide), showStudy, let window = mainWindow, window.frame.width < 1680 {
            // Page, editor and inspector do not fit side by side in a laptop-sized window: make room, and give it back on close.
            showStudy = false; labHidInspector = true
        }
        if case let .page(state) = editor, let index = sideEditors.firstIndex(where: { if case let .page(other) = $0 { other.title == state.title && other.bookID == state.bookID } else { false } }) {
            sideEditors[index] = editor
        } else if let index = sideEditors.firstIndex(where: { $0.id == editor.id }) {
            sideEditors[index] = editor
        } else {
            sideEditors.append(editor)
            if sideEditors.count > 8, let oldest = sideEditors.firstIndex(where: { $0.id != editor.id }) { sideEditors.remove(at: oldest) }
        }
        activeSideEditorID = editor.id
        saveWorkbench()
    }

    func closeSideEditor(_ id: String) {
        guard let index = sideEditors.firstIndex(where: { $0.id == id }) else { return }
        sideEditors.remove(at: index)
        if activeSideEditorID == id { activeSideEditorID = sideEditors.isEmpty ? nil : sideEditors[max(0, index - 1)].id }
        if !sideEditors.contains(where: \.isWide), labHidInspector { showStudy = true; labHidInspector = false }
        saveWorkbench()
    }

    func activateSideEditor(_ id: String) {
        guard let editor = sideEditors.first(where: { $0.id == id }) else { return }
        showSideEditor(editor)
    }

    /// The title of a side tab.
    func sideTitle(_ editor: SideEditor) -> String {
        switch editor {
        case let .page(state): state.title
        case let .lab(id): lab(id)?.title ?? "Lab"
        case let .map(request):
            switch request.scope {
            case let .chapter(chapter): "Map · Chapter \(chapter)"
            case let .prerequisites(key): "Map · \(key.title)"
            }
        case let .derivation(id): derivation(id)?.title ?? "Derivation"
        case let .project(id): project(id)?.title ?? "Project"
        }
    }

    // MARK: Panel and split editor

    func togglePanel() {
        if focusMode { toggleFocus() }
        showPanel.toggle()
    }

    /// Shows the Python console, or hides the panel when the console is already in front (⌃`).
    func toggleConsole() {
        if focusMode { toggleFocus() }
        if showPanel, panelTab == .console { showPanel = false } else { panelTab = .console; showPanel = true }
    }

    /// Lists the places that cite an object, a work or an index term in the bottom panel.
    func showReferences(_ query: ReferencesQuery) {
        if focusMode { toggleFocus() }
        referencesQuery = query
        panelTab = .references
        showPanel = true
    }

    func showReferences(to key: ReferenceKey) {
        if analysis?.analysis != nil { showReferences(.object(key)) } else { findMentions(of: key) }
    }

    /// Opens a target in the secondary editor, beside the reader.
    func openToSide(_ target: ReferenceTarget) {
        split = SplitEditorState(pageIndex: target.pageIndex, target: target, title: target.key.spokenTitle)
    }

    /// ⌥-click on a reference in the page: resolved as its peek would resolve it, then kept in the side editor.
    /// A reference Lemma cannot place opens its peek instead, which says so.
    func openReferenceToSide(_ mention: PageMention, pageIndex: Int) {
        guard let index = references, let workspaceID = workspace?.id else { return }
        Task { @MainActor [weak self] in
            let target = await index.resolve(mention, from: pageIndex)
            guard let self, self.workspace?.id == workspaceID else { return }
            if let target { self.openToSide(target) } else { self.peekReference(mention, pageIndex: pageIndex) }
        }
    }

    func openToSide(page pageIndex: Int, title: String? = nil) {
        split = SplitEditorState(pageIndex: pageIndex, target: nil, title: title ?? pageText(pageIndex))
    }

    /// Fits the page to the reader's width when it no longer fits, for example after opening the side editor.
    func fitPageIfOverflowing() {
        DispatchQueue.main.async { [weak self] in
            guard let view = self?.reader.view, let page = view.currentPage else { return }
            if page.displayedSize.width * view.scaleFactor > view.bounds.width - 16 { self?.reader.fitWidth() }
        }
    }

    func toggleSplit() {
        if split != nil { split = nil } else { openToSide(page: reader.pageNumber - 1) }
    }

    // MARK: Breadcrumbs

    /// The outline path containing the reading position: Chapter › Section › Subsection.
    func breadcrumb() -> [OutlineEntry] {
        let pageIndex = reader.focusPageIndex, y = reader.focusY
        var path: [OutlineEntry] = []
        var level = outline
        while let current = level.last(where: { $0.hasStarted(at: pageIndex, y: y) }) {
            path.append(current)
            guard let children = current.children else { break }
            level = children
        }
        return path
    }

    func go(to entry: OutlineEntry) {
        guard let pageIndex = entry.pageIndex, let page = document?.page(at: pageIndex) else { return }
        if let point = entry.point { reader.view?.go(to: PDFDestination(page: page, at: point)) } else { reader.goToPage(pageIndex + 1) }
    }

    // MARK: Palette

    func showPalette(_ mode: PaletteMode, text: String = "") {
        definitionLookup = nil; referencePeek = nil
        palette = PaletteRequest(mode: mode, text: text)
    }
}

extension OutlineEntry {
    /// Whether this entry starts at or before a point of the book. `y` is in PDF page space.
    func hasStarted(at pageIndex: Int, y: CGFloat?) -> Bool {
        guard let start = self.pageIndex else { return false }
        if start != pageIndex { return start < pageIndex }
        guard let y, let point else { return true }
        return point.y >= y - 2
    }
}
