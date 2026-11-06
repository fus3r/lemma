import AppKit
import PDFKit
import SwiftUI
import LemmaCore

@MainActor @Observable
final class ReaderController {
    weak var view: RegionPDFView?
    var regionMode = false { didSet { if regionMode { inkMode = false }; view?.cancelInkGesture() } }
    var inkMode = false { didSet {
        if inkMode { regionMode = false; showAnnotations = true } else { activeShapeID = nil }
        view?.cancelInkGesture()
    } }
    var drawingTool: DrawingTool = .pen { didSet { view?.cancelInkGesture(); activeShapeID = nil } }
    var inkEraser: Bool {
        get { drawingTool == .eraser }
        set { drawingTool = newValue ? .eraser : .pen }
    }
    var inkColor: InkColor = .graphite
    var inkWidth: Double = 1.5
    var shapeColorHex = "#2359B0"
    var shapeFillOpacity: Double = 0
    var shapeDashed = false
    var activeShapeID: UUID?
    var shapes: [PageShape] = []
    var appliedShapes: [PageShape] = []
    var shapeAnnotations: [UUID: PDFAnnotation] = [:]
    weak var shapeDocument: PDFDocument?
    var onInk: ((InkStroke) -> Void)?
    var onEraseInk: ((UUID) -> Void)?
    var inkStrokes: [InkStroke] = []
    private var appliedInk: [InkStroke] = []
    private var inkAnnotations: [UUID: PDFAnnotation] = [:]
    private weak var inkDocument: PDFDocument?
    var pageNumber = 1
    var pageCount = 0
    var hasSelection = false
    var selection: (Int, CGRect, String)?
    /// The mark most recently clicked, for the Highlight menu's remove and recolor actions.
    var activeHighlightID: UUID?
    var onReadingChanged: ((Int, Double) -> Void)?
    /// The page layout PDFKit switched to from its own context menu (Single Page… Two Pages Continuous).
    var onLayoutChanged: ((ReadingLayout) -> Void)?
    var searchText = ""
    var searchResults: [PDFSelection] = []
    var searchIndex = 0
    var hasSearched = false
    var isSearching = false
    /// Case sensitivity of `find()`; the find widget's Match Case sets it.
    var findOptions: NSString.CompareOptions = .caseInsensitive
    /// When set, a finished `find()` goes to the first match on or after this page (the find widget searches from
    /// where the reader is, as an editor searches from the cursor) instead of the book's first match.
    var findStartPage: Int?
    @ObservationIgnored private var searchObservers: [NSObjectProtocol] = []
    @ObservationIgnored private weak var searchDocument: PDFDocument?
    var canGoBack = false
    var canGoForward = false
    var scale: Double = 1
    /// The page and height (PDF space) a third of the way down the view: where the reader is looking.
    /// Breadcrumbs and the current section follow it.
    var focusPageIndex = 0
    /// The exact height changes on every frame of a scroll; observers are told only when the line under it changes
    /// (`focusBand`), so a view that reads `focusY` or `focusLine` is redrawn once per line, not once per frame.
    var focusY: CGFloat? {
        get { _ = focusBand; return exactFocusY }
        set { setFocus(y: newValue); publishFocus() }
    }
    /// The line of the focus page under the reading position (the status bar's “Ln”), when the page has text lines.
    var focusLine: Int? { _ = focusBand; return exactFocusLine }
    /// Changes whenever the page or the line under the reading position changes (every 24 points on a page without lines),
    /// at most every 100 ms while the page scrolls (the last change always arrives).
    private(set) var focusBand = 0
    @ObservationIgnored private var exactFocusY: CGFloat?
    @ObservationIgnored private var exactFocusLine: Int?
    @ObservationIgnored private var currentBand = 0
    /// Paces what the reading position publishes to SwiftUI, the line and the store's outline path and statement together:
    /// a fast scroll crosses several lines and statements per frame, and each SwiftUI update of this window costs
    /// several milliseconds, more than redrawing the breadcrumbs, sticky header and status bar for every one would show.
    @ObservationIgnored private let focusPacer = Pacer(interval: 0.1)
    /// The outline path and the statement at the reading position, published only when they change: the breadcrumbs,
    /// the outline, the sticky header and the page inspector follow these instead of every scroll step.
    var focusPath: [OutlineEntry] = []
    /// The statement being read; its `headVisible` is always false here, since the label's visibility changes far more
    /// often than the statement and only the sticky header needs it (`focusLabelVisible`).
    var focusStatement: ReadingStatement?
    var focusLabelVisible = false
    /// Set while the store watches the outline and analysis for changes that move `focusPath` and `focusStatement`.
    @ObservationIgnored var watchesFocusInputs = false
    /// The focus page once the reader stays on it a moment: views that describe the whole page (the page inspector) follow
    /// it rather than every page a fast scroll passes.
    private(set) var settledPageIndex = 0
    @ObservationIgnored private var settling: Task<Void, Never>?
    /// The pages currently on screen, for the overview ruler.
    var visiblePageRange: ClosedRange<Int>?
    /// Minimap dragging visits many transient pages. Cold text geometry waits for the final destination.
    private(set) var isScrubbing = false

    func beginScrubbing() {
        isScrubbing = true
        references?.cancelPrefetch()
        view?.hoverPreview.dismiss()
        view?.symbolHover.dismiss()
    }

