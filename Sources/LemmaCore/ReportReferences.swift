import Foundation
import PDFKit

/// Boxes and lettered special features identified by a report's embedded bookmarks.
public struct ReportReferences: Sendable {
    public struct Heading: Sendable {
        public let key: ReferenceKey
        public let item: OutlineItem

        public func target(in document: PDFDocument) -> ReferenceTarget? {
            PageReferenceAnalyzer.target(for: LinkDestination(pageIndex: item.pageIndex, point: item.point),
                                         key: key, in: document, origin: .outline)
        }
    }

    public let headings: [Heading]
    private let boxes: [(heading: Heading, end: OutlineItem?)]
    private static let featureTitle = try! NSRegularExpression(pattern: #"^([A-Z])\s+\p{L}"#)

    public init(outline: [OutlineItem]) {
        var headings: [Heading] = []
        var boxes: [(Heading, OutlineItem?)] = []
        var featuresLevel: Int?
        for (index, item) in outline.enumerated() {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if let level = featuresLevel, item.level <= level { featuresLevel = nil }
            if title.caseInsensitiveCompare("Special features") == .orderedSame {
                featuresLevel = item.level
            } else if let level = featuresLevel, item.level == level + 1,
                      let match = Self.featureTitle.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) {
                let letter = (title as NSString).substring(with: match.range(at: 1))
                headings.append(Heading(key: ReferenceKey(kind: .specialFeature, number: letter), item: item))
            } else if title.lowercased().hasPrefix("box "),
                      let label = ReferenceScanner.mentions(in: title).first, label.key.kind == .box, label.range.location == 0 {
                let heading = Heading(key: label.key, item: item)
                headings.append(heading)
                boxes.append((heading, outline.dropFirst(index + 1).first { $0.level <= item.level }))
            }
        }
        self.headings = headings
        self.boxes = boxes
    }

    /// Each box can have its own Chart A and Chart B. Use the heading's position as well as its page because
    /// a box can start or end midway through a page. Dotted chart labels are document-wide.
    public func key(for key: ReferenceKey, onPage pageIndex: Int, y: CGFloat?) -> ReferenceKey {
        guard key.kind == .chart, key.name == nil, key.number.count == 1, key.number.first?.isLetter == true else { return key }
        func hasStarted(_ item: OutlineItem) -> Bool {
            if item.pageIndex != pageIndex { return item.pageIndex < pageIndex }
            if let y, let point = item.point { return point.y >= y - 2 }
            return true
        }
        guard let box = boxes.last(where: { hasStarted($0.heading.item) && $0.end.map(hasStarted) != true }) else { return key }
        return ReferenceKey(kind: .chart, number: key.number, name: box.heading.key.title)
    }
}
