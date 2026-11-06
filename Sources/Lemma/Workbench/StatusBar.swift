import SwiftUI
import AppKit
import LemmaCore

/// VS Code's status bar: 22 pt, 12 pt text with codicons, a coloured indicator at the far left, items that tint on
/// hover. It turns to the debugging colour while a proof is being stepped through.
///
/// Each item is its own view and reads only what it shows: the reading position changes on every line while the page
/// scrolls, and only “p. 34, Ln 12” is redrawn for it, not the counts, summaries and timers beside it.
struct VSStatusBar: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme

    var body: some View {
        let _ = QAPerf.tick("StatusBar")
        let debugging = store.debug != nil
        // The book and its workspace open and close together; the document changes far less often than the workspace.
        let empty = store.document == nil
        let background: TC = debugging ? .statusBarDebuggingBackground : empty ? .statusBarNoFolderBackground : .statusBarBackground
        let foreground: TC = debugging ? .statusBarDebuggingForeground : empty ? .statusBarNoFolderForeground : .statusBarForeground
        // The items are an overlay of a bar whose size never depends on them: an item's text changes as the page scrolls
        // (“Ln 12”), and laid out in the window's own stack each change would measure the whole window again.
        theme[background]
            .frame(height: VSMetrics.statusBarHeight)
            .frame(maxWidth: .infinity)
            .overlay {
                HStack(spacing: 0) {
                    if let file = store.activeFile {
                        StatusItem(icon: file.icon, text: file.id) {}
                    } else {
                        ModeIndicator(store: store)
                        if !empty {
                            AnalysisStatusItem(store: store)
                            ProblemsStatusItem(store: store)
                            DebugStatusItem(store: store)
                            LabStatusItem(store: store)
                            FoldedStatusItem(store: store)
                        } else {
                            StatusItem(icon: "lemma", text: "Lemma · an IDE for reading mathematics") { store.openWelcome() }
                        }
                    }
                    Spacer(minLength: 8)
                    MessageStatusItem(store: store)
                    if let file = store.activeFile {
                        StatusItem(icon: nil, text: "Ln \(file.cursorLine), Col \(file.cursorColumn)" + (file.selectedCharacters > 0 ? " (\(file.selectedCharacters) selected)" : "")) {}
                        StatusItem(icon: nil, text: "Spaces: 4") {}
                        StatusItem(icon: nil, text: "UTF-8") {}
                        StatusItem(icon: nil, text: file.text.contains("\r\n") ? "CRLF" : "LF") {}
                        StatusItem(icon: file.icon, text: file.isMarkdown ? "Markdown" : "Plain Text") {}
                    } else if !empty && store.activeSpecial == nil {
                        PagePositionStatusItem(store: store)
                        PhysicalPageStatusItem(store: store)
                        ZoomStatusItem(store: store)
                        PageThemeStatusItem(store: store)
                        ReadingTimeStatusItem(store: store)
                        DueStatusItem(store: store)
                        ReturnNoteStatusItem(store: store)
                        SaveStatusItem(store: store)
                    }
                    NotificationsStatusItem(store: store)
                }
                .font(.ui(12))
                .foregroundStyle(theme[foreground])
            }
            .vsBorder(.top, debugging ? .statusBarDebuggingBorder : .statusBarBorder, theme: theme)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status Bar")
    }
}

/// The whole-book analysis: its progress while reading the book, then a summary of what it found.
private struct AnalysisStatusItem: View {
    @Bindable var store: StudyStore

    var body: some View {
        if let analysis = store.analysis {
            if let progress = analysis.progress {
                StatusItem(icon: "sync", spinning: true, text: progress.total > 0 ? "Reading the book \(progress.done)/\(progress.total)" : "Reading the book…") {}
                    .help("Lemma reads the whole book once, locally: page numbers, equations, figures, statements, the index and references.")
            } else if analysis.analysis != nil {
                StatusItem(icon: "symbol-structure", text: summary(analysis)) { store.reveal(.results) }
                    .help("Read on this Mac: printed page numbers, numbered objects, statements and proofs, the index and the reference list.")
            }
        }
    }

    private func summary(_ model: BookAnalysisModel) -> String {
        guard let analysis = model.analysis else { return "Book read" }
        var parts: [String] = []
        if let equations = model.definitionCounts[.equation], equations > 0 { parts.append("\(equations) eq.") }
        if let figures = model.definitionCounts[.figure], figures > 0 { parts.append("\(figures) fig.") }
        let statements = analysis.structure.statements.count
        if statements > 0 { parts.append("\(statements) results") }
        if !analysis.bibliography.isEmpty { parts.append("\(analysis.bibliography.count) refs") }
        return parts.isEmpty ? "Book read" : parts.joined(separator: " · ")
    }
}

