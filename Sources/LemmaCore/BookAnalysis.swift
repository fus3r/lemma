import Foundation
import PDFKit

/// One place where the running text names a numbered object, with a line of context for a references list.
public struct MentionRecord: Codable, Equatable, Sendable {
    public var key: ReferenceKey
    public var pageIndex: Int
    /// UTF-16 range in the page's text layer.
    public var location: Int
    public var length: Int
    public var before: String
    public var match: String
    public var after: String
    public init(key: ReferenceKey, pageIndex: Int, location: Int, length: Int, before: String, match: String, after: String) {
        self.key = key; self.pageIndex = pageIndex; self.location = location; self.length = length
        self.before = before; self.match = match; self.after = after
    }
    public var range: NSRange { NSRange(location: location, length: length) }
}

/// A citation in the running text and the reference-list entries it names.
public struct CitationRecord: Codable, Equatable, Sendable {
    public var entryIDs: [Int]
    public var pageIndex: Int
    public var location: Int
    public var length: Int
    public var text: String
    public var before: String
    public var after: String
    public init(entryIDs: [Int], pageIndex: Int, location: Int, length: Int, text: String, before: String = "", after: String = "") {
        self.entryIDs = entryIDs; self.pageIndex = pageIndex; self.location = location; self.length = length
        self.text = text; self.before = before; self.after = after
    }
    public var range: NSRange { NSRange(location: location, length: length) }
}

/// Everything Lemma learns from reading a whole book once: printed page numbers, where numbered objects are
/// defined and cited, the back-of-book index and the reference list. Stored per document beside its search index.
public struct BookAnalysis: Codable, Sendable {
    /// Bump when the analysis changes, so books are read again.
    public static let currentVersion = 8
    public var version = BookAnalysis.currentVersion
    public var pageCount: Int
    public var numbering: PageNumbering?
    public var definitions: [ReferenceTarget] = []
    public var mentions: [MentionRecord] = []
    public var index: [BookIndexEntry] = []
    public var indexPages: [Int] = []
    public var bibliography: [BibliographyEntry] = []
    public var bibliographyPages: [Int] = []
    public var citations: [CitationRecord] = []
    /// Outline titles whose spacing was restored from their page (“3.4.1Ridge Regression” → “3.4.1 Ridge Regression”).
    public var outlineTitles: [String: String] = [:]
    /// Terms the book introduces in italic or bold, at their defining occurrence.
    public var terms: [DefinedTerm] = []
    /// The book numbers every item in one sequence and cites items by number alone (“(2.34)” for result 2.34).
    public var itemsByNumber = false
    /// Statements, proofs and the uses between them.
    public var structure = DocumentStructure()
    /// Headings read from the text (“3 Experiments”, “2.1 Ridge regression”), an outline for PDFs that have none.
    public var headings: [OutlineItem] = []
    /// What the text says its symbols stand for (“where λ ≥ 0 is a complexity parameter”).
    public var symbols: [SymbolDefinition] = []
    public var analyzedAt = Date.now

    public init(pageCount: Int) { self.pageCount = pageCount }

    /// The first definition found for each key.
    public func definitionsByKey() -> [ReferenceKey: ReferenceTarget] {
        var result: [ReferenceKey: ReferenceTarget] = [:]
        for target in definitions where result[target.key] == nil { result[target.key] = target }
        return result
    }

    /// How often each numbered object is mentioned in the running text.
    public func mentionCounts() -> [ReferenceKey: Int] {
        mentions.reduce(into: [:]) { $0[$1.key, default: 0] += 1 }
    }

    /// The citations of one reference-list entry.
    public func citations(of entryID: Int) -> [CitationRecord] { citations.filter { $0.entryIDs.contains(entryID) } }

    /// Undotted equation labels the document defines (“12” for “(12)”), so references to them can be read.
    public func plainEquationLabels() -> Set<String> { Self.plainEquationLabels(in: definitions) }

    /// Undotted labels count only in a document that numbers its equations that way: a book numbering “(3.41)”
    /// may still show a stray “(1)” at the end of a line, and every “(1)” in its text must not become a link. Such a
    /// document numbers from (1) on: it has several distinct labels, (1) among them when there are only two · not “p′(3).” twice.
    static func plainEquationLabels(in definitions: [ReferenceTarget]) -> Set<String> {
        let equations = definitions.filter { $0.key.kind == .equation }
        let plain = equations.filter { !$0.key.number.contains(".") && $0.key.number.first?.isNumber == true }
        let labels = Set(plain.map(\.key.number))
        guard labels.count >= 3 || (labels.count == 2 && labels.contains("1")),
              Double(plain.count) >= 0.3 * Double(equations.count) else { return [] }
        return labels
    }
}

