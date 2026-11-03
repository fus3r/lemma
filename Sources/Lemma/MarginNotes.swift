import SwiftUI
import AppKit
import PDFKit
import LemmaCore

/// Margin notes: the pencilled remark beside a line. Double-click the page's margin, or choose Comment for a
/// selection, and write in place; the note then sits in the margin as a card, like a sticky note on paper.
@MainActor
extension StudyStore {
    /// A margin note for the current selection.
    func addMarginNote() {
        guard let (pageIndex, region, quote) = reader.selection, reader.hasSelection else {
            error = "Select a line or double-click the margin beside it to write a margin note."; return
        }
        addMarginNote(pageIndex: pageIndex, region: region, quote: quote)
    }

    func addMarginNote(pageIndex: Int, region: CGRect, quote: String) {
        guard let workspace, let page = document?.page(at: pageIndex) else { return }
        do {
            let anchorRegion = PageRegion(region)
            let data = try PDFRegionRenderer.png(page: page, region: anchorRegion)
            let name = "\(UUID().uuidString).png"
            try repository.saveImage(data, workspaceID: workspace.id, name: name)
            let anchor = SourceAnchor(pageIndex: pageIndex, pageLabel: printedLabel(for: pageIndex) ?? page.label ?? String(pageIndex + 1),
                                      region: anchorRegion, quote: quote, imageName: name)
            let note = StudyNote(anchor: anchor, kind: .comment)
            self.workspace?.notes.insert(note, at: 0)
            registerNoteCreationUndo(note, bookID: workspace.id)
            selectedNoteID = note.id
            reader.view?.clearSelection(); reader.selection = nil; reader.hasSelection = false
            flush()
            editMarginNote(note.id)
        } catch { self.error = "Could not start a margin note: \(error.localizedDescription)" }
    }

    /// Opens a margin note's editor beside its line.
    func editMarginNote(_ id: UUID) {
        guard let note = workspace?.notes.first(where: { $0.id == id }) else { return }
        definitionLookup = nil; referencePeek = nil; quickAsk = nil
        selectedNoteID = id
        if reader.view?.visiblePages.contains(where: { reader.view?.document?.index(for: $0) == note.anchor.pageIndex }) != true { reader.go(to: note.anchor) }
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.reader.view else { return }
            view.presentMarginNote(note, store: self)
        }
    }

    /// Closes a margin note's editor, as switching books or opening another editor does; the note keeps what was typed.
    func dismissMarginNote() { reader.view?.dismissMarginNote() }

    /// Called when a margin note's editor closes: an empty note is discarded, as an unused sticky note would be.
    func finishMarginNote(_ id: UUID) {
        guard let note = workspace?.notes.first(where: { $0.id == id }), note.kind == .comment else { return }
        if note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, note.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            removeNote(id: id, undoManager: nil)
        } else { flush() }
    }
}

@MainActor
final class MarginNotePopover: NSObject, NSPopoverDelegate {
    let popover = NSPopover()
    private weak var store: StudyStore?
    let noteID: UUID

    init(store: StudyStore, noteID: UUID) {
        self.store = store; self.noteID = noteID
        super.init()
        popover.contentViewController = NSHostingController(rootView: MarginNoteEditor(store: store, noteID: noteID) { [weak self] in self?.popover.close() }.tint(.lemmaOlive))
        popover.behavior = .semitransient
        popover.animates = false
        popover.delegate = self
    }

    func popoverDidClose(_ notification: Notification) { store?.finishMarginNote(noteID) }
}

