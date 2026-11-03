import AppKit
import CoreGraphics
import LemmaCore

/// Counts reading time on the page in view while the reader window is in front and the reader is active
/// (some input in the last 90 seconds). Time is buffered and written into the workspace's reading log every
/// five minutes, when Lemma goes to the background and whenever the book is saved anyway, so neither the
/// interface nor the disk hears of it every few seconds. The timer itself runs only while the reader could be
/// reading: Lemma in front, its window visible, the screen awake.
@MainActor
final class ReadingTracker {
    private weak var store: StudyStore?
    private var timer: Timer?
    var lastTick = Date.now
    private var pending: [Int: Double] = [:]
    private var pendingWorkspaceID: String?
    private var lastCommit = Date.now
    /// A book is open (`start`), so time may be counted.
    private var counting = false
    private var asleep = false
    private let observers = NotificationTokens()
    static let tickInterval: TimeInterval = 5
    static let idleLimit: TimeInterval = 90
    static let commitInterval: TimeInterval = 300
    /// Replaces the system's idle time, for tests.
    var idleSeconds: () -> TimeInterval = {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
    var isReaderInFront: () -> Bool = { NSApp.isActive }

    init(store: StudyStore) {
        self.store = store
        let center = NotificationCenter.default, system = NSWorkspace.shared.notificationCenter
        let update: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.updateTimer() } }
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            observers.add(center, center.addObserver(forName: name, object: nil, queue: .main, using: update))
        }
        // Time read so far is written into the book when Lemma goes to the background.
        observers.add(center, center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTimer(); self?.commit() }
        })
        for (name, sleeping) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.willSleepNotification, true),
                                 (NSWorkspace.screensDidWakeNotification, false), (NSWorkspace.didWakeNotification, false)] {
            observers.add(system, system.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.asleep = sleeping; self?.updateTimer() }
            })
        }
    }

    func start() { counting = true; updateTimer() }

    /// Side-by-side windows count reading only for the workbench in front.
    func frontChanged() {
        updateTimer()
        if store?.app.front !== store { commit() }
    }

    func stop() { counting = false; updateTimer(); commit() }

    /// Whether the timer runs: a book open, Lemma in front, its window visible and the screen awake.
    var isTiming: Bool { timer != nil }

    private func updateTimer() {
        let window = store?.mainWindow
        let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? true
        let wanted = counting && !asleep && visible && isReaderInFront() && store?.app.front === store
        if wanted, timer == nil {
            // The time away is not reading time.
            lastTick = .now
            let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !wanted, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    var hasPending: Bool { !pending.isEmpty }

    /// Buffered seconds for a book, not yet written to its log.
    func pendingSeconds(for workspaceID: String) -> Double {
        pendingWorkspaceID == workspaceID ? pending.values.reduce(0, +) : 0
    }

    func tick(now: Date = .now) {
        let elapsed = min(now.timeIntervalSince(lastTick), Self.tickInterval * 2)
        lastTick = now
        // The book was closed: nothing to count until another opens (`start`).
        if let store, store.workspace == nil, timer != nil { counting = false; updateTimer(); return }
        guard let store, store.activeFileName == nil, let workspace = store.workspace, store.document != nil, elapsed > 0,
              isReaderInFront(), store.app.front === store, store.mainWindow?.isVisible != false, store.mainWindow?.isMiniaturized != true,
              idleSeconds() < Self.idleLimit else { return }
        if pendingWorkspaceID != workspace.id { commit(); pendingWorkspaceID = workspace.id }
        pending[store.reader.focusPageIndex, default: 0] += elapsed
        if now.timeIntervalSince(lastCommit) >= Self.commitInterval { commit(now: now) }
    }

    /// Writes buffered time into the open workspace (or the book it was recorded for) and saves.
    func commit(now: Date = .now, save: Bool = true) {
        lastCommit = now
        guard let store, let id = pendingWorkspaceID, !pending.isEmpty else { return }
        let recorded = pending
        pending = [:]
        if store.workspace?.id == id {
            for (page, seconds) in recorded { store.workspace?.readingLog.record(seconds, onPage: page, at: now) }
            if save { store.scheduleSave() }
        } else if var stored = try? store.repository.load(id: id) {
            for (page, seconds) in recorded { stored.readingLog.record(seconds, onPage: page, at: now) }
            try? store.repository.save(stored)
        }
    }

    /// Seconds recorded for a page, including time not yet committed.
    func seconds(onPage pageIndex: Int) -> Double {
        guard let store, let workspace = store.workspace else { return 0 }
        return workspace.readingLog.seconds(onPage: pageIndex) + (pendingWorkspaceID == workspace.id ? pending[pageIndex] ?? 0 : 0)
    }
}

/// Notification observers removed with their owner.
final class NotificationTokens: @unchecked Sendable {
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    func add(_ center: NotificationCenter, _ token: NSObjectProtocol) { tokens.append((center, token)) }
    deinit { for (center, token) in tokens { center.removeObserver(token) } }
}
