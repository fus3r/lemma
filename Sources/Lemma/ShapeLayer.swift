import AppKit
import PDFKit
import LemmaCore

enum DrawingTool: String, CaseIterable {
    case select, pen, rectangle, ellipse, line, arrow, eraser
    var shapeKind: PageShapeKind? { PageShapeKind(rawValue: rawValue) }
    var label: String {
        switch self { case .select: "Select"; case .pen: "Pen"; case .eraser: "Eraser"; default: shapeKind!.label }
    }
    var symbol: String {
        switch self { case .select: "cursorarrow"; case .pen: "pencil.tip"; case .eraser: "eraser"; default: shapeKind!.symbol }
    }
}

extension PageShape {
    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
    var nativeColor: NSColor { (NSColor.highlightHex(colorHex) ?? InkColor.blue.nativeColor).withAlphaComponent(1) }

    var path: CGPath {
        let path = CGMutablePath()
        switch kind {
        case .rectangle: path.addRect(rect)
        case .ellipse: path.addEllipse(in: rect)
        case .line, .arrow:
            path.move(to: CGPoint(x: start.x, y: start.y)); path.addLine(to: CGPoint(x: end.x, y: end.y))
            if kind == .arrow {
                let angle = atan2(end.y - start.y, end.x - start.x)
                let head = min(hypot(end.x - start.x, end.y - start.y) / 2, max(8, width * 4))
                for offset in [-Double.pi / 6, Double.pi / 6] {
                    path.move(to: CGPoint(x: end.x - head * cos(angle + offset), y: end.y - head * sin(angle + offset)))
                    path.addLine(to: CGPoint(x: end.x, y: end.y))
                }
            }
        }
        return path
    }

    @MainActor func annotation() -> PDFAnnotation? {
        guard isValid else { return nil }
        let padding = kind.isClosed ? width / 2 : max(10, width * 5)
        let bounds = rect.insetBy(dx: -padding, dy: -padding)
        let subtype: PDFAnnotationSubtype = kind == .rectangle ? .square : kind == .ellipse ? .circle : .line
        let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
        annotation.color = nativeColor
        annotation.userName = "Lemma · personal annotation"
        let border = PDFBorder(); border.lineWidth = width
        if dashed { border.style = .dashed; border.dashPattern = [6, 3] }
        annotation.border = border
        if kind.isClosed {
            annotation.interiorColor = fillOpacity > 0 ? nativeColor.withAlphaComponent(fillOpacity) : nil
        } else {
            annotation.startPoint = CGPoint(x: start.x - bounds.minX, y: start.y - bounds.minY)
            annotation.endPoint = CGPoint(x: end.x - bounds.minX, y: end.y - bounds.minY)
            annotation.endLineStyle = kind == .arrow ? .openArrow : .none
        }
        return annotation
    }
}

@MainActor extension ReaderController {
    var activeShape: PageShape? { activeShapeID.flatMap { id in shapes.first { $0.id == id } } }

    func selectShape(_ shape: PageShape) {
        inkMode = true; drawingTool = .select; activeShapeID = shape.id
        view?.window?.makeFirstResponder(view)
        view?.updateOverlay()
    }

    func syncShapes(_ shapes: [PageShape], in document: PDFDocument) {
        if !self.shapes.sharesStorage(with: shapes), self.shapes != shapes { self.shapes = shapes; view?.invalidateMarks() }
        if let id = activeShapeID, !shapes.contains(where: { $0.id == id }) { activeShapeID = nil }
        let visible = showAnnotations ? shapes : []
        if shapeDocument === document, appliedShapes.sharesStorage(with: visible) { return }
        if shapeDocument === document, appliedShapes == visible { appliedShapes = visible; return }
        if shapeDocument !== document {
            for annotation in shapeAnnotations.values { annotation.page?.removeAnnotation(annotation) }
            shapeAnnotations = [:]; appliedShapes = []; shapeDocument = document
        }
        let wanted = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let previous = Dictionary(appliedShapes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, shape) in previous where wanted[id] != shape {
            if let annotation = shapeAnnotations.removeValue(forKey: id) { annotation.page?.removeAnnotation(annotation) }
        }
        for shape in visible where shapeAnnotations[shape.id] == nil {
            guard let page = document.page(at: shape.pageIndex), let annotation = shape.annotation() else { continue }
            page.addAnnotation(annotation); shapeAnnotations[shape.id] = annotation
        }
        appliedShapes = visible
        view?.updateOverlay(); view?.needsDisplay = true
    }
}

struct ShapeGesture {
    enum Operation { case draw, move, start, end }
    let original: PageShape
    let origin: CGPoint
    let operation: Operation
    var preview: PageShape
}

@MainActor extension RegionPDFView {
    func shapeHit(at location: CGPoint) -> PageShape? {
        guard let controller, controller.showAnnotations, let document,
              let page = page(for: location, nearest: false) else { return nil }
        let point = convert(location, to: page), index = document.index(for: page)
        return controller.shapes.reversed().first { shape in
            shape.pageIndex == index && shape.path.copy(strokingWithWidth: max(shape.width, 10 / scaleFactor), lineCap: .round, lineJoin: .round, miterLimit: 10).contains(point)
        }
    }

