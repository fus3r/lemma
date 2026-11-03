import Foundation
import LemmaCore

enum SidebarPosition: String, Codable, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct WorkbenchLayout: Codable, Equatable {
    var sidebarPosition: SidebarPosition = .left
    var activityBar = true
    var sidebarWidth: Double = 264
    var inspectorWidth: Double = 370
    /// Sizes by pane id throughout the workbench. The existing key keeps older sessions compatible.
    var explorerHeights: [String: Double]? = nil
    var panelHeight: Double? = nil
}

/// Editor state belongs to a book, rather than to whichever book happens to be in front.
struct BookEditorState: Codable {
    var editors: [SideEditor]
    var activeEditorID: String?
    var selectedNoteID: UUID?
    var studySection: StudySection
    var referencesQuery: ReferencesQuery?
    var hierarchyKey: ReferenceKey?
    var hierarchyDirection: HierarchyDirection
    var inspectorWasHidden: Bool
    /// 2.0: breakpoints and watch expressions of Run and Debug (absent in earlier sessions).
    var breakpoints: [LineBreakpoint]? = nil
    var watch: [String]? = nil
    /// Each window keeps its own page, zoom and viewport, including when two windows show the same book.
    var reading: ReadingState? = nil
}

/// Kept in the library's support folder, so isolated QA copies and other libraries have their own session.
struct WorkbenchSession: Codable {
    var bookIDs: [String] = []
    var activeBookID: String?
    var books: [String: BookEditorState] = [:]
    var homeEditors: [SideEditor] = []
    var activeHomeEditorID: String?
    var projectID: UUID?
    var layout = WorkbenchLayout()
    var showLibrary = true
    var showStudy = true
    var showPanel = false
    var panelTab: PanelTab = .references
    var navigator: NavigatorSection = .contents
    /// 2.0: Welcome, Settings and other special editors open in the main group, and the one in front.
    var specialTabs: [SpecialEditor]? = nil
    var activeSpecial: SpecialEditor? = nil
    var fileTabs: [String]? = nil
    var activeFileName: String? = nil
    /// Library sections and folders are expanded independently in each window.
    var paneExpanded: [String: Bool]? = nil
}

@MainActor
extension StudyStore {
    var sessionURL: URL {
        if windowID == AppModel.primaryWindowID { return repository.root.appendingPathComponent("workbench.json") }
        return repository.root.appendingPathComponent("Windows/\(windowID.uuidString)/workbench.json")
    }

    func rememberBookEditors() {
        guard let id = workspace?.id else { return }
        workbench.books[id] = BookEditorState(editors: sideEditors, activeEditorID: activeSideEditorID,
            selectedNoteID: selectedNoteID, studySection: studySection, referencesQuery: referencesQuery,
            hierarchyKey: hierarchyKey, hierarchyDirection: hierarchyDirection, inspectorWasHidden: labHidInspector,
            breakpoints: breakpoints, watch: watchExpressions, reading: workspace?.reading)
    }

    func restoreBookEditors(_ book: StudyWorkspace) {
        guard let saved = workbench.books[book.id] else { labHidInspector = false; breakpoints = []; watchExpressions = []; return }
        if var reading = saved.reading {
            reading.pageIndex = max(0, min(reading.pageIndex, (document?.pageCount ?? 1) - 1))
            workspace?.reading = reading
        }
        breakpoints = saved.breakpoints ?? []
        watchExpressions = saved.watch ?? []
        sideEditors = saved.editors.filter { editor in
            switch editor {
            case let .page(state):
                // Another book's page is checked against its recorded page count: its PDF is read when the tab is shown,
                // not while the book in front opens.
                guard state.pageIndex >= 0 else { return false }
                if let id = state.bookID, id != book.id {
                    guard let other = library.first(where: { $0.id == id }) else { return false }
                    let pages = (documents[id] ?? sideDocuments[id])?.pageCount ?? other.pageCount
                    return pages.map { state.pageIndex < $0 } ?? true
                }
                return state.pageIndex < (document?.pageCount ?? 0)
            case let .lab(id): return book.labs.contains { $0.id == id }
            case let .derivation(id): return book.derivations.contains { $0.id == id }
            case let .project(id): return projects.contains { $0.id == id && !$0.archived }
            case .map: return true
            }
        }
        activeSideEditorID = sideEditors.contains { $0.id == saved.activeEditorID } ? saved.activeEditorID : sideEditors.last?.id
        selectedNoteID = book.notes.contains { $0.id == saved.selectedNoteID } ? saved.selectedNoteID : book.notes.first?.id
        studySection = saved.studySection
        referencesQuery = saved.referencesQuery
        hierarchyKey = saved.hierarchyKey; hierarchyDirection = saved.hierarchyDirection
        labHidInspector = saved.inspectorWasHidden && sideEditors.contains(where: \.isWide)
        if labHidInspector { showStudy = false }
        // Restarting the app restores the editor, never the execution of a notebook.
        for editor in sideEditors {
            if case let .derivation(id) = editor { checkDerivation(id, delay: 0) }
        }
    }

