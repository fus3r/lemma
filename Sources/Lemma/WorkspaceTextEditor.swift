import AppKit
import SwiftUI

/// A real TextKit editor: native Undo, text finding and selection, with the workbench's typography and gutter.
struct WorkspaceTextEditor: NSViewRepresentable {
    @Bindable var store: StudyStore
    @Bindable var file: WorkspaceFileBuffer
    var wrapsLines: Bool
    @Environment(\.theme) private var theme

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let view = WorkspaceTextView(usingTextLayoutManager: false)
        view.isRichText = false; view.allowsUndo = true
        view.enabledTextCheckingTypes = 0
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false; view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false; view.isGrammarCheckingEnabled = false
        view.isAutomaticTextCompletionEnabled = false; view.smartInsertDeleteEnabled = false
        view.usesFindBar = true; view.isIncrementalSearchingEnabled = true
        view.isVerticallyResizable = true; view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 12, height: 14)
        view.textContainer?.lineFragmentPadding = 0
        view.string = file.text
        view.delegate = context.coordinator
        view.textStorage?.delegate = context.coordinator
        view.setAccessibilityLabel("\(file.id) editor")
        let scroll = NSScrollView()
        scroll.documentView = view; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let gutter = WorkspaceLineGutter(scrollView: scroll, orientation: .verticalRuler)
        gutter.clientView = view
        scroll.verticalRulerView = gutter; scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.textView = view; context.coordinator.gutter = gutter
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        context.coordinator.configure(scroll)
        context.coordinator.restyle()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let view = coordinator.textView else { return }
        coordinator.configure(scroll)
        if view.string != file.text {
            // Another window changed this buffer. Native text Undo stores character ranges, which no longer
            // address the same edit after replacing the string; keep it from removing the other window's text.
            view.undoManager?.removeAllActions()
            let selection = view.selectedRange()
            view.string = file.text
            view.setSelectedRange(NSRange(location: min(selection.location, (file.text as NSString).length), length: 0))
            coordinator.restyle()
        } else if coordinator.themeID != ThemeManager.shared.effectiveID {
            coordinator.restyle()
        }
        if coordinator.findRequest != file.findRequest {
            coordinator.findRequest = file.findRequest
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
                let item = NSMenuItem(); item.tag = file.findAction
                view.performFindPanelAction(item)
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: WorkspaceTextEditor
        weak var textView: WorkspaceTextView?
        weak var gutter: WorkspaceLineGutter?
        var findRequest = 0
        var themeID = ""
        private var wrapping: Bool?
        init(_ parent: WorkspaceTextEditor) { self.parent = parent }

        func configure(_ scroll: NSScrollView) {
            guard let view = textView else { return }
            let theme = ThemeManager.shared.colors
            scroll.backgroundColor = theme.ns(.editorBackground)
            view.backgroundColor = theme.ns(.editorBackground)
            view.insertionPointColor = theme.ns(.editorCursorForeground)
            view.selectedTextAttributes = [.backgroundColor: theme.ns(.editorSelectionBackground)]
            guard wrapping != parent.wrapsLines else { return }
            wrapping = parent.wrapsLines
            scroll.hasHorizontalScroller = !parent.wrapsLines
            view.isHorizontallyResizable = !parent.wrapsLines
            view.autoresizingMask = parent.wrapsLines ? [.width] : []
            view.textContainer?.widthTracksTextView = parent.wrapsLines
            view.textContainer?.containerSize = NSSize(width: parent.wrapsLines ? max(40, scroll.contentSize.width - 24) : .greatestFiniteMagnitude,
                                                      height: .greatestFiniteMagnitude)
            if parent.wrapsLines { view.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(view.frame.height, scroll.contentSize.height))) }
            gutter?.needsDisplay = true
        }

        func restyle() {
            guard let view = textView, let storage = view.textStorage else { return }
            themeID = ThemeManager.shared.effectiveID
            let theme = ThemeManager.shared.colors, font = EditorFont.nsFont(EditorFont.size + 1)
            view.font = font
            view.typingAttributes = [.font: font, .foregroundColor: theme.ns(.editorForeground)]
            storage.beginEditing()
            Self.color(storage, markdown: parent.file.isMarkdown)
            storage.endEditing()
            gutter?.lineStarts = Self.lineStarts(in: view.string)
            view.needsDisplay = true; gutter?.needsDisplay = true
        }

        static func color(_ storage: NSTextStorage, markdown: Bool) {
            let theme = ThemeManager.shared.colors, font = EditorFont.nsFont(EditorFont.size + 1)
            let range = NSRange(location: 0, length: storage.length)
            guard range.length > 0 else { return }
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
            paragraph.tabStops = []; paragraph.defaultTabInterval = ("    " as NSString).size(withAttributes: [.font: font]).width
            storage.setAttributes([.font: font, .foregroundColor: theme.ns(.editorForeground), .paragraphStyle: paragraph], range: range)
            guard markdown else { return }
            let rules: [(String, NSColor, Bool)] = [
                (#"(?m)^#{1,6}\s+.*$"#, theme.token(.control), true),
                (#"(?m)^\s*>.*$"#, theme.token(.comment), false),
                (#"\[[^\]\n]+\]\([^\)\n]+\)"#, theme.token(.function), false),
                (#"\*\*[^*\n]+\*\*"#, theme.ns(.editorForeground), true),
                (#"`[^`\n]+`"#, theme.token(.string), false),
                (#"(?m)^\s*(?:[-*+] |\d+\. )"#, theme.token(.control), false)
            ]
            for (pattern, color, bold) in rules {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                for match in regex.matches(in: storage.string, range: range) {
                    storage.addAttribute(.foregroundColor, value: color, range: match.range)
                    if bold { storage.addAttribute(.font, value: EditorFont.nsFont(EditorFont.size + 1, bold: true), range: match.range) }
                }
            }
        }

        static func lineStarts(in value: String) -> [Int] {
            let text = value as NSString
            var starts = [0], index = 0
            while index < text.length {
                let next = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
                guard next > index else { break }
                let last = text.character(at: next - 1)
                if next < text.length || [10, 13, 0x2028, 0x2029].contains(Int(last)) { starts.append(next) }
                index = next
            }
            return starts
        }

        nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            nonisolated(unsafe) let storage = textStorage
            MainActor.assumeIsolated { Self.color(storage, markdown: parent.file.isMarkdown) }
        }
        func textDidChange(_ notification: Notification) {
            guard let view = textView else { return }
            parent.store.updateWorkspaceFile(parent.file, text: view.string)
            gutter?.lineStarts = Self.lineStarts(in: view.string)
            selectionChanged()
        }
        func textViewDidChangeSelection(_ notification: Notification) { selectionChanged() }
        func textDidBeginEditing(_ notification: Notification) { selectionChanged() }
        private func selectionChanged() {
            guard let view = textView else { return }
            let range = view.selectedRange(), text = view.string as NSString
            let location = min(range.location, text.length)
            let starts = gutter?.lineStarts ?? [0]
            let line = starts.lastIndex(where: { $0 <= location }) ?? 0
            parent.file.cursorLine = line + 1
            parent.file.cursorColumn = text.substring(with: NSRange(location: starts[line], length: location - starts[line])).count + 1
            parent.file.selectedCharacters = text.substring(with: NSIntersectionRange(range, NSRange(location: 0, length: text.length))).count
            gutter?.activeLine = line
            gutter?.needsDisplay = true; view.needsDisplay = true
        }
        @objc func scrolled(_ notification: Notification) { gutter?.needsDisplay = true }
    }
}

final class WorkspaceTextView: NSTextView {
    private var requestedInitialFocus = false
    private let editingUndoManager = UndoManager()
    override var undoManager: UndoManager? { editingUndoManager }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !requestedInitialFocus else { return }
        requestedInitialFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.attachedSheet == nil else { return }
            window.makeFirstResponder(self)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        guard widthChanged else { return }
        // TextKit finishes reflow after the split view sizes its children; redraw the numbers against that layout.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let container = self.textContainer { self.layoutManager?.ensureLayout(for: container) }
            self.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard selectedRange().length == 0, let layout = layoutManager, let container = textContainer else { return }
        layout.ensureLayout(for: container)
        let position = min(selectedRange().location, (string as NSString).length)
        let fragment: NSRect
        if position == (string as NSString).length && (string.isEmpty || string.hasSuffix("\n")) { fragment = layout.extraLineFragmentRect }
        else if layout.numberOfGlyphs > 0 { fragment = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: min(position, max(0, (string as NSString).length - 1))), effectiveRange: nil) }
        else { return }
        let highlight = NSRect(x: bounds.minX, y: fragment.minY + textContainerOrigin.y, width: bounds.width, height: fragment.height)
        ThemeManager.shared.colors.ns(.editorLineHighlightBackground).setFill(); highlight.fill()
    }

    override func insertTab(_ sender: Any?) { insertText("    ", replacementRange: selectedRange()) }
    override func insertNewline(_ sender: Any?) {
        let text = string as NSString, position = selectedRange().location
        let range = text.lineRange(for: NSRange(location: position, length: 0))
        let prefix = text.substring(with: NSRange(location: range.location, length: position - range.location)).prefix { $0 == " " || $0 == "\t" }
        insertText("\n" + prefix, replacementRange: selectedRange())
    }
}

