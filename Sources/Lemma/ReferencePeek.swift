import SwiftUI
import AppKit
import PDFKit
import LemmaCore

struct ReferencePeekRequest: Identifiable, Equatable {
    let id = UUID()
    let workspaceID: String
    let mention: PageMention
    /// The page where the reader clicked the mention.
    let pageIndex: Int
}

/// Presented from the PDF view so the clicked mention anchors the peek.
@MainActor
final class ReferencePeekPopover: NSObject, NSPopoverDelegate {
    let popover = NSPopover()
    /// The VS Code style's peek view, used instead of the popover.
    let panel = VSFloatingPanel()
    /// The preview's size, shared by the peek and the edges it is resized from.
    let frame = PeekPreviewFrame()
    private weak var store: StudyStore?
    let requestID: UUID
    /// The reference it previews: Shift-clicking it again brings this peek forward rather than opening another.
    let key: ReferenceKey
    /// The mention the popover points at, on screen.
    private var anchor: CGRect?
    /// Kept open while the reader works on (moved, dragged away, or opened or left open by a Shift-click): clicks
    /// elsewhere, other peeks and scrolling leave it until its close button.
    private(set) var isKept = false
    /// Follows the peek being kept, and its closing.
    var onKept: (() -> Void)?
    var onClosed: (() -> Void)?
    /// Places a peek opened beside others as its preview loads and the peek takes its size, until the reader moves or
    /// resizes it.
    var autoPlace: (() -> Void)?
    private var monitors: [Any] = []

    var isShown: Bool { popover.isShown || panel.isShown }
    func close() {
        if popover.isShown { popover.close() }
        panel.close()
    }

    /// Keeps the peek open beside the reader's work, until its close button.
    func keep() {
        guard !isKept else { return }
        isKept = true
        frame.kept = true
        panel.keep()
        removeMonitors()
        onKept?()
    }

    func bringForward() {
        panel.orderFront()
        if popover.isShown { popover.contentViewController?.view.window?.orderFront(nil) }
    }

