import SwiftUI
import AppKit
import PDFKit
import LemmaCore

/// The editor for a special tab.
struct SpecialEditorView: View {
    @Bindable var store: StudyStore
    let editor: SpecialEditor
    var body: some View {
        switch editor {
        case .welcome: WelcomeEditor(store: store)
        case .settings: SettingsEditor(store: store)
        case .shortcuts: ShortcutsEditor(store: store)
        case .releaseNotes: ReleaseNotesEditor(store: store)
        }
    }
}

// MARK: - Welcome

/// The steps of the Get Started walkthrough; each is done when the reader has done it once.
enum WalkthroughStep: String, CaseIterable, Identifiable {
    case theme, open, goTo, peek, debug, derive, lab, ask, test
    var id: String { rawValue }
    var title: String {
        switch self {
        case .theme: "Choose the look you want"
        case .open: "Open a book or a paper"
        case .goTo: "Go to anything"
        case .peek: "Peek at references, as definitions"
        case .debug: "Step through a proof like a debugger"
        case .derive: "Check a derivation as you write it"
        case .lab: "Run an equation in Python"
        case .ask: "Ask an assistant with the right context"
        case .test: "Test what you remember"
        }
    }
    var detail: String {
        switch self {
        case .theme: "Pick a colour theme: Lemma's own, VS Code's, popular community themes, or any VS Code colour theme file (drop its .json or .vsix on the window). ⌥⌘T previews them as you move through the list. Prefer a native macOS window? Choose Classic in Settings › Interface Style."
        case .open: "Open a PDF, try the sample book (Help › Open the Sample Book), or get one of 45 free textbooks from the Catalog. Lemma reads the book once, on this Mac: page numbers, equations, statements, proofs, the index and the references."
        case .goTo: "⌘P goes to a printed page (“124”), a label (“(3.41)”, “fig 3.8”), a line (“64:12”), a term from the index or a note. ⇧⌘P runs any command."
        case .peek: "Underlined references are links: hover to preview, click to peek, ⌥-click to open beside the page. ⌘-click a term to look it up."
        case .debug: "Put the cursor on a theorem and press F5. Step over each line (F10), step into a cited result (F11), see the symbols in scope and the statement you are proving."
        case .derive: "Select a step the book calls “easily seen” and press ⌥⌘E. Write the missing steps; each line is checked at once by random numbers."
        case .lab: "Select an equation and press ⌥⌘L: a Python notebook opens beside the page, on your Mac's Python, gently."
        case .ask: "Select a passage and press ⌘K. Lemma assembles the passage, the cited equations and your notation, and sends them to your selected assistant."
        case .test: "Add definitions and theorems to the Testing view and recall them on schedule, statement first, then the source."
        }
    }
    var icon: String {
        switch self {
        case .theme: "symbol-color"; case .open: "file-pdf"; case .goTo: "go-to-file"; case .peek: "references"; case .debug: "debug-alt"
        case .derive: "symbol-operator"; case .lab: "notebook"; case .ask: "comment-discussion"; case .test: "beaker"
        }
    }
    var actionTitle: String {
        switch self {
        case .theme: "Browse Color Themes"; case .open: "Open PDF…"; case .goTo: "Go to…"; case .peek: "Show Me"; case .debug: "Start Debugging"
        case .derive: "New Derivation"; case .lab: "New Notebook"; case .ask: "Ask About the Selection"; case .test: "Open Testing"
        }
    }

    @MainActor func isDone(_ store: StudyStore) -> Bool {
        switch self {
        case .theme: return UserDefaults.standard.string(forKey: ThemePreferences.colorTheme) != nil || UserDefaults.standard.bool(forKey: "walkthrough.theme")
        case .open: return !store.library.isEmpty
        case .derive: return store.library.contains { !$0.derivations.isEmpty }
        case .lab: return store.library.contains { !$0.labs.isEmpty }
        case .ask: return store.library.contains { book in book.notes.contains { $0.explanation != nil || $0.pendingRequestID != nil } }
        case .test: return store.library.contains { book in book.notes.contains(where: \.isInReview) }
        default: return UserDefaults.standard.bool(forKey: "walkthrough.\(rawValue)")
        }
    }

