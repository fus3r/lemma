import AppKit
import PDFKit
import LemmaCore

extension InkColor {
    var nativeColor: NSColor {
        switch self {
        case .graphite: .init(srgbRed: 0.19, green: 0.19, blue: 0.19, alpha: 1)
        case .blue: .init(srgbRed: 0.14, green: 0.35, blue: 0.69, alpha: 1)
        case .red: .init(srgbRed: 0.69, green: 0.18, blue: 0.21, alpha: 1)
        case .green: .init(srgbRed: 0.20, green: 0.44, blue: 0.24, alpha: 1)
        }
    }
}

@MainActor
extension InkStroke {
    func annotation() -> PDFAnnotation? {
        guard points.count >= 2, width.isFinite, width > 0,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let minX = points.map(\.x).min(), let minY = points.map(\.y).min(),
              let maxX = points.map(\.x).max(), let maxY = points.map(\.y).max() else { return nil }
        let bounds = CGRect(x: minX - width, y: minY - width, width: maxX - minX + 2 * width, height: maxY - minY + 2 * width)
        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: points[0].x - bounds.minX, y: points[0].y - bounds.minY))
        for point in points.dropFirst() { path.line(to: CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)) }
        annotation.add(path)
        let border = PDFBorder(); border.lineWidth = width
        annotation.border = border; annotation.color = color.nativeColor
        return annotation
    }
}

@MainActor
extension StudyStore {
    func addInk(_ stroke: InkStroke, undoManager: UndoManager?, at index: Int? = nil) {
        guard let workspaceID = workspace?.id, let document, (0..<document.pageCount).contains(stroke.pageIndex),
              stroke.annotation() != nil, workspace?.inkStrokes.contains(where: { $0.id == stroke.id }) == false else { return }
        let count = workspace?.inkStrokes.count ?? 0
        let insertionIndex = min(index ?? count, count)
        workspace?.inkStrokes.insert(stroke, at: insertionIndex)
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                guard target.workspace?.id == workspaceID else { return }
                target.removeInk(id: stroke.id, undoManager: undoManager)
            }
        }
        undoManager?.setActionName("Draw Stroke")
        syncInk(); flush()
    }

    func removeInk(id: UUID, undoManager: UndoManager?) {
        guard let workspaceID = workspace?.id, let index = workspace?.inkStrokes.firstIndex(where: { $0.id == id }),
              let stroke = workspace?.inkStrokes.remove(at: index) else { return }
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                guard target.workspace?.id == workspaceID else { return }
                target.addInk(stroke, undoManager: undoManager, at: index)
            }
        }
        undoManager?.setActionName("Erase Stroke")
        syncInk(); flush()
    }

    private func syncInk() {
        guard let document else { return }
        reader.syncInk(workspace?.inkStrokes ?? [], in: document)
    }

    /// Exports a fresh copy. The reader's in-memory annotations never enter the source file.
    func exportPersonalPDF(to url: URL) throws {
        if let workspace, url.resolvingSymlinksInPath().standardizedFileURL == URL(fileURLWithPath: workspace.sourcePath).resolvingSymlinksInPath().standardizedFileURL {
            throw NSError(domain: "Lemma", code: 3, userInfo: [NSLocalizedDescriptionKey: "Choose a different filename to keep the original PDF intact."])
        }
        guard let workspace, let pdf = PDFDocument(url: URL(fileURLWithPath: workspace.sourcePath)) else { throw CocoaError(.fileReadNoSuchFile) }
        for stroke in workspace.inkStrokes {
            if let page = pdf.page(at: stroke.pageIndex), let annotation = stroke.annotation() { page.addAnnotation(annotation) }
        }
        for shape in workspace.shapes {
            if let page = pdf.page(at: shape.pageIndex), let annotation = shape.annotation() { page.addAnnotation(annotation) }
        }
        let renderer = ReaderController()
        renderer.syncHighlights(workspace.highlights, in: pdf)
        for note in workspace.notes {
            guard let page = pdf.page(at: note.anchor.pageIndex) else { continue }
            let r = note.anchor.region
            let annotation = PDFAnnotation(bounds: CGRect(x: r.x, y: r.y, width: 20, height: 20), forType: .text, withProperties: nil)
            annotation.contents = [note.title, note.body, note.explanation?.body ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
            annotation.userName = "Lemma · personal study note"
            page.addAnnotation(annotation)
        }
        guard pdf.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
    }
}
