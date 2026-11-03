import SwiftUI
import AppKit

/// An entry of a native menu built in SwiftUI code: an action, a submenu, a section title or a separator.
struct VSMenuItem {
    enum Kind { case action(@MainActor () -> Void), submenu([VSMenuItem]), separator, header }
    var title: String
    var kind: Kind
    var checked = false
    var enabled = true
    var shortcut: String? = nil
    var trailingColor: NSColor? = nil

    static func action(_ title: String, checked: Bool = false, enabled: Bool = true, shortcut: String? = nil, _ perform: @escaping @MainActor () -> Void) -> VSMenuItem {
        VSMenuItem(title: title, kind: .action(perform), checked: checked, enabled: enabled, shortcut: shortcut)
    }
    static func submenu(_ title: String, _ items: [VSMenuItem]) -> VSMenuItem { VSMenuItem(title: title, kind: .submenu(items)) }
    static func colorAction(_ title: String, color: NSColor, checked: Bool = false, enabled: Bool = true, _ perform: @escaping @MainActor () -> Void) -> VSMenuItem {
        VSMenuItem(title: title, kind: .action(perform), checked: checked, enabled: enabled, trailingColor: color)
    }
    static var separator: VSMenuItem { VSMenuItem(title: "", kind: .separator) }
    static func header(_ title: String) -> VSMenuItem { VSMenuItem(title: title, kind: .header) }
}

@MainActor
enum NativeMenu {
    static func make(_ items: [VSMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let colorWidth = max(150, items.filter { $0.trailingColor != nil }.map { ($0.title as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width + 40 }.max() ?? 150)
        for item in items {
            switch item.kind {
            case .separator: menu.addItem(.separator())
            case .header:
                if #available(macOS 14.0, *) { menu.addItem(.sectionHeader(title: item.title)) }
                else { let header = NSMenuItem(title: item.title, action: nil, keyEquivalent: ""); header.isEnabled = false; menu.addItem(header) }
            case let .submenu(children):
                let entry = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                entry.submenu = make(children)
                menu.addItem(entry)
            case let .action(perform):
                let entry = ActionMenuItem(item.title) { perform() }
                entry.state = item.checked ? .on : .off
                entry.isEnabled = item.enabled
                if let color = item.trailingColor { entry.attributedTitle = colorTitle(item.title, color: color, width: colorWidth) }
                if let shortcut = item.shortcut, let parsed = parse(shortcut) { entry.keyEquivalent = parsed.key; entry.keyEquivalentModifierMask = parsed.modifiers }
                menu.addItem(entry)
            }
        }
        return menu
    }

    /// A right-aligned swatch retains native menu highlighting, keyboard navigation and accessibility.
    private static func colorTitle(_ title: String, color: NSColor, width: CGFloat) -> NSAttributedString {
        let image = NSImage(size: NSSize(width: 20, height: 12), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
            color.withAlphaComponent(1).setFill(); path.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke(); path.lineWidth = 1; path.stroke()
            return true
        }
        let attachment = NSTextAttachment(); attachment.image = image
        attachment.bounds = CGRect(x: 0, y: -1, width: 20, height: 12)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: width)]
        let string = NSMutableAttributedString(string: title + "\t", attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: paragraph])
        string.append(NSAttributedString(attachment: attachment))
        return string
    }

    /// Where a menu opens next to its control: under it; above it (the status bar's, at the bottom of the window); or to
    /// its right, rising from its bottom (the activity bar's Manage menu), as VS Code places them.
    enum Placement { case below, above, trailingUp }

    /// Shows a menu next to `anchor` (a view behind the control that opened it), or at the pointer without one.
    static func show(_ items: [VSMenuItem], under anchor: NSView?, placement: Placement = .below) {
        let menu = make(items)
        menu.appearance = NSApp.appearance
        if let anchor, anchor.window != nil {
            menu.popUp(positioning: nil, at: location(under: anchor, placement: placement, menuHeight: menu.size.height), in: anchor)
            return
        }
        // At the pointer, in the window that received the click (a child panel's, a sheet's or the main window).
        guard let window = NSApp.currentEvent?.window ?? NSApp.keyWindow ?? NSApp.mainWindow, let content = window.contentView else { return }
        menu.popUp(positioning: nil, at: content.convert(window.mouseLocationOutsideOfEventStream, from: nil), in: content)
    }

    /// The point 2 pt below the anchor's lower left corner, in the anchor's own coordinates, flipped or not. (SwiftUI's
    /// hosting views are flipped: converting a SwiftUI frame as if they were not placed every menu mirrored around the
    /// middle of the window.)
    static func location(under anchor: NSView, placement: Placement = .below, menuHeight: CGFloat = 0) -> NSPoint {
        let bounds = anchor.bounds, flipped = anchor.isFlipped
        // `popUp(positioning: nil, at:in:)` puts the menu's top left corner at the point.
        switch placement {
        case .below: return NSPoint(x: bounds.minX, y: flipped ? bounds.maxY + 2 : bounds.minY - 2)
        case .above: return NSPoint(x: bounds.minX, y: flipped ? bounds.minY - 2 - menuHeight : bounds.maxY + 2 + menuHeight)
        case .trailingUp: return NSPoint(x: bounds.maxX + 2, y: flipped ? bounds.maxY - menuHeight : bounds.minY + menuHeight)
        }
    }

    /// “⇧⌘P” → key “p” with shift and command, for display beside the item.
    private static func parse(_ shortcut: String) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        var modifiers: NSEvent.ModifierFlags = []
        var key = ""
        for character in shortcut where character != " " {
            switch character {
            case "⌘": modifiers.insert(.command)
            case "⇧": modifiers.insert(.shift)
            case "⌥": modifiers.insert(.option)
            case "⌃": modifiers.insert(.control)
            default: key.append(character)
            }
        }
        guard key.count == 1 else { return nil }
        return (key.lowercased(), modifiers)
    }
}

