import SwiftUI
import AppKit
import PDFKit
import LemmaCore

/// Lemma 1.1's interface, kept as the Classic interface style.
/// The vertical strip of view icons at the window's left edge. Clicking the current view hides the sidebar, as in an IDE.
struct ClassicActivityBar: View {
    @Bindable var store: StudyStore
    @Environment(\.workbenchDensity) private var density

    var body: some View {
        VStack(spacing: 4) {
            ForEach(NavigatorSection.allCases) { section in
                ClassicActivityButton(symbol: section.symbol, label: section.title, help: section.help,
                               selected: store.showLibrary && store.navigatorSection == section,
                               badge: badge(for: section)) {
                    if store.showLibrary && store.navigatorSection == section { store.toggleLibrary() }
                    else { store.reveal(section) }
                }
            }
            Spacer(minLength: 8)
            ClassicActivityButton(symbol: "link", label: "Assistants", help: "Assistants: ChatGPT, Codex, Claude Code, and API keys for OpenAI, Anthropic and Gemini",
                           selected: false, badge: nil) { store.showBrowserSetup = true }
            SettingsLink {
                Image(systemName: "gearshape").font(.system(size: 16)).frame(width: 34, height: density.iconHeight).foregroundStyle(.secondary)
            }.buttonStyle(.plain).help("Settings · ⌘,").accessibilityLabel("Settings")
        }
        .padding(.vertical, 8)
        .frame(width: 46)
        .frame(maxHeight: .infinity)
        .background(Color.lemmaChrome)
    }

    private func badge(for section: NavigatorSection) -> String? {
        switch section {
        case .search: store.reader.searchResults.isEmpty ? nil : "\(min(store.reader.searchResults.count, 99))"
        case .lab: store.lab.sessions.values.contains { $0.state == .busy } ? "•" : nil
        case .bookmarks: nil
        default: nil
        }
    }
}

