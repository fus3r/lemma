import AppKit
import PDFKit
import LemmaCore

/// Actions offered by the PDF's context menu. The store performs them.
enum ReaderContextAction {
    case peek(PageMention, Int)
    case goTo(PageMention, Int)
    case pinReference(PageMention, Int)
    case openToSide(PageMention, Int)
    case findMentions(ReferenceKey)
    case ask(ReaderSelection)
    case addNote(NoteKind, ReaderSelection)
    case highlight(HighlightSwatch, ReaderSelection)
    case underline(ReaderSelection)
    case removeHighlight(UUID)
    case pinSelection(ReaderSelection)
    case lookUp(String, Int, CGRect)
    case bookmark
    case marginNote(Int, CGRect, String)
    case derive(ReaderSelection)
    case watch(String)
    case breakpoint(Int, CGPoint)
    case debugHere(Int, CGPoint)
}

/// The selection when the menu opened; PDFKit may change the live selection on a right-click.
typealias ReaderSelection = (pageIndex: Int, region: CGRect, text: String)

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, keyEquivalent: String = "", modifiers: NSEvent.ModifierFlags = [], handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        keyEquivalentModifierMask = modifiers
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func run() { handler() }
}

@MainActor
extension RegionPDFView {
    /// Lemma's study actions come first; PDFKit's own items (Copy, zoom…) follow.
    override func menu(for event: NSEvent) -> NSMenu? {
        let captured: ReaderSelection? = controller?.hasSelection == true ? controller?.selection.map { ($0.0, $0.1, $0.2) } : nil
        let menu = super.menu(for: event) ?? NSMenu()
        guard let controller, let perform = controller.onContextAction, !controller.regionMode, !controller.inkMode else { return menu }
        let point = convert(event.locationInWindow, from: nil)
        var items: [NSMenuItem] = []
        if let highlight = highlightHit(at: point) {
            items.append(ActionMenuItem(highlight.style == .underline ? "Remove Underline" : "Remove Highlight") { perform(.removeHighlight(highlight.id)) })
            items.append(.separator())
        }
        if let page = page(for: point, nearest: false), let document, let index = controller.references,
           let mention = index.mention(at: convert(point, to: page), onPage: document.index(for: page)) {
            let pageIndex = document.index(for: page)
            let title = mention.key.title
            if !mention.isDefinition || mention.destination != nil {
                items.append(ActionMenuItem("Peek at \(title)") { perform(.peek(mention, pageIndex)) })
                items.append(ActionMenuItem("Go to \(title)") { perform(.goTo(mention, pageIndex)) })
                items.append(ActionMenuItem("Open \(title) to the Side") { perform(.openToSide(mention, pageIndex)) })
                items.append(ActionMenuItem("Pin \(title)") { perform(.pinReference(mention, pageIndex)) })
            }
            items.append(ActionMenuItem(mention.key.kind == .citation ? "Find Citations of \(title)" : "Find All References to \(title)") { perform(.findMentions(mention.key)) })
            items.append(.separator())
        }
        if let captured {
            items.append(ActionMenuItem("Ask About Selection…", keyEquivalent: "k", modifiers: .command) { perform(.ask(captured)) })
            let notes = NSMenuItem(title: "New Note from Selection", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for kind in NoteKind.allCases { submenu.addItem(ActionMenuItem(kind.label) { perform(.addNote(kind, captured)) }) }
            notes.submenu = submenu
            items.append(notes)
            let highlight = NSMenuItem(title: "Highlight", action: nil, keyEquivalent: "")
            highlight.submenu = NativeMenu.make((controller.owner?.app.highlightPalette.settings.colors ?? HighlightColor.allCases.map(HighlightSwatch.init)).map { swatch in
                .colorAction(swatch.name, color: swatch.nativeColor) { perform(.highlight(swatch, captured)) }
            })
            items.append(highlight)
            items.append(ActionMenuItem("Underline Selection") { perform(.underline(captured)) })
            items.append(ActionMenuItem("Pin Selection") { perform(.pinSelection(captured)) })
            items.append(ActionMenuItem("Work Through as a Derivation…") { perform(.derive(captured)) })
            let term = captured.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !term.isEmpty, term.count <= 40 { items.append(ActionMenuItem("Look Up “\(term)”") { perform(.lookUp(term, captured.pageIndex, captured.region)) }) }
            if !term.isEmpty, term.count <= 24 { items.append(ActionMenuItem("Add “\(term)” to Watch") { perform(.watch(term)) }) }
        } else if let page = page(for: point, nearest: false), let document,
                  let word = page.selectionForWord(at: convert(point, to: page)), let text = word.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let pageIndex = document.index(for: page), bounds = word.bounds(for: page)
            items.append(ActionMenuItem("Look Up “\(text)”") { perform(.lookUp(text, pageIndex, bounds)) })
        }
        if captured == nil, let line = marginLine(at: point) ?? textLine(at: point) {
            items.append(ActionMenuItem("Add Margin Note Here") { perform(.marginNote(line.pageIndex, line.region, line.quote)) })
            let pagePoint = CGPoint(x: line.region.midX, y: line.region.midY)
            items.append(ActionMenuItem("Toggle Breakpoint on This Line") { perform(.breakpoint(line.pageIndex, pagePoint)) })
            items.append(ActionMenuItem("Run and Debug from Here") { perform(.debugHere(line.pageIndex, pagePoint)) })
        }
        items.append(ActionMenuItem("Bookmark Page") { perform(.bookmark) })
        items.append(.separator())
        for (offset, item) in items.enumerated() { menu.insertItem(item, at: offset) }
        return menu
    }
}

