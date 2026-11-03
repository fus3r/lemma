import SwiftUI
import AppKit
import LemmaCore

@MainActor
extension StudyStore {
    /// Clicking a mark or selecting its text makes it available in the passage toolbar.
    var activeHighlight: StudyHighlight? {
        guard reader.showAnnotations, let book = workspace else { return nil }
        if let (page, rect, _) = reader.selection, reader.hasSelection {
            let lines = reader.view?.currentSelection?.selectionsByLine().compactMap { selection in
                document?.page(at: page).map { selection.bounds(for: $0) }
            } ?? [rect]
            return book.highlights.reversed().first { mark in
                mark.pageIndex == page && mark.regions.contains { region in lines.contains { $0.intersects(region.rect) } }
            }
        }
        return book.highlights.first { $0.id == reader.activeHighlightID }
    }

    func applyHighlightSwatch(_ swatch: HighlightSwatch, style: HighlightStyle) {
        if var mark = activeHighlight, let bookID = workspace?.id {
            mark.color = swatch.color; mark.colorHex = swatch.hex; mark.style = style
            replaceHighlight(mark, bookID: bookID, actionName: "Change \(style.label) Color")
        } else { highlightSelection(swatch: swatch, style: style) }
    }

    func editHighlightColors(add: Bool = false) {
        addHighlightColor = add; showHighlightColors = true
    }

    var highlightMenuItems: [VSMenuItem] {
        let palette = app.highlightPalette, active = activeHighlight
        let canApply = reader.hasSelection || active != nil
        func colors(_ style: HighlightStyle, defaults: Bool = false) -> [VSMenuItem] {
            palette.settings.colors.map { swatch in
                .colorAction(swatch.name, color: swatch.nativeColor,
                             checked: defaults && palette.defaultColor(for: style).id == swatch.id,
                             enabled: defaults || canApply) { [self] in
                    if defaults {
                        do { try palette.setDefault(swatch.id, for: style) }
                        catch { self.error = "Could not save the default color: \(error.localizedDescription)" }
                    } else { applyHighlightSwatch(swatch, style: style) }
                }
            }
        }
        return [
            .action(active?.style == .underline ? "Remove Underline" : "Remove Highlight", enabled: active != nil) { [self] in
                if let active { removeHighlight(id: active.id) }
            },
            .separator, .header("Highlight")
        ] + colors(.highlight) + [.separator, .header("Underline")] + colors(.underline) + [
            .separator,
            .action("Add Color…") { [self] in editHighlightColors(add: true) },
            .submenu("Default Highlight Color", colors(.highlight, defaults: true)),
            .submenu("Default Underline Color", colors(.underline, defaults: true)),
            .action("Edit Colors & Defaults…") { [self] in editHighlightColors() }
        ]
    }
}

/// The same native menu in both interface styles, always available for managing colors.
struct HighlightMenu: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme
    @State private var themes = ThemeManager.shared
    var body: some View {
        VSMenu(items: { store.highlightMenuItems }) {
            HStack(spacing: 4) {
                if themes.style == .vscode { Codicon("symbol-color", size: 16) }
                else { Image(systemName: "highlighter") }
                Text("Highlight")
                Codicon("chevron-down", size: 12)
            }
            .foregroundStyle(theme[.foreground])
            .padding(.horizontal, 6).frame(height: 22)
            .contentShape(Rectangle())
        }
        .fixedSize()
        .help("Highlight ⇧⌘H or underline ⇧⌘U. Click a mark or select its text to change or remove it; Shift-drag to resize.")
        .accessibilityLabel("Highlight and underline")
    }
}

struct HighlightColorsSheet: View {
    let store: StudyStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var draft: HighlightPalette.Settings
    @State private var error: String?

    init(store: StudyStore) {
        self.store = store
        var settings = store.app.highlightPalette.settings
        if store.addHighlightColor { settings.colors.append(.newColor()) }
        _draft = State(initialValue: settings)
        _error = State(initialValue: store.app.highlightPalette.loadError)
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkbenchSheetHeader(codicon: "symbol-color", symbol: "highlighter", title: "Highlight Colors", tabs: { EmptyView() }) {
                Button("Cancel") { dismiss() }.workbenchButton(.secondary, compact: true).keyboardShortcut(.cancelAction)
                Button("Save") {
                    do { try store.app.highlightPalette.save(draft); dismiss() }
                    catch { self.error = "Could not save the colors: \(error.localizedDescription)" }
                }.workbenchButton(.primary, compact: true).keyboardShortcut(.defaultAction)
            }
            VStack(alignment: .leading, spacing: 16) {
                Text("Use the color well for the full macOS palette, spectrum and RGB sliders. Changes apply to future marks; existing marks keep their colors.")
                    .font(.ui(12)).foregroundStyle(theme[.descriptionForeground]).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(draft.colors) { swatch in
                            let binding = swatchBinding(for: swatch)
                            HStack(spacing: 12) {
                                TextField("Color name", text: binding.name).textFieldStyle(.plain).workbenchInputBox()
                                    .accessibilityLabel("Color name: \(swatch.name)")
                                ColorPicker("Choose \(swatch.name)", selection: Binding(get: { Color(nsColor: binding.wrappedValue.nativeColor.withAlphaComponent(1)) },
                                                                                     set: { var edited = binding.wrappedValue; edited.setColor(NSColor($0)); binding.wrappedValue = edited }), supportsOpacity: false)
                                    .labelsHidden().help("Choose \(swatch.name) from the full color palette")
                                Button {
                                    draft.removeColor(id: swatch.id)
                                } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).disabled(draft.colors.count == 1)
                                    .help("Remove \(swatch.name) from the palette").accessibilityLabel("Remove color \(swatch.name)")
                            }
                        }
                    }.padding(.vertical, 2)
                }
                Button { draft.colors.append(.newColor()) } label: { Label("Add Color", systemImage: "plus") }
                    .workbenchButton(.secondary, compact: true)
                Divider()
                defaultPicker("Default highlight", selection: $draft.highlightID)
                defaultPicker("Default underline", selection: $draft.underlineID)
                if let error { Text(error).font(.ui(12)).foregroundStyle(theme[.errorForeground]).fixedSize(horizontal: false, vertical: true) }
            }.padding(20)
        }
        .font(.ui(12)).foregroundStyle(theme[.foreground]).background(theme[.editorBackground])
        .frame(width: 540, height: 500)
    }

    /// A departing row's controls can finish editing after deletion. Resolve by ID instead of a retired array index.
    private func swatchBinding(for swatch: HighlightSwatch) -> Binding<HighlightSwatch> {
        Binding(get: { draft.colors.first { $0.id == swatch.id } ?? swatch }, set: { updated in
            guard let index = draft.colors.firstIndex(where: { $0.id == swatch.id }) else { return }
            draft.colors[index] = updated
        })
    }

    private func defaultPicker(_ title: String, selection: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Picker(title, selection: selection) {
                ForEach(draft.colors) { swatch in Text(swatch.name).tag(swatch.id) }
            }.labelsHidden().frame(width: 220)
            if let swatch = draft.colors.first(where: { $0.id == selection.wrappedValue }) {
                RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: swatch.nativeColor.withAlphaComponent(1)))
                    .frame(width: 18, height: 12).overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(theme[.foreground].opacity(0.2)))
                    .accessibilityLabel(swatch.name)
            }
        }
    }
}
