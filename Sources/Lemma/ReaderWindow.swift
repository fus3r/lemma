import SwiftUI
import AppKit
import PDFKit
import LemmaCore

/// The workbench, laid out as VS Code's: title bar with the command center, activity bar, side bar, editor groups
/// (tabs, breadcrumbs, the page with its minimap and overview ruler, the side group), the panel, the secondary side
/// bar and the status bar. Colours come from the colour theme (`ThemeManager`).
struct ReaderWindow: View {
    @Bindable var store: StudyStore
    @State private var themes = ThemeManager.shared
    @AppStorage(LemmaPreferences.referenceLinks) private var referenceLinks = true
    @AppStorage(LemmaPreferences.referenceCounts) private var referenceCounts = true
    @AppStorage("workbench.startupEditor") private var startupEditor = "welcomePage"
    @State private var fullScreen = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let colors = themes.colors
        lifecycle(sheets(root))
            .environment(\.theme, colors)
            // The Classic style's Settings window: macOS 14 ignores the old `showSettingsWindow:` action.
            .onAppear { store.openSettingsScene = { [openSettings] in openSettings() } }
            // lemma:// links go to the open window rather than opening another one on the same library. (Here rather
            // than on the scene's root view, whose type names the window's saved frame.)
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            .preferredColorScheme(colors.isDark ? .dark : .light)
            .tint(colors.accent)
    }

    /// VS Code's workbench, or Lemma 1.1's native one, as the reader chose in Settings.
    @ViewBuilder private var root: some View {
        Group {
            if themes.style == .classic {
                ClassicShell(store: store)
                    .overlay(alignment: .bottomTrailing) { NotificationsOverlay(store: store).padding(.bottom, 24) }
            } else {
                shell
            }
        }
        // The tour, over either interface; it lights up the parts of the window that report their frames.
        .overlayPreferenceValue(TutorialAnchorKey.self) { anchors in TutorialOverlay(store: store, anchors: anchors) }
    }

    private var shell: some View {
        VStack(spacing: 0) {
            VSTitleBar(store: store, fullScreen: fullScreen).tutorialAnchor(.titleBar)
            HStack(spacing: 0) {
                if !store.focusMode, store.workbenchLayout.activityBar, store.workbenchLayout.sidebarPosition == .left { VSActivityBar(store: store).tutorialAnchor(.activityBar) }
                WorkspacePanes(store: store) { editorColumn }
                if !store.focusMode, store.workbenchLayout.activityBar, store.workbenchLayout.sidebarPosition == .right { VSActivityBar(store: store).tutorialAnchor(.activityBar) }
            }
            VSStatusBar(store: store).tutorialAnchor(.statusBar)
        }
        .background(themes.colors[.editorBackground])
        .overlay(alignment: .top) { paletteOverlay }
        .overlay(alignment: .bottomTrailing) { NotificationsOverlay(store: store).padding(.bottom, VSMetrics.statusBarHeight) }
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowReader { window in
            store.attachWindow(window)
            if let window { store.titleBar.attach(window); fullScreen = window.styleMask.contains(.fullScreen) }
            store.fitWindowToScreen()
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in fullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in fullScreen = false }
        .navigationTitle(store.activeDocumentTitle)
    }

    private func sheets<Content: View>(_ content: Content) -> some View {
        content
            .sheet(isPresented: $store.showQuestion) { QuestionSheet(store: store).environment(\.theme, themes.colors) }
            .sheet(isPresented: $store.showBrowserSetup) { AssistantPane(store: store).environment(\.theme, themes.colors) }
            .sheet(isPresented: $store.showLibrarySources) { LibrarySourcesSheet(store: store).environment(\.theme, themes.colors) }
            .sheet(isPresented: $store.showHighlightColors) { HighlightColorsSheet(store: store).environment(\.theme, themes.colors) }
            .sheet(isPresented: $store.showNewFile) { NewWorkspaceFileSheet(store: store).environment(\.theme, themes.colors) }
            .sheet(isPresented: $store.showAcknowledgements) { AcknowledgementsView().environment(\.theme, themes.colors) }
            .sheet(isPresented: $store.showDependencyMap) { DependencyMapPane(store: store).tint(.lemmaOlive) }
            .sheet(isPresented: $store.showShortcuts) { ShortcutsSheet().tint(.lemmaOlive) }
            .sheet(item: $store.ocrCapture) { capture in ocrPane(capture) }
            .sheet(item: $store.formulaRequest) { request in FormulaPane(store: store, request: request) }
            .sheet(isPresented: $store.showCustomization) {
                VStack(spacing: 0) {
                    HStack { Text("Workbench").font(.title2.weight(.semibold)); Spacer(); Button("Done") { store.showCustomization = false }.keyboardShortcut(.defaultAction) }.padding(20)
                    Divider()
                    WorkbenchAppearanceView(store: store)
                }.frame(width: 610, height: 680)
            }
            .sheet(isPresented: $store.showReleaseNotes) {
                VStack(spacing: 0) {
                    ReleaseNotesEditor(store: store).frame(width: 760, height: 620)
                    Divider()
                    HStack { Spacer(); Button("Done") { store.showReleaseNotes = false }.keyboardShortcut(.defaultAction) }.padding(12)
                }
            }
            // Classic keeps 1.1's alert; the VS Code style shows errors as notifications that do not stop the reader.
            .alert("Lemma", isPresented: Binding(get: { themes.style == .classic && store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("OK") { store.error = nil }
            } message: { Text(store.error ?? "") }
            .onChange(of: store.error) { _, message in
                guard themes.style == .vscode, let message else { return }
                store.notify(message, severity: .error)
                store.error = nil
            }
    }

    private func ocrPane(_ capture: OCRCapture) -> some View {
        OCRPane(pngData: capture.pngData, pageLabel: "PDF page \(capture.anchor.pageIndex + 1) · label \(capture.anchor.pageLabel)",
            sourceLabel: capture.sourceLabel, initialText: capture.indexedPage?.text,
            commitLabel: capture.indexedPage == nil ? "Create source note" : "Save corrected index",
            onCreateNote: { text in
                if capture.indexedPage != nil { store.saveIndexReview(capture, text: text) }
                else { store.createNoteFromOCR(capture, text: text) }
            })
            .tint(.lemmaOlive)
    }

    private func lifecycle<Content: View>(_ content: Content) -> some View {
        content
            // Assistant answers are collected only while a question waits for one.
            .background(QuestionPoller(store: store))
            .onChange(of: store.reader.inkMode) { _, drawing in if drawing { store.reader.showAnnotations = true } }
            .onChange(of: referenceLinks) { _, value in store.reader.showReferenceLinks = value }
            .onChange(of: referenceCounts) { _, value in store.reader.showReferenceCounts = value }
            .onChange(of: themes.revision) { _, _ in store.applyAppearance() }
            // Turning the reading ruler off ends a debug session, whose current line it is.
            .onChange(of: store.reader.rulerMode) { _, on in if !on, store.debug != nil { store.stopDebugging() } }
            .onChange(of: themes.style) { _, style in
                // Settings, Welcome and the other editor tabs are the VS Code style's; Classic shows the book.
                if style == .classic { store.activeSpecial = nil }
                if let window = store.mainWindow { store.titleBar.attach(window) }
            }
            .onChange(of: SessionViewState(store: store)) { _, _ in store.saveWorkbench() }
            .onAppear { themes.startFollowingSystem(); store.applyAppearance() }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        switch url.pathExtension.lowercased() {
                        case "pdf": store.open(url)
                        case "json", "vsix":
                            do {
                                let installed = try ThemeManager.shared.install(from: url)
                                if let first = installed.first { ThemeManager.shared.choose(first.id); store.notify("Installed the theme \(first.label).", source: "Color Theme") }
                            } catch { store.notify("Could not install this theme: \(error.localizedDescription)", severity: .error, source: "Color Theme") }
                        default: break
                        }
                    }
                }
                return true
            }
    }

    private var editorColumn: some View {
        GeometryReader { geometry in
            // Room above the panel for the tabs, the breadcrumbs, the passage toolbar (always shown since 2.3.2) and some page.
            let maximumPanel = max(110, geometry.size.height - 180)
            let fittedPanel = min(store.panelHeight, maximumPanel)
            VStack(spacing: 0) {
                if !(store.panelMaximized && store.showPanel && store.workspace != nil) {
                    VStack(spacing: 0) {
                        // With a book open the tab bar belongs to the first group, so a second group's tabs sit level with it.
                        if !readingBook, !store.tabs.isEmpty || !store.specialTabs.isEmpty || !store.fileTabs.isEmpty { MainEditorTabs(store: store).tutorialAnchor(.editorTabs) }
                        mainEditor
                    }
                    .frame(maxHeight: .infinity)
                }
                if store.showPanel, store.workspace != nil {
                    if !store.panelMaximized {
                        VSSash(axis: .horizontal, onDrag: { delta in store.panelHeight = min(maximumPanel, max(110, min(store.panelHeight, maximumPanel) - delta)) },
                               onDoubleClick: { store.panelHeight = min(240, maximumPanel) })
                            .accessibilityElement()
                            .accessibilityLabel("Panel height")
                            .accessibilityValue("\(Int(fittedPanel)) points")
                            .accessibilityAdjustableAction { direction in
                                store.panelHeight = min(maximumPanel, max(110, fittedPanel + (direction == .increment ? 20 : -20)))
                            }
                            .help("Drag to resize the panel; double-click to reset its height")
                    }
                    BottomPanel(store: store)
                        .tutorialAnchor(.panel)
                        .frame(height: store.panelMaximized ? nil : fittedPanel)
                        .frame(maxHeight: store.panelMaximized ? .infinity : nil)
                }
            }
        }
        .onChange(of: store.sideEditors.isEmpty) { _, _ in store.fitPageIfOverflowing() }
    }

    private var readingBook: Bool { store.activeFileName == nil && store.activeSpecial == nil && store.document != nil && store.workspace != nil }

    @ViewBuilder private var mainEditor: some View {
        if let file = store.activeFile {
            WorkspaceFileEditor(store: store, file: file)
        } else if let special = store.activeSpecial {
            SpecialEditorView(store: store, editor: special)
                .modifier(EditorDropTarget(store: store))
        } else if let document = store.document, let workspace = store.workspace {
            // Each group owns its tab bar, breadcrumbs and editor actions, as VS Code's split editor groups do.
            ResizablePair(store: store, id: "editor.groups", axis: .vertical, minimumFirst: 260, minimumSecond: 300, showsSecond: !store.sideEditors.isEmpty) {
                VStack(spacing: 0) {
                    MainEditorTabs(store: store).tutorialAnchor(.editorTabs)
                    VSBreadcrumbs(store: store).tutorialAnchor(.breadcrumbs)
                    if store.reader.rulerMode && !store.reader.regionMode && !store.reader.inkMode && !store.reader.hasSelection && store.debug == nil { RulerBar(store: store) }
                    else { selectionBar.tutorialAnchor(.selectionBar) }
                    HStack(spacing: 0) {
                        PDFReaderSurface(document: document, reading: workspace.reading, controller: store.reader, regionMode: store.reader.regionMode,
                            notes: workspace.notes, highlights: workspace.highlights, inkStrokes: workspace.inkStrokes, shapes: workspace.shapes, selectedNoteID: store.selectedNoteID,
                            showAnnotations: store.reader.showAnnotations, recallMask: store.reader.recallMask,
                            foldedProofs: Set(workspace.foldedProofs), understood: Set(workspace.understood))
                            .tutorialAnchor(.page)
                        if store.showMinimap { PageMinimap(store: store).tutorialAnchor(.minimap) }
                        OverviewRuler(store: store).tutorialAnchor(.overviewRuler)
                    }
                    .overlay(alignment: .top) { StickyStatementBar(store: store).padding(.trailing, store.showMinimap ? 110 : 14) }
                    .overlay(alignment: .top) { if store.debug != nil { DebugToolbar(store: store).padding(.top, 8) } }
                    .overlay(alignment: .topTrailing) {
                        if store.find.isVisible { FindWidget(store: store).padding(.top, 8).padding(.trailing, store.showMinimap ? 118 : 22) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The gutter and minimap draw past their frames while scrolling; keep them off the tab bar.
                    .clipped()
                    .modifier(EditorDropTarget(store: store))
                }
            } second: {
                if !store.sideEditors.isEmpty {
                    SideEditorGroup(store: store).frame(maxWidth: .infinity, maxHeight: .infinity).tutorialAnchor(.sideEditors)
                }
            }
        } else if case .project? = store.activeSideEditor {
            SideEditorGroup(store: store)
        } else if startupEditor == "none" {
            EditorWatermark()
                .modifier(EditorDropTarget(store: store))
        } else {
            SpecialEditorView(store: store, editor: .welcome)
                .modifier(EditorDropTarget(store: store))
        }
    }

    @ViewBuilder private var selectionBar: some View {
        if store.reader.inkMode {
            AnnotationToolbox(store: store)
        } else {
        let theme = themes.colors
        HStack(spacing: 10) {
                Codicon(store.reader.regionMode ? "inspect" : "selection", size: 16).foregroundStyle(theme.accent)
                Text(store.reader.hasSelection ? (store.reader.regionMode ? "Region selected" : "Text selected") : (store.reader.regionMode ? "Drag around an equation or passage" : "Select text to highlight or annotate")).font(.ui(12)).foregroundStyle(theme[.descriptionForeground]).lineLimit(1)
                    .layoutPriority(-1)
                Spacer(minLength: 0)
                ViewThatFits(in: .horizontal) {
                    selectionActions(labels: true)
                    selectionActions(labels: false)
                }
                if store.reader.regionMode { VSIconButton(icon: "close", help: "Return to Text Selection") { store.reader.regionMode = false } }
        }
        .font(.ui(12))
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).frame(height: 30)
        .background(theme[.editorWidgetBackground])
        .vsBorder(.bottom, .editorWidgetBorder, theme: theme)
        .vsBorder(.top, .editorGroupHeaderTabsBorder, theme: theme)
        }
    }

    private func selectionActions(labels: Bool) -> some View {
        HStack(spacing: 2) {
            Group {
                SelectionAction(icon: "comment-discussion", title: "Ask", help: "Ask an assistant about this passage (⌘K)", labels: labels) { store.prepareQuickAsk() }
                SelectionAction(icon: "note", title: "Note", help: "New note from the selection (⌘N)", labels: labels) { store.addNote() }
                SelectionAction(icon: "comment", title: "Comment", help: "Margin note beside this line (⌥⌘M)", labels: labels) { store.addMarginNote() }
            }.disabled(!store.reader.hasSelection)
            HighlightMenu(store: store)
            Group {
                SelectionAction(icon: "pin", title: "Pin", help: "Keep this passage in Context (⌥⌘P)", labels: labels) { store.pinSelection() }
                SelectionAction(icon: "notebook", title: "Lab", help: "Try it in a Python notebook beside the page (⌥⌘L)", labels: labels) { store.sendSelectionToLab() }
                SelectionAction(icon: "symbol-operator", title: "Derive", help: "Work through it step by step, each line checked (⌥⌘E)", labels: labels) { store.deriveSelection() }
                SelectionAction(icon: "bracket", title: "LaTeX", help: "Read the formula's LaTeX locally", labels: labels) { store.readSelectedFormula() }
                SelectionAction(icon: "book", title: "Look Up", help: "The book's index and your glossary (⇧⌘L)", labels: labels) { store.lookupSelection() }
                SelectionAction(icon: "folder-library", title: "Collect", help: "Collect in the research project (⇧⌘C)", labels: labels) { store.collectSelection() }
                SelectionAction(icon: "eye", title: "OCR", help: "Recognize this source text locally", labels: labels) { store.prepareOCR(useSelection: true) }
            }.disabled(!store.reader.hasSelection)
        }.fixedSize()
    }

    @ViewBuilder private var paletteOverlay: some View {
        if let request = store.palette {
            ZStack(alignment: .top) {
                Color.black.opacity(0.001).onTapGesture { store.closePalette() }
                CommandPaletteView(store: store, request: request).id(request.id)
            }
        }
    }
}