    private func removeMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    init(store: StudyStore, request: ReferencePeekRequest, sizing: PeekSizing) {
        self.store = store; self.requestID = request.id; self.key = request.mention.key
        super.init()
        let pane = ReferencePeekPane(store: store, request: request, sizing: sizing, frame: frame).tint(.lemmaOlive)
            .fixedSize()
            .overlay { PeekResizeEdges(frame: frame, sizing: sizing, roundedCorners: true) }
            // Set after the layout pass that measured it: SwiftUI resizing the popover's window from inside its own
            // layout could recurse until the stack ran out, as a crash report showed with the peek dragged away.
            .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                DispatchQueue.main.async { self?.fitPopover(size) }
            }
        let controller = NSHostingController(rootView: pane)
        controller.sizingOptions = []
        popover.contentViewController = controller
        // The popover opens at its preview's size: placed at a size it then outgrew, it hung off the screen's edge.
        popover.contentSize = controller.sizeThatFits(in: CGSize(width: 10_000, height: 10_000))
        // It closes itself on a click elsewhere (show(relativeTo:of:)): a transient popover would close on the Shift-click
        // that opens another peek beside it, before the click reached the page.
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        // Anchored, the popover is centred on its mention, so its right edge moves half as far as its width changes.
        frame.widthGain = { [weak self] in self?.popover.isDetached == true ? 1 : 2 }
        panel.onClose = { [weak self] in
            guard let self else { return }
            if self.store?.referencePeek?.id == self.requestID { self.store?.referencePeek = nil }
            self.onClosed?()
        }
        panel.closesOnClick = { !$0.modifierFlags.contains(.shift) }
        frame.close = { [weak self] in self?.close() }
    }

    /// Shows the popover under its mention, `rect` in `view`, or above it when there is no room below.
    func show(relativeTo rect: CGRect, of view: NSView) {
        anchor = view.window?.convertToScreen(view.convert(rect, to: nil))
        popover.show(relativeTo: rect, of: view, preferredEdge: .minY)
        placeEdges()
        // As a transient popover, it closes on a click elsewhere and on Escape in the reader's window, unless it is kept;
        // a Shift-click opens another peek beside it.
        let window = view.window
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, !self.isKept, self.popover.isShown, event.window !== self.popover.contentViewController?.view.window,
                  !event.modifierFlags.contains(.shift) else { return event }
            self.close()
            return event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, !self.isKept, self.popover.isShown, let window, event.window === window,
                  NSApp.modalWindow == nil, window.attachedSheet == nil, !(window.firstResponder is NSText) else { return event }
            self.close()
            return nil
        } as Any)
    }

    /// The popover follows its content as the preview loads and as the reader resizes it. Dragged away, it keeps its top
    /// edge, as a window does; it would otherwise keep its bottom edge and grow away from the pointer. The popover's
    /// content is measured in the VS Code style too, where the popover is never shown, so it sizes only the popover.
    private func fitPopover(_ size: CGSize) {
        guard size.width > 0, size.height > 0,
              abs(size.width - popover.contentSize.width) > 0.5 || abs(size.height - popover.contentSize.height) > 0.5 else { return }
        let window = popover.isDetached ? popover.contentViewController?.view.window : nil
        let topLeft = window.map { NSPoint(x: $0.frame.minX, y: $0.frame.maxY) }
        popover.contentSize = size
        if let window, let topLeft { window.setFrameTopLeftPoint(topLeft) }
        placeEdges()
    }

    /// The VS Code style's peek view follows its chrome and preview, measured together.
    func fitPanel(_ size: CGSize) {
        panel.fit(size)
        placeEdges()
        if frame.resized == nil { autoPlace?() }
    }

    /// A peek above its mention keeps the edge next to the mention, so the reader resizes it by its top edge, the one
    /// that moves; below its mention or dragged away, by its bottom edge.
    func placeEdges() {
        let above: Bool
        if panel.isShown {
            above = panel.isAbove
        } else if !popover.isDetached, let anchor, let window = popover.contentViewController?.view.window {
            above = window.frame.midY > anchor.midY
        } else {
            above = false
        }
        if frame.fromTop != above { frame.fromTop = above }
    }

    /// Dragged away from its mention, the peek becomes a window of its own that stays open while the reader works on.
    func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }

    func popoverDidDetach(_ popover: NSPopover) { keep(); placeEdges() }

    func popoverDidClose(_ notification: Notification) {
        removeMonitors()
        if store?.referencePeek?.id == requestID { store?.referencePeek = nil }
        onClosed?()
    }
}

