//
//  EmphasisExtractor.swift · "Go to Definition" for words
//
//  Finds runs of emphasised prose (italic / bold) on a PDF page and locates them
//  in PDFKit's `page.string`.
//
//  Why not PDFKit's attributed strings: `PDFPage.attributedString` and
//  `PDFSelection.attributedString` report every character as Helvetica, so the
//  real fonts have to be read from the page's content stream:
//
//  1. Scan the content stream with CGPDFScanner, tracking the graphics/text state
//     (CTM, Tm/Tlm, Tf, Tc, Tw, Tz, TL, Ts) so every glyph gets a page-space
//     position, and classify each font from its /BaseFont (subset prefix
//     stripped) and /FontDescriptor: prose italic (CMTI, *-Italic, *-It, …),
//     bold (CMBX, *-Bold, …), or neither. Math italic (CMMI, *Math*, Symbol, …)
//     is never emphasis.
//  2. Glyphs of an emphasis font are decoded (ToUnicode › Encoding/Differences ›
//     built-in TeX OT1/T1 tables) and grouped into runs; word and line breaks
//     come from glyph geometry (gap > 0.15 em = space, baseline change = line
//     break). A visible glyph in any other font ends the run.
//  3. Each run is located in `page.string` by whitespace/hyphen/ligature/
//     accent-insensitive matching. Every match is checked against PDFKit's own
//     geometry (`selection(for:).bounds` of the first character must lie where
//     the run's first glyph is); when the text occurs several times, that check
//     picks the occurrence. If PDFKit orders the text differently (captions
//     beside figures, lines split around formulas), the run is located line by
//     line, then word by word, then by rectangle selection, and the pieces that
//     are adjacent in `page.string` are merged.
//
//  Imports only Foundation, PDFKit and CoreGraphics. No global mutable state:
//  CGPDFScanner callbacks reach their per-scan context through the `info` pointer.
//

import CoreGraphics
import Foundation
import PDFKit

// MARK: - Public API

public struct EmphasisRun: Equatable, Sendable {
    public enum Style: String, Codable, Sendable { case italic, bold }

    /// The run's text as decoded from the content stream: whitespace-normalised,
    /// ligatures expanded, words hyphenated across a line break re-joined.
    public var text: String
    /// Range in `page.string` (UTF-16 offsets) from the run's first to its last
    /// character. It can contain PDFKit's synthesised spaces/newlines and the
    /// hyphen of a word broken across lines.
    public var range: NSRange
    public var style: Style
    /// Font size relative to the body text (1.0 = body size): the document's body size
    /// when passed to `runs(on:pageText:bodyFontSize:)`, else the page's dominant prose
    /// size. Headings are larger (ESL: 1.2), captions and footnotes smaller (ESL: 0.9).
    public var relativeSize: Double

    public init(text: String, range: NSRange, style: Style, relativeSize: Double = 1) {
        self.text = text
        self.range = range
        self.style = style
        self.relativeSize = relativeSize
    }
}

public enum EmphasisExtractor {
    /// Italic and bold runs on `page`, sorted by position in `page.string`.
    public static func runs(on page: PDFPage) -> [EmphasisRun] {
        runs(on: page, pageText: nil, bodyFontSize: nil)
    }

    /// - Parameters:
    ///   - pageText: `page.string` if the caller already holds it (must be exactly that string).
    ///   - bodyFontSize: the document's body text size (`bodyFontSize(of:)`); `relativeSize`
    ///     is computed against it. Without it, each page's dominant prose size is used,
    ///     which is wrong on pages without prose (full-page figures, tables).
    public static func runs(on page: PDFPage, pageText: String?, bodyFontSize: Double? = nil) -> [EmphasisRun] {
        analyze(page: page, pageText: pageText, bodyFontSize: bodyFontSize).located.map(\.run)
    }

    /// The document's dominant prose font size in points, estimated from up to
    /// `samplePages` pages spread over the book (≈1–2 ms per page).
    public static func bodyFontSize(of document: PDFDocument, samplePages: Int = 30) -> Double? {
        let count = document.pageCount
        guard count > 0 else { return nil }
        let first = count > 20 ? count / 10 : 0, last = count > 20 ? count - count / 10 : count
        let n = min(samplePages, last - first)
        var votes: [Int: Int] = [:]
        for k in 0..<n {
            let index = first + (last - first) * k / max(n, 1)
            guard let cgPage = document.page(at: index)?.pageRef else { continue }
            for (size, letters) in EmphasisContentScanner.scan(cgPage).sizeVotes { votes[size, default: 0] += letters }
        }
        guard let best = votes.max(by: { $0.value < $1.value }) else { return nil }
        return Double(best.key) / 10
    }

    // Internal entry point that also returns diagnostics (used by the probe).
    static func analyze(page: PDFPage, pageText: String?, bodyFontSize: Double? = nil) -> EmphasisAnalysis {
        guard let cgPage = page.pageRef else { return EmphasisAnalysis() }
        var scan = EmphasisContentScanner.scan(cgPage)
        if let bodyFontSize, bodyFontSize > 0 { scan.bodyFontSize = CGFloat(bodyFontSize) }
        guard !scan.runs.isEmpty, let text = pageText ?? page.string, !text.isEmpty else {
            return EmphasisAnalysis(scan: scan)
        }
        var locator = EmphasisLocator(page: page, text: text)
        let located = locator.locate(scan)
        return EmphasisAnalysis(scan: scan, located: located, unlocated: locator.unlocated)
    }
}

// MARK: - Internal result types

struct EmphasisAnalysis {
    var scan = EmphasisScanResult()
    var located: [LocatedEmphasisRun] = []
    var unlocated: [RawEmphasisRun] = []
}

struct LocatedEmphasisRun {
    enum Method: String { case unique, disambiguated, perLine, perWord, geometric }
    var run: EmphasisRun
    var raw: RawEmphasisRun
    var method: Method
    /// Distance between the run's first glyph and PDFKit's rect for the first
    /// matched character, in ems (nil when PDFKit returned no rect).
    var geometryError: Double?
}

/// A word of a run as shown: split at word spaces and at line breaks (so the two
/// halves of a hyphenated word are separate pieces).
struct RawEmphasisWord {
    var text: String              // decoded glyphs, no separators
    var keyRange: Range<Int>      // slice of RawEmphasisRun.key (may be empty: punctuation only)
    var line: Int                 // line index within the run
    var rect: CGRect              // page space, union of the glyph boxes
    var firstGlyphRect: CGRect    // box of the glyph producing the first key scalar
}

struct RawEmphasisRun {
    var style: EmphasisRun.Style
    var fontName: String
    var fontSize: CGFloat          // em in page space (points)
    var text: String
    var key: [UInt32]              // folded matching key, see EmphasisFolding
    var words: [RawEmphasisWord]
    var firstGlyphRect: CGRect     // page space

    /// Word index ranges of the run's lines.
    var lineGroups: [Range<Int>] {
        guard !words.isEmpty else { return [] }
        var groups: [Range<Int>] = []
        var start = 0
        for i in 1...words.count where i == words.count || words[i].line != words[i - 1].line {
            if i > start { groups.append(start..<i) }
            start = i
        }
        return groups
    }
}

