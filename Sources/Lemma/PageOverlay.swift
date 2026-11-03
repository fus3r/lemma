import AppKit
import PDFKit
import QuartzCore
import LemmaCore

/// The marks Lemma draws over the pages: line numbers and change bars, reference underlines and counts, folded proofs
/// and their gutter controls, understood checks, margin notes, breakpoints, the reading ruler and the debugger's line,
/// recall masks, the capture outline and the stroke being drawn.
///
/// Marks are laid out per page in this view's bounds coordinates, and the bounds origin follows the PDF view's scroll
/// offset (`followScroll`, called from the clip view's bounds notification). Scrolling therefore moves every mark with
/// its page in the same Core Animation transaction, without measuring or drawing anything. A page's marks are built
/// when it comes into view and again only when what they show changes: the reader's marks and modes (`invalidate`),
/// the zoom, the room beside the page, the theme. Line numbers are drawn in narrow strips beside each page (the current
/// line is redrawn alone), underlines and other shapes are shape layers, and the transient marks (hover, flash, ruler,
/// capture outline, stroke, recall masks) are updated on their own. The bounds origin is reset to zero whenever
/// everything is laid out again, so between scrolls marks have the PDF view's coordinates.
@MainActor
final class RegionSelectionOverlay: NSView {
    weak var controller: ReaderController?
    /// The capture outline in the PDF view's coordinates, when there is one.
    private(set) var rectangle: CGRect?
    /// Recall masks in the PDF view's coordinates at the last update.
    private(set) var recallRectangles: [CGRect] = []
    var recallRectangle: CGRect? { recallRectangles.first }
    /// Where the recall masks are now, in the PDF view's coordinates: they move with the scroll between updates.
    var recallMasksOnScreen: [CGRect] {
        recallViews.map { convert($0.frame, to: superview).insetBy(dx: 0.5, dy: 0.5) }
    }

    /// Everything that places marks on the page; when any of it changes, every page is laid out again.
    private struct Layout: Equatable {
        var document: ObjectIdentifier?
        var documentView: ObjectIdentifier?
        var documentSize: CGSize = .zero
        var magnification: CGFloat = 0
        var size: CGSize = .zero
        var displayMode = -1
        var scale: CGFloat = 0
        var revision = -1
        var modes: [Bool] = []
        var pageTheme: PageTheme = .paper
        var appearance = ""
    }
    private var layout = Layout()
    private var revision = 0
    /// The document view's origin in the PDF view when the marks were laid out; the bounds origin is the scroll since.
    private var anchor: CGPoint = .zero

    private var pages: [Int: PageMarks] = [:]
    private var visibleIndexes: [Int] = []
    private var noteViews: [UUID: (signature: String, view: NSView)] = [:]
    private var marginInputs: (pages: [Int], selected: UUID?)?

