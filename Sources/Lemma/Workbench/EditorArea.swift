import SwiftUI
import AppKit
import PDFKit
import LemmaCore

/// One editor tab as VS Code draws it: 35 pt, icon and label, the close button on hover or when active,
/// a 1 pt accent line on top of the active tab, separators between tabs.
struct VSTab: View {
    @Environment(\.theme) private var theme
    @Environment(\.controlActiveState) private var activeState
    let icon: String
    let title: String
    var description: String? = nil
    var active: Bool
    var groupFocused = true
    var badge: Int? = nil
    var dirty = false
    var cover: NSImage? = nil
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false
    @State private var hoveringClose = false

    var body: some View {
        let focused = groupFocused && activeState != .inactive
        HStack(spacing: 0) {
            Group {
                if let cover {
                    Image(nsImage: cover).resizable().scaledToFill().frame(width: 12, height: 16).clipShape(RoundedRectangle(cornerRadius: 1.5))
                        .overlay(RoundedRectangle(cornerRadius: 1.5).stroke(theme[.tabBorder].opacity(0.8), lineWidth: 0.5))
                        .frame(width: 16, height: 16)
                } else { FileIcon(kind: icon) }
            }.padding(.trailing, 6)
            Text(title).font(.ui(13)).lineLimit(1)
                .foregroundStyle(theme[active ? (focused ? .tabActiveForeground : .tabUnfocusedActiveForeground) : (hovering ? .tabHoverForeground : (focused ? .tabInactiveForeground : .tabUnfocusedInactiveForeground))])
            if let description {
                Text(description).font(.ui(12)).foregroundStyle(theme[.descriptionForeground]).lineLimit(1).padding(.leading, 5)
            }
            if let badge {
                Text("\(badge)").font(.ui(11)).monospacedDigit().foregroundStyle(theme[.editorErrorForeground]).padding(.leading, 6)
                    .help("\(badge) failing \(badge == 1 ? "step" : "steps")")
            }
            ZStack {
                if hovering || active || hoveringClose {
                    Codicon("close", size: 16)
                        .foregroundStyle(theme[active ? .tabActiveForeground : .tabInactiveForeground])
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5).fill(hoveringClose ? theme[.toolbarHoverBackground] : .clear))
                        .onHover { hoveringClose = $0 }
                        .onTapGesture(perform: close)
                        .help("Close (⌘W)")
                        .accessibilityLabel("Close \(title)")
                        .accessibilityAddTraits(.isButton)
                } else if dirty {
                    Circle().fill(theme[.tabActiveForeground]).frame(width: 8, height: 8)
                }
            }.frame(width: 28, height: 20).padding(.leading, 4)
        }
        .padding(.leading, 10).padding(.trailing, 2)
        .frame(height: VSMetrics.tabHeight)
        .frame(minWidth: 120, maxWidth: 280)
        .background(active ? theme[focused ? .tabActiveBackground : .tabUnfocusedActiveBackground]
                    : (hovering && theme.has(.tabHoverBackground) ? theme[.tabHoverBackground] : theme[.tabInactiveBackground]))
        .overlay(alignment: .top) {
            if active { Rectangle().fill(theme[focused ? .tabActiveBorderTop : .tabUnfocusedActiveBorderTop]).frame(height: 1) }
        }
        .overlay(alignment: .bottom) {
            if active && theme.has(.tabActiveBorder) { Rectangle().fill(theme[.tabActiveBorder]).frame(height: 1) }
            else if !active { Rectangle().fill(theme.border(.editorGroupHeaderTabsBorder)).frame(height: 1) }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(theme.border(.tabBorder)).frame(width: 1) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: select)
        .simultaneousGesture(TapGesture().modifiers(.command).onEnded { select() })
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(.default, select)
        .accessibilityAction(named: "Close", close)
    }
}

