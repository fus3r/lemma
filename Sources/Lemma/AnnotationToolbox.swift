import SwiftUI
import AppKit
import Combine
import LemmaCore

/// Shared by the VS Code and Classic readers. Tools and the current tool's settings stay visible above the page.
struct AnnotationToolbox: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme
    @State private var undoRevision = 0

    var body: some View {
        let _ = undoRevision
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(DrawingTool.allCases, id: \.self) { tool in
                    Button { store.reader.drawingTool = tool } label: {
                        Image(systemName: tool.symbol).font(.system(size: 13))
                            .frame(width: 27, height: 26)
                            .foregroundStyle(store.reader.drawingTool == tool ? theme[.buttonForeground] : theme[.iconForeground])
                            .background(store.reader.drawingTool == tool ? theme[.buttonBackground] : Color.clear, in: RoundedRectangle(cornerRadius: 3))
                    }
                    .help(help(for: tool))
                    .accessibilityLabel(tool.label)
                    .accessibilityAddTraits(store.reader.drawingTool == tool ? .isSelected : [])
                    .accessibilityIdentifier("annotation.tool.\(tool.rawValue)")
                }
                Spacer(minLength: 2)
                Button("Done") { store.reader.inkMode = false }
                    .help("Return to reading · Escape")
                    .accessibilityIdentifier("annotation.done")
            }
            HStack(spacing: 8) {
                settings
                Spacer(minLength: 0)
                Button { store.pdfUndoManager.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!store.pdfUndoManager.canUndo).help("Undo · ⌘Z").accessibilityLabel("Undo annotation")
                    .accessibilityIdentifier("annotation.undo")
                Button { store.pdfUndoManager.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!store.pdfUndoManager.canRedo).help("Redo · ⇧⌘Z").accessibilityLabel("Redo annotation")
                    .accessibilityIdentifier("annotation.redo")
                Button(role: .destructive) {
                    if let id = store.reader.activeShapeID { store.removeShape(id: id) }
                } label: { Image(systemName: "trash") }
                    .disabled(store.reader.activeShape == nil)
                    .help("Delete the selected shape · Delete").accessibilityLabel("Delete selected shape")
                    .accessibilityIdentifier("annotation.delete")
            }
            .frame(height: 28)
        }
        .font(.ui(12)).buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 3)
        .foregroundStyle(theme[.editorForeground])
        .background(theme[.breadcrumbBackground])
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border(.editorGroupBorder)).frame(height: 1) }
        .accessibilityElement(children: .contain).accessibilityLabel("PDF annotation toolbox")
        // UndoManager changes its final availability after the annotation mutation has already redrawn this view.
        .onReceive(Publishers.MergeMany([
            NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange),
            NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange),
            NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup)
        ]).receive(on: RunLoop.main)) { notification in
            guard let manager = notification.object as? UndoManager, manager === store.pdfUndoManager else { return }
            undoRevision &+= 1
        }
    }

    @ViewBuilder private var settings: some View {
        let reader = store.reader
        if reader.drawingTool == .eraser {
            Text("Click a stroke or shape to erase").foregroundStyle(theme[.descriptionForeground]).lineLimit(1)
        } else if reader.drawingTool == .select && reader.activeShape == nil {
            Text("Click a shape to move or resize it").foregroundStyle(theme[.descriptionForeground]).lineLimit(1)
        } else {
            if reader.drawingTool == .pen {
                VSMenu(items: {
                    InkColor.allCases.map { color in
                        .colorAction(color.label, color: color.nativeColor, checked: reader.inkColor == color) { reader.inkColor = color }
                    }
                }) {
                    HStack(spacing: 4) {
                        Circle().fill(Color(nsColor: reader.inkColor.nativeColor)).frame(width: 12, height: 12)
                        Text(reader.inkColor.label)
                    }
                }.accessibilityElement(children: .combine).help("Pen color").accessibilityLabel("Pen color")
            } else {
                ColorPicker("Shape color", selection: Binding(get: {
                    Color(nsColor: reader.activeShape?.nativeColor ?? (NSColor.highlightHex(reader.shapeColorHex) ?? InkColor.blue.nativeColor).withAlphaComponent(1))
                }, set: { color in
                    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                    let hex = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
                    reader.shapeColorHex = hex; editSelected { $0.colorHex = hex }
                }), supportsOpacity: false).labelsHidden().fixedSize().help("Shape color")
            }
            VSMenu(items: {
                [0.75, 1.5, 3.0, 5.0].map { value in
                    .action("\(value.formatted()) pt", checked: width == value) {
                        reader.inkWidth = value; editSelected { $0.width = value }
                    }
                }
            }) {
                HStack(spacing: 3) { Text("\(width.formatted()) pt"); Image(systemName: "chevron.down").font(.system(size: 8)) }
            }.accessibilityElement(children: .combine).help("Line width").accessibilityLabel("Line width")
            if reader.drawingTool != .pen {
                VSMenu(items: {
                    let shape = reader.activeShape
                    var items: [VSMenuItem] = [
                        .action("Solid", checked: !(shape?.dashed ?? reader.shapeDashed)) { reader.shapeDashed = false; editSelected { $0.dashed = false } },
                        .action("Dashed", checked: shape?.dashed ?? reader.shapeDashed) { reader.shapeDashed = true; editSelected { $0.dashed = true } }
                    ]
                    if (shape?.kind ?? reader.drawingTool.shapeKind)?.isClosed == true {
                        items += [.separator, .header("Fill")]
                        for (label, value) in [("No Fill", 0.0), ("Light Fill · 15%", 0.15), ("Medium Fill · 30%", 0.3)] {
                            items.append(.action(label, checked: (shape?.fillOpacity ?? reader.shapeFillOpacity) == value) {
                                reader.shapeFillOpacity = value; editSelected { $0.fillOpacity = value }
                            })
                        }
                    }
                    return items
                }) {
                    HStack(spacing: 3) { Text("Style"); Image(systemName: "chevron.down").font(.system(size: 8)) }
                }.accessibilityElement(children: .combine).help("Solid or dashed outline and translucent fill").accessibilityLabel("Shape style")
            }
        }
    }

    private var width: Double { store.reader.activeShape?.width ?? store.reader.inkWidth }
    private func editSelected(_ change: (inout PageShape) -> Void) {
        guard var shape = store.reader.activeShape, let bookID = store.workspace?.id else { return }
        change(&shape); store.replaceShape(shape, bookID: bookID, actionName: "Change Shape Style")
    }
    private func help(for tool: DrawingTool) -> String {
        switch tool {
        case .select: "Select a shape, drag its outline to move it, or drag either handle to resize"
        case .pen: "Draw freehand on the page"
        case .eraser: "Erase a stroke or shape · Undo with ⌘Z"
        case .rectangle: "Draw a box · hold Shift for a square"
        case .ellipse: "Draw an ellipse · hold Shift for a circle"
        case .line: "Draw a line · hold Shift to snap its direction"
        case .arrow: "Draw an arrow · hold Shift to snap its direction"
        }
    }
}