    private let shapes = ShapeHost()
    private let dotsLayer = quiet(CALayer())
    private let underlinesLayer = quiet(CALayer())
    private let veil = quiet(CAShapeLayer()), band = quiet(CAShapeLayer()), bar = quiet(CAShapeLayer())
    private let arrow = quiet(CALayer())
    private let hoverFill = quiet(CAShapeLayer()), hoverLine = quiet(CAShapeLayer())
    private let flashLayer = quiet(CAShapeLayer())
    private let strokeLayer = quiet(CAShapeLayer())
    private let selectedNote = quiet(CAShapeLayer())
    private let region = quiet(CAShapeLayer())
    private var recallViews: [RecallMaskView] = []
    private var stroke: (pageIndex: Int, count: Int)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        // Marks of pages partly scrolled away must not draw over the tab bar or the minimap.
        clipsToBounds = true
        shapes.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        addSubview(shapes)
        for sublayer in [dotsLayer, veil, band, bar, arrow, underlinesLayer, hoverFill, hoverLine, flashLayer, strokeLayer, selectedNote, region] {
            shapes.layer?.addSublayer(sublayer)
        }
        strokeLayer.fillColor = nil; strokeLayer.lineCap = .round; strokeLayer.lineJoin = .round
        hoverLine.fillColor = nil
        veil.fillRule = .evenOdd
        region.lineWidth = 2
        selectedNote.lineWidth = 1
        flashLayer.lineWidth = 1.5
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    /// Only the marks that act on clicks take them (fold bars, counts, cards); clicks elsewhere reach the page.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard controller?.regionMode != true, controller?.inkMode != true else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let view = superview as? RegionPDFView { revision &+= 1; update(in: view) }
    }

    /// The marks are laid out again at the next update (the reader's notes, highlights or modes changed).
    func invalidate() { revision &+= 1 }

    // MARK: Scrolling

    /// Keeps the marks on their pages while the PDF view scrolls: the bounds origin follows the document view. Returns
    /// false when the scroll changed more than the offset (zoom, resizing, another layout), which needs `update`.
    @discardableResult
    func followScroll(in view: RegionPDFView) -> Bool {
        guard superview === view, let documentView = view.documentView else { return false }
        guard currentLayoutGeometry(view) == geometry(of: layout) else { return false }
        let origin = view.convert(CGPoint.zero, from: documentView)
        let target = CGPoint(x: anchor.x - origin.x, y: anchor.y - origin.y)
        // A horizontal scroll changes the room beside the page, which decides where numbers and cards go.
        guard abs(target.x) < 0.5 || abs(target.x - bounds.origin.x) < 0.5 else { return false }
        if bounds.origin != target { setBoundsOrigin(target) }
        return true
    }

    private struct Geometry: Equatable {
        var document: ObjectIdentifier?, documentView: ObjectIdentifier?
        var documentSize: CGSize, magnification: CGFloat, size: CGSize, displayMode: Int
    }

    private func geometry(of layout: Layout) -> Geometry {
        Geometry(document: layout.document, documentView: layout.documentView, documentSize: layout.documentSize,
                 magnification: layout.magnification, size: layout.size, displayMode: layout.displayMode)
    }

    private func currentLayoutGeometry(_ view: RegionPDFView) -> Geometry {
        let documentView = view.documentView
        return Geometry(document: view.document.map(ObjectIdentifier.init), documentView: documentView.map(ObjectIdentifier.init),
                        documentSize: documentView?.bounds.size ?? .zero, magnification: documentView?.enclosingScrollView?.magnification ?? 1,
                        size: view.bounds.size, displayMode: view.displayMode.rawValue)
    }

    // MARK: Update

    /// Brings the marks up to date: lays everything out again when the layout inputs changed, builds the pages that came
    /// into view, places the margin notes, and refreshes the transient marks. Cheap when nothing changed.
    func update(in view: RegionPDFView) {
        QAPerf.tick("Overlay.update")
        if superview !== view {
            autoresizingMask = [.width, .height]
            view.addSubview(self, positioned: .above, relativeTo: nil)
        }
        if frame != view.bounds { frame = view.bounds }
        guard let controller, let document = view.document, let documentView = view.documentView else { clear(); return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let current = currentLayout(view, controller: controller, document: document, documentView: documentView)
        if current != layout || !followScroll(in: view) {
            removePages(keeping: [])
            layout = current
            anchor = view.convert(CGPoint.zero, from: documentView)
            setBoundsOrigin(.zero)
            marginInputs = nil
            applyColors()
        }
        let visible = (view.visiblePageIndexes().map(Array.init) ?? []).compactMap { index in document.page(at: index).map { ($0, index) } }
        let indexes = visible.map(\.1)
        if indexes != visibleIndexes {
            removePages(keeping: Set(indexes))
            visibleIndexes = indexes
        }
        for (page, index) in visible where pages[index] == nil {
            pages[index] = buildPage(page, index: index, in: view, controller: controller)
        }
        if marginInputs.map({ $0.pages != indexes || $0.selected != controller.selectedNoteID }) ?? true {
            marginInputs = (indexes, controller.selectedNoteID)
            placeMarginNotes(visible, in: view, controller: controller, document: document)
        }
        updateTransientMarks(in: view, controller: controller, document: document)
        updateFocusLine()
    }

    private func currentLayout(_ view: RegionPDFView, controller: ReaderController, document: PDFDocument, documentView: NSView) -> Layout {
        let geometry = currentLayoutGeometry(view)
        return Layout(document: geometry.document, documentView: geometry.documentView, documentSize: geometry.documentSize,
                      magnification: geometry.magnification, size: geometry.size, displayMode: geometry.displayMode, scale: view.scaleFactor, revision: revision,
                      modes: [controller.showLineNumbers, controller.showReferenceLinks, controller.showReferenceCounts, controller.showFoldControls,
                              controller.showAnnotations, controller.regionMode, controller.inkMode, controller.isScrubbing, controller.debugging,
                              controller.references?.analysis?.analysis != nil, controller.references != nil],
                      pageTheme: PageThemeState.shared.theme, appearance: effectiveAppearance.name.rawValue)
    }

    private func clear() {
        removePages(keeping: [])
        for (_, entry) in noteViews { entry.view.removeFromSuperview() }
        noteViews = [:]; marginInputs = nil; visibleIndexes = []
        layout = Layout()
        for layer in [hoverFill, hoverLine, flashLayer, strokeLayer, selectedNote, region, veil, band, bar] { layer.path = nil }
        arrow.isHidden = true
        recallViews.forEach { $0.removeFromSuperview() }; recallViews = []; recallRectangles = []
        rectangle = nil; stroke = nil
    }

    private func removePages(keeping kept: Set<Int>) {
        for (index, marks) in pages where !kept.contains(index) {
            marks.remove()
            pages[index] = nil
        }
    }

    /// Colours of the shape layers, resolved in the view's appearance and the page theme.
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let olive = NSColor.lemmaOliveOnPage
            hoverFill.fillColor = olive.withAlphaComponent(0.12).cgColor
            hoverLine.strokeColor = olive.withAlphaComponent(0.95).cgColor
            hoverLine.lineWidth = 1.4
            flashLayer.fillColor = olive.withAlphaComponent(0.12).cgColor
            flashLayer.strokeColor = olive.withAlphaComponent(0.8).cgColor
            selectedNote.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.05).cgColor
            selectedNote.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor
            region.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.13).cgColor
            region.strokeColor = NSColor.controlAccentColor.cgColor
        }
        rulerInputs = nil; hoverInputs = nil; flashInputs = nil
    }

    // MARK: Pages

    /// Page space to this view's bounds space: the PDF view's mapping plus the scroll since the layout.
    private func transform(for page: PDFPage, in view: RegionPDFView) -> CGAffineTransform {
        let origin = bounds.origin
        let o = view.convert(CGPoint.zero, from: page), x = view.convert(CGPoint(x: 1, y: 0), from: page), y = view.convert(CGPoint(x: 0, y: 1), from: page)
        return CGAffineTransform(a: x.x - o.x, b: x.y - o.y, c: y.x - o.x, d: y.y - o.y, tx: o.x + origin.x, ty: o.y + origin.y)
    }

    private func buildPage(_ page: PDFPage, index pageIndex: Int, in view: RegionPDFView, controller: ReaderController) -> PageMarks {
        QAPerf.tick("Overlay.buildPage")
        let marks = PageMarks(index: pageIndex)
        let toView = transform(for: page, in: view)
        let box = page.bounds(for: .cropBox)
        let pageRect = box.applying(toView)
        marks.pageRect = pageRect
        if controller.showLineNumbers, !controller.regionMode, !controller.inkMode {
            placeLineNumbers(on: page, index: pageIndex, transform: toView, pageRect: pageRect, controller: controller, into: marks)
        }
        placeBreakpoints(on: page, index: pageIndex, transform: toView, pageRect: pageRect, controller: controller, into: marks)
        // Folded proofs and the gutter's fold controls are a reading aid, shown in either edition.
        if !controller.regionMode, !controller.inkMode, let analysis = controller.references?.analysis, analysis.analysis != nil {
            placeFolds(on: page, index: pageIndex, transform: toView, pageRect: pageRect, analysis: analysis, controller: controller, into: marks)
        }
        if controller.showAnnotations, controller.showReferenceLinks, !controller.regionMode, !controller.inkMode, let index = controller.references {
            placeUnderlines(index: pageIndex, transform: toView, references: index, controller: controller, into: marks)
            if controller.showReferenceCounts, let analysis = index.analysis, analysis.analysis != nil {
                placeLenses(on: page, index: pageIndex, transform: toView, pageRect: pageRect, analysis: analysis, controller: controller, into: marks)
            }
        }
        return marks
    }

    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
    /// Sizes of line numbers by digit count: the digits of this font all have the same advance.
    private static var numberSizes: [Int: CGSize] = [:]
    private static func numberSize(_ text: String) -> CGSize {
        if let size = numberSizes[text.count] { return size }
        let size = (String(repeating: "8", count: text.count) as NSString).size(withAttributes: [.font: numberFont])
        numberSizes[text.count] = size
        return size
    }

    /// Numbers beside each line, outside the page when the window leaves room (inside its margin otherwise), and a
    /// bar where the reader noted, marked “?” or drew, like the change bars of an editor's gutter.
    private func placeLineNumbers(on page: PDFPage, index pageIndex: Int, transform toView: CGAffineTransform, pageRect: CGRect,
                                  controller: ReaderController, into marks: PageMarks) {
        let lines = controller.readingLines(onPage: pageIndex)
        guard !lines.isEmpty, lines.count < 400 else { return }
        let leftRoom = pageRect.minX - bounds.minX, rightRoom = bounds.maxX - pageRect.maxX
        // Bars for the reader's own marks on this page.
        var bars: [(CGRect, NSColor)] = []
        // A highlight already marks its text. Repeating it as a solid gutter bar looked like a stray yellow stroke.
        for note in controller.notes where note.anchor.pageIndex == pageIndex {
            let color: NSColor = note.isQuickMark ? .systemOrange : note.kind == .comment ? MarginNoteStyle.edgeColor : .lemmaOliveOnPage
            bars.append((note.anchor.region.rect, color))
        }
        for stroke in controller.inkStrokes where stroke.pageIndex == pageIndex {
            let xs = stroke.points.map(\.x), ys = stroke.points.map(\.y)
            if let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() {
                bars.append((CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY)), .systemBlue))
            }
        }
        // Lines under a folded proof are hidden, as an editor hides folded lines.
        let folded = (controller.references?.analysis?.proofsByPage[pageIndex] ?? [])
            .filter { controller.foldedProofs.contains($0.stableID) }
            .flatMap { $0.regions.filter { $0.pageIndex == pageIndex }.map(\.region.rect) }
        let box = page.bounds(for: .cropBox)
        let mid = box.midX
        // Two columns when many lines sit wholly on each side of the middle (a paper); one otherwise (a centred display is not a column).
        let leftOnly = lines.filter { $0.maxX < mid }.count, rightOnly = lines.filter { $0.minX > mid }.count
        let twoColumns = leftOnly >= max(4, lines.count / 4) && rightOnly >= max(4, lines.count / 4)
        // Inside the margin, numbers align on the text column's left edge, so centred lines do not move them.
        let starts = lines.filter { !twoColumns || $0.maxX < mid }.map(\.minX).sorted()
        let columnLeft = starts.isEmpty ? box.minX : starts[starts.count / 10]
        let columnRight = lines.filter { $0.minX > mid }.map(\.maxX).sorted().last ?? box.maxX
        var left: [GutterView.Item] = [], right: [GutterView.Item] = []
        var lastLeft = CGRect.null, lastRight = CGRect.null
        for (index, line) in lines.enumerated() {
            if folded.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(CGPoint(x: line.midX, y: line.midY)) }) { continue }
            let rect = line.applying(toView)
            let isRight = twoColumns && line.minX > mid
            let text = "\(index + 1)"
            let size = Self.numberSize(text)
            var numberRect: CGRect
            var barX: CGFloat
            if isRight {
                if rightRoom >= 34 { numberRect = CGRect(x: pageRect.maxX + 9, y: rect.midY - size.height / 2, width: size.width, height: size.height); barX = pageRect.maxX + 3 }
                else {
                    let edge = CGPoint(x: columnRight, y: 0).applying(toView).x
                    numberRect = CGRect(x: edge + 6, y: rect.midY - size.height / 2, width: size.width, height: size.height); barX = edge + 2
                }
            } else if leftRoom >= 52 {
                numberRect = CGRect(x: pageRect.minX - 24 - size.width, y: rect.midY - size.height / 2, width: size.width, height: size.height)
                barX = pageRect.minX - 5
            } else {
                let edge = CGPoint(x: columnLeft, y: 0).applying(toView).x
                numberRect = CGRect(x: edge - 7 - size.width, y: rect.midY - size.height / 2, width: size.width, height: size.height)
                barX = edge - 4
                if numberRect.minX < pageRect.minX + 2 { continue }
            }
            // Lines set closer than the numbers' own height (scripts of a display) keep the first number.
            if isRight ? !lastRight.isNull && lastRight.insetBy(dx: -2, dy: -1).intersects(numberRect) : !lastLeft.isNull && lastLeft.insetBy(dx: -2, dy: -1).intersects(numberRect) { continue }
            if isRight { lastRight = numberRect } else { lastLeft = numberRect }
            let mark = bars.first { $0.0.insetBy(dx: -1, dy: -1).intersects(line.insetBy(dx: 0, dy: line.height * 0.2)) }
            let item = GutterView.Item(number: numberRect, text: text, bar: mark.map { _ in CGRect(x: barX, y: rect.minY, width: 2.5, height: rect.height) },
                                       barColor: mark?.1, index: index)
            if isRight { right.append(item) } else { left.append(item) }
            marks.lineHits.append((numberRect, index))
        }
        let dark = PageThemeState.shared.theme.isDark
        let onPaper = window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let dim = dark || onPaper ? NSColor(white: 0.55, alpha: 0.75) : NSColor(white: 0.45, alpha: 0.7)
        for items in [left, right] where !items.isEmpty {
            let gutter = GutterView(items: items, font: Self.numberFont, dim: dim)
            addSubview(gutter, positioned: .below, relativeTo: shapes)
            marks.gutters.append(gutter)
        }
    }

    /// Breakpoints (red dots) beside their lines, as in an editor's gutter.
    private func placeBreakpoints(on page: PDFPage, index pageIndex: Int, transform toView: CGAffineTransform, pageRect: CGRect,
                                  controller: ReaderController, into marks: PageMarks) {
        let breakpoints = controller.breakpoints.filter { $0.pageIndex == pageIndex }
        guard !breakpoints.isEmpty else { return }
        let lines = controller.readingLines(onPage: pageIndex)
        let x = pageRect.minX - bounds.minX >= 52 ? pageRect.minX - 47 : pageRect.minX + 4
        let enabled = CGMutablePath(), disabled = CGMutablePath()
        for mark in breakpoints {
            guard let line = lines.min(by: { abs(Double($0.midY) - mark.y) < abs(Double($1.midY) - mark.y) }) else { continue }
            let rect = line.applying(toView)
            (mark.enabled ? enabled : disabled).addEllipse(in: CGRect(x: x, y: rect.midY - 4.5, width: 9, height: 9))
        }
        for (path, key) in [(enabled, TC.debugIconBreakpointForeground), (disabled, TC.debugIconBreakpointDisabledForeground)] where !path.isEmpty {
            let layer = quiet(CAShapeLayer())
            layer.path = path
            layer.fillColor = ThemeSnapshot.shared.rgba(key).nsColor.cgColor
            dotsLayer.addSublayer(layer)
            marks.layers.append(layer)
        }
    }

    private func placeFolds(on page: PDFPage, index pageIndex: Int, transform toView: CGAffineTransform, pageRect: CGRect,
                            analysis: BookAnalysisModel, controller: ReaderController, into marks: PageMarks) {
        let gutterX = pageRect.minX - bounds.minX >= 24 ? pageRect.minX - 20 : pageRect.minX + 3
        for proof in analysis.proofsByPage[pageIndex] ?? [] {
            let folded = controller.foldedProofs.contains(proof.stableID)
            let parts = proof.regions.filter { $0.pageIndex == pageIndex }
            if folded {
                for (offset, part) in parts.enumerated() {
                    let first = pageIndex == proof.start.pageIndex && offset == 0
                    let bar = ProofFoldBar(proof: proof, first: first) { [weak controller] in controller?.onToggleProof?(proof.stableID) }
                    bar.frame = part.region.rect.applying(toView).insetBy(dx: -2, dy: -1)
                    marks.place(bar, in: self)
                }
            }
            if controller.showFoldControls, pageIndex == proof.start.pageIndex, let first = parts.first {
                let rect = first.region.rect.applying(toView)
                let control = GutterFoldControl(folded: folded, title: proof.statement?.title) { [weak controller] in controller?.onToggleProof?(proof.stableID) }
                control.frame = CGRect(x: gutterX, y: rect.maxY - 15, width: 16, height: 16)
                marks.place(control, in: self)
                marks.foldControlFrames.append(control.frame)
            }
        }
        // Understood statements: a green check beside their label.
        for target in analysis.definitionsByPage[pageIndex] ?? [] where controller.understood.contains(target.key) {
            let anchor = target.anchor.rect.applying(toView)
            let check = NSImageView(image: NSImage(systemSymbolName: "checkmark.seal.fill", accessibilityDescription: "Understood")!)
            check.contentTintColor = .systemGreen
            check.toolTip = "\(target.key.title) · marked as understood"
            check.setAccessibilityLabel("\(target.key.title) understood")
            check.frame = CGRect(x: gutterX, y: anchor.midY - 8, width: 16, height: 16)
            marks.place(check, in: self)
        }
    }

    private func placeUnderlines(index pageIndex: Int, transform toView: CGAffineTransform, references: ReferenceIndex,
                                 controller: ReaderController, into marks: PageMarks) {
        let mentions = controller.isScrubbing ? references.cachedMentions(onPage: pageIndex) : references.mentions(onPage: pageIndex)
        let path = CGMutablePath()
        for mention in mentions where !mention.isDefinition {
            for rect in mention.rects {
                let line = rect.applying(toView)
                path.move(to: CGPoint(x: line.minX, y: line.minY + 0.5))
                path.addLine(to: CGPoint(x: line.maxX, y: line.minY + 0.5))
            }
        }
        guard !path.isEmpty else { return }
        let layer = quiet(CAShapeLayer())
        layer.path = path
        layer.fillColor = nil
        layer.strokeColor = NSColor.lemmaOliveOnPage.withAlphaComponent(0.6).cgColor
        layer.lineWidth = 1
        layer.lineDashPattern = [2, 2]
        underlinesLayer.addSublayer(layer)
        marks.layers.append(layer)
    }

    /// Counts of references beside numbered objects, from the whole-book analysis.
    private func placeLenses(on page: PDFPage, index pageIndex: Int, transform toView: CGAffineTransform, pageRect: CGRect,
                             analysis: BookAnalysisModel, controller: ReaderController, into marks: PageMarks) {
        let notesOnPage = controller.notes.filter { $0.anchor.pageIndex == pageIndex }
        for target in analysis.definitionsByPage[pageIndex] ?? [] where ReferenceLensView.kinds.contains(target.key.kind) {
            let count = analysis.mentionCounts[target.key] ?? 0
            let notes = notesOnPage.filter { $0.anchor.region.rect.intersects(target.region.rect) }.count
            guard count > 0 || notes > 0 else { continue }
            // The count follows the page's type size, so it never outshouts the text it annotates.
            let fontSize = (min(10, max(7, 8.5 * (controller.view?.scaleFactor ?? 1))) * 2).rounded() / 2
            let lens = ReferenceLensView(key: target.key, references: count, notes: notes, fontSize: fontSize) { [weak controller] key in controller?.onShowReferences?(key) }
            let anchor = target.anchor.rect.applying(toView)
            let size = lens.intrinsicContentSize
            var frame: CGRect
            switch target.key.kind {
            case .equation:
                frame = CGRect(x: anchor.maxX + 5, y: anchor.midY - size.height / 2, width: size.width, height: size.height)
                if frame.maxX > pageRect.maxX - 2 { frame.origin = CGPoint(x: anchor.maxX - size.width, y: anchor.minY - size.height) }
            case .theorem, .exercise, .algorithm:
                // In the right margin, level with the label's line: above the label it sat in the gap between lines,
                // over the descenders of the line before.
                let statement = target.region.rect.applying(toView)
                frame = CGRect(x: statement.maxX + 6, y: anchor.midY - size.height / 2, width: size.width, height: size.height)
                if frame.maxX > pageRect.maxX - 2 { frame = CGRect(x: anchor.minX, y: anchor.maxY + 1, width: size.width, height: size.height) }
            default:
                frame = CGRect(x: anchor.minX, y: anchor.maxY + 1, width: size.width, height: size.height)
            }
            lens.frame = frame
            marks.place(lens, in: self)
        }
    }

    // MARK: Margin notes

    /// Notes sit in the margin beside their source: a card when the margin has room, otherwise an icon. Cards are placed
    /// from the top of the visible pages down, each below the ones it would overlap.
    private func placeMarginNotes(_ visible: [(PDFPage, Int)], in view: RegionPDFView, controller: ReaderController, document: PDFDocument) {
        var placedNotes: Set<UUID> = []
        defer {
            for (id, entry) in noteViews where !placedNotes.contains(id) { entry.view.removeFromSuperview(); noteViews[id] = nil }
        }
        guard controller.showAnnotations else { return }
        var transforms: [Int: (CGAffineTransform, CGRect)] = [:]
        for (page, index) in visible {
            let toView = transform(for: page, in: view)
            transforms[index] = (toView, page.bounds(for: .cropBox).applying(toView))
        }
        var occupied = visible.flatMap { pages[$0.1]?.foldControlFrames ?? [] }
        let placed = controller.notes.compactMap { note -> (StudyNote, CGRect, CGRect)? in
            guard let (toView, pageRect) = transforms[note.anchor.pageIndex] else { return nil }
            return (note, note.anchor.region.rect.applying(toView), pageRect)
        }.sorted { $0.1.maxY > $1.1.maxY }
        for (note, rect, pageRect) in placed {
            let selected = note.id == controller.selectedNoteID
            let gutter = bounds.maxX - pageRect.maxX - 18
            let child: NSView
            var frame: CGRect
            if gutter >= 150 {
                let card = reusableView(for: note, card: true, selected: selected) {
                    NoteCardView(note: note, selected: selected, figure: note.figureName.flatMap { controller.figureImage?($0) }) { [weak controller] in
                        if note.kind == .comment { controller?.onEditMarginNote?(note.id) } else { controller?.onSelectNote?(note.id) }
                    }
                } as! NoteCardView
                let width = min(note.figureName == nil ? 250 : 300, gutter - 4)
                let height = card.height(for: width)
                frame = CGRect(x: pageRect.maxX + 12, y: rect.maxY - height, width: width, height: height)
                while let blocking = occupied.first(where: { $0.insetBy(dx: 0, dy: -3).intersects(frame) }) { frame.origin.y = blocking.minY - 6 - height }
                child = card
            } else {
                child = reusableView(for: note, card: false, selected: selected) {
                    let marker = NoteMarkerButton(image: NSImage(systemSymbolName: note.kind.symbol, accessibilityDescription: nil)!, target: self, action: #selector(openNote(_:)))
                    marker.noteID = note.id
                    marker.bezelStyle = .inline; marker.isBordered = false
                    marker.contentTintColor = note.kind == .comment ? MarginNoteStyle.edgeColor : note.state == .understood ? .systemGreen : .controlAccentColor
                    marker.wantsLayer = true; marker.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor; marker.layer?.cornerRadius = 6
                    marker.toolTip = note.title
                    marker.setAccessibilityLabel("Open note: \(note.title)")
                    return marker
                }
                frame = CGRect(x: min(bounds.maxX - 28, pageRect.maxX + 6), y: rect.midY - 13, width: 26, height: 26)
                while occupied.contains(where: { $0.intersects(frame) }) { frame.origin.y -= 28 }
            }
            if child.frame != frame { child.frame = frame }
            if child.superview !== self { addSubview(child) }
            occupied.append(frame)
            placedNotes.insert(note.id)
        }
    }

    /// Margin views are reused while scrolling; only their frames change unless the note changes.
    private func reusableView(for note: StudyNote, card: Bool, selected: Bool, make: () -> NSView) -> NSView {
        let signature = "\(card)|\(selected)|\(note.kind.rawValue)|\(note.state.rawValue)|\(note.title)|\(note.figureName ?? "")|\(card ? (note.kind == .comment ? note.body : NoteCardView.snippet(for: note)) : "")"
        if let existing = noteViews[note.id], existing.signature == signature { return existing.view }
        noteViews[note.id]?.view.removeFromSuperview()
        let view = make()
        noteViews[note.id] = (signature, view)
        return view
    }

    @objc private func openNote(_ sender: NoteMarkerButton) {
        if controller?.notes.first(where: { $0.id == sender.noteID })?.kind == .comment { controller?.onEditMarginNote?(sender.noteID) }
        else { controller?.onSelectNote?(sender.noteID) }
    }

    // MARK: Transient marks

    private var hoverInputs: (pageIndex: Int, mention: PageMention)??
    private var flashInputs: (pageIndex: Int, rect: CGRect)??
    private var rulerInputs: (line: ReaderController.RulerLine?, debugging: Bool, pages: [Int])?

    private func updateTransientMarks(in view: RegionPDFView, controller: ReaderController, document: PDFDocument) {
        func visiblePage(_ index: Int) -> PDFPage? {
            guard visibleIndexes.contains(index) else { return nil }
            return document.page(at: index)
        }
        // The reference under the pointer: tinted, with a solid underline.
        let hovered = view.hoveredReference.flatMap { hit -> (pageIndex: Int, mention: PageMention)? in
            controller.showAnnotations && controller.showReferenceLinks && !controller.regionMode && !controller.inkMode ? (hit.pageIndex, hit.mention) : nil
        }
        if hoverInputs.map({ $0?.pageIndex != hovered?.pageIndex || $0?.mention != hovered?.mention }) ?? true {
            hoverInputs = .some(hovered)
            let fill = CGMutablePath(), line = CGMutablePath()
            if let hovered, let page = visiblePage(hovered.pageIndex) {
                let toView = transform(for: page, in: view)
                for rect in hovered.mention.rects {
                    let r = rect.applying(toView)
                    fill.addRoundedRect(in: r.insetBy(dx: -1.5, dy: -1), cornerWidth: 2.5, cornerHeight: 2.5)
                    line.move(to: CGPoint(x: r.minX, y: r.minY + 0.5)); line.addLine(to: CGPoint(x: r.maxX, y: r.minY + 0.5))
                }
            }
            hoverFill.path = fill.isEmpty ? nil : fill
            hoverLine.path = line.isEmpty ? nil : line
        }
        // The outline after navigating to a reference.
        let flash = controller.flash
        if flashInputs.map({ $0?.pageIndex != flash?.pageIndex || $0?.rect != flash?.rect }) ?? true {
            flashInputs = .some(flash)
            if let flash, let page = visiblePage(flash.pageIndex) {
                flashLayer.path = CGPath(roundedRect: flash.rect.applying(transform(for: page, in: view)), cornerWidth: 4, cornerHeight: 4, transform: nil)
            } else { flashLayer.path = nil }
        }
        updateRuler(in: view, controller: controller, document: document)
        // The selected note's source.
        let selectedPath = CGMutablePath()
        if let id = controller.selectedNoteID, let note = controller.notes.first(where: { $0.id == id }), controller.showAnnotations,
           let page = visiblePage(note.anchor.pageIndex) {
            selectedPath.addRect(note.anchor.region.rect.applying(transform(for: page, in: view)))
        }
        selectedNote.path = selectedPath.isEmpty ? nil : selectedPath
        updateRegion(in: view, controller: controller, document: document)
        updateRecallMasks(in: view, controller: controller, document: document)
    }

    /// The reading ruler: the rest of the visible pages behind a veil, the line in a band, a bar at its start. While a
    /// proof is debugged the line is in the stack frame's colour, with an arrow in the gutter, and nothing is dimmed.
    private func updateRuler(in view: RegionPDFView, controller: ReaderController, document: PDFDocument) {
        let inputs = (line: controller.rulerLine, debugging: controller.debugging, pages: visibleIndexes)
        if let previous = rulerInputs, previous.line == inputs.line, previous.debugging == inputs.debugging, previous.pages == inputs.pages { return }
        rulerInputs = inputs
        veil.path = nil; band.path = nil; bar.path = nil; arrow.isHidden = true
        guard let line = inputs.line, visibleIndexes.contains(line.pageIndex), let page = document.page(at: line.pageIndex) else { return }
        let toView = transform(for: page, in: view)
        let rulerRect = line.rect.applying(toView)
        if inputs.debugging {
            let highlight = ThemeSnapshot.shared.rgba(.editorStackFrameHighlightBackground)
            band.fillColor = NSColor(srgbRed: highlight.r, green: highlight.g, blue: highlight.b, alpha: max(highlight.a, PageThemeState.shared.theme.isDark ? 0.22 : 0.32)).cgColor
            band.path = CGPath(rect: rulerRect.insetBy(dx: -6, dy: -2), transform: nil)
            let pageRect = page.bounds(for: .cropBox).applying(toView)
            let x = pageRect.minX - bounds.minX >= 52 ? pageRect.minX - 50 : pageRect.minX + 2
            let rect = CGRect(x: x, y: rulerRect.insetBy(dx: -6, dy: -2).midY - 7, width: 14, height: 14)
            arrow.contents = Self.stackFrameArrow(scale: window?.backingScaleFactor ?? 2)
            arrow.contentsScale = window?.backingScaleFactor ?? 2
            arrow.frame = rect
            arrow.isHidden = false
        } else {
            let rect = rulerRect.insetBy(dx: -6, dy: -2.5)
            let dim = CGMutablePath()
            for index in visibleIndexes {
                if let visible = document.page(at: index) { dim.addRect(visible.bounds(for: .cropBox).applying(transform(for: visible, in: view))) }
            }
            dim.addRect(rect)
            veil.path = dim
            veil.fillColor = NSColor.lemmaPageVeil.cgColor
            band.path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
            band.fillColor = NSColor.lemmaOliveOnPage.withAlphaComponent(0.07).cgColor
            bar.path = CGPath(roundedRect: CGRect(x: rect.minX - 6, y: rect.minY + 1, width: 3, height: rect.height - 2), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
            bar.fillColor = NSColor.lemmaOliveOnPage.withAlphaComponent(0.85).cgColor
        }
    }

    /// The debugger's arrow: the codicon when its font is available, else a triangle.
    private static func stackFrameArrow(scale: CGFloat) -> NSImage {
        let colour = ThemeSnapshot.shared.rgba(.debugIconBreakpointCurrentStackframeForeground).nsColor
        return NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            if let glyph = Codicons.glyph("debug-stackframe"), let font = Codicons.nsFont(14) {
                (glyph as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: colour])
            } else {
                let path = NSBezierPath()
                path.move(to: CGPoint(x: rect.minX, y: rect.minY + 2)); path.line(to: CGPoint(x: rect.maxX, y: rect.midY)); path.line(to: CGPoint(x: rect.minX, y: rect.maxY - 2)); path.close()
                colour.setFill(); path.fill()
            }
            return true
        }
    }

    /// The capture outline: while dragging in region mode, then the captured region on its page (any visible page).
    private func updateRegion(in view: RegionPDFView, controller: ReaderController, document: PDFDocument) {
        var outline: CGRect?
        if controller.regionMode {
            if let drag = view.dragRectangle { outline = drag }
            else if let (index, rect, _) = controller.selection, visibleIndexes.contains(index), let page = document.page(at: index) {
                outline = view.convert(rect, from: page)
            }
        }
        rectangle = outline
        region.path = outline.map { CGPath(rect: $0.offsetBy(dx: bounds.minX, dy: bounds.minY), transform: nil) }
    }

    /// Recall masks hide the answer on the page: the cloze parts, or the whole source.
    private func updateRecallMasks(in view: RegionPDFView, controller: ReaderController, document: PDFDocument) {
        var rects: [CGRect] = []
        if let anchor = controller.recallMask, visibleIndexes.contains(anchor.pageIndex), let page = document.page(at: anchor.pageIndex) {
            let regions = controller.recallMaskRegions.isEmpty ? [anchor.region] : controller.recallMaskRegions
            rects = regions.map { view.convert($0.rect, from: page) }
        }
        recallRectangles = rects
        while recallViews.count > rects.count { recallViews.removeLast().removeFromSuperview() }
        while recallViews.count < rects.count {
            let mask = RecallMaskView()
            addSubview(mask, positioned: .above, relativeTo: shapes)
            recallViews.append(mask)
        }
        for (mask, rect) in zip(recallViews, rects) {
            // The border is stroked on the rectangle's edge, half outside it.
            let frame = rect.offsetBy(dx: bounds.minX, dy: bounds.minY).insetBy(dx: -0.5, dy: -0.5)
            if mask.frame != frame { mask.frame = frame }
        }
    }

    // MARK: Ink

    /// The stroke being drawn, extended point by point on a shape layer (the page is not redrawn for it).
    func updateStroke(_ stroke: InkStroke?, in view: RegionPDFView) {
        guard let stroke, let first = stroke.points.first, let page = view.document?.page(at: stroke.pageIndex) else {
            strokeLayer.path = nil; self.stroke = nil; return
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        _ = followScroll(in: view)
        let toView = transform(for: page, in: view)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: first.x, y: first.y).applying(toView))
        for point in stroke.points.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y).applying(toView)) }
        strokeLayer.path = path
        strokeLayer.lineWidth = stroke.width * view.scaleFactor
        strokeLayer.strokeColor = stroke.color.nativeColor.cgColor
        self.stroke = (stroke.pageIndex, stroke.points.count)
    }

    // MARK: Line numbers

    /// The line whose number is under a point (in the PDF view's coordinates), for clicks.
    func lineNumberHit(at point: CGPoint) -> (pageIndex: Int, index: Int)? {
        let local = CGPoint(x: point.x + bounds.minX, y: point.y + bounds.minY)
        for (pageIndex, marks) in pages {
            if let hit = marks.lineHits.first(where: { $0.rect.insetBy(dx: -3, dy: -1).contains(local) }) { return (pageIndex, hit.index) }
        }
        return nil
    }

    /// The current line's number is drawn darker; only the two numbers that change are redrawn.
    func updateFocusLine() {
        guard let controller else { return }
        let line = controller.focusLine
        for (pageIndex, marks) in pages {
            let current = pageIndex == controller.focusPageIndex ? line : nil
            for gutter in marks.gutters where gutter.current != current { gutter.current = current }
        }
    }
}