/// A tab bar's tabs side by side, each at its own width: what its icon, title and close button need, within the tab's
/// 120 to 280 points, as VS Code's tabs fit their labels. In an HStack a tab took the width proposed to it, and the bar's
/// scroll view proposes its whole width in some layout passes and none in others: while the side bar was resized, the
/// tabs jumped between 280 points and their own width from one frame to the next.
struct VSTabRow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(width: sizes.reduce(0) { $0 + $1.width }, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for subview in subviews {
            let width = subview.sizeThatFits(.unspecified).width
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width
        }
    }
}

/// The main editor group's tab bar: books, then Welcome, Settings and other special editors; editor actions at the end.
struct MainEditorTabs: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    VSTabRow {
                        ForEach(store.tabs) { tab in
                            VSTab(icon: "file-pdf", title: tab.title, active: store.activeMainTabID == tab.id,
                                  groupFocused: true, cover: store.library.first { $0.id == tab.id }.flatMap { store.covers.cover(for: $0) },
                                  select: { store.activateMainTab(tab.id) }, close: { store.closeTab(tab.id) })
                                .id(tab.id)
                                .contextMenu { bookTabMenu(tab) }
                                .draggable("lemma-tab:\(tab.id)")
                                .dropDestination(for: String.self) { values, _ in store.dropBookTab(values, onto: tab.id) }
                        }
                        ForEach(store.specialTabs) { editor in
                            VSTab(icon: editor.icon, title: editor.title, active: store.activeSpecial == editor,
                                  select: { store.openSpecial(editor) }, close: { store.closeSpecial(editor) })
                                .id(editor.id)
                                .contextMenu { Button("Close") { store.closeSpecial(editor) } }
                        }
                        ForEach(store.fileTabs, id: \.self) { name in
                            VSTab(icon: (name as NSString).pathExtension.lowercased() == "md" ? "markdown" : "file-text", title: name,
                                  active: store.activeFileName == name, dirty: store.app.fileBuffers[name]?.isDirty ?? false,
                                  select: { store.openWorkspaceFile(name) }, close: { store.closeWorkspaceFile(name) })
                                .id(StudyStore.fileTabID(name))
                                .contextMenu { Button("Close") { store.closeWorkspaceFile(name) } }
                        }
                    }
                    // The tabs scroll only once they fill the bar; its empty part keeps the bar's bottom border and
                    // opens a new workspace file on a double-click, as VS Code does.
                    .frame(minWidth: geometry.size.width, maxHeight: .infinity, alignment: .leading)
                    .background {
                        Color.clear.contentShape(Rectangle()).onTapGesture(count: 2) { store.beginNewFile() }
                            .overlay(alignment: .bottom) { Rectangle().fill(theme.border(.editorGroupHeaderTabsBorder)).frame(height: 1) }
                    }
                }
                // A book's tab dropped on the bar but not on another book's tab goes after the last book.
                .dropDestination(for: String.self) { values, _ in store.dropBookTab(values, onto: nil) }
                // The active tab is always in view (a tab just opened is laid out first).
                .onAppear { if let id = store.activeMainTabID { DispatchQueue.main.async { proxy.scrollTo(id) } } }
                .onChange(of: store.activeMainTabID) { _, id in
                    guard let id else { return }
                    DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                }
                .onChange(of: store.specialTabs.count &+ store.tabs.count &+ store.fileTabs.count) { _, _ in
                    guard let id = store.activeMainTabID else { return }
                    DispatchQueue.main.async { proxy.scrollTo(id) }
                }
            }
            }
            EditorActions(store: store)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) { Rectangle().fill(theme.border(.editorGroupHeaderTabsBorder)).frame(height: 1) }
        }
        .frame(height: VSMetrics.tabHeight)
        .background(theme[.editorGroupHeaderTabsBackground])
    }

    @ViewBuilder private func bookTabMenu(_ tab: BookTab) -> some View {
        Button("Close") { store.closeTab(tab.id) }
        Button("Close Others") { store.closeOtherTabs(keeping: tab.id) }
        Button("Close All") { store.closeAllEditors() }
        Divider()
        Button("Open to the Side") { store.openBookToTheSide(tab.id) }
        Button("Reveal in Explorer") { store.reveal(.library) }
        Button("Copy Path") {
            if let path = store.library.first(where: { $0.id == tab.id })?.sourcePath {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string)
            }
        }
        Divider()
        Button("Move Tab Left") { store.shiftBookTab(tab.id, by: -1) }
        Button("Move Tab Right") { store.shiftBookTab(tab.id, by: 1) }
    }
}