/// Maps a mention to the object a book defines when the spelling differs from the label: books that number every
/// item in one sequence cite result 2.34 as “(2.34)”, and a shared counter makes “Theorem 3.59” and a bold “3.59” the same item.
public struct KeyResolver: Sendable {
    private let defined: Set<ReferenceKey>
    private let statements: [String: ReferenceKey]
    /// Theorems, lemmas and definitions share one counter: no number is used by two kinds of statement.
    private let sharedCounter: Bool
    /// Every item is numbered in one sequence and cited by its number alone (“by 2.34”, “(2.34)”).
    private let itemsByNumber: Bool

    public init(definitions: [ReferenceTarget], itemsByNumber: Bool = false) {
        defined = Set(definitions.map(\.key))
        var statements: [String: ReferenceKey] = [:]
        var shared = true
        for target in definitions where target.key.kind == .theorem {
            if let existing = statements[target.key.number] { if existing.name != target.key.name { shared = false } }
            else { statements[target.key.number] = target.key }
        }
        self.statements = statements
        sharedCounter = shared
        self.itemsByNumber = itemsByNumber
    }

    /// The defined key a mention names, or nil when the book defines nothing by that number.
    public func resolve(_ key: ReferenceKey) -> ReferenceKey? {
        if defined.contains(key) { return key }
        // “Figure 1.15a” names a panel of Figure 1.15.
        if [.figure, .chart, .table].contains(key.kind), let last = key.number.last, last.isLetter {
            let whole = ReferenceKey(kind: key.kind, number: String(key.number.dropLast()), name: key.name)
            if defined.contains(whole) { return whole }
        }
        switch key.kind {
        case .equation: return itemsByNumber ? statements[key.number] : nil
        case .theorem: return sharedCounter || itemsByNumber ? statements[key.number] : nil
        default: return nil
        }
    }
}

/// Reads a whole PDF on a background thread with its own PDFKit document. About 10 s for a 760-page book,
/// most of it spent extracting text, which PDFKit does once per document.
public enum BookAnalyzer {
    static let indexTitles: Set<String> = ["index", "subject index", "general index", "author index", "index of subjects"]
    static let bibliographyTitles: Set<String> = ["references", "bibliography", "literature cited", "works cited", "references and notes",
                                                  "further reading", "literature", "cited literature", "selected bibliography"]
    /// Headings that end a reference list at the back of a paper.
    static let afterBibliographyTitles: Set<String> = ["appendix", "appendices", "supplementary material", "supplementary materials",
                                                       "supplemental material", "index", "subject index", "author index"]

    public static func analyze(url: URL, outline: [OutlineItem], progress: @Sendable (Int, Int) -> Void = { _, _ in },
                               isCancelled: @Sendable () -> Bool = { false }) -> BookAnalysis? {
        guard let document = PDFDocument(url: url) else { return nil }
        return analyze(document: document, outline: outline, progress: progress, isCancelled: isCancelled)
    }

