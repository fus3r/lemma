import AppKit
import ImageIO
@preconcurrency import ScreenCaptureKit
import LemmaCore

/// Development hooks for visual review, enabled only when Lemma is launched with LEMMA_QA_DIR set.
/// Another local process posts `com.lemma.qa` distributed notifications (`com.lemma.qa.<channel>` when
/// LEMMA_QA_CHANNEL is set); Lemma answers by writing
/// snapshots of its own windows (no screen-recording permission is involved) and state files into that directory.
/// Each request names its output; `<name>.done` appears when the request has been handled.
@MainActor
final class QAHooks: NSObject {
    static private(set) var shared: QAHooks?
    /// The video being recorded (videoStart … videoStop).
    static var recorder: QAVideoRecorder?
    let directory: URL
    weak var store: StudyStore?

    /// The shipping app (bundle `com.lemma.app`) never listens, whatever its environment: only re-identified QA copies
    /// (`com.lemma.app.qa…`) and unbundled development runs do, so no other process can drive a user's Lemma.
    static var isAllowed: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return true }
        return id.hasPrefix("com.lemma.app.qa") || !id.hasPrefix("com.lemma.app")
    }

    /// A QA copy launched with LEMMA_QA_BACKGROUND=1 never activates itself: typing in the reader's own apps must not
    /// land in its fields.
    static var startsInBackground: Bool {
        isAllowed && ProcessInfo.processInfo.environment["LEMMA_QA_BACKGROUND"] == "1"
    }

    static func installIfRequested(store: StudyStore) {
        guard shared == nil, isAllowed, let path = ProcessInfo.processInfo.environment["LEMMA_QA_DIR"], !path.isEmpty else { return }
        let hooks = QAHooks(directory: URL(fileURLWithPath: path, isDirectory: true), store: store)
        // Two QA copies running at once each listen on their own channel.
        let channel = ProcessInfo.processInfo.environment["LEMMA_QA_CHANNEL"].map { "com.lemma.qa.\($0)" } ?? "com.lemma.qa"
        DistributedNotificationCenter.default().addObserver(hooks, selector: #selector(received(_:)), name: Notification.Name(channel),
                                                            object: nil, suspensionBehavior: .deliverImmediately)
        shared = hooks
    }

    private init(directory: URL, store: StudyStore) {
        self.directory = directory; self.store = store
        super.init()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @objc private func received(_ notification: Notification) {
        let info = (notification.userInfo as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        // Several QA copies can run at once: a request naming another copy's QA folder is not for this one.
        if let target = info["qaDir"], URL(fileURLWithPath: target).standardizedFileURL.path != directory.standardizedFileURL.path { return }
        let name = info["name"] ?? UUID().uuidString
        Task { @MainActor in
            var message = "ok"
            do { try await handle(info["action"] ?? "", info: info, name: name) } catch { message = "error: \(error.localizedDescription)" }
            try? message.write(to: directory.appendingPathComponent("\(name).done"), atomically: true, encoding: .utf8)
        }
    }

    private func handle(_ action: String, info: [String: String], name: String) async throws {
        guard let store else { return }
        switch action {
        case "snapshot": try await snapshot(to: directory.appendingPathComponent("\(name).png"))
        case "videoStart":
            // fps= (60): a video of this app's windows into <name>.mov until videoStop (see QAVideoRecorder).
            let recorder = QAVideoRecorder()
            try await recorder.start(url: directory.appendingPathComponent("\(name).mov"), fps: Int(info["fps"] ?? "") ?? 60)
            QAHooks.recorder = recorder
        case "videoStop":
            // Writes <name>.json: the wall-clock time of the video's first frame and the number of frames.
            guard let recorder = QAHooks.recorder else { throw QAError.missing("video being recorded") }
            QAHooks.recorder = nil
            let result = try await recorder.stop()
            let summary: [String: Any] = ["firstFrameWall": result.firstFrameWall, "frames": result.frames]
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted]).write(to: directory.appendingPathComponent("\(name).json"))
        case "record":
            // seconds= fps=: frames into <name>/ (see record(to:seconds:fps:)).
            try await record(to: directory.appendingPathComponent(name, isDirectory: true), seconds: Double(info["seconds"] ?? "") ?? 10, fps: Double(info["fps"] ?? "") ?? 15)
        case "state":
            let data = try JSONSerialization.data(withJSONObject: store.qaState(), options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("\(name).json"))
        // Updates (a QA copy launched with LEMMA_QA_UPDATES=1): check quietly, download without asking, report.
        case "updateCheck": Updates.shared.checkInBackground()
        case "updateAuto": Updates.shared.automaticallyDownloads = info["value"] != "0"
        case "updateState":
            let state: [String: Any] = ["available": Updates.shared.isAvailable, "event": Updates.shared.lastEvent,
                                        "version": LemmaLinks.version, "canCheck": Updates.shared.canCheck]
            try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: directory.appendingPathComponent("\(name).json"))
        case "open":
            guard let path = info["path"] else { throw QAError.missing("path") }
            store.open(URL(fileURLWithPath: path))
            if let page = info["page"].flatMap(Int.init) { try await Task.sleep(for: .milliseconds(300)); store.reader.goToPage(page) }
        case let action where action.hasPrefix("tutorial"):
            TutorialCenter.shared.performQA(action, info: info, store: store)
        default:
            try await store.performQA(action, info: info)
        }
        try await Task.sleep(for: .milliseconds(Int(info["settle"] ?? "") ?? 0))
    }

    /// Captures every visible Lemma window composited as on screen: the main window with its popovers, sheets and menus.
    func snapshot(to url: URL) async throws {
        let image = try await captureWindows()
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw QAError.missing("image") }
        try png.write(to: url, options: .atomic)
    }

    /// Frames of Lemma's windows for a demo video, `seconds` long at about `fps` frames a second, written as JPEG into
    /// `folder` with the time of each frame in times.txt. Other QA actions run meanwhile, between two frames.
    func record(to folder: URL, seconds: Double, fps: Double) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let start = Date.now
        var times: [String] = []
        var index = 0
        while Date.now.timeIntervalSince(start) < seconds {
            let taken = Date.now
            // A frame that cannot be taken (a window appearing or closing at that moment) is skipped.
            guard let image = try? await captureWindows() else { try await Task.sleep(for: .milliseconds(20)); continue }
            let url = folder.appendingPathComponent(String(format: "%05d.jpg", index))
            // Encoded off the main thread, so the actions being recorded keep their pace.
            Task.detached(priority: .utility) {
                guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.93] as CFDictionary)
                CGImageDestinationFinalize(destination)
            }
            times.append(String(format: "%05d %.3f", index, taken.timeIntervalSince(start)))
            index += 1
            let spent = Date.now.timeIntervalSince(taken)
            if spent < 1 / fps { try await Task.sleep(for: .seconds(1 / fps - spent)) }
        }
        try await Task.sleep(for: .milliseconds(500))
        try times.joined(separator: "\n").write(to: folder.appendingPathComponent("times.txt"), atomically: true, encoding: .utf8)
    }

    private func captureWindows() async throws -> CGImage {
        let content = try await SCShareableContent.currentProcess
        // Tiny windows (macOS's text insertion indicator beside a focused field) would otherwise be all that is captured.
        let windows = content.windows.filter { $0.isOnScreen && $0.windowLayer >= 0 && $0.windowLayer != 24 && $0.frame.width > 40 && $0.frame.height > 40 }
        guard !windows.isEmpty else {
            // The window is on another Space or hidden: capture it on its own, without bringing Lemma forward.
            guard let main = content.windows.filter({ $0.windowLayer == 0 && $0.frame.width > 400 }).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                throw QAError.missing("window")
            }
            let configuration = SCStreamConfiguration()
            let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
            configuration.width = Int(main.frame.width * scale); configuration.height = Int(main.frame.height * scale)
            configuration.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: main), configuration: configuration)
        }
        let union = windows.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        guard let display = content.displays.first(where: { $0.frame.intersects(union) }) ?? content.displays.first else { throw QAError.missing("display") }
        let rect = union.intersection(display.frame)
        let scale = NSScreen.screens.first { $0.frame.width == display.frame.width }?.backingScaleFactor ?? 2
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(x: rect.minX - display.frame.minX, y: rect.minY - display.frame.minY, width: rect.width, height: rect.height)
        configuration.width = Int(rect.width * scale); configuration.height = Int(rect.height * scale)
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, including: windows), configuration: configuration)
    }

    enum QAError: LocalizedError {
        case missing(String)
        var errorDescription: String? { if case let .missing(what) = self { "Missing \(what)" } else { nil } }
    }
}