    func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        updatePage()
        view?.refreshCaptureOverlay()
        if showReferenceLinks { references?.prefetch(around: pageNumber - 1) }
    }
    // Viewing the original ends drawing so the eraser cannot remove hidden handwriting.
    var showAnnotations = true { didSet { if !showAnnotations { inkMode = false } } }
    var recallMask: SourceAnchor? { didSet { view?.updateOverlay() } }
    /// Cloze parts of the recall source; when empty the whole source region is hidden.
    var recallMaskRegions: [PageRegion] = [] { didSet { view?.updateOverlay() } }
    var onSelectNote: ((UUID) -> Void)?
    var onLookup: ((Int, CGRect, String) -> Void)?
    /// A click on a reference: its mention, its page, and whether it was a Shift-click, which opens the peek beside
    /// those already open and keeps them all open.
    var onReference: ((PageMention, Int, Bool) -> Void)?
    /// ⌥-click on a reference: opens it in the side editor instead of peeking at it.
    var onReferenceToSide: ((PageMention, Int) -> Void)?
    /// Starts a margin note beside a line (double-click in the margin, or the context menu).
    var onMarginNote: ((Int, CGRect, String) -> Void)?
    /// Opens a margin note's editor from its card.
    var onEditMarginNote: ((UUID) -> Void)?
    /// Opens the References panel for an object whose count was clicked on the page.
    var onShowReferences: ((ReferenceKey) -> Void)?
    /// Loads a note's margin figure by asset name.
    @ObservationIgnored var figureImage: ((String) -> NSImage?)?
    /// Reference counts beside equations and figures, like an editor's code lens.
    var showReferenceCounts = true { didSet { view?.refreshCaptureOverlay() } }
    var onContextAction: ((ReaderContextAction) -> Void)?
    @ObservationIgnored var references: ReferenceIndex?
    /// The store that owns this reader, for previews presented from the PDF view.
    @ObservationIgnored weak var owner: StudyStore?
    var showReferenceLinks = true { didSet { view?.refreshCaptureOverlay() } }
    /// A briefly outlined region after navigating to a reference.
    var flash: (pageIndex: Int, rect: CGRect)? { didSet { view?.updateOverlay() } }
    /// Proofs folded away on the page, by stable ID (“page:offset”), as an editor folds a function body.
    var foldedProofs: Set<String> = [] { didSet { if foldedProofs != oldValue { view?.refreshCaptureOverlay(); view?.scheduleOverlayRefresh() } } }
    /// Statements the reader marked as understood: a green check in the page's gutter.
    var understood: Set<ReferenceKey> = [] { didSet { if understood != oldValue { view?.refreshCaptureOverlay() } } }
    /// Fold controls in the gutter beside each proof.
    var showFoldControls = true { didSet { view?.refreshCaptureOverlay() } }
    /// Line numbers in the page's gutter, with change bars where the reader has marked, noted or drawn, as an editor's gutter.
    var showLineNumbers = UserDefaults.standard.object(forKey: LemmaPreferences.lineNumbers) as? Bool ?? true {
        didSet { UserDefaults.standard.set(showLineNumbers, forKey: LemmaPreferences.lineNumbers); view?.refreshCaptureOverlay() }
    }

    /// The line of a page at a height (PDF space), as the status bar's “line 12”.
    func lineIndex(onPage pageIndex: Int, y: CGFloat) -> (index: Int, count: Int)? {
        let lines = readingLines(onPage: pageIndex)
        guard !lines.isEmpty else { return nil }
        let index = lines.firstIndex { $0.maxY <= y + 2 } ?? lines.count - 1
        return (index, lines.count)
    }

    /// Selects one line of a page, as clicking a line number does in an editor.
    func selectLine(_ index: Int, onPage pageIndex: Int) {
        let lines = readingLines(onPage: pageIndex)
        guard lines.indices.contains(index), let page = view?.document?.page(at: pageIndex),
              let selection = page.selection(for: lines[index].insetBy(dx: -1, dy: 1)) else { return }
        view?.setCurrentSelection(selection, animate: false)
        updateSelection()
    }

    /// Goes to a line of a page and puts the ruler there when it is on.
    func goToLine(_ index: Int, onPage pageIndex: Int) {
        let lines = readingLines(onPage: pageIndex)
        guard let view, let page = view.document?.page(at: pageIndex), lines.indices.contains(index) else { return }
        let line = lines[index]
        view.go(to: PDFDestination(page: page, at: CGPoint(x: line.minX, y: min(line.maxY + 120, page.bounds(for: .cropBox).maxY))))
        if rulerMode { rulerLine = RulerLine(pageIndex: pageIndex, rect: line, index: index, count: lines.count) }
        else { flash(line.insetBy(dx: -3, dy: -2), onPage: pageIndex) }
    }
    /// Breakpoints drawn in the gutter, and whether a proof is being debugged (the ruler's line is then the current line).
    var breakpoints: [LineBreakpoint] = [] { didSet { if breakpoints != oldValue { view?.refreshCaptureOverlay() } } }
    var debugging = false { didSet { if debugging != oldValue { view?.refreshCaptureOverlay() } } }
    var onToggleProof: ((String) -> Void)?
    var onSelectStatement: ((ReferenceKey) -> Void)?

    // MARK: Reading ruler

    /// One line of the page highlighted and the rest dimmed, moved line by line with the arrow keys or J and K:
    /// a proof read one step at a time, as a debugger steps through code.
    var rulerMode = false {
        didSet {
            guard rulerMode != oldValue else { return }
            if rulerMode {
                regionMode = false; inkMode = false; placeRulerAtFocus()
                // The arrow keys step the ruler only while the page has the keyboard.
                if let view { view.window?.makeFirstResponder(view) }
            } else { rulerLine = nil }
            view?.updateOverlay()
        }
    }
    struct RulerLine: Equatable { var pageIndex: Int; var rect: CGRect; var index: Int; var count: Int }
    var rulerLine: RulerLine? { didSet { if rulerLine != oldValue { view?.updateOverlay() } } }
    @ObservationIgnored private var lineCache: [Int: [CGRect]] = [:]
    @ObservationIgnored private weak var lineDocument: PDFDocument?

    /// The page's lines in reading order (cached per page).
    func readingLines(onPage pageIndex: Int) -> [CGRect] {
        guard let document = view?.document else { return [] }
        if lineDocument !== document { lineCache = [:]; lineDocument = document }
        if let cached = lineCache[pageIndex] { return cached }
        guard !isScrubbing else { return [] }
        guard let page = document.page(at: pageIndex) else { return [] }
        let lines = ReferenceLayout.readingLines(PageReferenceAnalyzer.columnFragments(on: page), page: page.bounds(for: .cropBox))
        lineCache[pageIndex] = lines
        return lines
    }

    /// Puts the ruler on the first line at or below where the reader is looking.
    func placeRulerAtFocus() {
        let pageIndex = focusPageIndex
        let lines = readingLines(onPage: pageIndex)
        guard !lines.isEmpty else { rulerLine = nil; return }
        let y = focusY ?? lines[0].maxY
        let index = lines.firstIndex { $0.maxY <= y + 2 } ?? 0
        rulerLine = RulerLine(pageIndex: pageIndex, rect: lines[index], index: index, count: lines.count)
    }

    /// Puts the ruler on the line under a point of a page.
    func placeRuler(at point: CGPoint, pageIndex: Int) {
        let lines = readingLines(onPage: pageIndex)
        guard let index = lines.indices.min(by: { distance(lines[$0], point) < distance(lines[$1], point) }) else { return }
        rulerLine = RulerLine(pageIndex: pageIndex, rect: lines[index], index: index, count: lines.count)
    }

    private func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let dy = point.y < rect.minY ? rect.minY - point.y : point.y > rect.maxY ? point.y - rect.maxY : 0
        let dx = point.x < rect.minX ? rect.minX - point.x : point.x > rect.maxX ? point.x - rect.maxX : 0
        return dy * 3 + dx
    }

    /// Moves the ruler by whole lines, across pages, keeping the line in view.
    func moveRuler(by step: Int) {
        guard let document = view?.document else { return }
        if rulerLine == nil { placeRulerAtFocus() }
        guard var line = rulerLine else { return }
        var pageIndex = line.pageIndex, index = line.index + step
        var lines = readingLines(onPage: pageIndex)
        while index >= lines.count || index < 0 {
            if index >= lines.count {
                guard pageIndex + 1 < document.pageCount else { index = lines.count - 1; break }
                index -= lines.count; pageIndex += 1; lines = readingLines(onPage: pageIndex)
                if lines.isEmpty { index = 0; continue }
            } else {
                guard pageIndex > 0 else { index = 0; break }
                pageIndex -= 1; lines = readingLines(onPage: pageIndex); index += lines.count
            }
        }
        guard lines.indices.contains(index) else { return }
        line = RulerLine(pageIndex: pageIndex, rect: lines[index], index: index, count: lines.count)
        rulerLine = line
        revealRuler()
    }

    /// Scrolls just enough to keep the ruler a little above the middle of the view.
    func revealRuler() {
        guard let view, let line = rulerLine, let page = view.document?.page(at: line.pageIndex) else { return }
        let rect = view.convert(line.rect, from: page)
        let visible = view.bounds.insetBy(dx: 0, dy: view.bounds.height * 0.18)
        guard !visible.contains(CGPoint(x: rect.midX, y: rect.midY)) else { return }
        let target = CGRect(x: line.rect.minX, y: line.rect.minY - 160, width: line.rect.width, height: line.rect.height + 320)
            .intersection(page.bounds(for: .cropBox))
        view.go(to: target.isNull ? line.rect : target, on: page)
    }
    @ObservationIgnored var notes: [StudyNote] = []
    @ObservationIgnored var selectedNoteID: UUID?
    private var appliedHighlights: [StudyHighlight] = []
    private var highlightAnnotations: [UUID: [PDFAnnotation]] = [:]
    private weak var annotatedDocument: PDFDocument?
    @ObservationIgnored private weak var highlightGeometryDocument: PDFDocument?
    @ObservationIgnored private var highlightGeometry: [Int: HighlightGeometry] = [:]
    @ObservationIgnored private var highlightFonts = InkFontCache()
    @ObservationIgnored private var marking: Task<Void, Never>?

    func previousPage() { view?.goToPreviousPage(nil) }
    func nextPage() { view?.goToNextPage(nil) }
    func back() { view?.goBack(nil) }
    func forward() { view?.goForward(nil) }
    func zoomIn() { view?.zoomIn(nil) }
    func zoomOut() { view?.zoomOut(nil) }
    func fit() { view?.autoScales = true }
    func fitWidth() {
        guard let view, let page = view.currentPage else { return }
        view.autoScales = false
        view.scaleFactor = max(view.minScaleFactor, min(view.maxScaleFactor, (view.bounds.width - 32) / max(page.displayedSize.width, 1)))
    }
    func cancelSearch() {
        for observer in searchObservers { NotificationCenter.default.removeObserver(observer) }
        searchObservers = []
        searchDocument?.cancelFindString(); searchDocument = nil; isSearching = false
        marking?.cancel(); marking = nil
    }
    /// Shows matches found elsewhere (the Search view's, from the book's page texts) as this book's find results
    /// without moving the page. Selections are built a few pages at a time, so the reader stays responsive.
    func showMatches(_ matches: [(pageIndex: Int, range: NSRange)], for query: String) {
        cancelSearch(); searchResults = []; searchIndex = 0
        searchText = query
        hasSearched = !query.isEmpty
        guard let document = view?.document, !matches.isEmpty else { return }
        isSearching = true
        marking = Task { @MainActor [weak self] in
            var pending: [PDFSelection] = [], flushed = Date.now
            var turn = Date.now
            for match in matches {
                guard !Task.isCancelled, let self, self.view?.document === document else { return }
                if let selection = document.page(at: match.pageIndex)?.selection(for: match.range) { pending.append(selection) }
                if Date.now.timeIntervalSince(flushed) > 0.25 { self.searchResults.append(contentsOf: pending); pending = []; flushed = .now }
                if Date.now.timeIntervalSince(turn) > 0.012 {
                    try? await Task.sleep(for: .milliseconds(4))
                    turn = .now
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.searchResults.append(contentsOf: pending)
            self.isSearching = false; self.marking = nil
        }
    }
    func resetSearch() { cancelSearch(); searchText = ""; searchResults = []; searchIndex = 0; hasSearched = false }
    func find() {
        let startPage = findStartPage
        findStartPage = nil
        cancelSearch(); searchResults = []; searchIndex = 0
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        hasSearched = !query.isEmpty
        guard let document = view?.document, hasSearched else { return }
        searchDocument = document; isSearching = true
        searchObservers.append(NotificationCenter.default.addObserver(forName: .PDFDocumentDidFindMatch, object: document, queue: .main) { [weak self] notification in
            guard let document = notification.object as? PDFDocument,
                  let selection = notification.userInfo?[PDFDocumentFoundSelectionKey] as? PDFSelection else { return }
            let documentID = ObjectIdentifier(document)
            // This observer runs on the main queue; PDFKit selections stay on that queue.
            nonisolated(unsafe) let match = selection
            MainActor.assumeIsolated {
                guard let self, let document = self.searchDocument, ObjectIdentifier(document) == documentID else { return }
                self.searchResults.append(match)
            }
        })
        searchObservers.append(NotificationCenter.default.addObserver(forName: .PDFDocumentDidEndFind, object: document, queue: .main) { [weak self] notification in
            guard let document = notification.object as? PDFDocument else { return }
            let documentID = ObjectIdentifier(document)
            MainActor.assumeIsolated {
                guard let self, let document = self.searchDocument, ObjectIdentifier(document) == documentID else { return }
                for observer in self.searchObservers { NotificationCenter.default.removeObserver(observer) }
                self.searchObservers = []; self.searchDocument = nil; self.isSearching = false
                if !self.searchResults.isEmpty {
                    let start = startPage.flatMap { page in
                        self.searchResults.firstIndex { selection in selection.pages.first.map { document.index(for: $0) >= page } ?? false }
                    }
                    self.goToMatch(start ?? 0)
                }
            }
        })
        document.beginFindString(query, withOptions: findOptions)
    }
    func nextMatch() {
        guard !searchResults.isEmpty else { return }
        searchIndex = (searchIndex + 1) % searchResults.count
        view?.setCurrentSelection(searchResults[searchIndex], animate: true)
        view?.go(to: searchResults[searchIndex])
    }
    func previousMatch() {
        guard !searchResults.isEmpty else { return }
        searchIndex = (searchIndex - 1 + searchResults.count) % searchResults.count
        goToMatch(searchIndex)
    }
    func goToMatch(_ index: Int) {
        guard searchResults.indices.contains(index) else { return }
        searchIndex = index
        view?.setCurrentSelection(searchResults[index], animate: true)
        view?.go(to: searchResults[index])
    }
    func goToPage(_ number: Int) {
        guard let document = view?.document, let page = document.page(at: number - 1) else { return }
        view?.go(to: page)
    }
    func go(to anchor: SourceAnchor) {
        guard let page = view?.document?.page(at: anchor.pageIndex) else { return }
        let region = CGRect(x: anchor.region.x, y: anchor.region.y, width: anchor.region.width, height: anchor.region.height)
        view?.go(to: region, on: page)
    }
    func go(to bookmark: ReadingBookmark) {
        guard let page = view?.document?.page(at: bookmark.pageIndex) else { return }
        if let x = bookmark.positionX, let y = bookmark.positionY { view?.go(to: PDFDestination(page: page, at: CGPoint(x: x, y: y))) }
        else { view?.go(to: page) }
    }
    /// Brings `target` to the top of the view and flashes it, at the reader's zoom. The view keeps its sideways position
    /// when the item fits across it there; otherwise the item is centred across the view (or, wider than the view,
    /// starts at its left edge). The item's region is estimated, so it is never pinned to the view's edge.
    func go(to target: ReferenceTarget) {
        guard let view, let page = view.document?.page(at: target.pageIndex) else { return }
        let region = target.region.rect
        let top = min(region.maxY + 24, page.bounds(for: .cropBox).maxY)
        let clip = view.documentView?.enclosingScrollView?.contentView
        let x = clip?.bounds.minX
        view.go(to: PDFDestination(page: page, at: CGPoint(x: region.minX, y: top)))
        if let clip, let x {
            let item = clip.convert(view.convert(region, from: page), from: view)
            let width = clip.bounds.width
            var origin = CGPoint(x: x, y: clip.bounds.minY)
            if item.width > width - 16 { origin.x = item.minX - 8 }
            else if item.minX < x || item.maxX > x + width { origin.x = item.midX - width / 2 }
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
            clip.enclosingScrollView?.reflectScrolledClipView(clip)
        }
        flash(region, onPage: target.pageIndex)
    }
    func flash(_ rect: CGRect, onPage pageIndex: Int) {
        flash = (pageIndex, rect)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            if self?.flash?.pageIndex == pageIndex, self?.flash?.rect == rect { self?.flash = nil }
        }
    }
    /// Calculated once per annotated page, in PDF coordinates: scrolling and zooming need no text measurements.
    /// Stored regions remain intact; old marks and exported copies use the same fitted geometry as new marks.
    func highlightBounds(for highlight: StudyHighlight, on page: PDFPage) -> [CGRect] {
        highlightBounds(for: highlight.regions.map(\.rect), on: page)
    }

    func highlightBounds(for regions: [CGRect], on page: PDFPage) -> [CGRect] {
        if highlightGeometryDocument !== page.document {
            highlightGeometry = [:]; highlightFonts = InkFontCache(); highlightGeometryDocument = page.document
        }
        let index = page.document?.index(for: page) ?? 0
        let geometry: HighlightGeometry
        if let cached = highlightGeometry[index] { geometry = cached }
        else {
            geometry = HighlightGeometry(page: page, fonts: highlightFonts)
            highlightGeometry[index] = geometry
        }
        return geometry.rects(for: regions)
    }

    /// Highlights and underlines as annotations of the reader's pages. The arrays come from every SwiftUI update of the
    /// reader: the same array as last time (same storage) is not compared, and a change re-annotates only the highlights
    /// added, removed or edited.
    func syncHighlights(_ highlights: [StudyHighlight], in document: PDFDocument) {
        let visible = showAnnotations ? highlights : []
        if annotatedDocument === document, appliedHighlights.sharesStorage(with: visible) { return }
        if annotatedDocument === document, appliedHighlights == visible { appliedHighlights = visible; return }
        if annotatedDocument !== document {
            for annotation in highlightAnnotations.values.joined() { annotation.page?.removeAnnotation(annotation) }
            highlightAnnotations = [:]; appliedHighlights = []; annotatedDocument = document
        }
        let wanted = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let applied = Dictionary(appliedHighlights.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, highlight) in applied where wanted[id] != highlight {
            for annotation in highlightAnnotations.removeValue(forKey: id) ?? [] { annotation.page?.removeAnnotation(annotation) }
        }
        for highlight in visible where highlightAnnotations[highlight.id] == nil {
            guard let page = document.page(at: highlight.pageIndex) else { continue }
            var annotations: [PDFAnnotation] = []
            for rect in highlightBounds(for: highlight, on: page) {
                let annotation = PDFAnnotation(bounds: rect, forType: highlight.style == .underline ? .underline : .highlight, withProperties: nil)
                annotation.color = highlight.style == .underline ? highlight.nativeColor.withAlphaComponent(0.95) : highlight.nativeColor
                annotation.quadrilateralPoints = [CGPoint(x: 0, y: rect.height), CGPoint(x: rect.width, y: rect.height), .zero, CGPoint(x: rect.width, y: 0)].map { NSValue(point: $0) }
                annotation.contents = highlight.quote
                page.addAnnotation(annotation); annotations.append(annotation)
            }
            highlightAnnotations[highlight.id] = annotations
        }
        appliedHighlights = visible
    }

    /// Handwriting as ink annotations, diffed by stroke like the highlights.
    func syncInk(_ strokes: [InkStroke], in document: PDFDocument) {
        if !inkStrokes.sharesStorage(with: strokes), inkStrokes != strokes { inkStrokes = strokes; view?.invalidateMarks() }
        let visible = showAnnotations ? strokes : []
        if inkDocument === document, appliedInk.sharesStorage(with: visible) { return }
        if inkDocument === document, appliedInk == visible { appliedInk = visible; return }
        if inkDocument !== document {
            for annotation in inkAnnotations.values { annotation.page?.removeAnnotation(annotation) }
            inkAnnotations = [:]; appliedInk = []; inkDocument = document
        }
        let wanted = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let applied = Dictionary(appliedInk.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, stroke) in applied where wanted[id] != stroke {
            if let annotation = inkAnnotations.removeValue(forKey: id) { annotation.page?.removeAnnotation(annotation) }
        }
        for stroke in visible where inkAnnotations[stroke.id] == nil {
            guard let page = document.page(at: stroke.pageIndex), let annotation = stroke.annotation() else { continue }
            page.addAnnotation(annotation); inkAnnotations[stroke.id] = annotation
        }
        appliedInk = visible
        view?.needsDisplay = true
    }
    func updateSelection() {
        defer { view?.updateOverlay() }
        guard let view, let text = view.currentSelection, text.pages.count == 1,
              let page = text.pages.first, let document = view.document else {
            selection = nil; hasSelection = false; return
        }
        let bounds = text.bounds(for: page).insetBy(dx: -5, dy: -5).intersection(page.bounds(for: .cropBox))
        guard bounds.width > 0, bounds.height > 0 else { selection = nil; hasSelection = false; return }
        selection = (document.index(for: page), bounds, text.string ?? "")
        hasSelection = true
    }
    func updatePage() {
        guard let view, let page = view.currentPage, let document = view.document else { return }
        let number = document.index(for: page) + 1, zoom = Double(view.scaleFactor)
        if pageNumber != number { pageNumber = number }
        if pageCount != document.pageCount { pageCount = document.pageCount }
        if canGoBack != view.canGoBack { canGoBack = view.canGoBack }
        if canGoForward != view.canGoForward { canGoForward = view.canGoForward }
        if scale != zoom { scale = zoom }
        updateViewport()
        // PDFKit emits several page/layout notifications for one jump. Draw the final geometry once.
        view.scheduleOverlayRefresh()
        onReadingChanged?(pageNumber - 1, Double(view.scaleFactor))
    }

    private func settle() {
        settling?.cancel()
        settling = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled, self.settledPageIndex != self.focusPageIndex else { return }
            self.settledPageIndex = self.focusPageIndex
        }
    }

    /// A file editor can keep the source inspector visible before its PDF view has been created.
    func restorePageFocus(_ pageIndex: Int) {
        settling?.cancel()
        focusPageIndex = pageIndex
        settledPageIndex = pageIndex
    }

    /// Profiling: moves the published line by one, as a scroll to the next line would (QA copies only).
    func qaStepLine() {
        exactFocusLine = (exactFocusLine ?? 0) + 1
        currentBand += 1; focusBand = currentBand
    }

    /// Sets the reading height on the focus page; observers hear of it when the line under it changes.
    private func setFocus(y: CGFloat?) {
        exactFocusY = y
        exactFocusLine = y.flatMap { lineIndex(onPage: focusPageIndex, y: $0)?.index }
        let band = focusPageIndex * 100_000 + (exactFocusLine ?? 50_000 + Int(((y ?? 0) / 24).rounded(.down)))
        guard band != currentBand else { return }
        currentBand = band
        // The gutter's current line follows at once; observers hear of it paced (`publishFocus`).
        view?.updateGutterFocus()
    }

    /// Publishes the line and the store's outline path and statement at the reading position, in one SwiftUI update,
    /// at most every 100 ms while the page scrolls.
    func publishFocus() {
        focusPacer.run { [weak self] in
            guard let self else { return }
            if self.focusBand != self.currentBand { self.focusBand = self.currentBand }
            self.owner?.publishReadingFocus()
        }
    }

    /// Records where the reader is looking. The exact position is kept on every call; observed values change only when
    /// the page, the line, the section or the statement under it changes, so scrolling redraws only what names them.
    func updateViewport() {
        guard let view, let document = view.document, view.bounds.height > 0 else { return }
        let point = CGPoint(x: view.bounds.midX, y: view.isFlipped ? view.bounds.minY + view.bounds.height * 0.3 : view.bounds.maxY - view.bounds.height * 0.3)
        if let page = view.page(for: point, nearest: true) {
            let index = document.index(for: page)
            if index != focusPageIndex {
                focusPageIndex = index
                // PDFKit also updates the viewport while staying on the same page. Restarting the
                // delay on every notification can leave the inspector on the previous page indefinitely.
                settle()
            }
            setFocus(y: view.convert(point, to: page).y)
        }
        let range = view.visiblePageIndexes()
        if range != visiblePageRange { visiblePageRange = range }
        publishFocus()
        owner?.watchFocusInputs()
    }
}

