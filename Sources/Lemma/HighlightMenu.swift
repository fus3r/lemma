import SwiftUI
import AppKit
import LemmaCore

@MainActor
extension StudyStore {
    /// Clicking a mark or selecting its text makes it available in the passage toolbar.
    var activeHighlight: StudyHighlight? {
        guard reader.showAnnotations, let book = workspace else { return nil }
        if let (page, rect, _) = reader.selection, reader.hasSelection {
            guard let pdfPage = document?.page(at: page) else { return nil }
            let raw = reader.view?.currentSelection?.selectionsByLine().map { $0.bounds(for: pdfPage) } ?? [rect]
            let lines = reader.highlightBounds(for: raw, on: pdfPage)
            return book.highlights.reversed().first { mark in
                guard mark.pageIndex == page else { return false }
                return reader.highlightBounds(for: mark, on: pdfPage).contains { region in lines.contains { $0.intersects(region) } }
            }
        }
        return book.highlights.first { $0.id == reader.activeHighlightID }
    }

    func applyHighlightSwatch(_ swatch: HighlightSwatch, style: HighlightStyle) {
        guard canApplyHighlightColor else { return }
        if var mark = activeHighlight, let bookID = workspace?.id {
            mark.color = swatch.color; mark.colorHex = swatch.hex; mark.style = style
            replaceHighlight(mark, bookID: bookID, actionName: "Change \(style.label) Color")
        } else { highlightSelection(swatch: swatch, style: style) }
    }

    var canApplyHighlightColor: Bool {
        activeFileName == nil && activeSpecial == nil && workspace != nil && reader.showAnnotations
            && (reader.hasSelection || activeHighlight != nil)
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
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(nsColor: store.app.highlightPalette.defaultColor(for: .highlight).nativeColor.withAlphaComponent(1)))
                    .frame(width: 12, height: 12)
                Text("Highlight")
                Codicon("chevron-down", size: 12)
            }
            .foregroundStyle(theme[.foreground])
            .padding(.horizontal, 6).frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .bottom) { HighlightColorPopover(store: store) { showing = false } }
        .fixedSize()
        .help("Highlight ⇧⌘H or underline ⇧⌘U. Choose a color or configure its keyboard shortcut.")
        .accessibilityLabel("Highlight and underline")
    }
}

