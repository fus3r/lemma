import SwiftUI
import AppKit

@main
struct LemmaApp: App {
    @State private var app = AppModel()

    init() { ChatGPTSession.disableTextSubstitutions() }

    var body: some Scene {
        WindowGroup("Lemma", for: UUID.self) { $id in
            ReaderScene(app: app, id: $id)
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified)
        .restorationBehavior(.disabled)
        .commands { LemmaCommands(app: app) }
        Settings { SettingsView(store: app.front) }
    }

    /// A function key as a menu shortcut (F5, F10…).
    static func function(_ number: Int) -> KeyEquivalent {
        let codes = [5: NSF5FunctionKey, 9: NSF9FunctionKey, 10: NSF10FunctionKey, 11: NSF11FunctionKey]
        return KeyEquivalent(Character(Unicode.Scalar(UInt32(codes[number] ?? NSF5FunctionKey))!))
    }
}


/// SwiftUI owns one store per window. Only the first window restores the session and starts shared services.
private struct ReaderScene: View {
    let app: AppModel
    @Binding var id: UUID?
    @State private var store: StudyStore?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let store {
                ReaderWindow(store: store).onOpenURL { store.openLink($0) }
            } else { Color.clear }
        }
        .frame(minWidth: 960, minHeight: 640)
        .tint(.lemmaOlive)
        .onAppear {
            guard store == nil else { return }
            let first = !app.restored
            app.openWindow = { [openWindow] id in openWindow(value: id) }
            let claimed = app.claimWindow(id)
            id = claimed.windowID; store = claimed
            if first {
                if Bundle.main.bundleURL.pathExtension != "app" { NSApp.setActivationPolicy(.regular) }
                if QAHooks.startsInBackground {
                    DispatchQueue.main.async { for window in NSApp.windows where window.styleMask.contains(.titled) { window.orderBack(nil) } }
                } else { NSApp.activate(ignoringOtherApps: true) }
                QAHooks.installIfRequested(store: claimed); app.libraries.start()
                if !TutorialCenter.shared.presentIfFirstLaunch(claimed) { claimed.offerVSCodeTheme() }
                Updates.shared.start()
                if !Updates.shared.isAvailable { UpdateChecker.shared.checkIfDue(store: claimed) }
            }
            app.openRestoredWindows()
        }
    }
}