@MainActor
final class RegionPDFView: PDFView {
    var controller: ReaderController?
    var libraryDrop: PDFEditorDropHandler?

    /// ⌘C copies running text, as a reader means to paste it: the line breaks inside a paragraph and the words
    /// hyphenated across lines are joined, and TeX's broken ligatures and accents repaired (`CleanCopy`).
    override func copy(_ sender: Any?) {
        guard let text = currentSelection?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            super.copy(sender); return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CleanCopy.text(text), forType: .string)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        libraryDrop?.update(sender, in: self) ?? super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        libraryDrop?.update(sender, in: self) ?? super.draggingUpdated(sender)
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        libraryDrop?.accepts(sender) == true || super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        libraryDrop?.perform(sender, in: self) ?? super.performDragOperation(sender)
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        libraryDrop?.clear()
        super.draggingExited(sender)
    }
    var definitionPopover: DefinitionLookupPopover?
    var referencePopover: ReferencePeekPopover?
    /// Peeks kept open beside the reader's work: moved, dragged away or Shift-clicked.
    var keptReferencePeeks: [ReferencePeekPopover] = []
    var quickAskPopover: QuickAskPopover?
    var marginNotePopover: MarginNotePopover?
    /// Previews a reference while the pointer rests on it.
    lazy var hoverPreview = HoverPreviewController(view: self)
    /// Says what a symbol stands for while the pointer rests on it.
    lazy var symbolHover = SymbolHoverController(view: self)
    private(set) var hoveredSymbol: SymbolHit?
    private var pendingReference: (mention: PageMention, pageIndex: Int, start: CGPoint, toSide: Bool, keep: Bool)?
    private var referenceDragged = false
    private(set) var hoveredReference: (mention: PageMention, pageIndex: Int)?
    private var referenceTracking: NSTrackingArea?
    private var start: CGPoint?
    /// The capture rectangle being dragged in region mode, in this view's coordinates.
    private(set) var dragRectangle: CGRect?
    private var drawingStroke: InkStroke?
    var shapeGesture: ShapeGesture?
    var highlightDrag: HighlightDrag?
    lazy var selectionOverlay = RegionSelectionOverlay(frame: bounds)

    /// A Shift-click with text selected extends the selection, as anywhere on the page, even over a reference.
    private func extendsSelection(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.contains(.shift) && currentSelection?.string?.isEmpty == false
    }

    /// Peeks are child windows of the reader's window: they leave with the reader.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { dismissReferencePeek(); closeKeptReferencePeeks() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let target = super.hitTest(point) else { return nil }
        if target is NSScroller { return target }
        // PDFKit's page subviews otherwise consume the drag before our handler.
        if controller?.regionMode == true || controller?.inkMode == true { return self }
        let event = NSApp.currentEvent
        if event?.modifierFlags.contains(.command) == true { return self }
        // AppKit hit-tests for every scroll-wheel event too; only a click needs the margin, the gutter and the references.
        if let event, ![.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) { return target }
        let local = convert(point, from: superview)
        if let event, [.leftMouseDown, .rightMouseDown].contains(event.type), shapeHit(at: local) != nil { return self }
        if event?.type == .leftMouseDown { controller?.activeHighlightID = highlightHit(at: local)?.id }
        if let event, event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.shift)),
           controller?.showAnnotations == true, highlightHit(at: local) != nil { return self }
        // A double-click in the page's margin starts a margin note; PDFKit would otherwise take it.
        if let event, event.type == .leftMouseDown, event.clickCount == 2, event.modifierFlags.isDisjoint(with: [.command, .shift, .option, .control]),
           controller?.onMarginNote != nil, marginLine(at: local) != nil { return self }
        // A click on a line number selects the line, as in an editor.
        if event?.type == .leftMouseDown, selectionOverlay.lineNumberHit(at: local) != nil { return self }
        // References behave like links: a plain click opens the peek rather than starting a selection, ⌥-click opens
        // them beside the page and ⇧-click opens another peek. Control clicks, and Shift-clicks that extend a selection,
        // keep PDFKit's selection behaviour.
        if NSEvent.modifierFlags.isDisjoint(with: [.control]), !extendsSelection(NSEvent.modifierFlags), referenceHit(at: local) != nil { return self }
        return target
    }

    /// The indexes of the pages on screen. PDFKit's `visiblePages` asks every page view of the document (about a
    /// millisecond in a 400-page book), too slow for every frame of a scroll: the pages under the view's corners bound
    /// the range, and each page in it is kept if its rectangle meets the view.
    func visiblePageIndexes() -> ClosedRange<Int>? {
        guard let document, document.pageCount > 0, bounds.width > 2, bounds.height > 2 else { return nil }
        let inset = bounds.insetBy(dx: 1, dy: 1)
        let corners = [CGPoint(x: inset.minX, y: inset.minY), CGPoint(x: inset.maxX, y: inset.minY), CGPoint(x: inset.minX, y: inset.maxY), CGPoint(x: inset.maxX, y: inset.maxY)]
        let candidates = corners.compactMap { page(for: $0, nearest: true) }.map { document.index(for: $0) }
        guard let low = candidates.min(), let high = candidates.max() else { return nil }
        let shown = (low...high).filter { index in
            guard let page = document.page(at: index) else { return false }
            return convert(page.bounds(for: .cropBox), from: page).intersects(bounds)
        }
        guard let first = shown.first, let last = shown.last else { return low...high }
        return first...last
    }

    /// The reference mention under a point in this view's coordinates, if links are enabled.
    func referenceHit(at point: CGPoint) -> (mention: PageMention, pageIndex: Int)? {
        guard let controller, controller.showReferenceLinks, !controller.regionMode, !controller.inkMode,
              let index = controller.references, let page = page(for: point, nearest: false), let document else { return nil }
        let pageIndex = document.index(for: page)
        guard let mention = index.mention(at: convert(point, to: page), onPage: pageIndex), !mention.isDefinition || mention.destination != nil else { return nil }
        return (mention, pageIndex)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let referenceTracking { removeTrackingArea(referenceTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); referenceTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let reference = referenceHit(at: point)
        updateReferenceHover(reference)
        updateSymbolHover(reference == nil ? symbolHit(at: point) : nil)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateReferenceHover(nil)
        updateSymbolHover(nil)
    }

    /// A symbol under a point that the book defines somewhere: a Greek or mathematical letter, or a Latin letter standing alone.
    func symbolHit(at point: CGPoint, prefilter: Bool = true) -> SymbolHit? {
        guard let controller, !controller.regionMode, !controller.inkMode, let notation = controller.references?.analysis?.notation, !notation.isEmpty,
              let page = page(for: point, nearest: false), let document else { return nil }
        let local = convert(point, to: page)
        // The word under the pointer, found in the page's text near its position (PDFKit's character index counts differently).
        guard let word = page.selectionForWord(at: local), let wordText = word.string, !wordText.isEmpty else { return nil }
        // Most words cannot hold a symbol: only a Greek or mathematical letter, or a Latin letter standing alone, can.
        // Checking the word's own text first spares a selection per occurrence and per character on every move.
        let characters = Array(wordText)
        let candidate = characters.indices.contains { offset in
            let character = characters[offset]
            guard Notation.isSymbolCharacter(character), notation.bySymbol[Notation.key(String(character))] != nil else { return false }
            guard character.isASCII else { return true }
            return !(offset > 0 && characters[offset - 1].isLetter) && !(offset + 1 < characters.count && characters[offset + 1].isLetter)
        }
        guard candidate || !prefilter, let text = page.string else { return nil }
        let string = text as NSString
        let wordBounds = word.bounds(for: page)
        var index = NSNotFound
        var search = NSRange(location: 0, length: string.length)
        while true {
            let found = string.range(of: wordText, options: [], range: search)
            guard found.location != NSNotFound else { break }
            if let rect = page.selection(for: found)?.bounds(for: page), rect.insetBy(dx: -1, dy: -1).intersects(wordBounds) {
                // Within the word, the character whose prefix reaches the pointer.
                index = found.location
                for offset in 0..<found.length {
                    let prefix = page.selection(for: NSRange(location: found.location, length: offset + 1))?.bounds(for: page).maxX ?? rect.maxX
                    if prefix >= local.x { index = found.location + offset; break }
                }
                break
            }
            search = NSRange(location: found.upperBound, length: string.length - found.upperBound)
        }
        guard index != NSNotFound, index >= 0, index < string.length else { return nil }
        let range = string.rangeOfComposedCharacterSequence(at: index)
        // `first`, not `Character(_:)`: a composed sequence of NSString can hold more than one Swift character.
        guard let character = string.substring(with: range).first, Notation.isSymbolCharacter(character) else { return nil }
        if character.isASCII {
            func neighbour(_ offset: Int) -> Character? {
                let at = offset < 0 ? range.location - 1 : range.upperBound
                guard at >= 0, at < string.length else { return nil }
                return string.substring(with: string.rangeOfComposedCharacterSequence(at: at)).first
            }
            if neighbour(-1)?.isLetter == true || neighbour(1)?.isLetter == true { return nil }
        }
        let symbol = Notation.key(String(character))
        guard notation.bySymbol[symbol] != nil else { return nil }
        guard let rect = PageTextMap.bounds(of: index, on: page) else { return nil }
        return SymbolHit(symbol: symbol, pageIndex: document.index(for: page), location: range.location, rect: rect)
    }

    func qaShowSymbol(_ hit: SymbolHit) { hoveredSymbol = hit; symbolHover.showNow(hit) }

    private func updateSymbolHover(_ hit: SymbolHit?) {
        guard hit != hoveredSymbol else { return }
        hoveredSymbol = hit
        symbolHover.store = controller?.owner
        symbolHover.update(hit)
    }

    override func cursorUpdate(with event: NSEvent) {
        if event.modifierFlags.contains(.shift), highlightHit(at: convert(event.locationInWindow, from: nil)) != nil {
            NSCursor.resizeLeftRight.set(); return
        }
        if referenceHit(at: convert(event.locationInWindow, from: nil)) != nil { NSCursor.pointingHand.set() } else { super.cursorUpdate(with: event) }
    }

    private func updateReferenceHover(_ hit: (mention: PageMention, pageIndex: Int)?) {
        let changed = hit?.mention != hoveredReference?.mention || hit?.pageIndex != hoveredReference?.pageIndex
        hoveredReference = hit
        // A QA copy recording in the background leaves the reader's pointer alone.
        if !QAHooks.startsInBackground {
            if hit != nil { NSCursor.pointingHand.set() } else if changed { NSCursor.iBeam.set() }
        }
        if changed {
            updateOverlay()
            hoverPreview.store = controller?.owner
            hoverPreview.update(hit)
        }
    }

    /// With the ruler on, ↓ ↑ (or J K) step through the lines, Return opens the line's first reference, Escape ends it.
    override func keyDown(with event: NSEvent) {
        if let controller, controller.inkMode, event.modifierFlags.isDisjoint(with: [.command, .control, .option]) {
            if event.keyCode == 53 {
                if shapeGesture != nil { cancelShapeGesture() }
                else { controller.inkMode = false }
                return
            }
            if [51, 117].contains(event.keyCode), let id = controller.activeShapeID {
                controller.owner?.removeShape(id: id); return
            }
        }
        guard let controller, controller.rulerMode, event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { super.keyDown(with: event); return }
        // While a proof is debugged: Return steps into the line's citation, Shift-Return steps out, Escape stops
        // (F11 is often taken by macOS, so the debugger also answers to the keys the ruler already uses).
        if controller.debugging, let store = controller.owner {
            switch event.keyCode {
            case 36, 76: if event.modifierFlags.contains(.shift) { store.debugStepOut() } else { store.debugStepInto() }; return
            case 53: store.stopDebugging(); return
            case 125: store.debugStepOver(); return
            case 126: store.debugStepBack(); return
            default: break
            }
        }
        switch event.keyCode {
        case 125: controller.moveRuler(by: 1)          // ↓
        case 126: controller.moveRuler(by: -1)         // ↑
        case 53: controller.rulerMode = false           // Escape
        case 36, 76: openRulerReference()               // Return, Enter
        default:
            switch event.charactersIgnoringModifiers {
            case "j": controller.moveRuler(by: 1)
            case "k": controller.moveRuler(by: -1)
            case " ": controller.moveRuler(by: event.modifierFlags.contains(.shift) ? -3 : 3)
            case "?": controller.owner?.markUnclear()
            default: super.keyDown(with: event)
            }
        }
    }

    /// The first reference on the ruler's line, peeked as if clicked.
    func openRulerReference() {
        guard let controller, let line = controller.rulerLine, let index = controller.references else { return }
        let mentions = index.mentions(onPage: line.pageIndex).filter { !$0.isDefinition && $0.rects.contains { $0.intersects(line.rect.insetBy(dx: 0, dy: 1)) } }
        if let first = mentions.min(by: { ($0.rects.first?.minX ?? 0) < ($1.rects.first?.minX ?? 0) }) { controller.onReference?(first, line.pageIndex, false) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        controller?.regionMode == true || controller?.inkMode == true || super.acceptsFirstMouse(for: event)
    }

    override func resetCursorRects() {
        if controller?.regionMode == true || controller?.inkMode == true { addCursorRect(bounds, cursor: .crosshair) }
        else { super.resetCursorRects() }
    }

    private var overlayRefreshScheduled = false

    /// Brings the marks over the page up to date on the next turn of the run loop, once (after PDFKit's own layout).
    func scheduleOverlayRefresh() {
        guard !overlayRefreshScheduled else { return }
        overlayRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.overlayRefreshScheduled = false
            self?.updateOverlay()
        }
    }

    /// Lays the marks over the pages out again: the reader's marks, modes, the book's analysis or the theme changed.
    func refreshCaptureOverlay() {
        selectionOverlay.controller = controller
        selectionOverlay.invalidate()
        selectionOverlay.update(in: self)
    }

    /// Brings the marks up to date without rebuilding the pages already laid out (hover, selection, ruler, flash, pages
    /// coming into view).
    func updateOverlay() {
        selectionOverlay.controller = controller
        selectionOverlay.update(in: self)
    }

    /// Moves the marks with the pages while scrolling, in the same transaction as the scroll. Called synchronously from the
    /// clip view's bounds notification; a zoom or another layout lays them out again at once.
    func followScroll() {
        if !selectionOverlay.followScroll(in: self) { updateOverlay() }
    }

    /// The current line's number in the gutter follows the reading position.
    func updateGutterFocus() { selectionOverlay.updateFocusLine() }

    /// The page marks are laid out again at the next update (the reader's notes, highlights or handwriting changed).
    func invalidateMarks() { selectionOverlay.invalidate() }

    override func mouseDown(with event: NSEvent) {
        hoverPreview.dismiss()
        symbolHover.dismiss()
        if handleShapeMouseDown(event) { return }
        controller?.activeHighlightID = highlightHit(at: convert(event.locationInWindow, from: nil))?.id
        if beginHighlightExtension(with: event) { return }
        if controller?.regionMode != true, controller?.inkMode != true,
           let hit = selectionOverlay.lineNumberHit(at: convert(event.locationInWindow, from: nil)) {
            window?.makeFirstResponder(self)
            if controller?.rulerMode == true, let lines = controller?.readingLines(onPage: hit.pageIndex), lines.indices.contains(hit.index) {
                controller?.rulerLine = ReaderController.RulerLine(pageIndex: hit.pageIndex, rect: lines[hit.index], index: hit.index, count: lines.count)
            } else {
                controller?.selectLine(hit.index, onPage: hit.pageIndex)
            }
            return
        }
        // A double-click in the page's margin writes a margin note beside that line.
        if event.clickCount == 2, controller?.regionMode != true, controller?.inkMode != true, controller?.onMarginNote != nil,
           event.modifierFlags.isDisjoint(with: [.command, .shift, .option, .control]),
           let margin = marginLine(at: convert(event.locationInWindow, from: nil)) {
            controller?.onMarginNote?(margin.pageIndex, margin.region, margin.quote)
            return
        }
        if controller?.regionMode != true, controller?.inkMode != true, event.modifierFlags.contains(.command) {
            let local = convert(event.locationInWindow, from: nil)
            guard let page = page(for: local, nearest: false), let document,
                  let word = page.selectionForWord(at: convert(local, to: page)), let text = word.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            controller?.onLookup?(document.index(for: page), word.bounds(for: page), text)
            return
        }
        if controller?.regionMode != true, controller?.inkMode != true, event.modifierFlags.isDisjoint(with: [.control]),
           !extendsSelection(event.modifierFlags), let hit = referenceHit(at: convert(event.locationInWindow, from: nil)) {
            window?.makeFirstResponder(self)
            let local = convert(event.locationInWindow, from: nil)
            if event.clickCount > 1 {
                // A double-click still selects the word, as on ordinary text.
                pendingReference = nil
                if let page = page(for: local, nearest: false), let word = page.selectionForWord(at: convert(local, to: page)) { setCurrentSelection(word, animate: false) }
                return
            }
            clearSelection()
            pendingReference = (hit.mention, hit.pageIndex, local, event.modifierFlags.contains(.option), event.modifierFlags.contains(.shift))
            referenceDragged = false
            return
        }
        if let controller, controller.inkMode {
            window?.makeFirstResponder(self)
            let local = convert(event.locationInWindow, from: nil)
            guard let page = page(for: local, nearest: false), let document else { return }
            let point = convert(local, to: page)
            let inkPoint = InkPoint(x: point.x, y: point.y)
            if controller.inkEraser {
                let nearest = controller.inkStrokes.filter { $0.pageIndex == document.index(for: page) }
                    .min { $0.distance(to: inkPoint) < $1.distance(to: inkPoint) }
                if let nearest, nearest.distance(to: inkPoint) <= 8 / scaleFactor + nearest.width / 2 { controller.onEraseInk?(nearest.id) }
            } else {
                drawingStroke = InkStroke(pageIndex: document.index(for: page), points: [inkPoint], color: controller.inkColor, width: controller.inkWidth)
                selectionOverlay.updateStroke(drawingStroke, in: self)
            }
            return
        }
        guard controller?.regionMode == true else { super.mouseDown(with: event); return }
        start = convert(event.locationInWindow, from: nil)
        dragRectangle = nil
        clearSelection()
        controller?.selection = nil
        controller?.hasSelection = false
        updateOverlay()
    }
    override func mouseDragged(with event: NSEvent) {
        if shapeGesture != nil { updateShapeGesture(event); return }
        if highlightDrag != nil { updateHighlightExtension(with: event); return }
        if let pending = pendingReference {
            // Dragging from a reference selects text, as it would anywhere else on the page.
            let current = convert(event.locationInWindow, from: nil)
            if referenceDragged || hypot(current.x - pending.start.x, current.y - pending.start.y) > 3 {
                referenceDragged = true
                if let page = document?.page(at: pending.pageIndex),
                   let selection = page.selection(from: convert(pending.start, to: page), to: convert(current, to: page)) {
                    setCurrentSelection(selection, animate: false)
                }
            }
            return
        }
        if controller?.inkMode == true { appendInkPoint(event); return }
        guard controller?.regionMode == true, let start else { super.mouseDragged(with: event); return }
        let end = convert(event.locationInWindow, from: nil)
        dragRectangle = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x-start.x), height: abs(end.y-start.y))
        updateOverlay()
    }
    override func mouseUp(with event: NSEvent) {
        if shapeGesture != nil { finishShapeGesture(event); return }
        if highlightDrag != nil { finishHighlightExtension(with: event); return }
        // With the ruler on, a click on a line moves the ruler there.
        if let controller, controller.rulerMode, pendingReference == nil, !controller.regionMode, !controller.inkMode, event.clickCount == 1,
           currentSelection?.string?.isEmpty != false {
            let local = convert(event.locationInWindow, from: nil)
            if let page = page(for: local, nearest: false), let document { controller.placeRuler(at: convert(local, to: page), pageIndex: document.index(for: page)) }
        }
        if let pending = pendingReference {
            pendingReference = nil
            let dragged = referenceDragged
            referenceDragged = false
            if !dragged {
                if pending.toSide, let toSide = controller?.onReferenceToSide { toSide(pending.mention, pending.pageIndex) }
                else { controller?.onReference?(pending.mention, pending.pageIndex, pending.keep) }
            }
            return
        }
        if controller?.inkMode == true {
            appendInkPoint(event)
            let stroke = drawingStroke
            drawingStroke = nil; selectionOverlay.updateStroke(nil, in: self)
            if let stroke, stroke.points.count > 1 { controller?.onInk?(stroke) }
            return
        }
        guard controller?.regionMode == true, let start else { super.mouseUp(with: event); return }
        defer { self.start = nil; dragRectangle = nil; updateOverlay() }
        let end = convert(event.locationInWindow, from: nil)
        let rectangle = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x-start.x), height: abs(end.y-start.y))
        guard rectangle.width > 8, rectangle.height > 8,
              let page = page(for: start, nearest: false), let document else { return }
        let region = convert(rectangle, to: page).intersection(page.bounds(for: .cropBox))
        guard !region.isNull, region.width > 2, region.height > 2 else { return }
        let quote = page.selection(for: region)?.string ?? ""
        controller?.selection = (document.index(for: page), region, quote)
        controller?.hasSelection = true
    }

    // MARK: Visual review

    /// Hovers the `index`th reference on screen, as the pointer would (QA copies only).
    func qaHoverReference(_ index: Int, kind: ReferenceKind? = nil, number: String? = nil, off: Bool = false) -> Bool {
        if off { updateReferenceHover(nil); return true }
        guard let document, let references = controller?.references else { return false }
        var found: [(mention: PageMention, pageIndex: Int)] = []
        for page in visiblePages {
            let pageIndex = document.index(for: page)
            for mention in references.mentions(onPage: pageIndex) where !mention.isDefinition { found.append((mention, pageIndex)) }
        }
        // kind= and number= name the reference (“theorem”, “1.3”) rather than its place among those on screen.
        if kind != nil || number != nil {
            guard let hit = found.first(where: { (kind == nil || $0.mention.key.kind == kind) && (number == nil || $0.mention.key.number == number) }) else { return false }
            updateReferenceHover(hit)
            return true
        }
        guard found.indices.contains(index) else { return false }
        updateReferenceHover(found[index])
        return true
    }

    /// A drag along page points, delivered as mouse events made here and sent to this view's handlers directly: nothing
    /// goes through the window server (QA copies only, for ink and region capture).
    func qaDrag(onPage pageIndex: Int, through points: [CGPoint]) {
        guard let first = points.first, let last = points.last else { return }
        qaDragStep(.leftMouseDown, onPage: pageIndex, at: first)
        for point in points.dropFirst() { qaDragStep(.leftMouseDragged, onPage: pageIndex, at: point) }
        qaDragStep(.leftMouseUp, onPage: pageIndex, at: last)
    }

    /// One step of a drag, so that a demo can draw it at a person's pace: down, any number of drags, then up.
    func qaDragStep(_ type: NSEvent.EventType, onPage pageIndex: Int, at point: CGPoint) {
        guard let window, let page = document?.page(at: pageIndex),
              let event = NSEvent.mouseEvent(with: type, location: convert(convert(point, from: page), to: nil), modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        switch type {
        case .leftMouseDown: mouseDown(with: event)
        case .leftMouseUp: mouseUp(with: event)
        default: mouseDragged(with: event)
        }
    }

    /// Leaving ink or region mode drops the stroke in progress; the gutter and links come back (or go) with the mode.
    func cancelInkGesture() {
        drawingStroke = nil
        cancelShapeGesture()
        selectionOverlay.updateStroke(nil, in: self)
        refreshCaptureOverlay()
    }
    private func appendInkPoint(_ event: NSEvent) {
        guard let stroke = drawingStroke, let page = document?.page(at: stroke.pageIndex) else { return }
        let point = convert(convert(event.locationInWindow, from: nil), to: page)
        guard page.bounds(for: .cropBox).contains(point) else { return }
        let inkPoint = InkPoint(x: point.x, y: point.y)
        if let last = stroke.points.last, hypot(last.x - point.x, last.y - point.y) < 0.3 { return }
        drawingStroke?.points.append(inkPoint)
        selectionOverlay.updateStroke(drawingStroke, in: self)
    }
}


