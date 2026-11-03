import SwiftUI
import AppKit
import PDFKit
import LemmaCore

/// VS Code's minimap for a book: miniatures of the pages beside the page, the visible region as a slider, and the
/// reader's marks drawn over them (highlights, notes, “?” marks, search matches). Click or drag to move.
struct PageMinimap: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme
    @State private var marks = MinimapMarkCache()

    var body: some View {
        let _ = QAPerf.tick("Minimap")
        let byPage = marks.update(store: store, colors: theme)
        // Miniatures depend on the page theme only; the workbench theme changes the marks and the slider.
        MinimapSurface(store: store, marks: byPage, marksRevision: marks.revision, pageThemeRevision: store.pageThemeRevision,
                       themeRevision: ThemeManager.shared.revision, colors: theme, sliderAlways: store.minimapSliderAlways)
            .frame(width: 96)
            .background(theme[.minimapBackground])
            .vsBorder(.leading, .editorGroupBorder, theme: theme)
            .accessibilityElement()
            .accessibilityLabel("Minimap")
            .accessibilityValue("Page \(store.reader.pageNumber) of \(store.reader.pageCount)")
            .accessibilityAdjustableAction { direction in store.reader.goToPage(store.reader.pageNumber + (direction == .increment ? 1 : -1)) }
            .help("Minimap: click or drag to move through the book")
    }
}

/// The minimap's marks by page, rebuilt only when the highlights, notes, matches, edition or colours change. Search
/// matches are measured once each, as a search's results arrive (a selection's pages and bounds cost PDFKit work).
@MainActor
final class MinimapMarkCache {
    private(set) var marks: [Int: [MinimapMark]] = [:]
    private(set) var revision = 0
    private var highlights: [StudyHighlight] = []
    private var notes: [StudyNote] = []
    private var annotations = true
    private var colors: [RGBA] = []
    private var matches: [PDFSelection] = []
    private var measured: [(pageIndex: Int, rect: CGRect)] = []
    private weak var document: PDFDocument?

    func update(store: StudyStore, colors theme: WorkbenchColors) -> [Int: [MinimapMark]] {
        let highlights = store.workspace?.highlights ?? [], notes = store.workspace?.notes ?? []
        let annotations = store.reader.showAnnotations
        let colors = [theme.rgba(.minimapWarningHighlight), theme.rgba(.focusBorder), theme.rgba(.minimapFindMatchHighlight)]
        let results = store.reader.searchResults.prefix(2000)
        var changed = false
        if store.document !== document { document = store.document; matches = []; measured = []; changed = true }
        // Results grow in batches while a search runs: the matches already measured are kept.
        let extends = results.count >= matches.count && (matches.isEmpty || (results[results.startIndex] === matches[0]
            && results[results.startIndex + matches.count - 1] === matches[matches.count - 1]))
        if !extends { matches = []; measured = []; changed = true }
        if results.count > matches.count, let document {
            for match in results.dropFirst(matches.count) {
                for page in match.pages { measured.append((document.index(for: page), match.bounds(for: page))) }
            }
            matches = Array(results); changed = true
        }
        if !highlights.sharesStorage(with: self.highlights) { self.highlights = highlights; changed = true }
        if !notes.sharesStorage(with: self.notes) { self.notes = notes; changed = true }
        if annotations != self.annotations { self.annotations = annotations; changed = true }
        if colors != self.colors { self.colors = colors; changed = true }
        guard changed else { return marks }
        var marks: [Int: [MinimapMark]] = [:]
        if annotations {
            for highlight in highlights {
                for region in highlight.regions {
                    marks[highlight.pageIndex, default: []].append(MinimapMark(pageIndex: highlight.pageIndex, rect: region.rect, color: highlight.nativeColor.withAlphaComponent(0.85), full: false))
                }
            }
        }
        for note in notes {
            let unclear = note.isQuickMark
            marks[note.anchor.pageIndex, default: []].append(MinimapMark(pageIndex: note.anchor.pageIndex, rect: note.anchor.region.rect,
                                                                         color: unclear ? theme.ns(.minimapWarningHighlight) : theme.ns(.focusBorder).withAlphaComponent(0.7), full: true))
        }
        let match = theme.ns(.minimapFindMatchHighlight)
        for found in measured { marks[found.pageIndex, default: []].append(MinimapMark(pageIndex: found.pageIndex, rect: found.rect, color: match, full: false)) }
        self.marks = marks
        revision &+= 1
        return marks
    }
}