/// Joining words into display text, with line-end hyphenation removed.
enum EmphasisText {
    /// - Parameter hyphenated: lower-cased compounds written with a hyphen elsewhere on
    ///   the page (`hyphenatedWords(in:)`); a line-end hyphen that forms one is kept.
    static func join(_ words: ArraySlice<RawEmphasisWord>, hyphenated: Set<String> = []) -> String {
        var out = ""
        var previous: RawEmphasisWord?
        for word in words {
            if let previous {
                if word.line != previous.line, out.hasSuffix("-") || out.hasSuffix("\u{2010}") {
                    if dropsLineBreakHyphen(before: Substring(previous.text), after: Substring(word.text),
                                            hyphenated: hyphenated) {
                        out.removeLast()
                    }
                } else {
                    out += " "
                }
            }
            out += word.text
            previous = word
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the hyphen ending `before` (the word fragment at the end of a line)
    /// is a hyphenation point rather than a real hyphen, given the fragment that
    /// starts the next line. TeX breaks a word that has explicit hyphens only at
    /// them, so a fragment containing another hyphen ("degrees-|of-freedom")
    /// keeps its hyphen.
    static func dropsLineBreakHyphen(before: Substring, after: Substring, hyphenated: Set<String> = []) -> Bool {
        let stem = before.dropLast()
        guard let last = stem.unicodeScalars.last, last.properties.isAlphabetic,
              let first = after.unicodeScalars.first, first.properties.isLowercase else { return false }
        let hyphens: Set<Character> = ["-", "\u{2010}"]
        let stemWord = stem.split(whereSeparator: { $0 == " " }).last ?? stem
        if !hyphenated.isEmpty {
            let head = stemWord.reversed().prefix(while: \.isLetter).reversed()
            let tail = after.prefix(while: \.isLetter)
            if hyphenated.contains((String(head) + "-" + String(tail)).lowercased()) { return false }
        }
        return !stemWord.contains(where: hyphens.contains) && !after.contains(where: hyphens.contains)
    }

    private static let compound = try! NSRegularExpression(pattern: #"\p{L}+(?:[-\x{2010}]\p{L}+)+"#)

    /// Lower-cased hyphenated compounds of `text` whose hyphen is not at a line end
    /// ("forward-stepwise"; "k-nearest-neighbor" also yields "k-nearest", "nearest-neighbor").
    static func hyphenatedWords(in text: String) -> Set<String> {
        var result = Set<String>()
        let ns = text as NSString
        compound.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let parts = ns.substring(with: match.range).lowercased()
                .split(whereSeparator: { $0 == "-" || $0 == "\u{2010}" })
            for i in 0..<(parts.count - 1) { result.insert(parts[i] + "-" + parts[i + 1]) }
        }
        return result
    }
}

struct EmphasisScanResult {
    var runs: [RawEmphasisRun] = []
    var bodyFontSize: CGFloat = 0  // dominant size of running text, 0 if unknown
    var sizeVotes: [Int: Int] = [:]  // em×10 -> letters on prose-like lines
    var glyphCount = 0
    var imageBounds: [CGRect] = []
    var usedFormRecursion = false
}

// MARK: - Text folding (shared by run keys and the page key)

/// Matching keys ignore case, whitespace, hyphens/dashes, quotes and accents,
/// and expand ligatures, so "regu-\nlarization", "eﬀective"/"effective" and
/// "Fréchet"/"Fre´chet" compare equal.
enum EmphasisFolding {
    typealias Cache = [UInt32: [UInt32]]

    @inline(__always)
    static func fold(_ v: UInt32, into out: inout [UInt32], cache: inout Cache) {
        switch v {
        case 0x61...0x7A, 0x30...0x39: out.append(v)
        case 0x41...0x5A: out.append(v + 0x20)
        case 0x00...0x20, 0x7F: return
        case 0x22, 0x27, 0x2D, 0x5E, 0x60, 0x7E: return   // " ' - ^ ` ~
        case 0x21...0x7E: out.append(v)                   // other ASCII punctuation
        default:
            if let cached = cache[v] {
                out.append(contentsOf: cached)
            } else {
                let folded = foldNonASCII(v)
                cache[v] = folded
                out.append(contentsOf: folded)
            }
        }
    }

    static func fold(_ string: String, into out: inout [UInt32], cache: inout Cache) {
        for scalar in string.unicodeScalars { fold(scalar.value, into: &out, cache: &cache) }
    }

    static func key(_ string: String) -> [UInt32] {
        var out: [UInt32] = []
        var cache = Cache()
        fold(string, into: &out, cache: &cache)
        return out
    }

    private static func foldNonASCII(_ v: UInt32) -> [UInt32] {
        switch v {
        case 0x80...0xA0, 0xAD, 0x1680, 0x2000...0x200F, 0x2028...0x202F, 0x205F...0x206F, 0x3000, 0xFEFF:
            return []                                          // spaces, controls, soft hyphen
        case 0x2010...0x2015, 0x2043, 0x2212, 0xFE58, 0xFE63, 0xFF0D:
            return []                                          // hyphens, dashes, minus
        case 0xAB, 0xBB, 0xB4, 0x2B9...0x2BC, 0x2018...0x201F, 0x2032...0x2037, 0x2039, 0x203A:
            return []                                          // quotes, primes, guillemets
        case 0xA8, 0xAF, 0xB8, 0x2C6...0x2CB, 0x2D8...0x2DD, 0x300...0x36F:
            return []                                          // spacing and combining accents
        case 0xFB00: return [0x66, 0x66]
        case 0xFB01: return [0x66, 0x69]
        case 0xFB02: return [0x66, 0x6C]
        case 0xFB03: return [0x66, 0x66, 0x69]
        case 0xFB04: return [0x66, 0x66, 0x6C]
        case 0xFB05, 0xFB06: return [0x73, 0x74]
        case 0x2206: return [0x3B4]                            // increment sign: PDFKit's Delta
        case 0x131: return [0x69]                              // dotless i
        case 0x237: return [0x6A]                              // dotless j
        default:
            guard let scalar = Unicode.Scalar(v) else { return [] }
            var result: [UInt32] = []
            for s in String(scalar).decomposedStringWithCompatibilityMapping.unicodeScalars {
                switch s.properties.generalCategory {
                case .nonspacingMark, .spacingMark, .enclosingMark, .spaceSeparator,
                     .lineSeparator, .paragraphSeparator, .control, .format,
                     .dashPunctuation, .initialPunctuation, .finalPunctuation:
                    continue
                default:
                    for l in s.properties.lowercaseMapping.unicodeScalars { result.append(l.value) }
                }
            }
            return result
        }
    }
}

// MARK: - Content-stream scanning

enum EmphasisContentScanner {
    static func scan(_ page: CGPDFPage) -> EmphasisScanResult {
        let context = EmphasisScanContext(recurseIntoForms: false)
        context.scan(page)
        // Skip Form XObjects (figures) unless the page keeps all its text in them.
        if context.topLevelGlyphs == 0 && context.formInvocations > 0 {
            let deep = EmphasisScanContext(recurseIntoForms: true)
            deep.scan(page)
            var result = deep.result()
            result.usedFormRecursion = true
            return result
        }
        return context.result()
    }
}

final class EmphasisScanContext {
    struct GraphicsState {
        var ctm = CGAffineTransform.identity
        var font: EmphasisFontInfo?
        var fontSize: CGFloat = 0
        var charSpacing: CGFloat = 0
        var wordSpacing: CGFloat = 0
        var horizontalScale: CGFloat = 1
        var leading: CGFloat = 0
        var rise: CGFloat = 0
    }

    let recurseIntoForms: Bool
    private var state = GraphicsState()
    private var stack: [GraphicsState] = []
    private var textMatrix = CGAffineTransform.identity
    private var lineMatrix = CGAffineTransform.identity
    private var fonts: [Int: EmphasisFontInfo] = [:]
    private var builder = EmphasisRunBuilder()
    private var lineLetters: [Int64: Int] = [:]      // (em×10, baseline) -> letters in words of 3+ letters
    private var wordLetters = 0                       // letters of the word being shown (across shows)
    private var wordEmKey = 0
    private var wordBaseline = 0
    private var table: CGPDFOperatorTableRef?
    private var formDepth = 0
    private(set) var topLevelGlyphs = 0
    private(set) var formInvocations = 0
    private var glyphCount = 0
    private var imageBounds: [CGRect] = []

    init(recurseIntoForms: Bool) {
        self.recurseIntoForms = recurseIntoForms
    }

    func scan(_ page: CGPDFPage) {
        guard let table = Self.makeOperatorTable() else { return }
        self.table = table
        let stream = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        CGPDFOperatorTableRelease(table)
        self.table = nil
        builder.finishRun()
        endWord()
    }

    /// Lines with at least this many letters (in words of 3+ letters) count as prose.
    private static let proseLineLetters = 20

    func result() -> EmphasisScanResult {
        var votes: [Int: Int] = [:]
        for (bucket, letters) in lineLetters where letters >= Self.proseLineLetters {
            votes[Int(bucket >> 32), default: 0] += letters
        }
        var body: CGFloat = 0
        if let best = votes.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) {
            body = CGFloat(best.key) / 10
        }
        return EmphasisScanResult(runs: builder.runs, bodyFontSize: body, sizeVotes: votes, glyphCount: glyphCount, imageBounds: imageBounds)
    }

    // MARK: Operator table

    private static func context(_ info: UnsafeMutableRawPointer?) -> EmphasisScanContext? {
        guard let info else { return nil }
        return Unmanaged<EmphasisScanContext>.fromOpaque(info).takeUnretainedValue()
    }

    private static func popNumbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
        var values = [CGFloat](repeating: 0, count: count)
        for i in stride(from: count - 1, through: 0, by: -1) {
            var v: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &v) else { return nil }
            values[i] = v
        }
        return values
    }

    private static func makeOperatorTable() -> CGPDFOperatorTableRef? {
        guard let table = CGPDFOperatorTableCreate() else { return nil }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let c = EmphasisScanContext.context(info) else { return }
            c.stack.append(c.state)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let c = EmphasisScanContext.context(info) else { return }
            if let s = c.stack.popLast() { c.state = s }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let c = EmphasisScanContext.context(info),
                  let v = EmphasisScanContext.popNumbers(scanner, 6) else { return }
            let m = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            c.state.ctm = m.concatenating(c.state.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "BT") { _, info in
            guard let c = EmphasisScanContext.context(info) else { return }
            c.endWord()
            c.textMatrix = .identity
            c.lineMatrix = .identity
        }
        CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
            guard let c = EmphasisScanContext.context(info) else { return }
            var size: CGPDFReal = 0
            var name: UnsafePointer<Int8>?
            guard CGPDFScannerPopNumber(scanner, &size), CGPDFScannerPopName(scanner, &name), let name else { return }
            c.state.fontSize = size
            c.state.font = c.font(named: name, scanner: scanner)
        }
        CGPDFOperatorTableSetCallback(table, "Tc") { scanner, info in
            guard let c = EmphasisScanContext.context(info), let v = EmphasisScanContext.popNumbers(scanner, 1) else { return }
            c.state.charSpacing = v[0]
        }
        CGPDFOperatorTableSetCallback(table, "Tw") { scanner, info in
            guard let c = EmphasisScanContext.context(info), let v = EmphasisScanContext.popNumbers(scanner, 1) else { return }
            c.state.wordSpacing = v[0]
        }
        CGPDFOperatorTableSetCallback(table, "Tz") { scanner, info in
            guard let c = EmphasisScanContext.context(info), let v = EmphasisScanContext.popNumbers(scanner, 1) else { return }
            c.state.horizontalScale = v[0] / 100
        }
        CGPDFOperatorTableSetCallback(table, "TL") { scanner, info in
            guard let c = EmphasisScanContext.context(info), let v = EmphasisScanContext.popNumbers(scanner, 1) else { return }
            c.state.leading = v[0]
        }
        CGPDFOperatorTableSetCallback(table, "Ts") { scanner, info in
            guard let c = EmphasisScanContext.context(info), let v = EmphasisScanContext.popNumbers(scanner, 1) else { return }
            c.state.rise = v[0]
        }
        CGPDFOperatorTableSetCallback(table, "Td") { scanner, info in
            guard let c = EmphasisScanContext.context(info), let v = EmphasisScanContext.popNumbers(scanner, 2) else { return }
            c.moveLine(v[0], v[1])
        }
        CGPDFOperatorTableSetCallback(table, "TD") { scanner, info in
            guard let c = EmphasisScanContext.context(info), let v = EmphasisScanContext.popNumbers(scanner, 2) else { return }
            c.state.leading = -v[1]
            c.moveLine(v[0], v[1])
        }
        CGPDFOperatorTableSetCallback(table, "Tm") { scanner, info in
            guard let c = EmphasisScanContext.context(info), let v = EmphasisScanContext.popNumbers(scanner, 6) else { return }
            c.endWord()
            c.lineMatrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            c.textMatrix = c.lineMatrix
        }
        CGPDFOperatorTableSetCallback(table, "T*") { _, info in
            guard let c = EmphasisScanContext.context(info) else { return }
            c.moveLine(0, -c.state.leading)
        }
        CGPDFOperatorTableSetCallback(table, "Tj") { scanner, info in
            guard let c = EmphasisScanContext.context(info) else { return }
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string else { return }
            c.show(string)
        }
        CGPDFOperatorTableSetCallback(table, "'") { scanner, info in
            guard let c = EmphasisScanContext.context(info) else { return }
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string else { return }
            c.moveLine(0, -c.state.leading)
            c.show(string)
        }
        CGPDFOperatorTableSetCallback(table, "\"") { scanner, info in
            guard let c = EmphasisScanContext.context(info) else { return }
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string,
                  let v = EmphasisScanContext.popNumbers(scanner, 2) else { return }
            c.state.wordSpacing = v[0]
            c.state.charSpacing = v[1]
            c.moveLine(0, -c.state.leading)
            c.show(string)
        }
        CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
            guard let c = EmphasisScanContext.context(info) else { return }
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopArray(scanner, &array), let array else { return }
            c.showArray(array)
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let c = EmphasisScanContext.context(info) else { return }
            var name: UnsafePointer<Int8>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            c.invokeXObject(named: name, scanner: scanner)
        }
        return table
    }

    // MARK: State helpers

    private func moveLine(_ tx: CGFloat, _ ty: CGFloat) {
        endWord()
        lineMatrix = CGAffineTransform(translationX: tx, y: ty).concatenating(lineMatrix)
        textMatrix = lineMatrix
    }

    private func font(named name: UnsafePointer<Int8>, scanner: CGPDFScannerRef) -> EmphasisFontInfo? {
        let stream = CGPDFScannerGetContentStream(scanner)
        guard let object = CGPDFContentStreamGetResource(stream, "Font", name) else { return nil }
        var dict: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(object, .dictionary, &dict), let dict else { return nil }
        let key = unsafeBitCast(dict, to: Int.self)
        if let cached = fonts[key] { return cached }
        let info = EmphasisFontInfo(dictionary: dict)
        fonts[key] = info
        return info
    }

    private func invokeXObject(named name: UnsafePointer<Int8>, scanner: CGPDFScannerRef) {
        let parent = CGPDFScannerGetContentStream(scanner)
        guard let object = CGPDFContentStreamGetResource(parent, "XObject", name) else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
              let dict = CGPDFStreamGetDictionary(stream) else { return }
        let subtype = EmphasisPDF.name(dict, "Subtype")
        if subtype == "Image" {
            let bounds = CGRect(x: 0, y: 0, width: 1, height: 1).applying(state.ctm)
            if !bounds.isEmpty, LayoutFragment.isSane(bounds) { imageBounds.append(bounds) }
            return
        }
        guard subtype == "Form" else { return }
        formInvocations += 1
        guard recurseIntoForms, formDepth < 8, let table else { return }
        stack.append(state)
        if let m = EmphasisPDF.matrix(dict, "Matrix") { state.ctm = m.concatenating(state.ctm) }
        var resources: CGPDFDictionaryRef?
        let streamResources = CGPDFDictionaryGetDictionary(dict, "Resources", &resources) ? resources! : dict
        let formStream = CGPDFContentStreamCreateWithStream(stream, streamResources, parent)
        let formScanner = CGPDFScannerCreate(formStream, table, Unmanaged.passUnretained(self).toOpaque())
        formDepth += 1
        CGPDFScannerScan(formScanner)
        formDepth -= 1
        CGPDFScannerRelease(formScanner)
        CGPDFContentStreamRelease(formStream)
        if let s = stack.popLast() { state = s }
    }

    // MARK: Text showing

    private func showArray(_ array: CGPDFArrayRef) {
        let count = CGPDFArrayGetCount(array)
        for i in 0..<count {
            var object: CGPDFObjectRef?
            guard CGPDFArrayGetObject(array, i, &object), let object else { continue }
            switch CGPDFObjectGetType(object) {
            case .string:
                var string: CGPDFStringRef?
                if CGPDFObjectGetValue(object, .string, &string), let string { show(string) }
            case .integer, .real:
                var v: CGPDFReal = 0
                if CGPDFObjectGetValue(object, .real, &v) {
                    if v < -150 { endWord() }
                    let tx = -v / 1000 * state.fontSize * state.horizontalScale
                    textMatrix.tx += tx * textMatrix.a
                    textMatrix.ty += tx * textMatrix.b
                }
            default:
                continue
            }
        }
    }

    private func show(_ string: CGPDFStringRef) {
        guard let font = state.font, let bytes = CGPDFStringGetBytePtr(string) else { return }
        let length = CGPDFStringGetLength(string)
        guard length > 0 else { return }
        let fontSize = state.fontSize
        let hScale = state.horizontalScale
        let charSpacing = state.charSpacing
        let wordSpacing = state.wordSpacing
        let codeBytes = font.codeBytes
        var advance: CGFloat = 0                     // along the baseline, text space
        let m = textMatrix.concatenating(state.ctm)  // text space -> page space
        let upLength = hypot(m.c, m.d)
        let em = abs(fontSize) * font.emScale * upLength
        let emKey = Self.safeInt(em * 10)
        let countable = !font.isMath
        // Baseline position (perpendicular to the text direction) in half-em steps.
        let start = CGPoint(x: 0, y: state.rise).applying(m)
        let upUnit = upLength > 0 ? CGVector(dx: m.c / upLength, dy: m.d / upLength) : CGVector(dx: 0, dy: 1)
        let baseline = em > 0 ? Self.safeInt((start.x * upUnit.dx + start.y * upUnit.dy) / (em * 0.5)) : 0

        if let style = font.style, em > 0, em.isFinite {
            let dirLength = max(hypot(m.a, m.b), 1e-9)
            let dir = CGVector(dx: m.a / dirLength, dy: m.b / dirLength)
            let up = CGVector(dx: m.c / max(upLength, 1e-9), dy: m.d / max(upLength, 1e-9))
            var i = 0
            while i + codeBytes <= length {
                let code = codeBytes == 1 ? UInt32(bytes[i]) : (UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1]))
                i += codeBytes
                let w = font.width(code) * fontSize
                let origin = CGPoint(x: advance, y: state.rise).applying(m)
                let glyphEnd = CGPoint(x: advance + w * hScale, y: state.rise).applying(m)
                let isSpace = codeBytes == 1 && code == 32
                advance += (w + charSpacing + (isSpace ? wordSpacing : 0)) * hScale
                let pen = CGPoint(x: advance, y: state.rise).applying(m)
                let decoded = font.unicode(code) ?? ""
                builder.addEmphasisGlyph(style: style, fontName: font.name, em: em, text: decoded,
                                         origin: origin, glyphEnd: glyphEnd, pen: pen, dir: dir, up: up)
                countLetter(font.isLetter(code), emKey, baseline)
                glyphCount += 1
                if formDepth == 0 { topLevelGlyphs += 1 }
            }
        } else {
            var i = 0
            var visible = false
            var spaces = false
            while i + codeBytes <= length {
                let code = codeBytes == 1 ? UInt32(bytes[i]) : (UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1]))
                i += codeBytes
                let w = font.width(code) * fontSize
                let isSpace = font.isSpace(code)
                advance += (w + charSpacing + (codeBytes == 1 && code == 32 ? wordSpacing : 0)) * hScale
                if isSpace { spaces = true } else { visible = true }
                if countable { countLetter(font.isLetter(code), emKey, baseline) } else { endWord() }
                glyphCount += 1
                if formDepth == 0 { topLevelGlyphs += 1 }
            }
            if visible { builder.breakRun() } else if spaces { builder.noteSpace() }
        }
        textMatrix.tx += advance * textMatrix.a
        textMatrix.ty += advance * textMatrix.b
    }

    /// Rounds, mapping non-finite or absurd values (malformed matrices) to 0 instead of trapping.
    private static func safeInt(_ value: CGFloat) -> Int {
        guard value.isFinite, abs(value) < 1e9 else { return 0 }
        return Int(value.rounded())
    }

    // Body-size statistics: letters of words with 3+ letters, by font size. Words
    // span several shows (pdfTeX/Ghostscript emit one or two glyphs per string),
    // so the counter is only reset by non-letters, word spaces and line moves.
    @inline(__always)
    private func countLetter(_ isLetter: Bool, _ emKey: Int, _ baseline: Int) {
        if !isLetter || emKey != wordEmKey { endWord() }
        if isLetter {
            if wordLetters == 0 { wordBaseline = baseline }
            wordEmKey = emKey
            wordLetters += 1
        }
    }

    fileprivate func endWord() {
        if wordLetters >= 3 {
            lineLetters[Int64(wordEmKey) << 32 | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: wordBaseline))), default: 0] += wordLetters
        }
        wordLetters = 0
    }
}

