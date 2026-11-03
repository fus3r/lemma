import SwiftUI

/// Help → Keyboard Shortcuts: the study actions and where to find them.
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let groups: [(String, [(String, String)])] = [
        ("Go to", [("⌘P", "Go to a page (printed numbers), section, “(3.41)”, “fig 3.8”, an index term or a note"),
                   ("⇧⌘P", "Command palette: every command by name"), ("⌘T", "Go to an equation, figure, table, algorithm or exercise"),
                   ("⌥⌘←  ⌥⌘→", "Back to the reading position · Forward"), ("⌃⇥  ⌃⇧⇥", "Next book tab · Previous book tab"),
                   ("⌘F", "Find in the PDF, your notes or indexed pages")]),
        ("Workbench", [("⌘B", "Show or hide the sidebar"), ("⌥⌘I", "Show or hide the notebook"), ("⌘J", "Show or hide the panel: problems, references, questions, notes"),
                       ("⌘\\", "Split editor: keep another page beside this one, as a side tab"), ("⌥⌘Z", "Zen mode: focus on reading"),
                       ("⌃⌘L", "Show or hide line numbers; click a number to select its line"), ("⌃⌘T", "Page theme: paper, sepia, night"),
                       ("⌘P 64:12", "Go to line 12 of page 64"),
                       ("⌘W", "Close the book's tab"), ("⌘D", "Bookmark the page"), ("⌘0  ⌘+  ⌘−", "Fit page · Zoom in · Zoom out")]),
        ("References and definitions", [("Hover", "Preview an underlined reference without clicking"),
                                        ("Click", "Peek at an underlined reference: “(2.3)”, “Figure 2.1”, “Rudin (1976)”"),
                                        ("⇧-click", "Open another peek beside the ones open; drag a peek's title bar to keep it in sight"),
                                        ("⌥-click", "Open a result or a page reference in the side editor"),
                                        ("⌘-click", "Look a term up in the book's index and your glossary"), ("⇧⌘L", "Look up a typed term (for scans)"),
                                        ("Right-click", "Study actions, Find All References, Open to the Side")]),
        ("Results and proofs", [("⌥⌘[", "Fold every proof (read the statements, try each proof first) · again to unfold"),
                                ("Gutter ▸", "Fold or unfold one proof beside its first line"),
                                ("⇧⌥⌘H", "What the statement being read uses, and what uses it (Hierarchy panel)"),
                                ("⌥⌘G", "Dependency map of the chapter: prerequisites above what rests on them"),
                                ("⌥⌘R", "Reading ruler: one line at a time"), ("↓ ↑  J K", "Step the ruler · Space jumps three lines"),
                                ("↩", "Open the reference on the ruler's line"), ("Hover a symbol", "What λ, X or β stands for at this point of the book")]),
        ("Working on a passage", [("⌘K", "Ask about the selection, with its context"), ("⌘E", "Prepare the current note’s question"),
                                  ("⌘N", "New note from the selection"), ("⌥⌘M", "Margin note beside the selection; or double-click the margin"),
                                  ("⌥⌘S", "Save the selection as a definition"), ("⌥⌘P", "Pin the selection as context"),
                                  ("⇧⌘H  ⇧⌘U", "Highlight · Underline the selection"), ("⇧⌘S", "Draw a region to capture"),
                                  ("⌥⇧⌘D", "Write by hand on My edition"), ("⇧⌘O", "Recognize text on the current page")]),
        ("Derivations", [("⌥⌘E", "Work through the selection as a derivation: each line is checked as you type"),
                         ("= …", "Start a line with a relation to continue the previous one"),
                         ("X \\in \\mathbb{R}^{N\\times p}", "Declare a size or an assumption (λ > 0) on a line of its own"),
                         ("RSS(β) := …", "Define a name; later steps use its definition"),
                         ("⌘/", "Comment or uncomment lines (in a derivation)")]),
        ("Lab", [("⌥⌘L", "Send the selection to the Lab: a Python notebook beside the page"), ("⌃`", "Python console in the panel (shares the open notebook)"),
                 ("⇧↩", "Run the cell and go to the next one"), ("⌘↩", "Run the cell"), ("⌥↩", "Run the cell and add one below"),
                 ("⇥  ⇧⇥", "Indent · Dedent the selected lines"), ("⌘/", "Comment or uncomment lines (in a cell)"), ("esc", "Leave the cell")]),
        ("Review", [("⇧⌘R", "Open Review"), ("⌘↩", "Reveal the source and your saved work"), ("⌘1 – ⌘4", "Grade: Again, Hard, Good, Easy")]),
        ("Files", [("⇧⌘N", "New empty window"), ("⌘O", "Open a PDF in a new tab"), ("⌥⇧⌘E", "Export study notes"), ("⌘,", "Settings")])
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard shortcuts").font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groups, id: \.0) { group in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(group.0).font(.headline)
                            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                                ForEach(group.1, id: \.0) { item in
                                    GridRow {
                                        Text(item.0).font(.callout.monospaced()).foregroundStyle(Color.lemmaOlive).gridColumnAlignment(.trailing)
                                        Text(item.1).font(.callout)
                                    }
                                }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 680, height: 760)
    }
}
