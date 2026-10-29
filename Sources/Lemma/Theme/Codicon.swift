import SwiftUI
import AppKit
import CoreText

/// VS Code's icon font (Codicons, © Microsoft, CC BY 4.0), loaded from the app's resources.
enum Codicons {
    static let fontName = "codicon"

    /// Where the bundled resources live: the packaged app's Resources, or the SwiftPM bundle during development and
    /// tests. The SwiftPM bundle is looked up by hand: `Bundle.module` stops the app with a fatal error when its bundle
    /// is missing, which a copy of Lemma on another Mac must never do.
    static func resource(_ path: String) -> URL? {
        if let packaged = Bundle.main.resourceURL?.appendingPathComponent(path), FileManager.default.fileExists(atPath: packaged.path) { return packaged }
        let folders = [Bundle.main.executableURL?.deletingLastPathComponent(), Bundle(for: ResourceAnchor.self).bundleURL.deletingLastPathComponent()]
        for folder in folders.compactMap({ $0 }) {
            let candidate = folder.appendingPathComponent("Lemma_Lemma.bundle", isDirectory: true).appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
    private final class ResourceAnchor {}

    /// Name → code point, read once.
    static let mapping: [String: UInt32] = {
        guard let url = resource("Codicons/mapping.json"), let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var mapping: [String: UInt32] = [:]
        for (name, value) in object {
            if let number = value as? NSNumber { mapping[name] = number.uint32Value }
            else if let text = value as? String {
                let hex = text.lowercased().replacingOccurrences(of: "0x", with: "").replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "u+", with: "")
                if let code = UInt32(hex, radix: 16) { mapping[name] = code }
            }
        }
        return mapping
    }()

    /// Registers the font for this process; true when it can be drawn.
    static let isAvailable: Bool = {
        if NSFont(name: fontName, size: 12) != nil { return true }
        guard let url = resource("Codicons/codicon.ttf") else { return false }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return NSFont(name: fontName, size: 12) != nil && !mapping.isEmpty
    }()

    static func glyph(_ name: String) -> String? {
        guard isAvailable, let code = mapping[name], let scalar = Unicode.Scalar(code) else { return nil }
        return String(Character(scalar))
    }

    static func nsFont(_ size: CGFloat) -> NSFont? { NSFont(name: fontName, size: size) }

    /// An NSImage of a codicon, for AppKit menus and buttons.
    @MainActor static func image(_ name: String, size: CGFloat = 16, color: NSColor = .labelColor) -> NSImage? {
        guard let glyph = glyph(name), let font = nsFont(size) else {
            return fallbackSymbol[name].flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: name) }
        }
        let attributed = NSAttributedString(string: glyph, attributes: [.font: font, .foregroundColor: color])
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            attributed.draw(at: NSPoint(x: (rect.width - attributed.size().width) / 2, y: (rect.height - attributed.size().height) / 2))
            return true
        }
        image.isTemplate = true
        return image
    }

    /// SF Symbols that stand in when the font is missing (tests run without the app's resources).
    static let fallbackSymbol: [String: String] = [
        "files": "doc.on.doc", "search": "magnifyingglass", "source-control": "arrow.triangle.branch", "debug-alt": "ladybug",
        "extensions": "square.grid.2x2", "beaker": "flask", "notebook": "book", "book": "book", "library": "books.vertical",
        "list-tree": "list.bullet.indent", "symbol-class": "cube", "symbol-method": "function", "symbol-function": "function",
        "symbol-variable": "x.squareroot", "symbol-constant": "number", "symbol-numeric": "number", "symbol-key": "key",
        "references": "arrow.triangle.branch", "type-hierarchy": "point.3.connected.trianglepath.dotted", "settings-gear": "gearshape",
        "account": "person.crop.circle", "close": "xmark", "chevron-right": "chevron.right", "chevron-down": "chevron.down",
        "chevron-up": "chevron.up", "chevron-left": "chevron.left", "arrow-left": "arrow.left", "arrow-right": "arrow.right",
        "arrow-up": "arrow.up", "arrow-down": "arrow.down", "arrow-swap": "arrow.left.arrow.right",
        "ellipsis": "ellipsis", "add": "plus", "remove": "minus", "check": "checkmark", "error": "xmark.circle", "warning": "exclamationmark.triangle",
        "info": "info.circle", "question": "questionmark.circle", "bell": "bell", "bell-dot": "bell.badge", "layout-sidebar-left": "sidebar.left",
        "layout-sidebar-right": "sidebar.right", "layout-panel": "rectangle.bottomthird.inset.filled", "layout": "rectangle.3.group",
        "split-horizontal": "rectangle.split.2x1", "screen-full": "arrow.up.left.and.arrow.down.right", "bookmark": "bookmark",
        "pin": "pin", "pinned": "pin.fill", "comment": "text.bubble", "note": "note.text", "edit": "pencil", "pencil": "pencil",
        "eye": "eye", "eye-closed": "eye.slash", "play": "play.fill", "debug-start": "play.fill", "debug-stop": "stop.fill",
        "debug-pause": "pause.fill", "debug-continue": "forward.fill", "debug-step-over": "arrow.uturn.right",
        "debug-step-into": "arrow.down.to.line", "debug-step-out": "arrow.up.to.line", "debug-restart": "arrow.clockwise",
        "debug-breakpoint": "circle.fill", "circle-filled": "circle.fill", "circle-outline": "circle", "pass": "checkmark.circle",
        "pass-filled": "checkmark.circle.fill",
        "run-all": "forward.end.alt", "refresh": "arrow.clockwise", "filter": "line.3.horizontal.decrease", "collapse-all": "rectangle.compress.vertical",
        "expand-all": "rectangle.expand.vertical", "clear-all": "trash", "trash": "trash", "folder": "folder", "folder-opened": "folder",
        "new-folder": "folder.badge.plus", "new-file": "doc.badge.plus", "file-pdf": "doc.richtext", "file": "doc", "file-code": "doc.text",
        "history": "clock", "clock": "clock", "graph": "point.3.connected.trianglepath.dotted", "type-hierarchy-sub": "arrow.down.left",
        "type-hierarchy-super": "arrow.up.right", "terminal": "terminal", "output": "text.alignleft", "go-to-file": "arrow.right.square",
        "zoom-in": "plus.magnifyingglass", "zoom-out": "minus.magnifyingglass", "milestone": "flag", "lightbulb": "lightbulb",
        "sparkle": "sparkles", "copilot": "sparkles", "symbol-misc": "function", "fold": "chevron.right.square", "unfold": "chevron.down.square",
        "color-mode": "circle.lefthalf.filled", "symbol-color": "paintpalette", "keyboard": "keyboard",
        "link": "link", "link-external": "arrow.up.right.square", "cloud-download": "icloud.and.arrow.down", "desktop-download": "arrow.down.circle",
        "export": "square.and.arrow.up", "save": "square.and.arrow.down", "copy": "doc.on.doc", "quote": "quote.opening",
        "circle-large-outline": "circle", "workspace-trusted": "checkmark.shield", "remote": "chevron.left.forwardslash.chevron.right",
        "mortar-board": "graduationcap", "lightbulb-sparkle": "lightbulb", "inspect": "viewfinder", "screen-normal": "arrow.down.right.and.arrow.up.left",
        "list-unordered": "list.bullet", "list-ordered": "list.number", "map": "map", "symbol-event": "bolt", "symbol-field": "square.grid.3x3",
        "symbol-property": "wrench", "symbol-ruler": "ruler", "whole-word": "textformat", "case-sensitive": "textformat.size", "regex": "asterisk",
        "replace": "arrow.2.squarepath", "flame": "flame", "target": "scope", "sync": "arrow.triangle.2.circlepath", "lock": "lock",
        "versions": "square.stack.3d.up", "law": "scalemass", "telescope": "binoculars", "compass": "safari", "rocket": "paperplane",
        "star-full": "star.fill", "star-empty": "star", "verified-filled": "checkmark.seal.fill", "verified": "checkmark.seal",
        "issues": "exclamationmark.circle", "issue-draft": "circle.dashed", "record": "record.circle", "circle-slash": "nosign",
        "watch": "eye", "variable-group": "square.stack", "symbol-namespace": "curlybraces", "symbol-structure": "square.split.2x2",
        "symbol-interface": "rectangle.connected.to.line.below", "symbol-enum": "list.number", "symbol-text": "textformat",
        "symbol-boolean": "switch.2", "symbol-string": "quote.opening", "symbol-array": "square.stack", "symbol-snippet": "text.badge.plus",
        "text-size": "textformat.size", "word-wrap": "text.word.spacing", "preview": "eye", "open-preview": "eye", "markdown": "text.alignleft",
        "mention": "at", "hubot": "sparkles", "zap": "bolt", "wand": "wand.and.stars", "selection": "selection.pin.in.out",
        "gripper": "line.3.horizontal", "debug-step-back": "arrow.uturn.left", "debug-stackframe": "arrowtriangle.right.fill",
        "debug-stackframe-dot": "circle", "debug-rerun": "arrow.clockwise", "symbol-operator": "function", "folder-library": "books.vertical",
        "file-media": "photo", "table": "tablecells", "tasklist": "checklist", "list-selection": "text.line.first.and.arrowtriangle.forward",
        "close-all": "xmark.square", "discard": "arrow.uturn.backward", "bracket": "curlybraces", "comment-discussion": "bubble.left.and.bubble.right",
        "loading": "circle.dotted", "layout-sidebar-left-off": "sidebar.left",
        "layout-sidebar-right-off": "sidebar.right", "layout-panel-off": "rectangle.bottomhalf.inset.filled",
        "debug": "ladybug", "run": "play", "check-all": "checkmark.circle",
        "file-text": "doc.text", "inbox": "tray", "checklist": "checklist", "cloud": "cloud", "globe": "globe",
        "heart": "heart", "key": "key", "plug": "powerplug"
    ]
}

/// A codicon, sized like VS Code's (16 pt in lists and toolbars, 24 pt in the activity bar).
struct Codicon: View {
    let name: String
    var size: CGFloat = 16

    init(_ name: String, size: CGFloat = 16) { self.name = name; self.size = size }

    var body: some View {
        if ThemeManager.shared.style == .vscode, let glyph = Codicons.glyph(name) {
            Text(glyph).font(.custom(Codicons.fontName, fixedSize: size)).frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: Codicons.fallbackSymbol[name] ?? "circle").font(.system(size: size * 0.78)).frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}
