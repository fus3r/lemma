import AppKit
import PDFKit
import LemmaCore

/// Finds where a book's numbered references are defined. Pages are analysed on demand,
/// nearest first and inside the referenced chapter when the outline names it, then remembered.
@MainActor
final class ReferenceIndex {
    let workspaceID: String
    private(set) weak var document: PDFDocument?
    let outline: [OutlineItem]
    private let repository: DocumentIndexRepository
    private var cache: ReferenceCache
    private var definitions: [ReferenceKey: ReferenceTarget] = [:]
    private var outlineTargets: [ReferenceKey: ReferenceTarget] = [:]
    private var mentionCache: [Int: [PageMention]] = [:]
    private var mentionOrder: [Int] = []
    private var dirty = false
    private var prefetchTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    /// The whole-book analysis, when ready: every definition is then known, and citations are linked.
    weak var analysis: BookAnalysisModel?

    init(workspaceID: String, document: PDFDocument, outline: [OutlineItem], repository: DocumentIndexRepository) {
        self.workspaceID = workspaceID; self.document = document; self.outline = outline; self.repository = repository
        cache = repository.referenceCache(workspaceID) ?? ReferenceCache()
        for target in cache.targets where definitions[target.key] == nil { definitions[target.key] = target }
    }

    var scannedPageCount: Int { cache.scannedPages.count }

    /// Passive decorations during a minimap drag must not analyse the pages the pointer merely passes.
    func cachedMentions(onPage index: Int) -> [PageMention] { mentionCache[index] ?? [] }

    func cancelPrefetch() { prefetchTask?.cancel(); prefetchTask = nil }

    /// Mentions on a page, with defining labels marked. Analysing a visible page also records its definitions.
    func mentions(onPage index: Int) -> [PageMention] {
        if let cached = mentionCache[index] { return cached }
        guard let document, let page = document.page(at: index) else { return [] }
        scan(index)
        var found = PageReferenceAnalyzer.mentions(on: page, in: document, plainEquations: analysis?.plainEquations ?? [])
        if let analysis, analysis.analysis != nil {
            // Once the whole book is read, a mention links only to something the book defines, under the label it uses:
            // “figure 3” in running text or “(2.34)” for result 2.34 resolve, dead references do not underline.
            found = found.compactMap { mention in
                if let destination = mention.destination {
                    // Books with one counter cite statements as “(3.21)” too. Rename such a PDF link only when
                    // the book defines no equation by that number and the exact destination confirms the lone
                    // same-number statement on that page. A missing or distant destination stays authoritative.
                    guard mention.key.kind == .equation, let key = analysis.resolver.resolve(mention.key), key.kind == .theorem,
                          let point = destination.point, let target = analysis.definitionsByKey[key],
                          target.pageIndex == destination.pageIndex,
                          (analysis.definitionsByPage[destination.pageIndex] ?? []).filter({ $0.key.number == key.number }).count == 1,
                          target.region.rect.insetBy(dx: -40, dy: -40).contains(point) else { return mention }
                    var resolved = mention; resolved.key = key
                    return resolved
                }
                switch mention.key.kind {
                case .chapter, .link, .citation: return mention
                case .section where outline.contains(where: { OutlineMap.numberPrefix(of: $0.title) == mention.key.number }): return mention
                default:
                    guard let key = analysis.resolver.resolve(mention.key) else { return nil }
                    var resolved = mention; resolved.key = key
                    return resolved
                }
            }
        }
        let local = cache.targets.filter { $0.pageIndex == index }
        for position in found.indices where found[position].destination == nil {
            let mention = found[position]
            if let anchor = local.first(where: { $0.key == mention.key })?.anchor.rect.insetBy(dx: -1, dy: -1) {
                found[position].isDefinition = mention.rects.contains { $0.intersects(anchor) }
            }
        }
        if let analysis, let records = analysis.citationsByPage[index] {
            let taken = found.flatMap(\.rects)
            for record in records {
                guard let key = analysis.citationKey(for: record), let selection = page.selection(for: record.range) else { continue }
                let rects = selection.selectionsByLine().map { $0.bounds(for: page) }.filter { !$0.isEmpty && !$0.isNull }
                guard !rects.isEmpty, !rects.contains(where: { rect in taken.contains { $0.intersects(rect) } }) else { continue }
                found.append(PageMention(key: key, text: record.text, range: record.range, rects: rects))
            }
        }
        mentionCache[index] = found
        mentionOrder.append(index)
        if mentionOrder.count > 80 { mentionCache[mentionOrder.removeFirst()] = nil }
        scheduleSave()
        return found
    }