@MainActor
extension RegionPDFView {
    func presentMarginNote(_ note: StudyNote, store: StudyStore) {
        guard window?.isVisible == true, let page = document?.page(at: note.anchor.pageIndex) else { return }
        dismissMarginNote(); dismissQuickAsk(); dismissReferencePeek(); dismissDefinitionLookup()
        var anchor = convert(note.anchor.region.rect, from: page).intersection(bounds)
        if anchor.isNull || anchor.isEmpty { anchor = CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1) }
        let presentation = MarginNotePopover(store: store, noteID: note.id)
        marginNotePopover = presentation
        presentation.popover.show(relativeTo: anchor, of: self, preferredEdge: .maxX)
    }

    func dismissMarginNote() {
        if marginNotePopover?.popover.isShown == true { marginNotePopover?.popover.close() }
        marginNotePopover = nil
    }

    /// The text line beside a point in the page's margin, widened to its column: where a pencilled remark belongs.
    func marginLine(at local: CGPoint) -> (pageIndex: Int, region: CGRect, quote: String)? {
        guard let page = page(for: local, nearest: false), let document else { return nil }
        let point = convert(local, to: page)
        let box = page.bounds(for: .cropBox)
        let fragments = PageReferenceAnalyzer.fragments(on: page)
        guard !fragments.isEmpty else { return nil }
        let column = ReferenceLayout.column(containing: point.x, near: point.y, fragments: fragments, page: box)
        guard point.x < column.lowerBound - 6 || point.x > column.upperBound + 6 else { return nil }
        let inColumn = fragments.filter { $0.bounds.midX >= column.lowerBound - 4 && $0.bounds.midX <= column.upperBound + 4 }
        guard let line = inColumn.min(by: { abs($0.bounds.midY - point.y) < abs($1.bounds.midY - point.y) }),
              abs(line.bounds.midY - point.y) <= max(14, line.bounds.height) else { return nil }
        let region = CGRect(x: column.lowerBound - 2, y: line.bounds.minY - 1.5, width: column.upperBound - column.lowerBound + 4, height: line.bounds.height + 3)
            .intersection(box)
        return (document.index(for: page), region, page.selection(for: region)?.string ?? line.text)
    }
}

/// The note's text in place, with Markdown and LaTeX preview.
struct MarginNoteEditor: View {
    @Bindable var store: StudyStore
    let noteID: UUID
    let close: () -> Void
    @State private var preview = false
    @FocusState private var focused: Bool

    private var note: StudyNote? { store.workspace?.notes.first { $0.id == noteID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Margin note", systemImage: "note.text").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let note { Text(store.shortPageText(note.anchor.pageIndex)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary) }
                Spacer()
                Button(preview ? "Edit" : "Preview") { preview.toggle() }.buttonStyle(.link).font(.caption)
                    .disabled(note?.body.isEmpty != false)
            }
            if preview, let note, !note.body.isEmpty {
                ScrollView { MathPreview(text: note.body) }.frame(width: 320, height: 150)
            } else {
                TextEditor(text: Binding(get: { note?.body ?? "" }, set: { value in store.updateNote(id: noteID) { $0.body = value } }))
                    .font(.system(size: 13)).scrollContentBackground(.hidden)
                    .padding(6).frame(width: 320, height: 150)
                    .background(MarginNoteStyle.paper, in: RoundedRectangle(cornerRadius: 6))
                    .focused($focused)
                    .accessibilityLabel("Margin note text")
            }
            Text("Markdown and LaTeX · the first line is the title").font(.caption2).foregroundStyle(.tertiary)
            HStack {
                Button("Open in Notebook") { store.selectNote(noteID); close() }.buttonStyle(.link).font(.caption)
                Spacer()
                // The reader window's undo manager: the popover's own goes away with it, and ⌘Z in the reader could not restore the note.
                Button(role: .destructive) { close(); store.removeNote(id: noteID, undoManager: store.mainWindow?.undoManager ?? store.reader.view?.undoManager) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Delete this margin note (Undo restores it)").accessibilityLabel("Delete margin note")
                Button("Done", action: close).buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command).help("⌘↩")
            }
        }
        .padding(12)
        .onAppear { focused = true }
    }
}

/// The sticky-note colours: warm paper that reads in both appearances.
enum MarginNoteStyle {
    static let paperColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.31, green: 0.28, blue: 0.16, alpha: 1) : NSColor(srgbRed: 1.0, green: 0.96, blue: 0.78, alpha: 1)
    }
    static let edgeColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.62, green: 0.55, blue: 0.27, alpha: 1) : NSColor(srgbRed: 0.86, green: 0.74, blue: 0.33, alpha: 1)
    }
    static var paper: Color { Color(nsColor: paperColor) }
}