private struct ProblemsStatusItem: View {
    @Bindable var store: StudyStore

    var body: some View {
        let counts = store.problemCounts
        StatusItem(content: AnyView(HStack(spacing: 4) {
            Codicon("error", size: 16); Text("\(counts.errors)").monospacedDigit()
            Codicon("warning", size: 16).padding(.leading, 2); Text("\(counts.warnings)").monospacedDigit()
        })) { store.showProblems() }
            .help("\(counts.errors) failing derivation \(counts.errors == 1 ? "step" : "steps") · \(counts.warnings) open “?” \(counts.warnings == 1 ? "mark" : "marks")")
    }
}

/// The proof being debugged, or the reading ruler's line.
private struct DebugStatusItem: View {
    @Bindable var store: StudyStore

    var body: some View {
        if let debug = store.debug {
            StatusItem(icon: "debug-alt", text: store.frameTitle(debug.top, line: store.reader.rulerLine) + (debug.frames.count > 1 ? " · depth \(debug.frames.count)" : "")) { store.reveal(.debug) }
                .help("Run and Debug: \(debug.statusText)")
        } else if store.reader.rulerMode, let line = store.reader.rulerLine {
            StatusItem(icon: "symbol-ruler", text: "Ruler · line \(line.index + 1)/\(line.count)") { store.reader.rulerMode = false }
                .help("Reading ruler · ↓ ↑ or J K to step · click to stop")
        }
    }
}

private struct LabStatusItem: View {
    @Bindable var store: StudyStore

    var body: some View {
        if let labID = store.openLabID {
            let session = store.lab.sessions[labID]
            StatusItem(icon: session?.state == .busy ? "loading" : "notebook", spinning: session?.state == .busy, text: labStatus(session)) { store.reveal(.lab) }
                .help(store.lab.interpreter.map { "Lab · \($0.summary)" } ?? "Lab")
        }
    }

    private func labStatus(_ session: LabSession?) -> String {
        guard let session else { return store.lab.interpreter.map { "Python \($0.version)" } ?? "Lab" }
        switch session.state {
        case .busy: return "Running" + (session.queued.isEmpty ? "" : " · \(session.queued.count) queued")
        case .starting: return "Starting Python…"
        case .idle: return "Python \(session.python ?? "") · idle"
        case .stopped: return "Python stopped"
        }
    }
}

private struct FoldedStatusItem: View {
    @Bindable var store: StudyStore

    var body: some View {
        let folded = store.workspace?.foldedProofs.count ?? 0
        if folded > 0 {
            StatusItem(icon: "fold", text: "\(folded) folded") { store.reveal(.results) }.help("Proofs folded away to try first")
        }
    }
}

private struct MessageStatusItem: View {
    @Bindable var store: StudyStore

    var body: some View {
        if !store.browserStatus.isEmpty {
            StatusItem(icon: "comment-discussion", text: store.browserStatus) { store.showBrowserSetup = true }
        } else if !store.status.isEmpty {
            StatusItem(icon: nil, text: store.status) {}
        }
    }
}

/// “p. 34, Ln 12”: the only item that follows the reading position line by line.
private struct PagePositionStatusItem: View {
    @Bindable var store: StudyStore

    var body: some View {
        let _ = QAPerf.tick("StatusBar.position")
        StatusItem(icon: nil, text: pagePosition) { store.showPalette(.goTo) }.help("Go to a page, or a line as “64:12” (⌘P)")
    }

    private var pagePosition: String {
        let index = store.reader.pageNumber - 1
        let page = store.printedLabel(for: index) ?? String(index + 1)
        if store.reader.focusPageIndex == index, let line = store.reader.focusLine { return "p. \(page), Ln \(line + 1)" }
        return "p. \(page)"
    }
}

private struct PhysicalPageStatusItem: View {
    @Bindable var store: StudyStore

    var body: some View {
        StatusItem(icon: nil, text: "PDF \(store.reader.pageNumber)/\(store.reader.pageCount)") { store.showPalette(.goTo, text: "pdf ") }
            .help("Physical page of the PDF")
    }
}

private struct ZoomStatusItem: View {
    @Bindable var store: StudyStore