    /// Analyses the pages around the reader during idle moments, so turning the page finds them ready. Once the
    /// whole-book analysis exists it knows every definition, and the main thread has nothing to scan.
    func prefetch(around pageIndex: Int) {
        cancelPrefetch()
        guard analysis?.analysis == nil else { return }
        prefetchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, self.analysis?.analysis == nil, let count = self.document?.pageCount else { return }
            for index in [pageIndex + 1, pageIndex - 1, pageIndex + 2, pageIndex + 3, pageIndex - 2, pageIndex + 4] where (0..<count).contains(index) {
                if Task.isCancelled { return }
                self.scan(index)
                try? await Task.sleep(for: .milliseconds(15))
            }
            self.scheduleSave()
        }
    }

    private func scheduleSave() {
        guard dirty, saveTask == nil else { return }
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.saveTask = nil
            self?.saveIfNeeded()
        }
    }

    func mention(at point: CGPoint, onPage index: Int) -> PageMention? {
        mentions(onPage: index).first { $0.contains(point) }
    }

    func knownTarget(_ key: ReferenceKey) -> ReferenceTarget? { analysis?.target(for: key) ?? definitions[key] }

    /// Underlines change once citations are linked; pages are measured again on demand.
    func invalidateMentions() { mentionCache = [:]; mentionOrder = [] }

    /// Resolves a clicked mention. Internal PDF links are exact; text mentions are looked up.
    func resolve(_ mention: PageMention, from pageIndex: Int, progress: ((Int, Int) -> Void)? = nil) async -> ReferenceTarget? {
        if let destination = mention.destination, let document {
            return PageReferenceAnalyzer.target(for: destination, key: mention.key, in: document, origin: .link)
        }
        return await resolve(mention.key, from: pageIndex, progress: progress)
    }

    func resolve(_ key: ReferenceKey, from pageIndex: Int, progress: ((Int, Int) -> Void)? = nil) async -> ReferenceTarget? {
        guard let document else { return nil }
        if key.kind == .citation { return analysis?.target(for: key) }
        // An outline entry is authoritative for chapters and sections; text headings are a fallback.
        if key.kind == .chapter || key.kind == .section {
            if let known = outlineTargets[key] { return known }
            if let item = outlineItem(for: key),
               let target = PageReferenceAnalyzer.target(for: LinkDestination(pageIndex: item.pageIndex, point: item.point), key: key, in: document, origin: .outline) {
                outlineTargets[key] = target
                return target
            }
        }
        // The analysis first, as `knownTarget` (the hover) does, so a click and a hover always agree.
        if let known = analysis?.definitionsByKey[key] ?? definitions[key] { return known }
        let order = pageOrder(for: key, from: pageIndex, pageCount: document.pageCount)
        let pending = order.filter { !cache.scannedPages.contains($0) }
        for (count, index) in pending.enumerated() {
            if Task.isCancelled { saveIfNeeded(); return nil }
            scan(index)
            if let found = definitions[key] { saveIfNeeded(); return found }
            if count % 3 == 2 {
                progress?(count + 1, pending.count)
                await Task.yield()
            }
        }
        saveIfNeeded()
        return definitions[key]
    }

    /// Whether `key` would be searched inside a chapter range given by the outline.
    func chapterRange(for key: ReferenceKey) -> Range<Int>? {
        guard let chapter = key.chapter, let document else { return nil }
        return OutlineMap.chapterRange(chapter, in: outline, pageCount: document.pageCount)
    }

    private func outlineItem(for key: ReferenceKey) -> OutlineItem? {
        if key.kind == .section { return OutlineMap.section(key.number, in: outline) }
        guard let range = chapterRange(for: key) else { return nil }
        return outline.first { $0.pageIndex == range.lowerBound && OutlineMap.numberPrefix(of: $0.title) == key.number } ?? outline.first { $0.pageIndex == range.lowerBound }
    }

    private func scan(_ index: Int) {
        guard !cache.scannedPages.contains(index), let page = document?.page(at: index) else { return }
        for target in PageReferenceAnalyzer.definitions(on: page, pageIndex: index) where definitions[target.key] == nil {
            definitions[target.key] = target
            cache.targets.append(target)
        }
        cache.scannedPages.insert(index)
        dirty = true
    }

    private func pageOrder(for key: ReferenceKey, from pageIndex: Int, pageCount: Int) -> [Int] {
        var order: [Int] = []
        var seen = Set<Int>()
        if let range = chapterRange(for: key) {
            for index in Self.proximity(around: min(max(pageIndex, range.lowerBound), range.upperBound - 1), within: range) where seen.insert(index).inserted {
                order.append(index)
            }
        }
        for index in Self.proximity(around: pageIndex, within: 0..<pageCount) where seen.insert(index).inserted { order.append(index) }
        return order
    }

    /// Nearest pages first, alternating backwards (references usually look back) and forwards.
    static func proximity(around center: Int, within range: Range<Int>) -> [Int] {
        guard !range.isEmpty else { return [] }
        let center = min(max(center, range.lowerBound), range.upperBound - 1)
        var result = [center]
        var distance = 1
        while result.count < range.count {
            if center - distance >= range.lowerBound { result.append(center - distance) }
            if center + distance < range.upperBound { result.append(center + distance) }
            distance += 1
        }
        return result
    }

    func saveIfNeeded() {
        saveTask?.cancel(); saveTask = nil
        guard dirty else { return }
        dirty = false
        try? repository.save(cache, id: workspaceID)
    }
}

extension OutlineEntry {
    /// Flattens the navigator's outline for reference resolution, with destination points where known.
    static func items(in document: PDFDocument) -> [OutlineItem] { OutlineReader.items(in: document) }
}