// MARK: - Run building

struct EmphasisRunBuilder {
    private enum Separator: Int, Comparable {
        case none = 0, space, newline
        static func < (a: Separator, b: Separator) -> Bool { a.rawValue < b.rawValue }
    }

    private(set) var runs: [RawEmphasisRun] = []

    private var active = false
    private var style: EmphasisRun.Style = .italic
    private var fontName = ""
    private var em: CGFloat = 0
    private var key: [UInt32] = []
    private var words: [RawEmphasisWord] = []
    private var wordText = String.UnicodeScalarView()
    private var wordKeyStart = 0
    private var wordRect = CGRect.null
    private var wordFirstGlyph = CGRect.null
    private var line = 0
    private var lastPen = CGPoint.zero
    private var pending: Separator = .none
    private var pendingAccent: Unicode.Scalar?
    private var foldCache = EmphasisFolding.Cache()

    // Gap thresholds in ems. TeX's minimum interword space is ~0.22 em and its
    // largest kerns ~0.1 em; baselines of adjacent lines are ~1.2 em apart.
    private static let spaceGap: CGFloat = 0.15
    private static let lineShift: CGFloat = 0.6
    private static let maxLineDrop: CGFloat = 3.0
    private static let maxGap: CGFloat = 3.0
    private static let maxBacktrack: CGFloat = 2.5

    /// A visible glyph in a non-emphasis font ends the current run.
    mutating func breakRun() {
        if active { finishRun() }
    }

    /// A whitespace-only show in a non-emphasis font.
    mutating func noteSpace() {
        if active { pending = max(pending, .space) }
    }

    mutating func addEmphasisGlyph(style: EmphasisRun.Style, fontName: String, em: CGFloat, text decoded: String,
                                   origin: CGPoint, glyphEnd: CGPoint, pen: CGPoint, dir: CGVector, up: CGVector) {
        let scalars = decoded.unicodeScalars
        if scalars.isEmpty {                                  // undecodable glyph: no text, not a space
            if active { lastPen = pen }
            return
        }
        if scalars.allSatisfy({ $0.properties.isWhitespace }) {
            if active {
                pending = max(pending, .space)
                lastPen = pen
            }
            return
        }
        var separator = Separator.none
        var along: CGFloat = 0
        if active {
            if style != self.style || abs(em - self.em) > 0.15 * self.em {
                finishRun()
            } else {
                let dx = origin.x - lastPen.x, dy = origin.y - lastPen.y
                along = (dx * dir.dx + dy * dir.dy) / em
                let perp = (dx * up.dx + dy * up.dy) / em
                if perp > Self.lineShift || perp < -Self.maxLineDrop {
                    finishRun()                                   // column or float jump
                } else if perp < -Self.lineShift {
                    separator = .newline
                } else if along > Self.maxGap || along < -Self.maxBacktrack {
                    finishRun()                                   // table cell, overprint
                } else if along > Self.spaceGap {
                    separator = .space
                }
                if active { separator = max(separator, pending) }
            }
        }

        let rect = Self.glyphRect(origin: origin, end: glyphEnd, up: up, em: em)
        if !active {
            active = true
            self.style = style
            self.fontName = fontName
            self.em = em
            line = 0
            separator = .none
        }
        if separator != .none {
            closeWord()
            if separator == .newline { line += 1 }
        }

        // Spacing accents (TeX builds accented letters from accent + letter).
        if scalars.count == 1, let combining = Self.combiningAccent(for: scalars.first!) {
            if !wordText.isEmpty && separator == .none && along < -0.1 {
                wordText.append(combining)                        // accent drawn over the previous letter
            } else {
                pendingAccent = combining
            }
            wordRect = wordRect.union(rect)
            lastPen = pen
            pending = .none
            return
        }

        var appended = false
        for s in scalars {
            wordText.append(s)
            if !appended, let accent = pendingAccent, s.properties.isAlphabetic {
                wordText.append(accent)
                pendingAccent = nil
            }
            appended = true
        }
        let keyCount = key.count
        EmphasisFolding.fold(decoded, into: &key, cache: &foldCache)
        if key.count > keyCount && wordFirstGlyph.isNull { wordFirstGlyph = rect }
        wordRect = wordRect.union(rect)
        lastPen = pen
        pending = .none
    }