@MainActor
extension RegionPDFView {
    /// Opens the peek at its mention. A kept peek (`keep`, a Shift-click) opens beside the peeks already open and keeps
    /// the one open before it, so several stay in sight; the same reference again brings its peek forward.
    func presentReferencePeek(_ request: ReferencePeekRequest, store: StudyStore, keep: Bool = false) {
        guard window?.isVisible == true else { return }
        if keep {
            if let current = referencePopover, current.isShown { current.keep() }
            if let open = keptReferencePeeks.first(where: { $0.key == request.mention.key && $0.isShown }) { open.bringForward(); return }
        }
        dismissReferencePeek()
        dismissDefinitionLookup()
        var anchor = CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
        if let page = document?.page(at: request.pageIndex), let first = request.mention.rects.first {
            let rect = convert(first, from: page).intersection(bounds)
            if !rect.isNull, !rect.isEmpty { anchor = rect }
        }
        let vscode = ThemeManager.shared.style == .vscode
        let sizing = PeekSizing(reading: self, popover: !vscode)
        let presentation = ReferencePeekPopover(store: store, request: request, sizing: sizing)
        presentation.onKept = { [weak self, weak presentation, weak store] in
            guard let self, let presentation else { return }
            if self.referencePopover === presentation { self.referencePopover = nil }
            if !self.keptReferencePeeks.contains(where: { $0 === presentation }) { self.keptReferencePeeks.append(presentation) }
            if store?.referencePeek?.id == presentation.requestID { store?.referencePeek = nil }
        }
        presentation.onClosed = { [weak self, weak presentation] in
            self?.keptReferencePeeks.removeAll { $0 === presentation || !$0.isShown }
        }
        referencePopover = presentation
        if vscode {
            // VS Code's peek view: under the line, with a title bar and the peek frame, as wide as its preview. It keeps
            // its left edge as it widens.
            presentation.frame.widthGain = { 1 }
            let line = CGRect(x: max(bounds.minX + 16, anchor.minX - 40), y: anchor.minY, width: 1, height: anchor.height)
            let key = request.mention.key
            let page = store.references?.knownTarget(key).map { store.pageText($0.pageIndex) } ?? ""
            let chrome = VSPeekChrome(icon: Self.peekIcon(key.kind), title: key.kind == .citation ? (key.name ?? key.title) : key.spokenTitle,
                                      description: page, moveHelp: Self.keepHelp) {
                VSIconButton(icon: "close", help: "Close (Escape)") { presentation.close() }
            } content: {
                ReferencePeekPane(store: store, request: request, sizing: sizing, frame: presentation.frame, chromeless: true).padding(12)
            } onMoved: { [weak presentation] in presentation?.autoPlace = nil; presentation?.keep() }
            // The panel follows the peek's size as its preview loads and as the reader resizes it, after the layout pass
            // that measured it.
            .fixedSize()
            .overlay { PeekResizeEdges(frame: presentation.frame, sizing: sizing, roundedCorners: false) }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak presentation] size in
                DispatchQueue.main.async { presentation?.fitPanel(size) }
            }
            let room = window.map { $0.contentLayoutRect.height } ?? bounds.height
            presentation.panel.show(chrome, anchor: line, in: self, placement: .below, interactive: true,
                                    maxWidth: .greatestFiniteMagnitude, maxHeight: room, resizable: true)
            presentation.placeEdges()
            if keep {
                presentation.keep()
                presentation.autoPlace = { [weak self, weak presentation] in
                    if let self, let presentation { self.placeBesideKeptPeeks(presentation) }
                }
                placeBesideKeptPeeks(presentation)
            }
            return
        }
        presentation.show(relativeTo: anchor, of: self)
        if keep { presentation.keep() }
    }

    /// A peek opened beside others goes where it covers none of them: right of the one it would cover, else left of it,
    /// below or above it, inside the window. Failing that, it steps down and right of it, so that each title bar shows.
    private func placeBesideKeptPeeks(_ presentation: ReferencePeekPopover) {
        guard let window, let mine = presentation.panel.frame else { return }
        let others = keptReferencePeeks.filter { $0 !== presentation && $0.isShown }.compactMap(\.panel.frame)
        guard let covered = others.first(where: { $0.intersects(mine) }) else { return }
        let screen = window.screen?.visibleFrame ?? .infinite
        let area = window.convertToScreen(window.contentLayoutRect).intersection(screen)
        let gap: CGFloat = 8
        let candidates = [CGPoint(x: covered.maxX + gap, y: covered.maxY - mine.height), CGPoint(x: covered.minX - gap - mine.width, y: covered.maxY - mine.height),
                          CGPoint(x: covered.minX, y: covered.minY - gap - mine.height), CGPoint(x: covered.minX, y: covered.maxY + gap)]
        var target: CGPoint
        if let free = candidates.map({ CGRect(origin: $0, size: mine.size) }).first(where: { rect in
            area.contains(rect) && !others.contains { $0.intersects(rect) }
        }) {
            target = free.origin
        } else {
            // Its top stays below the other's title bar, so both titles show, even if its bottom must leave the window.
            target = CGPoint(x: max(area.minX, min(covered.minX + 24, area.maxX - mine.width)), y: covered.maxY - 30 - mine.height)
        }
        presentation.panel.move(by: CGSize(width: target.x - mine.minX, height: target.y - mine.minY))
    }

    /// What moving or Shift-clicking does, said where the reader would try it.
    static let keepHelp = "Drag to move it; it then stays open. ⇧-click another reference to open it beside this one."

    /// The peek's title icon, as the Go to list shows each kind.
    static func peekIcon(_ kind: ReferenceKind) -> String {
        switch kind {
        case .citation: "book"
        case .equation: "symbol-numeric"
        case .figure, .chart: "file-media"
        case .table: "table"
        case .box: "symbol-structure"
        case .algorithm: "symbol-method"
        case .exercise: "tasklist"
        case .theorem: "verified"
        case .section, .chapter, .specialFeature: "symbol-class"
        case .link: "link"
        }
    }

    func dismissReferencePeek() {
        referencePopover?.panel.onClose = nil
        referencePopover?.close()
        referencePopover = nil
    }

    /// Closes the peeks kept open: they belong to the book on the page, and to this view's window.
    func closeKeptReferencePeeks() {
        let kept = keptReferencePeeks
        keptReferencePeeks.removeAll()
        for peek in kept { peek.onClosed = nil; peek.close() }
    }
}