private struct ClassicActivityButton: View {
    @Environment(\.workbenchDensity) private var density
    let symbol: String
    let label: String
    let help: String
    let selected: Bool
    let badge: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.lemmaOlive : (hovering ? Color.primary : Color.secondary))
                .frame(width: 34, height: density.iconHeight)
                .background(selected ? Color.lemmaOlive.opacity(0.16) : (hovering ? Color.primary.opacity(0.06) : .clear), in: RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text(badge).font(.system(size: 8.5, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                            .padding(.horizontal, 3.5).frame(minWidth: 13, minHeight: 13).background(Color.lemmaOlive, in: Capsule()).offset(x: 2, y: -2)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Open books as editor tabs. The current tab joins the page area; others recede.
struct ClassicEditorTabBar: View {
    @Bindable var store: StudyStore
    @Environment(\.workbenchDensity) private var density

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(store.tabs) { tab in
                        ClassicEditorTab(title: tab.title, cover: store.library.first { $0.id == tab.id }.flatMap { store.covers.cover(for: $0) },
                                  selected: tab.id == store.activeMainTabID,
                                  select: { store.activateTab(tab.id) }, close: { store.closeTab(tab.id) },
                                  closeOthers: { store.closeOtherTabs(keeping: tab.id) },
                                  move: { store.shiftBookTab(tab.id, by: $0) })
                            .draggable("lemma-tab:\(tab.id)")
                            .dropDestination(for: String.self) { values, _ in store.dropBookTab(values, onto: tab.id) }
                        Divider().frame(height: 18)
                    }
                    ForEach(store.fileTabs, id: \.self) { name in
                        HStack(spacing: 7) {
                            Button { store.openWorkspaceFile(name) } label: {
                                Label(name, systemImage: "doc.text").font(.system(size: 12, weight: store.activeFileName == name ? .medium : .regular)).lineLimit(1)
                            }.buttonStyle(.plain)
                            Button { store.closeWorkspaceFile(name) } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                                .buttonStyle(.plain).accessibilityLabel("Close \(name)")
                        }.padding(.horizontal, 12).frame(height: density.tabHeight)
                        .background(store.activeFileName == name ? Color.primary.opacity(0.07) : .clear)
                        Divider().frame(height: 18)
                    }
                }
            }
            // A tab dropped after the last one goes last.
            .dropDestination(for: String.self) { values, _ in store.dropBookTab(values, onto: nil) }
            Menu {
                Button("Add New File…") { store.beginNewFile() }
                Button("Open PDF…", action: store.choosePDF)
            } label: { Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 28, height: 28) }
                .menuStyle(.borderlessButton).fixedSize().help("Add a file or open a PDF").accessibilityLabel("Add File")
            Spacer(minLength: 0)
        }
        .frame(height: density.tabHeight)
        .background(Color.lemmaChrome)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct ClassicEditorTab: View {
    @Environment(\.workbenchDensity) private var density
    let title: String
    let cover: NSImage?
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    let closeOthers: () -> Void
    let move: (Int) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Button(action: select) {
                HStack(spacing: 7) {
                    Group {
                        if let cover { Image(nsImage: cover).resizable().scaledToFill() } else { Image(systemName: "book.closed").font(.system(size: 9)) }
                    }
                    .frame(width: 11, height: 15).clipShape(RoundedRectangle(cornerRadius: 1.5))
                    .overlay(RoundedRectangle(cornerRadius: 1.5).stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
                    Text(title).font(.system(size: 12, weight: selected ? .medium : .regular)).lineLimit(1)
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).frame(width: 16, height: 16)
                    .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).opacity(selected || hovering ? 1 : 0)
            .help("Close this book · ⌘W").accessibilityLabel("Close \(title)")
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(height: density.tabHeight).frame(minWidth: 120, maxWidth: 240)
        .background(selected ? Color.lemmaEditor : (hovering ? Color.primary.opacity(0.03) : .clear))
        .overlay(alignment: .top) { if selected { Rectangle().fill(Color.lemmaOlive).frame(height: 2) } }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Close", action: close)
            Button("Close Other Books", action: closeOthers)
            Divider()
            Button("Move Tab Left") { move(-1) }
            Button("Move Tab Right") { move(1) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(.default, select)
        .accessibilityAction(named: "Close", close)
    }
}

/// Book › Chapter › Section › Subsection for the reading position, each opening its siblings, with the editor's own controls on the right.
struct ClassicBreadcrumbBar: View {
    @Bindable var store: StudyStore
    @Environment(\.workbenchDensity) private var density
    @Binding var pageInput: String
    @FocusState.Binding var pageFocused: Bool
    @AppStorage(LemmaPreferences.referenceLinks) private var referenceLinks = true

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                Button(action: store.reader.back) { Image(systemName: "chevron.backward") }.disabled(!store.reader.canGoBack).help("Back · ⌥⌘←")
                Button(action: store.reader.forward) { Image(systemName: "chevron.forward") }.disabled(!store.reader.canGoForward).help("Forward · ⌥⌘→")
            }.font(.system(size: 11, weight: .medium)).fixedSize()
            crumbs.frame(maxWidth: .infinity, alignment: .leading).clipped()
            pageControls.fixedSize()
            Divider().frame(height: 14)
            editorMenus.fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: density.barHeight)
        .frame(maxWidth: .infinity)
        .background(Color.lemmaEditor)
    }

    /// The path from the book to the current subsection. Every crumb shrinks with an ellipsis when space runs out,
    /// the current section last; clicking one lists its siblings, as in an editor's breadcrumbs.
    private var crumbs: some View {
        let path = store.breadcrumb()
        return HStack(spacing: 3) {
            crumb(store.workspace?.title ?? "", symbol: "book.closed", priority: 0) { store.outline }
            ForEach(Array(path.enumerated()), id: \.element.id) { offset, entry in
                Image(systemName: "chevron.compact.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                crumb(entry.title, symbol: nil, priority: offset == path.count - 1 ? 3 : 1) { siblings(at: offset, path: path) }
            }
            // The statement being read, as an editor's breadcrumb ends at the symbol under the cursor.
            if store.analysis?.analysis != nil, let reading = store.readingStatement() {
                Image(systemName: "chevron.compact.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                HStack(spacing: 4) {
                    KindBadge(key: reading.statement.key, size: 12)
                    Text(reading.label).lineLimit(1).fixedSize()
                }
                .padding(.horizontal, 3).frame(height: 20)
                .contentShape(Rectangle())
                .onTapGesture { store.showHierarchy(reading.statement.key) }
                .help("\(reading.label) · click for what it uses and what uses it")
                .layoutPriority(2)
            }
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Location in the book")
    }

    private func crumb(_ title: String, symbol: String?, priority: Double, entries: @escaping () -> [OutlineEntry]) -> some View {
        // When space runs out a crumb shows its section number (“2.3”), then shrinks with an ellipsis.
        let short = OutlineMap.numberPrefix(of: title)
        return HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11)) }
            ViewThatFits(in: .horizontal) {
                Text(title).lineLimit(1).fixedSize()
                if let short, priority < 3 { Text(short).lineLimit(1).fixedSize() }
                Text(title).lineLimit(1).truncationMode(.tail)
            }
        }
        .foregroundStyle(priority >= 3 ? Color.primary : Color.secondary)
        .padding(.horizontal, 3).frame(height: 20)
        .contentShape(Rectangle())
        .onTapGesture { showMenu(entries()) }
        .layoutPriority(priority)
        .help(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { showMenu(entries()) }
    }

    /// A native menu of outline entries at the pointer.
    private func showMenu(_ entries: [OutlineEntry]) {
        guard !entries.isEmpty, let window = store.mainWindow, let content = window.contentView else { return }
        let menu = NSMenu()
        let current = Set(store.breadcrumb().map(\.id))
        for entry in entries {
            let item = ActionMenuItem(entry.title) { [store] in store.go(to: entry) }
            item.state = current.contains(entry.id) ? .on : .off
            menu.addItem(item)
        }
        let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: point, in: content)
    }

    private func siblings(at offset: Int, path: [OutlineEntry]) -> [OutlineEntry] {
        offset == 0 ? store.outline : (path[offset - 1].children ?? [])
    }

    private var pageControls: some View {
        HStack(spacing: 4) {
            Button(action: store.reader.previousPage) { Image(systemName: "chevron.up") }.disabled(store.reader.pageNumber <= 1).help("Previous page")
            Button(action: store.reader.nextPage) { Image(systemName: "chevron.down") }.disabled(store.reader.pageNumber >= store.reader.pageCount).help("Next page")
            TextField("Page", text: $pageInput).frame(width: 40).multilineTextAlignment(.center).textFieldStyle(.roundedBorder).controlSize(.small)
                .focused($pageFocused)
                .onSubmit {
                    if let index = store.pageIndex(forTyped: pageInput) { store.reader.goToPage(index + 1) }
                    pageInput = store.printedLabel(for: store.reader.pageNumber - 1) ?? String(store.reader.pageNumber); pageFocused = false
                    // The keyboard goes back to the page just reached: clearing the focus binding leaves AppKit's field
                    // editor in place, and ⌘F or the arrow keys would still act on the field.
                    if let view = store.reader.view { view.window?.makeFirstResponder(view) }
                }
                .accessibilityLabel("Page").help(store.printedLabel(for: 0) != nil || store.analysis?.numbering?.differsFromPhysical == true ? "Printed page number; type “pdf 31” for a PDF page" : "PDF page")
            Text(pageSuffix).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).fixedSize()
        }.font(.system(size: 11, weight: .medium))
    }

    private var pageSuffix: String {
        let index = store.reader.pageNumber - 1
        return store.printedLabel(for: index) != nil ? "PDF \(index + 1)/\(store.reader.pageCount)" : "/ \(store.reader.pageCount)"
    }

    private var editorMenus: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("Page layout", selection: Binding(get: { store.workspace?.reading.layout ?? .standard }, set: { store.updateLayout($0) })) {
                    ForEach(ReadingLayout.allCases, id: \.self) { layout in Text(layout.label).tag(layout) }
                }
                Divider()
                Picker("Edition", selection: $store.reader.showAnnotations) {
                    Text("Original").tag(false); Text("My edition").tag(true)
                }.pickerStyle(.inline)
                Divider()
                Picker("Page", selection: Binding(get: { store.pageTheme }, set: { store.pageTheme = $0 })) {
                    ForEach(PageTheme.allCases) { theme in Label(theme.label, systemImage: theme.symbol).tag(theme) }
                }.pickerStyle(.inline)
                Divider()
                Toggle("Line Numbers", isOn: $store.reader.showLineNumbers)
                Toggle("Link References", isOn: $referenceLinks)
                Button("Export My Edition as PDF…", action: store.exportMyEdition)
            } label: { Image(systemName: "doc.text.magnifyingglass") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22).help("Layout and edition")
                .accessibilityLabel("Reading layout").accessibilityValue(store.reader.showAnnotations ? "My edition" : "Original")
            Menu {
                Button("Fit Page", action: store.reader.fit)
                Button("Fit Width", action: store.reader.fitWidth)
                Divider()
                ForEach([75, 100, 125, 150, 200], id: \.self) { percent in
                    Button("\(percent)%") { store.reader.view?.autoScales = false; store.reader.view?.scaleFactor = CGFloat(percent) / 100 }
                }
            } label: { Text("\(Int(store.reader.scale * 100))%").font(.system(size: 11).monospacedDigit()) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Zoom")
            Button(action: store.toggleBookmark) { Image(systemName: store.pageIsBookmarked ? "bookmark.fill" : "bookmark") }
                .help("Bookmark page · ⌘D").accessibilityLabel("Bookmark current page")
            Button(action: store.toggleSplit) { Image(systemName: store.split == nil ? "rectangle.split.2x1" : "rectangle.split.2x1.fill") }
                .help("Split editor: keep another page beside this one · ⌘\\").accessibilityLabel("Split editor")
        }.font(.system(size: 12))
    }
}

