import XCTest
import AppKit
import PDFKit
import SwiftUI
import LemmaCore
@testable import Lemma

final class HighlightPaletteTests: XCTestCase {
    @MainActor
    func testDeletingPaletteRowsThroughTheirTrashButtonsKeepsDefaultsAndTheLastColor() async throws {
        let fixture = try WorkbenchFixture()
        let store = fixture.store
        defer { NSColorPanel.shared.close(); store.app.prepareForTermination(); fixture.close() }
        var settings = store.app.highlightPalette.settings
        var custom = HighlightSwatch.newColor(); custom.name = "Violet"
        settings.colors.append(custom)
        settings.highlightID = custom.id; settings.underlineID = custom.id
        try store.app.highlightPalette.save(settings)
        let previousStyle = ThemeManager.shared.style
        ThemeManager.shared.style = .classic
        defer { ThemeManager.shared.style = previousStyle }
        let host = NSHostingView(rootView: HighlightColorsSheet(store: store))
        fixture.window.contentView = host
        fixture.window.orderFront(nil)
        try await fixture.settle(150)

        func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            var found = (view as? T).map { [$0] } ?? []
            for child in view.subviews { found += descendants(type, in: child) }
            return found
        }
        func center(_ view: NSView) -> CGPoint { CGPoint(x: host.convert(view.bounds, from: view).midX, y: host.convert(view.bounds, from: view).midY) }
        func wells() -> [NSColorWell] { descendants(NSColorWell.self, in: host).sorted { center($0).y < center($1).y } }
        func trash(at index: Int) throws -> NSButton {
            let well = wells()[index]
            return try XCTUnwrap(descendants(NSButton.self, in: host).filter { abs(center($0).y - center(well).y) < 2 }.max { center($0).x < center($1).x })
        }
        var names = ["Yellow", "Green", "Blue", "Rose", "Violet"]
        // Click the actual native trash buttons: the last row reproduces the crash, and the first shifts later rows.
        for name in ["Violet", "Yellow", "Rose", "Blue"] {
            let index = try XCTUnwrap(names.firstIndex(of: name))
            try trash(at: index).performClick(nil)
            names.remove(at: index)
            try await fixture.settle(80)
            XCTAssertEqual(wells().count, names.count)
        }
        XCTAssertFalse(try trash(at: 0).isEnabled, "The palette must retain one color")
        // Use Save's default shortcut: SwiftUI does not expose it as an NSButton on every macOS release.
        let save = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: fixture.window.windowNumber, context: nil,
                                                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertTrue(fixture.window.performKeyEquivalent(with: save), "Return activates Save")
        try await fixture.settle(80)
        let restored = HighlightPalette(url: store.repository.root.appendingPathComponent("HighlightColors.json"))
        XCTAssertEqual(restored.settings.colors.map(\.id), ["green"])
        XCTAssertEqual(restored.settings.colors.first?.name, "Green")
        XCTAssertEqual(restored.settings.highlightID, "green")
        XCTAssertEqual(restored.settings.underlineID, "green")
    }

    @MainActor
    func testRecorderReceivesCommandKeysBeforeMenusAndCanClearOrCancel() throws {
        let fixture = try WorkbenchFixture()
        defer { fixture.store.app.prepareForTermination(); fixture.close() }
        let control = HighlightShortcutControl(frame: CGRect(x: 20, y: 20, width: 142, height: 28))
        XCTAssertTrue(control.isAccessibilityElement())
        XCTAssertEqual(control.accessibilityRole(), .button)
        fixture.window.contentView?.addSubview(control)
        fixture.window.makeKeyAndOrderFront(nil)
        var recorded: HighlightShortcut?
        control.record = { recorded = $0; return nil }
        func event(_ key: String, code: UInt16, flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                          windowNumber: fixture.window.windowNumber, context: nil, characters: key,
                                          charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
        }
        XCTAssertTrue(control.accessibilityPerformPress())
        XCTAssertTrue(fixture.window.firstResponder === control)
        XCTAssertTrue(fixture.window.performKeyEquivalent(with: try event("b", code: 11, flags: [.command, .control])))
        XCTAssertEqual(recorded, HighlightShortcut(key: "b", modifiers: [.command, .control]))
        XCTAssertFalse(control.recording)
        control.accessibilityPerformPress()
        control.keyDown(with: try event("\u{1b}", code: 53, flags: []))
        XCTAssertEqual(recorded?.key, "b")
        control.accessibilityPerformPress()
        control.keyDown(with: try event("\u{7f}", code: 51, flags: []))
        XCTAssertNil(recorded)
    }

    @MainActor
    func testShortcutsPersistOnLegacyPalettesRejectDuplicatesAndApplyOnlyInTheReader() throws {
        let fixture = try WorkbenchFixture()
        let store = fixture.store, palette = fixture.store.app.highlightPalette
        defer { store.app.prepareForTermination(); fixture.close() }
        // The optional field must read palettes written before shortcuts existed.
        let old = Data(#"{"colors":[{"id":"yellow","name":"Yellow","color":"yellow"}],"highlightID":"yellow","underlineID":"yellow"}"#.utf8)
        let legacy = try JSONDecoder().decode(HighlightPalette.Settings.self, from: old)
        XCTAssertNil(legacy.colors.first?.shortcut)
        let shortcut = HighlightShortcut(key: "b", modifiers: [.command, .control])
        XCTAssertEqual(shortcut.label, "⌃⌘B")
        var draft = palette.settings
        draft.colors[2].shortcut = shortcut
        try palette.save(draft)
        XCTAssertEqual(HighlightPalette(url: store.repository.root.appendingPathComponent("HighlightColors.json")).settings, draft)
        draft.colors[0].shortcut = shortcut
        XCTAssertThrowsError(try palette.save(draft))
        XCTAssertNil(palette.settings.colors[0].shortcut, "A rejected draft leaves the saved palette intact")
        let menu = NSMenu(); let item = NSMenuItem(title: "Existing command", action: nil, keyEquivalent: "b")
        item.keyEquivalentModifierMask = [.command, .control]; menu.addItem(item)
        XCTAssertEqual(shortcut.conflict(in: menu), "Existing command")
        store.open(fixture.book)
        store.reader.selection = (0, CGRect(x: 40, y: 600, width: 220, height: 40), "A passage")
        store.reader.hasSelection = true
        let blue = palette.settings.colors[2]
        store.applyHighlightSwatch(blue, style: .highlight)
        XCTAssertEqual(store.workspace?.highlights.last?.color, .blue)
        let count = store.workspace?.highlights.count
        _ = try store.createWorkspaceFile(name: "Notes", kind: .text)
        store.applyHighlightSwatch(palette.settings.colors[0], style: .highlight)
        XCTAssertEqual(store.workspace?.highlights.count, count)
        XCTAssertEqual(store.workspace?.highlights.last?.color, .blue, "A file tab must not recolor a selection retained in the PDF")
    }

    @MainActor
    func testPaletteColorWellOpensTheNativeColorPanel() async throws {
        let fixture = try WorkbenchFixture()
        defer { NSColorPanel.shared.close(); fixture.store.app.prepareForTermination(); fixture.close() }
        let host = NSHostingView(rootView: HighlightColorsSheet(store: fixture.store))
        fixture.window.contentView = host
        fixture.window.orderFront(nil)
        try await fixture.settle(150)
        func findWell(_ view: NSView) -> NSColorWell? {
            if let well = view as? NSColorWell { return well }
            for child in view.subviews { if let found = findWell(child) { return found } }
            return nil
        }
        let well = try XCTUnwrap(findWell(host))
        well.performClick(nil)
        try await fixture.settle(100)
        XCTAssertTrue(NSColorPanel.shared.isVisible, "The color well opens the full native palette")
    }

    @MainActor
    func testCustomColorsDefaultsAndEditedPresetsPersistWithoutRecoloringExistingMarks() throws {
        let fixture = try WorkbenchFixture()
        let store = fixture.store, palette = fixture.store.app.highlightPalette
        defer { store.app.prepareForTermination(); fixture.close() }
        store.open(fixture.book)
        let source = try Data(contentsOf: fixture.book)
        store.reader.selection = (0, CGRect(x: 40, y: 600, width: 220, height: 40), "A passage")
        store.highlightSelection()
        let original = try XCTUnwrap(store.workspace?.highlights.first)
        var settings = palette.settings
        var purple = HighlightSwatch.newColor()
        purple.name = "Violet"; purple.setColor(NSColor(srgbRed: 0.6, green: 0.2, blue: 0.8, alpha: 1))
        settings.colors.append(purple)
        settings.colors[0].name = "Amber"
        settings.colors[0].setColor(NSColor(srgbRed: 1, green: 0.6, blue: 0.1, alpha: 1))
        settings.highlightID = purple.id; settings.underlineID = settings.colors[0].id
        try palette.save(settings)
        XCTAssertEqual(store.workspace?.highlights.first, original, "Palette edits do not change saved marks")
        store.highlightSelection()
        let custom = try XCTUnwrap(store.workspace?.highlights.last)
        XCTAssertEqual(custom.colorHex, "#9933CC")
        store.highlightSelection(style: .underline)
        XCTAssertEqual(store.workspace?.highlights.last?.colorHex, "#FF991A")
        XCTAssertEqual(store.workspace?.highlights.last?.style, .underline)
        let restored = HighlightPalette(url: store.repository.root.appendingPathComponent("HighlightColors.json"))
        XCTAssertEqual(restored.settings, palette.settings)
        XCTAssertEqual(restored.defaultColor(for: .highlight), purple)
        XCTAssertEqual(try store.repository.load(id: XCTUnwrap(store.workspace?.id))?.highlights, store.workspace?.highlights)

        let data = try JSONEncoder().encode(custom)
        XCTAssertEqual(try JSONDecoder().decode(StudyHighlight.self, from: data), custom)
        struct LegacyHighlight: Decodable { let color: HighlightColor; let style: HighlightStyle }
        let legacy = try JSONDecoder().decode(LegacyHighlight.self, from: data)
        XCTAssertEqual(legacy.color, custom.color, "The original color field remains readable by older versions")
        XCTAssertEqual(legacy.style, .highlight)
        let old = try JSONEncoder().encode(original)
        XCTAssertNil(try JSONDecoder().decode(StudyHighlight.self, from: old).colorHex)
        let rendered = try XCTUnwrap(custom.nativeColor.usingColorSpace(.sRGB))
        XCTAssertEqual(rendered.redComponent, 0.6, accuracy: 0.001)
        XCTAssertEqual(rendered.alphaComponent, 0.4, accuracy: 0.001)
        let edition = fixture.root.appendingPathComponent("My edition.pdf")
        try store.exportPersonalPDF(to: edition)
        let annotations = try XCTUnwrap(PDFDocument(url: edition)?.page(at: 0)?.annotations)
        XCTAssertTrue(annotations.contains { annotation in
            guard let rgb = annotation.color.usingColorSpace(.sRGB) else { return false }
            return abs(rgb.redComponent - 0.6) < 0.01 && abs(rgb.blueComponent - 0.8) < 0.01
        }, "The exported PDF keeps the custom color")
        XCTAssertEqual(try Data(contentsOf: fixture.book), source)
    }

    @MainActor
    func testHighlightMenuRemovesClickedMarkAndShowsSwatchesAndDefaultsWithoutASelection() throws {
        let fixture = try WorkbenchFixture()
        let store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        store.open(fixture.book)
        store.reader.selection = (0, CGRect(x: 40, y: 600, width: 220, height: 40), "A passage")
        store.highlightSelection()
        let mark = try XCTUnwrap(store.workspace?.highlights.first)
        store.reader.selection = nil; store.reader.hasSelection = false; store.reader.activeHighlightID = nil
        let unavailable = NativeMenu.make(store.highlightMenuItems)
        XCTAssertFalse(try XCTUnwrap(unavailable.item(withTitle: "Remove Highlight")).isEnabled)
        XCTAssertTrue(try XCTUnwrap(unavailable.item(withTitle: "Add Color…")).isEnabled)

        store.reader.activeHighlightID = mark.id
        let menu = NativeMenu.make(store.highlightMenuItems)
        let remove = try XCTUnwrap(menu.item(withTitle: "Remove Highlight"))
        XCTAssertTrue(remove.isEnabled)
        let colorItem = try XCTUnwrap(menu.items.first { $0.attributedTitle?.string.hasPrefix("Green") == true })
        let attributed = try XCTUnwrap(colorItem.attributedTitle)
        XCTAssertNotNil(attributed.attribute(.attachment, at: attributed.length - 1, effectiveRange: nil), "Each color has a trailing visual preview")
        let defaults = try XCTUnwrap(menu.item(withTitle: "Default Highlight Color")?.submenu)
        XCTAssertEqual(defaults.items.filter { $0.state == .on }.count, 1)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(colorItem.action), to: colorItem.target, from: colorItem))
        XCTAssertEqual(store.workspace?.highlights.count, 1)
        XCTAssertEqual(store.workspace?.highlights.first?.color, .green)
        store.pdfUndoManager.undo(); XCTAssertEqual(store.workspace?.highlights.first, mark)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(remove.action), to: remove.target, from: remove))
        XCTAssertTrue(store.workspace?.highlights.isEmpty == true)
        store.pdfUndoManager.undo(); XCTAssertEqual(store.workspace?.highlights.first, mark)
    }

}
