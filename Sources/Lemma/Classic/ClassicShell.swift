import SwiftUI
import AppKit
import PDFKit
import LemmaCore

/// Lemma 1.1's workbench in the native macOS style (unified toolbar, SF Symbols, system colours), kept as the
/// Classic interface style. The editors inside it are shared with the VS Code style.
struct ClassicShell: View {
    @Bindable var store: StudyStore
    @State private var pageInput = "1"
    @FocusState private var pageFocused: Bool
    /// The editor column's height, so the panel always leaves room for the page (the height is shared with the VS Code
    /// style, whose limit follows the window).
    @State private var columnHeight: CGFloat = 900

    var body: some View {
        toolbar(layout)
            .onChange(of: store.reader.pageNumber) { _, _ in syncPageInput() }
            .onChange(of: store.analysis?.analysis?.analyzedAt) { _, _ in syncPageInput() }
            .onAppear(perform: syncPageInput)
    }

    private var layout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if !store.focusMode, store.workbenchLayout.activityBar, store.workbenchLayout.sidebarPosition == .left {
                    ClassicActivityBar(store: store).tutorialAnchor(.activityBar)
                    Divider()
                }
                WorkspacePanes(store: store) { editorColumn }
                if !store.focusMode, store.workbenchLayout.activityBar, store.workbenchLayout.sidebarPosition == .right { Divider(); ClassicActivityBar(store: store).tutorialAnchor(.activityBar) }
            }
            ClassicStatusBar(store: store).tutorialAnchor(.statusBar)
        }
        .overlay(alignment: .top) { paletteOverlay }
        .background(WindowReader { window in
            store.attachWindow(window)
            if let window { store.titleBar.attach(window) }
            store.fitWindowToScreen()
        })
        .navigationTitle(store.activeDocumentTitle)
    }

    private func toolbar<Content: View>(_ content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button(action: store.toggleLibrary) { Image(systemName: "sidebar.left") }.help("Toggle sidebar · ⌘B").accessibilityLabel("Toggle sidebar")
                }
                ToolbarItem(placement: .principal) { ClassicCommandCenter(store: store) }
                ToolbarItemGroup(placement: .primaryAction) { toolbarActions }
            }
    }

    @ViewBuilder private var toolbarActions: some View {
        if store.document != nil && store.activeFileName == nil {
            Toggle(isOn: $store.reader.regionMode) { Label("Capture", systemImage: "viewfinder") }.toggleStyle(.button).help("Draw a source region · ⇧⌘S")
            Toggle(isOn: $store.reader.inkMode) { Label("Draw", systemImage: "pencil.tip") }.toggleStyle(.button).help("Write on My edition · ⌥⇧⌘D")
            Toggle(isOn: $store.reader.rulerMode) { Label("Ruler", systemImage: "text.line.first.and.arrowtriangle.forward") }.toggleStyle(.button)
                .help("Reading ruler: one line at a time, ↓ ↑ or J K to step, Return to open its reference · ⌥⌘R")
            Menu {
                ForEach(NoteKind.allCases, id: \.self) { kind in
                    Button { store.addNote(kind: kind) } label: { Label(kind.label, systemImage: kind.symbol) }
                }
            } label: { Label("New note", systemImage: "square.and.pencil") }.disabled(!store.reader.hasSelection).help("Save the selection as a question, definition, notation or theorem · ⌘N")
            Button { if store.reader.hasSelection { store.prepareQuickAsk() } else { store.showQuestion = true } } label: { Label("Ask", systemImage: "text.bubble") }
                .disabled(!store.reader.hasSelection && !canAsk).help("Ask about the selection · ⌘K, or prepare the current note’s question · ⌘E")
        }
        Button(action: store.togglePanel) { Image(systemName: store.showPanel ? "rectangle.bottomthird.inset.filled" : "rectangle.bottomhalf.inset.filled") }
            .help("Toggle panel: references, questions, notes · ⌘J").accessibilityLabel("Toggle panel").disabled(store.workspace == nil)
        Button(action: store.toggleStudy) { Image(systemName: "sidebar.right") }.help("Toggle notebook · ⌥⌘I").accessibilityLabel("Toggle notebook").disabled(store.workspace == nil)
        Menu {
            ForEach(LayoutPreset.allCases) { preset in Button { store.applyLayout(preset) } label: { Label(preset.label, systemImage: preset.symbol) } }
            Divider()
            Button("Customize Workbench…") { store.showCustomization = true }
            Button("Switch to the VS Code Interface") { ThemeManager.shared.style = .vscode }
        } label: { Label("Layout", systemImage: "slider.horizontal.3") }.help("Layout presets and workbench appearance").accessibilityLabel("Customize workbench")
    }

    private var canAsk: Bool { store.currentNote?.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && store.currentNote?.pendingRequestID == nil }

    private func syncPageInput() {
        guard !pageFocused else { return }
        let index = store.reader.pageNumber - 1
        pageInput = store.printedLabel(for: index) ?? String(store.reader.pageNumber)
    }

    private var editorColumn: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if !store.tabs.isEmpty || !store.fileTabs.isEmpty { ClassicEditorTabBar(store: store).tutorialAnchor(.editorTabs) }
                if let file = store.activeFile {
                    WorkspaceFileEditor(store: store, file: file)
                } else if let document = store.document, let workspace = store.workspace {
                    ClassicBreadcrumbBar(store: store, pageInput: $pageInput, pageFocused: $pageFocused).tutorialAnchor(.breadcrumbs)
                    Divider()
                    if store.reader.rulerMode && !store.reader.regionMode && !store.reader.inkMode && !store.reader.hasSelection { RulerBar(store: store); Divider() }
                    else { selectionBar.tutorialAnchor(.selectionBar); Divider() }
                    ResizablePair(store: store, id: "editor.groups", axis: .vertical, minimumFirst: 260, minimumSecond: 300, showsSecond: !store.sideEditors.isEmpty) {
                        HStack(spacing: 0) {
                            PDFReaderSurface(document: document, reading: workspace.reading, controller: store.reader, regionMode: store.reader.regionMode,
                                notes: workspace.notes, highlights: workspace.highlights, inkStrokes: workspace.inkStrokes, selectedNoteID: store.selectedNoteID,
                                showAnnotations: store.reader.showAnnotations, recallMask: store.reader.recallMask,
                                foldedProofs: Set(workspace.foldedProofs), understood: Set(workspace.understood))
                                .tutorialAnchor(.page)
                            OverviewRuler(store: store).tutorialAnchor(.overviewRuler)
                        }
                        .overlay(alignment: .top) { StickyStatementBar(store: store).padding(.trailing, 14) }
                        .overlay(alignment: .top) { if store.debug != nil { DebugToolbar(store: store).padding(.top, 8) } }
                        .overlay(alignment: .topTrailing) { if store.find.isVisible { FindWidget(store: store).padding(.top, 8).padding(.trailing, 22) } }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .modifier(EditorDropTarget(store: store))
                    } second: {
                    if !store.sideEditors.isEmpty {
                            SideEditorGroup(store: store).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                } else if case .project? = store.activeSideEditor {
                    SideEditorGroup(store: store)
                } else {
                    LibraryHome(store: store)
                        .modifier(EditorDropTarget(store: store))
                }
            }
            .frame(maxHeight: .infinity)
            if store.showPanel, store.workspace != nil {
                let maximum = max(110, Double(columnHeight) - 180)
                ClassicPanelResizeHandle(height: $store.panelHeight, maximum: maximum)
                BottomPanel(store: store).frame(height: min(store.panelHeight, maximum)).tutorialAnchor(.panel)
            }
        }
        .background(GeometryReader { geometry in
            Color.clear.onAppear { columnHeight = geometry.size.height }
                .onChange(of: geometry.size.height) { _, height in columnHeight = height }
        })
        .onChange(of: store.sideEditors.isEmpty) { _, _ in store.fitPageIfOverflowing() }
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            if store.reader.inkMode {
                Picker("Drawing tool", selection: $store.reader.inkEraser) {
                    Label("Pen", systemImage: "pencil.tip").tag(false); Label("Eraser", systemImage: "eraser").tag(true)
                }.pickerStyle(.segmented).frame(width: 150).labelsHidden()
                if !store.reader.inkEraser {
                    Picker("Ink color", selection: $store.reader.inkColor) {
                        ForEach(InkColor.allCases, id: \.self) { color in Text(color.label).tag(color) }
                    }.labelsHidden().fixedSize()
                    Picker("Pen width", selection: $store.reader.inkWidth) {
                        Text("Fine").tag(1.5); Text("Medium").tag(3.0); Text("Broad").tag(5.0)
                    }.labelsHidden().fixedSize()
                }
                Spacer(minLength: 0)
                Button { store.reader.inkMode = false } label: { Image(systemName: "xmark") }.help("Finish drawing")
            } else {
                Image(systemName: store.reader.regionMode ? "viewfinder" : "selection.pin.in.out").foregroundStyle(Color.lemmaOlive)
                Text(store.reader.hasSelection ? (store.reader.regionMode ? "Region selected" : "Text selected") : (store.reader.regionMode ? "Drag around an equation or passage" : "Select text to highlight or annotate")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .layoutPriority(-1)
                Spacer(minLength: 0)
                // Labels when they fit, icons when the editor is narrow (for example beside the side editor).
                ViewThatFits(in: .horizontal) {
                    selectionActions(labels: true)
                    selectionActions(labels: false)
                }
                if store.reader.regionMode { Button { store.reader.regionMode = false } label: { Image(systemName: "xmark") }.help("Return to text selection") }
            }
        }
        .font(.system(size: 12))
        .buttonStyle(.borderless).padding(.horizontal, 12).frame(height: 30).background(Color.lemmaOlive.opacity(0.07))
    }

    private func selectionActions(labels: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                Button { store.prepareQuickAsk() } label: { Label("Ask…", systemImage: "text.bubble").labelStyle(StudyLabelStyle(labels: labels)) }.help("Ask an assistant about this passage · ⌘K")
                Button(action: store.addNote) { Label("Note", systemImage: "square.and.pencil").labelStyle(StudyLabelStyle(labels: labels)) }.help("New note from the selection · ⌘N")
                Button { store.collectSelection() } label: { Label("Collect", systemImage: "folder.badge.plus").labelStyle(StudyLabelStyle(labels: labels)) }.help("Collect this passage in the current research project · ⇧⌘C")
                Button(action: store.addMarginNote) { Label("Comment", systemImage: "note.text").labelStyle(StudyLabelStyle(labels: labels)) }.help("Write a margin note beside this line · ⌥⌘M, or double-click the margin")
            }.disabled(!store.reader.hasSelection)
            HighlightMenu(store: store)
            Group {
                Button(action: store.pinSelection) { Label("Pin", systemImage: "pin").labelStyle(StudyLabelStyle(labels: labels)) }.help("Keep this passage in Context · ⌥⌘P")
                Button(action: store.sendSelectionToLab) { Label("Lab", systemImage: "flask").labelStyle(StudyLabelStyle(labels: labels)) }.help("Try this equation or passage in a Python notebook beside the page · ⌥⌘L")
                Button(action: store.deriveSelection) { Label("Derive", systemImage: "function").labelStyle(StudyLabelStyle(labels: labels)) }.help("Work through this step by step: each line you write is checked as you type · ⌥⌘E")
                Button(action: store.readSelectedFormula) { Label("LaTeX", systemImage: "curlybraces").labelStyle(StudyLabelStyle(labels: labels)) }.help("Read the formula's LaTeX locally and compare it with the original")
                Button(action: store.lookupSelection) { Label("Look up", systemImage: "character.book.closed").labelStyle(StudyLabelStyle(labels: labels)) }.help("The book's index and your glossary · ⇧⌘L or ⌘-click a term")
                Button { store.prepareOCR(useSelection: true) } label: { Label("OCR…", systemImage: "text.viewfinder").labelStyle(StudyLabelStyle(labels: labels)) }.help("Recognize and review this source text locally")
            }.disabled(!store.reader.hasSelection)
        }.fixedSize()
    }

    @ViewBuilder private var paletteOverlay: some View {
        if let request = store.palette {
            ZStack(alignment: .top) {
                Color.black.opacity(0.001).onTapGesture { store.closePalette() }
                ClassicCommandPaletteView(store: store, request: request).padding(.top, 6).id(request.id)
            }
        }
    }
}