final class WorkspaceLineGutter: NSRulerView {
    var lineStarts = [0]
    var activeLine = 0
    override var requiredThickness: CGFloat { 56 }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        let theme = ThemeManager.shared.colors
        theme.ns(.editorBackground).setFill(); bounds.fill()
        guard let view = clientView as? NSTextView, let layout = view.layoutManager, let container = view.textContainer else { return }
        layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
        let glyphs = layout.glyphRange(forBoundingRect: view.visibleRect, in: container)
        func drawLine(_ line: Int, _ fragment: NSRect) {
            let point = convert(NSPoint(x: 0, y: fragment.minY + view.textContainerOrigin.y), from: view)
            let other = convert(NSPoint(x: 0, y: fragment.maxY + view.textContainerOrigin.y), from: view)
            let number = "\(line + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: EditorFont.nsFont(EditorFont.size),
                .foregroundColor: theme.ns(line == activeLine ? .editorLineNumberActiveForeground : .editorLineNumberForeground)
            ]
            let size = number.size(withAttributes: attributes)
            number.draw(at: NSPoint(x: bounds.width - 14 - size.width, y: min(point.y, other.y) + (fragment.height - size.height) / 2), withAttributes: attributes)
        }
        layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, range, _ in
            let character = layout.characterIndexForGlyph(at: range.location)
            // Only the first visual fragment of a logical line gets its number.
            if let line = self.lineStarts.firstIndex(of: character) { drawLine(line, fragment) }
        }
        if view.string.isEmpty || view.string.hasSuffix("\n") {
            let extra = layout.extraLineFragmentRect
            if extra.height > 0 { drawLine(lineStarts.count - 1, extra) }
        }
    }
}