/// The editor's actions at the end of the tab bar, as VS Code puts Run, Split and More there.
struct EditorActions: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme
    @AppStorage(LemmaPreferences.referenceLinks) private var referenceLinks = true

    var body: some View {
        HStack(spacing: 2) {
            if store.document != nil && store.activeSpecial == nil && store.activeFileName == nil {
                if store.debug == nil {
                    VSIconButton(icon: "debug-alt", help: "Debug the Statement in View: step through its proof (F5)", tint: theme[.debugIconStartForeground]) { store.startDebugging() }
                }
                VSIconButton(icon: "inspect", help: "Capture a Region (⇧⌘S)", toggled: store.reader.regionMode) { store.reader.regionMode.toggle() }
                VSIconButton(icon: "edit", help: "Draw on My Edition (⌥⇧⌘D)", toggled: store.reader.inkMode) { store.reader.inkMode.toggle() }
                VSIconButton(icon: "symbol-ruler", help: "Reading Ruler: one line at a time (⌥⌘R)", toggled: store.reader.rulerMode) { store.reader.rulerMode.toggle() }
                VSIconButton(icon: "split-horizontal", help: "Split Editor: another page beside this one (⌘\\)") { store.toggleSplit() }
                moreMenu
            } else if store.activeSpecial != nil {
                VSIconButton(icon: "split-horizontal", help: "Split Editor", enabled: false) {}
            }
        }
        .padding(.horizontal, 6)
    }

    private var moreMenu: some View {
        VSMenuButton(icon: "ellipsis", help: "More Actions…") {
            let layout = store.workspace?.reading.layout ?? .standard
            return [
                .submenu("Page Layout", ReadingLayout.allCases.map { option in .action(option.label, checked: option == layout) { store.updateLayout(option) } }),
                .submenu("Edition", [.action("Original", checked: !store.reader.showAnnotations) { store.reader.showAnnotations = false },
                                     .action("My Edition", checked: store.reader.showAnnotations) { store.reader.showAnnotations = true }]),
                .submenu("Page Theme", PageTheme.allCases.map { page in .action(page.label, checked: page == store.pageTheme) { store.pageTheme = page } }),
                .separator,
                .action("Line Numbers", checked: store.reader.showLineNumbers, shortcut: "⌃⌘L") { store.reader.showLineNumbers.toggle() },
                .action("Minimap", checked: store.showMinimap) { store.showMinimap.toggle() },
                .action("Link References", checked: referenceLinks) { referenceLinks.toggle() },
                .separator,
                .action("Fit Page", shortcut: "⌘0") { store.reader.fit() },
                .action("Fit Width") { store.reader.fitWidth() },
                .separator,
                .action(store.pageIsBookmarked ? "Remove Bookmark" : "Bookmark Page", shortcut: "⌘D") { store.toggleBookmark() },
                .action(store.allProofsFolded ? "Unfold All Proofs" : "Fold All Proofs", enabled: !store.proofs.isEmpty) { store.toggleAllProofs() },
                .action("Toggle Breakpoint on the Line", shortcut: nil) { store.toggleBreakpoint() },
                .separator,
                .action("Export My Edition as PDF…") { store.exportMyEdition() },
                .action("Reveal Source in Finder") {
                    if let path = store.workspace?.sourcePath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
            ]
        }
    }
}

/// VS Code's breadcrumbs: the book, then chapter › section › subsection with symbol icons, then the statement being read.
/// The path and the statement come from the reader, which publishes them only when they change (not on every scroll step).
///
/// The bar's own size never depends on its crumbs: they are an overlay of a fixed bar. A change of size, or of content
/// laid out in the editor's stack, would lay out the whole editor again (tabs, selection bar, page, minimap, ruler),
/// several milliseconds for each statement the reading position passes.
struct VSBreadcrumbs: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme

    var body: some View {
        theme[.breadcrumbBackground]
            .frame(height: VSMetrics.breadcrumbHeight)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) { BreadcrumbTrail(store: store) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Breadcrumbs")
    }
}