/// Menu actions resolve their store from the front window, including when a sheet or Settings has the keyboard.
private struct LemmaCommands: Commands {
    let app: AppModel
    private var store: StudyStore { app.front }
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Lemma") { LemmaLinks.showAbout() }
            Button("Check for Updates…") { Updates.shared.checkForUpdates(store: store) }.disabled(!Updates.shared.canCheck)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { store.openSettingsEditor() }.keyboardShortcut(",")
            Button(ThemeManager.shared.style == .vscode ? "Use the Classic Interface" : "Use the VS Code-Style Interface") {
                ThemeManager.shared.style = ThemeManager.shared.style == .vscode ? .classic : .vscode
            }
            Button("Color Theme…") { store.showThemePicker() }.keyboardShortcut("t", modifiers: [.command, .option])
            Button("Install Color Theme from File…") { store.installThemeFromFile() }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Window") { app.newWindow() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Add New File…") { store.beginNewFile() }.keyboardShortcut("n", modifiers: [.control, .option, .command])
            Button("Open PDF…", action: store.choosePDF).keyboardShortcut("o")
            // The books read most recently, as a document app's Open Recent menu lists them.
            Menu("Open Recent") {
                ForEach(store.library.prefix(12)) { book in
                    Button(book.title) { store.reopen(book) }
                }
                if store.library.isEmpty { Button("No Recent Books") {}.disabled(true) }
            }
            Button("Open the Sample Book") { store.openSampleBook() }
            Button("New Library…") { store.beginNewLibrary() }
            Button("Manage Library Sources…") { store.showLibrarySources = true }
            Button("Refresh Libraries") { store.libraries.refresh() }
            Button("New Research Project") { store.newProject() }
            Button("Add Source Note", action: store.addNote).keyboardShortcut("n").disabled(!store.reader.hasSelection)
            Button("Export Study Notes…", action: store.exportNotes).keyboardShortcut("e", modifiers: [.command, .shift, .option]).disabled(store.workspace == nil)
            Button("Export My Edition as PDF…", action: store.exportMyEdition).disabled(store.workspace == nil)
            Button("Export Review Cards for Anki…", action: store.exportAnkiDeck).disabled(store.workspace == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save File") { store.saveActiveFile() }.keyboardShortcut("s").disabled(store.activeFile == nil)
            // ⌘W closes the editor in front, as in VS Code: Settings or Welcome before the book behind them.
            Button(store.activeFileName != nil ? "Close File" : store.activeSpecial != nil ? "Close Editor" : store.workspace == nil ? "Close Window" : "Close Book") {
                guard let key = NSApp.keyWindow, key === store.mainWindow else { NSApp.keyWindow?.performClose(nil); return }
                if let name = store.activeFileName { store.closeWorkspaceFile(name) }
                else if let special = store.activeSpecial { store.closeSpecial(special) }
                else if store.workspace != nil { store.closeBook() }
                else { key.performClose(nil) }
            }.keyboardShortcut("w")
            Button("Close All Books") { store.closeAllBooks() }.keyboardShortcut("w", modifiers: [.command, .shift]).disabled(store.tabs.isEmpty)
        }
        CommandMenu("Go") {
            Button("Command Palette…") { store.showPalette(.commands) }.keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Go to Page, Section or Equation…") { store.showPalette(.goTo) }.keyboardShortcut("p")
            Button("Go to Symbol…") { store.showPalette(.symbols) }.keyboardShortcut("t").disabled(store.document == nil)
            Divider()
            Button("Back", action: store.reader.back).keyboardShortcut(.leftArrow, modifiers: [.option, .command]).disabled(!store.reader.canGoBack)
            Button("Forward", action: store.reader.forward).keyboardShortcut(.rightArrow, modifiers: [.option, .command]).disabled(!store.reader.canGoForward)
            Divider()
            Button("Next Book") { store.cycleTab(1) }.keyboardShortcut(.tab, modifiers: .control).disabled(store.tabs.count < 2)
            Button("Previous Book") { store.cycleTab(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift]).disabled(store.tabs.count < 2)
        }
        CommandMenu("Study") {
            Toggle("Draw a Region", isOn: Bindable(store).reader.regionMode).keyboardShortcut("s", modifiers: [.command, .shift])
            Toggle("Handwritten Annotations", isOn: Bindable(store).reader.inkMode).keyboardShortcut("d", modifiers: [.command, .shift, .option])
            Toggle("Reading Ruler", isOn: Bindable(store).reader.rulerMode).keyboardShortcut("r", modifiers: [.command, .option]).disabled(store.document == nil)
            Button("Pin Selection", action: store.pinSelection).keyboardShortcut("p", modifiers: [.command, .option]).disabled(!store.reader.hasSelection)
            Button("Ask About Selection…", action: store.prepareQuickAsk).keyboardShortcut("k").disabled(!store.reader.hasSelection)
            Button("Prepare Question…") { store.showQuestion = true }.keyboardShortcut("e")
                .disabled(store.currentNote?.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false || store.currentNote?.pendingRequestID != nil)
            Button("Paste Explanation", action: store.pasteExplanation).disabled(store.currentNote == nil)
            Button("Add Margin Note", action: store.addMarginNote).keyboardShortcut("m", modifiers: [.command, .option]).disabled(!store.reader.hasSelection)
            Button("Collect Selection in Project") { store.collectSelection() }.keyboardShortcut("c", modifiers: [.command, .shift]).disabled(!store.reader.hasSelection)
            Button("Read Formula as LaTeX…", action: store.readSelectedFormula).disabled(!store.reader.hasSelection)
            Button("Mark as Unclear (“?”)", action: store.markUnclear).keyboardShortcut("/", modifiers: [.command, .option])
                .disabled(!store.reader.hasSelection && !store.reader.rulerMode)
            Button("Resume at First “?”", action: store.resumeAtFirstMark).keyboardShortcut("j", modifiers: [.command, .option])
                .disabled(store.openMarks.isEmpty)
            Button("Save Definition") { store.addNote(kind: .definition) }.keyboardShortcut("s", modifiers: [.command, .option]).disabled(!store.reader.hasSelection)
            Button("Look Up Definition…", action: store.lookupSelection).keyboardShortcut("l", modifiers: [.command, .shift]).disabled(store.document == nil)
            Button("Highlight Selection") { store.highlightSelection() }.keyboardShortcut("h", modifiers: [.command, .shift]).disabled(!store.reader.hasSelection)
            Button("Underline Selection") { store.highlightSelection(style: .underline) }.keyboardShortcut("u", modifiers: [.command, .shift]).disabled(!store.reader.hasSelection)
            Divider()
            Button("Send Selection to Lab", action: store.sendSelectionToLab).keyboardShortcut("l", modifiers: [.command, .option]).disabled(store.document == nil)
            Button("New Lab Notebook") { store.newLab() }.disabled(store.workspace == nil)
            Button("Set Up Python for the Lab…") { store.showPythonSetup() }
            Button("Work Through as a Derivation") { store.deriveSelection() }.keyboardShortcut("e", modifiers: [.command, .option]).disabled(store.document == nil)
            Button("Check the Steps of the Saved Answer") { if let id = store.currentNote?.id { store.checkAnswerSteps(noteID: id) } }
                .disabled(store.currentNote?.explanation == nil)
            Divider()
            Button("Index Pages for Search", action: store.startIndexing).disabled(store.document == nil || store.isLaunchingIndex)
            Button("Recognize Selected Region…") { store.prepareOCR(useSelection: true) }.disabled(!store.reader.hasSelection)
            Button("Recognize Current Page…") { store.prepareOCR(useSelection: false) }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(store.document == nil)
            Button("Review Notes") { store.revealStudy(); store.studySection = .review }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Dependencies & References…") { store.showDependencyMap = true }.disabled(store.currentNote == nil)
            Divider()
            Button(store.allProofsFolded ? "Unfold All Proofs" : "Fold All Proofs", action: store.toggleAllProofs)
                .keyboardShortcut("[", modifiers: [.command, .option]).disabled(store.proofs.isEmpty)
            Button("Show What This Statement Uses", action: store.showHierarchyAtFocus).keyboardShortcut("h", modifiers: [.shift, .option, .command])
                .disabled(store.analysis?.analysis == nil)
            Button("Dependency Map of This Chapter") { store.showMap() }.keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(store.analysis?.analysis == nil)
            Button("Analyze Book Again", action: store.reanalyze).disabled(store.document == nil || store.analysis?.isAnalyzing == true)
            Divider()
            Button("Assistants…") { store.showBrowserSetup = true }
        }
        CommandMenu("Run") {
            Button(store.debug == nil ? "Start Debugging" : "Continue") { store.debug == nil ? store.startDebugging() : store.debugContinue() }
                .keyboardShortcut(LemmaApp.function(5), modifiers: []).disabled(store.document == nil)
            Button("Stop Debugging") { store.stopDebugging() }.keyboardShortcut(LemmaApp.function(5), modifiers: .shift).disabled(store.debug == nil)
            Button("Restart Debugging") { store.debugRestart() }.keyboardShortcut(LemmaApp.function(5), modifiers: [.shift, .command]).disabled(store.debug == nil)
            Divider()
            Button("Step Over") { store.debugStepOver() }.keyboardShortcut(LemmaApp.function(10), modifiers: []).disabled(store.document == nil)
            Button("Step Back") { store.debugStepBack() }.keyboardShortcut(LemmaApp.function(10), modifiers: .shift).disabled(store.debug == nil)
            Button("Step Into") { store.debugStepInto() }.keyboardShortcut(LemmaApp.function(11), modifiers: []).disabled(store.document == nil)
            Button("Step Out") { store.debugStepOut() }.keyboardShortcut(LemmaApp.function(11), modifiers: .shift).disabled(store.debug == nil)
            Divider()
            Button("Toggle Breakpoint") { store.toggleBreakpoint() }.keyboardShortcut(LemmaApp.function(9), modifiers: []).disabled(store.document == nil)
            Button("Remove All Breakpoints") { store.breakpoints = []; store.saveWorkbench() }.disabled(store.breakpoints.isEmpty)
            Divider()
            Button("Run Due Tests") { store.runDueTests() }.disabled(store.workspace == nil)
            Button("Run Tests in This Chapter") { store.runChapterTests() }.disabled(store.analysis?.analysis == nil)
        }
        CommandGroup(replacing: .help) {
            Button("Lemma Tour") { TutorialCenter.shared.startTour(store) }
            Menu("Lemma Guides") {
                Button("All Guides…") { TutorialCenter.shared.open(store) }
                Divider()
                ForEach(TutorialCenter.shared.guides.dropFirst()) { guide in
                    Button(guide.title) { TutorialCenter.shared.open(store, guide: guide.id) }
                }
            }
            Divider()
            Button("Welcome") { store.openWelcome() }
            Button("Open the Sample Book") { store.openSampleBook() }
            Button("What’s New in Lemma") { store.openSpecial(.releaseNotes) }
            Button("Keyboard Shortcuts") { store.openShortcutsEditor() }.keyboardShortcut("/", modifiers: .command)
            Divider()
            Button("Assistants…") { store.showBrowserSetup = true }
            Divider()
            Button("Report an Issue…") { NSWorkspace.shared.open(LemmaLinks.newIssue()) }
            Button("Report How Lemma Read This Book…") { store.reportBook() }.disabled(store.workspace == nil)
            Button("Lemma on GitHub") { NSWorkspace.shared.open(LemmaLinks.site) }
            Button("Privacy") { NSWorkspace.shared.open(LemmaLinks.privacy) }
            Button("Acknowledgements") { store.showAcknowledgements = true }
        }
        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar", action: store.toggleLibrary).keyboardShortcut("b")
            Button("Toggle Secondary Side Bar", action: store.toggleStudy).keyboardShortcut("b", modifiers: [.command, .option])
            Button("Toggle Notebook", action: store.toggleStudy).keyboardShortcut("i", modifiers: [.command, .option])
            Button("Toggle Panel", action: store.togglePanel).keyboardShortcut("j").disabled(store.workspace == nil)
            Button("Python Console") { store.toggleConsole() }.keyboardShortcut("`", modifiers: .control).disabled(store.workspace == nil)
            Button(store.split == nil ? "Split Editor" : "Close Side Editor", action: store.toggleSplit).keyboardShortcut("\\").disabled(store.document == nil)
            Button("Zen Mode", action: store.toggleFocus).keyboardShortcut("z", modifiers: [.command, .option]).disabled(store.document == nil)
            Toggle("Minimap", isOn: Bindable(store).showMinimap)
            // VS Code's view shortcuts, which the activity bar shows.
            Button("Show Explorer") { store.reveal(.contents) }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("Show Search") { store.reveal(.search) }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Show Run and Debug") { store.reveal(.debug) }.keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Show Testing") { store.reveal(.testing) }
            Button("Show Catalog") { store.reveal(.catalog) }.keyboardShortcut("x", modifiers: [.command, .shift])
            Divider()
            Button("Find…") { store.find.show(store) }.keyboardShortcut("f").disabled(store.document == nil)
            Button("Find Next") { let find = store.find; if find.isVisible, !find.query.isEmpty { find.next() } else { find.show(store) } }
                .keyboardShortcut("g").disabled(store.document == nil)
            Button("Find Previous") { let find = store.find; if find.isVisible, !find.query.isEmpty { find.previous() } else { find.show(store) } }
                .keyboardShortcut("g", modifiers: [.command, .shift]).disabled(store.document == nil)
            Button("Show Outline") { store.reveal(.contents) }
            Button("Show Projects") { store.reveal(.projects) }
            Menu("Layout") { ForEach(LayoutPreset.allCases) { preset in Button(preset.label) { store.applyLayout(preset) } } }
            Button("Settings") { store.openSettingsEditor() }
            Button("Show Symbols") { store.reveal(.symbols) }
            Button("Show Index") { store.reveal(.index) }
            Button("Show Lab") { store.reveal(.lab) }
            Button("Bookmark Page", action: store.toggleBookmark).keyboardShortcut("d").disabled(store.document == nil)
            Divider()
            Toggle("Line Numbers", isOn: Bindable(store).reader.showLineNumbers).keyboardShortcut("l", modifiers: [.control, .command])
            Picker("Page Theme", selection: Binding(get: { store.pageTheme }, set: { store.pageTheme = $0 })) {
                ForEach(PageTheme.allCases) { theme in Text(theme.label).tag(theme) }
            }
            Button("Cycle Page Theme") { store.cyclePageTheme() }.keyboardShortcut("t", modifiers: [.control, .command])
            Divider()
            Button("Fit Page", action: store.reader.fit).keyboardShortcut("0").disabled(store.document == nil)
            Button("Zoom In", action: store.reader.zoomIn).keyboardShortcut("+").disabled(store.document == nil)
            Button("Zoom Out", action: store.reader.zoomOut).keyboardShortcut("-").disabled(store.document == nil)
        }
        // AppKit does not quit while a sheet is shown; Lemma closes it first, then quits and saves as usual.
        CommandGroup(replacing: .appTermination) {
            Button("Quit Lemma") { AppLifecycle.shared.quit() }.keyboardShortcut("q")
        }
    }
}