/// A SwiftUI label that opens a native menu below itself, keeping the label's own colours (SwiftUI's `Menu`
/// restyles its label with the accent and drops backgrounds).
struct VSMenu<Label: View>: View {
    let items: () -> [VSMenuItem]
    var placement: NativeMenu.Placement = .below
    @ViewBuilder var label: Label
    @State private var anchor = MenuAnchor()

    var body: some View {
        label
            .contentShape(Rectangle())
            // A real view behind the label: the menu opens under it wherever the label is · scrolled, in a child
            // panel or a sheet · rather than at a frame remembered in SwiftUI's coordinates.
            .background(MenuAnchorView(anchor: anchor, placement: placement))
            .onTapGesture { NativeMenu.show(items(), under: anchor.view, placement: placement) }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { NativeMenu.show(items(), under: anchor.view, placement: placement) }
    }
}

/// Holds the view a menu opens under.
final class MenuAnchor {
    weak var view: NSView?
}

struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor
    var placement: NativeMenu.Placement = .below
    static let identifier = NSUserInterfaceItemIdentifier("lemma.menuAnchor")

    /// The view a menu opens next to, and on which side.
    final class AnchorView: NSView { var placement: NativeMenu.Placement = .below }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.identifier = Self.identifier
        view.placement = placement
        anchor.view = view
        return view
    }
    func updateNSView(_ view: AnchorView, context: Context) { view.placement = placement; anchor.view = view }
}

/// A toolbar action that opens a menu: VS Code's “More Actions…” and similar.
struct VSMenuButton: View {
    @Environment(\.theme) private var theme
    let icon: String
    var help: String = ""
    var size: CGFloat = 16
    let items: () -> [VSMenuItem]
    @State private var hovering = false
    var body: some View {
        VSMenu(items: items) {
            Codicon(icon, size: size).foregroundStyle(theme[.iconForeground])
                .frame(width: size + 6, height: size + 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? theme[.toolbarHoverBackground] : .clear))
        }
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help.isEmpty ? icon : help)
    }
}