    mutating func finishRun() {
        guard active else { return }
        closeWord()
        let text = EmphasisText.join(words[...])
        let hasAlphanumerics = text.unicodeScalars.contains { $0.properties.isAlphabetic || ("0"..."9").contains($0) }
        if hasAlphanumerics && !key.isEmpty,
           let first = words.first(where: { !$0.keyRange.isEmpty }) {
            runs.append(RawEmphasisRun(style: style, fontName: fontName, fontSize: em, text: text, key: key,
                                       words: words, firstGlyphRect: first.firstGlyphRect))
        }
        active = false
        key.removeAll(keepingCapacity: true)
        words.removeAll()
        wordKeyStart = 0
        line = 0
        pending = .none
        pendingAccent = nil
    }

    private mutating func closeWord() {
        if !wordText.isEmpty {
            var expanded = String.UnicodeScalarView()
            for s in wordText {
                switch s.value {                                     // ligature code points from ToUnicode maps
                case 0xFB00: expanded.append(contentsOf: "ff".unicodeScalars)
                case 0xFB01: expanded.append(contentsOf: "fi".unicodeScalars)
                case 0xFB02: expanded.append(contentsOf: "fl".unicodeScalars)
                case 0xFB03: expanded.append(contentsOf: "ffi".unicodeScalars)
                case 0xFB04: expanded.append(contentsOf: "ffl".unicodeScalars)
                case 0xFB05, 0xFB06: expanded.append(contentsOf: "st".unicodeScalars)
                default: expanded.append(s)
                }
            }
            let text = String(expanded).precomposedStringWithCanonicalMapping
            words.append(RawEmphasisWord(text: text, keyRange: wordKeyStart..<key.count, line: line,
                                         rect: wordRect, firstGlyphRect: wordFirstGlyph))
        }
        wordText = String.UnicodeScalarView()
        wordKeyStart = key.count
        wordRect = .null
        wordFirstGlyph = .null
    }

    private static func glyphRect(origin: CGPoint, end: CGPoint, up: CGVector, em: CGFloat) -> CGRect {
        let down = CGVector(dx: -up.dx * 0.25 * em, dy: -up.dy * 0.25 * em)
        let top = CGVector(dx: up.dx * 0.75 * em, dy: up.dy * 0.75 * em)
        let xs = [origin.x + down.dx, origin.x + top.dx, end.x + down.dx, end.x + top.dx]
        let ys = [origin.y + down.dy, origin.y + top.dy, end.y + down.dy, end.y + top.dy]
        let minX = xs.min()!, minY = ys.min()!
        return CGRect(x: minX, y: minY, width: max(xs.max()! - minX, 0.01), height: max(ys.max()! - minY, 0.01))
    }

    private static func combiningAccent(for s: Unicode.Scalar) -> Unicode.Scalar? {
        switch s.value {
        case 0x60: return "\u{300}"
        case 0xB4: return "\u{301}"
        case 0x2C6, 0x5E: return "\u{302}"
        case 0x2DC, 0x7E: return "\u{303}"
        case 0xAF, 0x2C9: return "\u{304}"
        case 0x2D8: return "\u{306}"
        case 0x2D9: return "\u{307}"
        case 0xA8: return "\u{308}"
        case 0x2DA: return "\u{30A}"
        case 0x2DD: return "\u{30B}"
        case 0x2C7: return "\u{30C}"
        case 0xB8: return "\u{327}"
        case 0x2DB: return "\u{328}"
        default: return nil
        }
    }
}

// MARK: - Fonts

final class EmphasisFontInfo {
    let name: String
    let style: EmphasisRun.Style?
    let isMath: Bool
    let isCID: Bool
    private(set) var codeBytes = 1
    /// Multiplier from Tfs to the em size (Type 3 fonts with unusual FontMatrix).
    private(set) var emScale: CGFloat = 1
    private var simpleWidths = [CGFloat](repeating: -1, count: 256)   // in ems; < 0 = unknown
    private var cidWidths: [UInt32: CGFloat] = [:]
    private var defaultWidth: CGFloat = 0.5
    private var simpleUnicode = [String?](repeating: nil, count: 256)
    /// Glyph names of a simple font, by code: from /Differences, else the embedded Type 1 program's own
    /// encoding, else TeX's table for the font (“summationdisplay”, “parenleftbig”). The formula reader needs
    /// them: a ToUnicode map cannot tell a display sum from a text one, or the pieces of a tall parenthesis.
    private(set) var glyphNames = [String?](repeating: nil, count: 256)
    private var cidUnicode: [UInt32: String] = [:]
    private var letterFlags = [Bool](repeating: false, count: 256)
    private var spaceFlags = [Bool](repeating: false, count: 256)

    init(dictionary font: CGPDFDictionaryRef) {
        let subtype = EmphasisPDF.name(font, "Subtype") ?? ""
        let isType0 = subtype == "Type0"
        let isType3 = subtype == "Type3"
        isCID = isType0
        var descendant: CGPDFDictionaryRef?
        if isType0, let fonts = EmphasisPDF.array(font, "DescendantFonts") {
            var d: CGPDFDictionaryRef?
            if CGPDFArrayGetDictionary(fonts, 0, &d) { descendant = d }
        }
        let descriptor = EmphasisPDF.dictionary(descendant ?? font, "FontDescriptor")
        var baseName = EmphasisPDF.name(font, "BaseFont")
            ?? descriptor.flatMap { EmphasisPDF.name($0, "FontName") }
            ?? (isType3 ? "Type3" : "")
        baseName = EmphasisFontClassifier.stripSubsetPrefix(baseName)
        if isType0, let dash = baseName.range(of: "-Identity", options: .backwards) {
            baseName = String(baseName[..<dash.lowerBound])
        }
        name = baseName
        let flags = descriptor.flatMap { EmphasisPDF.integer($0, "Flags") } ?? 0
        let italicAngle = descriptor.flatMap { EmphasisPDF.number($0, "ItalicAngle") } ?? 0
        let weight = descriptor.flatMap { EmphasisPDF.number($0, "FontWeight") } ?? 0
        let classification = EmphasisFontClassifier.classify(baseName, flags: flags, italicAngle: italicAngle,
                                                             weight: weight, isType3: isType3)
        style = classification.style
        isMath = classification.isMath

        // Widths.
        var glyphScale: CGFloat = 0.001
        if isType3, let fm = EmphasisPDF.numbers(font, "FontMatrix"), fm.count == 6 {
            glyphScale = fm[0]
            // Type 3 glyph space has no fixed em (bitmap TeX fonts use pixels): take
            // the font's bounding-box height as the em, else assume 1000 units.
            var units: CGFloat = 1000
            if let bbox = EmphasisPDF.numbers(font, "FontBBox"), bbox.count == 4, abs(bbox[3] - bbox[1]) > 0 {
                units = abs(bbox[3] - bbox[1])
            }
            emScale = abs(fm[3]) * units
            if !(emScale > 0) || !emScale.isFinite { emScale = 1 }
        }
        if let missing = descriptor.flatMap({ EmphasisPDF.number($0, "MissingWidth") }), missing > 0 {
            defaultWidth = missing * glyphScale
        }
        if isType0 {
            codeBytes = 2
            if let d = descendant {
                if let dw = EmphasisPDF.number(d, "DW") { defaultWidth = dw * 0.001 } else { defaultWidth = 1 }
                if let w = EmphasisPDF.array(d, "W") { parseCIDWidths(w) }
            }
        } else if let widths = EmphasisPDF.array(font, "Widths") {
            let first = EmphasisPDF.integer(font, "FirstChar") ?? 0
            for i in 0..<CGPDFArrayGetCount(widths) {
                var w: CGPDFReal = 0
                let code = first + i
                if code >= 0 && code < 256 && CGPDFArrayGetNumber(widths, i, &w) {
                    simpleWidths[code] = w * glyphScale
                }
            }
        }

        // Decoding: ToUnicode › Encoding (+Differences) › built-in tables.
        let toUnicode = EmphasisPDF.stream(font, "ToUnicode").flatMap { EmphasisCMap.parse($0) }
        if isType0 {
            if let cmap = toUnicode {
                cidUnicode = cmap.map
                if cmap.codeBytes == 1 { codeBytes = 1 }
            }
        } else {
            var names = [String?](repeating: nil, count: 256)
            var table = EmphasisFontInfo.baseTable(font: font, baseName: baseName, subtype: subtype, flags: flags, names: &names)
            if names.allSatisfy({ $0 == nil }) || TeXFontEncodings.table(for: baseName) != nil {
                // No /Differences (or only some): the font program's own encoding, then TeX's slots for its fonts.
                let program = descriptor.flatMap { EmphasisPDF.stream($0, "FontFile") }.flatMap { Type1ProgramEncoding.names(in: $0) }
                let tex = TeXFontEncodings.table(for: baseName)
                let reencoded = names.contains { $0 != nil }
                for code in 0..<256 where names[code] == nil {
                    if let name = program?[code] { names[code] = name }
                    // A producer that wrote /Differences re-encoded the subset: its other codes are not TeX's slots.
                    else if !reencoded, let name = tex.flatMap({ TeXFontEncodings.name(in: $0, code: code) }) { names[code] = name }
                }
                // The built-in tables above are those of text fonts: a math font's letters come from its glyph names.
                for code in 0..<256 where table[code] == nil || classification.isMath {
                    if let name = names[code], let string = EmphasisGlyphNames.unicode(for: name) { table[code] = string }
                }
            }
            glyphNames = names
            if let cmap = toUnicode {
                for (code, string) in cmap.map where code < 256 { table[Int(code)] = string }
            }
            simpleUnicode = table
            for code in 0..<256 {
                guard let s = table[code], let first = s.unicodeScalars.first else { continue }
                letterFlags[code] = first.properties.isAlphabetic
                spaceFlags[code] = s.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
            }
            if table[32] == nil { spaceFlags[32] = true }
        }
    }