private struct HighlightColorPopover: View {
    let store: StudyStore
    let close: () -> Void
    @Environment(\.theme) private var theme
    @State private var style: HighlightStyle = .highlight

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach([HighlightStyle.highlight, .underline], id: \.self) { value in
                    Button { style = value } label: {
                        HStack(spacing: 6) {
                            Image(systemName: value == .highlight ? "highlighter" : "underline")
                            Text(value.label)
                        }
                        .font(.ui(12, weight: style == value ? .semibold : .regular))
                        .frame(maxWidth: .infinity).frame(height: 32)
                        .background(style == value ? theme[.listActiveSelectionBackground] : .clear)
                        .foregroundStyle(theme[style == value ? .listActiveSelectionForeground : .foreground])
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(8)
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.app.highlightPalette.settings.colors) { swatch in
                        WorkbenchListRow(selected: false, action: { store.applyHighlightSwatch(swatch, style: style); close() }) {
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: swatch.nativeColor.withAlphaComponent(1)))
                                    .frame(width: 22, height: 16)
                                Text(swatch.name).font(.ui(13)).lineLimit(1)
                                Spacer(minLength: 8)
                                if let shortcut = swatch.shortcut, style == .highlight {
                                    Text(shortcut.label).font(.ui(11)).foregroundStyle(theme[.descriptionForeground])
                                }
                                if store.activeHighlight?.nativeColor == swatch.nativeColor && store.activeHighlight?.style == style {
                                    Image(systemName: "checkmark").font(.ui(11))
                                }
                            }.padding(.horizontal, 10).frame(height: 34)
                        }
                        .disabled(!store.canApplyHighlightColor)
                        .accessibilityLabel("\(style.label) with \(swatch.name)")
                    }
                }.padding(6)
            }.frame(maxHeight: 238)
            if !store.canApplyHighlightColor {
                Text("Select text on the page to apply a color.")
                    .font(.ui(11)).foregroundStyle(theme[.descriptionForeground]).padding(.bottom, 10)
            }
            Divider()
            HStack {
                if let mark = store.activeHighlight {
                    Button { store.removeHighlight(id: mark.id); close() } label: {
                        Image(systemName: "trash").frame(width: 24, height: 26)
                    }.buttonStyle(.plain).help("Remove \(mark.style.label)").accessibilityLabel("Remove \(mark.style.label)")
                }
                Button {
                    close()
                    DispatchQueue.main.async { store.editHighlightColors() }
                } label: {
                    HStack(spacing: 6) {
                        WorkbenchGlyph(codicon: "settings-gear", symbol: "slider.horizontal.3", size: 13)
                        Text("Colors & Shortcuts…")
                        Spacer()
                        WorkbenchGlyph(codicon: "chevron-right", symbol: "chevron.right", size: 12)
                    }.frame(height: 30).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }.font(.ui(12)).padding(.horizontal, 12).padding(.vertical, 4)
        }
        .frame(width: 300).fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(theme[.foreground]).background(theme[.editorWidgetBackground])
        .onAppear { style = store.activeHighlight?.style ?? .highlight }
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
            WorkbenchSheetHeader(codicon: "symbol-color", symbol: "highlighter", title: "Colors & Shortcuts", tabs: { EmptyView() }) {
                Button("Cancel") { dismiss() }.workbenchButton(.secondary, compact: true).keyboardShortcut(.cancelAction)
                Button("Save") {
                    do { try store.app.highlightPalette.save(draft); dismiss() }
                    catch { self.error = "Could not save the colors: \(error.localizedDescription)" }
                }.workbenchButton(.primary, compact: true).keyboardShortcut(.defaultAction)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Your annotation palette").font(.ui(18, weight: .semibold))
                        Text("Name your colors and highlight a selection with a single shortcut.")
                            .font(.ui(12)).foregroundStyle(theme[.descriptionForeground])
                    }
                    Spacer()
                    Button { draft.colors.append(.newColor()) } label: { Label("Add Color", systemImage: "plus") }
                        .workbenchButton(.secondary, compact: true)
                }.padding(20)
                HStack(spacing: 12) {
                    Text("Color").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Highlight shortcut").frame(width: 142, alignment: .leading)
                    Text("Default for").frame(width: 112)
                    Color.clear.frame(width: 24)
                }
                .font(.ui(11, weight: .medium)).foregroundStyle(theme[.descriptionForeground])
                .padding(.horizontal, 20).frame(height: 28).background(theme[.sideBarBackground])
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(draft.colors) { swatch in
                            let binding = swatchBinding(for: swatch)
                            HStack(spacing: 12) {
                                ColorPicker("Choose \(swatch.name)", selection: Binding(get: { Color(nsColor: binding.wrappedValue.nativeColor.withAlphaComponent(1)) },
                                                                                     set: { var edited = binding.wrappedValue; edited.setColor(NSColor($0)); binding.wrappedValue = edited }), supportsOpacity: false)
                                    .labelsHidden().frame(width: 28).help("Choose \(swatch.name) from the full color palette")
                                VStack(alignment: .leading, spacing: 3) {
                                    TextField("Color name", text: binding.name).textFieldStyle(.plain).font(.ui(13))
                                        .accessibilityLabel("Color name: \(swatch.name)")
                                    Text(swatch.hex ?? hex(of: swatch)).font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(theme[.descriptionForeground])
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                HighlightShortcutRecorder(shortcut: swatch.shortcut, colorName: swatch.name) { shortcut in
                                    if let shortcut {
                                        if let other = draft.colors.first(where: { $0.id != swatch.id && $0.shortcut == shortcut }) {
                                            error = "\(shortcut.label) is already assigned to \(other.name)."
                                            return "Already in use"
                                        }
                                        if let conflict = shortcut.conflict() {
                                            error = "\(shortcut.label) is used by “\(conflict)”. Choose another combination."
                                            return "Already in use"
                                        }
                                    }
                                    binding.wrappedValue.shortcut = shortcut; error = nil; return nil
                                }.frame(width: 142, height: 28)
                                HStack(spacing: 4) {
                                    defaultButton("Highlight", color: swatch.name, symbol: "highlighter", selected: draft.highlightID == swatch.id) { draft.highlightID = swatch.id }
                                    defaultButton("Underline", color: swatch.name, symbol: "underline", selected: draft.underlineID == swatch.id) { draft.underlineID = swatch.id }
                                }.frame(width: 112)
                                Button {
                                    draft.removeColor(id: swatch.id)
                                } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).frame(width: 24).disabled(draft.colors.count == 1)
                                    .help("Remove \(swatch.name) from the palette").accessibilityLabel("Remove color \(swatch.name)")
                            }.padding(.horizontal, 20).frame(height: 60)
                            Divider().padding(.horizontal, 20)
                        }
                    }
                }
                Divider()
                HStack(spacing: 24) {
                    preview(style: .highlight, id: draft.highlightID)
                    preview(style: .underline, id: draft.underlineID)
                    Spacer()
                    Text("Defaults\n⇧⌘H  ·  ⇧⌘U").font(.ui(11)).foregroundStyle(theme[.descriptionForeground]).multilineTextAlignment(.trailing)
                }.padding(.horizontal, 20).padding(.vertical, 16)
                if let error { Text(error).font(.ui(12)).foregroundStyle(theme[.errorForeground]).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 20).padding(.bottom, 10) }
                Text("Click a shortcut, then press keys with ⌘ or ⌃. Delete clears it. Existing annotations keep their colors.")
                    .font(.ui(11)).foregroundStyle(theme[.descriptionForeground]).padding(.horizontal, 20).padding(.bottom, 16)
            }
        }
        .font(.ui(12)).foregroundStyle(theme[.foreground]).background(theme[.editorBackground])
        .frame(width: 720, height: 540)
    }

    /// A departing row's controls can finish editing after deletion. Resolve by ID instead of a retired array index.
    private func swatchBinding(for swatch: HighlightSwatch) -> Binding<HighlightSwatch> {
        Binding(get: { draft.colors.first { $0.id == swatch.id } ?? swatch }, set: { updated in
            guard let index = draft.colors.firstIndex(where: { $0.id == swatch.id }) else { return }
            draft.colors[index] = updated
        })
    }

    private func defaultButton(_ title: String, color: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.ui(13)).frame(width: 46, height: 28)
                .foregroundStyle(theme[selected ? .listActiveSelectionForeground : .descriptionForeground])
                .background(selected ? theme[.listActiveSelectionBackground] : theme[.inputBackground], in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? theme[.focusBorder] : .clear))
        }.buttonStyle(.plain).help("Use \(color) as default \(title.lowercased()) color")
            .accessibilityLabel("\(color): default \(title.lowercased()) color").accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func preview(style: HighlightStyle, id: String) -> some View {
        let swatch = draft.colors.first { $0.id == id } ?? draft.colors[0]
        return VStack(alignment: .leading, spacing: 7) {
            Text("Default \(style.label.lowercased())").font(.ui(11)).foregroundStyle(theme[.descriptionForeground])
            Text("A passage worth keeping.").font(.system(size: 13, design: .serif))
                .underline(style == .underline, color: Color(nsColor: swatch.nativeColor.withAlphaComponent(1)))
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(style == .highlight ? Color(nsColor: swatch.nativeColor.withAlphaComponent(0.32)) : .clear)
        }
    }

    private func hex(of swatch: HighlightSwatch) -> String {
        var copy = swatch; copy.setColor(swatch.nativeColor); return copy.hex ?? ""
    }
}
