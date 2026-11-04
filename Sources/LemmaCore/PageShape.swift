import Foundation

public enum PageShapeKind: String, Codable, CaseIterable, Sendable {
    case rectangle, ellipse, line, arrow
    public var label: String {
        switch self { case .rectangle: "Box"; case .ellipse: "Ellipse"; case .line: "Line"; case .arrow: "Arrow" }
    }
    public var symbol: String {
        switch self { case .rectangle: "rectangle"; case .ellipse: "oval"; case .line: "line.diagonal"; case .arrow: "arrow.up.right" }
    }
    public var isClosed: Bool { self == .rectangle || self == .ellipse }
}

/// Endpoints and width use the original PDF coordinates, so zoom and page rotation do not change a saved shape.
public struct PageShape: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var pageIndex: Int
    public var kind: PageShapeKind
    public var start: InkPoint
    public var end: InkPoint
    public var colorHex: String
    public var width: Double
    public var fillOpacity: Double
    public var dashed: Bool

    public init(id: UUID = UUID(), pageIndex: Int, kind: PageShapeKind, start: InkPoint, end: InkPoint,
                colorHex: String = "#2359B0", width: Double = 1.5, fillOpacity: Double = 0, dashed: Bool = false) {
        self.id = id; self.pageIndex = pageIndex; self.kind = kind; self.start = start; self.end = end
        self.colorHex = colorHex; self.width = width; self.fillOpacity = fillOpacity; self.dashed = dashed
    }

    public var isValid: Bool {
        pageIndex >= 0 && [start.x, start.y, end.x, end.y, width, fillOpacity].allSatisfy(\.isFinite)
            && width > 0 && (0...1).contains(fillOpacity)
            && (kind.isClosed ? abs(end.x - start.x) >= 3 && abs(end.y - start.y) >= 3 : hypot(end.x - start.x, end.y - start.y) >= 3)
    }
}
