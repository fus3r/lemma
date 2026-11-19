import SwiftUI
import AppKit
import PDFKit
import LemmaCore

/// An editor-style hover: resting the pointer on an underlined reference shows what it points to · the equation,
/// figure or table rendered from its page, or a citation's entry in the reference list · without a click.
/// The preview never takes focus and closes when the pointer leaves; a click still opens the full peek.
@MainActor
final class HoverPreviewController {
    private weak var view: RegionPDFView?
    private var popover: NSPopover?
    /// The VS Code style's hover widget, used instead of the popover.
    private let panel = VSFloatingPanel()
    private var pending: DispatchWorkItem?
    /// The search for a definition the book's analysis does not know, stopped as soon as the pointer moves on.
    private var resolving: Task<Void, Never>?
    private var shown: (mention: PageMention, pageIndex: Int)?
    weak var store: StudyStore?
    static let delay: TimeInterval = 0.45

    private var observers: [NSObjectProtocol] = []

    init(view: RegionPDFView) {
        self.view = view
        // A preview never outlives the app or the window being in front.
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
    }

    var isShown: Bool { popover?.isShown == true || panel.isShown }

    func update(_ hit: (mention: PageMention, pageIndex: Int)?) {
        if let shown, let hit, shown.mention == hit.mention, shown.pageIndex == hit.pageIndex { return }
        pending?.cancel(); pending = nil
        dismiss()
        guard let hit, LemmaPreferences.flag(LemmaPreferences.hoverPreviews) else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.show(hit) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    func dismiss() {
        pending?.cancel(); pending = nil
        resolving?.cancel(); resolving = nil
        if popover?.isShown == true { popover?.close() }
        panel.close(notify: false)
        popover = nil; shown = nil
    }

    private func canShow(_ hit: (mention: PageMention, pageIndex: Int)) -> Bool {
        // A QA copy recording in the background shows previews in a window that is not key.
        guard let view, let store, view.window?.isKeyWindow == true || QAHooks.startsInBackground, NSEvent.pressedMouseButtons == 0,
              view.hoveredReference.map({ $0.mention == hit.mention && $0.pageIndex == hit.pageIndex }) == true,
              store.referencePeek == nil, store.definitionLookup == nil, store.quickAsk == nil, store.palette == nil,
              view.referencePopover?.isShown != true, view.definitionPopover?.popover.isShown != true else { return false }
        return true
    }

    /// Resolves the target and renders it first, so the preview opens at its final size.
    private func show(_ hit: (mention: PageMention, pageIndex: Int)) {
        guard canShow(hit), let store, let index = store.references else { return }
        let key = hit.mention.key
        if hit.mention.destination != nil {
            if let target = index.linkedTarget(for: hit.mention) {
                present(hit, content: HoverPreviewContent(store: store, key: key, target: target))
            }
            return
        }
        if let target = index.knownTarget(key) { present(hit, content: HoverPreviewContent(store: store, key: key, target: target)); return }
        guard key.kind != .citation else { return }
        // Without the whole-book analysis the definition is looked for page by page, nearest first. Not while the
        // analysis runs (it will know shortly), not once it has read the book (it would know already), and the search
        // stops when the pointer leaves the reference: a click still opens the peek, which searches with its progress.
        if let analysis = store.analysis, analysis.analysis != nil || analysis.isAnalyzing { return }
        resolving?.cancel()
        resolving = Task { @MainActor [weak self] in
            let target = await index.resolve(hit.mention, from: hit.pageIndex)
            guard !Task.isCancelled, let self, let target, self.canShow(hit), let store = self.store else { return }
            self.resolving = nil
            self.present(hit, content: HoverPreviewContent(store: store, key: key, target: target))
        }
    }

    private func present(_ hit: (mention: PageMention, pageIndex: Int), content: HoverPreviewContent) {
        guard let view, let store, let page = view.document?.page(at: hit.pageIndex), let first = hit.mention.rects.first else { return }
        let anchor = view.convert(first, from: page).intersection(view.bounds)
        guard !anchor.isNull, !anchor.isEmpty else { return }
        dismiss()
        if ThemeManager.shared.style == .vscode {
            let hint = content.key.kind == .citation ? "Click for the entry · right-click to find citations" : "Click to peek · ⌥-click to open beside the page"
            panel.show(VSHoverChrome(status: hint) { HoverPreviewPane(store: store, content: content, compact: true) }, anchor: anchor, in: view, placement: .above, interactive: false)
            shown = hit
            return
        }
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = true
        let controller = NSHostingController(rootView: HoverPreviewPane(store: store, content: content).tint(.lemmaOlive))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        self.popover = popover
        shown = hit
        popover.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
    }
}

/// What a hover shows, computed before the popover opens.
@MainActor
struct HoverPreviewContent {
    let key: ReferenceKey
    let target: ReferenceTarget
    let image: NSImage?
    let entryText: String?
    let count: Int

    init(store: StudyStore, key: ReferenceKey, target: ReferenceTarget) {
        self.key = key; self.target = target
        if key.kind == .citation, let entry = store.analysis?.bibliographyEntry(key) {
            entryText = entry.text
            count = store.analysis?.citationCounts[entry.id] ?? 0
            image = nil
        } else {
            entryText = nil
            count = store.analysis?.mentionCounts[key] ?? 0
            var rendered: NSImage?
            if let page = store.document?.page(at: target.pageIndex) {
                // Rendered at 3× and shown at up to 1.5× the page: crisp on Retina, compact enough for a hover.
                let region = target.region.rect.insetBy(dx: -4, dy: -3).intersection(page.bounds(for: .cropBox))
                if let data = try? PDFRegionRenderer.png(page: page, region: PageRegion(region), scale: 3), let image = NSImage(data: data) {
                    let fit = min(1.5, 500 / max(region.width, 1), 300 / max(region.height, 1))
                    image.size = NSSize(width: region.width * fit, height: region.height * fit)
                    rendered = image
                }
            }
            image = rendered
        }
    }
}

struct HoverPreviewPane: View {
    @Bindable var store: StudyStore
    let content: HoverPreviewContent
    /// Inside VS Code's hover chrome: its own padding and hint row are left to the chrome.
    var compact = false
    @Environment(\.theme) private var theme

    private var key: ReferenceKey { content.key }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: key.kind.symbol).font(.system(size: 11)).foregroundStyle(Color.lemmaOlive)
                Text(key.kind == .citation ? (key.name ?? key.title) : key.spokenTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(store.shortPageText(content.target.pageIndex)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if content.count > 0 {
                    Text(key.kind == .citation ? "cited \(content.count)×" : "\(content.count) \(content.count == 1 ? "ref" : "refs")")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            if let text = content.entryText {
                Text(text).font(.system(size: 11.5)).lineLimit(8).fixedSize(horizontal: false, vertical: true)
            } else if let image = content.image {
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: image.size.width, height: image.size.height)
                    .padding(6).background(Color.white, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                    .accessibilityLabel("Preview of \(key.spokenTitle)")
            }
            if !compact {
                Text(key.kind == .citation ? "Click for the entry · right-click to find citations" : "Click to peek · ⌥-click opens it beside the page")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(compact ? 0 : 10)
        .frame(width: key.kind == .citation ? 380 : max(260, (content.image?.size.width ?? 240) + 32))
        .fixedSize(horizontal: false, vertical: true)
    }
}