struct MinimapMark: Equatable {
    let pageIndex: Int
    let rect: CGRect
    let color: NSColor
    /// Spans the miniature's width (a note), rather than the marked text only.
    let full: Bool
}

private struct MinimapSurface: NSViewRepresentable {
    let store: StudyStore
    let marks: [Int: [MinimapMark]]
    let marksRevision: Int
    let pageThemeRevision: Int
    let themeRevision: Int
    let colors: WorkbenchColors
    let sliderAlways: Bool

    func makeNSView(context: Context) -> MinimapView {
        let view = MinimapView()
        view.controller = store.reader
        return view
    }

    func updateNSView(_ view: MinimapView, context: Context) {
        view.controller = store.reader
        view.colors = colors
        if view.pageThemeRevision != pageThemeRevision { view.pageThemeRevision = pageThemeRevision; view.clearCache() }
        var changed = false
        if view.marksRevision != marksRevision { view.marks = marks; view.marksRevision = marksRevision; changed = true }
        if view.themeRevision != themeRevision { view.themeRevision = themeRevision; changed = true }
        if view.sliderAlways != sliderAlways { view.sliderAlways = sliderAlways; changed = true }
        view.attach()
        view.refresh(redraw: changed)
    }
}

final class MinimapView: NSView {
    weak var controller: ReaderController?
    /// Marks by page; `marksRevision` changes with them, so they are never compared.
    var marks: [Int: [MinimapMark]] = [:]
    var marksRevision = -1
    var colors: WorkbenchColors?
    var themeRevision = -1
    /// VS Code shows the slider only while the pointer is over the minimap (`editor.minimap.showSlider: mouseover`);
    /// themes colour it for that (Light 2026's is 75 % opaque), so drawn all the time it hid the miniatures.
    var sliderAlways = false
    /// The miniatures are drawn in the page theme; a new theme renders them again.
    var pageThemeRevision = -1
    /// The miniatures, their marks and the current page's outline, drawn for a stretch of the strip three views tall and
    /// moved as the reader scrolls: the strip is drawn again only when the view reaches the end of that stretch, or when
    /// what it shows changes. The slider is a layer moved on its own.
    private let canvas = MinimapCanvas()
    private let slider = MinimapSlider()
    /// Where the drawn stretch starts in the strip, and the current page it outlined.
    private var canvasTop: CGFloat = 0
    private var canvasPage = -1
    private var cache: [Int: NSImage] = [:]
    private weak var cachedDocument: PDFDocument?
    private weak var observedClip: NSClipView?
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    private var hovering = false
    private var dragging: (start: CGFloat, fraction: CGFloat, fractionPerPoint: CGFloat)?
    private var tracking: NSTrackingArea?
    nonisolated(unsafe) private var navigationTimer: Timer?
    private var pendingFraction: CGFloat?
    private var renderTask: Task<Void, Never>?
    private var renderGeneration = 0
    /// Pages whose miniature could not be made, not tried again until the cache is cleared: a page that never renders
    /// must not keep the minimap drawing and rendering in a loop.
    private var unrenderable: Set<Int> = []

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // The canvas is three views tall: only the part over the minimap may show.
        clipsToBounds = true
        canvas.owner = self
        addSubview(canvas)
        addSubview(slider)
    }
    required init?(coder: NSCoder) { nil }

    deinit {
        navigationTimer?.invalidate()
        renderTask?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func clearCache() {
        renderGeneration &+= 1
        renderTask?.cancel(); renderTask = nil
        cache.removeAll(); unrenderable = []
        refresh(redraw: true)
    }

    /// Something the strip shows changed (marks, colours): draw it again.
    func redraw() { refresh(redraw: true) }

    /// Follows the PDF view's scrolling.
    func attach() {
        guard let clip = controller?.view?.documentView?.enclosingScrollView?.contentView, clip !== observedClip else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observedClip = clip
        clip.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Moves the drawn strip and the slider to the reader's position; draws the strip again only when the view leaves the
    /// stretch it covers, the current page changed, or `redraw` asks for it.
    func refresh(redraw: Bool = false) {
        guard let document, let viewport else { canvas.isHidden = true; slider.isHidden = true; return }
        if cachedDocument !== document {
            cachedDocument = document
            renderGeneration &+= 1; renderTask?.cancel(); renderTask = nil; cache.removeAll(); unrenderable = []
        }
        canvas.isHidden = false
        let offset = viewport.offset, height = max(bounds.height, 1)
        let page = (controller?.pageNumber ?? 0) - 1
        var stale = redraw || page != canvasPage || canvas.frame.width != bounds.width || canvas.frame.height != height * 3
        if offset < canvasTop || offset + height > canvasTop + height * 3 { stale = true }
        if stale {
            canvasTop = max(0, offset - height)
            canvasPage = page
            canvas.frame = CGRect(x: 0, y: canvasTop - offset, width: bounds.width, height: height * 3)
            canvas.redraw()
        } else if canvas.frame.minY != canvasTop - offset {
            canvas.setFrameOrigin(CGPoint(x: 0, y: canvasTop - offset))
        }
        let showSlider = sliderAlways || hovering || dragging != nil
        slider.isHidden = !showSlider
        if showSlider, let colors {
            let key: TC = dragging != nil ? .minimapSliderActiveBackground : hovering ? .minimapSliderHoverBackground : .minimapSliderBackground
            slider.color = colors.ns(key)
            let frame = CGRect(x: 0, y: viewport.sliderTop, width: bounds.width, height: viewport.sliderHeight)
            if slider.frame != frame { slider.frame = frame }
        }
        renderVisibleMiniatures()
    }

    override func layout() {
        super.layout()
        refresh()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }

    // MARK: Geometry

    private var document: PDFDocument? { controller?.view?.document }
    private let margin: CGFloat = 6
    private let gap: CGFloat = 4

    /// The height of one page miniature (pages share the first page's proportions, as books do).
    private var pageHeight: CGFloat {
        guard let page = document?.page(at: 0) else { return 100 }
        let size = page.bounds(for: .cropBox).size
        let rotated = page.rotation % 180 != 0
        let ratio = rotated ? size.width / max(size.height, 1) : size.height / max(size.width, 1)
        return (bounds.width - margin * 2) * ratio
    }
    private var stride: CGFloat { pageHeight + gap }
    private var contentHeight: CGFloat { CGFloat(document?.pageCount ?? 0) * stride + gap }

    /// The visible part of the document, as fractions of its height (top, bottom).
    private var visibleFractions: (CGFloat, CGFloat)? {
        guard let view = controller?.view, let documentView = view.documentView, let clip = documentView.enclosingScrollView?.contentView else { return nil }
        let height = documentView.bounds.height
        guard height > 0 else { return nil }
        if view.displayMode == .singlePage || view.displayMode == .twoUp {
            let count = CGFloat(max(document?.pageCount ?? 1, 1))
            let index = CGFloat((controller?.pageNumber ?? 1) - 1)
            return (index / count, (index + (view.displayMode == .twoUp ? 2 : 1)) / count)
        }
        let rect = clip.bounds
        if documentView.isFlipped { return (rect.minY / height, rect.maxY / height) }
        return (1 - rect.maxY / height, 1 - rect.minY / height)
    }

    private var viewport: MinimapViewport? {
        guard let (top, bottom) = visibleFractions else { return nil }
        return MinimapViewport(contentHeight: contentHeight, height: bounds.height, top: top, bottom: bottom)
    }

    /// The thumbnail strip and its slider use the same mapping, including the slider's minimum height.
    private var offset: CGFloat { viewport?.offset ?? 0 }

    // MARK: Drawing

    /// Draws the miniatures of the canvas's stretch of the strip (in the canvas's coordinates, `canvasTop` at its top).
    fileprivate func drawCanvas(_ dirtyRect: NSRect) {
        QAPerf.tick("Minimap.draw")
        guard let document, let colors else { return }
        let top = canvasTop + dirtyRect.minY, bottom = canvasTop + dirtyRect.maxY
        let first = max(0, Int((top - gap) / stride))
        let last = min(document.pageCount - 1, Int(bottom / stride))
        guard first <= last else { return }
        var missing: [Int] = []
        let width = bounds.width - margin * 2
        for index in first...last {
            let rect = CGRect(x: margin, y: gap + CGFloat(index) * stride - canvasTop, width: width, height: pageHeight)
            if let image = cache[index] {
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                (PageThemeState.shared.theme.isDark ? NSColor(white: 0.16, alpha: 1) : NSColor.white).setFill()
                NSBezierPath(rect: rect).fill()
                missing.append(index)
            }
            if index == canvasPage {
                colors.ns(.focusBorder).withAlphaComponent(0.55).setStroke()
                let path = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1)); path.lineWidth = 1; path.stroke()
            }
            drawMarks(onPage: index, in: rect, document: document)
        }
        if !missing.isEmpty { renderVisibleMiniatures() }
    }

    private func drawMarks(onPage index: Int, in rect: CGRect, document: PDFDocument) {
        guard let page = document.page(at: index) else { return }
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return }
        for mark in marks[index] ?? [] {
            // Page space has its origin at the bottom left; the minimap is flipped.
            let x = rect.minX + (mark.rect.minX - box.minX) / box.width * rect.width
            let y = rect.minY + (box.maxY - mark.rect.maxY) / box.height * rect.height
            let height = max(1.5, mark.rect.height / box.height * rect.height)
            let markRect = mark.full ? CGRect(x: rect.maxX - 3, y: y, width: 3, height: max(3, height))
                : CGRect(x: x, y: y, width: max(2, mark.rect.width / box.width * rect.width), height: height)
            mark.color.setFill()
            NSBezierPath(rect: markRect).fill()
        }
    }

    /// The miniatures on screen not made yet (or that could not be made).
    private func missingVisibleMiniatures() -> [Int] {
        guard let document, document.pageCount > 0, stride > 0 else { return [] }
        let first = max(0, Int((offset - gap) / stride)), last = min(document.pageCount - 1, Int((offset + bounds.height) / stride))
        guard first <= last else { return [] }
        return (first...last).filter { miniatureIsVisible($0) && cache[$0] == nil && !unrenderable.contains($0) }
    }

    /// Rasterizes the miniatures on screen, off the main thread at utility priority, a few at a time, once each (they
    /// are cached); then the pages scrolled to next, as they come into view. Each copy takes a fraction of a
    /// millisecond; rendering six cold pages on the main queue used to block scrolling for tens to hundreds of
    /// milliseconds. Nothing runs once the miniatures on screen exist: the minimap is idle at rest.
    private func renderVisibleMiniatures() {
        guard renderTask == nil, let document else { return }
        let indexes = missingVisibleMiniatures()
        guard !indexes.isEmpty else { return }
        let generation = renderGeneration
        let scale = window?.backingScaleFactor ?? 2
        let size = CGSize(width: (bounds.width - margin * 2) * scale, height: pageHeight * scale)
        renderTask = Task { @MainActor [weak self, weak document] in
            for index in indexes.prefix(6) {
                guard !Task.isCancelled, let self, self.renderGeneration == generation, let document, self.document === document else { return }
                // A fast drag may have moved the minimap while a previous page was rendering: skip what left the screen.
                guard self.miniatureIsVisible(index), self.cache[index] == nil else { continue }
                guard let page = document.page(at: index), let snapshot = MinimapPageSnapshot(page: page) else { self.unrenderable.insert(index); continue }
                let worker = Task.detached(priority: .utility) { snapshot.render(size: size) }
                let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, self.renderGeneration == generation, self.document === document else { return }
                if let result { self.cache[index] = NSImage(cgImage: result.image, size: .zero) } else { self.unrenderable.insert(index) }
                if self.cache.count > 160, let current = self.controller?.pageNumber {
                    for key in self.cache.keys where abs(key - (current - 1)) > 60 { self.cache.removeValue(forKey: key) }
                }
                self.canvas.redraw(self.canvasRect(of: index))
            }
            guard let self, self.renderGeneration == generation else { return }
            self.renderTask = nil
            // More pages may have come into view meanwhile; stops when every miniature on screen exists.
            self.renderVisibleMiniatures()
        }
    }

    private func miniatureIsVisible(_ index: Int) -> Bool {
        let top = gap + CGFloat(index) * stride - offset
        return top < bounds.maxY && top + pageHeight > bounds.minY
    }

    /// A miniature's rectangle in the canvas, with room for its outline.
    private func canvasRect(of index: Int) -> CGRect {
        CGRect(x: 0, y: gap + CGFloat(index) * stride - canvasTop, width: bounds.width, height: pageHeight).insetBy(dx: 0, dy: -2)
    }

    // MARK: Interaction

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let viewport else { return }
        controller?.beginScrubbing()
        if !(viewport.sliderTop...(viewport.sliderTop + viewport.sliderHeight)).contains(point.y) { jump(to: point.y) }
        // Clicking a miniature establishes one anchor too; later events must not keep jumping against a moving strip.
        if let viewport = self.viewport {
            dragging = (point.y, viewport.top, viewport.fractionPerPoint)
            refresh()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let drag = dragging else { return }
        let delta = (point.y - drag.start) * drag.fractionPerPoint
        pendingFraction = drag.fraction + delta
        guard navigationTimer == nil else { return }
        // Pointer input can arrive much faster than PDFKit can display it. Navigate to the latest input once
        // per frame; common modes keep the timer running during AppKit's mouse tracking loop.
        let frameRate = max(60, window?.screen?.maximumFramesPerSecond ?? 60)
        let timer = Timer(timeInterval: 1.0 / Double(frameRate), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushNavigation() }
        }
        navigationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func mouseUp(with event: NSEvent) {
        // The release may carry a newer point than the last drag event. Always land there, even before the timer fires.
        if let drag = dragging {
            let point = convert(event.locationInWindow, from: nil)
            pendingFraction = drag.fraction + (point.y - drag.start) * drag.fractionPerPoint
        }
        flushNavigation()
        dragging = nil
        controller?.endScrubbing()
        refresh()
    }

    private func flushNavigation() {
        navigationTimer?.invalidate(); navigationTimer = nil
        guard let fraction = pendingFraction else { return }
        pendingFraction = nil
        scroll(toTopFraction: fraction)
    }

    override func scrollWheel(with event: NSEvent) {
        controller?.view?.documentView?.enclosingScrollView?.scrollWheel(with: event)
    }

    private func jump(to y: CGFloat) {
        let fraction = (y + offset) / max(contentHeight, 1)
        guard let view = controller?.view, let document = document else { return }
        if view.displayMode == .singlePage || view.displayMode == .twoUp {
            let index = min(document.pageCount - 1, max(0, Int(fraction * CGFloat(document.pageCount))))
            controller?.goToPage(index + 1)
            controller?.updatePage()
            return
        }
        if let (top, bottom) = visibleFractions { scroll(toTopFraction: fraction - (bottom - top) / 2) }
    }

    private func scroll(toTopFraction fraction: CGFloat) {
        if let view = controller?.view, view.displayMode == .singlePage || view.displayMode == .twoUp,
           let document, document.pageCount > 0 {
            let index = min(document.pageCount - 1, max(0, Int((fraction * CGFloat(document.pageCount)).rounded())))
            guard index != (controller?.pageNumber ?? 1) - 1 else { return }
            controller?.goToPage(index + 1)
            controller?.updatePage()
            return
        }
        guard let view = controller?.view, let documentView = view.documentView, let scrollView = documentView.enclosingScrollView else { return }
        let clip = scrollView.contentView
        let height = documentView.bounds.height
        let clamped = min(max(0, fraction), 1) * height
        let maximum = max(0, height - clip.bounds.height)
        let y = documentView.isFlipped ? min(clamped, maximum) : max(0, height - clamped - clip.bounds.height)
        // Moving the clip view alone leaves PDFKit's currentPage/currentDestination on the old page.
        // Navigate through PDFKit so the status bar, bookmarks and saved reading position move with the page.
        let top = CGPoint(x: clip.bounds.minX, y: documentView.isFlipped ? y : y + clip.bounds.height)
        let point = view.convert(top, from: documentView)
        guard let page = view.page(for: point, nearest: true) else { return }
        view.go(to: PDFDestination(page: page, at: view.convert(point, to: page)))
        controller?.updatePage()
    }
}