@MainActor
extension StudyStore {
    /// A summary of the visible state for automated checks.
    func qaState() -> [String: Any] {
        var state: [String: Any] = [
            "page": reader.pageNumber, "pageCount": reader.pageCount, "scale": reader.scale,
            "hasSelection": reader.hasSelection, "showLibrary": showLibrary, "showStudy": showStudy, "focusMode": focusMode,
            "studySection": studySection.rawValue, "status": status, "notes": workspace?.notes.count ?? 0
        ]
        state["workspace"] = workspace?.title
        state["layout"] = workspace?.reading.layout?.rawValue
        state["displayMode"] = reader.view?.displayMode.rawValue
        state["libraries"] = libraries.collections.map { collection in
            ["id": collection.id, "title": collection.displayTitle, "count": libraries.entries.filter { $0.collectionID == collection.id }.count] as [String: Any]
        }
        state["libraryIssues"] = libraries.issues
        state["libraryPDFCount"] = libraryPDFCount
        state["arxivResults"] = arxivResults.map { ["id": $0.id, "title": $0.title] }
        state["arxivSearching"] = arxivSearching
        state["arxivSearchError"] = arxivSearchError
        state["referencePeek"] = referencePeek?.mention.key.title
        // Peeks kept open beside the reader's work: their reference and screen frame (bottom-left origin).
        state["keptPeeks"] = (reader.view?.keptReferencePeeks ?? []).filter(\.isShown).map { peek -> [String: Any] in
            let frame = peek.panel.frame ?? peek.popover.contentViewController?.view.window?.frame ?? .zero
            return ["reference": peek.key.title, "frame": [frame.minX, frame.minY, frame.width, frame.height].map(Double.init)]
        }
        func resizeArea(in view: NSView) -> PeekResizeAreaView? {
            (view as? PeekResizeAreaView) ?? view.subviews.lazy.compactMap { resizeArea(in: $0) }.first
        }
        if let area = NSApp.windows.lazy.filter(\.isVisible).compactMap({ $0.contentView?.superview.flatMap { resizeArea(in: $0) } }).first,
           let window = area.window {
            // Screen rects (bottom-left origin) where the pointer catches the open peek's edges.
            state["peekEdges"] = area.edges.reduce(into: [String: [Double]]()) {
                let rect = window.convertToScreen(area.convert(area.rects(of: $1).reduce(CGRect.null) { $0.union($1) }, to: nil))
                $0["\($1)"] = [rect.minX, rect.minY, rect.width, rect.height].map(Double.init)
            }
        }
        state["tabs"] = tabs.map(\.title)
        state["navigator"] = navigatorSection.rawValue
        state["panel"] = showPanel ? panelTab.rawValue : nil
        state["split"] = split?.title
        let find = FindController.shared
        state["find"] = ["visible": find.isVisible, "query": find.query, "searched": reader.hasSearched, "results": reader.searchResults.count] as [String: Any]
        state["breadcrumb"] = breadcrumb().map(\.title)
        state["printedPage"] = printedLabel(for: reader.pageNumber - 1)
        state["analysis"] = analysis?.analysis.map { ["definitions": $0.definitions.count, "index": $0.index.count, "bibliography": $0.bibliography.count, "citations": $0.citations.count] }
        state["analyzing"] = analysis?.progress.map { "\($0.done)/\($0.total)" }
        // The current page's rectangle in global screen coordinates (top-left origin), for posting real clicks.
        if let view = reader.view, let window = view.window, let page = view.currentPage, let screen = window.screen ?? NSScreen.screens.first {
            let rect = window.convertToScreen(view.convert(view.convert(page.bounds(for: .cropBox), from: page), to: nil))
            let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
            state["pageScreenRect"] = [rect.minX, top - rect.maxY, rect.width, rect.height]
            state["notesOnPage"] = workspace?.notes.filter { $0.anchor.pageIndex == reader.pageNumber - 1 }.map { "\($0.kind.rawValue):\($0.title)" }
            // Visible reference mentions with their centres in screen coordinates (top-left origin), for real hover and clicks.
            var mentions: [[String: Any]] = []
            for visible in view.visiblePages {
                guard let document = view.document else { break }
                let index = document.index(for: visible)
                for mention in references?.mentions(onPage: index) ?? [] where !mention.isDefinition {
                    guard let first = mention.rects.first else { continue }
                    let local = view.convert(first, from: visible)
                    guard view.bounds.contains(CGPoint(x: local.midX, y: local.midY)) else { continue }
                    let screenRect = window.convertToScreen(view.convert(local, to: nil))
                    mentions.append(["title": mention.key.title, "x": screenRect.midX, "y": top - screenRect.midY])
                }
            }
            state["mentions"] = mentions
        }
        state["marginEditor"] = reader.view?.marginNotePopover?.popover.isShown == true
        if let id = openLabID, let notebook = lab(id) {
            let session = lab.sessions[id]
            let kernel: [String: Any] = ["pid": session?.kernel?.processIdentifier ?? 0, "message": session?.message ?? ""]
            state["labKernel"] = kernel
            state["lab"] = ["title": notebook.title, "cells": notebook.cells.count, "kernel": lab.sessions[id]?.state.label ?? "none",
                            "sources": notebook.cells.map { String($0.source.prefix(80)) },
                            "outputs": notebook.cells.map { $0.outputs.map { "\($0.kind.rawValue):\($0.text.prefix(60))" } }]
        }
        state["labPython"] = ["interpreter": lab.interpreter?.path ?? "", "preferred": lab.preferredPath, "problem": lab.interpreterProblem ?? "",
                              "kernels": lab.sessions.values.compactMap { $0.kernel?.processIdentifier }]
        state["mathWebViewsIdle"] = MathWebViews.shared.idleCount
        state["labInterpreters"] = lab.interpreters.map { "\($0.path) \($0.version)" }
        state["labSetupBases"] = lab.setup.bases.map { "\($0.path) \($0.version)" }
        state["labSetup"] = ["phase": "\(lab.setup.phase)", "fraction": lab.setup.progress.fraction, "detail": lab.setup.progress.detail,
                             "failure": lab.setup.failure ?? "", "window": LabPythonSetupWindow.isVisible]
        state["readingLog"] = workspace.map { ["pages": $0.readingLog.pageSeconds.count, "total": $0.readingLog.totalSeconds] }
        state["hoverPreview"] = reader.view?.hoverPreview.isShown == true
        state["structure"] = analysis?.analysis.map { ["statements": $0.structure.statements.count, "proofs": $0.structure.proofs.count,
                                                       "edges": $0.structure.edges.count, "symbols": $0.symbols.count, "headings": $0.headings.count] }
        state["foldedProofs"] = workspace?.foldedProofs.count
        state["ruler"] = reader.rulerLine.map { ["page": $0.pageIndex + 1, "line": $0.index + 1, "count": $0.count] }
        state["readingStatement"] = readingStatement()?.label
        state["hierarchyKey"] = hierarchyKey?.title
        state["map"] = openMap != nil
        state["sideTabs"] = sideEditors.map { sideTitle($0) }
        state["activeSide"] = activeSideEditor.map { sideTitle($0) }
        if let id = openDerivationID, let report = derivationReports[id] {
            state["derivation"] = ["title": derivation(id)?.title ?? "", "holds": report.holds, "fails": report.fails, "unchecked": report.unchecked,
                                   "lines": report.lines.map { "\($0.line + 1):\($0.status.rawValue):\($0.message)" }]
        }
        let problems = problemCounts
        state["problems"] = [problems.errors, problems.warnings, problems.infos]
        if let editor = mainWindow?.firstResponder as? LabTextView {
            state["editor"] = ["string": editor.string, "selection": [editor.selectedRange().location, editor.selectedRange().length]]
        }
        return state
    }