    static func markDone(_ step: WalkthroughStep) { UserDefaults.standard.set(true, forKey: "walkthrough.\(step.rawValue)") }

    @MainActor func perform(_ store: StudyStore) {
        switch self {
        case .theme: store.showThemePicker()
        case .open: store.choosePDF()
        case .goTo: store.showPalette(.goTo)
        case .peek: if store.document != nil { store.notify("Click any underlined reference on the page, such as an equation number.", source: "Get Started") } else { store.choosePDF() }
        case .debug: store.startDebugging()
        case .derive:
            if store.workspace != nil { store.newDerivation() }
            else { store.notify("Open a book first: a derivation starts from a step on its page (select it and press ⌥⌘E).", source: "Get Started") }
        case .lab:
            if store.workspace != nil { store.newLab() }
            else { store.notify("Open a book first: a notebook lives beside a book (select an equation and press ⌥⌘L).", source: "Get Started") }
        case .ask: if store.reader.hasSelection { store.prepareQuickAsk() } else { store.notify("Select a passage on the page first, then press ⌘K.", source: "Get Started") }
        case .test: store.reveal(.testing)
        }
    }
}

/// A miniature of a theme drawn from its own colours: activity bar, side bar, editor with a page, status bar.
struct ThemeTile: View {
    @Environment(\.theme) private var theme
    let entry: ThemeEntry
    let selected: Bool
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        let colors = ThemeManager.shared.previewColors(for: entry.id)
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                if let colors {
                    VStack(spacing: 0) {
                        colors[.titleBarActiveBackground].frame(height: 6)
                        HStack(spacing: 0) {
                            colors[.activityBarBackground].frame(width: 9)
                                .overlay(alignment: .top) { Rectangle().fill(colors[.activityBarForeground]).frame(width: 4, height: 4).padding(.top, 4) }
                            colors[.sideBarBackground].frame(width: 26)
                                .overlay(alignment: .topLeading) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        ForEach(0..<4) { index in Capsule().fill(colors[.sideBarForeground].opacity(0.5)).frame(width: CGFloat(14 - index * 2), height: 1.5) }
                                    }.padding(4)
                                }
                            VStack(spacing: 0) {
                                HStack(spacing: 0) {
                                    colors[.tabActiveBackground].frame(width: 26).overlay(alignment: .top) { colors[.tabActiveBorderTop].frame(height: 1) }
                                    colors[.tabInactiveBackground]
                                }.frame(height: 7)
                                colors.pageCanvas.color.overlay {
                                    RoundedRectangle(cornerRadius: 1).fill(Color.white).frame(width: 30, height: 34)
                                        .overlay(VStack(spacing: 3) { ForEach(0..<5) { _ in Rectangle().fill(Color.gray.opacity(0.6)).frame(width: 20, height: 1) } })
                                }
                            }
                        }
                        colors[.statusBarBackground].frame(height: 5)
                    }
                } else { theme[.editorBackground] }
            }
            .frame(height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? theme[.focusBorder] : hovering ? theme[.descriptionForeground] : theme.border(.widgetBorder), lineWidth: selected ? 2 : 1))
            Text(entry.label).font(.ui(12, weight: selected ? .semibold : .regular)).lineLimit(1).foregroundStyle(theme[.foreground])
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: choose)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.label) color theme")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Keyboard shortcuts