/// The minimap's drawn stretch of miniatures, three views tall. It hosts its own layer, drawn whole when asked: a view
/// drawn by AppKit is drawn only where it shows, so moving it under the minimap would draw the strip it uncovers on every
/// scroll frame. It takes no clicks: the minimap handles them.
private final class MinimapCanvas: NSView {
    private final class StripLayer: CALayer {
        nonisolated(unsafe) weak var owner: MinimapView?
        override func draw(in context: CGContext) {
            // The minimap's coordinates run down from the top, as its miniatures are laid out (under a flipped view
            // Core Animation has already turned the context).
            if !contentsAreFlipped() { context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1) }
            // Core Animation displays the minimap's layers on the main thread, in its transaction.
            nonisolated(unsafe) let context = context
            nonisolated(unsafe) let owner = owner
            MainActor.assumeIsolated {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                owner?.drawCanvas(context.boundingBoxOfClipPath)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    private let strip = StripLayer()
    weak var owner: MinimapView? { didSet { strip.owner = owner } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        strip.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "hidden": NSNull()]
        strip.needsDisplayOnBoundsChange = true
        layer = strip
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        strip.contentsScale = window?.backingScaleFactor ?? 2
        strip.setNeedsDisplay()
    }

    /// Draws the whole stretch again.
    func redraw() { strip.contentsScale = window?.backingScaleFactor ?? strip.contentsScale; strip.setNeedsDisplay() }
    /// Draws one part again (a rectangle in this view's coordinates, from the top).
    func redraw(_ rect: CGRect) {
        strip.setNeedsDisplay(strip.contentsAreFlipped() ? rect : CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height))
    }
}