/// “4 refs · 1 note” beside an equation label, in the margin beside a statement, or above a caption. Clicking lists the
/// references in the panel. It sits on a paper-coloured backing, so it stays legible wherever the layout puts it.
@MainActor final class ReferenceLensView: NSView {
    static let kinds: Set<ReferenceKind> = [.equation, .figure, .table, .algorithm, .theorem, .exercise]
    let key: ReferenceKey
    private let text: String
    private let open: (ReferenceKey) -> Void
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    private let font: NSFont
    /// Measured once: the lens is placed on every layout of its page.
    private let textSize: CGSize

    init(key: ReferenceKey, references: Int, notes: Int, fontSize: CGFloat = 10, open: @escaping (ReferenceKey) -> Void) {
        self.key = key; self.open = open
        font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        var parts: [String] = []
        if references > 0 { parts.append("\(references) \(references == 1 ? "ref" : "refs")") }
        if notes > 0 { parts.append("\(notes) \(notes == 1 ? "note" : "notes")") }
        text = parts.joined(separator: " · ")
        textSize = (text as NSString).size(withAttributes: [.font: font])
        super.init(frame: .zero)
        // Drawn once: the lens moves with its page, which must not redraw it. A view that may draw outside its bounds
        // (the default since macOS 14) is drawn again whenever its visible part changes, that is on every scroll frame.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        clipsToBounds = true
        toolTip = references > 0 ? "\(key.spokenTitle) is cited \(references) \(references == 1 ? "time" : "times") · click to list the references" : "\(notes) of your notes on \(key.spokenTitle)"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(text) for \(key.spokenTitle)")
    }
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(textSize.width) + 8, height: ceil(textSize.height) + 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        QAPerf.tick("Lens.draw")
        // Drawn on the page in the page theme's colours, whatever the appearance.
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        NSColor.lemmaPagePaper.withAlphaComponent(0.92).setFill(); shape.fill()
        let color = hovering ? NSColor.lemmaOliveOnPage : NSColor.lemmaPageSecondary
        if hovering { NSColor.lemmaOliveOnPage.withAlphaComponent(0.1).setFill(); shape.fill() }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        (text as NSString).draw(at: CGPoint(x: 4, y: (bounds.height - textSize.height) / 2), withAttributes: attributes)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { open(key) }
    override func accessibilityPerformPress() -> Bool { open(key); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A margin card: the note's kind, title and the start of the reader's own words.
@MainActor final class NoteCardView: NSView {
    let noteID: UUID
    private let open: () -> Void
    private let title = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let icon = NSImageView()
    private let selected: Bool
    private let isComment: Bool
    private let figureView = NSImageView()
    private let figure: NSImage?

    init(note: StudyNote, selected: Bool, figure: NSImage? = nil, open: @escaping () -> Void) {
        noteID = note.id; self.open = open; self.selected = selected; isComment = note.kind == .comment; self.figure = figure
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        clipsToBounds = true
        layer?.cornerRadius = 7
        layer?.borderWidth = selected ? 1.5 : 0.5
        icon.image = NSImage(systemSymbolName: note.kind.symbol, accessibilityDescription: nil)
        icon.contentTintColor = note.kind == .comment ? MarginNoteStyle.edgeColor : note.state == .understood ? .systemGreen : .lemmaOlive
        title.stringValue = note.title
        title.font = .systemFont(ofSize: 11.5, weight: .semibold)
        title.maximumNumberOfLines = 2
        // A margin note shows its words; its first line is already the title.
        detail.stringValue = note.kind == .comment ? note.body.split(whereSeparator: \.isNewline).dropFirst().joined(separator: " ") : Self.snippet(for: note)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 3
        for label in [title, detail] { label.lineBreakMode = .byTruncatingTail; label.isSelectable = false }
        [icon, title, detail].forEach(addSubview)
        if let figure {
            // A figure from the Lab: shown on white, like a plot pasted beside the equation.
            figureView.image = figure
            figureView.imageScaling = .scaleProportionallyUpOrDown
            figureView.wantsLayer = true
            figureView.layer?.backgroundColor = NSColor.white.cgColor
            figureView.layer?.cornerRadius = 4
            figureView.setAccessibilityLabel("Figure from the Lab")
            addSubview(figureView)
            if note.body.hasPrefix("Figure from the Lab notebook") { detail.stringValue = "" }
        }
        toolTip = note.title
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Open note: \(note.title)")
    }
    required init?(coder: NSCoder) { nil }

    static func snippet(for note: StudyNote) -> String {
        let candidates = [note.body, note.explanation?.body ?? "", note.recallPrompt, note.anchor.quote]
        let text = candidates.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func figureHeight(for width: CGFloat) -> CGFloat {
        guard let figure, figure.size.width > 0 else { return 0 }
        return min(220, (width - 16) * figure.size.height / figure.size.width)
    }

    /// Card heights by width: a card is recreated when its note changes, so a width is measured once.
    private var heights: [CGFloat: CGFloat] = [:]

    func height(for width: CGFloat) -> CGFloat {
        if let cached = heights[width] { return cached }
        let textWidth = width - 34
        let titleHeight = min(title.sizeThatFits(CGSize(width: textWidth, height: 100)).height, 30)
        let detailHeight = detail.stringValue.isEmpty ? 0 : min(detail.sizeThatFits(CGSize(width: textWidth, height: 200)).height, 44)
        let figure = figureHeight(for: width)
        let height = 12 + titleHeight + (detailHeight > 0 ? 3 + detailHeight : 0) + (figure > 0 ? 6 + figure : 0)
        if heights.count > 8 { heights = [:] }
        heights[width] = height
        return height
    }

    override func layout() {
        super.layout()
        let textWidth = bounds.width - 34
        icon.frame = CGRect(x: 9, y: bounds.height - 22, width: 16, height: 16)
        let titleHeight = min(title.sizeThatFits(CGSize(width: textWidth, height: 100)).height, 30)
        title.frame = CGRect(x: 28, y: bounds.height - 6 - titleHeight, width: textWidth, height: titleHeight)
        let figure = figureHeight(for: bounds.width)
        figureView.frame = CGRect(x: 8, y: 6, width: bounds.width - 16, height: figure)
        let bottom = figure > 0 ? 6 + figure + 3 : 6
        detail.frame = CGRect(x: 28, y: bottom, width: textWidth, height: max(0, title.frame.minY - 3 - bottom))
    }

    override func updateLayer() {
        layer?.backgroundColor = isComment ? MarginNoteStyle.paperColor.cgColor : NSColor.controlBackgroundColor.withAlphaComponent(0.94).cgColor
        layer?.borderColor = (selected ? NSColor.lemmaOlive : isComment ? MarginNoteStyle.edgeColor : NSColor.separatorColor).cgColor
    }
    override var wantsUpdateLayer: Bool { true }
    override func mouseDown(with event: NSEvent) { open() }
    override func accessibilityPerformPress() -> Bool { open(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Runs work at most once per interval, so a value that keeps changing is published regularly and its last state
/// always arrives. While calls keep coming (a scroll, frame by frame) the work runs inline in the first call after the
/// interval, in that frame's transaction; when they stop, the latest work runs a moment after the interval's end.
@MainActor
final class Pacer {
    private let interval: CFTimeInterval
    private var last: CFTimeInterval = 0
    private var pending: DispatchWorkItem?

    init(interval: CFTimeInterval) { self.interval = interval }

    func run(_ work: @escaping @MainActor () -> Void) {
        let now = CACurrentMediaTime()
        pending?.cancel(); pending = nil
        if now - last >= interval { last = now; work(); return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pending = nil
                self?.last = CACurrentMediaTime()
                work()
            }
        }
        pending = item
        // A little after the interval: a frame arriving by then runs the work itself.
        DispatchQueue.main.asyncAfter(deadline: .now() + interval - (now - last) + 0.02, execute: item)
    }
}

extension PDFPage {
    /// The page's size as shown: a page turned a quarter is as wide as it is tall.
    var displayedSize: CGSize {
        let box = bounds(for: .cropBox).size
        return rotation % 180 == 0 ? box : CGSize(width: box.height, height: box.width)
    }
}

extension HighlightColor {
    var nativeColor: NSColor {
        switch self {
        case .yellow: NSColor(srgbRed: 0.97, green: 0.81, blue: 0.22, alpha: 0.45)
        case .green: NSColor(srgbRed: 0.42, green: 0.75, blue: 0.43, alpha: 0.4)
        case .blue: NSColor(srgbRed: 0.34, green: 0.64, blue: 0.91, alpha: 0.4)
        case .rose: NSColor(srgbRed: 0.92, green: 0.44, blue: 0.57, alpha: 0.4)
        }
    }
}

extension PDFView {
    /// `gap` points between consecutive pages, split above and below each page, and `side` points beside it. A change lays
    /// the pages out again and keeps the reading position.
    func setPageGap(_ gap: Double, side: CGFloat) {
        let margins = NSEdgeInsets(top: gap / 2, left: side, bottom: gap / 2, right: side)
        guard !NSEdgeInsetsEqual(pageBreakMargins, margins) else { return }
        let destination = document == nil ? nil : currentDestination
        pageBreakMargins = margins
        layoutDocumentView()
        if let destination { go(to: destination) }
    }
}

extension ReadingLayout {
    var displayMode: PDFDisplayMode {
        switch self { case .singlePage: .singlePage; case .continuous: .singlePageContinuous; case .twoPages: .twoUp; case .twoPagesContinuous: .twoUpContinuous }
    }
    init(_ mode: PDFDisplayMode) {
        switch mode {
        case .singlePage: self = .singlePage
        case .twoUp: self = .twoPages
        case .twoUpContinuous: self = .twoPagesContinuous
        default: self = .continuous
        }
    }
}

struct PDFReaderSurface: NSViewRepresentable {
    let document: PDFDocument
    let reading: ReadingState
    let controller: ReaderController
    let regionMode: Bool
    var notes: [StudyNote] = []
    var highlights: [StudyHighlight] = []
    var inkStrokes: [InkStroke] = []
    var shapes: [PageShape] = []
    var selectedNoteID: UUID?
    var showAnnotations = true
    var recallMask: SourceAnchor?
    var foldedProofs: Set<String> = []
    var understood: Set<ReferenceKey> = []
    @AppStorage(LemmaPreferences.pageGap) private var pageGap = LemmaPreferences.pageGapDefault

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }
    func makeNSView(context: Context) -> RegionPDFView {
        let view = RegionPDFView()
        view.controller = controller
        if let store = controller.owner { view.libraryDrop = PDFEditorDropHandler(store: store, toSide: false) }
        view.registerForDraggedTypes(view.registeredDraggedTypes + [.string])
        controller.view = view
        view.displayMode = .singlePage
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.setPageGap(pageGap, side: 12)
        view.backgroundColor = PageThemeState.shared.theme.isDark ? NSColor(white: 0.085, alpha: 1) : (ThemeSnapshot.shared.colors?.pageCanvas.nsColor ?? .windowBackgroundColor)
        view.minScaleFactor = 0.25; view.maxScaleFactor = 6
        view.autoScales = true
        context.coordinator.observe(view)
        return view
    }
    func updateNSView(_ view: RegionPDFView, context: Context) {
        view.setPageGap(pageGap, side: 12)
        let mode = (reading.layout ?? .standard).displayMode
        if view.displayMode != mode { view.displayMode = mode }
        if view.document !== document {
            view.dismissDefinitionLookup()
            view.dismissReferencePeek()
            view.closeKeptReferencePeeks()
            view.dismissQuickAsk()
            // A margin note's editor belongs to the book it was opened on; left open, typing would go nowhere.
            view.dismissMarginNote()
            view.cancelInkGesture()
            view.document = document
            view.autoScales = reading.scale <= 0
            if let page = document.page(at: min(reading.pageIndex, document.pageCount - 1)) { view.go(to: page) }
            if reading.scale > 0 { view.scaleFactor = CGFloat(reading.scale) }
            // SwiftUI gives the new PDF view its pane size after this update. Restoring before
            // that layout (or before choosing Continuous) can move the destination to another page.
            DispatchQueue.main.async { [weak view, weak document] in
                guard let view, let document, view.document === document,
                      let page = document.page(at: min(reading.pageIndex, document.pageCount - 1)) else { return }
                view.layoutDocumentView()
                if reading.scale > 0 { view.scaleFactor = CGFloat(reading.scale) }
                if let x = reading.positionX, let y = reading.positionY {
                    view.go(to: PDFDestination(page: page, at: CGPoint(x: x, y: y)))
                } else { view.go(to: page) }
                controller.updatePage()
            }
            controller.selection = nil; controller.hasSelection = false; controller.activeHighlightID = nil; controller.activeShapeID = nil
            controller.pageCount = document.pageCount
            controller.pageNumber = min(max(reading.pageIndex + 1, 1), document.pageCount)
        }
        // The same notes as last time (same storage) are not compared; changed notes lay the page marks out again.
        if !controller.notes.sharesStorage(with: notes) {
            if controller.notes != notes { view.invalidateMarks() }
            controller.notes = notes
        }
        if controller.selectedNoteID != selectedNoteID { controller.selectedNoteID = selectedNoteID }
        if controller.foldedProofs != foldedProofs { controller.foldedProofs = foldedProofs }
        if controller.understood != understood { controller.understood = understood }
        // Edition snapshots trigger updates, but an older update must not reset the controller's selection.
        if controller.recallMask != recallMask { controller.recallMask = recallMask }
        controller.syncHighlights(highlights, in: document)
        controller.syncInk(inkStrokes, in: document)
        controller.syncShapes(shapes, in: document)
        context.coordinator.observeScroll(in: view)
        view.scheduleOverlayRefresh()
        view.window?.invalidateCursorRects(for: view)
    }
    static func dismantleNSView(_ view: RegionPDFView, coordinator: Coordinator) { coordinator.stop() }
    @MainActor final class Coordinator {
        let controller: ReaderController
        var observations: [NSObjectProtocol] = []
        private weak var clipView: NSClipView?
        private var scrollObservation: NSObjectProtocol?
        private var viewportUpdateScheduled = false
        private var overlayPages: ClosedRange<Int>?
        init(controller: ReaderController) { self.controller = controller }
        func observe(_ view: RegionPDFView) {
            // Visible pages change after layout too (a fold, a jump): the gutter and marks follow them.
            for notification in [Notification.Name.PDFViewSelectionChanged, .PDFViewPageChanged, .PDFViewScaleChanged, .PDFViewVisiblePagesChanged] {
                observations.append(NotificationCenter.default.addObserver(forName: notification, object: view, queue: .main) { [weak self] notification in
                    let selectionChanged = notification.name == .PDFViewSelectionChanged
                    MainActor.assumeIsolated {
                        if selectionChanged { self?.controller.updateSelection() }
                        else { self?.controller.updatePage() }
                    }
                })
            }
            // PDFKit's context menu sets the display mode itself; the book must take that layout, or the next update of
            // this view would put the book's own back.
            observations.append(NotificationCenter.default.addObserver(forName: .PDFViewDisplayModeChanged, object: view, queue: .main) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let view else { return }
                    self?.controller.onLayoutChanged?(ReadingLayout(view.displayMode))
                }
            })
            observeScroll(in: view)
        }
        func observeScroll(in view: RegionPDFView) {
            guard let clip = view.documentView?.enclosingScrollView?.contentView, clip !== clipView else { return }
            if let scrollObservation { NotificationCenter.default.removeObserver(scrollObservation) }
            clipView = clip; clip.postsBoundsChangedNotifications = true
            scrollObservation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // The marks over the page move with it in this transaction (a recall mask must never lag behind the
                    // answer it hides); what follows the reading position is coalesced to once per run-loop turn.
                    self?.controller.view?.followScroll()
                    self?.scheduleViewportUpdate()
                }
            }
        }
        private func scheduleViewportUpdate() {
            guard !viewportUpdateScheduled else { return }
            viewportUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.viewportUpdateScheduled = false
                let controller = self.controller
                controller.updateViewport()
                if controller.view?.hoverPreview.isShown == true { controller.view?.hoverPreview.dismiss() }
                controller.view?.symbolHover.dismiss()
                // The marks already move with the pages; only a page coming into view needs its own.
                if controller.visiblePageRange != self.overlayPages {
                    self.overlayPages = controller.visiblePageRange
                    controller.view?.updateOverlay()
                }
                controller.onReadingChanged?(controller.pageNumber - 1, controller.scale)
            }
        }
        func stop() {
            for observer in observations { NotificationCenter.default.removeObserver(observer) }
            if let scrollObservation { NotificationCenter.default.removeObserver(scrollObservation) }
            observations.removeAll(); scrollObservation = nil
        }
    }
}