    public static func analyze(document: PDFDocument, outline: [OutlineItem], progress: @Sendable (Int, Int) -> Void = { _, _ in },
                               isCancelled: @Sendable () -> Bool = { false }) -> BookAnalysis? {
        let count = document.pageCount
        var analysis = BookAnalysis(pageCount: count)
        let report = ReportReferences(outline: outline)
        // Numbered outline entries are authoritative for sections; numbered lines in the text are then not headings.
        let outlineSections = Set(outline.compactMap { OutlineMap.numberPrefix(of: $0.title) })
        let textHeadings = outlineSections.filter { $0.contains(".") }.count < 3
        var indexRange = sectionRange(in: outline, pageCount: count, matching: indexTitles)
        var bibliographyRange = sectionRange(in: outline, pageCount: count, matching: bibliographyTitles)
        var texts: [String] = []
        texts.reserveCapacity(count)
        var candidates: [(PageNumbering.Candidate, band: Int, y: Int)] = []
        var pageLines: [[PageLine]] = []
        var bounds: [Int: CGRect] = [:]
        var definitionsByPage: [[ReferenceTarget]] = []
        // Emphasis is read from the content stream's fonts; sizes are compared with the body text's.
        let bodySize = EmphasisExtractor.bodyFontSize(of: document)
        var termCandidates: [(pageIndex: Int, candidate: TermCandidate)] = []
        var headingCandidates: [OutlineItem] = []
        var symbolDefinitions: [SymbolDefinition] = []
        var exerciseSequence = PageReferenceAnalyzer.ExerciseSequence()
        var listedExercises: Set<ReferenceKey> = [], listedExerciseIDs: Set<String> = []
        let outlineSectionPages = outline.reduce(into: [String: Set<Int>]()) { pages, item in
            if let number = OutlineMap.numberPrefix(of: item.title) { pages[number, default: []].insert(item.pageIndex) }
        }

        for pageIndex in 0..<count {
            if isCancelled() { return nil }
            guard let page = document.page(at: pageIndex) else { texts.append(""); pageLines.append([]); definitionsByPage.append([]); continue }
            let text = page.string ?? ""
            texts.append(text)
            let box = page.bounds(for: .cropBox)
            bounds[pageIndex] = box
            let lines = PageReferenceAnalyzer.fragments(on: page)
            pageLines.append(lines.map { PageLine(pageIndex: pageIndex, text: $0.text, bounds: $0.bounds) })
            candidates += runningHeadCandidates(lines, pageIndex: pageIndex, box: box)
            let emphasis = text.isEmpty ? EmphasisAnalysis() : EmphasisExtractor.analyze(page: page, pageText: text, bodyFontSize: bodySize)
            let runs = emphasis.located.map(\.run)
            var options = PageReferenceAnalyzer.DefinitionOptions(emphasis: runs, textHeadings: textHeadings,
                                                                  knownSections: outlineSections, numberedResults: true)
            options.imageBounds = emphasis.scan.imageBounds
            var definitions = PageReferenceAnalyzer.definitions(on: page, pageIndex: pageIndex, options: options).map { target in
                var target = target
                target.key = report.key(for: target.key, onPage: pageIndex, y: target.anchor.rect.midY)
                return target
            }
            let defined = Set(definitions.map(\.key))
            let listed = PageReferenceAnalyzer.numberedExercises(on: page, pageIndex: pageIndex, sequence: &exerciseSequence,
                                                                 sections: outlineSectionPages, emphasis: runs)
                .filter { !defined.contains($0.key) }
            listedExercises.formUnion(listed.map(\.key))
            listedExerciseIDs.formUnion(listed.map { "\($0.pageIndex):\($0.location ?? -1)" })
            definitions += listed
            definitionsByPage.append(definitions)
            if outline.isEmpty, !text.isEmpty { headingCandidates += headings(in: text, page: page, pageIndex: pageIndex, runs: runs, fragments: lines) }
            if !text.isEmpty { symbolDefinitions += Notation.definitions(in: text, pageIndex: pageIndex) }
            if indexRange?.contains(pageIndex) != true, bibliographyRange?.contains(pageIndex) != true, !text.isEmpty {
                termCandidates += TermCandidates.candidates(runs: runs, pageText: text).map { (pageIndex, $0) }
            }
            if pageIndex % 4 == 3 || pageIndex == count - 1 { progress(pageIndex + 1, count) }
        }

        analysis.numbering = numbering(document: document, candidates: candidates)
        for item in outline where texts.indices.contains(item.pageIndex) {
            let repaired = OutlineTitle.repaired(item.title, pageText: texts[item.pageIndex])
            if repaired != item.title { analysis.outlineTitles[item.title] = repaired }
        }

        if outline.isEmpty {
            // A page listing many headings is a table of contents, not the text.
            let perPage = Dictionary(grouping: headingCandidates, by: \.pageIndex).mapValues(\.count)
            analysis.headings = orderedHeadings(headingCandidates.filter { (perPage[$0.pageIndex] ?? 0) <= 6 })
        }

        // Back matter without an outline entry: find its heading in the text.
        if indexRange == nil, var start = headingPage(titles: indexTitles, in: pageLines, from: count - 1, through: Int(Double(count) * 0.75)) {
            // The search runs backwards and may stop at a later “Index” line; earlier pages that read as index pages belong to it.
            while start > 0, count - start < 60, isIndexLike(pageLines[start - 1]) { start -= 1 }
            indexRange = start..<count
        }
        if bibliographyRange == nil,
           let start = headingPage(titles: bibliographyTitles, in: pageLines, from: (indexRange?.lowerBound ?? count) - 1,
                                   through: count > 150 ? Int(Double(count) * 0.7) : count / 3) {
            var stop = (start + 1..<count).first { page in pageLines[page].contains { isHeading($0.text, in: afterBibliographyTitles) } }
            // A labelled list (“[12] …”) ends with the last page that still has labels: an appendix follows in papers.
            func labelled(_ page: Int) -> Int { pageLines[page].filter { BibliographyParser.numericLabel($0.text) != nil }.count }
            if labelled(start) >= 3, let end = (start + 1..<count).first(where: { labelled($0) < 2 }) { stop = min(stop ?? end, end) }
            bibliographyRange = start..<min(stop ?? count, indexRange?.lowerBound ?? count, start + 80)
        }
        // The back matter starts at its heading, which may sit partway down a page shared with the text (a short paper).
        var backMatterStart: [Int: Int] = [:]
        var indexLines: [PageLine] = [], bibliographyLines: [PageLine] = []
        if let indexRange {
            let (lines, start) = backMatterLines(indexRange, titles: indexTitles, document: document)
            indexLines = lines
            backMatterStart[indexRange.lowerBound] = min(backMatterStart[indexRange.lowerBound] ?? .max, start)
        }
        if let bibliographyRange {
            let (lines, start) = backMatterLines(bibliographyRange, titles: bibliographyTitles, document: document)
            bibliographyLines = lines
            backMatterStart[bibliographyRange.lowerBound] = min(backMatterStart[bibliographyRange.lowerBound] ?? .max, start)
        }
        let backMatterPages = Set(Array(indexRange ?? 0..<0) + Array(bibliographyRange ?? 0..<0))
        func isBackMatter(_ pageIndex: Int, _ location: Int) -> Bool {
            guard backMatterPages.contains(pageIndex) else { return false }
            return location >= backMatterStart[pageIndex, default: 0]
        }
        // Terms found in the back matter are entries, not definitions.
        termCandidates.removeAll { isBackMatter($0.pageIndex, $0.candidate.range.location) }
        analysis.symbols = symbolDefinitions.filter { !isBackMatter($0.pageIndex, $0.location) }

        if let indexRange {
            analysis.indexPages = Array(indexRange)
            analysis.index = BookIndexParser.parse(indexLines, pageBounds: bounds)
        }
        let numbering = analysis.numbering
        analysis.terms = BookTerms.table(termCandidates, index: analysis.index) { pageIndex in
            numbering.map { $0.label(for: pageIndex).flatMap(Int.init) } ?? pageIndex + 1
        }
        if let bibliographyRange {
            analysis.bibliographyPages = Array(bibliographyRange)
            analysis.bibliography = BibliographyParser.parse(bibliographyLines, pageBounds: bounds)
        }

        // Definitions: drop numbered results unless the book names its items that way, add the outline's sections.
        let numberFirstStyle = texts.reduce(0) { $0 + numberFirstItems(in: $1) } >= 10
        var definitions = definitionsByPage.flatMap { $0 }.filter { numberFirstStyle || $0.numberFirst != true }
        if numberFirstStyle {
            definitions += PageReferenceAnalyzer.interleavedItems(among: definitions, texts: texts, document: document, knownSections: outlineSections)
        }
        // An exercise found in its exercise section wins over the same head elsewhere (Bishop's margin pointers “Exercise 1.1”).
        definitions.removeAll { listedExercises.contains($0.key) && !listedExerciseIDs.contains("\($0.pageIndex):\($0.location ?? -1)") }
        // Undotted equation labels stay only in documents that number equations that way.
        let plainLabels = BookAnalysis.plainEquationLabels(in: definitions)
        definitions.removeAll { $0.key.kind == .equation && !$0.key.number.contains(".") && $0.key.number.first?.isNumber == true && !plainLabels.contains($0.key.number) }
        definitions.removeAll { isBackMatter($0.pageIndex, $0.location ?? 0) && $0.key.kind != .section }
        var definedKeys = Set(definitions.map(\.key))
        for item in outline {
            guard let number = OutlineMap.numberPrefix(of: item.title), number.contains(".") else { continue }
            let key = ReferenceKey(kind: .section, number: number)
            guard !definedKeys.contains(key),
                  let target = PageReferenceAnalyzer.target(for: LinkDestination(pageIndex: item.pageIndex, point: item.point), key: key,
                                                            in: document, origin: .outline) else { continue }
            definitions.append(target); definedKeys.insert(key)
        }
        for heading in report.headings where !definedKeys.contains(heading.key) {
            guard let target = heading.target(in: document) else { continue }
            definitions.append(target); definedKeys.insert(heading.key)
        }
        analysis.definitions = definitions

        // Mentions, now that every label is known: undotted equation numbers become references in papers that use them.
        let plain = analysis.plainEquationLabels()
        let resolver = KeyResolver(definitions: definitions, itemsByNumber: numberFirstStyle)
        analysis.itemsByNumber = numberFirstStyle
        for (pageIndex, text) in texts.enumerated() where !isBackMatter(pageIndex, 0) && !text.isEmpty {
            if isCancelled() { return nil }
            guard let page = document.page(at: pageIndex) else { continue }
            let pageDefinitions = definitions.filter { $0.pageIndex == pageIndex }
            analysis.mentions += mentions(in: text, page: page, pageIndex: pageIndex, definitions: pageDefinitions, plainEquations: plain, report: report)
                .filter { !isBackMatter(pageIndex, $0.location) }
                .compactMap { record in
                    var record = record
                    if let key = resolver.resolve(record.key) { record.key = key }
                    else if [.chart, .box, .specialFeature].contains(record.key.kind) { return nil }
                    return record
                }
        }

        // Statements, proofs and what each one uses.
        let outlinePoints = outline.compactMap { item -> (key: ReferenceKey, point: TextPoint)? in
            guard let number = OutlineMap.numberPrefix(of: item.title), let page = document.page(at: item.pageIndex) else { return nil }
            let key = number.contains(".") || item.level > 0 ? ReferenceKey(kind: .section, number: number) : ReferenceKey(kind: .chapter, number: number)
            return (key, TextPoint(pageIndex: item.pageIndex, location: textLocation(of: item.title, near: item.point, on: page)))
        }
        analysis.structure = StructureAnalyzer.analyze(document: document, texts: texts, definitions: definitions, mentions: analysis.mentions,
                                                       sections: outlinePoints, resolve: resolver.resolve)

        if !analysis.bibliography.isEmpty {
            let numeric = analysis.bibliography.contains { $0.label.map(BibliographyParser.isNumericLabel) == true }
            let alphabetic = Set(analysis.bibliography.compactMap { $0.label }.filter { !BibliographyParser.isNumericLabel($0) })
            for (pageIndex, text) in texts.enumerated() where !isBackMatter(pageIndex, 0) && !text.isEmpty {
                let string = text as NSString
                for citation in CitationScanner.mentions(in: text, numeric: numeric, labels: alphabetic) where !isBackMatter(pageIndex, citation.range.location) {
                    let entries = CitationScanner.match(citation, in: analysis.bibliography)
                    guard !entries.isEmpty else { continue }
                    let context = Self.contextAround(citation.range, in: string)
                    analysis.citations.append(CitationRecord(entryIDs: entries.map(\.id), pageIndex: pageIndex, location: citation.range.location,
                                                             length: citation.range.length, text: citation.text, before: context.before, after: context.after))
                }
            }
        }
        analysis.analyzedAt = .now
        return analysis
    }