    @inline(__always)
    func width(_ code: UInt32) -> CGFloat {
        if isCID { return cidWidths[code] ?? defaultWidth }
        let w = code < 256 ? simpleWidths[Int(code)] : -1
        return w >= 0 ? w : defaultWidth
    }

    @inline(__always)
    func unicode(_ code: UInt32) -> String? {
        if isCID { return cidUnicode[code] }
        return code < 256 ? simpleUnicode[Int(code)] : nil
    }

    /// The glyph's name in the font's encoding, when the font is a simple one that names its glyphs.
    @inline(__always)
    func glyphName(_ code: UInt32) -> String? {
        isCID || code >= 256 ? nil : glyphNames[Int(code)]
    }

    @inline(__always)
    func isLetter(_ code: UInt32) -> Bool {
        if isCID { return cidUnicode[code]?.unicodeScalars.first?.properties.isAlphabetic ?? false }
        return code < 256 && letterFlags[Int(code)]
    }

    @inline(__always)
    func isSpace(_ code: UInt32) -> Bool {
        if isCID { return cidUnicode[code]?.unicodeScalars.allSatisfy { $0.properties.isWhitespace } ?? false }
        return code < 256 && spaceFlags[Int(code)]
    }

    private func parseCIDWidths(_ w: CGPDFArrayRef) {
        let count = CGPDFArrayGetCount(w)
        var i = 0
        while i < count {
            var first: CGPDFInteger = 0
            guard CGPDFArrayGetInteger(w, i, &first), first >= 0, first < 0x1_0000_0000 else { break }
            var list: CGPDFArrayRef?
            if i + 1 < count, CGPDFArrayGetArray(w, i + 1, &list), let list {
                for j in 0..<min(CGPDFArrayGetCount(list), 65536) {
                    var v: CGPDFReal = 0
                    if CGPDFArrayGetNumber(list, j, &v), let cid = UInt32(exactly: first + j) { cidWidths[cid] = v * 0.001 }
                }
                i += 2
            } else {
                var last: CGPDFInteger = 0
                var v: CGPDFReal = 0
                guard i + 2 < count, CGPDFArrayGetInteger(w, i + 1, &last), CGPDFArrayGetNumber(w, i + 2, &v),
                      last >= first, last - first < 65536 else { break }
                for cid in first...last { if let c = UInt32(exactly: cid) { cidWidths[c] = v * 0.001 } }
                i += 3
            }
        }
    }

    private static func baseTable(font: CGPDFDictionaryRef, baseName: String, subtype: String,
                                  flags: Int, names: inout [String?]) -> [String?] {
        var encodingName: String?
        var differences: CGPDFArrayRef?
        var object: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(font, "Encoding", &object), let object {
            switch CGPDFObjectGetType(object) {
            case .name:
                var n: UnsafePointer<Int8>?
                if CGPDFObjectGetValue(object, .name, &n), let n { encodingName = String(cString: n) }
            case .dictionary:
                var d: CGPDFDictionaryRef?
                if CGPDFObjectGetValue(object, .dictionary, &d), let d {
                    encodingName = EmphasisPDF.name(d, "BaseEncoding")
                    differences = EmphasisPDF.array(d, "Differences")
                }
            default:
                break
            }
        }
        var table: [String?]
        switch encodingName {
        case "WinAnsiEncoding": table = EmphasisEncodings.winAnsi
        case "MacRomanEncoding": table = EmphasisEncodings.macRoman
        case "StandardEncoding", "MacExpertEncoding": table = EmphasisEncodings.standard
        default: table = EmphasisEncodings.builtIn(for: baseName, subtype: subtype, symbolic: flags & 4 != 0)
        }
        if let differences {
            var code = 0
            for i in 0..<CGPDFArrayGetCount(differences) {
                var n: CGPDFInteger = 0
                var glyph: UnsafePointer<Int8>?
                if CGPDFArrayGetInteger(differences, i, &n) {
                    code = n
                } else if CGPDFArrayGetName(differences, i, &glyph), let glyph {
                    if code >= 0 && code < 256 {
                        let name = String(cString: glyph)
                        table[code] = EmphasisGlyphNames.unicode(for: name)
                        if name != ".notdef" { names[code] = name }
                    }
                    code += 1
                }
            }
        }
        return table
    }
}

enum EmphasisFontClassifier {
    static func stripSubsetPrefix(_ name: String) -> String {
        let scalars = Array(name.unicodeScalars)
        if scalars.count > 7, scalars[6] == "+", scalars[0..<6].allSatisfy({ ("A"..."Z").contains($0) }) {
            return String(String.UnicodeScalarView(scalars[7...]))
        }
        return name
    }

    private static let mathPrefixes = [
        "CMMI", "CMSY", "CMBSY", "CMEX", "MSAM", "MSBM", "EUFM", "EUFB", "EURM", "EURB", "EUSM", "EUSB",
        "EUEX", "RSFS", "LASY", "WASY", "STMARY", "ESINT", "BBOLD", "BBM", "DSROM", "TXMI", "TXSY", "TXEX",
        "PXMI", "PXSY", "PXEX", "RTXMI", "RPXMI", "MTMI", "MTSY", "MTEX", "LMMI", "LMSY", "LMEX", "ZPLM",
    ]
    private static let italicPrefixes = [
        "CMTI", "CMSL", "CMBXTI", "CMBXSL", "CMITT", "CMSSI", "CMUI", "CMFI", "SFTI", "SFSL", "SFBI", "SFBL",
        "SFSI", "SFSO", "SFIT", "SFST", "ECTI", "ECSL", "ECBI", "ECBL", "ECSI", "ECSO", "ECIT", "ECST",
    ]
    private static let boldPrefixes = [
        "CMBX", "CMB10", "CMB12", "CMSSBX", "CMSSDC", "SFBX", "SFSX", "SFBI", "SFBL", "ECBX", "ECSX",
        "ECBI", "ECBL",
    ]

    static func classify(_ name: String, flags: Int, italicAngle: CGFloat, weight: CGFloat,
                         isType3: Bool) -> (style: EmphasisRun.Style?, isMath: Bool) {
        let upper = name.uppercased()
        let lower = name.lowercased()
        if lower.contains("math") || lower.contains("symbol") || lower.contains("dingbat")
            || lower.contains("wingding") || lower.contains("webding")
            || mathPrefixes.contains(where: { upper.hasPrefix($0) }) {
            return (nil, true)
        }
        if isType3 && name == "Type3" { return (nil, false) }

        // Style token: the part after the last "-" or "," ("MinionPro-BoldIt", "Arial,Italic").
        var token = Substring(name)
        if let sep = name.lastIndex(where: { $0 == "-" || $0 == "," }) { token = name[name.index(after: sep)...] }
        let tokenLower = token.lowercased()

        var bold = boldPrefixes.contains(where: { upper.hasPrefix($0) })
            || lower.contains("bold") || lower.contains("black") || lower.contains("heavy")
            || lower.contains("demi") || tokenLower.hasPrefix("bd") || token.contains("Bd")
            || (tokenLower.hasPrefix("medi") && !tokenLower.hasPrefix("medium"))
            || tokenLower.hasPrefix("semibd") || tokenLower.hasPrefix("hv") || tokenLower.hasPrefix("blk")
        var italic = italicPrefixes.contains(where: { upper.hasPrefix($0) })
            || lower.contains("ital") || lower.contains("oblique") || lower.contains("slant")
            || lower.contains("kursiv") || lower.contains("inclined") || tokenLower.hasSuffix("obl")
            || hasItToken(token)

        if !bold && !italic {
            // Name says nothing: fall back to the font descriptor.
            if weight >= 600 || flags & (1 << 18) != 0 { bold = true }
            if flags & (1 << 6) != 0 || abs(italicAngle) >= 4 { italic = true }
        }
        if bold { return (.bold, false) }
        if italic { return (.italic, false) }
        return (nil, false)
    }

    /// "It" as a style token: "MinionPro-It", "MinionPro-BoldIt", "SourceSerifPro-ItDisp".
    private static func hasItToken(_ token: Substring) -> Bool {
        let chars = Array(token)
        guard chars.count >= 2 else { return false }
        for i in 0..<(chars.count - 1) where chars[i] == "I" && chars[i + 1] == "t" {
            let next: Character? = i + 2 < chars.count ? chars[i + 2] : nil
            if let next, next.isLowercase { continue }
            return true
        }
        return false
    }
}

// MARK: - CGPDF helpers

enum EmphasisPDF {
    static func name(_ d: CGPDFDictionaryRef, _ key: String) -> String? {
        var v: UnsafePointer<Int8>?
        guard CGPDFDictionaryGetName(d, key, &v), let v else { return nil }
        return String(cString: v)
    }

    static func dictionary(_ d: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var v: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(d, key, &v) ? v : nil
    }

    static func array(_ d: CGPDFDictionaryRef, _ key: String) -> CGPDFArrayRef? {
        var v: CGPDFArrayRef?
        return CGPDFDictionaryGetArray(d, key, &v) ? v : nil
    }

    static func stream(_ d: CGPDFDictionaryRef, _ key: String) -> CGPDFStreamRef? {
        var v: CGPDFStreamRef?
        return CGPDFDictionaryGetStream(d, key, &v) ? v : nil
    }

    static func number(_ d: CGPDFDictionaryRef, _ key: String) -> CGFloat? {
        var v: CGPDFReal = 0
        return CGPDFDictionaryGetNumber(d, key, &v) ? v : nil
    }

    static func integer(_ d: CGPDFDictionaryRef, _ key: String) -> Int? {
        var v: CGPDFInteger = 0
        if CGPDFDictionaryGetInteger(d, key, &v) { return v }
        if let n = number(d, key), n.isFinite, abs(n) < 1e9 { return Int(n) }
        return nil
    }

    static func numbers(_ d: CGPDFDictionaryRef, _ key: String) -> [CGFloat]? {
        guard let a = array(d, key) else { return nil }
        var result: [CGFloat] = []
        for i in 0..<CGPDFArrayGetCount(a) {
            var v: CGPDFReal = 0
            guard CGPDFArrayGetNumber(a, i, &v) else { return nil }
            result.append(v)
        }
        return result
    }

