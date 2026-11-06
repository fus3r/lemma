import AppKit
import SwiftUI

/// A layout-aware key equivalent, using the same representation as the app's native menu commands.
struct HighlightShortcut: Codable, Equatable, Hashable {
    let key: String
    let modifiers: UInt

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key.lowercased()
        self.modifiers = modifiers.intersection([.command, .control, .option, .shift]).rawValue
    }

    init?(event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1,
              event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control),
              ![36, 48, 51, 53, 76, 117].contains(event.keyCode) else { return nil }
        self.init(key: key, modifiers: event.modifierFlags)
    }

    var flags: NSEvent.ModifierFlags { .init(rawValue: modifiers) }
    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }
    var keyEquivalent: KeyEquivalent { KeyEquivalent(key.first ?? " ") }
    var label: String {
        let special = ["\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→", " ": "Space"]
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
            + (special[key] ?? key.uppercased())
    }

    @MainActor
    func conflict(in menu: NSMenu? = NSApp.mainMenu) -> String? {
        guard let menu else { return nil }
        for item in menu.items {
            // These entries are checked against the draft palette instead, so a binding can be reassigned.
            if item.title == "Highlight Color" { continue }
            if item.keyEquivalent.lowercased() == key,
               item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift]) == flags {
                return item.title
            }
            if let found = conflict(in: item.submenu) { return found }
        }
        return nil
    }
}

/// Recording stays in the first-responder chain, so it never installs an app-wide keyboard monitor.
struct HighlightShortcutRecorder: NSViewRepresentable {
    let shortcut: HighlightShortcut?
    let colorName: String
    let record: (HighlightShortcut?) -> String?

    func makeNSView(context: Context) -> HighlightShortcutControl { HighlightShortcutControl() }
    func updateNSView(_ control: HighlightShortcutControl, context: Context) {
        control.shortcut = shortcut; control.record = record
        control.setAccessibilityLabel("Shortcut for \(colorName)")
        control.setAccessibilityValue(shortcut?.label ?? "Not assigned")
        control.toolTip = "Click, then press a combination with Command or Control. Delete clears; Escape cancels."
        control.needsDisplay = true
    }
}

final class HighlightShortcutControl: NSControl {
    var shortcut: HighlightShortcut?
    var record: ((HighlightShortcut?) -> String?)?
    private(set) var recording = false
    private var message: String?
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 142, height: 28) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) { beginRecording() }
    override func accessibilityPerformPress() -> Bool { beginRecording(); return true }
    private func beginRecording() {
        window?.makeFirstResponder(self); recording = true; message = nil; needsDisplay = true
    }
    override func resignFirstResponder() -> Bool {
        recording = false; message = nil; needsDisplay = true
        return super.resignFirstResponder()
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording { capture(event); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if recording { capture(event) }
        else if event.keyCode == 49 || event.keyCode == 36 { beginRecording() }
        else { super.keyDown(with: event) }
    }
    private func capture(_ event: NSEvent) {
        if event.keyCode == 53 { recording = false; message = nil; needsDisplay = true; return }
        if event.keyCode == 48 { window?.selectNextKeyView(self); return }
        if event.keyCode == 51 || event.keyCode == 117 {
            message = record?(nil); recording = message != nil
        } else if let value = HighlightShortcut(event: event) {
            message = record?(value); recording = message != nil
        } else { message = "Use ⌘ or ⌃" }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.colors
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        theme.ns(.inputBackground).setFill(); path.fill()
        let focused = window?.firstResponder === self
        (recording || focused ? theme.ns(.focusBorder) : theme.ns(.foreground).withAlphaComponent(0.2)).setStroke()
        path.lineWidth = recording || focused ? 1.5 : 1; path.stroke()
        let title = (message ?? (recording ? "Press shortcut…" : shortcut?.label ?? "Record shortcut")) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: shortcut != nil && !recording ? NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular) : NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: theme.ns(message == nil ? .foreground : .errorForeground)
        ]
        let size = title.size(withAttributes: attributes)
        title.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}