/// How large a peek's preview of the page is. It opens with the page at 85% of the reader's zoom, a little smaller than
/// the text being read, within 70% of the reader's window across and 65% of it down; the reader resizes it from its right
/// edge, its bottom edge or its corner.
struct PeekSizing: Equatable {
    /// The reader's zoom.
    var scale: CGFloat
    /// The largest preview a peek opens with.
    var opening: CGSize
    /// The largest preview the reader can resize it to: the window, or for a popover, the screen.
    var largest: CGSize

    /// The share of the reader's zoom a peek opens with.
    static let share: CGFloat = 0.85
    /// The smallest the reader can make the preview.
    static let smallest = CGSize(width: 160, height: 90)
    /// Room around the preview for the peek's padding, title, buttons and caption.
    static let surroundings = CGSize(width: 52, height: 120)
    /// The page gap at both sides of the preview together (PeekPDFSurface).
    static let sides: CGFloat = 12

    init(scale: CGFloat, opening: CGSize, largest: CGSize) {
        self.scale = scale; self.opening = opening; self.largest = largest
    }

    /// A popover may grow to its screen; VS Code's peek view stays in the window.
    @MainActor init(reading view: PDFView, popover: Bool) {
        let window = view.window?.contentLayoutRect.size ?? view.bounds.size
        let screen = view.window?.screen?.visibleFrame.size ?? window
        let room = popover ? screen : window
        self.init(scale: view.scaleFactor,
                  opening: CGSize(width: window.width * 0.7 - Self.surroundings.width, height: window.height * 0.65 - Self.surroundings.height),
                  largest: CGSize(width: room.width - Self.surroundings.width - 16, height: room.height - Self.surroundings.height - 16))
    }

    /// The zoom a peek opens with.
    var zoom: CGFloat { scale * Self.share }

    /// As wide as a page of `pageWidth` points at the peek's zoom, within the opening limit. A page narrower than the
    /// smallest preview is centred in it at that zoom rather than enlarged.
    func width(forPage pageWidth: CGFloat) -> CGFloat {
        max(Self.smallest.width, min(pageWidth * zoom + Self.sides, opening.width))
    }

    /// The zoom a page of `pageWidth` points opens at in a preview `width` wide: the peek's zoom, or less when the
    /// page must shrink to fit within the opening limit.
    func zoom(forPage pageWidth: CGFloat, width: CGFloat) -> CGFloat {
        min(zoom, (width - Self.sides) / max(pageWidth, 1))
    }

    /// Wide enough for the target's page at the peek's zoom and tall enough for the referenced item at that zoom.
    func size(for target: ReferenceTarget, in document: PDFDocument) -> CGSize {
        let pageWidth = max(document.page(at: target.pageIndex)?.bounds(for: .cropBox).width ?? 612, 1)
        let width = width(forPage: pageWidth)
        let fitted = zoom(forPage: pageWidth, width: width)
        // At least 92 points of the page show, however far the reader zooms.
        let height = min(max(target.region.rect.height, 92) * fitted + 28, max(opening.height, 110))
        return CGSize(width: width, height: height)
    }

    /// The preview's size after the peek's edge moved by `drag` (screen points, down positive) from a preview of `start`.
    /// A peek that widens on both sides, as a popover centred on its mention does, widens by `widthGain` times as much,
    /// so that its right edge stays under the pointer.
    func resized(_ start: CGSize, by drag: CGSize, widthGain: CGFloat = 1) -> CGSize {
        CGSize(width: min(max(start.width + drag.width * widthGain, Self.smallest.width), max(largest.width, Self.smallest.width)),
               height: min(max(start.height + drag.height, Self.smallest.height), max(largest.height, Self.smallest.height)))
    }
}

