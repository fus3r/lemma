import AppKit
import PDFKit
import LemmaCore

/// A Shift-drag moves the nearer end of a mark inward, or extends it outward, with one undo step on mouse-up.
struct HighlightDrag {
    let bookID: String
    let original: StudyHighlight
    let range: NSRange
    let movesStart: Bool
    let start: CGPoint
    var selection: PDFSelection?
    var shortens = false
}

@MainActor
extension RegionPDFView {
    func highlightHit(at local: CGPoint) -> StudyHighlight? {
        guard controller?.showAnnotations == true, let book = controller?.owner?.workspace,
              let page = page(for: local, nearest: false), let document else { return nil }
        let pageIndex = document.index(for: page), point = convert(local, to: page)
        return book.highlights.reversed().first { highlight in
            highlight.pageIndex == pageIndex && highlight.regions.contains { $0.rect.insetBy(dx: -1, dy: -1).contains(point) }
        }
    }

    /// Only a drag starting on an existing mark is intercepted; ordinary Shift-selection elsewhere stays PDFKit's.
    func beginHighlightExtension(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.shift), event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
              controller?.regionMode != true, controller?.inkMode != true,
              let bookID = controller?.owner?.workspace?.id,
              let highlight = highlightHit(at: convert(event.locationInWindow, from: nil)),
              let page = document?.page(at: highlight.pageIndex) else { return false }
        let ranges = highlight.regions.flatMap { region -> [NSRange] in
            guard let selection = page.selection(for: region.rect) else { return [] }
            return (0..<selection.numberOfTextRanges(on: page)).map { selection.range(at: $0, on: page) }
                .filter { $0.location != NSNotFound && $0.length > 0 }
        }
        guard let lower = ranges.map(\.location).min(), let upper = ranges.map({ NSMaxRange($0) }).max(),
              upper > lower, upper <= page.numberOfCharacters else { return false }
        let local = convert(event.locationInWindow, from: nil)
        let character = page.characterIndex(at: convert(local, to: page))
        highlightDrag = HighlightDrag(bookID: bookID, original: highlight, range: NSRange(location: lower, length: upper - lower),
                                      movesStart: character < lower + (upper - lower) / 2, start: local)
        controller?.activeHighlightID = highlight.id
        window?.makeFirstResponder(self)
        NSCursor.resizeLeftRight.set()
        return true
    }

    func updateHighlightExtension(with event: NSEvent) {
        guard var drag = highlightDrag, let page = document?.page(at: drag.original.pageIndex) else { return }
        let local = convert(event.locationInWindow, from: nil)
        guard hypot(local.x - drag.start.x, local.y - drag.start.y) > 3 else {
            if drag.selection != nil { setCurrentSelection(page.selection(for: drag.range), animate: false) }
            drag.selection = nil; highlightDrag = drag
            return
        }
        let point = convert(local, to: page)
        let anchor = page.characterBounds(at: drag.movesStart ? NSMaxRange(drag.range) - 1 : drag.range.location)
        guard let preview = page.selection(from: CGPoint(x: anchor.midX, y: anchor.midY), to: point),
              preview.numberOfTextRanges(on: page) > 0 else { return }
        let ranges = (0..<preview.numberOfTextRanges(on: page)).map { preview.range(at: $0, on: page) }
            .filter { $0.location != NSNotFound && $0.length > 0 }
        guard let first = ranges.map(\.location).min(), let last = ranges.map({ NSMaxRange($0) }).max() else { return }
        let outside = first < drag.range.location || last > NSMaxRange(drag.range)
        let lower = outside ? min(drag.range.location, first) : drag.movesStart ? first : drag.range.location
        let upper = outside ? max(NSMaxRange(drag.range), last) : drag.movesStart ? NSMaxRange(drag.range) : last
        drag.shortens = lower > drag.range.location || upper < NSMaxRange(drag.range)
        if lower == drag.range.location && upper == NSMaxRange(drag.range) {
            drag.selection = nil
            setCurrentSelection(page.selection(for: drag.range), animate: false)
        } else {
            drag.selection = page.selection(for: NSRange(location: lower, length: upper - lower))
            setCurrentSelection(drag.selection, animate: false)
        }
        highlightDrag = drag
    }

    func finishHighlightExtension(with event: NSEvent) {
        updateHighlightExtension(with: event)
        guard let drag = highlightDrag else { return }
        highlightDrag = nil
        guard let store = controller?.owner, store.workspace?.id == drag.bookID,
              let selection = drag.selection, let page = document?.page(at: drag.original.pageIndex) else { return }
        let regions = selection.selectionsByLine().map { $0.bounds(for: page) }
            .filter { !$0.isEmpty && !$0.isNull }.map(PageRegion.init)
        guard !regions.isEmpty else { return }
        var changed = drag.original
        changed.regions = regions; changed.quote = selection.string ?? changed.quote
        let action = drag.shortens ? "Shorten" : "Extend"
        store.replaceHighlight(changed, bookID: drag.bookID, actionName: "\(action) \(changed.style.label)")
        clearSelection()
        controller?.selection = nil; controller?.hasSelection = false
    }
}