    /// Writes the editor session when it changed (it is compared with what was last written, so the many calls made
    /// while working cost an encoding of a few kilobytes and no disk write).
    func saveWorkbench() {
        guard sessionWritable else { return }
        rememberBookEditors()
        // Tabs of books whose saved notes could not be read stay in the session, for when they can be read again.
        workbench.bookIDs = tabs.map(\.id) + preservedTabIDs.filter { id in !tabs.contains { $0.id == id } }
        workbench.activeBookID = workspace?.id
        if workspace == nil { workbench.homeEditors = sideEditors; workbench.activeHomeEditorID = activeSideEditorID }
        workbench.projectID = selectedProjectID; workbench.layout = workbenchLayout
        if !focusMode { workbench.showLibrary = showLibrary; workbench.showStudy = showStudy; workbench.showPanel = showPanel }
        workbench.panelTab = panelTab; workbench.navigator = navigatorSection
        workbench.specialTabs = specialTabs; workbench.activeSpecial = activeSpecial
        workbench.fileTabs = fileTabs; workbench.activeFileName = activeFileName
        workbench.paneExpanded = paneExpanded
        do {
            let data = try sessionEncoder.encode(workbench)
            guard data != lastSessionData else { return }
            if lastSessionData == nil { try FileManager.default.createDirectory(at: sessionURL.deletingLastPathComponent(), withIntermediateDirectories: true) }
            try data.write(to: sessionURL, options: .atomic)
            lastSessionData = data
            app.saveWindows()
        } catch { self.error = "Could not save the editor session: \(error.localizedDescription)" }
    }

    var panelHeight: Double {
        get { workbenchLayout.panelHeight ?? (UserDefaults.standard.object(forKey: "panelHeight") as? Double ?? 240) }
        set { workbenchLayout.panelHeight = newValue; saveWorkbench() }
    }

    /// A tab dropped on another takes that tab's place, so a drag to the right lands after the tab dropped on (it landed
    /// before it, and a tab dropped on its right-hand neighbour stayed where it was); dropped after the last tab, it goes last.
    func moveTab(_ id: String, onto targetID: String?) {
        if tabs.move(id, onto: targetID) { saveWorkbench() }
    }

    func moveSideEditor(_ id: String, onto targetID: String) {
        if sideEditors.move(id, onto: targetID) { saveWorkbench() }
    }

    /// A drop on the main group's tab bar, on a tab or after the last one (no target): a book's tab, dragged as
    /// `lemma-tab:<id>`, moves there.
    func dropBookTab(_ values: [String], onto targetID: String?) -> Bool {
        guard let value = values.first, value.hasPrefix("lemma-tab:") else { return false }
        moveTab(String(value.dropFirst("lemma-tab:".count)), onto: targetID); return true
    }

    /// A drop on a side editor's tab: another side editor's tab, dragged as `lemma-side:<id>`, takes its place.
    func dropSideTab(_ values: [String], onto targetID: String) -> Bool {
        guard let value = values.first, value.hasPrefix("lemma-side:") else { return false }
        moveSideEditor(String(value.dropFirst("lemma-side:".count)), onto: targetID); return true
    }

    /// Closes the other book tabs together: the kept book comes to the front, none of the others is opened on the way.
    func closeOtherTabs(keeping id: String) {
        closeTabs(Set(tabs.map(\.id) + (workspace.map { [$0.id] } ?? [])).subtracting([id]), preferring: id)
    }

    func shiftBookTab(_ id: String, by offset: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs.indices.contains(index + offset) else { return }
        tabs.swapAt(index, index + offset); saveWorkbench()
    }

    func shiftSideTab(_ id: String, by offset: Int) {
        guard let index = sideEditors.firstIndex(where: { $0.id == id }), sideEditors.indices.contains(index + offset) else { return }
        sideEditors.swapAt(index, index + offset); saveWorkbench()
    }

    func applyLayout(_ preset: LayoutPreset) {
        if focusMode { toggleFocus() }
        workbenchLayout.activityBar = true
        switch preset {
        case .reading:
            showLibrary = true; navigatorSection = .contents; showStudy = false; showPanel = false
            workbenchLayout.sidebarWidth = 236
        case .study:
            showLibrary = true; navigatorSection = .results; showStudy = true; showPanel = false
            workbenchLayout.sidebarWidth = 244; workbenchLayout.inspectorWidth = 354
        case .research:
            showLibrary = true; navigatorSection = .projects; showStudy = false; showPanel = false
            workbenchLayout.sidebarWidth = 250
            if let id = selectedProjectID { openProject(id) }
        case .lab:
            showLibrary = false; showStudy = false; panelTab = .console; showPanel = true
            if openLabID == nil, let notebook = workspace?.labs.first { openLabNotebook(notebook.id) }
        }
        saveWorkbench()
        fitPageIfOverflowing()
    }
}

extension Array where Element: Identifiable, Element.ID == String {
    /// Moves the element `id` to the place of the element `targetID`, those in between shifting one place toward its old
    /// place, or to the end without a target. False when nothing moves.
    mutating func move(_ id: String, onto targetID: String?) -> Bool {
        guard let source = firstIndex(where: { $0.id == id }) else { return false }
        var target = endIndex - 1
        if let targetID { guard let index = firstIndex(where: { $0.id == targetID }) else { return false }; target = index }
        guard target != source else { return false }
        insert(remove(at: source), at: target)
        return true
    }
}

enum LayoutPreset: String, CaseIterable, Identifiable {
    case reading, study, research, lab
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbol: String { switch self { case .reading: "book"; case .study: "pencil.and.outline"; case .research: "folder"; case .lab: "flask" } }
}