/// One page's marks: the views and layers built for it, removed together when the page leaves the view or changes.
@MainActor
private final class PageMarks {
    let index: Int
    var pageRect: CGRect = .null
    var gutters: [GutterView] = []
    var layers: [CALayer] = []
    var views: [NSView] = []
    var lineHits: [(rect: CGRect, index: Int)] = []
    var foldControlFrames: [CGRect] = []

    init(index: Int) { self.index = index }

    func place(_ view: NSView, in overlay: NSView) {
        overlay.addSubview(view)
        views.append(view)
    }

    func remove() {
        gutters.forEach { $0.removeFromSuperview() }
        layers.forEach { $0.removeFromSuperlayer() }
        views.forEach { $0.removeFromSuperview() }
        gutters = []; layers = []; views = []
    }
}

/// A view drawn into a layer of its own, whole, when asked. AppKit draws a layer-backed view only where it shows, so a
/// tall mark (a page's line numbers, a folded proof) moving into view as the page scrolls would be drawn again, strip
/// by strip, on every frame; this one is drawn once and then only moved.
@MainActor
class WholeLayerView: NSView {
    private final class ContentLayer: CALayer {
        nonisolated(unsafe) weak var owner: WholeLayerView?
        override func draw(in context: CGContext) {
            // Core Animation displays these layers on the main thread, in its transaction.
            let flipped = contentsAreFlipped(), height = bounds.height
            nonisolated(unsafe) let context = context
            nonisolated(unsafe) let owner = owner
            MainActor.assumeIsolated {
                guard let owner else { return }
                if flipped != owner.isFlipped { context.translateBy(x: 0, y: height); context.scaleBy(x: 1, y: -1) }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: owner.isFlipped)
                owner.effectiveAppearance.performAsCurrentDrawingAppearance { owner.drawContents(in: context.boundingBoxOfClipPath) }
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    private let content = ContentLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        content.owner = self
        content.needsDisplayOnBoundsChange = true
        content.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        layer = content
        wantsLayer = true
        content.setNeedsDisplay()
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scale = window?.backingScaleFactor, scale != content.contentsScale { content.contentsScale = scale; content.setNeedsDisplay() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        content.contentsScale = window?.backingScaleFactor ?? 2
        content.setNeedsDisplay()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        content.setNeedsDisplay()
    }

    /// Draws the view's content in its own coordinates; `dirtyRect` is the part being drawn.
    func drawContents(in dirtyRect: CGRect) {}

    /// Draws everything again, or one part (in the view's coordinates).
    func redraw(_ rect: CGRect? = nil) {
        guard let rect else { content.setNeedsDisplay(); return }
        content.setNeedsDisplay(content.contentsAreFlipped() == isFlipped ? rect : CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height))
    }
}

/// Line numbers and change bars of one side of a page. Drawn once; when the current line changes only its number and
/// the previous one are redrawn.
@MainActor
private final class GutterView: WholeLayerView {
    struct Item { var number: CGRect; var text: String; var bar: CGRect?; var barColor: NSColor?; var index: Int }
    private let items: [Item]
    private let font: NSFont
    private let dim: NSColor
    var current: Int? {
        didSet {
            guard current != oldValue else { return }
            for item in items where item.index == oldValue || item.index == current { redraw(item.number.insetBy(dx: -1, dy: -1)) }
        }
    }

