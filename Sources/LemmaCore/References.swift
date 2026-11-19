import Foundation
import PDFKit

/// A numbered object that a book or paper refers to in its own text.
public enum ReferenceKind: String, Codable, CaseIterable, Sendable {
    case equation, figure, chart, table, box, section, chapter, specialFeature, exercise, algorithm, theorem, link, citation

    public var label: String {
        switch self {
        case .equation: "Equation"; case .figure: "Figure"; case .chart: "Chart"; case .table: "Table"; case .box: "Box"
        case .section: "Section"; case .chapter: "Chapter"; case .specialFeature: "Special Feature"
        case .exercise: "Exercise"; case .algorithm: "Algorithm"; case .theorem: "Statement"
        case .link: "Link"; case .citation: "Citation"
        }
    }

    public var symbol: String {
        switch self {
        case .equation: "function"; case .figure, .chart: "chart.xyaxis.line"; case .table: "tablecells"; case .box: "text.rectangle"
        case .section, .specialFeature: "list.bullet.indent"; case .chapter: "book"; case .exercise: "pencil.and.list.clipboard"
        case .algorithm: "list.number"; case .theorem: "checkmark.seal"; case .link: "link"; case .citation: "quote.opening"
        }
    }
}

/// Identifies one numbered object, independent of how a sentence spells it.
/// `name` distinguishes theorem-like statements and lettered charts that repeat in different boxes.
public struct ReferenceKey: Hashable, Codable, Sendable {
    public var kind: ReferenceKind
    public var number: String
    public var name: String?

    public init(kind: ReferenceKind, number: String, name: String? = nil) {
        self.kind = kind; self.number = number; self.name = name
    }

    /// How the reader sees the object named, for example "(2.3)", "Figure 2.1" or "Lemma 4.2".
    public var title: String {
        switch kind {
        case .equation: "(\(number))"
        case .theorem: "\(name ?? "Statement") \(number)"
        case .link: number
        case .citation: name ?? "Reference \(number)"
        default: "\(kind.label) \(number)"
        }
    }

    /// A longer description for headers and accessibility, for example "Equation (2.3)".
    public var spokenTitle: String {
        if kind == .equation { return "Equation (\(number))" }
        if kind == .chart, let name { return "\(title) (\(name))" }
        return title
    }

    /// The text to search for when listing the places that mention this object.
    public var searchText: String {
        switch kind {
        case .equation: "(\(number))"
        case .citation: (name ?? "").components(separatedBy: CharacterSet(charactersIn: " (")).first ?? ""
        default: title
        }
    }

    /// The leading chapter number of a dotted label, used to narrow the pages to inspect.
    public var chapter: Int? {
        if kind == .chapter { return Int(number) }
        guard kind != .link, kind != .citation, number.contains(".") else { return nil }
        return Int(number.prefix { $0.isNumber })
    }
}

/// One place where the text mentions a numbered object. Ranges are UTF-16 offsets into the scanned string.
public struct ReferenceMention: Equatable, Sendable {
    public var key: ReferenceKey
    public var range: NSRange
    public var text: String
    /// True for the first item of a list, which carries the word ("Figures 2.1"), and for standalone mentions.
    public var hasHead: Bool
    public init(key: ReferenceKey, range: NSRange, text: String, hasHead: Bool = true) {
        self.key = key; self.range = range; self.text = text; self.hasHead = hasHead
    }
}

/// Literal recognition of common numbering conventions in mathematical books and papers.
/// It finds spellings such as "(2.3)", "Figures 2.1, 2.2 and 2.3", "Section 2.3.3" or "Ex. 2.8".
/// Whether a mention is the defining occurrence is decided separately from page layout.
public enum ReferenceScanner {
    /// A letter suffix (“2.1a”) is kept only when no other letter follows: some PDFs drop the space after a number
    /// (“Figure3.15illustrates”), and the number must still be read.
    private static let number = "[1-9]\\d?(?:\\.\\d{1,3}){0,3}(?:[a-z](?!\\p{L}))?"
    /// Dotted equation labels, including appendix labels such as “(A.1)”.
    private static let dottedNumber = "(?:[1-9]\\d?|[A-Z])(?:\\.\\d{1,3}){1,3}[a-z]?"

