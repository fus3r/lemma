import SwiftUI
import AppKit
import PDFKit
import LemmaCore

/// Editors that are not a book: they open as tabs in the main group, as VS Code opens its Welcome page and Settings.
enum SpecialEditor: String, Codable, CaseIterable, Identifiable {
    case welcome, settings, shortcuts, releaseNotes
    var id: String { "special:\(rawValue)" }
    var title: String {
        switch self {
        case .welcome: "Welcome"; case .settings: "Settings"; case .shortcuts: "Keyboard Shortcuts"; case .releaseNotes: "What’s New"
        }
    }
    var icon: String {
        switch self { case .welcome: "home"; case .settings: "settings-gear"; case .shortcuts: "keyboard"; case .releaseNotes: "info" }
    }
}

/// A notification, as VS Code's toasts: a severity, a message, the source and up to two actions.
struct LemmaNotification: Identifiable {
    enum Severity { case info, warning, error
        var icon: String { switch self { case .info: "info"; case .warning: "warning"; case .error: "error" } }
        var color: TC { switch self { case .info: .notificationsInfoIconForeground; case .warning: .notificationsWarningIconForeground; case .error: .notificationsErrorIconForeground } }
    }
    struct Action { let title: String; let primary: Bool; let perform: @MainActor () -> Void }
    let id = UUID()
    var severity: Severity
    var message: String
    var source: String = "Lemma"
    var actions: [Action] = []
    var progress: Double? = nil
    var date = Date()
    /// Shown as a toast until dismissed or until it times out; it stays in the notification center either way.
    var toast = true
}

@MainActor
extension StudyStore {
    // MARK: Main editor group

    /// The id of the tab in front of the main editor group: a book's fingerprint or a special editor's id.
    var activeMainTabID: String? { activeFileName.map(Self.fileTabID) ?? activeSpecial?.id ?? workspace?.id }

    func openSpecial(_ editor: SpecialEditor) {
        palette = nil
        // The page view goes away behind the editor: keep its exact place now, or a save after it is gone would pair the
        // page reached while scrolling with the position of an earlier page.
        if activeSpecial == nil, activeFileName == nil, workspace != nil { captureViewport(); scheduleViewportSave() }
        if ThemeManager.shared.style == .classic {
            // The Classic style keeps 1.1's Settings window and sheets.
            switch editor {
            case .settings: openSettingsScene?()
            case .shortcuts: showShortcuts = true
            case .releaseNotes: showReleaseNotes = true
            case .welcome: if workspace != nil { notify("The welcome page appears when no book is open: close the book's tab (⌘W) to see it.", source: "Lemma") }
            }
            return
        }
        if !specialTabs.contains(editor) { specialTabs.append(editor) }
        activeSpecial = editor
        saveWorkbench()
    }

    func closeSpecial(_ editor: SpecialEditor) {
        guard let index = specialTabs.firstIndex(of: editor) else { return }
        specialTabs.remove(at: index)
        if activeSpecial == editor {
            if workspace != nil { activeSpecial = nil }
            else { activeSpecial = specialTabs.isEmpty ? nil : specialTabs[max(0, index - 1)] }
            if activeSpecial == nil, workspace == nil, let name = fileTabs.last { openWorkspaceFile(name) }
        }
        saveWorkbench()
    }

    func openSettingsEditor() { openSpecial(.settings) }
    func openShortcutsEditor() { openSpecial(.shortcuts) }
    func openWelcome() { openSpecial(.welcome) }
    func showThemePicker() {
        if ThemeManager.shared.style == .classic { showCustomization = true } else { showPalette(.themes) }
    }

    // MARK: Side bar panes

    func paneBinding(_ key: String, default value: Bool = true) -> Binding<Bool> {
        Binding(get: { self.paneExpanded[key] ?? value }, set: { self.paneExpanded[key] = $0 })
    }

    // MARK: Notifications

    @discardableResult
    func notify(_ message: String, severity: LemmaNotification.Severity = .info, source: String = "Lemma",
                actions: [LemmaNotification.Action] = [], timeout: Double? = 8) -> UUID {
        let notification = LemmaNotification(severity: severity, message: message, source: source, actions: actions)
        notifications.insert(notification, at: 0)
        if notifications.count > 40 { notifications.removeLast(notifications.count - 40) }
        if let timeout, severity != .error { hideToast(notification.id, after: timeout) }
        return notification.id
    }

    /// Hides a toast after a delay, but not while the pointer is on it (reaching for its button).
    private func hideToast(_ id: UUID, after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if self.hoveredToast == id { self.hideToast(id, after: 2) } else { self.hideToast(id) }
        }
    }

    func hideToast(_ id: UUID) {
        if let index = notifications.firstIndex(where: { $0.id == id }) { notifications[index].toast = false }
    }

    func dismissNotification(_ id: UUID) { notifications.removeAll { $0.id == id } }
    func clearNotifications() { notifications.removeAll() }
    /// Toasts at the bottom right, unless Settings › Notifications › Show Toasts is off (the bell keeps them all).
    var visibleToasts: [LemmaNotification] {
        guard UserDefaults.standard.object(forKey: "workbench.notifications.toasts") as? Bool ?? true else { return [] }
        return Array(notifications.filter(\.toast).prefix(3))
    }
}