    init(items: [Item], font: NSFont, dim: NSColor) {
        let union = items.reduce(CGRect.null) { result, item in result.union(item.number).union(item.bar ?? .null) }.insetBy(dx: -1, dy: -1)
        self.items = items.map { item in
            var local = item
            local.number = item.number.offsetBy(dx: -union.minX, dy: -union.minY)
            local.bar = item.bar?.offsetBy(dx: -union.minX, dy: -union.minY)
            return local
        }
        self.font = font; self.dim = dim
        super.init(frame: union)
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func drawContents(in dirtyRect: CGRect) {
        QAPerf.tick("Overlay.gutterDraw")
        for item in items {
            if item.number.intersects(dirtyRect) {
                (item.text as NSString).draw(in: item.number, withAttributes: [.font: font, .foregroundColor: item.index == current ? NSColor.labelColor : dim])
            }
            if let bar = item.bar, let color = item.barColor, bar.intersects(dirtyRect) {
                color.setFill()
                NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
            }
        }
    }
}

/// A recall mask: the answer covered by the page's background colour.
@MainActor
private final class RecallMaskView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { false }
    override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        if resized { needsDisplay = true }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        NSColor.controlBackgroundColor.setFill(); NSBezierPath(rect: rect).fill()
        NSColor.secondaryLabelColor.withAlphaComponent(0.35).setStroke()
        let border = NSBezierPath(rect: rect); border.lineWidth = 1; border.stroke()
        if rect.width > 120 && rect.height > 30 {
            let text = "Hidden for recall" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
        }
    }
}

/// Hosts the shape layers (its layer tree is Lemma's own, so AppKit does not reorder it). It never takes clicks.
@MainActor
private final class ShapeHost: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let root = quiet(CALayer())
        root.masksToBounds = false
        layer = root
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor private final class NoteMarkerButton: NSButton { var noteID = UUID() }

/// A layer whose changes apply at once: marks follow the page, they do not fade or slide into place.
private func quiet<Layer: CALayer>(_ layer: Layer) -> Layer {
    layer.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "path": NSNull(), "hidden": NSNull(),
                     "contents": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull(), "opacity": NSNull(),
                     "sublayers": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull()]
    return layer
}
