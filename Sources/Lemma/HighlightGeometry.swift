import CoreGraphics
import PDFKit
import LemmaCore

/// Page-space line bands, shared by drawing and hit testing. PDFKit sometimes gives every character on a line
/// a math font's oversized ascent/descent. Divide the available space between neighbouring visual lines instead.
struct HighlightGeometry {
    private struct Line {
        var rect: CGRect
        var center: CGFloat
        var size: CGFloat
        var members: [CGRect]
        var anchorWidth: CGFloat
    }
    private let lines: [Line]

    init(page: PDFPage, fonts: InkFontCache) {
        let fragments = PageReferenceAnalyzer.columnFragments(on: page)
        let rects = fragments.map(\.bounds)
        let overlaps = rects.enumerated().contains { index, rect in
            rects.dropFirst(index + 1).contains { other in rect.intersects(other) }
        }
        // Most pages need no correction, and never incur a content-stream scan. Font decoding is shared per document.
        let glyphs = overlaps ? PageInkScanner.scan(page, cache: fonts).glyphs : []
        let fragmentsWithAnchors = rects.map { rect in
            let ink = glyphs.filter { glyph in
                glyph.width > 0 && rect.contains(CGPoint(x: glyph.midX, y: glyph.y + glyph.size * 0.25))
            }
            // A weighted median keeps an inline superscript, accent or large operator from moving the prose baseline.
            func median(_ value: (InkGlyph) -> CGFloat, fallback: CGFloat) -> CGFloat {
                let ordered = ink.sorted { value($0) < value($1) }
                let half = ordered.reduce(CGFloat.zero) { $0 + $1.width } / 2
                var width: CGFloat = 0
                for glyph in ordered {
                    width += glyph.width
                    if width >= half { return value(glyph) }
                }
                return fallback
            }
            return Line(rect: rect, center: median({ $0.y + $0.size * 0.25 }, fallback: rect.midY),
                        size: median(\.size, fallback: rect.height), members: [rect], anchorWidth: rect.width)
        }
        var rows: [Line] = []
        for fragment in fragmentsWithAnchors {
            if let index = rows.firstIndex(where: { row in
                let gap = max(fragment.rect.minX - row.rect.maxX, row.rect.minX - fragment.rect.maxX)
                return (gap <= max(row.size, fragment.size) * 0.5
                        && abs(row.center - fragment.center) <= max(row.size, fragment.size) * 0.5)
                    || row.members.contains { $0.contains(fragment.rect) || fragment.rect.contains($0) }
            }) {
                rows[index].rect = rows[index].rect.union(fragment.rect)
                rows[index].members.append(fragment.rect)
                if fragment.anchorWidth > rows[index].anchorWidth {
                    rows[index].center = fragment.center; rows[index].size = fragment.size
                    rows[index].anchorWidth = fragment.anchorWidth
                }
            } else { rows.append(fragment) }
        }
        lines = rows
    }

    private func lineIndex(for rect: CGRect) -> Int? {
        // Captured areas and multi-line rectangles keep their exact geometry. Only a text line's font box is fitted.
        lines.firstIndex { line in
            line.members.contains {
                abs($0.minY - rect.minY) < 0.5 && abs($0.maxY - rect.maxY) < 0.5
                    && $0.minX <= rect.minX + 0.5 && $0.maxX >= rect.maxX - 0.5
            }
        }
    }

    func bounds(for rect: CGRect) -> CGRect {
        guard let index = lineIndex(for: rect) else { return rect }
        return bounds(for: rect, in: lines[index])
    }

    /// Scripts can split one visual line into overlapping PDFKit selections. Paint their combined span once.
    func rects(for regions: [CGRect]) -> [CGRect] {
        var grouped: [(line: Int?, rect: CGRect)] = []
        for rect in regions {
            let line = lineIndex(for: rect)
            if let line, let index = grouped.firstIndex(where: { $0.line == line }) {
                grouped[index].rect = grouped[index].rect.union(rect)
            } else { grouped.append((line, rect)) }
        }
        return grouped.map { entry in
            entry.line.map { bounds(for: entry.rect, in: lines[$0]) } ?? entry.rect
        }
    }

    private func bounds(for rect: CGRect, in line: Line) -> CGRect {
        var bottom = rect.minY, top = rect.maxY
        for other in lines where other.rect.minX < line.rect.maxX && other.rect.maxX > line.rect.minX {
            let distance = other.center - line.center
            // Fragments of the same visual line (including scripts) do not constrain one another.
            guard abs(distance) > min(line.size, other.size) * 0.5 else { continue }
            let boundary = (line.center * other.size + other.center * line.size) / (line.size + other.size)
            let halfGap = min(0.4, abs(distance) * 0.04)
            if distance < 0 { bottom = max(bottom, boundary + halfGap) }
            else { top = min(top, boundary - halfGap) }
        }
        guard top > bottom else { return rect }
        return CGRect(x: rect.minX, y: bottom, width: rect.width, height: top - bottom)
    }
}