    /// “name=Theorem&number=1.3” for QA actions on a statement.
    private func statementKey(_ info: [String: String]) -> ReferenceKey? {
        guard let number = info["number"] else { return nil }
        let name = info["name"]
        return analysis?.structure.statements.first { $0.key.number == number && (name == nil || $0.key.name == name) }?.key
            ?? ReferenceKey(kind: info["kind"].flatMap(ReferenceKind.init(rawValue:)) ?? .theorem, number: number, name: name)
    }

    /// Actions available to visual review, named after the menu commands they mirror.
    func performQA(_ action: String, info: [String: String]) async throws {
        switch action {
        // 3.0 find widget: findShow [query=…] [matchCase=1], findNext, findPrevious, findClose.
        case "findShow":
            FindController.shared.show(self)
            if let query = info["query"] { FindController.shared.query = query }
            if let matchCase = info["matchCase"] { FindController.shared.matchCase = matchCase == "1" }
            if let wholeWord = info["wholeWord"] { FindController.shared.wholeWord = wholeWord == "1" }
            if info["query"] != nil || info["matchCase"] != nil || info["wholeWord"] != nil { FindController.shared.search() }
        case "openSample": openSampleBook()
        case "findNext": FindController.shared.next()
        case "findPrevious": FindController.shared.previous()
        case "findClose": FindController.shared.hide()
        case "page": if let page = info["page"].flatMap(Int.init) { reader.goToPage(page) }
        case "focus": toggleFocus()
        case "closeBook": closeBook()
        case "section":
            if let section = info["value"].flatMap(StudySection.init(rawValue:)) { revealStudy(); studySection = section }
        case "navigator", "reveal":
            if let section = info["value"].flatMap(NavigatorSection.init(rawValue:)) { reveal(section) }
        case "panel":
            if let tab = info["value"].flatMap(PanelTab.init(rawValue:)) { panelTab = tab; showPanel = true } else { togglePanel() }
        case "consoleRun":
            guard let code = info["code"] else { throw QAHooks.QAError.missing("code") }
            submitConsole(code)
        case "palette":
            let mode: PaletteMode = info["mode"] == "commands" ? .commands : info["mode"] == "symbols" ? .symbols : info["mode"] == "themes" ? .themes : .goTo
            showPalette(mode, text: info["text"] ?? "")
        case "paletteClose": closePalette()
        case "goto":
            let items = PaletteProvider(store: self).items(mode: .goTo, query: info["query"] ?? "")
            guard let item = items.first else { throw QAHooks.QAError.missing("result for \(info["query"] ?? "")") }
            if info["side"] == "1", let side = item.openToSide { side() } else { item.perform() }
        case "split": toggleSplit()
        case "references":
            let key = ReferenceKey(kind: info["kind"].flatMap(ReferenceKind.init(rawValue:)) ?? .equation, number: info["number"] ?? "")
            showReferences(.object(key))
        case "index":
            guard let entry = analysis?.analysis.flatMap({ BookIndexSearch.find(info["term"] ?? "", in: $0.index, limit: 1).first?.entry }) else { throw QAHooks.QAError.missing("index entry") }
            openIndexEntry(entry)
        case "peek":
            let pageIndex = reader.pageNumber - 1
            let kind = info["kind"].flatMap(ReferenceKind.init(rawValue:))
            guard let mention = references?.mentions(onPage: pageIndex).first(where: { !$0.isDefinition && (kind == nil || $0.key.kind == kind) && (info["number"] == nil || $0.key.number == info["number"]) })
            else { throw QAHooks.QAError.missing("mention on this page") }
            // keep=1 opens it as a Shift-click does, beside the peeks already open.
            peekReference(mention, pageIndex: pageIndex, keep: info["keep"] == "1")
        case "peekMove":
            // The open peek moved by its title bar, dx, dy screen points (up positive), as the reader drags it: it stays open.
            guard let view = reader.view, let peek = view.referencePopover ?? view.keptReferencePeeks.last else { throw QAHooks.QAError.missing("peek") }
            peek.autoPlace = nil
            peek.panel.move(by: CGSize(width: Double(info["dx"] ?? "") ?? 0, height: Double(info["dy"] ?? "") ?? 0))
            peek.keep()
        case "peekResize":
            // The open peek's edge (edge=right|top|bottom|topRight|bottomRight, its corner by default) dragged by dx, dy
            // screen points (down positive), as the reader drags it.
            func area(in view: NSView) -> PeekResizeAreaView? {
                (view as? PeekResizeAreaView) ?? view.subviews.lazy.compactMap { area(in: $0) }.first
            }
            guard let found = NSApp.windows.lazy.filter(\.isVisible).compactMap({ $0.contentView?.superview.flatMap { area(in: $0) } }).first
            else { throw QAHooks.QAError.missing("peek") }
            let edge = found.edges.first { "\($0)" == info["edge"] } ?? found.edges[0]
            found.drag(edge, by: CGSize(width: Double(info["dx"] ?? "") ?? 0, height: Double(info["dy"] ?? "") ?? 0)); found.onEnd()
        case "lookup": lookupDefinition(info["term"] ?? "", pageIndex: reader.pageNumber - 1, region: nil)
        case "select":
            // Selects the first occurrence of a phrase on the current page, as a drag would.
            guard let page = document?.page(at: reader.pageNumber - 1), let range = StudyStore.occurrence(of: info["text"] ?? "", in: page.string ?? ""),
                  let selection = page.selection(for: range) else { throw QAHooks.QAError.missing("text on this page") }
            reader.view?.setCurrentSelection(selection, animate: false)
            reader.updateSelection()
        case "askSelection": prepareQuickAsk()
        case "selectRegion":
            // A captured region, as a drag in Capture mode makes one: page (from 1) and x, y, width, height in PDF points.
            guard let number = info["page"].flatMap(Int.init), let page = document?.page(at: number - 1),
                  let x = info["x"].flatMap(Double.init), let y = info["y"].flatMap(Double.init),
                  let width = info["width"].flatMap(Double.init), let height = info["height"].flatMap(Double.init) else { throw QAHooks.QAError.missing("page, x, y, width, height") }
            let rect = CGRect(x: x, y: y, width: width, height: height)
            reader.selection = (number - 1, rect, page.selection(for: rect)?.string ?? "")
            reader.hasSelection = true
        case "quickAsk":
            // The open Ask widget: question=, style=, provider=, mode=, untick=text|section|cited, state=<name>, send=1.
            NotificationCenter.default.post(name: QuickAskPane.qaNotification, object: nil, userInfo: info)
        case let action where action.hasPrefix("assistant") || action.hasPrefix("questionSheet"): try await performAssistantQA(action, info: info)
        case "dismiss": referencePeek = nil; definitionLookup = nil; quickAsk = nil; palette = nil
        case "waitAnalysis":
            let deadline = Date.now.addingTimeInterval(Double(info["timeout"] ?? "90") ?? 90)
            while analysis?.analysis == nil, Date.now < deadline { try await Task.sleep(for: .milliseconds(250)) }
            if analysis?.analysis == nil { throw QAHooks.QAError.missing("finished analysis") }
        case "layout":
            if let layout = info["value"].flatMap(ReadingLayout.init(rawValue:)) { updateLayout(layout) }
        case "pageMenu":
            // The context menu a right-click in the middle of the page opens, PDFKit's items included; perform=<title> runs
            // one of them as the menu would. Writes the items, then the display mode and the book's layout.
            guard let view = reader.view, let window = view.window,
                  let event = NSEvent.mouseEvent(with: .rightMouseDown, location: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil),
                                                 modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let menu = view.menu(for: event) else { throw QAHooks.QAError.missing("page menu") }
            if let title = info["perform"] {
                guard let item = menu.items.first(where: { $0.title == title }), let action = item.action else { throw QAHooks.QAError.missing("menu item \(title)") }
                NSApp.sendAction(action, to: item.target ?? view, from: item)
            }
            let items: [[String: Any]] = menu.items.map { ["title": $0.title, "on": $0.state == .on, "action": $0.action.map(NSStringFromSelector) ?? ""] }
            let result: [String: Any] = ["items": items, "displayMode": view.displayMode.rawValue, "layout": workspace?.reading.layout?.rawValue ?? ""]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]).write(to: QAHooks.shared!.directory.appendingPathComponent("\(info["name"] ?? "page-menu").json"))
        case "fitWidth": reader.fitWidth()
        case "appearance":
            NSApp.appearance = info["value"] == "light" ? NSAppearance(named: .aqua) : info["value"] == "dark" ? NSAppearance(named: .darkAqua) : nil
        case "open": if let path = info["path"] { open(URL(fileURLWithPath: path)) }
        case "sidebarSweep":
            // The Explorer's width moved from= to= (points) over ms= milliseconds at 60 steps a second and back back=1, as
            // the reader drags its sash: record it with videoStart/videoStop.
            let from = Double(info["from"] ?? "") ?? 400, to = Double(info["to"] ?? "") ?? 180
            let steps = max(1, Int((Double(info["ms"] ?? "") ?? 1500) / 1000 * 60))
            let sweep = (0...steps).map { from + (to - from) * Double($0) / Double(steps) }
            for width in sweep + (info["back"] == "1" ? sweep.reversed() : []) {
                workbenchLayout.sidebarWidth = width
                try await Task.sleep(for: .milliseconds(16))
            }
            saveWorkbench()
        case "tab": if let id = tabs.first(where: { $0.title == info["title"] })?.id { activateTab(id) }
        case "closeTab": if let id = tabs.first(where: { $0.title == info["title"] })?.id { closeTab(id) }
        case "selectNote":
            if let note = workspace?.notes.first(where: { $0.title == info["title"] }) { selectNote(note.id) }
        case "sendToLab": sendSelectionToLab()
        case "labNew": newLab(title: info["title"])
        case "labOpen":
            if let notebook = workspace?.labs.first(where: { $0.title == info["title"] }) ?? workspace?.labs.first { openLabNotebook(notebook.id) }
        case "labSetCode":
            guard let id = openLabID, let cell = lab(id)?.cells.last(where: { $0.kind == .code }) else { throw QAHooks.QAError.missing("open notebook") }
            let code = (info["code"] ?? "").replacingOccurrences(of: "\\n", with: "\n")
            if info["append"] == "1" { addLabCell(id, kind: info["kind"] == "text" ? .text : .code, after: lab(id)?.cells.last?.id ?? cell.id, source: code) }
            else { updateLab(id) { notebook in if let index = notebook.cells.firstIndex(where: { $0.id == cell.id }) { notebook.cells[index].source = code } } }
        case "labRunAll": if let id = openLabID { runAllLabCells(id) }
        case "labWait":
            let deadline = Date.now.addingTimeInterval(Double(info["timeout"] ?? "60") ?? 60)
            while Date.now < deadline {
                if let id = openLabID, let session = lab.sessions[id], session.state == .idle, session.queued.isEmpty, session.runningCellID == nil { break }
                try await Task.sleep(for: .milliseconds(200))
            }
        case "labClose": closeLabEditor()
        case "labPython": lab.setPreferredInterpreter(info["path"] ?? "")
        case "labProbe":
            // Runs an interpreter the way discovery does and reports what happened, for diagnosis.
            let path = info["path"] ?? ""
            let report: String = await Task.detached {
                let started = Date()
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = ["-I", "-c", "import sys, json; print(json.dumps({'version': sys.version.split()[0]}))"]
                let output = Pipe(), errors = Pipe()
                process.standardOutput = output; process.standardError = errors; process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { return "run failed: \(error)" }
                process.waitUntilExit()
                let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                return "status \(process.terminationStatus) in \(Date().timeIntervalSince(started)) s; out \(out); err \(err.prefix(600)); safe \(LabInterpreterFinder.isSafeToRun(path)); probe \(String(describing: LabInterpreterFinder.probe(path)))"
            }.value
            try report.write(to: QAHooks.shared!.directory.appendingPathComponent("\(info["name"] ?? "probe").txt"), atomically: true, encoding: .utf8)
        case "labSetupShow": showPythonSetup()
        case "labSetupClose": LabPythonSetupWindow.close()
        case "labSetupStart":
            await discoverPython()
            lab.setup.start()
        case "labSetupCancel": lab.setup.cancel()
        case "labSetupWait":
            let deadline = Date.now.addingTimeInterval(Double(info["timeout"] ?? "600") ?? 600)
            while lab.setup.isRunning, Date.now < deadline { try await Task.sleep(for: .milliseconds(250)) }
        case "labPinFigure":
            guard let id = openLabID, let name = lab(id)?.cells.flatMap(\.outputs).compactMap(\.imageName).first else { throw QAHooks.QAError.missing("figure") }
            pinLabFigure(name, notebookID: id)
        case "labFocus":
            guard let id = openLabID, let cell = lab(id)?.cells.last(where: { $0.kind == .code }) else { throw QAHooks.QAError.missing("open notebook") }
            NSApp.activate(ignoringOtherApps: true)
            lab.requestFocus(cell.id)
        case "renderTarget":
            let key = ReferenceKey(kind: info["kind"].flatMap(ReferenceKind.init(rawValue:)) ?? .equation, number: info["number"] ?? "")
            guard let target = references?.knownTarget(key), let page = document?.page(at: target.pageIndex) else { throw QAHooks.QAError.missing("target") }
            let data = try PDFRegionRenderer.png(page: page, region: target.region, scale: 3)
            try data.write(to: QAHooks.shared!.directory.appendingPathComponent("\(info["name"] ?? "target").png"))
            let json = ["page": target.pageIndex, "region": [target.region.x, target.region.y, target.region.width, target.region.height],
                        "anchor": [target.anchor.x, target.anchor.y, target.anchor.width, target.anchor.height]] as [String: Any]
            try JSONSerialization.data(withJSONObject: json).write(to: QAHooks.shared!.directory.appendingPathComponent("\(info["name"] ?? "target").json"))
        case "markUnclear": markUnclear()
        case "resumeMark": resumeAtFirstMark()
        case "foldAll": toggleAllProofs()
        case "foldProof":
            guard let key = statementKey(info), let proof = analysis?.structure.proof(of: key) else { throw QAHooks.QAError.missing("proof") }
            toggleProof(proof.stableID)
        case "understood": if let key = statementKey(info) { toggleUnderstood(key) }
        case "hierarchy":
            if let key = statementKey(info) { showHierarchy(key, direction: info["direction"] == "usedBy" ? .usedBy : .uses) } else { showHierarchyAtFocus() }
        case "map": if let key = statementKey(info) { showMap(for: key) } else { showMap() }
        case "mapClose": closeMap()
        case "goStatement": if let key = statementKey(info) { goToKey(key) }
        case "ruler": reader.rulerMode = info["value"] != "0"
        case "rulerMove": reader.moveRuler(by: Int(info["by"] ?? "1") ?? 1)
        case "hoverSymbol":
            // Shows the symbol hover for the first occurrence of a symbol on the current page.
            guard let view = reader.view, let page = document?.page(at: reader.pageNumber - 1), let text = page.string,
                  let range = StudyStore.occurrence(of: info["symbol"] ?? "", in: text), let rect = PageTextMap.bounds(of: range.location, on: page) else {
                throw QAHooks.QAError.missing("symbol on this page")
            }
            let point = view.convert(CGPoint(x: rect.midX, y: rect.midY), from: page)
            if let hit = view.symbolHit(at: point) { view.symbolHover.store = self; view.qaShowSymbol(hit) } else { throw QAHooks.QAError.missing("symbol definition") }
        case "theme": if let theme = info["value"].flatMap(PageTheme.init(rawValue:)) { pageTheme = theme }
        case "lineNumbers": reader.showLineNumbers = info["value"] != "0"
        case "goLine":
            if let page = info["page"].flatMap(Int.init), let line = info["line"].flatMap(Int.init) { reader.goToLine(line - 1, onPage: page - 1) }
        case "getBook":
            guard let book = BookCatalog.books.first(where: { $0.id == info["id"] }) else { throw QAHooks.QAError.missing("catalog book") }
            getCatalogBook(book)
        case "arxiv": openArxiv(info["id"] ?? "")
        case "findPaper":
            guard let key = referencePeek?.mention.key, let entry = analysis?.bibliographyEntry(key) else { throw QAHooks.QAError.missing("citation peek") }
            findPaper(entry)
            let deadline = Date.now.addingTimeInterval(Double(info["timeout"] ?? "20") ?? 20)
            while Date.now < deadline, paperLookups[entry.id] == .searching { try await Task.sleep(for: .milliseconds(200)) }
            if case let .found(papers)? = paperLookups[entry.id] {
                let lines = papers.map { "\($0.title) | \($0.authorLine) | \($0.year.map(String.init) ?? "") | pdf=\($0.pdfURL?.absoluteString ?? "-") | \(String(format: "%.2f", $0.confidence))" }
                try lines.joined(separator: "\n").write(to: QAHooks.shared!.directory.appendingPathComponent("\(info["name"] ?? "paper").txt"), atomically: true, encoding: .utf8)
            }
        case "derive": deriveSelection()
        case "derivationNew":
            let source = (info["source"] ?? "").replacingOccurrences(of: "\\n", with: "\n")
            newDerivation(title: info["title"], source: source.isEmpty ? nil : source)
        case "derivationSet":
            guard let id = openDerivationID else { throw QAHooks.QAError.missing("open derivation") }
            // From a file, so LaTeX such as \\nabla survives.
            let source = try info["file"].map { try String(contentsOfFile: $0, encoding: .utf8) } ?? (info["source"] ?? "").replacingOccurrences(of: "\\n", with: "\n")
            updateDerivation(id) { $0.source = source }
        case "derivationWait":
            let deadline = Date.now.addingTimeInterval(Double(info["timeout"] ?? "10") ?? 10)
            while Date.now < deadline {
                if let id = openDerivationID, derivationReports[id] != nil, derivationChecks[id] == nil { break }
                try await Task.sleep(for: .milliseconds(150))
            }
            try await Task.sleep(for: .milliseconds(400))
        case "derivationFocus":
            guard let id = openDerivationID else { throw QAHooks.QAError.missing("open derivation") }
            derivationFocus = (id, Int(info["line"] ?? "0") ?? 0, UUID())
        case "problems": showProblems()
        case "sideTab":
            if let editor = sideEditors.first(where: { sideTitle($0) == info["title"] }) { activateSideEditor(editor.id) }
        case "sideClose":
            // title= closes that side editor; without it, every one.
            for editor in sideEditors where info["title"] == nil || sideTitle(editor) == info["title"] { closeSideEditor(editor.id) }
        case "checkAnswer":
            guard let note = workspace?.notes.first(where: { $0.title == info["title"] }) ?? currentNote else { throw QAHooks.QAError.missing("note") }
            checkAnswerSteps(noteID: note.id)
        case "settings": openSettingsEditor()
        case "closeSettings": closeSpecial(.settings)
        case "special":
            if let editor = info["value"].flatMap(SpecialEditor.init(rawValue:)) { openSpecial(editor) }
        case "closeSpecial":
            if let editor = info["value"].flatMap(SpecialEditor.init(rawValue:)) { closeSpecial(editor) }
        case "mainTab": if let id = tabs.first(where: { $0.title == info["title"] })?.id { activateMainTab(id) }
        case "statements":
            // Writes the statements Lemma found, with their pages and proofs, for choosing what to test.
            let structure = analysis?.structure
            let rows: [[String: Any]] = (structure?.statements ?? []).prefix(Int(info["limit"] ?? "400") ?? 400).map { statement in
                var row: [String: Any] = ["title": statement.key.title, "page": statement.start.pageIndex + 1]
                if let name = statement.title { row["name"] = name }
                if let proof = structure?.proof(of: statement.key) { row["proof"] = [proof.start.pageIndex + 1, proof.end.pageIndex + 1, proof.lineCount] }
                return row
            }
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]).write(to: QAHooks.shared!.directory.appendingPathComponent("\(info["name"] ?? "statements").json"))
        case "debugState":
            let rows: [String: Any] = [
                "frames": debug?.frames.map(\.label) ?? [], "steps": debug?.steps ?? 0, "finished": debug?.finished ?? false,
                "line": reader.rulerLine.map { [$0.pageIndex + 1, $0.index + 1, $0.count] } ?? [],
                "scopes": debugScopes().map { ["scope": $0.scope, "variables": $0.variables.map { "\($0.name) = \($0.value) [\($0.detail)]" }] },
                "goal": debugGoal()?.title ?? "", "breakpoints": breakpoints.count, "watch": watchExpressions.map { evaluateWatch($0).value },
                "lineText": reader.rulerLine.map { lineText($0) } ?? "",
                "lineRect": reader.rulerLine.map { "\($0.rect)" } ?? "",
                "pageMentions": reader.rulerLine.map { line in (references?.mentions(onPage: line.pageIndex) ?? []).filter { !$0.isDefinition }.map { "\($0.key.title)@\($0.rects.first.map { "\(Int($0.minY))-\(Int($0.maxY))" } ?? "")" } } ?? []
            ]
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]).write(to: QAHooks.shared!.directory.appendingPathComponent("\(info["name"] ?? "debug").json"))
        case "librarySearch":
            reveal(.search)
            librarySearch.query = info["query"] ?? ""
            librarySearch.scope = info["scope"] == "book" ? .book : .library
            runLibrarySearch()
            let deadline = Date.now.addingTimeInterval(Double(info["timeout"] ?? "60") ?? 60)
            try await Task.sleep(for: .milliseconds(100))
            while librarySearch.isSearching, Date.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
            let rows = librarySearch.results.map { ["book": $0.title, "hits": $0.hits.count, "first": $0.hits.first.map { "p. \($0.pageLabel): …\($0.before.suffix(30))[\($0.match)]\($0.after.prefix(30))…" } ?? ""] as [String: Any] }
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]).write(to: QAHooks.shared!.directory.appendingPathComponent("\(info["name"] ?? "search").json"))
        case "openFirstHit":
            if let hit = librarySearch.results.first(where: { $0.title == info["book"] })?.hits.first ?? librarySearch.results.first?.hits.first { openSearchHit(hit) }
            try await Task.sleep(for: .milliseconds(700))
        case "titlebar":
            // The window's frame views above the content (title bar, toolbar), to check what draws over the workbench.
            guard let window = mainWindow, let frameView = window.contentView?.superview else { throw QAHooks.QAError.missing("window") }
            var lines = ["styleMask \(window.styleMask.rawValue) transparent \(window.titlebarAppearsTransparent) titleVisibility \(window.titleVisibility.rawValue) toolbar \(window.toolbar.map { "visible \($0.isVisible) style \(window.toolbarStyle.rawValue)" } ?? "none")"]
            func describe(_ view: NSView, depth: Int) {
                guard depth < 7 else { return }
                var line = String(repeating: "  ", count: depth) + "\(type(of: view)) \(NSStringFromRect(view.frame)) hidden \(view.isHidden) alpha \(view.alphaValue)"
                if let effect = view as? NSVisualEffectView { line += " effect material \(effect.material.rawValue) state \(effect.state.rawValue) blending \(effect.blendingMode.rawValue)" }
                if let color = view.layer?.backgroundColor { line += " layerBG \(color)" }
                lines.append(line)
                for subview in view.subviews where subview !== window.contentView { describe(subview, depth: depth + 1) }
            }
            describe(frameView, depth: 0)
            try lines.joined(separator: "\n").write(to: QAHooks.shared!.directory.appendingPathComponent("\(info["name"] ?? "titlebar").txt"), atomically: true, encoding: .utf8)
        case "style": ThemeManager.shared.style = WorkbenchStyle(rawValue: info["value"] ?? "") ?? .vscode
        case "classicTheme":
            UserDefaults.standard.set(info["value"] ?? "system", forKey: "workbench.theme")
            if let accent = info["accent"] { UserDefaults.standard.set(accent, forKey: "workbench.accent") }
            ThemeManager.shared.apply()
        case "colorTheme":
            // value=<theme id>; auto=1 follows macOS again.
            if info["auto"] == "1" { ThemeManager.shared.autoDetect = true }
            else if let id = info["value"] { ThemeManager.shared.autoDetect = false; ThemeManager.shared.choose(id) }
        case "themePreview": ThemeManager.shared.preview(info["value"])
        case "accent": ThemeManager.shared.accent = AccentOverride(rawValue: info["value"] ?? "") ?? .theme
        case "minimap": showMinimap = info["value"] != "0"
        case "debugStart": startDebugging()
        case "debugStep": for _ in 0..<(Int(info["count"] ?? "1") ?? 1) { debugStepOver() }
        case "debugBack": debugStepBack()
        case "debugInto": debugStepInto()
        case "debugOut": debugStepOut()
        case "debugContinue": debugContinue()
        case "debugRestart": debugRestart()
        case "debugStop": stopDebugging()
        case "breakpoint": toggleBreakpoint()
        case "watch": addWatch(info["value"] ?? "")
        case "testsDue": runDueTests()
        case "testsChapter": runChapterTests()
        case "menuProbe":
            // The menus' anchors on screen (top-left coordinates, as the window server reports windows), and optionally
            // one menu opened under its anchor, to check where AppKit really puts it.
            guard let window = mainWindow, let content = window.contentView, let screen = NSScreen.screens.first else { throw QAHooks.QAError.missing("window") }
            func anchors(_ view: NSView) -> [NSView] { (view.identifier == MenuAnchorView.identifier ? [view] : []) + view.subviews.flatMap(anchors) }
            let found = anchors(content).filter { !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0 }
            let rows: [[String: Double]] = found.map { anchor in
                let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
                return ["x": rect.minX, "y": screen.frame.height - rect.maxY, "width": rect.width, "height": rect.height]
            }
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]).write(to: QAHooks.shared!.directory.appendingPathComponent("\(info["name"] ?? "menus").json"))
            if let index = info["open"].flatMap(Int.init), found.indices.contains(index) {
                let anchor = found[index]
                let placement = (anchor as? MenuAnchorView.AnchorView)?.placement ?? .below
                DispatchQueue.main.async { NativeMenu.show([.action("Probe One") {}, .action("Probe Two") {}], under: anchor, placement: placement) }
            }
        case "commands":
            // Every command the palette offers now, for a smoke test that runs them one by one.
            let titles = commandCatalog().map(\.title)
            try JSONSerialization.data(withJSONObject: titles, options: [.prettyPrinted]).write(to: QAHooks.shared!.directory.appendingPathComponent("\(info["name"] ?? "commands").json"))
        case "runCommand":
            guard let title = info["title"], let item = commandCatalog().first(where: { $0.title == title }) else { throw QAHooks.QAError.missing("command \(info["title"] ?? "")") }
            let before = Set(notifications.map(\.id))
            item.perform()
            try await Task.sleep(for: .milliseconds(Int(info["wait"] ?? "") ?? 400))
            let added = notifications.filter { !before.contains($0.id) }.map { ["severity": "\($0.severity)", "message": $0.message] }
            let result: [String: Any] = ["title": title, "notifications": added, "error": error ?? "", "special": activeSpecial?.rawValue ?? "",
                                         "palette": palette != nil, "sheets": [showShortcuts, showReleaseNotes, showCustomization].map { $0 ? 1 : 0 }]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]).write(to: QAHooks.shared!.directory.appendingPathComponent("\(info["name"] ?? "command").json"))
        case "notify": notify(info["message"] ?? "Hello from QA", severity: info["severity"] == "error" ? .error : info["severity"] == "warning" ? .warning : .info)
        case "notifications": showNotificationCenter = info["value"] != "0"
        case "panelMax": showPanel = true; panelMaximized = info["value"] != "0"
        case "pane": paneExpanded[info["key"] ?? ""] = info["value"] != "0"
        case "openSide": if let book = library.first(where: { $0.title == info["title"] }) { openBookToTheSide(book.id) }
        case "closeMarginNote": dismissMarginNote()
        case "lineFlip":
            // Profiling: moves the status bar's line `count` times, every 30 ms.
            for _ in 0..<(Int(info["count"] ?? "") ?? 100) {
                reader.qaStepLine()
                try await Task.sleep(for: .milliseconds(30))
            }
        case "focusFlip":
            // Profiling: flips the published statement (breadcrumbs and sticky header) `count` times, every 30 ms.
            // mode=swap keeps the header shown and changes its text (proof or statement), as reading on does.
            let original = reader.focusStatement
            let other = original.map { ReadingStatement(statement: $0.statement, inProof: !$0.inProof, headVisible: false) }
            for step in 0..<(Int(info["count"] ?? "") ?? 100) {
                reader.focusStatement = step % 2 == 0 ? (info["mode"] == "swap" ? other : nil) : original
                try await Task.sleep(for: .milliseconds(30))
            }
            reader.focusStatement = original
        case "windowOrder":
            // front: the reader's window over the others without activating Lemma (it takes no keyboard focus); back: behind them.
            if info["value"] == "back" { mainWindow?.orderBack(nil) } else { mainWindow?.orderFrontRegardless() }
        case "symbolSweep":
            // Hit-tests a grid over the visible area with and without the word prefilter; writes how many hits differ.
            guard let view = reader.view else { throw QAHooks.QAError.missing("reader") }
            var hits = 0, mismatches = 0, points = 0
            let step = CGFloat(Double(info["step"] ?? "") ?? 6)
            var y = view.bounds.minY
            while y < view.bounds.maxY {
                var x = view.bounds.minX
                while x < view.bounds.maxX {
                    let fast = view.symbolHit(at: CGPoint(x: x, y: y)), slow = view.symbolHit(at: CGPoint(x: x, y: y), prefilter: false)
                    points += 1; if slow != nil { hits += 1 }; if fast != slow { mismatches += 1 }
                    x += step
                }
                y += step
            }
            try "points \(points) hits \(hits) mismatches \(mismatches)".write(to: QAHooks.shared!.directory.appendingPathComponent("\(info["name"] ?? "sweep").txt"), atomically: true, encoding: .utf8)
        case "zoom":
            // value=<scale factor>, or fit=width|page.
            if info["fit"] == "width" { reader.fitWidth() } else if info["fit"] == "page" { reader.fit() }
            else if let value = info["value"].flatMap(Double.init) { reader.view?.autoScales = false; reader.view?.scaleFactor = CGFloat(value) }
        case "hoverReference":
            // index=, or kind= and number=; off=1 ends the hover, as the pointer leaving the reference does.
            guard reader.view?.qaHoverReference(Int(info["index"] ?? "") ?? 0, kind: info["kind"].flatMap(ReferenceKind.init(rawValue:)), number: info["number"],
                                                off: info["off"] == "1") == true
            else { throw QAHooks.QAError.missing("reference on screen") }
        case "inkStroke":
            // Draws a wavy stroke across the current page (synthesized events sent straight to the reader, not the system).
            guard let view = reader.view, let page = document?.page(at: reader.pageNumber - 1) else { throw QAHooks.QAError.missing("page") }
            let box = page.bounds(for: .cropBox)
            let height: CGFloat = box.height * CGFloat(Double(info["y"] ?? "") ?? 0.5)
            let y: CGFloat = box.minY + height
            reader.inkMode = true
            var points: [CGPoint] = []
            for step in 0...40 {
                let t = CGFloat(step) / 40
                points.append(CGPoint(x: box.minX + box.width * (0.2 + 0.6 * t), y: y + 12 * sin(CGFloat(step) / 3)))
            }
            view.qaDrag(onPage: reader.pageNumber - 1, through: points)
            if info["keep"] != "1" { reader.inkMode = false }
        case "regionCapture":
            // Captures a region of the current page given in page points (x, y, w, h), as a drag in region mode would.
            guard let view = reader.view else { throw QAHooks.QAError.missing("reader") }
            let x = Double(info["x"] ?? "") ?? 72, y = Double(info["y"] ?? "") ?? 400, w = Double(info["w"] ?? "") ?? 200, h = Double(info["h"] ?? "") ?? 80
            reader.regionMode = true
            view.qaDrag(onPage: reader.pageNumber - 1, through: [CGPoint(x: x, y: y + h), CGPoint(x: x + w / 2, y: y + h / 2), CGPoint(x: x + w, y: y)])
        case "regionMode": reader.regionMode = info["value"] != "0"
        case "activate":
            // A demo recorded with the window active (traffic lights, caret, selection colours), while the reader is away.
            NSApp.activate(ignoringOtherApps: true)
            mainWindow?.makeKeyAndOrderFront(nil)
        case "typeText":
            // text= or file=, interval= (seconds a character), at= (first puts the caret before that text): types into the
            // text view that has the keyboard, one character at a time, as a person types. Writes <name>.json with the
            // wall-clock times of the first and last characters.
            guard let textView = mainWindow?.firstResponder as? NSTextView else { throw QAHooks.QAError.missing("a text view with the keyboard") }
            let text = try info["file"].map { try String(contentsOfFile: $0, encoding: .utf8) } ?? info["text"] ?? ""
            if let at = info["at"] {
                let range = (textView.string as NSString).range(of: at)
                guard range.location != NSNotFound else { throw QAHooks.QAError.missing("“\(at)” in the text") }
                textView.setSelectedRange(NSRange(location: range.location, length: 0))
            }
            let interval = Double(info["interval"] ?? "") ?? 0.06
            var times: [Double] = []
            for (index, character) in text.enumerated() {
                if index > 0 { try await Task.sleep(for: .seconds(interval)) }
                textView.insertText(String(character), replacementRange: textView.selectedRange())
                times.append(Date().timeIntervalSince1970)
            }
            if let directory = QAHooks.shared?.directory {
                try JSONSerialization.data(withJSONObject: ["first": times.first ?? 0, "last": times.last ?? 0, "count": times.count])
                    .write(to: directory.appendingPathComponent("\(info["name"] ?? "typeText").json"))
            }
        case "caretRect":
            // at=: writes <name>.json with the rectangle of that text's first character in the text view that has the
            // keyboard, in window points from the window's top left.
            guard let window = mainWindow, let textView = window.firstResponder as? NSTextView, let at = info["at"] else { throw QAHooks.QAError.missing("a text view and at=") }
            let range = (textView.string as NSString).range(of: at)
            guard range.location != NSNotFound else { throw QAHooks.QAError.missing("“\(at)” in the text") }
            let screen = textView.firstRect(forCharacterRange: NSRange(location: range.location, length: 1), actualRange: nil)
            let rect = [screen.minX - window.frame.minX, window.frame.maxY - screen.maxY, screen.width, screen.height]
            if let directory = QAHooks.shared?.directory {
                try JSONSerialization.data(withJSONObject: ["rect": rect]).write(to: directory.appendingPathComponent("\(info["name"] ?? "caretRect").json"))
            }
        case "glyphRects":
            // Writes <name>.json with every character's rectangle in the text view that has the keyboard (window points from
            // the window's top left), for drawing a caret over a recording.
            guard let window = mainWindow, let textView = window.firstResponder as? NSTextView else { throw QAHooks.QAError.missing("a text view with the keyboard") }
            let string = textView.string as NSString
            var rects: [[Double]] = []
            for index in 0..<string.length {
                let screen = textView.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
                rects.append([screen.minX - window.frame.minX, window.frame.maxY - screen.maxY, screen.width, screen.height])
            }
            if let directory = QAHooks.shared?.directory {
                try JSONSerialization.data(withJSONObject: ["text": textView.string, "rects": rects])
                    .write(to: directory.appendingPathComponent("\(info["name"] ?? "glyphRects").json"))
            }
        case "dragAnimate":
            // page= x0= y0= x1= y1= (page points) duration=: a capture drag drawn at 60 steps a second with an eased motion.
            // Writes <name>.json with the wall-clock times of the press and the release.
            guard let view = reader.view, let x0 = info["x0"].flatMap(Double.init), let y0 = info["y0"].flatMap(Double.init),
                  let x1 = info["x1"].flatMap(Double.init), let y1 = info["y1"].flatMap(Double.init) else { throw QAHooks.QAError.missing("reader, x0, y0, x1, y1") }
            let page = (Int(info["page"] ?? "") ?? reader.pageNumber) - 1
            let duration = Double(info["duration"] ?? "") ?? 0.9
            view.qaDragStep(.leftMouseDown, onPage: page, at: CGPoint(x: x0, y: y0))
            let start = Date()
            var elapsed = 0.0
            while elapsed < duration {
                try await Task.sleep(for: .milliseconds(16))
                elapsed = min(duration, Date().timeIntervalSince(start))
                let u = elapsed / duration, e = u * u * (3 - 2 * u)
                view.qaDragStep(.leftMouseDragged, onPage: page, at: CGPoint(x: x0 + (x1 - x0) * e, y: y0 + (y1 - y0) * e))
            }
            view.qaDragStep(.leftMouseUp, onPage: page, at: CGPoint(x: x1, y: y1))
            if let directory = QAHooks.shared?.directory {
                try JSONSerialization.data(withJSONObject: ["down": start.timeIntervalSince1970, "up": Date().timeIntervalSince1970])
                    .write(to: directory.appendingPathComponent("\(info["name"] ?? "dragAnimate").json"))
            }
        case "dragStep":
            // phase=down|drag|up page= (from 1) x= y= in page points: a capture drag one step at a time.
            guard let view = reader.view, let x = info["x"].flatMap(Double.init), let y = info["y"].flatMap(Double.init) else { throw QAHooks.QAError.missing("reader, x, y") }
            let type: NSEvent.EventType = info["phase"] == "down" ? .leftMouseDown : info["phase"] == "up" ? .leftMouseUp : .leftMouseDragged
            view.qaDragStep(type, onPage: (Int(info["page"] ?? "") ?? reader.pageNumber) - 1, at: CGPoint(x: x, y: y))
        case "scrollBench":
            // Scrolls the reader through `pages` pages at `fps` (step points per frame) and writes <name>.json (see QAPerf).
            guard let directory = QAHooks.shared?.directory else { throw QAHooks.QAError.missing("QA folder") }
            try await QAPerf.scrollBench(store: self, info: info, output: directory.appendingPathComponent("\(info["name"] ?? "scrollBench").json"))
        case "wheel":
            // A trackpad gesture at x, y (points from the window's top left); writes <name>.json (see QAWheel).
            guard let window = mainWindow, let directory = QAHooks.shared?.directory else { throw QAHooks.QAError.missing("window") }
            try await QAWheel.perform(window: window, info: info, output: directory.appendingPathComponent("\(info["name"] ?? "wheel").json"))
        case "mouseThrough":
            // value=1 lets the reader's own pointer pass through the window (while a demo is recorded), value=0 restores it.
            mainWindow?.ignoresMouseEvents = info["value"] != "0"
        case "inspector": showStudy = info["value"] != "0"
        case "sidebar": showLibrary = info["value"] != "0"
        default:
            if try await performLibraryQA(action, info: info) { break }
            throw QAHooks.QAError.missing("action \(action)")
        }
    }
}