    static func matrix(_ d: CGPDFDictionaryRef, _ key: String) -> CGAffineTransform? {
        guard let v = numbers(d, key), v.count == 6 else { return nil }
        return CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
    }
}

// MARK: - ToUnicode CMaps

enum EmphasisCMap {
    struct Result {
        var map: [UInt32: String] = [:]
        var codeBytes = 2
    }

    static func parse(_ stream: CGPDFStreamRef) -> Result? {
        var format = CGPDFDataFormat.raw
        guard let cfData = CGPDFStreamCopyData(stream, &format), format == .raw else { return nil }
        let data = cfData as Data
        return data.withUnsafeBytes { raw -> Result? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return parse(UnsafeBufferPointer(start: base, count: raw.count))
        }
    }

    private enum Token {
        case hex([UInt8]), open, close, word(String)
    }

    private static func parse(_ b: UnsafeBufferPointer<UInt8>) -> Result {
        var result = Result()
        var tokens: [Token] = []
        var i = 0
        let n = b.count
        func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 10 || c == 13 || c == 9 || c == 12 || c == 0 }
        let delimiters: Set<UInt8> = [40, 41, 47, 60, 62, 91, 93, 123, 125, 37]
        func hexValue(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        while i < n {
            let c = b[i]
            if isSpace(c) { i += 1; continue }
            if c == 37 { while i < n && b[i] != 10 && b[i] != 13 { i += 1 }; continue }      // %
            if c == 60 {                                                                      // <
                if i + 1 < n && b[i + 1] == 60 { i += 2; continue }                          // <<
                i += 1
                var bytes: [UInt8] = []
                var high: UInt8?
                while i < n && b[i] != 62 {
                    if let v = hexValue(b[i]) {
                        if let h = high { bytes.append(h << 4 | v); high = nil } else { high = v }
                    }
                    i += 1
                }
                if let h = high { bytes.append(h << 4) }
                i += 1
                tokens.append(.hex(bytes))
                continue
            }
            if c == 62 { i += 1; continue }                                                    // >
            if c == 91 { tokens.append(.open); i += 1; continue }                              // [
            if c == 93 { tokens.append(.close); i += 1; continue }                             // ]
            if c == 40 {                                                                       // ( ... )
                var depth = 0
                while i < n {
                    if b[i] == 92 { i += 2; continue }
                    if b[i] == 40 { depth += 1 } else if b[i] == 41 { depth -= 1; if depth == 0 { i += 1; break } }
                    i += 1
                }
                continue
            }
            if c == 47 { i += 1 }                                                             // /Name
            let start = i
            while i < n && !isSpace(b[i]) && !delimiters.contains(b[i]) { i += 1 }
            if i > start {
                let word = String(decoding: UnsafeBufferPointer(rebasing: b[start..<i]), as: UTF8.self)
                tokens.append(.word(c == 47 ? "/" + word : word))
            } else if c != 47 {
                i += 1
            }
        }

        func code(_ bytes: [UInt8]) -> UInt32 { bytes.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }
        func string(_ bytes: [UInt8]) -> String {
            var units: [UInt16] = []
            var k = 0
            while k + 1 < bytes.count { units.append(UInt16(bytes[k]) << 8 | UInt16(bytes[k + 1])); k += 2 }
            if bytes.count % 2 == 1 { units.append(UInt16(bytes[bytes.count - 1])) }
            return String(decoding: units, as: UTF16.self)
        }

        var codeLengths: [Int] = []
        var t = 0
        var mode = ""
        while t < tokens.count {
            switch tokens[t] {
            case .word(let w):
                if w.hasPrefix("begin") || w.hasPrefix("end") { mode = w }
                t += 1
            case .hex(let src) where mode == "begincodespacerange":
                codeLengths.append(src.count)
                t += 2
            case .hex(let src) where mode == "beginbfchar":
                if t + 1 < tokens.count, case .hex(let dst) = tokens[t + 1] {
                    result.map[code(src)] = string(dst)
                    codeLengths.append(src.count)
                }
                t += 2
            case .hex(let lo) where mode == "beginbfrange":
                guard t + 2 < tokens.count, case .hex(let hi) = tokens[t + 1] else { t += 1; continue }
                let loCode = code(lo), hiCode = code(hi)
                codeLengths.append(lo.count)
                if case .hex(let dst) = tokens[t + 2] {
                    if hiCode >= loCode && hiCode - loCode < 65536 {
                        var units: [UInt16] = []
                        var k = 0
                        while k + 1 < dst.count { units.append(UInt16(dst[k]) << 8 | UInt16(dst[k + 1])); k += 2 }
                        if !units.isEmpty {
                            for c in loCode...hiCode {
                                var u = units
                                u[u.count - 1] = u[u.count - 1] &+ UInt16(truncatingIfNeeded: c - loCode)
                                result.map[c] = String(decoding: u, as: UTF16.self)
                            }
                        }
                    }
                    t += 3
                } else if case .open = tokens[t + 2] {
                    var k = t + 3
                    var c = loCode
                    while k < tokens.count {
                        if case .hex(let dst) = tokens[k] {
                            if c <= hiCode { result.map[c] = string(dst) }
                            c += 1
                            k += 1
                        } else {
                            break
                        }
                    }
                    t = k + 1
                } else {
                    t += 3
                }
            default:
                t += 1
            }
        }
        if !codeLengths.isEmpty { result.codeBytes = codeLengths.max() == 1 ? 1 : 2 }
        return result
    }
}

// MARK: - Locating runs in page.string

/// The folded key of `page.string` with each key scalar's UTF-16 source range.
struct EmphasisPageKey {
    var scalars: [UInt32] = []
    var starts: [Int] = []
    var ends: [Int] = []

    init(_ string: String) {
        let units = Array(string.utf16)
        scalars.reserveCapacity(units.count)
        starts.reserveCapacity(units.count)
        ends.reserveCapacity(units.count)
        var cache = EmphasisFolding.Cache()
        var folded: [UInt32] = []
        var i = 0
        while i < units.count {
            var value = UInt32(units[i])
            var length = 1
            if UTF16.isLeadSurrogate(units[i]), i + 1 < units.count, UTF16.isTrailSurrogate(units[i + 1]) {
                value = 0x10000 + ((UInt32(units[i]) - 0xD800) << 10) + (UInt32(units[i + 1]) - 0xDC00)
                length = 2
            }
            folded.removeAll(keepingCapacity: true)
            EmphasisFolding.fold(value, into: &folded, cache: &cache)
            for s in folded {
                scalars.append(s)
                starts.append(i)
                ends.append(i + length)
            }
            i += length
        }
    }

    func occurrences(of key: ArraySlice<UInt32>, limit: Int) -> [Int] {
        guard let first = key.first, key.count <= scalars.count else { return [] }
        var result: [Int] = []
        let m = key.count
        scalars.withUnsafeBufferPointer { p in
            key.withUnsafeBufferPointer { k in
                var i = 0
                let last = p.count - m
                while i <= last {
                    if p[i] == first {
                        var j = 1
                        while j < m && p[i + j] == k[j] { j += 1 }
                        if j == m {
                            result.append(i)
                            if result.count >= limit { return }
                        }
                    }
                    i += 1
                }
            }
        }
        return result
    }
}

struct EmphasisLocator {
    let page: PDFPage
    let text: String
    let pageKey: EmphasisPageKey
    private var claimed: [Bool]
    private(set) var unlocated: [RawEmphasisRun] = []
    /// PDFKit bounds of each line of `text` (computed on first need).
    private var lineBoxes: [(start: Int, end: Int, rect: CGRect)]?
    /// Hyphenated compounds of the page (computed on first need).
    private var hyphenatedWords: Set<String>?

    /// A match is rejected when PDFKit places its first character further than
    /// this (in ems) from the run's first glyph.
    static let maxGeometryError = 2.0

    init(page: PDFPage, text: String) {
        self.page = page
        self.text = text
        pageKey = EmphasisPageKey(text)
        claimed = [Bool](repeating: false, count: pageKey.scalars.count)
    }

    private struct Piece {
        var start: Int            // page-key index, inclusive
        var end: Int              // page-key index, exclusive
        var words: Range<Int>     // indices into RawEmphasisRun.words
        var error: Double?
    }

    mutating func locate(_ scan: EmphasisScanResult) -> [LocatedEmphasisRun] {
        var located: [LocatedEmphasisRun] = []
        let body = scan.bodyFontSize
        for var raw in scan.runs {
            let relative = body > 0 ? (Double(raw.fontSize / body) * 100).rounded() / 100 : 1
            if raw.words.count > 1 && raw.words.last!.line > 0 {
                // A line-end hyphen that forms a compound written elsewhere on the page stays.
                if hyphenatedWords == nil { hyphenatedWords = EmphasisText.hyphenatedWords(in: text) }
                raw.text = EmphasisText.join(raw.words[...], hyphenated: hyphenatedWords ?? [])
            }
            if let m = bestMatch(key: raw.key[...], firstGlyph: raw.firstGlyphRect, em: raw.fontSize) {
                claim(m.start, m.end)
                let run = EmphasisRun(text: raw.text, range: range(m.start, m.end), style: raw.style,
                                      relativeSize: relative)
                located.append(LocatedEmphasisRun(run: run, raw: raw, method: m.ambiguous ? .disambiguated : .unique,
                                                  geometryError: m.error))
                continue
            }

            // Fallbacks: PDFKit may order lines or even words of a block differently
            // (captions beside figures, tall math). Locate lines, then words, then
            // fall back to rectangle selection, and merge pieces that are adjacent.
            var pieces: [Piece] = []
            var method = LocatedEmphasisRun.Method.perLine
            let lines = raw.lineGroups
            for lineWords in lines {
                let keyed = lineWords.filter { !raw.words[$0].keyRange.isEmpty }
                guard let firstWord = keyed.first, let lastWord = keyed.last else { continue }
                let lineKey = raw.words[firstWord].keyRange.lowerBound..<raw.words[lastWord].keyRange.upperBound
                if lines.count > 1,
                   let m = bestMatch(key: raw.key[lineKey], firstGlyph: raw.words[firstWord].firstGlyphRect,
                                     em: raw.fontSize) {
                    claim(m.start, m.end)
                    pieces.append(Piece(start: m.start, end: m.end, words: lineWords, error: m.error))
                    continue
                }
                for w in keyed {
                    let word = raw.words[w]
                    if keyed.count > 1 || lines.count > 1,
                       let m = bestMatch(key: raw.key[word.keyRange], firstGlyph: word.firstGlyphRect, em: raw.fontSize) {
                        claim(m.start, m.end)
                        pieces.append(Piece(start: m.start, end: m.end, words: w..<(w + 1), error: m.error))
                        if method == .perLine { method = .perWord }
                    } else if let g = geometricMatch(rect: word.rect, key: Array(raw.key[word.keyRange]), em: raw.fontSize) {
                        claim(g.start, g.end)
                        pieces.append(Piece(start: g.start, end: g.end, words: w..<(w + 1), error: nil))
                        method = .geometric
                    }
                }
            }
            guard !pieces.isEmpty else {
                unlocated.append(raw)
                continue
            }
            pieces.sort { $0.start < $1.start }
            var groups: [[Piece]] = []
            for piece in pieces {
                if let tail = groups.last?.last, piece.start == tail.end {
                    groups[groups.count - 1].append(piece)
                } else {
                    groups.append([piece])
                }
            }
            for group in groups {
                let start = group.first!.start, end = group.last!.end
                let indices = group.flatMap { Array($0.words) }
                let text = groups.count == 1 && indices == Array(0..<raw.words.count)
                    ? raw.text : EmphasisText.join(indices.map { raw.words[$0] }[...], hyphenated: hyphenatedWords ?? [])
                let run = EmphasisRun(text: text, range: range(start, end), style: raw.style, relativeSize: relative)
                located.append(LocatedEmphasisRun(run: run, raw: raw, method: method, geometryError: group.first!.error))
            }
        }
        located.sort { $0.run.range.location < $1.run.range.location }
        return located
    }