@MainActor
extension StudyStore {
    /// Brings a main-group tab to the front: a book, or a special editor.
    func activateMainTab(_ id: String) {
        if let name = fileTabs.first(where: { Self.fileTabID($0) == id }) { openWorkspaceFile(name); return }
        if let special = SpecialEditor.allCases.first(where: { $0.id == id }) { openSpecial(special); return }
        activeSpecial = nil; activeFileName = nil
        if workspace?.id != id { activateTab(id) } else { saveWorkbench() }
    }

    func closeAllEditors() {
        for name in fileTabs { if !closeWorkspaceFile(name) { return } }
        for editor in sideEditors { closeSideEditor(editor.id) }
        for special in specialTabs { closeSpecial(special) }
        closeAllBooks()
    }

    /// A library PDF in the side group, including a second, independent view of the main book.
    func openBookToTheSide(_ id: String) {
        guard let book = workspace.flatMap({ $0.id == id ? $0 : nil }) ?? library.first(where: { $0.id == id }) else { return }
        guard workspace != nil else { reopen(book); return }
        activeSpecial = nil; activeFileName = nil
        if let editor = sideEditors.first(where: { if case let .page(state) = $0 { state.bookID == id } else { false } }) {
            activateSideEditor(editor.id)
            return
        }
        split = SplitEditorState(pageIndex: book.reading.pageIndex, target: nil, title: book.title, bookID: id)
    }

    /// Library rows and book tabs already carry these local drag payloads; unopened rows carry a file URL.
    @discardableResult
    func openEditorDrop(_ value: String, toSide: Bool) -> Bool {
        for prefix in ["lemma-book:", "lemma-tab:"] where value.hasPrefix(prefix) {
            let id = String(value.dropFirst(prefix.count))
            guard let book = library.first(where: { $0.id == id }) else { return false }
            if toSide { openBookToTheSide(id) } else { reopen(book) }
            return true
        }
        guard let url = URL(string: value), url.isFileURL, url.pathExtension.lowercased() == "pdf" else { return false }
        open(url, toSide: toSide)
        return true
    }

    /// The document a side editor shows: the main book, or another book of the library (loaded once, and let go when no
    /// side tab shows it any more).
    func sideDocument(for state: SplitEditorState) -> PDFDocument? {
        guard let id = state.bookID, id != workspace?.id else { return document }
        if let open = documents[id] ?? sideDocuments[id] { return open }
        guard let book = library.first(where: { $0.id == id }) else { return nil }
        var url = URL(fileURLWithPath: book.sourcePath)
        if let bookmark = book.sourceBookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale) { url = resolved }
        }
        guard let loaded = PDFDocument(url: url) else { return nil }
        // A locked PDF opens with the password given in this session, if any; otherwise it shows no pages.
        if loaded.isLocked, let password = passwords[book.fingerprint] { loaded.unlock(withPassword: password) }
        // Drawn with the page theme (Sepia, Night) like the book in front.
        loaded.delegate = ThemedPageProvider.shared
        sideDocuments[id] = loaded
        return loaded
    }
}

@MainActor
extension StudyStore {
    /// Once, after the update to 2.0: offers the colour theme the reader uses in VS Code. Reading VS Code's settings and
    /// themes waits for the window's first frame.
    func offerVSCodeTheme() {
        afterFirstFrame { [weak self] in self?.offerVSCodeThemeNow() }
    }

    private func offerVSCodeThemeNow() {
        let key = "workbench.vscodeThemeOffered"
        guard !UserDefaults.standard.bool(forKey: key), QAHooks.shared == nil || ProcessInfo.processInfo.environment["LEMMA_OFFER_THEME"] != nil else { return }
        let manager = ThemeManager.shared
        guard let label = manager.vscodeThemeLabel, manager.vscodeThemeID != manager.effectiveID else { return }
        UserDefaults.standard.set(true, forKey: key)
        let current = manager.entry(manager.effectiveID)?.label ?? "the current theme"
        notify("You use \(label) in VS Code. Use it in Lemma too?", source: "Color Theme", actions: [
            .init(title: "Use \(label)", primary: true) { [weak self] in
                do { if try manager.useVSCodeTheme() == nil { self?.notify("Lemma could not find “\(label)”.", severity: .warning, source: "Color Theme") } }
                catch { self?.notify("Could not use VS Code's theme: \(error.localizedDescription)", severity: .error, source: "Color Theme") }
            },
            .init(title: "Keep \(current)", primary: false) {}
        ], timeout: 30)
    }
}