    /// Numbers at either end of the topmost and bottommost rows of a page: its running head or footer.
    /// Rows are judged against the page's own lines, so large top margins and tall heads are read as well.
    static func runningHeadCandidates(_ lines: [LayoutFragment], pageIndex: Int, box: CGRect) -> [(PageNumbering.Candidate, band: Int, y: Int)] {
        guard !lines.isEmpty else { return [] }
        let heights = lines.map(\.bounds.height).sorted()
        let typical = max(6, heights[heights.count / 2])
        let top = lines.map(\.bounds.maxY).max()!, bottom = lines.map(\.bounds.minY).min()!
        var result: [(PageNumbering.Candidate, band: Int, y: Int)] = []
        for line in lines where line.bounds.height < max(16, typical * 1.9) {
            let isTop = line.bounds.maxY >= top - 3 && line.bounds.minY >= box.minY + box.height * 0.75
            let isBottom = line.bounds.minY <= bottom + 3 && line.bounds.maxY <= box.minY + box.height * 0.2
            guard isTop || isBottom, !line.text.contains("This is page"),
                  let value = PageNumbering.candidateValue(inLine: line.text.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            result.append((PageNumbering.Candidate(pageIndex: pageIndex, value: value.value, style: value.style), isTop ? 0 : 1, Int((line.bounds.midY / 3).rounded())))
        }
        return result
    }

    /// The last page, searching backwards from `from` to `through`, with a line that is one of `titles`
    /// (“References”, “8 References”, “REFERENCES”).
    static func headingPage(titles: Set<String>, in pages: [[PageLine]], from: Int, through: Int) -> Int? {
        guard from >= 0, from < pages.count else { return nil }
        for pageIndex in stride(from: from, through: max(0, through), by: -1) where pages[pageIndex].contains(where: { isHeading($0.text, in: titles) }) {
            return pageIndex
        }
        return nil
    }

    /// A page of index entries: most lines end with page numbers (“ridge regression, 61–64”).
    static func isIndexLike(_ lines: [PageLine]) -> Bool {
        let entries = lines.filter { $0.text.trimmingCharacters(in: .whitespaces).count >= 3 }
        guard entries.count >= 8 else { return false }
        let numbered = entries.filter { $0.text.range(of: #"(,\s*\d+([–-]\d+)?|\s\d+([–-]\d+)?)[,.;]?\s*$"#, options: .regularExpression) != nil }.count
        return Double(numbered) >= 0.45 * Double(entries.count)
    }

    static func isHeading(_ text: String, in titles: Set<String>) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 40 else { return false }
        var folded = TextRepair.folded(trimmed).trimmingCharacters(in: CharacterSet(charactersIn: ".:"))
        if let range = folded.range(of: #"^(\d+(\.\d+)*|[ivxlc]+|[a-z])\.?\s+"#, options: .regularExpression) { folded.removeSubrange(range) }
        if let range = folded.range(of: #"^(appendix|appendices)(\s+[a-z0-9]+)?(\s*[.:]?\s+.*)?$"#, options: .regularExpression), titles.contains("appendix"),
           range.lowerBound == folded.startIndex { return true }
        return titles.contains(folded)
    }

    /// The back matter's lines, column by column, without what precedes its heading on the first page, and where the
    /// heading starts in that page's text.
    static func backMatterLines(_ range: Range<Int>, titles: Set<String>, document: PDFDocument) -> ([PageLine], Int) {
        var lines: [PageLine] = []
        var start = 0
        // The heading may sit on the range's second page when an outline entry points one page early.
        var first = range.lowerBound
        if range.count > 1, let page = document.page(at: first), !PageReferenceAnalyzer.fragments(on: page).contains(where: { isHeading($0.text, in: titles) }),
           let next = document.page(at: first + 1), PageReferenceAnalyzer.fragments(on: next).contains(where: { isHeading($0.text, in: titles) }) {
            first += 1
        }
        for pageIndex in first..<range.upperBound {
            guard let page = document.page(at: pageIndex) else { continue }
            var pageLines = PageReferenceAnalyzer.columnFragments(on: page).map { PageLine(pageIndex: pageIndex, text: $0.text, bounds: $0.bounds) }
            if pageIndex == first, let heading = pageLines.filter({ isHeading($0.text, in: titles) }).max(by: { $0.bounds.minY < $1.bounds.minY }) {
                // A section can start partway down its first page; keep what follows the heading, the heading included.
                pageLines = pageLines.filter { $0.bounds.maxY <= heading.bounds.maxY + 1 }
                let map = PageTextMap(page: page)
                if let line = map.lines.first(where: { $0.rect.insetBy(dx: -2, dy: -2).intersects(heading.bounds) && isHeading(((page.string ?? "") as NSString).substring(with: $0.range), in: titles) })
                    ?? map.line(at: CGPoint(x: heading.bounds.minX + 2, y: heading.bounds.midY)) {
                    start = line.range.location
                }
            }
            lines += pageLines
        }
        // A first page skipped above belongs to the text, not to the back matter.
        return (lines, first > range.lowerBound ? Int.max : start)
    }

    private static let numberedHeading = try! NSRegularExpression(
        pattern: #"^[ \t]*((?:[1-9]\d?|[A-Z])(?:\.\d{1,2}){0,3})\.?[ \t]+(\p{Lu}[^\n]{1,100})$"#, options: [.anchorsMatchLines])

    /// Numbered headings: “1 Introduction”, “3.2 Optimizer”, “A Proofs” · set in bold at least at body size, or in capitals
    /// or title case on a short line set apart from the text above (small capitals are neither bold nor italic).
    static func headings(in text: String, page: PDFPage, pageIndex: Int, runs: [EmphasisRun], fragments: [LayoutFragment] = []) -> [OutlineItem] {
        let bold = runs.filter { $0.style == .bold && $0.relativeSize >= 0.98 }
        let string = text as NSString
        let box = page.bounds(for: .cropBox)
        var result: [OutlineItem] = []
        for match in numberedHeading.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            let numberRange = match.range(at: 1)
            let number = string.substring(with: numberRange)
            let title = string.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            // An initial (“A. Fixture”) is not an appendix heading (“A Proofs”, “A.1 Lemmas”).
            if number.count == 1, number.first?.isLetter == true,
               numberRange.upperBound < string.length, string.character(at: numberRange.upperBound) == 0x2E { continue }
            // A table of contents lists the same headings with their pages (“1.1 Probability Spaces 1”, dotted leaders).
            guard title.range(of: #"(\s\d{1,4}|\.\s?\.\s?\.)\s*$"#, options: .regularExpression) == nil else { continue }
            // A heading is a short title, not a sentence or an exercise (“4.4.1 Show that if j ≤ k then …”).
            let words = title.split(separator: " ")
            let openers: Set<String> = ["show", "suppose", "prove", "let", "use", "find", "compute", "generalize", "give", "consider",
                                        "assume", "if", "for", "in", "we", "this", "the", "a", "an", "write", "check", "verify", "derive"]
            guard words.count <= 10, title.count <= 80, !openers.contains(words.first.map { $0.lowercased() } ?? ""),
                  title.rangeOfCharacter(from: CharacterSet(charactersIn: "=≤≥<>∈⊂∑∫")) == nil else { continue }
            guard title.range(of: #"\p{L}{3,}"#, options: .regularExpression) != nil, !title.hasSuffix(","), !title.hasSuffix("."),
                  number.first?.isNumber == false || ReferenceScanner.isSectionNumber(number.contains(".") ? number : number + ".1"),
                  let rect = page.selection(for: match.range)?.bounds(for: page), LayoutFragment.isSane(rect),
                  rect.minY > box.minY + 40, rect.maxY < box.maxY - 40 else { continue }
            let isBold = bold.contains(where: { NSIntersectionRange($0.range, numberRange).length == numberRange.length })
            if !isBold {
                // Capitals or title case (“2 ALGORITHM”, “3 Related Work”), short, apart from the text above.
                let words = words.filter { $0.first?.isLetter == true }
                let small: Set<String> = ["a", "an", "the", "of", "and", "or", "for", "in", "on", "to", "with", "via", "from", "by", "vs", "at"]
                let titleCase = !words.isEmpty && words.allSatisfy { $0.first!.isUppercase || small.contains($0.lowercased()) } && words.count <= 9
                guard titleCase, rect.width < box.width * 0.6, !fragments.isEmpty,
                      ReferenceLayout.isSeparatedAbove(rect, fragments: fragments, page: box) else { continue }
            }
            let level = number.filter { $0 == "." }.count
            result.append(OutlineItem(title: "\(number) \(TextRepair.repaired(title))", pageIndex: pageIndex, level: level,
                                      point: CGPoint(x: rect.minX, y: rect.maxY + 4)))
        }
        return result
    }

    /// Keeps the longest run of headings whose numbers advance through the document; a stray number in a table or an
    /// author's initial is out of order and left out.
    static func orderedHeadings(_ candidates: [OutlineItem]) -> [OutlineItem] {
        func parts(_ item: OutlineItem) -> [Int] {
            (item.title.split(separator: " ").first ?? "").split(separator: ".").map { part in Int(part) ?? Int(part.unicodeScalars.first!.value) - 64 + 1000 }
        }
        let numbers = candidates.map(parts)
        guard !numbers.isEmpty else { return [] }
        // Longest strictly increasing subsequence (lexicographic on the number's parts).
        var length = [Int](repeating: 1, count: numbers.count), previous = [Int](repeating: -1, count: numbers.count)
        for i in numbers.indices {
            for j in 0..<i where numbers[j].lexicographicallyPrecedes(numbers[i]) && length[j] + 1 > length[i] {
                length[i] = length[j] + 1; previous[i] = j
            }
        }
        guard var index = length.indices.max(by: { length[$0] < length[$1] }) else { return [] }
        var chain: [OutlineItem] = []
        while index >= 0 { chain.append(candidates[index]); index = previous[index] }
        chain.reverse()
        return chain.count >= 2 ? chain : []
    }

    /// Where an outline entry's text starts on its page: its title found in the text, else the first line below its destination.
    static func textLocation(of title: String, near point: CGPoint?, on page: PDFPage) -> Int {
        let text = page.string ?? ""
        if let location = OutlineTitle.location(of: title, in: text) { return location }
        guard let point else { return 0 }
        return PageTextMap(page: page).firstLine(atOrBelow: point.y)?.range.location ?? 0
    }

    private static let numberFirstExpression = try! NSRegularExpression(
        pattern: #"^\d{1,2}\.\d{1,3}\s+(?i:definition|example|theorem|lemma|proposition|corollary|notation|result)\b\s*:"#, options: [.anchorsMatchLines])
    static func numberFirstItems(in text: String) -> Int {
        numberFirstExpression.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    /// Text mentions of numbered objects, excluding defining labels and running heads.
    static func mentions(in text: String, page: PDFPage, pageIndex: Int, definitions: [ReferenceTarget], plainEquations: Set<String>,
                         report: ReportReferences) -> [MentionRecord] {
        let string = text as NSString
        let box = page.bounds(for: .cropBox)
        var records: [MentionRecord] = []
        for mention in ReferenceScanner.mentions(in: text, plainEquations: plainEquations) {
            var key = mention.key
            if key.kind == .chart || key.kind == .section || definitions.contains(where: { $0.key == key }) {
                guard let rect = page.selection(for: mention.range)?.bounds(for: page), !rect.isNull else { continue }
                key = report.key(for: key, onPage: pageIndex, y: rect.midY)
                if definitions.contains(where: { $0.key == key && $0.anchor.rect.insetBy(dx: -1, dy: -1).intersects(rect) }) { continue }
                if rect.minY >= box.maxY - 36 || rect.maxY <= box.minY + 36 { continue }
            }
            let context = Self.contextAround(mention.range, in: string)
            records.append(MentionRecord(key: key, pageIndex: pageIndex, location: mention.range.location, length: mention.range.length,
                                         before: context.before, match: mention.text.replacingOccurrences(of: "\n", with: " "), after: context.after))
        }
        return records
    }

    /// Up to about 70 characters on either side, on one line, cut at word boundaries. Spacing next to the match is kept.
    public static func contextAround(_ range: NSRange, in string: NSString) -> (before: String, after: String) {
        let start = max(0, range.location - 90), end = min(string.length, range.upperBound + 90)
        func clean(_ text: String) -> String {
            let collapsed = TextRepair.repaired(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !collapsed.isEmpty else { return text.isEmpty ? "" : " " }
            return (text.first?.isWhitespace == true ? " " : "") + collapsed + (text.last?.isWhitespace == true ? " " : "")
        }
        var before = clean(string.substring(with: NSRange(location: start, length: range.location - start)))
        var after = clean(string.substring(with: NSRange(location: range.upperBound, length: end - range.upperBound)))
        if before.count > 70 {
            let tail = String(before.suffix(70))
            before = "…" + (tail.firstIndex(of: " ").map { String(tail[tail.index(after: $0)...]) } ?? tail)
        } else if start > 0 { before = "…" + String(before.drop { $0 == " " }) }
        if after.count > 70 {
            let head = String(after.prefix(70))
            after = (head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head) + "…"
        }
        return (before, after)
    }

    /// The pages of an outline section with one of the given titles, up to the next entry at the same or a higher level.
    public static func sectionRange(in outline: [OutlineItem], pageCount: Int, matching titles: Set<String>) -> Range<Int>? {
        guard let index = outline.lastIndex(where: { titles.contains(normalizedTitle($0.title)) }) else { return nil }
        let item = outline[index]
        let end = outline[(index + 1)...].first { $0.level <= item.level && $0.pageIndex >= item.pageIndex }?.pageIndex ?? pageCount
        let upper = max(item.pageIndex + 1, end == item.pageIndex ? end + 1 : end)
        return item.pageIndex..<min(pageCount, upper)
    }

    static func normalizedTitle(_ title: String) -> String {
        var folded = TextRepair.folded(title)
        if let range = folded.range(of: #"^(\d+(\.\d+)*|[ivxlc]+)\.?\s+"#, options: .regularExpression) { folded.removeSubrange(range) }
        return folded
    }

    /// The PDF's own labels when they are meaningful, otherwise numbers read from running heads.
    static func numbering(document: PDFDocument, candidates: [(PageNumbering.Candidate, band: Int, y: Int)]) -> PageNumbering? {
        let labels = (0..<document.pageCount).map { document.page(at: $0)?.label ?? String($0 + 1) }
        if labels.enumerated().contains(where: { $0.element != String($0.offset + 1) }), Set(labels).count > document.pageCount / 2 {
            return PageNumbering(runs: [], source: .pdfLabels, labels: labels)
        }
        // Keep the band and height used by most pages, so a chapter number or a stray figure label does not count.
        let groups = Dictionary(grouping: candidates) { "\($0.band):\($0.y)" }
        guard let best = groups.max(by: { $0.value.count < $1.value.count })?.value.first else { return nil }
        let kept = candidates.filter { $0.band == best.band && abs($0.y - best.y) <= 1 }.map(\.0)
        let pages = Set(kept.map(\.pageIndex))
        // Even and odd pages put the number at opposite ends of the same line; one candidate per page is enough.
        let unique = pages.compactMap { page in kept.first { $0.pageIndex == page } }
        return PageNumbering.infer(from: unique, pageCount: document.pageCount)
    }
}

extension DocumentIndexRepository {
    private func analysisURL(_ id: String) -> URL { directory(id).appendingPathComponent("analysis.json") }

    public func bookAnalysis(_ id: String) -> BookAnalysis? {
        guard let data = try? Data(contentsOf: analysisURL(id)),
              let analysis = try? WorkspaceRepository.decoder.decode(BookAnalysis.self, from: data),
              analysis.version == BookAnalysis.currentVersion else { return nil }
        return analysis
    }

    public func save(_ analysis: BookAnalysis, id: String) throws {
        try FileManager.default.createDirectory(at: directory(id), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(analysis).write(to: analysisURL(id), options: .atomic)
    }
}
