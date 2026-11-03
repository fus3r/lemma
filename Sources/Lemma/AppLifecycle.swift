import AppKit

/// Quitting and closing the reader window, whatever the window is doing: the session is saved and helpers stop even when
/// the window was closed before Lemma quits (a window's own `onReceive` would not be there to hear it).
///
/// Not an application delegate adaptor: with one, SwiftUI rebuilt the window's root view each time the menus were
/// recomputed (closing a tab took twice as long), so the same work is done with notifications and an Apple event handler.
@MainActor
final class AppLifecycle: NSObject {
    static let shared = AppLifecycle()
    private(set) weak var app: AppModel?
    private var observers: [NSObjectProtocol] = []

    /// Starts following the app's lifecycle for this store; called once the session is restored.
    func attach(_ app: AppModel) {
        self.app = app
        // Test processes create many stores and never quit as an app does.
        guard observers.isEmpty, NSClassFromString("XCTestCase") == nil else { return }
        // A notebook kernel, the analysis helper or an assistant's process that exits while Lemma writes to its input
        // must not end Lemma: the write fails with EPIPE instead of the process receiving SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppLifecycle.shared.app?.prepareForTermination() }
        })
        // Closing the reader window saves at once, rather than when Lemma eventually quits.
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { notification in
            let closing = (notification.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let app = AppLifecycle.shared.app,
                      let window = app.windows.compactMap(\.mainWindow).first(where: { ObjectIdentifier($0) == closing }) else { return }
                app.windowWillClose(window)
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { notification in
            let key = (notification.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let app = AppLifecycle.shared.app,
                      let window = app.windows.compactMap(\.mainWindow).first(where: { ObjectIdentifier($0) == key }) else { return }
                app.windowDidBecomeKey(window)
            }
        })
        for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
                let changed = (notification.object as? NSWindow).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let app = AppLifecycle.shared.app,
                          app.windows.contains(where: { $0.mainWindow.map(ObjectIdentifier.init) == changed }) else { return }
                    app.saveWindows()
                }
            })
        }
        // AppKit does not quit while a window shows a sheet: a quit from the Dock, another app, or a logout, restart or
        // shutdown would wait until the sheet closed (and hold up the restart). Quit events are handled here instead.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleQuit(_:reply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
    }

    @objc private func handleQuit(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) { quit() }

    /// Quits even while a sheet is shown: the sheets are dismissed first (their state in the store, then AppKit's), then
    /// Lemma quits as usual; the will-terminate notification saves and stops notebooks, questions and helpers.
    func quit(attempt: Int = 0) {
        app?.dismissSheets()
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        if attempt < 20, NSApp.windows.contains(where: { $0.attachedSheet != nil }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { self.quit(attempt: attempt + 1) } }
            return
        }
        app?.prepareForTermination()
        NSApp.terminate(nil)
    }
}