/// The IDE status bar. It takes the accent colour while a mode changes what clicks do (capture, drawing).
struct ClassicStatusBar: View {
    @Bindable var store: StudyStore
    @State private var editingReturnNote = false
    @State private var showingReading = false

    private var mode: (label: String, symbol: String, active: Bool) {
        if store.reader.regionMode { return ("Capture", "viewfinder", true) }
        if store.reader.inkMode { return ("Draw", "pencil.tip", true) }
        if store.focusMode { return ("Focus", "eye", false) }
        return ("Read", "book", false)
    }

    var body: some View {
        let mode = mode
        HStack(spacing: 0) {
            if let file = store.activeFile {
                item { Label(file.id, systemImage: "doc.text").lineLimit(1) }
            } else if store.workspace != nil {
                item {
                    Label(mode.label, systemImage: mode.symbol).labelStyle(.titleAndIcon)
                }
                .background(mode.active ? Color.lemmaOlive : Color.clear)
                .foregroundStyle(mode.active ? Color.white : Color.secondary)
                .help(mode.active ? "Click to return to reading" : "Reading mode")
                .onTapGesture { store.reader.regionMode = false; store.reader.inkMode = false }
                if let analysis = store.analysis {
                    if let progress = analysis.progress {
                        item {
                            HStack(spacing: 5) {
                                ProgressView(value: progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0).progressViewStyle(.circular).controlSize(.mini)
                                Text(progress.total > 0 ? "Reading the book \(progress.done)/\(progress.total)" : "Reading the book…").monospacedDigit()
                            }
                        }.help("Lemma reads the whole book once, locally: page numbers, equations, figures, index and references.")
                    } else if let result = analysis.analysis {
                        item { Label(summary(result), systemImage: "checkmark.seal") }
                            .help("Read on this Mac: printed page numbers, numbered objects, the index and the reference list. ⌘T lists the symbols.")
                            .onTapGesture { store.reveal(.symbols) }
                    }
                }
                if let section = store.breadcrumb().last {
                    item { Text(section.title).lineLimit(1) }.onTapGesture { store.reveal(.contents) }.help("Current section · click to show the outline")
                }
                if store.reader.rulerMode, let line = store.reader.rulerLine {
                    item { Label("Ruler · line \(line.index + 1)/\(line.count)", systemImage: "text.line.first.and.arrowtriangle.forward").monospacedDigit() }
                        .background(Color.lemmaOlive).foregroundStyle(Color.white)
                        .help("Reading ruler · ↓ ↑ or J K to step, Escape to stop").onTapGesture { store.reader.rulerMode = false }
                }
                // Problems, as an editor counts errors and warnings: failing derivation steps and open “?” marks.
                let counts = store.problemCounts
                item {
                    HStack(spacing: 7) {
                        Label("\(counts.errors)", systemImage: "xmark.circle").foregroundStyle(counts.errors > 0 ? Color.red : Color.secondary)
                        Label("\(counts.warnings)", systemImage: "questionmark.circle").foregroundStyle(counts.warnings > 0 ? Color.orange : Color.secondary)
                    }
                    .labelStyle(.titleAndIcon).monospacedDigit()
                }
                .help("\(counts.errors) failing derivation \(counts.errors == 1 ? "step" : "steps") · \(counts.warnings) open “?” \(counts.warnings == 1 ? "mark" : "marks") · click for the Problems panel")
                .onTapGesture { store.showProblems() }
                let folded = store.workspace?.foldedProofs.count ?? 0
                if folded > 0 {
                    item { Label("\(folded) \(folded == 1 ? "proof" : "proofs") folded", systemImage: "chevron.right.square").monospacedDigit() }
                        .foregroundStyle(Color.lemmaOlive)
                        .help("Proofs folded away to try first · click to show the book's results").onTapGesture { store.reveal(.results) }
                }
                if let labID = store.openLabID {
                    let session = store.lab.sessions[labID]
                    item {
                        Label(labStatus(session), systemImage: "flask").lineLimit(1)
                    }
                    .background(session?.state == .busy ? Color.lemmaOlive : Color.clear)
                    .foregroundStyle(session?.state == .busy ? Color.white : Color.secondary)
                    .onTapGesture { store.reveal(.lab) }
                    .help(store.lab.interpreter.map { "Lab · \($0.summary)" } ?? "Lab")
                }
            } else {
                item { Text("Lemma · an IDE for reading mathematics") }
            }
            Spacer(minLength: 8)
            if !store.browserStatus.isEmpty {
                item { Label(store.browserStatus, systemImage: "text.bubble").lineLimit(1) }.onTapGesture { store.showBrowserSetup = true }
            } else if !store.status.isEmpty {
                item { Text(store.status).lineLimit(1) }
            }
            if let file = store.activeFile {
                item { Text(file.isMarkdown ? "Markdown · UTF-8" : "Plain Text · UTF-8") }
            } else if let workspace = store.workspace {
                item {
                    Button { showingReading = true } label: {
                        Label("Today \(ReadingLog.describeShort(store.secondsToday))", systemImage: "clock").lineLimit(1)
                    }.buttonStyle(.plain)
                }
                .help("Reading time today · click for the last two weeks")
                .popover(isPresented: $showingReading, arrowEdge: .top) { ReadingStatsView(store: store) }
                let due = workspace.notes.filter { $0.isDue() }.count
                if due > 0 {
                    item { Label("\(due) due", systemImage: "arrow.clockwise") }.onTapGesture { store.revealStudy(); store.studySection = .review }.help("Notes due for recall · ⇧⌘R")
                }
                item {
                    Button { editingReturnNote = true } label: {
                        Label(workspace.reading.returnNote.isEmpty ? "Next time" : workspace.reading.returnNote, systemImage: "arrow.turn.down.right").lineLimit(1).frame(maxWidth: 200)
                    }.buttonStyle(.plain)
                }
                .help("A thought for next time: where to pick up")
                .popover(isPresented: $editingReturnNote, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Next time").font(.headline)
                        TextField("Where should you pick up?", text: Binding(get: { store.workspace?.reading.returnNote ?? "" }, set: { store.updateReturnNote($0) }), axis: .vertical)
                            .lineLimit(2...5).textFieldStyle(.roundedBorder).frame(width: 300).accessibilityLabel("Thought for next time")
                    }.padding(14)
                }
                item { Text(pageSummary).monospacedDigit() }.onTapGesture { store.showPalette(.goTo) }.help("Go to a page, or a line as “64:12” · ⌘P")
                item {
                    Image(systemName: store.saveFailed ? "exclamationmark.circle" : store.isSaving ? "circle.dotted" : "checkmark.circle")
                        .foregroundStyle(store.saveFailed ? Color.red : Color.secondary)
                }.help(store.saveFailed ? "Not saved" : store.isSaving ? "Saving…" : "Saved locally")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(height: 24)
        .background(Color.lemmaChrome)
        .overlay(alignment: .top) { Divider() }
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

    /// “p. 64 · Ln 12/45 · PDF 83 of 764”: the page and, as an editor shows Ln, the line where the reader is looking.
    private var pageSummary: String {
        let index = store.reader.pageNumber - 1
        var line = ""
        if store.reader.focusPageIndex == index, let y = store.reader.focusY, let found = store.reader.lineIndex(onPage: index, y: y) {
            line = " · Ln \(found.index + 1)/\(found.count)"
        }
        if let printed = store.printedLabel(for: index) { return "p. \(printed)\(line) · PDF \(index + 1) of \(store.reader.pageCount)" }
        return "Page \(index + 1)\(line) of \(store.reader.pageCount)"
    }

    private func summary(_ analysis: BookAnalysis) -> String {
        let kinds = Dictionary(grouping: Set(analysis.definitions.map(\.key)), by: \.kind)
        var parts: [String] = []
        func count(_ number: Int, _ noun: String) { if number > 0 { parts.append("\(number) \(noun)\(number == 1 ? "" : "s")") } }
        count(kinds[.equation]?.count ?? 0, "equation")
        count(kinds[.figure]?.count ?? 0, "figure")
        count(analysis.structure.statements.count, "statement")
        count(analysis.structure.proofs.count, "proof")
        if !analysis.index.isEmpty { parts.append("index") }
        count(analysis.bibliography.count, "reference")
        return parts.isEmpty ? "Book read" : parts.joined(separator: " · ")
    }

    private func item<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(.horizontal, 8).frame(maxHeight: .infinity).contentShape(Rectangle())
    }
}