/// The size of a peek's preview: the one its target opens at, until the reader resizes the peek.
@MainActor @Observable
final class PeekPreviewFrame {
    /// The size the preview opens at, once its target is found.
    var natural: CGSize?
    /// The size the reader gave it.
    var resized: CGSize?
    /// How much wider the preview grows than the pointer moves: 2 for a popover centred on its mention.
    @ObservationIgnored var widthGain: () -> CGFloat = { 1 }
    /// Resized by its top edge, as a peek above its mention is; by its bottom edge otherwise.
    var fromTop = false
    /// Kept open beside the reader's work: its buttons then leave it open.
    var kept = false
    /// Closes the peek.
    @ObservationIgnored var close: () -> Void = {}
    @ObservationIgnored private var start: CGSize?

    var size: CGSize? { resized ?? natural }

    /// The peek's edge moved by `drag` (growing it, positive) since the drag began.
    func drag(by drag: CGSize, sizing: PeekSizing) {
        guard let from = start ?? size else { return }
        start = from
        resized = sizing.resized(from, by: drag, widthGain: widthGain())
    }

    func endDrag() { start = nil }
}

struct ReferencePeekPane: View {
    @Bindable var store: StudyStore
    let request: ReferencePeekRequest
    let sizing: PeekSizing
    let frame: PeekPreviewFrame
    /// Inside VS Code's peek chrome, which shows the title and the close button.
    var chromeless = false
    @State private var target: ReferenceTarget?
    @State private var finished = false
    @State private var progress: Double?
    private var key: ReferenceKey { request.mention.key }

    /// The preview's width before its target is found: the clicked page's, so the peek keeps its width as it loads.
    private var loadingWidth: CGFloat {
        sizing.width(forPage: max(store.document?.page(at: request.pageIndex)?.bounds(for: .cropBox).width ?? 612, 1))
    }

    private func previewSize(_ target: ReferenceTarget, in document: PDFDocument) -> CGSize {
        frame.size ?? sizing.size(for: target, in: document)
    }

    private var peekWidth: CGFloat { frame.size?.width ?? loadingWidth }