private struct SelectionAction: View {
    @Environment(\.isEnabled) private var enabled
    let icon: String
    let title: String
    let help: String
    let labels: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) { SelectionActionLabel(icon: icon, title: title, labels: labels) }
            .buttonStyle(.plain).help(help).accessibilityLabel(title)
            .opacity(enabled ? 1 : 0.4)
    }
}

private struct SelectionActionLabel: View {
    @Environment(\.theme) private var theme
    let icon: String
    let title: String
    let labels: Bool
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 4) {
            Codicon(icon, size: 16)
            if labels { Text(title).font(.ui(12)) }
        }
        .foregroundStyle(theme[.foreground])
        .padding(.horizontal, labels ? 6 : 3).frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? theme[.toolbarHoverBackground] : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// One observation keeps the window's generic modifier chain small.
private struct SessionViewState: Equatable {
    let library: Bool
    let study: Bool
    let panel: Bool
    let panelTab: PanelTab
    let navigator: NavigatorSection
    let studySection: StudySection
    let selectedNote: UUID?
    let sidebar: SidebarPosition
    let activity: Bool
    let special: SpecialEditor?
    let specials: [SpecialEditor]
    @MainActor init(store: StudyStore) {
        library = store.showLibrary; study = store.showStudy; panel = store.showPanel; panelTab = store.panelTab
        navigator = store.navigatorSection; studySection = store.studySection; selectedNote = store.selectedNoteID
        sidebar = store.workbenchLayout.sidebarPosition; activity = store.workbenchLayout.activityBar
        special = store.activeSpecial; specials = store.specialTabs
    }
}

/// Title and icon in a wide editor, icon alone in a narrow one.
struct StudyLabelStyle: LabelStyle {
    let labels: Bool
    func makeBody(configuration: Configuration) -> some View {
        if labels { HStack(spacing: 4) { configuration.icon; configuration.title } } else { configuration.icon }
    }
}

/// Reports the hosting window, so window-level commands can tell the reader window from Settings or sheets.
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    init(_ found: @escaping (NSWindow?) -> Void) { self.found = found }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in found(view?.window) }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in if let window = view?.window { found(window) } }
    }
}