@MainActor
extension RegionPDFView {
    /// The text line under a point of the page, widened to its column, for a margin note started from the context menu.
    func textLine(at local: CGPoint) -> (pageIndex: Int, region: CGRect, quote: String)? {
        guard let page = page(for: local, nearest: false), let document else { return nil }
        let point = convert(local, to: page)
        let box = page.bounds(for: .cropBox)
        let fragments = PageReferenceAnalyzer.fragments(on: page)
        guard let line = fragments.first(where: { $0.bounds.insetBy(dx: -2, dy: -2).contains(point) }) else { return nil }
        let column = ReferenceLayout.column(containing: point.x, near: point.y, fragments: fragments, page: box)
        let region = CGRect(x: column.lowerBound - 2, y: line.bounds.minY - 1.5, width: column.upperBound - column.lowerBound + 4, height: line.bounds.height + 3).intersection(box)
        return (document.index(for: page), region, page.selection(for: region)?.string ?? line.text)
    }
}

@MainActor
extension StudyStore {
    func perform(_ action: ReaderContextAction) {
        switch action {
        case let .peek(mention, page): peekReference(mention, pageIndex: page)
        case let .goTo(mention, page): withTarget(of: mention, from: page) { self.goToReference($0) }
        case let .pinReference(mention, page): withTarget(of: mention, from: page) { self.pinReference($0) }
        case let .openToSide(mention, page): withTarget(of: mention, from: page) { self.openToSide($0) }
        case let .findMentions(key): showReferences(to: key)
        case let .ask(selection): restore(selection); prepareQuickAsk()
        case let .addNote(kind, selection): restore(selection); addNote(kind: kind)
        case let .highlight(swatch, selection): restore(selection); highlightSelection(swatch: swatch)
        case let .underline(selection): restore(selection); highlightSelection(style: .underline)
        case let .removeHighlight(id): removeHighlight(id: id)
        case let .pinSelection(selection): restore(selection); pinSelection()
        case let .lookUp(text, page, rect): lookupDefinition(text, pageIndex: page, region: rect)
        case .bookmark: toggleBookmark()
        case let .marginNote(page, region, quote): addMarginNote(pageIndex: page, region: region, quote: quote)
        case let .derive(selection): restore(selection); deriveSelection()
        case let .watch(term): addWatch(term); reveal(.debug); paneExpanded["debug.watch"] = true
        case let .breakpoint(page, point):
            let wasOn = reader.rulerMode, previous = reader.rulerLine
            reader.placeRuler(at: point, pageIndex: page)
            toggleBreakpoint()
            if !wasOn { reader.rulerLine = nil } else if let previous, debug != nil { reader.rulerLine = previous }
        case let .debugHere(page, point):
            if debug != nil { stopDebugging() }
            startDebugging(from: (page, point))
        }
    }

    private func restore(_ selection: ReaderSelection) {
        reader.selection = (selection.pageIndex, selection.region, selection.text)
        reader.hasSelection = true
    }

    private func withTarget(of mention: PageMention, from page: Int, _ use: @escaping (ReferenceTarget) -> Void) {
        guard let index = references else { return }
        let workspaceID = workspace?.id
        status = "Finding \(mention.key.title)…"
        Task { @MainActor [weak self] in
            let target = await index.resolve(mention, from: page)
            guard let self, self.workspace?.id == workspaceID else { return }
            if let target { self.status = ""; use(target) }
            else { self.status = "No definition found for \(mention.key.title). Try Find Mentions." }
        }
    }
}