    var body: some View {
        StatusMenuItem(icon: "zoom-in", text: "\(Int(store.reader.scale * 100))%", help: "Zoom") {
            [.action("Fit Page", shortcut: "⌘0") { store.reader.fit() }, .action("Fit Width") { store.reader.fitWidth() }, .separator]
                + [75, 100, 125, 150, 200].map { percent in
                    .action("\(percent)%", checked: Int(store.reader.scale * 100) == percent) { store.reader.view?.autoScales = false; store.reader.view?.scaleFactor = CGFloat(percent) / 100 }
                }
        }
    }
}

private struct PageThemeStatusItem: View {
    @Bindable var store: StudyStore

    var body: some View {
        // The theme is read from the defaults; the revision is what tells SwiftUI that it changed.
        let _ = store.pageThemeRevision
        StatusMenuItem(icon: nil, text: store.pageTheme.label, help: "Page theme (⌃⌘T)") {
            PageTheme.allCases.map { page in .action(page.label, checked: page == store.pageTheme) { store.pageTheme = page } }
        }
    }
}

private struct ReadingTimeStatusItem: View {
    @Bindable var store: StudyStore
    @State private var showingReading = false

    var body: some View {
        StatusItem(icon: "clock", text: ReadingLog.describeShort(store.secondsToday)) { showingReading = true }
            .help("Reading time today · click for the last two weeks")
            .popover(isPresented: $showingReading, arrowEdge: .top) { ReadingStatsView(store: store) }
    }
}

private struct DueStatusItem: View {
    @Bindable var store: StudyStore

    var body: some View {
        let due = store.workspace?.notes.filter { $0.isDue() }.count ?? 0
        if due > 0 {
            StatusItem(icon: "beaker", text: "\(due) due") { store.reveal(.testing) }.help("Recall tests due (⇧⌘R)")
        }
    }
}

private struct ReturnNoteStatusItem: View {
    @Bindable var store: StudyStore
    @State private var editingReturnNote = false

    var body: some View {
        let note = store.workspace?.reading.returnNote ?? ""
        StatusItem(icon: "milestone", text: note.isEmpty ? "Next time" : note) { editingReturnNote = true }
            .frame(maxWidth: 220)
            .help("A thought for next time: where to pick up")
            .popover(isPresented: $editingReturnNote, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Next time").font(.headline)
                    TextField("Where should you pick up?", text: Binding(get: { store.workspace?.reading.returnNote ?? "" }, set: { store.updateReturnNote($0) }), axis: .vertical)
                        .lineLimit(2...5).textFieldStyle(.roundedBorder).frame(width: 300).accessibilityLabel("Thought for next time")
                }.padding(14)
            }
    }
}

private struct SaveStatusItem: View {
    @Bindable var store: StudyStore

    var body: some View {
        StatusItem(icon: store.saveFailed ? "error" : store.isSaving ? "sync" : "check", spinning: store.isSaving, text: nil) {}
            .help(store.saveFailed ? "Not saved" : store.isSaving ? "Saving…" : "Saved on this Mac")
    }
}

private struct NotificationsStatusItem: View {
    @Bindable var store: StudyStore

    var body: some View {
        StatusItem(icon: store.notifications.isEmpty ? "bell" : "bell-dot", text: nil) { store.showNotificationCenter.toggle() }
            .help(store.notifications.isEmpty ? "No Notifications" : "\(store.notifications.count) Notifications")
    }
}