    // MARK: Matching

    private struct Match {
        var start: Int       // index into pageKey (inclusive)
        var end: Int         // index into pageKey (exclusive)
        var ambiguous: Bool
        var error: Double?
    }

    /// Occurrences of `key` not yet claimed; with several, the one PDFKit places
    /// nearest to `firstGlyph`. Rejects matches PDFKit places elsewhere.
    private mutating func bestMatch(key: ArraySlice<UInt32>, firstGlyph: CGRect, em: CGFloat) -> Match? {
        guard !key.isEmpty else { return nil }
        var candidates = pageKey.occurrences(of: key, limit: 100_000).filter { start in
            !(start..<(start + key.count)).contains { claimed[$0] }
        }
        guard !candidates.isEmpty else { return nil }
        // Short keys ("a", "not") occur many times: keep the occurrences whose
        // page.string line lies where the glyph is, before asking for exact rects.
        if candidates.count > 8 && !firstGlyph.isNull {
            let zone = firstGlyph.insetBy(dx: -em, dy: -0.5 * em)
            candidates = candidates.filter { start in
                guard let box = lineBox(containing: pageKey.starts[start]), !box.isNull else { return true }
                return box.intersects(zone)
            }
            guard !candidates.isEmpty else { return nil }
        }
        if candidates.count == 1 {
            let start = candidates[0]
            let error = geometryError(keyIndex: start, glyph: firstGlyph, em: em)
            if let error, error > Self.maxGeometryError { return nil }   // same text, elsewhere on the page
            return Match(start: start, end: start + key.count, ambiguous: false, error: error)
        }
        var best: (start: Int, error: Double)?
        for start in candidates.prefix(256) {
            guard let error = geometryError(keyIndex: start, glyph: firstGlyph, em: em) else { continue }
            if best == nil || error < best!.error { best = (start, error) }
            if error == 0 { break }
        }
        guard let best, best.error <= Self.maxGeometryError else { return nil }
        return Match(start: best.start, end: best.start + key.count, ambiguous: true, error: best.error)
    }

    /// Horizontal distance between centres (minus the part explained by width
    /// differences: PDFKit splits ligatures) and vertical distance outside
    /// PDFKit's box (PDFKit's line boxes can be several lines tall next to large
    /// delimiters), in ems.
    private func geometryError(keyIndex i: Int, glyph: CGRect, em: CGFloat) -> Double? {
        guard !glyph.isNull else { return nil }
        let r = NSRange(location: pageKey.starts[i], length: pageKey.ends[i] - pageKey.starts[i])
        guard let selection = page.selection(for: r) else { return nil }
        let b = selection.bounds(for: page)
        guard !b.isNull, b.width > 0 || b.height > 0 else { return nil }
        let dx = max(abs(b.midX - glyph.midX) - abs(b.width - glyph.width) / 2, 0)
        let dy = max(b.minY - glyph.midY, glyph.midY - b.maxY, 0)
        return Double(hypot(dx, dy) / max(em, 1))
    }

    private mutating func lineBox(containing offset: Int) -> CGRect? {
        if lineBoxes == nil {
            let ns = text as NSString
            var boxes: [(start: Int, end: Int, rect: CGRect)] = []
            var location = 0
            while location < ns.length {
                let line = ns.lineRange(for: NSRange(location: location, length: 0))
                var length = line.length
                while length > 0, let s = Unicode.Scalar(ns.character(at: line.location + length - 1)),
                      s.properties.isWhitespace { length -= 1 }
                var rect = CGRect.null
                if length > 0, let selection = page.selection(for: NSRange(location: line.location, length: length)) {
                    rect = selection.bounds(for: page)
                }
                boxes.append((line.location, NSMaxRange(line), rect))
                location = NSMaxRange(line)
            }
            lineBoxes = boxes
        }
        guard let boxes = lineBoxes, !boxes.isEmpty else { return nil }
        var lo = 0, hi = boxes.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if offset < boxes[mid].start { hi = mid - 1 } else if offset >= boxes[mid].end { lo = mid + 1 } else { return boxes[mid].rect }
        }
        return nil
    }

    private func geometricMatch(rect: CGRect, key: [UInt32], em: CGFloat) -> (start: Int, end: Int)? {
        guard !rect.isNull, !key.isEmpty else { return nil }
        let probe = rect.insetBy(dx: min(0.1 * em, rect.width / 4), dy: min(0.3 * em, rect.height / 4))
        guard let selection = page.selection(for: probe) else { return nil }
        var lo = Int.max, hi = Int.min
        for k in 0..<selection.numberOfTextRanges(on: page) {
            let r = selection.range(at: k, on: page)
            guard r.location != NSNotFound, r.length > 0 else { continue }
            lo = min(lo, r.location)
            hi = max(hi, r.location + r.length)
        }
        guard lo < hi, let startIndex = firstKeyIndex(atOrAfter: lo) else { return nil }
        var endIndex = startIndex
        while endIndex < pageKey.starts.count && pageKey.starts[endIndex] < hi { endIndex += 1 }
        guard endIndex > startIndex else { return nil }
        let selected = Array(pageKey.scalars[startIndex..<endIndex])
        guard Self.similarity(selected, key) >= 0.75,
              !(startIndex..<endIndex).contains(where: { claimed[$0] }) else { return nil }
        return (startIndex, endIndex)
    }

    private func firstKeyIndex(atOrAfter offset: Int) -> Int? {
        var lo = 0, hi = pageKey.starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if pageKey.starts[mid] < offset { lo = mid + 1 } else { hi = mid }
        }
        return lo < pageKey.starts.count ? lo : nil
    }

    /// Dice coefficient over scalar bigrams (1 for equal keys).
    static func similarity(_ a: [UInt32], _ b: [UInt32]) -> Double {
        if a == b { return 1 }
        guard a.count >= 2, b.count >= 2 else { return 0 }
        var counts: [UInt64: Int] = [:]
        for i in 0..<(a.count - 1) { counts[UInt64(a[i]) << 32 | UInt64(a[i + 1]), default: 0] += 1 }
        var common = 0
        for i in 0..<(b.count - 1) {
            let k = UInt64(b[i]) << 32 | UInt64(b[i + 1])
            if let c = counts[k], c > 0 { common += 1; counts[k] = c - 1 }
        }
        return Double(2 * common) / Double(a.count + b.count - 2)
    }

    private mutating func claim(_ start: Int, _ end: Int) {
        for i in start..<end { claimed[i] = true }
    }

    private func range(_ start: Int, _ end: Int) -> NSRange {
        NSRange(location: pageKey.starts[start], length: pageKey.ends[end - 1] - pageKey.starts[start])
    }
}

// MARK: - Encodings

enum EmphasisEncodings {
    static let winAnsi: [String?] = {
        var table = [String?](repeating: nil, count: 256)
        for code in 32..<256 {
            if let s = String(bytes: [UInt8(code)], encoding: .windowsCP1252), s.unicodeScalars.first?.value != 0xFFFD {
                table[code] = s
            }
        }
        table[0x7F] = nil
        table[0xA0] = " "
        table[0xAD] = "-"
        return table
    }()

    static let macRoman: [String?] = {
        var table = [String?](repeating: nil, count: 256)
        for code in 32..<256 {
            if let s = String(bytes: [UInt8(code)], encoding: .macOSRoman) { table[code] = s }
        }
        table[0x7F] = nil
        table[0xCA] = " "
        return table
    }()

    static let standard: [String?] = {
        var table = ascii
        table[0x27] = "\u{2019}"
        table[0x60] = "\u{2018}"
        let high: [Int: String] = [
            0xA1: "exclamdown", 0xA2: "cent", 0xA3: "sterling", 0xA4: "fraction", 0xA5: "yen", 0xA6: "florin",
            0xA7: "section", 0xA8: "currency", 0xA9: "quotesingle", 0xAA: "quotedblleft", 0xAB: "guillemotleft",
            0xAC: "guilsinglleft", 0xAD: "guilsinglright", 0xAE: "fi", 0xAF: "fl", 0xB1: "endash", 0xB2: "dagger",
            0xB3: "daggerdbl", 0xB4: "periodcentered", 0xB6: "paragraph", 0xB7: "bullet", 0xB8: "quotesinglbase",
            0xB9: "quotedblbase", 0xBA: "quotedblright", 0xBB: "guillemotright", 0xBC: "ellipsis",
            0xBD: "perthousand", 0xBF: "questiondown", 0xC1: "grave", 0xC2: "acute", 0xC3: "circumflex",
            0xC4: "tilde", 0xC5: "macron", 0xC6: "breve", 0xC7: "dotaccent", 0xC8: "dieresis", 0xCA: "ring",
            0xCB: "cedilla", 0xCD: "hungarumlaut", 0xCE: "ogonek", 0xCF: "caron", 0xD0: "emdash", 0xE1: "AE",
            0xE3: "ordfeminine", 0xE8: "Lslash", 0xE9: "Oslash", 0xEA: "OE", 0xEB: "ordmasculine", 0xF1: "ae",
            0xF5: "dotlessi", 0xF8: "lslash", 0xF9: "oslash", 0xFA: "oe", 0xFB: "germandbls",
        ]
        for (code, name) in high { table[code] = EmphasisGlyphNames.unicode(for: name) }
        return table
    }()