    /// Clicking the defining label itself has nothing to preview elsewhere.
    private var isDefinitionItself: Bool {
        guard let target, target.pageIndex == request.pageIndex else { return false }
        let anchor = target.anchor.rect.insetBy(dx: -1, dy: -1)
        return request.mention.rects.contains { $0.intersects(anchor) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !chromeless {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: key.kind.symbol).foregroundStyle(Color.lemmaOlive)
                Text(key.spokenTitle).font(.headline)
                if let target {
                    Text(store.printedLabel(for: target.pageIndex).map { "p. \($0) · PDF page \(target.pageIndex + 1)" } ?? "PDF page \(target.pageIndex + 1)")
                        .font(.caption).foregroundStyle(.secondary)
                    if let count = store.analysis?.mentionCounts[key], count > 0, key.kind != .citation {
                        Text("· \(count) \(count == 1 ? "reference" : "references")").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { frame.close() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).keyboardShortcut(.cancelAction).accessibilityLabel("Close reference preview")
            }
            .help(frame.kept ? "" : "Drag it away to keep it open. ⇧-click another reference to open it beside this one.")
            }
            content
            if key.kind == .citation, let entry = store.analysis?.bibliographyEntry(key) {
                HStack(spacing: 14) {
                    Button("Copy Reference") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.text, forType: .string)
                        store.status = "Reference copied."
                    }
                    Button("Search Scholar ↗") {
                        var components = URLComponents(string: "https://scholar.google.com/scholar")!
                        components.queryItems = [URLQueryItem(name: "q", value: entry.searchQuery)]
                        if let url = components.url { NSWorkspace.shared.open(url) }
                    }.help("Look the work up on Google Scholar in your browser")
                    Spacer()
                    let citations = store.analysis?.citationCounts[entry.id] ?? 0
                    if citations > 0 { Text("Cited \(citations)× in this book").font(.caption).foregroundStyle(.secondary) }
                }.font(.callout).buttonStyle(.borderless)
                PaperLookupView(store: store, entry: entry)
            }
            HStack(spacing: 14) {
                Button(key.kind == .citation ? "Find Citations" : "Find All References") { leave(); store.showReferences(to: key) }
                    .help("List the places in this book that cite \(key.title) · in the panel below")
                Button("Pin") { if let target { leave(); store.pinReference(target) } }
                    .disabled(target == nil).help("Keep this passage in Context")
                if key.kind == .equation {
                    Button("LaTeX…") { if let target { leave(); store.readFormula(target) } }.disabled(target == nil)
                        .help("Read this formula's LaTeX locally, with the original beside the transcription")
                }
                if [.equation, .algorithm, .figure, .table].contains(key.kind) {
                    Button("Lab") { if let target { leave(); store.sendTargetToLab(target) } }
                        .disabled(target == nil).help("Try \(key.spokenTitle) in a Python notebook beside the page")
                }
                Spacer()
                Button("Open to the Side") { if let target { leave(); store.openToSide(target) } }
                    .disabled(target == nil).help("Keep it in the side editor beside your page · ⌥-click a reference")
                Button("Go to") { if let target { leave(); store.goToReference(target) } }
                    .keyboardShortcut(.defaultAction).disabled(target == nil || isDefinitionItself)
                    .help("Move the reader there. Back returns to this page · ⌥⌘←")
            }.font(.callout).buttonStyle(.borderless)
        }
        .padding(14).frame(width: peekWidth + 28)
        .task(id: request.id) { await resolve() }
    }

    @ViewBuilder private var content: some View {
        if !finished {
            VStack(alignment: .leading, spacing: 8) {
                if let progress { ProgressView(value: progress) } else { ProgressView().controlSize(.small) }
                Text(searchDescription).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        } else if let target, let document = store.document, store.workspace?.id == request.workspaceID {
            if isDefinitionItself {
                Text("This is where \(key.title) is defined. Find mentions lists the passages that refer to it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            let size = previewSize(target, in: document)
            PeekPDFSurface(document: document, target: target, largestScale: sizing.zoom)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                .accessibilityLabel("Live preview of \(key.spokenTitle) on PDF page \(target.pageIndex + 1)")
            Text(originDescription(target)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("No definition found for \(key.title)").font(.callout.weight(.medium))
                Text("Lemma looks for an equation label at the end of a line, a caption, a heading or a PDF link. Find mentions searches the text instead.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        }
    }

    /// A button's action closes the peek, unless the reader kept it open.
    private func leave() { if !frame.kept { frame.close() } }

    private var searchDescription: String {
        if let range = store.references?.chapterRange(for: key) {
            return "Finding \(key.title) in PDF pages \(range.lowerBound + 1)–\(range.upperBound)…"
        }
        return "Finding \(key.title) near this page…"
    }

    private func originDescription(_ target: ReferenceTarget) -> String {
        switch target.origin {
        case .link: "From the PDF’s own link. Scroll the preview for more context."
        case .outline: "From the document outline. Scroll the preview for more context."
        case .text: target.key.kind == .citation ? "From the book’s list of references. Scroll the preview for neighbouring entries."
            : "Found from the label’s position in the text layer. Scroll the preview to check its context."
        }
    }

    private func resolve() async {
        guard let index = store.references, store.workspace?.id == request.workspaceID else { finished = true; return }
        target = await index.resolve(request.mention, from: request.pageIndex) { done, total in
            progress = total > 0 ? Double(done) / Double(total) : nil
        }
        if let target, let document = store.document { frame.natural = sizing.size(for: target, in: document) }
        finished = true
    }
}

/// A small live PDF view scrolled to the referenced region. It shares the reader's document.
struct PeekPDFSurface: NSViewRepresentable {
    let document: PDFDocument
    let target: ReferenceTarget
    /// The peek's zoom, which the page opens at no larger than.
    var largestScale: CGFloat = .greatestFiniteMagnitude
    @AppStorage(LemmaPreferences.pageGap) private var pageGap = LemmaPreferences.pageGapDefault

    func makeNSView(context: Context) -> PeekPDFView {
        let view = PeekPDFView()
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.setPageGap(pageGap, side: PeekSizing.sides / 2)
        view.backgroundColor = .windowBackgroundColor
        view.autoScales = false
        view.document = document
        view.largestScale = largestScale
        view.target = target
        return view
    }

    func updateNSView(_ view: PeekPDFView, context: Context) {
        view.setPageGap(pageGap, side: PeekSizing.sides / 2)
        if view.document !== document { view.document = document }
        if view.target != target { view.target = target }
    }
}

final class PeekPDFView: PDFView {
    var target: ReferenceTarget? { didSet { fittedWidth = nil; needsLayout = true } }
    /// The zoom the page opens at no larger than: a page narrower than the preview is centred in it.
    var largestScale: CGFloat = .greatestFiniteMagnitude
    /// The width the page was last fitted to.
    private var fittedWidth: CGFloat?
    /// The line at the top of the preview before the reader resized it, kept there as the page is fitted again.
    private var pendingTop: (page: PDFPage, y: CGFloat)?

    /// Read before the frame changes: a taller preview keeps its bottom edge, so afterwards another line is at the top.
    override func setFrameSize(_ newSize: NSSize) {
        if fittedWidth != nil, pendingTop == nil, newSize != frame.size {
            let edge = CGPoint(x: bounds.midX, y: isFlipped ? bounds.minY + 1 : bounds.maxY - 1)
            pendingTop = page(for: edge, nearest: true).map { ($0, convert(edge, to: $0).y) }
        }
        super.setFrameSize(newSize)
    }

    /// The page's width fills the preview, up to the peek's zoom, with the referenced item at the top. Made wider or
    /// narrower, the page fills the new width with the same line at the top; made only taller, it keeps its zoom.
    override func layout() {
        super.layout()
        guard let target, bounds.width > 20, let page = document?.page(at: target.pageIndex) else { return }
        if let fittedWidth {
            guard let top = pendingTop else { return }
            pendingTop = nil
            if abs(bounds.width - fittedWidth) > 0.5 {
                self.fittedWidth = bounds.width
                scaleFactor = scaleFactorForSizeToFit
                layoutDocumentView()
            }
            go(to: PDFDestination(page: top.page, at: CGPoint(x: top.page.bounds(for: .cropBox).minX, y: top.y)))
            return
        }
        fittedWidth = bounds.width
        scaleFactor = min(scaleFactorForSizeToFit, largestScale)
        layoutDocumentView()
        let region = target.region.rect
        go(to: PDFDestination(page: page, at: CGPoint(x: region.minX, y: min(region.maxY + 8, page.bounds(for: .cropBox).maxY))))
    }
}

/// The edges a peek is resized from, at the outside of its window as on any window: the right edge, the edge across
/// that moves (the bottom one, or the top one for a peek above its mention) and the corner between them, which shows a
/// grip. Each reaches a few points further in than it looks, to be easy to catch.
struct PeekResizeEdges: View {
    let frame: PeekPreviewFrame
    let sizing: PeekSizing
    /// The peek's window has rounded corners, as a popover does, rather than VS Code's square ones.
    let roundedCorners: Bool

    var body: some View {
        PeekResizeArea(active: frame.size != nil, fromTop: frame.fromTop, roundedCorners: roundedCorners) {
            frame.drag(by: $0, sizing: sizing)
        } onEnd: { frame.endDrag() }
    }
}

/// One AppKit view over the whole peek that takes the pointer only along the edges it is resized by and in their
/// corner, and lets every other click through to the peek.
struct PeekResizeArea: NSViewRepresentable {
    let active: Bool
    let fromTop: Bool
    let roundedCorners: Bool
    let onDrag: (CGSize) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> PeekResizeAreaView { PeekResizeAreaView() }
    func updateNSView(_ view: PeekResizeAreaView, context: Context) {
        view.onDrag = onDrag; view.onEnd = onEnd
        if view.active != active { view.active = active }
        if view.fromTop != fromTop { view.fromTop = fromTop }
        if view.roundedCorners != roundedCorners { view.roundedCorners = roundedCorners }
    }
}

final class PeekResizeAreaView: NSView {
    enum Edge { case right, top, bottom, topRight, bottomRight }
    /// How far in from the edge the pointer catches it, and the size of the corner.
    static let band: CGFloat = 8
    static let corner: CGFloat = 22

    var active = false { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    /// Resized by its top edge and top-right corner rather than its bottom ones.
    var fromTop = false { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    /// The peek's window has rounded corners, which the grip keeps inside.
    var roundedCorners = true { didSet { needsDisplay = true } }
    /// The edges the peek is resized by: the corner first, as it overlaps the edges' ends.
    var edges: [Edge] { fromTop ? [.topRight, .right, .top] : [.bottomRight, .right, .bottom] }
    var onDrag: (CGSize) -> Void = { _ in }
    var onEnd: () -> Void = {}
    private var dragging: (edge: Edge, start: NSPoint)?

    override var isFlipped: Bool { true }
    /// A drag here resizes the peek: it must not move the popover, or drag it away from its mention.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Where the pointer catches `edge`. The top-right corner keeps to the outer band of each edge, clear of the close
    /// button in the corner of the peek's title bar.
    func rects(of edge: Edge) -> [CGRect] {
        switch edge {
        case .topRight: [CGRect(x: bounds.maxX - Self.corner, y: 0, width: Self.corner, height: Self.band),
                         CGRect(x: bounds.maxX - Self.band, y: 0, width: Self.band, height: Self.corner)]
        case .bottomRight: [CGRect(x: bounds.maxX - Self.corner, y: bounds.maxY - Self.corner, width: Self.corner, height: Self.corner)]
        case .right: [CGRect(x: bounds.maxX - Self.band, y: fromTop ? Self.corner : 0, width: Self.band, height: bounds.height - Self.corner)]
        case .top: [CGRect(x: 0, y: 0, width: bounds.width - Self.corner, height: Self.band)]
        case .bottom: [CGRect(x: 0, y: bounds.maxY - Self.band, width: bounds.width - Self.corner, height: Self.band)]
        }
    }

    private func edge(at point: NSPoint) -> Edge? {
        guard active else { return nil }
        return edges.first { rects(of: $0).contains { $0.contains(point) } }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return edge(at: convert(point, from: superview)) == nil ? nil : self
    }

    override func resetCursorRects() {
        guard active else { return }
        for edge in edges {
            let position: NSCursor.FrameResizePosition = switch edge {
            case .right: .right
            case .top: .top
            case .bottom: .bottom
            case .topRight: .topRight
            case .bottomRight: .bottomRight
            }
            for rect in rects(of: edge) { addCursorRect(rect, cursor: .frameResize(position: position, directions: .all)) }
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragging = edge(at: convert(event.locationInWindow, from: nil)).map { ($0, NSEvent.mouseLocation) }
    }
    /// How far the pointer moved on screen since the drag began: the peek moves as it grows, so a distance within its
    /// own window would drift.
    override func mouseDragged(with event: NSEvent) {
        guard let dragging else { return }
        let point = NSEvent.mouseLocation
        drag(dragging.edge, by: CGSize(width: point.x - dragging.start.x, height: dragging.start.y - point.y))
    }
    override func mouseUp(with event: NSEvent) {
        guard dragging != nil else { return }
        dragging = nil; onEnd()
    }

    /// The pointer moved by `distance` (down positive) holding `edge`, as the growth it asks of the peek: a side edge
    /// follows it only across, the bottom edge only down, the top edge only up, a corner both ways.
    func drag(_ edge: Edge, by distance: CGSize) {
        switch edge {
        case .right: onDrag(CGSize(width: distance.width, height: 0))
        case .top: onDrag(CGSize(width: 0, height: -distance.height))
        case .bottom: onDrag(CGSize(width: 0, height: distance.height))
        case .topRight: onDrag(CGSize(width: distance.width, height: -distance.height))
        case .bottomRight: onDrag(distance)
        }
    }

    /// Diagonal strokes in the corner it is resized by, as on a resizable window's corner, inside a popover's rounded
    /// edge; smaller at the top, tucked into the corner beside the close button.
    override func draw(_ dirtyRect: NSRect) {
        guard active else { return }
        NSColor.secondaryLabelColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        let inset: CGFloat = fromTop ? (roundedCorners ? 6 : 3) : 5
        let corner = NSPoint(x: bounds.maxX - inset, y: fromTop ? bounds.minY + inset : bounds.maxY - inset)
        let inward: CGFloat = fromTop ? 1 : -1
        for length in fromTop ? [3.0, 6.0] : [4.0, 8.0, 12.0] {
            path.move(to: NSPoint(x: corner.x, y: corner.y + inward * length))
            path.line(to: NSPoint(x: corner.x - length, y: corner.y))
        }
        path.stroke()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }
}