    func handleShapeMouseDown(_ event: NSEvent) -> Bool {
        guard let controller, !controller.regionMode else { return false }
        let local = convert(event.locationInWindow, from: nil)
        guard let document, let page = page(for: local, nearest: false) else { return controller.inkMode }
        let point = convert(local, to: page)
        if controller.inkMode, let kind = controller.drawingTool.shapeKind {
            controller.showAnnotations = true
            window?.makeFirstResponder(self); clearSelection(); controller.activeShapeID = nil
            let shape = PageShape(pageIndex: document.index(for: page), kind: kind, start: .init(x: point.x, y: point.y), end: .init(x: point.x, y: point.y),
                                  colorHex: controller.shapeColorHex, width: controller.inkWidth, fillOpacity: controller.shapeFillOpacity, dashed: controller.shapeDashed)
            shapeGesture = ShapeGesture(original: shape, origin: point, operation: .draw, preview: shape)
            return true
        }
        if controller.inkMode, controller.drawingTool == .eraser, let hit = shapeHit(at: local) {
            controller.owner?.removeShape(id: hit.id); return true
        }
        guard !controller.inkMode || controller.drawingTool == .select else { return false }
        var operation = ShapeGesture.Operation.move
        var hit: PageShape?
        if controller.inkMode, let active = controller.activeShape, active.pageIndex == document.index(for: page) {
            if hypot(point.x - active.start.x, point.y - active.start.y) <= 7 / scaleFactor { hit = active; operation = .start }
            else if hypot(point.x - active.end.x, point.y - active.end.y) <= 7 / scaleFactor { hit = active; operation = .end }
        }
        hit = hit ?? shapeHit(at: local)
        guard let hit else {
            controller.activeShapeID = nil; updateOverlay()
            return controller.inkMode
        }
        controller.selectShape(hit); clearSelection()
        shapeGesture = ShapeGesture(original: hit, origin: point, operation: operation, preview: hit)
        return true
    }

    func updateShapeGesture(_ event: NSEvent) {
        guard var gesture = shapeGesture, let page = document?.page(at: gesture.original.pageIndex) else { return }
        let box = page.bounds(for: .cropBox)
        let raw = convert(convert(event.locationInWindow, from: nil), to: page)
        var point = CGPoint(x: min(box.maxX, max(box.minX, raw.x)), y: min(box.maxY, max(box.minY, raw.y)))
        var shape = gesture.original
        if gesture.operation == .move {
            let dx = min(box.maxX - shape.rect.maxX, max(box.minX - shape.rect.minX, point.x - gesture.origin.x))
            let dy = min(box.maxY - shape.rect.maxY, max(box.minY - shape.rect.minY, point.y - gesture.origin.y))
            shape.start.x += dx; shape.start.y += dy; shape.end.x += dx; shape.end.y += dy
        } else {
            let anchor = gesture.operation == .start ? shape.end : shape.start
            if event.modifierFlags.contains(.shift) {
                let dx = point.x - anchor.x, dy = point.y - anchor.y
                if shape.kind.isClosed {
                    let size = min(max(abs(dx), abs(dy)), dx < 0 ? anchor.x - box.minX : box.maxX - anchor.x,
                                   dy < 0 ? anchor.y - box.minY : box.maxY - anchor.y)
                    point = CGPoint(x: anchor.x + (dx < 0 ? -size : size), y: anchor.y + (dy < 0 ? -size : size))
                } else {
                    let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4), length = hypot(dx, dy)
                    point = CGPoint(x: min(box.maxX, max(box.minX, anchor.x + length * cos(angle))),
                                    y: min(box.maxY, max(box.minY, anchor.y + length * sin(angle))))
                }
            }
            if gesture.operation == .start { shape.start = .init(x: point.x, y: point.y) }
            else { shape.end = .init(x: point.x, y: point.y) }
        }
        gesture.preview = shape; shapeGesture = gesture
        if gesture.operation != .draw { controller?.shapeAnnotations[shape.id]?.shouldDisplay = false }
        selectionOverlay.updateShape(shape, in: self)
    }

    func finishShapeGesture(_ event: NSEvent) {
        updateShapeGesture(event)
        guard let gesture = shapeGesture, let controller else { return }
        cancelShapeGesture()
        guard gesture.preview.isValid else { return }
        if gesture.operation == .draw { controller.owner?.addShape(gesture.preview) }
        else if let bookID = controller.owner?.workspace?.id {
            controller.owner?.replaceShape(gesture.preview, bookID: bookID, actionName: gesture.operation == .move ? "Move Shape" : "Resize Shape")
        }
        controller.activeShapeID = gesture.preview.id
        updateOverlay()
    }

    func cancelShapeGesture() {
        if let gesture = shapeGesture { controller?.shapeAnnotations[gesture.original.id]?.shouldDisplay = true }
        shapeGesture = nil; selectionOverlay.updateShape(nil, in: self)
        needsDisplay = true
    }
}