    private static let equation = try! NSRegularExpression(pattern: "(?<![\\p{N}\\)\\]_^])\\((\(dottedNumber))\\)")
    /// Undotted labels such as “(12)”: papers number their equations this way, but so do lists and enumerations.
    /// They are references only in a document known to define such an equation.
    private static let plainEquation = try! NSRegularExpression(pattern: "(?<![\\p{N}\\)\\]_^])\\(([1-9]\\d{0,2}[a-z]?)\\)")
    /// Letters right before a parenthesis: a function's name (“f(1)”, “sin(2)”) unless they run to four or more, prose
    /// whose space the text layer lost (“substituting(25)into(24a)”).
    private static let functionName = try! NSRegularExpression(pattern: "(?<!\\p{L})\\p{L}{1,3}\\z")
    private static let prefixedEquation = try! NSRegularExpression(pattern: "\\b(?:[Ee]qs?\\.|[Ee]quations?|EQUATIONS?)\\s*\\(([1-9]\\d{0,2}[a-z]?)\\)")
    private static let separator = try! NSRegularExpression(pattern: "(?:\\s*,\\s*(?:and\\s+|&\\s*)?|\\s+and\\s+|\\s*&\\s*|\\s*[–\u{2014}-]\\s*|\\s+to\\s+)")
    private static let listedNumber = try! NSRegularExpression(pattern: "(\(number))(?![\\p{N}])")
    private static let chartNumber = try! NSRegularExpression(pattern: "(\(number)|[A-Z](?:(?:\\.\\d{1,3}){1,3}[a-z]?)?)(?![\\p{L}\\p{N}]|\\.\\d)")
    private static let featureLetter = try! NSRegularExpression(pattern: #"([A-Z])(?![\p{L}\p{N}]|\.\d)"#)
    private static let listedEquation = try! NSRegularExpression(pattern: "\\(([1-9]\\d{0,2}[a-z]?)\\)")
    private static let heading = try! NSRegularExpression(pattern: "^(\\d{1,2}(?:\\.\\d{1,2}){1,3})\\.?\\s*(?=\\p{Lu}[\\p{Ll}\\p{Lu}])", options: [.anchorsMatchLines])

    private struct Head {
        let expression: NSRegularExpression
        let kind: ReferenceKind
        let named: Bool
        var label = ReferenceScanner.listedNumber
    }

    /// Heads match in any case: some books write “figure 3.7” and “section 2.3” in running text, and small capitals
    /// print “lemma 16.2” in lower case. Lower-case mentions that name nothing the book defines are dropped later.
    private static let heads: [Head] = [
        Head(expression: try! NSRegularExpression(pattern: "\\b(?i:figures?|figs?\\.)\\s*(?=[1-9])"), kind: .figure, named: false),
        Head(expression: try! NSRegularExpression(pattern: #"\b(?i:charts?)\s*(?=[1-9A-Z])"#), kind: .chart, named: false, label: chartNumber),
        Head(expression: try! NSRegularExpression(pattern: "\\b(?i:tables?|tabs?\\.)\\s*(?=[1-9])"), kind: .table, named: false),
        Head(expression: try! NSRegularExpression(pattern: #"\b(?i:box(?:es)?)\s*(?=[1-9])"#), kind: .box, named: false),
        Head(expression: try! NSRegularExpression(pattern: #"\b(?i:special\s+features?)\s+(?=[A-Z])"#), kind: .specialFeature, named: false, label: featureLetter),
        Head(expression: try! NSRegularExpression(pattern: "(?:\\b(?i:sections?|sects?\\.|secs?\\.)\\s*|§§?\\s*)(?=[1-9])"), kind: .section, named: false),
        Head(expression: try! NSRegularExpression(pattern: "\\b(?i:chapters?|chaps?\\.)\\s*(?=[1-9])"), kind: .chapter, named: false),
        Head(expression: try! NSRegularExpression(pattern: "\\b(?i:exercises?|exs?\\.|problems?|probs?\\.)\\s*(?=[1-9])"), kind: .exercise, named: false),
        Head(expression: try! NSRegularExpression(pattern: "\\b(?i:algorithms?|alg\\.)\\s*(?=[1-9])"), kind: .algorithm, named: false),
        Head(expression: try! NSRegularExpression(pattern: "\\b((?i:theorems?|thm\\.|lemmas?|lemmata|lem\\.|propositions?|prop\\.|corollar(?:y|ies)|cor\\.|definitions?|defn?\\.|examples?|remarks?|assumptions?|conjectures?|claims?|facts?|propert(?:y|ies)|hypothes[ie]s|axioms?))\\s*(?=[1-9])"),
             kind: .theorem, named: true)
    ]

    /// - Parameter plainEquations: undotted equation labels the document defines (“12” for “(12)”); a parenthesized
    ///   number is an equation reference only when it names one of them.
    public static func mentions(in text: String, plainEquations: Set<String> = []) -> [ReferenceMention] {
        let string = text as NSString
        let whole = NSRange(location: 0, length: string.length)
        var found: [ReferenceMention] = []
        func anchored(_ expression: NSRegularExpression, at location: Int) -> NSTextCheckingResult? {
            guard location <= string.length else { return nil }
            return expression.firstMatch(in: text, options: [.anchored], range: NSRange(location: location, length: string.length - location))
        }
        func appliesFunction(_ match: NSTextCheckingResult) -> Bool {
            let start = max(0, match.range.location - 4)
            return functionName.firstMatch(in: text, range: NSRange(location: start, length: match.range.location - start)) != nil
        }
        for match in equation.matches(in: text, range: whole) where !appliesFunction(match) {
            let label = string.substring(with: match.range(at: 1))
            found.append(ReferenceMention(key: ReferenceKey(kind: .equation, number: label), range: match.range, text: string.substring(with: match.range)))
        }
        if !plainEquations.isEmpty {
            for match in plainEquation.matches(in: text, range: whole) where !appliesFunction(match) {
                let label = string.substring(with: match.range(at: 1))
                guard plainEquations.contains(label) else { continue }
                found.append(ReferenceMention(key: ReferenceKey(kind: .equation, number: label), range: match.range, text: string.substring(with: match.range)))
            }
        }
        for match in prefixedEquation.matches(in: text, range: whole) {
            var item = match.range(at: 1)
            var first = true
            while true {
                let parenthesized = NSRange(location: item.location - 1, length: item.length + 2)
                if !found.contains(where: { NSIntersectionRange($0.range, parenthesized).length > 0 }) {
                    found.append(ReferenceMention(key: ReferenceKey(kind: .equation, number: string.substring(with: item)),
                        range: first ? NSRange(location: match.range.location, length: parenthesized.upperBound - match.range.location) : parenthesized,
                        text: string.substring(with: parenthesized), hasHead: first))
                }
                first = false
                guard let gap = anchored(separator, at: parenthesized.upperBound),
                      let next = anchored(listedEquation, at: gap.range.upperBound) else { break }
                item = next.range(at: 1)
            }
        }
        for head in heads {
            for match in head.expression.matches(in: text, range: whole) {
                let name = head.named ? statementName(string.substring(with: match.range(at: 1))) : nil
                var location = match.range.upperBound
                var first = true, dotted = false, count = 0
                while count < 8, let item = anchored(head.label, at: location) {
                    let label = string.substring(with: item.range(at: 1))
                    // List items share the first item's shape: "Figures 2.1 and 2.2", never "Figure 2.1 and 15 points".
                    if first { dotted = label.contains(".") } else if label.contains(".") != dotted { break }
                    let range = first ? NSRange(location: match.range.location, length: item.range.upperBound - match.range.location) : item.range
                    if !(head.kind == .chapter && dotted) {
                        found.append(ReferenceMention(key: ReferenceKey(kind: head.kind, number: label, name: name), range: range,
                                                      text: string.substring(with: range), hasHead: first))
                    }
                    first = false; count += 1
                    location = item.range.upperBound
                    guard let gap = anchored(separator, at: location) else { break }
                    location = gap.range.upperBound
                }
            }
        }
        return found.sorted { $0.range.location == $1.range.location ? $0.range.length > $1.range.length : $0.range.location < $1.range.location }
            .reduce(into: []) { result, mention in
                // A single place in the text names one object.
                if let last = result.last, NSIntersectionRange(last.range, mention.range).length > 0 { return }
                result.append(mention)
            }
    }

    /// Section headings ("2.3.3 From Least Squares…") at the start of a short line. Numbers must look like section
    /// numbers: no leading zeros, a chapter below 40 and parts below 40, so table rows (“6.66 ResNet”, “25.03 …”) are not read as headings.
    public static func headings(in text: String) -> [ReferenceMention] {
        let string = text as NSString
        return heading.matches(in: text, range: NSRange(location: 0, length: string.length)).compactMap { match in
            let line = string.substring(with: string.lineRange(for: match.range))
            guard line.count < 110 else { return nil }
            let label = string.substring(with: match.range(at: 1))
            guard isSectionNumber(label) else { return nil }
            return ReferenceMention(key: ReferenceKey(kind: .section, number: label), range: match.range(at: 1), text: label)
        }
    }

    static func isSectionNumber(_ label: String) -> Bool {
        let parts = label.split(separator: ".").map(String.init)
        guard let first = parts.first.flatMap({ Int($0) }), first < 40 else { return false }
        for (index, part) in parts.enumerated() {
            guard let value = Int(part) else { return false }
            if part.count > 1 && part.hasPrefix("0") { return false }
            if index > 0 && (value == 0 || value >= 40) { return false }
        }
        // “0.50” is a number; chapter 0 has single-digit sections (“0.1”).
        return !(first == 0 && parts.count > 1 && parts[1].count > 1)
    }

    static func statementName(_ word: String) -> String {
        let lower = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let names: [(String, String)] = [
            ("thm", "Theorem"), ("theorem", "Theorem"), ("lem", "Lemma"), ("propert", "Property"), ("prop", "Proposition"),
            ("cor", "Corollary"), ("def", "Definition"), ("example", "Example"),
            ("remark", "Remark"), ("assumption", "Assumption"), ("conjecture", "Conjecture"), ("claim", "Claim"),
            ("fact", "Fact"), ("observation", "Observation"), ("hypothes", "Hypothesis"), ("axiom", "Axiom")
        ]
        return names.first { lower.hasPrefix($0.0) }?.1 ?? word.capitalized
    }
}

/// Where a numbered object is defined: its label, caption or heading, plus the region worth showing.
public struct ReferenceTarget: Codable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable { case text, outline, link }
    public var key: ReferenceKey
    public var pageIndex: Int
    public var anchor: PageRegion
    public var region: PageRegion
    public var origin: Origin
    /// Where the label starts in the page's text layer (UTF-16), for definitions read from the text.
    public var location: Int?
    /// Read from a number opening a line (“2.35 definition:”, “1.26 unique additive identity”): kept only in books that
    /// number every item that way, since elsewhere such a line is a section heading (“10.8 Example: Spam Data”).
    public var numberFirst: Bool?
    public init(key: ReferenceKey, pageIndex: Int, anchor: PageRegion, region: PageRegion, origin: Origin, location: Int? = nil) {
        self.key = key; self.pageIndex = pageIndex; self.anchor = anchor; self.region = region; self.origin = origin; self.location = location
    }
}

/// One visual line fragment of a page, in PDF page coordinates (origin at the lower left).
public struct LayoutFragment: Equatable, Sendable {
    public var text: String
    public var bounds: CGRect
    public init(text: String, bounds: CGRect) { self.text = text; self.bounds = bounds }

    /// Finite and within a generous page-sized range: anything else comes from a malformed PDF.
    public static func isSane(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy { $0.isFinite && abs($0) < 1e5 }
    }
}

/// Geometry heuristics for single text columns. They estimate what to show around a definition;
/// they do not parse mathematics, and the reader can always scroll the live page.
public enum ReferenceLayout {
    struct Row {
        var fragments: [LayoutFragment]
        var minY: CGFloat
        var maxY: CGFloat
        var text: String { fragments.sorted { $0.bounds.minX < $1.bounds.minX }.map(\.text).joined(separator: " ") }
        var minX: CGFloat { fragments.map(\.bounds.minX).min() ?? 0 }
        var maxX: CGFloat { fragments.map(\.bounds.maxX).max() ?? 0 }
        var width: CGFloat { maxX - minX }
    }

    private static let prose = try! NSRegularExpression(pattern: "(?<!\\p{L})(\\p{Latin}{2,})[,;:.’'”)]?\\s+(\\p{Latin}{2,})[,;:.’'”)]?\\s+(\\p{Latin}{2,})(?!\\p{L})")

    /// Three consecutive Latin-script words, one of at least four letters, read as prose.
    /// Formulas rarely contain them: “εk. Xj βjk” or “ORANGE if” are symbols, not sentences.
    public static func isProse(_ text: String) -> Bool {
        let string = text as NSString
        var location = 0
        while location < string.length,
              let match = prose.firstMatch(in: text, range: NSRange(location: location, length: string.length - location)) {
            if (1...3).contains(where: { match.range(at: $0).length >= 4 }) { return true }
            location = match.range(at: 1).upperBound
        }
        return false
    }

    /// Body text starts at the column's left edge (allowing a paragraph indent); displays are inset.
    /// A paragraph's short last line ("output", "the rule") is body text as well.
    static func isBodyText(_ row: Row, column: ClosedRange<CGFloat>) -> Bool {
        guard row.minX <= column.lowerBound + 16 else { return false }
        if isProse(row.text) { return true }
        let words = row.text.split(whereSeparator: \.isWhitespace).map(String.init)
        return !words.isEmpty && words.count <= 3 && words.contains { $0.count >= 4 }
            && words.allSatisfy { latinWord.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }
    }
    private static let latinWord = try! NSRegularExpression(pattern: "^\\p{Latin}{2,}[,;:.]?$")

    /// The text column containing `x` near height `y`. Two-column pages are split at an empty gutter.
    /// - Parameter margins: a point beside the text column belongs to the margin's own column (side captions,
    ///   margin notes). Off for equation labels, which may stand a little outside ragged prose.
    public static func column(containing x: CGFloat, near y: CGFloat? = nil, fragments: [LayoutFragment], page: CGRect, margins: Bool = false) -> ClosedRange<CGFloat> {
        let pageRange = page.minX <= page.maxX ? page.minX...page.maxX : 0...612
        var wide = fragments.filter { $0.bounds.width >= 60 && $0.bounds.minX.isFinite && $0.bounds.maxX.isFinite && $0.bounds.midY.isFinite }
        if let y {
            let nearby = wide.filter { abs($0.bounds.midY - y) <= 220 }
            if nearby.count >= 4 { wide = nearby }
        }
        guard let left = wide.map(\.bounds.minX).min(), let right = wide.map(\.bounds.maxX).max(), x.isFinite else { return pageRange }
        let gutter = stride(from: left + (right - left) * 0.35, through: left + (right - left) * 0.65, by: 2).first { gutter in
            !wide.contains { $0.bounds.minX < gutter - 3 && $0.bounds.maxX > gutter + 3 }
                && wide.contains { $0.bounds.maxX <= gutter } && wide.contains { $0.bounds.minX >= gutter }
        }
        let side = gutter.map { gutter in wide.filter { x < gutter ? $0.bounds.maxX <= gutter : $0.bounds.minX >= gutter } } ?? wide
        guard let sideLeft = side.map(\.bounds.minX).min(), let sideRight = side.map(\.bounds.maxX).max() else { return pageRange }
        var lower = edge(side.map(\.bounds.minX), fallback: sideLeft), upper = edge(side.map(\.bounds.maxX), fallback: sideRight)
        if lower > upper {
            // The most common edges come from different columns · MacKay's text column ends at 396 while more margin notes
            // start at 412: the lines passing through `x` belong to the column in question.
            let through = side.filter { $0.bounds.minX <= x && $0.bounds.maxX >= x }
            if through.count >= 3, let left = through.map(\.bounds.minX).min(), let right = through.map(\.bounds.maxX).max() {
                lower = edge(through.map(\.bounds.minX), fallback: left)
                upper = edge(through.map(\.bounds.maxX), fallback: right)
            }
        }
        // The most common left and right edges can come from different lines (ragged or indented text, margin notes);
        // when they still cross, the column's extreme edges are the safer answer.
        let column = lower <= upper ? lower...upper : sideLeft...max(sideLeft, sideRight)
        // A point in a margin beside the text column (side captions, margin notes) belongs to the margin's own column.
        if margins, x > column.upperBound + 4 || x < column.lowerBound - 4 {
            let outside = fragments.filter { fragment in
                let side = x > column.upperBound ? fragment.bounds.minX > column.upperBound - 2 : fragment.bounds.maxX < column.lowerBound + 2
                let near = y.map { abs(fragment.bounds.midY - $0) <= 300 } ?? true
                return side && near && fragment.bounds.minX.isFinite && fragment.bounds.maxX.isFinite
            }
            if let left = outside.map(\.bounds.minX).min(), let right = outside.map(\.bounds.maxX).max(), left <= right { return left...right }
        }
        return column
    }

    /// Justified lines share their edges; the most common edge ignores overfull lines and short ones. Edges a fraction of
    /// a point apart count together: a justified column ending at 395.9, 396.1 and 396.6 outweighs a margin's 547.9.
    static func edge(_ values: [CGFloat], fallback: CGFloat) -> CGFloat {
        let values = values.filter { $0.isFinite && abs($0) < 1e7 }
        let buckets = Dictionary(grouping: values) { Int($0.rounded()) }
        func score(_ key: Int) -> Int { (buckets[key - 1]?.count ?? 0) + (buckets[key]?.count ?? 0) + (buckets[key + 1]?.count ?? 0) }
        guard let winner = buckets.keys.max(by: { score($0) == score($1) ? $0 > $1 : score($0) < score($1) }), score(winner) >= 2 else { return fallback }
        let members = (winner - 1...winner + 1).flatMap { buckets[$0] ?? [] }
        return members.reduce(0, +) / CGFloat(members.count)
    }

    /// Rotated labels (a figure's axis title, for example) run vertically and would join unrelated lines.
    static func isRotated(_ fragment: LayoutFragment) -> Bool {
        fragment.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 && fragment.bounds.height > 18 && fragment.bounds.height > 2 * fragment.bounds.width
    }

    static func rows(_ fragments: [LayoutFragment], in column: ClosedRange<CGFloat>) -> [Row] {
        let inColumn = fragments.filter { column.contains($0.bounds.midX) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isRotated($0) }
        var rows: [Row] = []
        for fragment in inColumn.sorted(by: { $0.bounds.maxY > $1.bounds.maxY }) {
            let b = fragment.bounds
            if let index = rows.firstIndex(where: { row in
                let overlap = min(row.maxY, b.maxY) - max(row.minY, b.minY)
                return overlap > 0.3 * min(row.maxY - row.minY, max(b.height, 1))
            }) {
                rows[index].fragments.append(fragment)
                rows[index].minY = min(rows[index].minY, b.minY); rows[index].maxY = max(rows[index].maxY, b.maxY)
            } else {
                rows.append(Row(fragments: [fragment], minY: b.minY, maxY: b.maxY))
            }
        }
        // Tall summation signs can join rows after the fact; merge any rows that now overlap.
        rows.sort { $0.maxY > $1.maxY }
        var merged: [Row] = []
        for row in rows {
            if var last = merged.last, min(last.maxY, row.maxY) - max(last.minY, row.minY) > 0.3 * min(last.maxY - last.minY, row.maxY - row.minY) {
                last.fragments += row.fragments; last.minY = min(last.minY, row.minY); last.maxY = max(last.maxY, row.maxY)
                merged[merged.count - 1] = last
            } else { merged.append(row) }
        }
        return merged
    }

    private static func row(containing y: CGFloat, in rows: [Row]) -> Int? {
        rows.firstIndex { $0.maxY >= y && $0.minY <= y } ?? rows.indices.min { abs((rows[$0].minY + rows[$0].maxY) / 2 - y) < abs((rows[$1].minY + rows[$1].maxY) / 2 - y) }
    }

    /// A line of the paragraph around a display, which ends the display: body text, a paragraph's first line indented as
    /// 11 and 12 pt LaTeX indent it (17 and 18 pt), or a justified line of mathematical prose that fills the column from
    /// its left edge without three words in a row (“Hence, by (3.5) and (3.2), βλ = V(D² + λI)⁻¹ …”). A centred display
    /// does none of these, and a display too long for its line starts inside the column (multline's 10 pt gap).
    static func endsDisplay(_ row: Row, column: ClosedRange<CGFloat>) -> Bool {
        if isBodyText(row, column: column) { return true }
        if row.minX <= column.lowerBound + 20, isProse(row.text) { return true }
        // Displays are inset. A line at the column's left edge is text, even with mathematics in it, when it opens with a
        // word (“If τ = [τ₀ˡ] then”, “Index-based notation”) or holds a run of seven letters: prose whose word spaces
        // the text layer lost (“βⱼ ∈ ℝˢ, (j = 1, …, k), thefollowingholds:”), which a formula does not contain.
        if let first = row.fragments.min(by: { $0.bounds.minX < $1.bounds.minX }), opensText(first, text: row.text, column: column) { return true }
        let width = column.upperBound - column.lowerBound
        guard row.minX <= column.lowerBound + 2, row.maxX >= column.upperBound - 0.06 * width else { return false }
        return longWord.firstMatch(in: row.text, range: NSRange(location: 0, length: (row.text as NSString).length)) != nil
    }
    private static let longWord = try! NSRegularExpression(pattern: "(?<!\\p{L})\\p{Latin}{4,}(?!\\p{L})")
    /// Whether a line starting with `fragment` (the line's `text`) is text by its start at the column's left edge.
    private static func opensText(_ fragment: LayoutFragment, text: String, column: ClosedRange<CGFloat>) -> Bool {
        guard fragment.bounds.minX <= column.lowerBound + 16 else { return false }
        return leadingWord.firstMatch(in: fragment.text, range: NSRange(location: 0, length: (fragment.text as NSString).length)) != nil
            || letterRun.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }
    /// A fragment of text rather than of a formula: prose, or a line opening at the column's left edge as text.
    static func isText(_ fragment: LayoutFragment, column: ClosedRange<CGFloat>) -> Bool {
        isProse(fragment.text) || opensText(fragment, text: fragment.text, column: column)
    }
    private static let leadingWord = try! NSRegularExpression(pattern: "^\\s*\\p{Latin}{2,}(?=[\\s,.:;\\-])")
    private static let letterRun = try! NSRegularExpression(pattern: "\\p{Latin}{7}")

    /// A displayed equation: the label's row and adjacent formula rows, bounded by body text or whitespace.
    public static func equationRegion(label: CGRect, fragments: [LayoutFragment], page: CGRect) -> CGRect {
        let column = column(containing: label.midX, near: label.midY, fragments: fragments, page: page)
        let rows = rows(fragments, in: (column.lowerBound - 2)...(column.upperBound + 2))
        guard let index = row(containing: label.midY, in: rows) else {
            return padded(CGRect(x: column.lowerBound, y: label.minY, width: column.upperBound - column.lowerBound, height: label.height), page: page)
        }
        // A text line whose glyph boxes run tall (accents, a fraction beside it) can share the label's row. Text never
        // belongs to a display: its fragments are left out of the label's line and bound the display on their side.
        let prose = rows[index].fragments.filter { isText($0, column: column) }
        let formula = rows[index].fragments.filter { !isText($0, column: column) }
        func minY(_ i: Int) -> CGFloat { i == index ? formula.map(\.bounds.minY).min() ?? label.minY : rows[i].minY }
        func maxY(_ i: Int) -> CGFloat { i == index ? formula.map(\.bounds.maxY).max() ?? label.maxY : rows[i].maxY }
        var top = index, bottom = index
        if !prose.contains(where: { $0.bounds.midY > label.midY }) {
            while top > 0, !endsDisplay(rows[top - 1], column: column), rows[top - 1].minY - maxY(top) <= 16 { top -= 1 }
        }
        if !prose.contains(where: { $0.bounds.midY <= label.midY }) {
            while bottom + 1 < rows.count, !endsDisplay(rows[bottom + 1], column: column), minY(bottom) - rows[bottom + 1].maxY <= 16 { bottom += 1 }
        }
        let minY = min(minY(bottom), label.minY), maxY = max(maxY(top), label.maxY)
        // Ragged prose can end before a flush-right label; the label always belongs to its display.
        let minX = min(column.lowerBound, label.minX), maxX = max(column.upperBound, label.maxX)
        return padded(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), page: page)
    }

    /// A figure normally sits above its caption; the caption runs until the next paragraph gap.
    /// Books with captions in the margin (Bishop, Deisenroth et al.) set the figure beside its caption instead.
    public static func figureRegion(caption: CGRect, fragments: [LayoutFragment], page: CGRect) -> CGRect {
        let column = column(containing: caption.midX, near: caption.midY, fragments: fragments, page: page, margins: true)
        let width = column.upperBound - column.lowerBound
        if let main = mainColumn(fragments, page: page), width < 0.4 * (main.upperBound - main.lowerBound),
           caption.maxX <= main.lowerBound + 12 || caption.minX >= main.upperBound - 12 {
            return marginFigureRegion(caption: caption, captionColumn: column, main: main, fragments: fragments, page: page)
        }
        let rows = rows(fragments, in: (column.lowerBound - 2)...(column.upperBound + 2))
        guard let index = row(containing: caption.midY, in: rows) else {
            return padded(CGRect(x: column.lowerBound, y: caption.minY, width: width, height: max(caption.height, page.maxY - 30 - caption.minY)), page: page)
        }
        var bottom = index
        while bottom + 1 < rows.count, rows[bottom].minY - rows[bottom + 1].maxY <= 5.5 { bottom += 1 }
        // Walk up through the figure, stopping at body text or the running head.
        var top = index
        let header = page.maxY - 36
        while top > 0 {
            let above = rows[top - 1]
            if above.minY >= header || (isBodyText(above, column: column) && above.width >= 0.6 * width) { break }
            top -= 1
        }
        let upper = top > 0 ? rows[top - 1].minY - 3 : page.maxY - 18
        let minY = rows[bottom].minY
        let minX = min(column.lowerBound, caption.minX), maxX = max(column.upperBound, caption.maxX)
        return padded(CGRect(x: minX, y: minY, width: maxX - minX, height: max(upper, rows[index].maxY) - minY), page: page)
    }

    /// The column holding most of the page's prose, when one stands out.
    static func mainColumn(_ fragments: [LayoutFragment], page: CGRect) -> ClosedRange<CGFloat>? {
        let prose = fragments.filter { $0.bounds.width >= 0.45 * page.width && isProse($0.text) }
        guard prose.count >= 3 else { return nil }
        let lower = edge(prose.map(\.bounds.minX), fallback: prose.map(\.bounds.minX).min()!)
        let upper = edge(prose.map(\.bounds.maxX), fallback: prose.map(\.bounds.maxX).max()!)
        return lower < upper ? lower...upper : nil
    }

    /// A margin caption: the figure spans the text column beside it, from the prose above to the prose below.
    static func marginFigureRegion(caption: CGRect, captionColumn: ClosedRange<CGFloat>, main: ClosedRange<CGFloat>,
                                   fragments: [LayoutFragment], page: CGRect) -> CGRect {
        let captionRows = rows(fragments, in: (captionColumn.lowerBound - 2)...(captionColumn.upperBound + 2))
        var captionBottom = caption.minY
        if var index = row(containing: caption.midY, in: captionRows) {
            while index + 1 < captionRows.count, captionRows[index].minY - captionRows[index + 1].maxY <= 5.5 { index += 1 }
            captionBottom = captionRows[index].minY
        }
        let mainRows = rows(fragments, in: (main.lowerBound - 2)...(main.upperBound + 2))
        let width = main.upperBound - main.lowerBound
        func isProseRow(_ row: Row) -> Bool { isBodyText(row, column: main) && row.width >= 0.6 * width }
        let header = page.maxY - 36
        let above = mainRows.last { $0.minY > caption.maxY - 2 && (isProseRow($0) || $0.minY >= header) }
        let below = mainRows.first { $0.maxY < caption.maxY - 4 && isProseRow($0) }
        let top = min(above.map { $0.minY - 3 } ?? page.maxY - 18, max(caption.maxY + 140, caption.maxY))
        let bottom = min(captionBottom, below.map { $0.maxY + 3 } ?? captionBottom)
        let minX = min(caption.minX, main.lowerBound), maxX = max(caption.maxX, main.upperBound)
        return padded(CGRect(x: minX, y: bottom, width: maxX - minX, height: max(caption.height, top - bottom)), page: page)
    }

    /// Tables, algorithms, statements, exercises and headings start at their caption and continue below it.
    /// A table ends at the next line of body text; other blocks end at a paragraph gap.
    public static func blockBelow(start: CGRect, fragments: [LayoutFragment], page: CGRect, gap: CGFloat, maximumHeight: CGFloat, stopAtBodyText: Bool = false) -> CGRect {
        let column = column(containing: start.midX, near: start.midY, fragments: fragments, page: page)
        let rows = rows(fragments, in: (column.lowerBound - 2)...(column.upperBound + 2))
        guard let index = row(containing: start.midY, in: rows) else {
            return padded(CGRect(x: column.lowerBound, y: start.maxY - maximumHeight, width: column.upperBound - column.lowerBound, height: maximumHeight), page: page)
        }
        var bottom = index
        // The caption's own lines are tightly spaced; skip them before applying the body-text stop.
        while bottom + 1 < rows.count, rows[bottom].minY - rows[bottom + 1].maxY <= 5.5, isProse(rows[bottom + 1].text) { bottom += 1 }
        while bottom + 1 < rows.count, rows[bottom].minY - rows[bottom + 1].maxY <= gap,
              rows[index].maxY - rows[bottom + 1].minY <= maximumHeight,
              !(stopAtBodyText && isBodyText(rows[bottom + 1], column: column) && rows[bottom + 1].width >= 0.75 * (column.upperBound - column.lowerBound)) { bottom += 1 }
        let minY = rows[bottom].minY, maxY = max(rows[index].maxY, start.maxY)
        let minX = min(column.lowerBound, start.minX), maxX = max(column.upperBound, start.maxX)
        return padded(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), page: page)
    }

    /// Report charts put the caption above the artwork. Panel labels and notes are smaller than the caption,
    /// and the artwork itself may contribute no text at all, so a gap between panel labels and notes is expected.
    static func chartRegion(caption: CGRect, fragments: [LayoutFragment], images: [CGRect], page: CGRect) -> CGRect {
        // Raster panels start below the title. Their bounds also recover panel edges when the labels read as separate columns.
        let artwork = images.filter { image in
            image.width >= 40 && image.height >= 40 && image.minX >= caption.minX - 12 &&
            (caption.minY - 144...caption.minY + 2).contains(image.maxY)
        }.reduce(CGRect.null) { $0.union($1) }
        let textColumn = column(containing: caption.midX, near: caption.midY, fragments: fragments, page: page, margins: true)
        let column = artwork.isNull ? textColumn : min(textColumn.lowerBound, artwork.minX)...max(textColumn.upperBound, artwork.maxX)
        let footer = page.minY + 36
        let rows = rows(fragments, in: (column.lowerBound - 4)...(column.upperBound + 4)).filter { $0.maxY > footer }
        guard let index = row(containing: caption.midY, in: rows) else { return padded(caption, page: page) }
        var titleEnd = index
        while titleEnd + 1 < rows.count, rows[titleEnd].minY - rows[titleEnd + 1].maxY <= 6,
              isProse(rows[titleEnd + 1].text) { titleEnd += 1 }
        let end = rows.indices.dropFirst(titleEnd + 1).first { i in
            let line = rows[i]
            guard artwork.isNull || line.maxY < artwork.minY else { return false }
            guard line.maxY - line.minY >= 0.92 * caption.height else { return false }
            let text = line.text.trimmingCharacters(in: .whitespaces)
            return isBodyText(line, column: column) || text.hasPrefix("Chart ") || text.hasPrefix("Box ")
        }
        let contents = rows[index..<(end ?? rows.count)]
        let left = min(caption.minX, column.lowerBound)
        let right = max(caption.maxX, column.upperBound, contents.map(\.maxX).max() ?? column.upperBound)
        let textBottom = end.map { rows[$0].maxY + 4 } ?? (artwork.isNull ? footer : contents.last?.minY ?? footer)
        let bottom = artwork.isNull ? textBottom : min(textBottom, artwork.minY)
        return padded(CGRect(x: left, y: min(caption.minY, bottom), width: right - left,
                             height: caption.maxY - min(caption.minY, bottom)), page: page)
    }

    /// Line bounds already include ascenders and descenders; a little vertical room avoids neighbouring lines.
    static func padded(_ rect: CGRect, page: CGRect) -> CGRect {
        let result = rect.insetBy(dx: -4, dy: -1.5).intersection(page)
        return result.isNull || result.isEmpty ? rect : result
    }
}

extension ReferenceLayout {
    /// The page's lines in reading order, column by column, as rectangles: what a reading ruler steps through.
    /// A displayed equation with tall operators counts as one line. Running heads and footers are left out.
    public static func readingLines(_ fragments: [LayoutFragment], page: CGRect) -> [CGRect] {
        let usable = fragments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isRotated($0)
                && $0.bounds.minY > page.minY + 30 && $0.bounds.maxY < page.maxY - 30
        }
        guard let left = usable.map(\.bounds.minX).min(), let right = usable.map(\.bounds.maxX).max() else { return [] }
        let wide = usable.filter { $0.bounds.width >= 60 }
        let gutter = stride(from: left + (right - left) * 0.35, through: left + (right - left) * 0.65, by: 2).first { gutter in
            wide.count >= 6 && !wide.contains { $0.bounds.minX < gutter - 3 && $0.bounds.maxX > gutter + 3 }
                && wide.filter { $0.bounds.maxX <= gutter }.count >= 3 && wide.filter { $0.bounds.minX >= gutter }.count >= 3
        }
        let columns: [ClosedRange<CGFloat>] = gutter.map { [left...$0, $0...right] } ?? [left...right]
        var result: [CGRect] = []
        for column in columns {
            // One baseline per line: fragments join a line only when their centres agree, so two lines of prose whose
            // boxes overlap (tall glyphs, tight leading) stay two steps; a display's limits join it (“i=1” under Σ).
            let inColumn = usable.filter { column.contains($0.bounds.midX) }.sorted { $0.bounds.midY > $1.bounds.midY }
            var lines: [CGRect] = []
            for fragment in inColumn {
                let b = fragment.bounds
                if let index = lines.lastIndex(where: { line in
                    let tolerance = 0.45 * min(line.height, b.height)
                    return abs(line.midY - b.midY) <= max(tolerance, 2) || (b.height < 0.7 * line.height && b.maxY > line.minY && b.minY < line.maxY && b.height < 9)
                }) {
                    lines[index] = lines[index].union(b)
                } else {
                    lines.append(b)
                }
            }
            result += lines.sorted { $0.midY > $1.midY }
        }
        return result
    }
}

extension PageRegion {
    public init(_ rect: CGRect) { self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height) }
    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// An entry of a document's embedded outline, flattened in document order.
public struct OutlineItem: Codable, Equatable, Sendable {
    public var title: String
    public var pageIndex: Int
    public var level: Int
    public var point: CGPoint?
    public init(title: String, pageIndex: Int, level: Int, point: CGPoint? = nil) {
        self.title = title; self.pageIndex = pageIndex; self.level = level; self.point = point
    }
}

/// Reads a PDF's embedded outline in document order.
public enum OutlineReader {
    /// Every entry with a destination page, depth-first, with destination points where the PDF specifies them.
    public static func items(in document: PDFDocument) -> [OutlineItem] {
        guard let root = document.outlineRoot else { return [] }
        var items: [OutlineItem] = []
        func walk(_ item: PDFOutline, level: Int) {
            for index in 0..<item.numberOfChildren {
                guard let child = item.child(at: index) else { continue }
                let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                if let page = destination?.page {
                    let point = destination.map { $0.point }.flatMap { abs($0.x) < 1e6 && abs($0.y) < 1e6 ? $0 : nil }
                    items.append(OutlineItem(title: child.label ?? "", pageIndex: document.index(for: page), level: level, point: point))
                }
                walk(child, level: level + 1)
            }
        }
        walk(root, level: 0)
        return items
    }
}

/// Chapter page ranges and numbered sections from a document outline.
public enum OutlineMap {
    /// Pages of chapter `chapter`, from its outline entry to the next entry at the same level.
    public static func chapterRange(_ chapter: Int, in items: [OutlineItem], pageCount: Int) -> Range<Int>? {
        guard let index = items.firstIndex(where: { numberPrefix(of: $0.title) == "\(chapter)" || chapterWord(of: $0.title) == chapter }) else { return nil }
        let start = items[index].pageIndex
        let end = items[(index + 1)...].first { $0.level <= items[index].level && $0.pageIndex > start }?.pageIndex ?? pageCount
        return start..<max(start + 1, min(end + 1, pageCount))
    }

    /// The outline entry for a numbered section, such as "2.3.3 From Least Squares…".
    public static func section(_ number: String, in items: [OutlineItem]) -> OutlineItem? {
        items.first { numberPrefix(of: $0.title) == number }
    }

    /// The most recent outline entry at or before a point of the document: the reader's current section.
    /// `y` is in PDF page space; an entry lower on the same page has not started yet.
    public static func section(containing pageIndex: Int, y: CGFloat? = nil, in items: [OutlineItem]) -> OutlineItem? {
        var best: (item: OutlineItem, order: Int)?
        for (order, item) in items.enumerated() where item.pageIndex <= pageIndex {
            if item.pageIndex == pageIndex, let y, let point = item.point, point.y < y - 2 { continue }
            if best == nil || item.pageIndex > best!.item.pageIndex || (item.pageIndex == best!.item.pageIndex && order > best!.order) {
                best = (item, order)
            }
        }
        return best?.item
    }

    public static func numberPrefix(of title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let first = digits.first, first.isNumber else { return nil }
        let number = digits.hasSuffix(".") ? String(digits.dropLast()) : String(digits)
        return number.isEmpty ? nil : number
    }

    private static func chapterWord(of title: String) -> Int? {
        let words = title.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2, words[0].lowercased() == "chapter" else { return nil }
        return Int(words[1].trimmingCharacters(in: CharacterSet(charactersIn: ".:")))
    }
}