/// The minimap's slider: a coloured layer over the miniatures, moved without redrawing them.
private final class MinimapSlider: NSView {
    var color: NSColor = .clear { didSet { if color != oldValue { needsDisplay = true } } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = color.cgColor }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Dragging is measured over the slider's on-screen travel, not over the entire miniature strip.
private struct MinimapViewport {
    let contentHeight: CGFloat
    let height: CGFloat
    let top: CGFloat
    let bottom: CGFloat
    private var span: CGFloat { min(1, max(0, bottom - top)) }
    private var trackHeight: CGFloat { min(contentHeight, height) }
    var sliderHeight: CGFloat { min(trackHeight, max(6, span * contentHeight)) }
    private var travel: CGFloat { max(0, trackHeight - sliderHeight) }
    var sliderTop: CGFloat { min(1, max(0, top / max(1 - span, 0.0001))) * travel }
    var offset: CGFloat { contentHeight > height ? max(0, top * contentHeight - sliderTop) : 0 }
    var fractionPerPoint: CGFloat { travel > 0 ? (1 - span) / travel : 0 }
}

/// Ownership crosses the thread boundary only for a page copy, never a PDFPage attached to the reader.
/// Copies retain the page subclass, rotation and annotations; the worker alone reads this snapshot.
struct MinimapPageSnapshot: @unchecked Sendable {
    private let page: PDFPage
    @MainActor init?(page: PDFPage) {
        guard let copy = page.copy() as? PDFPage else { return nil }
        self.page = copy
    }
    nonisolated func render(size: CGSize) -> MinimapThumbnail? {
        guard !Task.isCancelled else { return nil }
        return autoreleasepool {
            let image = page.thumbnail(of: size, for: .cropBox)
            guard !Task.isCancelled, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            return MinimapThumbnail(image: cg)
        }
    }
}

/// CGImage is immutable; no AppKit view or mutable image is shared with the worker.
struct MinimapThumbnail: @unchecked Sendable { let image: CGImage }
