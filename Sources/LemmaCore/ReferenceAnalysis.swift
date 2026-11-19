import Foundation
import PDFKit

/// An internal PDF link's destination, in the same document.
public struct LinkDestination: Codable, Equatable, Sendable {
    public var pageIndex: Int
    public var point: CGPoint?
    public init(pageIndex: Int, point: CGPoint?) { self.pageIndex = pageIndex; self.point = point }
}

/// A mention placed on a page: what it names, and its line rectangles in page space.
public struct PageMention: Equatable, Sendable {
    public var key: ReferenceKey
    public var text: String
    public var range: NSRange?
    public var rects: [CGRect]
    public var destination: LinkDestination?
    /// The defining label or caption itself, rather than a reference to it.
    public var isDefinition = false
    public init(key: ReferenceKey, text: String, range: NSRange?, rects: [CGRect], destination: LinkDestination? = nil) {
        self.key = key; self.text = text; self.range = range; self.rects = rects; self.destination = destination
    }
    public func contains(_ point: CGPoint, tolerance: CGFloat = 1.5) -> Bool {
        rects.contains { $0.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
    }
}

/// Reads mentions and defining occurrences from PDFKit's text layer.
/// Equation labels count as definitions when they end a line at the column's right edge,
/// separated from the formula; captions and statements when they begin a line.
/// The functions only read the page given to them, so a background analysis can call them on its own document.
public enum PageReferenceAnalyzer {
    /// - Parameter plainEquations: undotted equation labels the document defines, so “(12)” can be a reference.
    public static func mentions(on page: PDFPage, in document: PDFDocument, plainEquations: Set<String> = []) -> [PageMention] {
        var result: [PageMention] = []
        for annotation in page.annotations where annotation.type == "Link" {
            guard let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination,
                  let target = destination.page else { continue }
            let index = document.index(for: target)
            guard index != NSNotFound, index >= 0, index < document.pageCount else { continue }
            let text = (page.selection(for: annotation.bounds)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let key = ReferenceScanner.mentions(in: text).first?.key
                ?? contextualKey(for: annotation.bounds, text: text, on: page)
                ?? ReferenceKey(kind: .link, number: text.isEmpty ? "PDF page \(index + 1)" : String(text.prefix(40)))
            result.append(PageMention(key: key, text: text, range: nil, rects: [annotation.bounds],
                                      destination: LinkDestination(pageIndex: index, point: specified(destination.point))))
        }
        guard let text = page.string, !text.isEmpty else { return result }
        let links = result.flatMap(\.rects)
        let box = page.bounds(for: .cropBox)
        for mention in ReferenceScanner.mentions(in: text, plainEquations: plainEquations) {
            guard let selection = page.selection(for: mention.range) else { continue }
            let rects = selection.selectionsByLine().map { $0.bounds(for: page) }.filter { !$0.isEmpty && !$0.isNull }
            guard !rects.isEmpty, !rects.contains(where: { rect in links.contains { $0.intersects(rect) } }) else { continue }
            // Running heads ("Exercises 39") are not references.
            guard !rects.allSatisfy({ $0.minY >= box.maxY - 36 || $0.maxY <= box.minY + 36 }) else { continue }
            result.append(PageMention(key: mention.key, text: mention.text, range: mention.range, rects: rects))
        }
        return result
    }

    /// A link that covers only a number (hyperref links “1.3” in “Theorem 1.3” and “2.1” in “(2.1)”) is named from the
    /// words around it, so that its peek says “Theorem 1.3” and it counts as a reference to that theorem.
    static func contextualKey(for bounds: CGRect, text: String, on page: PDFPage) -> ReferenceKey? {
        guard !text.isEmpty, text.count <= 12, let selection = page.selection(for: bounds), let pageText = page.string,
              selection.numberOfTextRanges(on: page) > 0 else { return nil }
        let link = selection.range(at: 0, on: page)
        let string = pageText as NSString
        guard link.location != NSNotFound, link.length > 0, NSMaxRange(link) <= string.length else { return nil }
        let start = max(0, link.location - 32), end = min(string.length, NSMaxRange(link) + 2)
        let window = string.substring(with: NSRange(location: start, length: end - start))
        let linkStart = link.location - start, linkEnd = NSMaxRange(link) - start
        return ReferenceScanner.mentions(in: window).last {
            $0.range.location <= linkStart && NSMaxRange($0.range) >= linkEnd
        }?.key
    }

    public static func fragments(on page: PDFPage) -> [LayoutFragment] {
        guard let selection = page.selection(for: page.bounds(for: .cropBox)) else { return [] }
        return selection.selectionsByLine().compactMap { line in
            let bounds = line.bounds(for: page)
            // Malformed PDFs can report infinite or absurd boxes; the layout heuristics assume finite geometry.
            guard !bounds.isEmpty, !bounds.isNull, LayoutFragment.isSane(bounds) else { return nil }
            return LayoutFragment(text: line.string ?? "", bounds: bounds)
        }
    }

    /// Line fragments read column by column. PDFKit joins the lines of two columns into one when they share a
    /// baseline and the gutter is narrow (“continuous function, 122 difference quotient, 155”); a column start shared
    /// by many lines in the middle of the page reveals the gutter, and each side is then read on its own.
    public static func columnFragments(on page: PDFPage) -> [LayoutFragment] {
        let lines = fragments(on: page)
        guard lines.count >= 8, let left = lines.map(\.bounds.minX).min(), let right = lines.map(\.bounds.maxX).max(), right - left > 200 else { return lines }
        let middle = (left + (right - left) * 0.3)...(left + (right - left) * 0.7)
        let starts = Dictionary(grouping: lines.filter { middle.contains($0.bounds.minX) }) { Int(($0.bounds.minX / 3).rounded()) }
        // The second column's edge is its leftmost frequent start: its subentries start further right.
        let frequent = starts.filter { $0.value.count >= max(4, lines.count / 8) }
        guard let best = frequent.min(by: { $0.key < $1.key }) else { return lines }
        let start = best.value.map(\.bounds.minX).min()!
        // Lines ending before the second column's start confirm a gutter rather than an indented block.
        guard lines.filter({ $0.bounds.maxX < start - 4 && $0.bounds.minX < middle.lowerBound }).count >= 3,
              lines.contains(where: { $0.bounds.minX < start - 20 && $0.bounds.maxX > start + 20 }) else { return lines }
        let box = page.bounds(for: .cropBox)
        let gutter = start - 2
        let sides = [CGRect(x: box.minX, y: box.minY, width: gutter - box.minX, height: box.height),
                     CGRect(x: gutter, y: box.minY, width: box.maxX - gutter, height: box.height)]
        return sides.flatMap { rect -> [LayoutFragment] in
            guard let selection = page.selection(for: rect) else { return [] }
            return selection.selectionsByLine().compactMap { line in
                let bounds = line.bounds(for: page)
                guard !bounds.isEmpty, !bounds.isNull, LayoutFragment.isSane(bounds) else { return nil }
                return LayoutFragment(text: line.string ?? "", bounds: bounds)
            }
        }
    }

    /// What a page analysis may use beyond the text layer.
    public struct DefinitionOptions: Sendable {
        var imageBounds: [CGRect]?
        /// Bold and italic runs read from the page's fonts (`EmphasisExtractor`): captions, statement heads and
        /// headings are usually set in bold, which tells them apart from a sentence that starts with “Figure 2.1”.
        public var emphasis: [EmphasisRun]?
        /// Whether numbered lines may define sections. Off when the document's outline already numbers its sections:
        /// tables and lists also start lines with numbers.
        public var textHeadings: Bool
        /// Section numbers the outline already defines.
        public var knownSections: Set<String>
        /// Whether a bold number opening a line at body size (“3.15 injectivity ⟺ null space equals {0}”) defines a
        /// numbered result, as in books that number every item in one sequence. The whole-book analysis keeps these
        /// only when the book also names items that way.
        public var numberedResults: Bool
        public init(emphasis: [EmphasisRun]? = nil, textHeadings: Bool = true, knownSections: Set<String> = [], numberedResults: Bool = false) {
            self.emphasis = emphasis; self.textHeadings = textHeadings; self.knownSections = knownSections; self.numberedResults = numberedResults
        }
    }

    private static let plainLabel = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}\)\]_^])\(([1-9]\d{0,2}[a-z]?)\)"#)
    /// “2.35 definition:”, “7.11 example:” · books that number every item in one sequence and name its kind after the number.
    private static let numberFirstItem = try! NSRegularExpression(
        pattern: #"^(\d{1,2}\.\d{1,3})\s+((?i:definition|theorem|lemma|proposition|corollary|example|examples|notation|result|remark|exercise|problem|algorithm))\b\s*:?"#,
        options: [.anchorsMatchLines])
    private static let leadingNumber = try! NSRegularExpression(pattern: #"^(\d{1,2}\.\d{1,3})\s+(?=\S)"#, options: [.anchorsMatchLines])
    /// “Exercises 64” (a contents line or running head), “Figures 2.1 and 2.2”: a plural head names several items and defines none.
    private static let pluralHead = try! NSRegularExpression(
        pattern: #"^(?i:figures|charts|tables|exercises|problems|algorithms|theorems|lemmas|lemmata|definitions|propositions|corollaries|examples|remarks|facts|properties|axioms|hypotheses|claims|conjectures|assumptions|observations|notations)\b"#)
    static func isPluralHead(_ text: String) -> Bool {
        pluralHead.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }
    /// A line opening a caption: “FIGURE 13.3.”, “Figure 2.1:”, “Table 3.2”.
    private static let captionStart = try! NSRegularExpression(pattern: #"^\s*(?:FIGURE|Figure|FIG\.|Fig\.|TABLE|Table)\s*[1-9]"#)
    /// The text of the line before the one containing `location`.
    static func previousLine(before location: Int, in string: NSString) -> String? {
        let start = string.lineRange(for: NSRange(location: location, length: 0)).location
        guard start > 0 else { return nil }
        return string.substring(with: string.lineRange(for: NSRange(location: start - 1, length: 0))).trimmingCharacters(in: .newlines)
    }
    /// Glyphs some books set before an exercise or statement head: a solution mark, a difficulty star, a bullet.
    static let leadingMarks: Set<Character> = ["◃", "▹", "▷", "◁", "⊳", "⊲", "▸", "►", "▶", "★", "☆", "✩", "✱", "∗", "*", "⋆", "•", "†", "‡", "♦", "◦"]

    /// Where an exercise section's numbering stands while the pages are read in order.
    public struct ExerciseSequence: Sendable {
        struct Item: Sendable { let parts: [Int]; let target: ReferenceTarget }
        var last: [Int]?
        var expectFirst = false
        /// A first item whose number does not end in 1 (earlier exercises were set in the text): kept once the next follows it.
        var pending: Item?
        var pagesSinceLast = 0
        public init() {}

        static func follows(_ parts: [Int], after last: [Int]) -> Bool {
            guard let previous = last.last, let current = parts.last, last.count == parts.count, last.dropLast() == parts.dropLast() else { return false }
            return (previous + 1...previous + 3).contains(current)
        }
    }

    /// “Exercises”, “2.7 Exercises”, “EXERCISES”, “Problems”, “Exercises for Section 1.2”, or the running head “Exercises 61” -
    /// but not a contents line, “2.4 Exercises 41”, which has both a section number and a page number.
    private static let exerciseSectionHead = try! NSRegularExpression(
        pattern: #"^\s*(?:\d{1,2}(?:\.\d{1,2})*\.?\s+(?:Exercises|EXERCISES|Problems|PROBLEMS)|(?:Exercises|EXERCISES|Problems|PROBLEMS)(?:\s+(?:for\s+)?(?:(?i:section|chapter)\s+)?[\dA-Z]{1,3}(?:\.\d{1,3})*)?\s*\d{0,4})\s*$"#)
    /// A contents line: a number, a title and a page number (“3.2.1 Agnostic PAC Learning 45”).
    private static let contentsLine = try! NSRegularExpression(pattern: #"^\s*\d{1,2}(?:\.\d{1,3})*\.?\s+\D.*\s\d{1,4}\s*$"#, options: [.anchorsMatchLines])
    /// A line opening with a dotted number and text: “1.4.1. Show that…”, “2.3 Midpoint convexity.”
    private static let numberedItem = try! NSRegularExpression(pattern: #"^[ \t]*([1-9]\d?(?:\.\d{1,3}){1,2})\.?[ \t]+(?=[\p{L}(\[“"])"#)

    /// Exercises numbered without their name inside an exercise section: “Exercises” then “1.4.1. Show that…” (Durrett) or
    /// “2.1 Let C ⊆ Rⁿ be…” (Boyd–Vandenberghe). The first number after the section's heading ends in 1 and each next one
    /// continues the sequence (a missed item or two allowed), so table rows, lists and section headings that open lines with
    /// numbers are left alone. `sequence` carries the numbering from one page to the next; `sections` maps the outline's
    /// section numbers to their pages, so the next chapter's “3.1 Norms” is not taken for exercise 3.1, nor is a line in
    /// bold (`emphasis`), as headings are.
    public static func numberedExercises(on page: PDFPage, pageIndex: Int, sequence: inout ExerciseSequence,
                                         sections: [String: Set<Int>] = [:], emphasis: [EmphasisRun] = []) -> [ReferenceTarget] {
        let boldRuns = emphasis.filter { $0.style == .bold }.map(\.range)
        if sequence.pagesSinceLast > 2 { sequence.last = nil; sequence.expectFirst = false; sequence.pending = nil }
        guard let text = page.string, !text.isEmpty else { sequence.pagesSinceLast += 1; return [] }
        let string = text as NSString
        // A table of contents lists numbered sections and their pages, “Exercises” among them.
        guard contentsLine.numberOfMatches(in: text, range: NSRange(location: 0, length: string.length)) < 6 else { return [] }
        let box = page.bounds(for: .cropBox)
        var cachedFragments: [LayoutFragment]?
        func fragments() -> [LayoutFragment] {
            if let cachedFragments { return cachedFragments }
            let value = Self.fragments(on: page); cachedFragments = value; return value
        }
        var result: [ReferenceTarget] = []
        var location = 0
        // An “Exercises” heading opens the items below it; at the foot of a page, the items on the next page.
        var markerNearEnd = false
        while location < string.length {
            let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
            guard lineRange.length > 0 else { break }
            location = NSMaxRange(lineRange)
            let line = string.substring(with: lineRange).trimmingCharacters(in: .newlines)
            let whole = NSRange(location: 0, length: (line as NSString).length)
            if whole.length <= 48, exerciseSectionHead.firstMatch(in: line, range: whole) != nil {
                sequence.expectFirst = true
                markerNearEnd = string.length - location < 160
                continue
            }
            guard let match = numberedItem.firstMatch(in: line, range: whole) else { continue }
            let number = (line as NSString).substring(with: match.range(at: 1))
            let parts = number.split(separator: ".").compactMap { Int($0) }
            // A section the outline places here, or a line set in bold like a heading, is not an exercise.
            if sections[number]?.contains(pageIndex) == true { continue }
            let rest = NSRange(location: lineRange.location + NSMaxRange(match.range), length: max(0, whole.length - NSMaxRange(match.range)))
            if rest.length > 0, boldRuns.reduce(0, { $0 + NSIntersectionRange($1, rest).length }) * 10 >= rest.length * 6 { continue }
            let continues = sequence.last.map { ExerciseSequence.follows(parts, after: $0) } == true
            let confirms = sequence.pending.map { ExerciseSequence.follows(parts, after: $0.parts) } == true
            guard continues || confirms || sequence.expectFirst else { sequence.pending = nil; continue }
            let range = NSRange(location: lineRange.location + match.range(at: 1).location, length: match.range(at: 1).length)
            guard let label = page.selection(for: range)?.bounds(for: page), !label.isEmpty, !label.isNull, LayoutFragment.isSane(label),
                  label.minY < box.maxY - 40, label.maxY > box.minY + 40 else { continue }
            let region = ReferenceLayout.blockBelow(start: label, fragments: fragments(), page: box, gap: 7, maximumHeight: 230)
            let target = ReferenceTarget(key: ReferenceKey(kind: .exercise, number: number), pageIndex: pageIndex, anchor: PageRegion(label),
                                         region: PageRegion(region), origin: .text, location: range.location)
            if !continues, !confirms, parts.last != 1 {
                // “Exercises” then “2.3.4.”: wait for 2.3.5 before believing it.
                sequence.pending = ExerciseSequence.Item(parts: parts, target: target)
                sequence.expectFirst = false
                continue
            }
            if confirms, let pending = sequence.pending { result.append(pending.target) }
            result.append(target)
            sequence.pending = nil
            sequence.last = parts
            sequence.expectFirst = false
        }
        if sequence.expectFirst, !markerNearEnd { sequence.expectFirst = false }
        sequence.pagesSinceLast = result.isEmpty ? sequence.pagesSinceLast + 1 : 0
        // Each exercise's region stops above the next one on the page.
        for index in result.indices {
            let region = result[index].region.rect
            guard let next = result.filter({ $0.pageIndex == result[index].pageIndex && $0.anchor.rect.maxY < result[index].anchor.rect.minY })
                .max(by: { $0.anchor.rect.maxY < $1.anchor.rect.maxY }) else { continue }
            let floor = next.anchor.rect.maxY + 1
            if floor > region.minY, floor < region.maxY {
                result[index].region = PageRegion(CGRect(x: region.minX, y: floor, width: region.width, height: region.maxY - floor))
            }
        }
        return result
    }

    /// In a book that numbers every item in one sequence, a line opening with a number that falls between two items found
    /// on nearby pages · “6.14 Cauchy–Schwarz inequality” between 6.13 and 6.16 · is an item too, whatever the case of its
    /// title. Only a number followed by a short title on its own line counts: a reference wrapped to the start of a line
    /// (“6.14 implies that…”) continues a sentence across the column.
    public static func interleavedItems(among definitions: [ReferenceTarget], texts: [String], document: PDFDocument,
                                        knownSections: Set<String>) -> [ReferenceTarget] {
        var byChapter: [Int: [(minor: Int, pageIndex: Int)]] = [:]
        for item in definitions where item.numberFirst == true && item.key.kind == .theorem {
            let parts = item.key.number.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 2 else { continue }
            byChapter[parts[0], default: []].append((parts[1], item.pageIndex))
        }
        for chapter in byChapter.keys { byChapter[chapter]?.sort { $0.minor < $1.minor } }
        var taken = Set(definitions.map(\.key.number))
        var result: [ReferenceTarget] = []
        for (pageIndex, text) in texts.enumerated() where !text.isEmpty {
            let string = text as NSString
            for match in leadingNumber.matches(in: text, range: NSRange(location: 0, length: string.length)) {
                let numberRange = match.range(at: 1)
                let number = string.substring(with: numberRange)
                let parts = number.split(separator: ".").compactMap { Int($0) }
                guard parts.count == 2, !taken.contains(number), !knownSections.contains(number), let items = byChapter[parts[0]],
                      let before = items.last(where: { $0.minor < parts[1] }), let after = items.first(where: { $0.minor > parts[1] }),
                      after.minor - before.minor <= 6, (before.pageIndex...after.pageIndex).contains(pageIndex) else { continue }
                let lineEnd = string.lineRange(for: numberRange).upperBound
                let title = string.substring(with: NSRange(location: numberRange.upperBound, length: lineEnd - numberRange.upperBound))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, title.split(separator: " ").count <= 6, !title.hasSuffix("."), !title.hasSuffix(","),
                      let page = document.page(at: pageIndex), let label = page.selection(for: numberRange)?.bounds(for: page),
                      !label.isEmpty, !label.isNull, LayoutFragment.isSane(label) else { continue }
                let box = page.bounds(for: .cropBox)
                let region = ReferenceLayout.blockBelow(start: label, fragments: fragments(on: page), page: box, gap: 7, maximumHeight: 230)
                var target = ReferenceTarget(key: ReferenceKey(kind: .theorem, number: number, name: "Result"), pageIndex: pageIndex,
                                             anchor: PageRegion(label), region: PageRegion(region), origin: .text, location: numberRange.location)
                target.numberFirst = true
                result.append(target)
                taken.insert(number)
            }
        }
        return result
    }

    public static func definitions(on page: PDFPage, pageIndex: Int) -> [ReferenceTarget] {
        definitions(on: page, pageIndex: pageIndex, options: DefinitionOptions())
    }

    public static func definitions(on page: PDFPage, pageIndex: Int, options: DefinitionOptions) -> [ReferenceTarget] {
        guard let text = page.string, !text.isEmpty else { return [] }
        let string = text as NSString
        let box = page.bounds(for: .cropBox)
        var cachedFragments: [LayoutFragment]?
        func fragments() -> [LayoutFragment] {
            if let cachedFragments { return cachedFragments }
            let value = Self.fragments(on: page); cachedFragments = value; return value
        }
        var cachedImages = options.imageBounds
        func imageBounds() -> [CGRect] {
            if let cachedImages { return cachedImages }
            let value = page.pageRef.map { EmphasisContentScanner.scan($0).imageBounds } ?? []
            cachedImages = value
            return value
        }
        func character(_ index: Int) -> Character? {
            guard index >= 0, index < string.length else { return nil }
            return Character(string.substring(with: string.rangeOfComposedCharacterSequence(at: index)))
        }
        func previousIndex(before location: Int) -> Int? {
            var index = location - 1
            while let c = character(index), c == " " || c == "\t" { index -= 1 }
            guard let c = character(index), !c.isNewline else { return nil }
            return index
        }
        /// Whether a label starts a line as the reader sees it. PDFKit's text sometimes joins a page's running head and
        /// first line (“1.5. PROPERTIES OF THE INTEGRAL Theorem 1.5.1. …”); the character before is then on another line.
        func startsLine(_ location: Int, label: CGRect) -> Bool {
            var location = location
            // A mark set before the head (MacKay's “◃ Exercise 1.4.”, a star for a hard problem) does not start the text.
            while let previous = previousIndex(before: location), let c = character(previous), Self.leadingMarks.contains(c) { location = previous }
            guard let previous = previousIndex(before: location) else { return true }
            guard let bounds = PageTextMap.bounds(of: previous, on: page) else { return false }
            return abs(bounds.midY - label.midY) > max(label.height, 4) * 0.7
        }
        func next(after location: Int) -> Character? {
            var index = location
            while let c = character(index), c == " " || c == "\t" { index += 1 }
            return character(index)
        }
        func rect(_ range: NSRange) -> CGRect? {
            guard let bounds = page.selection(for: range)?.bounds(for: page), !bounds.isEmpty, !bounds.isNull, LayoutFragment.isSane(bounds) else { return nil }
            return bounds
        }
        let bold = (options.emphasis ?? []).filter { $0.style == .bold }
        let boldRuns = bold.map(\.range)
        let pageHasBold = !boldRuns.isEmpty
        /// Whether most of `range` is set in bold.
        func isBold(_ range: NSRange) -> Bool {
            let covered = boldRuns.reduce(0) { $0 + NSIntersectionRange($1, range).length }
            return range.length > 0 && Double(covered) >= Double(range.length) * 0.6
        }
        var found: [ReferenceKey: ReferenceTarget] = [:]
        func add(_ key: ReferenceKey, anchor: CGRect, region: CGRect, at location: Int) {
            guard found[key] == nil else { return }
            found[key] = ReferenceTarget(key: key, pageIndex: pageIndex, anchor: PageRegion(anchor), region: PageRegion(region), origin: .text, location: location)
        }
        func inMargin(_ rect: CGRect) -> Bool { rect.minY >= box.maxY - 40 || rect.maxY <= box.minY + 40 }

        // Equation labels: “(2.3)” and, as candidates, undotted “(12)”.
        let mentions = ReferenceScanner.mentions(in: text)
        var labels = mentions.filter { $0.key.kind == .equation && $0.text.hasPrefix("(") }
        let taken = labels.map(\.range)
        for match in plainLabel.matches(in: text, range: NSRange(location: 0, length: string.length))
        where !taken.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
            labels.append(ReferenceMention(key: ReferenceKey(kind: .equation, number: string.substring(with: match.range(at: 1))),
                                           range: match.range, text: string.substring(with: match.range)))
        }
        for mention in labels {
            guard let label = rect(mention.range), !inMargin(label) else { continue }
            if isEquationLabel(mention, label: label, string: string, page: page, fragments: fragments(),
                               previousIndex: previousIndex) {
                add(mention.key, anchor: label, region: ReferenceLayout.equationRegion(label: label, fragments: fragments(), page: box), at: mention.range.location)
            }
        }

        for mention in mentions {
            let key = mention.key
            switch key.kind {
            case .chart:
                guard mention.hasHead, !Self.isPluralHead(mention.text), let label = rect(mention.range), !inMargin(label),
                      startsLine(mention.range.location, label: label) else { continue }
                let endsLabel = next(after: mention.range.upperBound).map { $0.isNewline || ":–—".contains($0) } ?? true
                guard endsLabel && (isBold(mention.range) ||
                    (mention.text.first?.isUppercase == true && ReferenceLayout.isSeparatedAbove(label, fragments: fragments(), page: box))) else { continue }
                add(key, anchor: label, region: ReferenceLayout.chartRegion(caption: label, fragments: fragments(), images: imageBounds(), page: box),
                    at: mention.range.location)
            case .figure, .table, .algorithm, .exercise, .theorem:
                guard mention.hasHead, !Self.isPluralHead(mention.text), let label = rect(mention.range), !inMargin(label),
                      startsLine(mention.range.location, label: label) else { continue }
                let following = next(after: mention.range.upperBound)
                let bold = isBold(mention.range)
                let capitalized = mention.text.first?.isUppercase == true
                switch key.kind {
                case .figure, .table:
                    let headIsCapitalized = mention.text.prefix(3).allSatisfy(\.isUppercase)
                    let punctuated = following.map { ".:\u{2014}–|".contains($0) } ?? true
                    // “Figure 2.1 The line…” or a margin caption whose head stands on its own line.
                    let opensCaption = following.map { $0.isNewline || $0.isUppercase } ?? true
                    guard bold || headIsCapitalized || (capitalized && (punctuated || opensCaption)) else { continue }
                    // The second line of another caption can start with a mention (“…applied to the simulation data of⏎
                    // Figure 13.1. The broken purple curve…”): a line continuing an unfinished caption is not one.
                    if !bold, !headIsCapitalized, let previous = Self.previousLine(before: mention.range.location, in: string),
                       captionStart.firstMatch(in: previous, range: NSRange(location: 0, length: (previous as NSString).length)) != nil,
                       previous.trimmingCharacters(in: .whitespaces).last.map({ !".!?".contains($0) }) == true { continue }
                    // A caption is set apart from the paragraph above it; a sentence ending "…in\nFigure 2.1." is not.
                    guard bold || headIsCapitalized || ReferenceLayout.isSeparatedAbove(label, fragments: fragments(), page: box) else { continue }
                    let region = key.kind == .figure
                        ? ReferenceLayout.figureRegion(caption: label, fragments: fragments(), page: box)
                        : ReferenceLayout.blockBelow(start: label, fragments: fragments(), page: box, gap: 17, maximumHeight: 320, stopAtBodyText: true)
                    add(key, anchor: label, region: region, at: mention.range.location)
                default:
                    if capitalized || bold {
                        guard following.map({ $0.isNewline || ".:(".contains($0) || $0.isUppercase }) ?? true else { continue }
                    } else {
                        // Small capitals print “lemma 16.2”; a lower-case head elsewhere is a sentence continuing from the line
                        // above · unless space sets it apart from that line (“definition 10.1 (γ-Weak-Learnability)”, or a head
                        // whose first words PDFKit moved after it).
                        guard following.map({ $0 == "." || $0.isUppercase }) == true
                                || ReferenceLayout.isSeparatedAbove(label, fragments: fragments(), page: box) else { continue }
                    }
                    let gap: CGFloat = key.kind == .algorithm ? 12 : 7
                    add(key, anchor: label, region: ReferenceLayout.blockBelow(start: label, fragments: fragments(), page: box, gap: gap, maximumHeight: key.kind == .algorithm ? 280 : 230),
                        at: mention.range.location)
                }
            default:
                continue
            }
        }

        // Items numbered first: “2.35 definition: dimension” (named), or a bold “3.15” opening a result.
        let whole = NSRange(location: 0, length: string.length)
        for match in numberFirstItem.matches(in: text, range: whole) {
            let number = string.substring(with: match.range(at: 1))
            guard !options.knownSections.contains(number), let label = rect(match.range), !inMargin(label) else { continue }
            let name = ReferenceScanner.statementName(string.substring(with: match.range(at: 2)))
            let kind: ReferenceKind = name == "Exercise" || name == "Problem" ? .exercise : name == "Algorithm" ? .algorithm : .theorem
            let key = kind == .theorem ? ReferenceKey(kind: .theorem, number: number, name: name) : ReferenceKey(kind: kind, number: number)
            add(key, anchor: label, region: ReferenceLayout.blockBelow(start: label, fragments: fragments(), page: box, gap: 7, maximumHeight: 230),
                at: match.range.location)
            found[key]?.numberFirst = true
        }
        if options.numberedResults {
            for match in leadingNumber.matches(in: text, range: whole) {
                let numberRange = match.range(at: 1)
                let number = string.substring(with: numberRange)
                // A numbered result opens with its number and a title: in bold (“3.15 injectivity…”), or a lower-case
                // title after a plain number (“1.26 unique additive identity”). A heading's number is bold too, but set
                // larger than the text and known to the outline; the analysis keeps these only in books numbered this way.
                let after = numberRange.upperBound < string.length ? string.substring(with: NSRange(location: numberRange.upperBound, length: min(3, string.length - numberRange.upperBound))) : ""
                let lowerTitle = after.trimmingCharacters(in: .whitespaces).first?.isLowercase == true
                let boldNumber = isBold(numberRange) && bold.first(where: { NSIntersectionRange($0.range, numberRange).length > 0 }).map { (0.8...1.12).contains($0.relativeSize) } == true
                guard boldNumber || lowerTitle, !options.knownSections.contains(number), !found.keys.contains(where: { $0.number == number }),
                      let label = rect(numberRange), !inMargin(label) else { continue }
                let key = ReferenceKey(kind: .theorem, number: number, name: "Result")
                add(key, anchor: label, region: ReferenceLayout.blockBelow(start: label, fragments: fragments(), page: box, gap: 7, maximumHeight: 230), at: numberRange.location)
                found[key]?.numberFirst = true
            }
        }

        if options.textHeadings {
            for heading in ReferenceScanner.headings(in: text) {
                // Running heads repeat a section number ("2.3 Least Squares… 13") at the top of many pages.
                guard let label = rect(heading.range), !inMargin(label) else { continue }
                // When the page's fonts are known, a heading's number is bold: table rows and lists are not.
                if pageHasBold, !isBold(heading.range) { continue }
                if options.knownSections.contains(heading.key.number) { continue }
                add(heading.key, anchor: label, region: ReferenceLayout.blockBelow(start: label, fragments: fragments(), page: box, gap: 8, maximumHeight: 110),
                    at: heading.range.location)
            }
        }
        return found.values.sorted { $0.anchor.y > $1.anchor.y }
    }

    /// Whether a parenthesized number at `label` is a displayed equation's own label: it ends its line flush with
    /// the column's right edge, apart from the formula, or starts a formula's line at the column's left edge.
    static func isEquationLabel(_ mention: ReferenceMention, label: CGRect, string: NSString, page: PDFPage, fragments: [LayoutFragment],
                                previousIndex: (Int) -> Int?) -> Bool {
        let box = page.bounds(for: .cropBox)
        let lineEnd = string.lineRange(for: NSRange(location: mention.range.upperBound, length: 0)).upperBound
        let rest = string.substring(with: NSRange(location: mention.range.upperBound, length: max(0, lineEnd - mention.range.upperBound)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let column = ReferenceLayout.column(containing: label.midX, near: label.midY, fragments: fragments, page: box)
        let previous = previousIndex(mention.range.location)
        // Left labels (“leqno”): first on their line, at the column's left edge, with a formula · not prose · beside them.
        if previous == nil, label.minX <= column.lowerBound + 3, !ReferenceLayout.isProse(rest) {
            let beside = fragments.filter { fragment in
                let overlap = min(fragment.bounds.maxY, label.maxY) - max(fragment.bounds.minY, label.minY)
                return overlap > 0.4 * min(label.height, fragment.bounds.height) && fragment.bounds.minX > label.maxX + 3
            }
            // A displayed formula is set apart from its label (centred); prose would follow the label at a word space.
            if let nearest = beside.min(by: { $0.bounds.minX < $1.bounds.minX }),
               nearest.bounds.minX - label.maxX >= 12 || !beside.contains(where: { ReferenceLayout.isProse($0.text) }) { return true }
        }
        // Defining labels end their line, flush with the column, apart from the formula. A summation's
        // limits ("j=1") can follow the label in the text layer although they sit on another line.
        guard rest.isEmpty || (rest.count <= 8 && !rest.contains("(") && !ReferenceLayout.isProse(rest)) else { return false }
        guard label.maxX >= column.upperBound - 3 else { return false }
        if let previous {
            let bounds = PageTextMap.bounds(of: previous, on: page) ?? .null
            let sameLine = abs(bounds.midY - label.midY) < max(label.height, 4) * 0.8
            let gap = label.minX - bounds.maxX
            if sameLine, gap < 10 {
                // "…given by (2.8)" ending a justified prose line: a word sits just before the label. A wide display
                // can also end close to its label (“+ hp(Xp)ᵀθp, (5.6)”); there the text before is a formula, not prose.
                let lineStart = string.lineRange(for: NSRange(location: mention.range.location, length: 0)).location
                let before = string.substring(with: NSRange(location: lineStart, length: mention.range.location - lineStart))
                if ReferenceLayout.isProse(before) { return false }
                let trailingWord = before.trimmingCharacters(in: .whitespaces).reversed().prefix { $0.isASCII && $0.isLetter }
                if trailingWord.count >= 2, gap >= 0 { return false }
            }
        }
        return true
    }

    /// The item numbered `number` defined within 40 pt of `point` vertically: a link's destination sits at its item or
    /// just above it. A number without a letter also names its lettered equations (“(15)” for 15a and 15b), which give
    /// their regions together, anchored at the first.
    static func definition(numbered number: String, at point: CGPoint?, in defined: [ReferenceTarget]) -> ReferenceTarget? {
        guard let point else { return nil }
        func distance(_ target: ReferenceTarget) -> CGFloat {
            let region = target.region.rect
            return point.y > region.maxY ? point.y - region.maxY : point.y < region.minY ? region.minY - point.y : 0
        }
        let near = defined.filter { distance($0) <= 40 }
        if let exact = near.filter({ $0.key.number == number }).min(by: { distance($0) < distance($1) }) { return exact }
        let parts = near.filter {
            $0.key.kind == .equation && $0.key.number.count > number.count && $0.key.number.hasPrefix(number)
                && $0.key.number.dropFirst(number.count).allSatisfy(\.isLetter)
        }
        guard var whole = parts.max(by: { $0.anchor.rect.maxY < $1.anchor.rect.maxY }) else { return nil }
        whole.region = PageRegion(parts.reduce(whole.region.rect) { $0.union($1.region.rect) })
        return whole
    }

    /// A destination from a PDF link or an outline entry. Uses the text definition on that page when one matches: the
    /// same key, or for a link read only as its number (hyperref links “4a” inside “(4a)”) the item with that number
    /// defined where the link points.
    public static func target(for destination: LinkDestination, key: ReferenceKey, in document: PDFDocument, origin: ReferenceTarget.Origin) -> ReferenceTarget? {
        guard let page = document.page(at: destination.pageIndex) else { return nil }
        let defined = definitions(on: page, pageIndex: destination.pageIndex)
        var pageKey = key
        if key.kind == .chart { pageKey.name = nil }
        if var target = defined.first(where: { $0.key == pageKey }) {
            target.key = key; target.origin = origin; return target
        }
        if key.kind == .link, var target = definition(numbered: key.number, at: destination.point, in: defined) {
            target.origin = origin; return target
        }
        let box = page.bounds(for: .cropBox)
        var point = destination.point ?? CGPoint(x: box.minX, y: box.maxY)
        let lines = fragments(on: page)
        if key.kind == .link, let note = ReferenceLayout.footnoteRegion(linkText: key.number, at: point, fragments: lines, page: box) {
            return ReferenceTarget(key: key, pageIndex: destination.pageIndex, anchor: PageRegion(note.anchor),
                                   region: PageRegion(note.region), origin: origin)
        }
        // Box bookmarks can sit above the heading and to the left of the body column.
        let label = key.kind == .box ? boxLabel(key, near: point, on: page) : nil
        if let label { point = CGPoint(x: label.minX, y: label.maxY) }
        let x = min(max(point.x, box.minX), box.maxX)
        let column = ReferenceLayout.column(containing: x, near: point.y, fragments: lines, page: box)
        let left = key.kind == .box || key.kind == .specialFeature ? min(x, column.lowerBound) : column.lowerBound
        let top = min(point.y + 6, box.maxY)
        let height = min(170, max(24, top - box.minY))
        let region = CGRect(x: left - 4, y: top - height, width: column.upperBound - left + 8, height: height).intersection(box)
        let anchor = label ?? CGRect(x: left, y: top - 14, width: column.upperBound - left, height: 14).intersection(box)
        return ReferenceTarget(key: key, pageIndex: destination.pageIndex, anchor: PageRegion(anchor), region: PageRegion(region), origin: origin)
    }

    private static func boxLabel(_ key: ReferenceKey, near point: CGPoint, on page: PDFPage) -> CGRect? {
        guard let text = page.string else { return nil }
        return ReferenceScanner.mentions(in: text).lazy.filter { $0.key == key }.compactMap {
            page.selection(for: $0.range)?.bounds(for: page)
        }.first { abs($0.minX - point.x) <= 16 && abs($0.maxY - point.y) <= 32 && !$0.isEmpty && LayoutFragment.isSane($0) }
    }

    private static func specified(_ point: CGPoint) -> CGPoint? {
        // PDFKit reports an unspecified coordinate as kPDFDestinationUnspecifiedValue.
        guard point.x.isFinite, point.y.isFinite, abs(point.x) < 1e6, abs(point.y) < 1e6 else { return nil }
        return point
    }
}

extension ReferenceLayout {
    /// A PDF link to a numbered footnote can land in a different column from the main text. Confirm the number
    /// at the destination, then include its indented continuation lines up to the next note.
    static func footnoteRegion(linkText: String, at point: CGPoint, fragments: [LayoutFragment], page: CGRect) -> (anchor: CGRect, region: CGRect)? {
        guard linkText.count <= 6, point.y <= page.minY + page.height / 3 else { return nil }
        let number = String(linkText.reversed().prefix(while: \.isNumber).reversed())
        guard !number.isEmpty, let label = fragments.first(where: {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == number &&
            abs($0.bounds.minX - point.x) <= 10 && abs($0.bounds.maxY - point.y) <= 8
        })?.bounds else { return nil }
        let below = fragments.filter {
            $0.bounds.minX >= label.minX - 2 && $0.bounds.maxY <= label.maxY + 3 && $0.bounds.minY > page.minY + 36
        }
        let lines = rows(below, in: page.minX...page.maxX)
        guard let first = lines.firstIndex(where: { $0.minY <= label.midY && $0.maxY >= label.midY }) else { return nil }
        var last = first
        while last + 1 < lines.count, lines[last + 1].minX > label.minX + 2,
              lines[last].minY - lines[last + 1].maxY <= 6 { last += 1 }
        let right = lines[first...last].map(\.maxX).max() ?? label.maxX
        let region = CGRect(x: label.minX, y: lines[last].minY, width: right - label.minX, height: lines[first].maxY - lines[last].minY)
        return (label, padded(region, page: page))
    }

    /// Whether the line at `rect` starts a new block: nothing above, a visible gap, or non-body content above.
    public static func isSeparatedAbove(_ rect: CGRect, fragments: [LayoutFragment], page: CGRect) -> Bool {
        let column = column(containing: rect.midX, near: rect.midY, fragments: fragments, page: page, margins: true)
        let rows = rows(fragments, in: (column.lowerBound - 2)...(column.upperBound + 2))
        guard let index = rows.firstIndex(where: { $0.maxY >= rect.midY && $0.minY <= rect.midY }), index > 0 else { return true }
        let above = rows[index - 1]
        return above.minY - rows[index].maxY >= 6 || !isBodyText(above, column: column)
    }
}

/// Persisted reference scanning, so a book is analysed once. Bump `currentVersion` when heuristics change.
public struct ReferenceCache: Codable, Sendable {
    public static let currentVersion = 4
    public var version = ReferenceCache.currentVersion
    public var scannedPages: Set<Int> = []
    public var targets: [ReferenceTarget] = []
    public init() {}
}

extension DocumentIndexRepository {
    private func referenceCacheURL(_ id: String) -> URL { directory(id).appendingPathComponent("references.json") }

    public func referenceCache(_ id: String) -> ReferenceCache? {
        guard let data = try? Data(contentsOf: referenceCacheURL(id)),
              let cache = try? WorkspaceRepository.decoder.decode(ReferenceCache.self, from: data),
              cache.version == ReferenceCache.currentVersion else { return nil }
        return cache
    }

    public func save(_ cache: ReferenceCache, id: String) throws {
        try FileManager.default.createDirectory(at: directory(id), withIntermediateDirectories: true)
        try WorkspaceRepository.encoder.encode(cache).write(to: referenceCacheURL(id), options: .atomic)
    }
}