/// VS Code's Keyboard Shortcuts editor: a searchable table of commands, keybindings and when they apply.
struct ShortcutsEditor: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme
    @State private var query = ""

    struct Row: Identifiable { let id: String; let command: String; let keys: String; let when: String; let source: String }

    var body: some View {
        let rows = self.rows.filter { query.isEmpty || "\($0.command) \($0.keys) \($0.when)".localizedCaseInsensitiveContains(query) }
        VStack(spacing: 0) {
            VSTextField(placeholder: "Type to search in keybindings", text: $query, icon: "search").padding(.horizontal, 24).padding(.vertical, 14)
            HStack(spacing: 0) {
                header("Command").frame(maxWidth: .infinity, alignment: .leading)
                header("Keybinding").frame(width: 200, alignment: .leading)
                header("When").frame(width: 220, alignment: .leading)
                header("Source").frame(width: 80, alignment: .leading)
            }
            .padding(.horizontal, 24).frame(height: 26)
            .background(theme[.sideBarSectionHeaderBackground])
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        HStack(spacing: 0) {
                            VSHighlightedText(text: row.command, matches: FuzzyMatch.ranges(of: query, in: row.command)).font(.ui(13))
                                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                            Group { if row.keys.isEmpty { Text("-").foregroundStyle(theme[.descriptionForeground]) } else { VSKeybinding(shortcut: row.keys) } }
                                .frame(width: 200, alignment: .leading)
                            Text(row.when).font(.ui(12)).foregroundStyle(theme[.descriptionForeground]).frame(width: 220, alignment: .leading).lineLimit(1)
                            Text(row.source).font(.ui(12)).foregroundStyle(theme[.descriptionForeground]).frame(width: 80, alignment: .leading)
                        }
                        .padding(.horizontal, 24).frame(height: 24)
                        .background(index % 2 == 1 ? theme[.listHoverBackground].opacity(0.4) : .clear)
                    }
                }
            }
        }
        .background(theme[.editorBackground])
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.ui(12, weight: .semibold)).foregroundStyle(theme[.foreground])
    }

    private var rows: [Row] {
        var rows: [Row] = []
        var seen = Set<String>()
        for item in store.commandCatalog() where !seen.contains(item.title) {
            seen.insert(item.title)
            rows.append(Row(id: item.id, command: item.title, keys: item.shortcut ?? "", when: Self.when(item.title), source: "Default"))
        }
        // Bindings whose command the palette does not list in the current context (debugging, a focused cell…).
        let extras: [(String, String, String)] = [
            ("Debug: Start Debugging the Statement in View", "F5", "bookOpen && !inDebugMode"), ("Debug: Continue", "F5", "inDebugMode"),
            ("Debug: Step Over (Next Line)", "F10", "bookOpen"), ("Debug: Step Into the Cited Result", "F11", "bookOpen"),
            ("Debug: Step Out", "⇧F11", "inDebugMode"), ("Debug: Restart", "⇧⌘F5", "inDebugMode"), ("Debug: Stop", "⇧F5", "inDebugMode"),
            ("Debug: Toggle Breakpoint", "F9", "bookOpen"),
            ("Preferences: Color Theme", "⌥⌘T", ""), ("Preferences: Open Settings", "⌘,", ""),
            ("Reference: Peek", "Click", "referenceUnderPointer"), ("Reference: Open to the Side", "⌥Click", "referenceUnderPointer"),
            ("Term: Look Up", "⌘Click", "termUnderPointer"), ("Ruler: Next Line · Previous Line", "↓ ↑", "rulerVisible"),
            ("Lab: Run Cell and Select Below", "⇧↩", "notebookCellFocused"), ("Lab: Run Cell", "⌘↩", "notebookCellFocused"),
            ("Review: Reveal", "⌘↩", "reviewVisible"), ("Review: Grade Again · Hard · Good · Easy", "⌘1", "reviewVisible")
        ]
        for extra in extras where !seen.contains(extra.0) { rows.append(Row(id: extra.0, command: extra.0, keys: extra.1, when: extra.2, source: "Default")) }
        return rows.sorted { $0.command.localizedStandardCompare($1.command) == .orderedAscending }
    }

    private static func when(_ title: String) -> String {
        switch title {
        case "Debug: Start Debugging the Statement in View": return "bookOpen && !inDebugMode"
        case "Debug: Continue", "Debug: Step Out", "Debug: Restart", "Debug: Stop": return "inDebugMode"
        case "Derivation: Work Through the Selection": return "bookOpen && selection"
        default: break
        }
        if title.hasPrefix("Study:") { return "bookOpen && selection" }
        if title.hasPrefix("Lab:") { return "notebookOpen" }
        if title.hasPrefix("Derivation: Close") || title.hasPrefix("Derivation: Delete") { return "derivationOpen" }
        if title.hasPrefix("Debug:") || title.hasPrefix("Derivation:") || title.hasPrefix("Reading:") || title.hasPrefix("Results:") || title.hasPrefix("Go to:") { return "bookOpen" }
        return ""
    }
}