/// The coloured block at the far left (VS Code's remote indicator): the reading mode, with a menu of modes.
private struct ModeIndicator: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        let (icon, label) = mode
        VSMenu(items: {
            [.action("Read", checked: label.isEmpty) { store.reader.regionMode = false; store.reader.inkMode = false; store.reader.rulerMode = false },
             .action("Capture a Region", checked: store.reader.regionMode, enabled: store.document != nil, shortcut: "⇧⌘S") { store.reader.regionMode = true },
             .action("Draw on My Edition", checked: store.reader.inkMode, enabled: store.document != nil, shortcut: "⌥⇧⌘D") { store.reader.inkMode = true },
             .action("Reading Ruler", checked: store.reader.rulerMode, enabled: store.document != nil, shortcut: "⌥⌘R") { store.reader.rulerMode = true },
             .action(store.debug == nil ? "Debug the Statement in View (F5)" : "Stop Debugging (⇧F5)", enabled: store.document != nil) {
                 if store.debug == nil { store.startDebugging() } else { store.stopDebugging() }
             },
             .separator,
             .action(store.focusMode ? "Leave Zen Mode" : "Zen Mode", shortcut: "⌥⌘Z") { store.toggleFocus() }]
        }, placement: .above) {
            HStack(spacing: 4) {
                Codicon(icon, size: 16)
                if !label.isEmpty { Text(label).font(.ui(12)) }
            }
            .foregroundStyle(theme[.statusBarItemRemoteForeground])
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .background(theme[hovering ? .statusBarItemRemoteHoverBackground : .statusBarItemRemoteBackground])
        }
        .onHover { hovering = $0 }
        .help("Reading mode")
        .accessibilityLabel("Reading mode: \(label.isEmpty ? "Read" : label)")
    }

    private var mode: (String, String) {
        if store.debug != nil { return ("debug-alt", "Debugging") }
        if store.reader.regionMode { return ("inspect", "Capture") }
        if store.reader.inkMode { return ("edit", store.reader.drawingTool.label) }
        if store.reader.rulerMode { return ("symbol-ruler", "Ruler") }
        if store.focusMode { return ("eye", "Zen") }
        return ("remote", "")
    }
}

/// One status bar entry: an optional codicon and text, tinted on hover.
struct StatusItem: View {
    @Environment(\.theme) private var theme
    var icon: String?
    var spinning = false
    var text: String?
    var content: AnyView? = nil
    let action: () -> Void
    @State private var hovering = false

    init(icon: String?, spinning: Bool = false, text: String?, action: @escaping () -> Void) {
        self.icon = icon; self.spinning = spinning; self.text = text; self.action = action
    }
    init(content: AnyView, action: @escaping () -> Void) { self.content = content; self.action = action }

    var body: some View {
        Group {
            if let content { content }
            else { StatusLabel(icon: icon, spinning: spinning, text: text) }
        }
        .padding(.horizontal, 5)
        .frame(maxHeight: .infinity)
        .background(hovering ? theme[.statusBarItemHoverBackground] : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .padding(.horizontal, 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

struct StatusLabel: View {
    var icon: String?
    var spinning = false
    var text: String?
    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                if icon == "lemma" { LemmaGlyph(size: 14) }
                // A spinning icon exists only while it spins and turns in Core Animation. A SwiftUI animation repeated
                // forever redrew the whole window at the display's rate, and kept doing so once a save had ended.
                else if spinning { SpinningCodicon(name: icon, size: 16) }
                else { Codicon(icon, size: 16) }
            }
            if let text { Text(text).lineLimit(1) }
        }
    }
}

/// A codicon turning as VS Code's `~spin` icons do. Core Animation runs the turn, so the window is not redrawn for it.
struct SpinningCodicon: NSViewRepresentable {
    let name: String
    var size: CGFloat = 16
    var color: TC = .statusBarForeground
    @Environment(\.theme) private var theme

    func makeNSView(context: Context) -> SpinnerView { SpinnerView(frame: NSRect(x: 0, y: 0, width: size, height: size)) }
    func updateNSView(_ view: SpinnerView, context: Context) {
        view.show(Codicons.image(name, size: size, color: theme.ns(color)))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SpinnerView, context: Context) -> CGSize? { CGSize(width: size, height: size) }

    final class SpinnerView: NSView {
        private let glyph = CALayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            glyph.contentsGravity = .center
            layer?.addSublayer(glyph)
        }
        required init?(coder: NSCoder) { nil }

        func show(_ image: NSImage?) {
            glyph.contents = image
            glyph.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            guard glyph.animation(forKey: "spin") == nil else { return }
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 1.2
            spin.repeatCount = .infinity
            glyph.add(spin, forKey: "spin")
        }
        override func layout() {
            super.layout()
            glyph.frame = bounds
        }
        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            glyph.contentsScale = window?.backingScaleFactor ?? 2
        }
    }
}

/// A status bar entry that opens a menu.
private struct StatusMenuItem: View {
    @Environment(\.theme) private var theme
    let icon: String?
    let text: String
    let help: String
    let items: () -> [VSMenuItem]
    @State private var hovering = false
    var body: some View {
        VSMenu(items: items, placement: .above) {
            StatusLabel(icon: icon, text: text)
                .padding(.horizontal, 5).frame(maxHeight: .infinity)
                .background(hovering ? theme[.statusBarItemHoverBackground] : .clear)
        }
        .padding(.horizontal, 1)
        .onHover { hovering = $0 }
        .help(help)
    }
}