    /// TeX OT1 (Computer Modern text fonts) for fonts embedded without /Encoding.
    static let ot1: [String?] = {
        var table = ascii
        let names = ["Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Upsilon", "Phi", "Psi", "Omega",
                     "ff", "fi", "fl", "ffi", "ffl", "dotlessi", "dotlessj", "grave", "acute", "caron", "breve",
                     "macron", "ring", "cedilla", "germandbls", "ae", "oe", "oslash", "AE", "OE", "Oslash"]
        for (code, name) in names.enumerated() { table[code] = EmphasisGlyphNames.unicode(for: name) }
        let fixes: [Int: String] = [0x20: "", 0x22: "\u{201D}", 0x27: "\u{2019}", 0x3C: "\u{A1}", 0x3E: "\u{BF}",
                                    0x5C: "\u{201C}", 0x5E: "\u{2C6}", 0x5F: "\u{2D9}", 0x60: "\u{2018}",
                                    0x7B: "\u{2013}", 0x7C: "\u{2014}", 0x7D: "\u{2DD}", 0x7E: "\u{2DC}",
                                    0x7F: "\u{A8}"]
        for (code, s) in fixes { table[code] = s }
        return table
    }()

    /// TeX T1/Cork (EC / cm-super fonts) for fonts embedded without /Encoding.
    static let t1: [String?] = {
        var table = ascii
        let low = ["`", "\u{B4}", "\u{2C6}", "\u{2DC}", "\u{A8}", "\u{2DD}", "\u{2DA}", "\u{2C7}", "\u{2D8}", "\u{AF}",
                   "\u{2D9}", "\u{B8}", "\u{2DB}", "\u{201A}", "\u{2039}", "\u{203A}", "\u{201C}", "\u{201D}",
                   "\u{201E}", "\u{AB}", "\u{BB}", "\u{2013}", "\u{2014}", "", "0", "\u{131}", "\u{237}", "ff", "fi",
                   "fl", "ffi", "ffl"]
        for (code, s) in low.enumerated() { table[code] = s }
        table[0x20] = "\u{2423}"
        table[0x27] = "\u{2019}"
        table[0x60] = "\u{2018}"
        table[0x7F] = "-"
        let high = Array("ĂĄĆČĎĚĘĞĹĽŁŃŇŊŐŔŘŚŠŞŤŢŰŮŸŹŽŻĲİđ§ăąćčďěęğĺľłńňŋőŕřśšşťţűůÿźžżĳ¡¿£")
        for (k, ch) in high.enumerated() { table[0x80 + k] = String(ch) }
        for code in 0xC0...0xFF { table[code] = String(UnicodeScalar(UInt8(code))) }
        table[0xD7] = "Œ"
        table[0xDF] = "SS"
        table[0xF7] = "œ"
        table[0xFF] = "ß"
        return table
    }()

    private static let ascii: [String?] = {
        var table = [String?](repeating: nil, count: 256)
        for code in 32..<127 { table[code] = String(UnicodeScalar(UInt8(code))) }
        return table
    }()

    static func builtIn(for baseName: String, subtype: String, symbolic: Bool) -> [String?] {
        let upper = baseName.uppercased()
        if upper.hasPrefix("CMTT") || upper.hasPrefix("CMITT") || upper.hasPrefix("CMSLTT") { return ascii }
        if upper.hasPrefix("CM") || upper.hasPrefix("LCMSS") { return ot1 }
        if upper.hasPrefix("SF") || upper.hasPrefix("EC") || upper.hasPrefix("TC") { return t1 }
        if subtype == "TrueType" { return symbolic ? ascii : winAnsi }
        return standard
    }
}

enum EmphasisGlyphNames {
    static func unicode(for glyphName: String) -> String? {
        var name = Substring(glyphName)
        if let dot = name.firstIndex(of: "."), dot != name.startIndex { name = name[..<dot] }  // "a.sc"
        if let s = table[String(name)] { return s }
        if name.count == 1, let c = name.first, c.isLetter || c.isNumber { return String(c) }
        if name.contains("_") {                                                               // "f_f_i"
            let parts = name.split(separator: "_").map { unicode(for: String($0)) }
            if parts.allSatisfy({ $0 != nil }) { return parts.compactMap { $0 }.joined() }
        }
        if name.hasPrefix("uni"), name.count >= 7, (name.count - 3) % 4 == 0 {
            var units: [UInt16] = []
            var rest = name.dropFirst(3)
            while !rest.isEmpty {
                guard let v = UInt16(rest.prefix(4), radix: 16) else { return nil }
                units.append(v)
                rest = rest.dropFirst(4)
            }
            return String(decoding: units, as: UTF16.self)
        }
        if name.hasPrefix("u"), (5...7).contains(name.count), let v = UInt32(name.dropFirst(), radix: 16),
           let scalar = Unicode.Scalar(v) {
            return String(scalar)
        }
        // Precomposed Latin letters: "eacute", "Odieresis", "ccedilla", …
        if name.count > 1, let first = name.first, first.isASCII, first.isLetter,
           let mark = combining[String(name.dropFirst())] {
            return (String(first) + mark).precomposedStringWithCanonicalMapping
        }
        return nil
    }

    private static let combining: [String: String] = [
        "grave": "\u{300}", "acute": "\u{301}", "circumflex": "\u{302}", "tilde": "\u{303}", "macron": "\u{304}",
        "breve": "\u{306}", "dotaccent": "\u{307}", "dieresis": "\u{308}", "ring": "\u{30A}",
        "hungarumlaut": "\u{30B}", "caron": "\u{30C}", "cedilla": "\u{327}", "ogonek": "\u{328}",
        "commaaccent": "\u{326}",
    ]

    private static let table: [String: String] = [
        "space": " ", "nbspace": " ", "nonbreakingspace": " ", "exclam": "!", "quotedbl": "\"", "numbersign": "#",
        "dollar": "$", "percent": "%", "ampersand": "&", "quotesingle": "'", "parenleft": "(", "parenright": ")",
        "asterisk": "*", "plus": "+", "comma": ",", "hyphen": "-", "sfthyphen": "-", "hyphensoft": "-",
        "period": ".", "slash": "/", "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9", "colon": ":", "semicolon": ";", "less": "<",
        "equal": "=", "greater": ">", "question": "?", "at": "@", "bracketleft": "[", "backslash": "\\",
        "bracketright": "]", "asciicircum": "^", "underscore": "_", "grave": "`", "braceleft": "{", "bar": "|",
        "braceright": "}", "asciitilde": "~",
        "quoteleft": "\u{2018}", "quoteright": "\u{2019}", "quotedblleft": "\u{201C}", "quotedblright": "\u{201D}",
        "quotesinglbase": "\u{201A}", "quotedblbase": "\u{201E}", "guillemotleft": "\u{AB}",
        "guillemotright": "\u{BB}", "guilsinglleft": "\u{2039}", "guilsinglright": "\u{203A}",
        "endash": "\u{2013}", "emdash": "\u{2014}", "bullet": "\u{2022}", "ellipsis": "\u{2026}",
        "dagger": "\u{2020}", "daggerdbl": "\u{2021}", "perthousand": "\u{2030}", "trademark": "\u{2122}",
        "copyright": "\u{A9}", "registered": "\u{AE}", "section": "\u{A7}", "paragraph": "\u{B6}",
        "exclamdown": "\u{A1}", "questiondown": "\u{BF}", "cent": "\u{A2}", "sterling": "\u{A3}", "yen": "\u{A5}",
        "currency": "\u{A4}", "florin": "\u{192}", "fraction": "\u{2044}", "periodcentered": "\u{B7}",
        "minus": "\u{2212}", "multiply": "\u{D7}", "divide": "\u{F7}", "plusminus": "\u{B1}", "degree": "\u{B0}",
        "mu": "\u{B5}", "ordfeminine": "\u{AA}", "ordmasculine": "\u{BA}", "onehalf": "\u{BD}",
        "onequarter": "\u{BC}", "threequarters": "\u{BE}", "onesuperior": "\u{B9}", "twosuperior": "\u{B2}",
        "threesuperior": "\u{B3}", "brokenbar": "\u{A6}", "logicalnot": "\u{AC}", "Euro": "\u{20AC}",
        "visiblespace": "\u{2423}", "cwm": "", "compwordmark": "", "suppress": "",
        "acute": "\u{B4}", "circumflex": "\u{2C6}", "tilde": "\u{2DC}", "dieresis": "\u{A8}",
        "ring": "\u{2DA}", "cedilla": "\u{B8}", "caron": "\u{2C7}", "breve": "\u{2D8}", "macron": "\u{AF}",
        "dotaccent": "\u{2D9}", "hungarumlaut": "\u{2DD}", "ogonek": "\u{2DB}",
        "ff": "ff", "fi": "fi", "fl": "fl", "ffi": "ffi", "ffl": "ffl", "dotlessi": "\u{131}",
        "dotlessj": "\u{237}", "germandbls": "\u{DF}", "ae": "\u{E6}", "AE": "\u{C6}", "oe": "\u{153}",
        "OE": "\u{152}", "oslash": "\u{F8}", "Oslash": "\u{D8}", "lslash": "\u{142}", "Lslash": "\u{141}",
        "eth": "\u{F0}", "Eth": "\u{D0}", "thorn": "\u{FE}", "Thorn": "\u{DE}", "dcroat": "\u{111}",
        "Dcroat": "\u{110}", "eng": "\u{14B}", "Eng": "\u{14A}", "ij": "\u{133}", "IJ": "\u{132}",
        "Gamma": "\u{393}", "Delta": "\u{394}", "Theta": "\u{398}", "Lambda": "\u{39B}", "Xi": "\u{39E}",
        "Pi": "\u{3A0}", "Sigma": "\u{3A3}", "Upsilon": "\u{3A5}", "Phi": "\u{3A6}", "Psi": "\u{3A8}",
        "Omega": "\u{3A9}", "alpha": "\u{3B1}", "beta": "\u{3B2}", "gamma": "\u{3B3}", "delta": "\u{3B4}",
        "epsilon": "\u{3B5}", "zeta": "\u{3B6}", "eta": "\u{3B7}", "theta": "\u{3B8}", "iota": "\u{3B9}",
        "kappa": "\u{3BA}", "lambda": "\u{3BB}", "nu": "\u{3BD}", "xi": "\u{3BE}", "omicron": "\u{3BF}",
        "pi": "\u{3C0}", "rho": "\u{3C1}", "sigma": "\u{3C3}", "sigma1": "\u{3C2}", "tau": "\u{3C4}",
        "upsilon": "\u{3C5}", "phi": "\u{3C6}", "chi": "\u{3C7}", "psi": "\u{3C8}", "omega": "\u{3C9}",
    ]
}