/// The search field in the title bar that opens Go to, as an editor's command center.
/// It is a tappable view rather than a `Button`: SwiftUI on macOS 15 silently drops a toolbar item whose
/// content is a plain-styled button with a custom label.
struct ClassicCommandCenter: View {
    @Bindable var store: StudyStore

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11))
            Text(store.activeFileName ?? store.workspace.map { "\($0.title) · page, section, (3.41), a term…" } ?? "Go to a book or command…").lineLimit(1)
            Spacer(minLength: 6)
            Text("⌘P").font(.system(size: 10.5).monospaced()).foregroundStyle(.tertiary)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(width: 360, height: 24)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture { store.showPalette(.goTo) }
        .help("Go to a page, section, equation, figure, index term or note · ⌘P. Commands · ⇧⌘P")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Go to")
        .accessibilityAction { store.showPalette(.goTo) }
    }
}

/// The divider above the bottom panel: drag it to resize the panel, as in an editor.
struct ClassicPanelResizeHandle: View {
    @Binding var height: Double
    var maximum: Double = 620
    var body: some View {
        VSSash(axis: .horizontal, onDrag: { height = min(maximum, max(110, min(height, maximum) - $0)) },
               onDoubleClick: { height = min(240, maximum) })
            .accessibilityElement().accessibilityLabel("Panel height").accessibilityValue("\(Int(min(height, maximum))) points")
            .accessibilityAdjustableAction { direction in height = min(maximum, max(110, min(height, maximum) + (direction == .increment ? 40 : -40))) }
            .help("Drag to resize the panel; double-click to reset its height")
    }
}