/// The crumbs themselves, laid out inside the bar.
private struct BreadcrumbTrail: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme

    var body: some View {
        let _ = QAPerf.tick("Breadcrumbs")
        let path = store.reader.focusPath
        let statement = store.reader.focusStatement
        HStack(spacing: 0) {
            // The book's title is read by its own view: the workspace changes with every saved position and reading minute.
            BookCrumb(store: store, isLast: path.isEmpty) { showMenu(store.outline) }
            ForEach(Array(path.enumerated()), id: \.element.id) { offset, entry in
                separator
                let icon = offset == 0 ? "symbol-namespace" : offset == 1 ? "symbol-class" : "symbol-method"
                let color: TC = offset == 0 ? .symbolIconNamespaceForeground : offset == 1 ? .symbolIconClassForeground : .symbolIconMethodForeground
                crumb(entry.title, icon: icon, iconColor: color, isLast: offset == path.count - 1 && statement == nil) {
                    showMenu(offset == 0 ? store.outline : (path[offset - 1].children ?? []))
                }
            }
            if store.analysis?.analysis != nil, let reading = statement {
                separator
                HStack(spacing: 4) {
                    KindBadge(key: reading.statement.key, size: 13)
                    Text(reading.label).lineLimit(1)
                }
                .foregroundStyle(theme[.breadcrumbFocusForeground])
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
                .onTapGesture { store.showHierarchy(reading.statement.key) }
                .help("\(reading.label) · click for what it uses and what uses it")
                .layoutPriority(3)
            }
            Spacer(minLength: 0)
        }
        .font(.ui(13))
        .padding(.leading, 12).padding(.trailing, 8)
        .frame(height: VSMetrics.breadcrumbHeight)
        .frame(maxWidth: .infinity)
    }

    private var separator: some View {
        Codicon("chevron-right", size: 16).foregroundStyle(theme[.breadcrumbForeground].opacity(0.8)).padding(.horizontal, 1)
    }

    private func crumb(_ title: String, icon: String, iconColor: TC?, isLast: Bool, open: @escaping () -> Void) -> some View {
        BreadcrumbItem(title: title, icon: icon, iconColor: iconColor, isLast: isLast, open: open)
    }

    /// A native menu of outline entries at the pointer.
    private func showMenu(_ entries: [OutlineEntry]) {
        guard !entries.isEmpty, let window = store.mainWindow, let content = window.contentView else { return }
        let menu = NSMenu()
        let current = Set(store.reader.focusPath.map(\.id))
        for entry in entries {
            let item = ActionMenuItem(entry.title) { [store] in store.go(to: entry) }
            item.state = current.contains(entry.id) ? .on : .off
            menu.addItem(item)
        }
        let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: point, in: content)
    }
}

private struct BookCrumb: View {
    @Bindable var store: StudyStore
    let isLast: Bool
    let open: () -> Void
    var body: some View { BreadcrumbItem(title: store.workspace?.title ?? "", icon: "file-pdf", iconColor: nil, isLast: isLast, open: open) }
}

private struct BreadcrumbItem: View {
    @Environment(\.theme) private var theme
    let title: String
    let icon: String
    let iconColor: TC?
    let isLast: Bool
    let open: () -> Void
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 4) {
            if let iconColor { Codicon(icon, size: 16).foregroundStyle(theme[iconColor]) } else { FileIcon(kind: icon) }
            ViewThatFits(in: .horizontal) {
                Text(title).lineLimit(1).fixedSize()
                if let short = OutlineMap.numberPrefix(of: title), !isLast { Text(short).lineLimit(1).fixedSize() }
                Text(title).lineLimit(1).truncationMode(.tail)
            }
        }
        .foregroundStyle(theme[hovering || isLast ? .breadcrumbFocusForeground : .breadcrumbForeground])
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .layoutPriority(isLast ? 2 : 1)
        .help(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
    }
}
