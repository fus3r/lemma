import SwiftUI
import AppKit
import LemmaCore

@MainActor
extension StudyStore {
    /// Every command the palette can run, named “Group: Action” as in an editor. Unavailable commands are left out.
    func commandCatalog() -> [PaletteItem] {
        let book = document != nil, selected = reader.hasSelection
        var items: [PaletteItem] = []
        func add(_ title: String, _ symbol: String, _ shortcut: String? = nil, when enabled: Bool = true, _ perform: @escaping @MainActor () -> Void) {
            guard enabled else { return }
            items.append(PaletteItem(id: "command-\(title)", title: title, symbol: symbol, category: "Command", shortcut: shortcut, perform: perform))
        }
        add("File: New Window", "macwindow", "⇧⌘N") { [self] in app.newWindow() }
        add("File: Add New File…", "doc.badge.plus", "⌃⌥⌘N") { [self] in beginNewFile() }
        add("File: Save File", "square.and.arrow.down", "⌘S", when: activeFile != nil) { [self] in saveActiveFile() }
        add("File: Show Workspace Files in Finder", "folder") { [self] in revealWorkspaceFiles() }
        add("File: Open PDF…", "folder", "⌘O") { [self] in choosePDF() }
        add("Library: Manage Watched Sources…", "folder.badge.gearshape") { [self] in showLibrarySources = true }
        add("Library: Refresh Libraries", "arrow.clockwise") { [self] in libraries.refresh() }
        add("Library: New Library…", "folder.badge.plus") { [self] in beginNewLibrary() }
        add("Library: New Library from Folder…", "folder.badge.plus") { [self] in chooseFolderForNewLibrary() }
        add("Library: Collapse All", "rectangle.compress.vertical") { [self] in reveal(.library); collapseLibrary() }
        add("Library: Reveal Book in Library", "scope", when: book) { [self] in reveal(.library); revealInLibrary() }
        if let current = workspace {
            add("Library: Rename “\(current.title)”…", "pencil") { [self] in
                reveal(.library)
                libraryQuery = ""
                revealInLibrary(bookID: current.id)
                if let row = libraryRows().first(where: { $0.bookID == current.id }) { beginLibraryRename(row, mode: .lemma) }
            }
        }
        for sort in LibrarySort.allCases where sort != librarySort {
            add("Library: Sort PDFs by \(sort.label)", "arrow.up.arrow.down") { [self] in librarySort = sort }
        }
        add("Papers: Search arXiv", "doc.text.magnifyingglass") { [self] in catalogMode = .arxiv; reveal(.catalog) }
        add("Project: New Research Project", "folder.badge.plus") { [self] in newProject() }
        add("Project: Collect Selection", "folder.badge.plus", "⇧⌘C", when: selected) { [self] in collectSelection() }
        for project in activeProjects {
            add("Project: Open “\(project.title)”", "folder") { [self] in openProject(project.id) }
        }
        if let project = currentProject {
            add("Project: Search “\(project.title)”", "magnifyingglass") { [self] in searchProject(project.id) }
            add("Project: Export “\(project.title)”…", "square.and.arrow.up") { [self] in exportProject(project.id) }
        }
        add("Preferences: Open Settings", "gearshape", "⌘,") { [self] in openSettingsEditor() }
        if ThemeManager.shared.style == .vscode {
            add("Preferences: Use the Classic Interface", "macwindow") { ThemeManager.shared.style = .classic }
        } else {
            add("Preferences: Use the VS Code-Style Interface", "macwindow") { ThemeManager.shared.style = .vscode }
            add("View: Customize Workbench…", "slider.horizontal.3") { [self] in showCustomization = true }
        }
        add("Preferences: Color Theme", "paintpalette", "⌥⌘T") { [self] in showThemePicker() }
        add("Preferences: Install Color Theme from File…", "paintpalette") { [self] in installThemeFromFile() }
        if let label = ThemeManager.shared.vscodeThemeLabel {
            add("Preferences: Use My VS Code Theme (\(label))", "paintpalette") { [self] in
                do { _ = try ThemeManager.shared.useVSCodeTheme() } catch { notify(error.localizedDescription, severity: .error, source: "Color Theme") }
            }
        }
        add("Preferences: Open Keyboard Shortcuts", "keyboard", "⌘/") { [self] in openShortcutsEditor() }
        add("Help: Welcome", "house") { [self] in openWelcome() }
        add("Help: Lemma Tour", "graduationcap") { [self] in TutorialCenter.shared.startTour(self) }
        add("Help: Lemma Guides", "graduationcap") { [self] in TutorialCenter.shared.open(self) }
        for guide in TutorialCenter.shared.guides.dropFirst() {
            add("Help: Lemma Guide › \(guide.title)", "graduationcap") { [self] in TutorialCenter.shared.open(self, guide: guide.id) }
        }
        add("Help: What’s New in Lemma", "info.circle") { [self] in openSpecial(.releaseNotes) }
        add(showMinimap ? "View: Hide Minimap" : "View: Show Minimap", "rectangle.righthalf.inset.filled") { [self] in showMinimap.toggle() }
        add("View: Toggle Zen Mode", "eye", "⌥⌘Z", when: book) { [self] in toggleFocus() }
        add("View: Toggle Maximized Panel", "chevron.up", when: book) { [self] in if !showPanel { showPanel = true }; panelMaximized.toggle() }
        add("Notifications: Show Notifications", "bell") { [self] in showNotificationCenter = true }
        add("Notifications: Clear All Notifications", "bell.slash", when: !notifications.isEmpty) { [self] in clearNotifications() }
        add(debug == nil ? "Debug: Start Debugging the Statement in View" : "Debug: Continue", "ladybug", "F5", when: book) { [self] in
            if debug == nil { startDebugging() } else { debugContinue() }
        }
        add("Debug: Step Over (Next Line)", "arrow.uturn.right", "F10", when: book) { [self] in debugStepOver() }
        add("Debug: Step Into the Cited Result", "arrow.down.to.line", "F11", when: book) { [self] in debugStepInto() }
        add("Debug: Step Out", "arrow.up.to.line", "⇧F11", when: debug != nil) { [self] in debugStepOut() }
        add("Debug: Restart", "arrow.clockwise", "⇧⌘F5", when: debug != nil) { [self] in debugRestart() }
        add("Debug: Stop", "stop.fill", "⇧F5", when: debug != nil) { [self] in stopDebugging() }
        add("Debug: Toggle Breakpoint", "circle.fill", "F9", when: book) { [self] in toggleBreakpoint() }
        add("Debug: Remove All Breakpoints", "circle.slash", when: !breakpoints.isEmpty) { [self] in breakpoints = []; saveWorkbench() }
        add("Testing: Run Due Tests", "play.fill", when: book) { [self] in runDueTests() }
        add("Testing: Run Tests in This Chapter", "forward.end.alt", when: analysis?.analysis != nil) { [self] in runChapterTests() }
        add("Testing: Focus on Test Explorer View", "checkmark.circle", when: book) { [self] in reveal(.testing) }
        for preset in LayoutPreset.allCases {
            add("Layout: \(preset.label)", preset.symbol) { [self] in applyLayout(preset) }
        }
        add("File: Close Book", "xmark", "⌘W", when: book) { [self] in closeBook() }
        add("File: Export Study Notes…", "square.and.arrow.up", "⌥⇧⌘E", when: book) { [self] in exportNotes() }
        add("File: Export My Edition as PDF…", "doc.richtext", when: book) { [self] in exportMyEdition() }
        add("File: Export Review Cards for Anki…", "rectangle.stack", when: book) { [self] in exportAnkiDeck() }
        add("Go to: Page, Section or Equation…", "arrow.right.square", "⌘P", when: book) { [self] in showPalette(.goTo) }
        add("Go to: Symbol…", "function", "⌘T", when: book) { [self] in showPalette(.symbols) }
        add("Go to: Back", "arrow.left", "⌥⌘←", when: reader.canGoBack) { [self] in reader.back() }
        add("Go to: Forward", "arrow.right", "⌥⌘→", when: reader.canGoForward) { [self] in reader.forward() }
        add("Go to: Next Book Tab", "arrow.right.to.line", "⌃⇥", when: tabs.count > 1) { [self] in cycleTab(1) }
        add("Go to: Previous Book Tab", "arrow.left.to.line", "⌃⇧⇥", when: tabs.count > 1) { [self] in cycleTab(-1) }
        add("View: Toggle Primary Side Bar", "sidebar.left", "⌘B") { [self] in toggleLibrary() }
        add("View: Toggle Secondary Side Bar", "sidebar.right", "⌥⌘B", when: book) { [self] in toggleStudy() }
        add("View: Toggle Panel", "rectangle.bottomthird.inset.filled", "⌘J", when: book) { [self] in togglePanel() }
        add("View: Split Editor", "rectangle.split.2x1", "⌘\\", when: book) { [self] in toggleSplit() }
        for section in NavigatorSection.allCases {
            add("View: Show \(section.title)", section.symbol) { [self] in reveal(section) }
        }
        for tab in PanelTab.allCases {
            add("View: Show \(tab.title) Panel", tab.symbol, when: book) { [self] in
                if focusMode { toggleFocus() }
                panelTab = tab; showPanel = true
            }
        }
        for layout in ReadingLayout.allCases {
            add("Reading: \(layout.label)", "doc.plaintext", when: book) { [self] in updateLayout(layout) }
        }
        add("Reading: Show the Original Edition (Hide My Marks)", "doc", when: book && reader.showAnnotations) { [self] in reader.showAnnotations = false }
        add("Reading: Show My Edition (with My Marks)", "doc.badge.ellipsis", when: book && !reader.showAnnotations) { [self] in reader.showAnnotations = true }
        for theme in PageTheme.allCases where theme != pageTheme {
            add("Reading: \(theme.label) Page", theme.symbol, when: book) { [self] in pageTheme = theme }
        }
        add(reader.showLineNumbers ? "View: Hide Line Numbers" : "View: Show Line Numbers", "list.number", "⌃⌘L", when: book) { [self] in reader.showLineNumbers.toggle() }
        add("Reading: Fit Page", "arrow.up.left.and.down.right.magnifyingglass", "⌘0", when: book) { [self] in reader.fit() }
        add("Reading: Fit Width", "arrow.left.and.right", when: book) { [self] in reader.fitWidth() }
        add("Reading: Zoom In", "plus.magnifyingglass", "⌘+", when: book) { [self] in reader.zoomIn() }
        add("Reading: Zoom Out", "minus.magnifyingglass", "⌘−", when: book) { [self] in reader.zoomOut() }
        add(pageIsBookmarked ? "Reading: Remove Bookmark" : "Reading: Bookmark Page", "bookmark", "⌘D", when: book) { [self] in toggleBookmark() }
        add("Study: Ask About Selection…", "text.bubble", "⌘K", when: selected) { [self] in prepareQuickAsk() }
        add("Study: Prepare Question…", "text.bubble.fill", "⌘E", when: currentNote?.question.isEmpty == false && currentNote?.pendingRequestID == nil) { [self] in showQuestion = true }
        add("Study: New Note from Selection", "square.and.pencil", "⌘N", when: selected) { [self] in addNote() }
        add("Study: Read Formula as LaTeX…", "curlybraces", when: selected) { [self] in readSelectedFormula() }
        add("Study: Save Selection as Definition", "text.book.closed", "⌥⌘S", when: selected) { [self] in addNote(kind: .definition) }
        add("Study: Add Margin Note", "note.text", "⌥⌘M", when: selected) { [self] in addMarginNote() }
        add("Study: Mark as Unclear (“?”)", "questionmark.circle", "⌥⌘/", when: selected || reader.rulerMode) { [self] in markUnclear() }
        add("Study: Resume at First “?” (\(openMarks.count) open)", "questionmark.circle.fill", "⌥⌘J", when: !openMarks.isEmpty) { [self] in resumeAtFirstMark() }
        add("Study: Pin Selection", "pin", "⌥⌘P", when: selected) { [self] in pinSelection() }
        add("Study: Highlight Selection", "highlighter", "⇧⌘H", when: selected) { [self] in highlightSelection() }
        add("Study: Underline Selection", "underline", "⇧⌘U", when: selected) { [self] in highlightSelection(style: .underline) }
        add("Study: Look Up Definition…", "character.book.closed", "⇧⌘L", when: book) { [self] in lookupSelection() }
        add(reader.regionMode ? "Study: Stop Capturing" : "Study: Capture a Region", "viewfinder", "⇧⌘S", when: book) { [self] in reader.regionMode.toggle() }
        add(reader.inkMode ? "Study: Stop Drawing" : "Study: Draw on My Edition", "pencil.tip", "⌥⇧⌘D", when: book) { [self] in reader.inkMode.toggle() }
        for kind in PageShapeKind.allCases {
            add("Study: Draw \(kind.label)", kind.symbol, when: book) { [self] in
                reader.inkMode = true; reader.drawingTool = DrawingTool(rawValue: kind.rawValue) ?? .rectangle
            }
        }
        add("Study: Review Notes", "arrow.clockwise", "⇧⌘R", when: book) { [self] in revealStudy(); studySection = .review }
        add("Study: Recognize Text on This Page…", "text.viewfinder", "⇧⌘O", when: book) { [self] in prepareOCR(useSelection: false) }
        add("Study: Dependencies & References…", "point.3.connected.trianglepath.dotted", when: currentNote != nil) { [self] in showDependencyMap = true }
        let analysed = analysis?.analysis != nil
        add(reader.rulerMode ? "Reading: Put the Ruler Away" : "Reading: Reading Ruler", "text.line.first.and.arrowtriangle.forward", "⌥⌘R", when: book) { [self] in reader.rulerMode.toggle() }
        add(allProofsFolded ? "Results: Unfold All Proofs" : "Results: Fold All Proofs (Prove It First)", "chevron.right.square", "⌥⌘[", when: !proofs.isEmpty) { [self] in toggleAllProofs() }
        add("Results: Show What the Statement in View Uses", "point.3.connected.trianglepath.dotted", "⇧⌥⌘H", when: analysed) { [self] in showHierarchyAtFocus() }
        add("Results: Dependency Map of This Chapter", "point.3.filled.connected.trianglepath.dotted", "⌥⌘G", when: analysed) { [self] in showMap() }
        if let statement = analysed ? statementAtFocus() : nil {
            add(isUnderstood(statement.key) ? "Results: Mark \(statement.key.title) as Not Understood" : "Results: Mark \(statement.key.title) as Understood",
                "checkmark.circle") { [self] in toggleUnderstood(statement.key) }
            add("Results: Add \(statement.key.title) to Review", "arrow.clockwise") { [self] in addStatementToReview(statement.key) }
            add("Results: Map What \(statement.key.title) Rests On", "point.3.filled.connected.trianglepath.dotted") { [self] in showMap(for: statement.key) }
        }
        if openMap != nil { add("Results: Close the Map", "xmark") { [self] in closeMap() } }
        add("Lab: New Notebook", "flask", when: book) { [self] in newLab() }
        add("Lab: Send Selection to Lab", "flask", "⌥⌘L", when: selected) { [self] in sendSelectionToLab() }
        add("Lab: Set Up Python for the Lab…", "shippingbox") { [self] in showPythonSetup() }
        if let labID = openLabID {
            add("Lab: Run All Cells", "forward.end.alt", when: book) { [self] in runAllLabCells(labID) }
            add("Lab: Interrupt", "stop.fill", when: lab.sessions[labID]?.state == .busy) { [self] in interruptLab(labID) }
            add("Lab: Restart Python", "arrow.clockwise", when: book) { [self] in restartLabKernel(labID) }
            add("Lab: Clear All Outputs", "eraser", when: book) { [self] in clearLabOutputs(labID) }
            add("Lab: Export as Jupyter Notebook…", "square.and.arrow.up", when: book) { [self] in exportLab(labID) }
            add("Lab: Close Notebook", "xmark", when: book) { [self] in closeLabEditor() }
        }
        for notebook in (workspace?.labs ?? []).prefix(12) where notebook.id != openLabID {
            add("Lab: Open “\(notebook.title)”", "flask", when: book) { [self] in openLabNotebook(notebook.id) }
        }
        add("Derivation: Work Through the Selection", "function", "⌥⌘E", when: book) { [self] in deriveSelection() }
        add("Derivation: New", "function", when: book) { [self] in newDerivation() }
        if let note = currentNote, note.explanation.map({ !DerivationTemplate.steps(fromAnswer: $0.body).isEmpty }) == true {
            add("Derivation: Check the Steps of the Saved Answer", "checkmark.seal", when: book) { [self] in checkAnswerSteps(noteID: note.id) }
        }
        if let id = openDerivationID, let derivation = derivation(id) {
            add("Derivation: Close “\(derivation.title)”", "xmark") { [self] in closeSideEditor("derivation:\(id)") }
            add("Derivation: Delete “\(derivation.title)”", "trash") { [self] in deleteDerivation(id) }
        }
        for derivation in (workspace?.derivations ?? []).prefix(12) where derivation.id != openDerivationID {
            add("Derivation: Open “\(derivation.title)”", "function", when: book) { [self] in openDerivation(derivation.id) }
        }
        for editor in sideEditors where editor.id != activeSideEditor?.id {
            add("View: Side Tab “\(sideTitle(editor))”", editor.symbol) { [self] in activateSideEditor(editor.id) }
        }
        add("Book: Index Pages for Search", "magnifyingglass.circle", when: book && !isLaunchingIndex) { [self] in startIndexing() }
        add("Book: Analyze Again", "arrow.triangle.2.circlepath", when: book && analysis?.isAnalyzing == false) { [self] in reanalyze() }
        add("Help: Assistants…", "link") { [self] in showBrowserSetup = true }
        add("Help: Report How Lemma Read This Book…", "text.book.closed", when: book) { [self] in reportBook() }
        return items
    }

    func reveal(_ section: NavigatorSection) {
        if focusMode { toggleFocus() }
        showLibrary = true
        navigatorSection = section
        // VS Code opens the view's pane when it reveals a view that shares its container with others.
        let pane: String? = switch section {
        case .library: "explorer.library"
        case .contents: "explorer.outline"
        case .timeline: "explorer.timeline"
        case .pages: "explorer.pages"
        case .results: "structure.results"
        case .symbols: "structure.symbols"
        case .index: "structure.index"
        default: nil
        }
        if let pane { paneExpanded[pane] = true }
    }

    func cycleTab(_ step: Int) {
        guard tabs.count > 1, let current = tabs.firstIndex(where: { $0.id == workspace?.id }) else { return }
        activateTab(tabs[(current + step + tabs.count) % tabs.count].id)
    }

    func reanalyze() {
        guard let workspace, let document else { return }
        analysis?.start(url: URL(fileURLWithPath: workspace.sourcePath), outline: OutlineEntry.items(in: document), force: true)
    }
}