// MARK: - Release notes

struct ReleaseNotesEditor: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme

    private let sections: [(String, String, [String])] = [
        ("Lemma 3.4.1: keep your place", "check", [
            "Find keeps each book's query without searching or moving its page when you switch tabs. Classic Find shows previous and next chevrons. Thanks to Songlan Nie.",
            "Tabs keep their width while you resize the Explorer, and dragging a tab right can move it to the last position.",
            "Links to numbered statements use the statement's name when the book and destination agree, including Result 3.21 in Axler.",
            "Check for Updates can replace an older waiting download with the newest release."
        ]),
        ("Lemma 3.4: peeks you can keep in sight", "eye", [
            "Drag a peek by its title bar to move it anywhere: it stays open while you read on, until you close it.",
            "⇧-click another reference to open its peek beside the ones already open: a figure and the theorem that uses it, side by side.",
            "Peeks open at a little less than your reading zoom and resize by their edges, by Songlan Nie, Lemma's first contributor."
        ]),
        ("Lemma 3.3.1", "check", [
            "The page layout chosen in the page's context menu (Single Page, Two Pages, Two Pages Continuous) stays, and the book opens in it next time. Two Pages Continuous is in Page Layout and the command palette too. Thanks to Sudhenduahir for the report."
        ]),
        ("Lemma 3.3: reading, refined", "book", [
            "Pages sit closer together (8 pt), and Settings › Reading › Gap between pages sets the gap from 0 to 32 pt.",
            "Drag a reference preview off its line to keep it open in a window of its own; previews open at the page's width.",
            "Go to keeps your zoom and horizontal position, the box around an equation fits it, and (15) leads to (15a)–(15c).",
            "Citations like \"and(24a)\" are counted, the notebook panel has a close button, and ⌘F always reaches the find field.",
            "Thanks to Songlan Nie, Lemma's first contributor, who made all of these while reading with Lemma."
        ]),
        ("Lemma 3.2.2", "check", [
            "The Dock keeps a single Lemma icon: reading a new book, or quitting and opening Lemma again, no longer adds another one among the recent apps. Thanks to Songlan Nie, who found and fixed it first."
        ]),
        ("Lemma 3.2.1", "book", [
            "Help › Report How Lemma Read This Book… opens GitHub's book report form with the book and what Lemma found in it already filled in: say what went wrong and submit it from your browser.",
            "Lemma no longer stops responding while macOS asks whether it may read a library folder, or while a library folder's disk wakes up."
        ]),
        ("Lemma 3.2: asking, redone", "comment-discussion", [
            "⌘K opens Ask under the passage, as VS Code's inline chat opens under a line: the passage, your question, the kind of help, and every item sent with it, each with its checkbox.",
            "Send now, or Review first in Lemma's ChatGPT page. A failed question is asked again with one click, to the same note.",
            "The question names the printed page and the book's authors, and Explain fills in the steps the book leaves out.",
            "ChatGPT Web works again when macOS's smart quotes are on, keeps code blocks and tables in its answers, and Cancel stops the answer.",
            "The Assistants window looks like the rest of Lemma, in your theme's colours; saved explanations scroll smoothly, follow your theme and fit wide equations beside their number."
        ]),
        ("Lemma 3.1: updates inside Lemma", "cloud-download", [
            "Lemma › Check for Updates… shows what is new and installs the new version, then relaunches. No more downloading a disk image.",
            "If you agree (Lemma asks once), it also checks once a day; it can download and install on its own when you quit. Settings › Updates.",
            "Updates are signed: Lemma installs only versions published by its maintainers."
        ]),
        ("A look of its own", "symbol-color", [
            "Lemma Dark and Lemma Light, warm graphite and paper with an olive accent, follow macOS light and dark. Every VS Code theme still works, and the Classic Mac window is one setting away.",
            "A new Welcome page: open a PDF, drop one, add a folder, pick a free textbook from a shelf of covers, or continue a book where you left it.",
            "A new icon, and covers for the catalog's 45 free textbooks."
        ]),
        ("Reading", "book", [
            "Find in the book (⌘F), with Match Case and Whole Word, highlights every match on the page; ⌘G and ⇧⌘G move between them from where you are reading.",
            "PDFs open from Finder's Open With menu, from the Dock and from other apps. A book takes its title from the PDF when the PDF has a real one.",
            "⌘C copies a passage as running text, without the PDF's line breaks; ⌥-click a reference to open it beside the page.",
            "Faster to launch, scroll, switch books and search, and nothing runs while Lemma sits idle.",
            "Search indexing works at low priority and pauses on battery, in Low Power Mode and when the Mac is hot.",
            "Your notes follow a PDF whose file changed on disk, and password-protected PDFs open."
        ]),
        ("Assistants", "comment-discussion", [
            "Ask OpenAI, Anthropic or Google Gemini with your own API key, kept in your Keychain, besides ChatGPT, Codex and Claude Code.",
            "Codex and Claude Code use the sign-in you set up; signing in happens in your browser. ChatGPT's page loads only when you connect it."
        ]),
        ("Lab", "notebook", [
            "Set Up Python for the Lab… creates a private Python environment with NumPy, SciPy, Matplotlib, SymPy and pandas.",
            "Notebooks' Python processes always stop when Lemma quits."
        ]),
        ("Open and private", "lock", [
            "Lemma is free software under the GNU GPL v3, on GitHub. Help › Report an Issue… fills in your versions; Help › Acknowledgements lists every licence.",
            "New readers start with two libraries, Books and Papers; add your own folders from the Welcome page or File › New Library…."
        ]),
        ("Shortcuts that changed", "keyboard", [
            "Save Definition is now ⌥⌘S (macOS uses ⌥⌘D to hide the Dock).",
            "Resume at the First “?” is now ⌥⌘J (macOS uses ⇧⌘/ for the Help menu).",
            "Show What This Statement Uses is now ⇧⌥⌘H, so typing in notes is never interrupted."
        ])
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("What’s New in Lemma \(WelcomeEditor.version)").font(.system(size: 30, weight: .semibold, design: .serif))
                            .foregroundStyle(theme[.foreground])
                        Text("October 2026 · Updates since the first public release").font(.ui(13)).foregroundStyle(theme[.descriptionForeground])
                    }
                }
                ForEach(sections, id: \.0) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 9) {
                            Codicon(section.1, size: 17).foregroundStyle(theme.accent)
                            Text(section.0).font(.system(size: 18, weight: .semibold, design: .serif))
                        }
                        .foregroundStyle(theme[.foreground])
                        ForEach(section.2, id: \.self) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 9) {
                                Circle().fill(theme.accent.opacity(0.7)).frame(width: 4, height: 4).offset(y: -3)
                                Text(line).font(.ui(13)).foregroundStyle(theme[.foreground]).fixedSize(horizontal: false, vertical: true).lineSpacing(2.5)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme[.welcomePageTileBackground]))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.border(.welcomePageTileBorder), lineWidth: 1))
                }
                HStack(spacing: 18) {
                    VSLinkButton(title: "Full changelog on GitHub", icon: "link-external") { NSWorkspace.shared.open(LemmaLinks.releases) }
                    VSLinkButton(title: "Acknowledgements", icon: "heart") { store.showAcknowledgements = true }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 56).padding(.vertical, 40)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(theme[.editorBackground])
    }
}

/// The empty editor when no book is open and the Welcome page is turned off: VS Code's watermark of shortcuts.
struct EditorWatermark: View {
    @Environment(\.theme) private var theme
    private let entries: [(String, String)] = [("Show All Commands", "⇧⌘P"), ("Open PDF", "⌘O"), ("Go to Page or Section", "⌘P"),
                                               ("Get a Free Textbook", "⇧⌘X"), ("Search All Books", "⇧⌘F"), ("Open Settings", "⌘,")]
    var body: some View {
        VStack(spacing: 22) {
            LemmaGlyph(size: 96).opacity(0.12)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(entries, id: \.0) { entry in
                    GridRow {
                        Text(entry.0).font(.ui(13)).foregroundStyle(theme[.editorForeground].opacity(0.6)).gridColumnAlignment(.trailing)
                        VSKeybinding(shortcut: entry.1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme[.editorBackground])
    }
}
