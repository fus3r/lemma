import SwiftUI
import AppKit
import PDFKit
import LemmaCore

/// A line the reader wants the debugger to stop at (F9): a page and the line's height on it.
struct LineBreakpoint: Codable, Equatable, Identifiable {
    var id = UUID()
    var pageIndex: Int
    /// The line's vertical centre, in page space.
    var y: Double
    var enabled = true
    /// The start of the line's text, to name it in the Breakpoints pane.
    var text: String

    func matches(_ line: ReaderController.RulerLine) -> Bool {
        line.pageIndex == pageIndex && abs(Double(line.rect.midY) - y) <= max(2, Double(line.rect.height) / 2)
    }
}

/// One frame of the call stack: a statement (or section) being read and, below the top, where reading left it.
struct DebugFrame: Equatable, Identifiable {
    let id = UUID()
    var key: ReferenceKey?
    var label: String
    /// Where the reader was in this frame when stepping into another (nil for the top frame, which is the ruler).
    var saved: ReaderController.RulerLine?
}

/// Run and Debug for a proof: the reading ruler is the current line, the call stack the results stepped into.
struct ProofDebugSession: Equatable {
    var frames: [DebugFrame]
    /// Whether the ruler was already on, so stopping leaves it as it was.
    var rulerWasOn: Bool
    /// Where the session began, for Restart when no statement was found.
    var startLine: ReaderController.RulerLine? = nil
    var steps = 0
    var finished = false
    var top: DebugFrame { frames[frames.count - 1] }
    var statusText: String {
        let base = frames.first?.label ?? "Reading"
        return frames.count > 1 ? "\(base) › \(top.label)" : base
    }
}

/// A row of the Variables or Watch pane: a symbol and what it stands for, a result and its statement.
struct DebugVariable: Identifiable {
    let id: String
    let name: String
    let value: String
    var detail: String = ""
    var italicName = false
    var target: ReferenceTarget? = nil
    var definition: SymbolDefinition? = nil
}

@MainActor
extension StudyStore {
    // MARK: Session

    /// Starts debugging a statement · the one given, the one at the reading position, or the first one in view · or,
    /// without one, the passage in view: F5.
    func startDebugging(at key: ReferenceKey? = nil, from here: (pageIndex: Int, point: CGPoint)? = nil) {
        guard document != nil else { choosePDF(); return }
        if panelMaximized || activeSpecial != nil || activeFileName != nil {
            // The page must be in view to place the reading line: bring the book back first, as VS Code shows the
            // editor when a debug session starts.
            panelMaximized = false
            activeSpecial = nil
            activeFileName = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.startDebugging(at: key, from: here) }
            return
        }
        if debug != nil {
            guard key != nil || here != nil, key == nil || key != debug?.frames.first?.key else { debugContinue(); return }
            stopDebugging()
        }
        let rulerWasOn = reader.rulerMode
        if !reader.rulerMode { reader.rulerMode = true }
        let statement: StatementInfo?
        if let here {
            // Run and Debug from Here: from the clicked line, in the statement that line belongs to.
            reader.placeRuler(at: here.point, pageIndex: here.pageIndex)
            statement = reader.rulerLine.flatMap { self.statement(containing: point(of: $0)) }
        } else {
            statement = key.flatMap { analysis?.structure.statement($0) } ?? statementAtFocus() ?? statementInView()
            if let statement { placeRuler(at: statement.start) }
        }
        if reader.rulerLine == nil { reader.placeRulerAtFocus() }
        guard reader.rulerLine != nil else {
            // A page of figures or a blank page: there is no line to step through.
            if !rulerWasOn { reader.rulerMode = false }
            notify("No line of text in view to step through. Scroll to a passage or a proof, then press F5.", severity: .warning, source: "Run and Debug", timeout: 6)
            return
        }
        let label: String
        if let statement {
            label = statement.key.title
        } else {
            label = breadcrumb().last?.title ?? "Page \(printedLabel(for: reader.pageNumber - 1) ?? String(reader.pageNumber))"
        }
        debug = ProofDebugSession(frames: [DebugFrame(key: statement?.key, label: label)], rulerWasOn: rulerWasOn, startLine: reader.rulerLine)
        reader.debugging = true
        reveal(.debug)
        WalkthroughStep.markDone(.debug)
        if statement == nil, analysis?.analysis != nil {
            notify("No numbered statement here: stepping through the passage in view. Put the reading position in a theorem or its proof to debug it.",
                   source: "Run and Debug", timeout: 6)
        }
    }

    func stopDebugging() {
        guard let session = debug else { return }
        debug = nil
        reader.debugging = false
        if !session.rulerWasOn { reader.rulerMode = false }
    }

    func debugRestart() {
        guard var session = debug, let first = session.frames.first else { return }
        if revealDebugReader(then: { $0.debugRestart() }) { return }
        session.frames = [DebugFrame(key: first.key, label: first.label)]
        session.steps = 0; session.finished = false
        debug = session
        if let key = first.key, let statement = analysis?.structure.statement(key) { placeRuler(at: statement.start) }
        else if let line = session.startLine { reader.rulerLine = line; reader.revealRuler() }
        else { reader.placeRulerAtFocus() }
    }

    /// The ruler's line during a session, placed at the reading position when it has none (after scrolling to a page of
    /// figures, say); nil, with a notice, when no line of text is in view. Never starts a session again: F5, F10 and F11
    /// calling one another without a line recursed until the app crashed.
    private func debugLine() -> ReaderController.RulerLine? {
        if let line = reader.rulerLine { return line }
        reader.placeRulerAtFocus()
        if let line = reader.rulerLine { return line }
        notify("No line of text in view. Scroll to the passage you are debugging.", severity: .warning, source: "Run and Debug", timeout: 5)
        return nil
    }

    /// A file or maximized panel can replace the PDF surface while a proof session stays open.
    /// Restore that session's page before its next action, then wait for the attached reader.
    private func revealDebugReader(then action: @escaping @MainActor (StudyStore) -> Void) -> Bool {
        guard activeFileName != nil || activeSpecial != nil || panelMaximized, let id = workspace?.id else { return false }
        let page = reader.rulerLine?.pageIndex ?? workspace?.reading.pageIndex ?? reader.pageNumber - 1
        panelMaximized = false; openBook(id, atPage: page)
        whenShowing(id, action)
        return true
    }

    /// Next line (F10).
    func debugStepOver() {
        guard debug != nil else { startDebugging(); return }
        if revealDebugReader(then: { $0.debugStepOver() }) { return }
        guard debugLine() != nil else { return }
        reader.moveRuler(by: 1)
        debug?.steps += 1
        checkEndOfProof()
    }

    func debugStepBack() {
        guard debug != nil else { return }
        if revealDebugReader(then: { $0.debugStepBack() }) { return }
        guard debugLine() != nil else { return }
        reader.moveRuler(by: -1)
        debug?.steps += 1
    }

    /// Into the result, equation or figure the line cites (F11); a line that cites nothing is stepped over.
    func debugStepInto() {
        guard debug != nil else { startDebugging(); return }
        if revealDebugReader(then: { $0.debugStepInto() }) { return }
        guard let line = debugLine(), var session = debug else { return }
        guard let cited = citedTarget(on: line) else { debugStepOver(); return }
        session.frames[session.frames.count - 1].saved = line
        session.frames.append(DebugFrame(key: cited.key, label: cited.label))
        session.steps += 1
        debug = session
        if let key = cited.key, let statement = analysis?.structure.statement(key) { placeRuler(at: statement.start) }
        else {
            reader.placeRuler(at: cited.point, pageIndex: cited.pageIndex)
            reader.revealRuler()
        }
        if let region = cited.region { reader.flash(region, onPage: cited.pageIndex) }
    }

    /// Back to where the result was cited (⇧F11); from the outermost frame, to the end of the proof.
    func debugStepOut() {
        guard var session = debug else { return }
        if revealDebugReader(then: { $0.debugStepOut() }) { return }
        if session.frames.count > 1 {
            session.frames.removeLast()
            let saved = session.frames[session.frames.count - 1].saved
            session.frames[session.frames.count - 1].saved = nil
            session.steps += 1
            debug = session
            if let saved { reader.rulerLine = saved; reader.revealRuler() }
            return
        }
        if let end = proofEnd(of: session.top.key) { placeRuler(at: end, before: true); debug?.finished = true; offerUnderstood() }
    }

    /// To the next breakpoint or “?” mark, else to the end of the proof (F5 while debugging). The lines ahead are read
    /// without moving: the ruler moves once, to where it stops (stepping it line by line scrolled the page at every line
    /// and left the reader 40 pages on when nothing stopped it).
    func debugContinue() {
        guard debug != nil else { startDebugging(); return }
        if revealDebugReader(then: { $0.debugContinue() }) { return }
        guard let document, let current = debugLine() else { return }
        let end = proofEnd(of: debug?.top.key)
        let lastPage = min(document.pageCount - 1, current.pageIndex + 40)
        var previous = current
        var pageIndex = current.pageIndex, index = current.index + 1
        while pageIndex <= lastPage {
            let lines = reader.readingLines(onPage: pageIndex)
            while index < lines.count {
                let line = ReaderController.RulerLine(pageIndex: pageIndex, rect: lines[index], index: index, count: lines.count)
                if let end, point(of: line) >= end {
                    // Stop on the proof's last line, not on the first line after it.
                    moveRuler(to: point(of: line) > end ? previous : line)
                    debug?.finished = true; offerUnderstood(); return
                }
                if breakpoints.contains(where: { $0.enabled && $0.matches(line) }) || hasQuestionMark(on: line) {
                    moveRuler(to: line); debug?.steps += 1; return
                }
                previous = line; index += 1
            }
            pageIndex += 1; index = 0
        }
        notify("No breakpoint ahead in the next 40 pages. Mark a line with F9, or a passage with “?” (⌥⌘/).", source: "Run and Debug", timeout: 5)
    }

    private func moveRuler(to line: ReaderController.RulerLine) {
        reader.rulerLine = line
        reader.revealRuler()
    }

    /// Adds or removes a breakpoint on the ruler's line, or on the line at the reading position (F9).
    func toggleBreakpoint() {
        let line: ReaderController.RulerLine? = reader.rulerLine ?? {
            let page = reader.focusPageIndex
            let lines = reader.readingLines(onPage: page)
            guard let y = reader.focusY, let index = lines.firstIndex(where: { $0.maxY <= y + 2 }) ?? lines.indices.first else { return nil }
            return ReaderController.RulerLine(pageIndex: page, rect: lines[index], index: index, count: lines.count)
        }()
        guard let line else { return }
        if let index = breakpoints.firstIndex(where: { $0.matches(line) }) { breakpoints.remove(at: index) }
        else {
            let text = document?.page(at: line.pageIndex)?.selection(for: line.rect)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            breakpoints.append(LineBreakpoint(pageIndex: line.pageIndex, y: Double(line.rect.midY), text: String(text.prefix(80))))
            breakpoints.sort { $0.pageIndex == $1.pageIndex ? $0.y > $1.y : $0.pageIndex < $1.pageIndex }
        }
        saveWorkbench()
    }

    func goToBreakpoint(_ breakpoint: LineBreakpoint) {
        if activeFileName != nil || activeSpecial != nil || panelMaximized, let id = workspace?.id {
            panelMaximized = false; openBook(id, atPage: breakpoint.pageIndex)
            whenShowing(id) { $0.goToBreakpoint(breakpoint) }
            return
        }
        let lines = reader.readingLines(onPage: breakpoint.pageIndex)
        guard let index = lines.indices.min(by: { abs(Double(lines[$0].midY) - breakpoint.y) < abs(Double(lines[$1].midY) - breakpoint.y) }) else {
            reader.goToPage(breakpoint.pageIndex + 1); return
        }
        if reader.rulerMode { reader.rulerLine = ReaderController.RulerLine(pageIndex: breakpoint.pageIndex, rect: lines[index], index: index, count: lines.count); reader.revealRuler() }
        else { reader.goToLine(index, onPage: breakpoint.pageIndex) }
    }

    /// “Proof of Theorem 2.3” while the line is inside the proof, else the frame's own label.
    func frameTitle(_ frame: DebugFrame, line: ReaderController.RulerLine?) -> String {
        guard let key = frame.key, let line, let proof = analysis?.structure.proof(of: key) else { return frame.label }
        let here = point(of: line)
        return proof.start <= here && here <= proof.end ? "Proof of \(frame.label)" : frame.label
    }

    // MARK: What the panes show

    /// The text point at the start of a ruler line.
    func point(of line: ReaderController.RulerLine) -> TextPoint {
        let location = pageTextMap(line.pageIndex)?.line(at: CGPoint(x: line.rect.minX + 2, y: line.rect.midY))?.range.location ?? 0
        return TextPoint(pageIndex: line.pageIndex, location: location)
    }

    func lineText(_ line: ReaderController.RulerLine) -> String {
        document?.page(at: line.pageIndex)?.selection(for: line.rect.insetBy(dx: -1, dy: 0))?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Scopes for the Variables pane: the statement being proved, the symbols on the current line, those introduced in this
    /// statement so far, and the results it uses.
    func debugScopes() -> [(scope: String, variables: [DebugVariable])] {
        guard let session = debug, let line = reader.rulerLine else { return [] }
        var scopes: [(String, [DebugVariable])] = []
        let here = point(of: line)
        let notation = analysis?.notation
        // The symbols on this line, with the meaning in force here.
        if let notation, !notation.isEmpty {
            let used = notation.symbols(usedIn: lineText(line), pageIndex: line.pageIndex)
            let variables = used.map { item in
                DebugVariable(id: "line-\(item.symbol)", name: item.symbol, value: item.definition.meaning,
                              detail: (item.later ? "defined later · " : "") + shortPageText(item.definition.pageIndex), italicName: true, definition: item.definition)
            }
            scopes.append(("Line \(line.index + 1)", variables))
        }
        // Symbols this statement and its proof introduce before the current line.
        if let key = session.top.key, let statement = analysis?.structure.statement(key), let symbols = analysis?.analysis?.symbols {
            var latest: [String: SymbolDefinition] = [:]
            for definition in symbols where statement.start <= definition.point && definition.point <= here { latest[definition.symbol] = definition }
            let variables = latest.values.sorted { $0.point < $1.point }.map {
                DebugVariable(id: "local-\($0.symbol)-\($0.location)", name: $0.symbol, value: $0.meaning, detail: shortPageText($0.pageIndex), italicName: true, definition: $0)
            }
            scopes.append(("Local", variables))
        }
        // What the statement and its proof use.
        if let key = session.top.key, let structure = analysis?.structure {
            let uses = structure.uses(key).sorted { $0.count > $1.count }
            let variables = uses.map { edge -> DebugVariable in
                let target = analysis?.target(for: edge.to) ?? references?.knownTarget(edge.to)
                let title = structure.statement(edge.to)?.title
                return DebugVariable(id: "uses-\(edge.to.title)", name: edge.to.title, value: title ?? (edge.inProof ? "used in the proof" : "used in the statement"),
                                     detail: target.map { shortPageText($0.pageIndex) } ?? "", target: target)
            }
            scopes.append(("Uses", variables))
        }
        return scopes
    }

    /// The statement being proved, rendered from the page, for the top of the Variables pane.
    func debugGoal() -> (title: String, image: NSImage?, target: ReferenceTarget?)? {
        guard let key = debug?.top.key else { return nil }
        let target = analysis?.target(for: key) ?? references?.knownTarget(key)
        var image: NSImage?
        if let target, let page = document?.page(at: target.pageIndex) {
            image = renderRegion(page: page, rect: target.region.rect, maxHeight: 220)
        }
        let title = analysis?.structure.statement(key)?.title.map { "\(key.title) (\($0))" } ?? key.title
        return (title, image, target)
    }

    /// A watch expression's value at the current line: a label, a symbol, or an index term.
    func evaluateWatch(_ expression: String) -> DebugVariable {
        let text = expression.trimmingCharacters(in: .whitespaces)
        let id = "watch-\(text)"
        if let definitions = analysis?.analysis?.definitions {
            let lowered = text.lowercased()
            if let target = definitions.first(where: { $0.key.title.lowercased() == lowered || $0.key.spokenTitle.lowercased() == lowered || "(\($0.key.number))" == text }) {
                return DebugVariable(id: id, name: text, value: target.key.spokenTitle, detail: shortPageText(target.pageIndex), target: target)
            }
        }
        if let notation = analysis?.notation, let line = reader.rulerLine,
           let found = notation.definition(of: Notation.key(text), at: point(of: line)) {
            return DebugVariable(id: id, name: text, value: found.definition.meaning,
                                 detail: (found.later ? "defined later · " : "") + shortPageText(found.definition.pageIndex), italicName: true, definition: found.definition)
        }
        if let index = analysis?.analysis?.index, let hit = BookIndexSearch.find(text, in: index, limit: 1).first {
            let pages = hit.entry.locators.prefix(4).map { "p. \($0.text)" }.joined(separator: ", ")
            return DebugVariable(id: id, name: text, value: "in the index: \(pages)", detail: "")
        }
        return DebugVariable(id: id, name: text, value: "not defined before this line", detail: "")
    }

    func addWatch(_ expression: String) {
        let text = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !watchExpressions.contains(text) else { return }
        watchExpressions.append(text); saveWorkbench()
    }

    func removeWatch(_ expression: String) { watchExpressions.removeAll { $0 == expression }; saveWorkbench() }

    // MARK: Helpers

    /// The statement whose head is visible nearest the top of the view, when the reading position is in none.
    private func statementInView() -> StatementInfo? {
        guard let statements = analysis?.structure.statements, let view = reader.view, let document else { return nil }
        var best: (statement: StatementInfo, y: CGFloat)?
        for page in view.visiblePages {
            let pageIndex = document.index(for: page)
            for statement in statements where statement.start.pageIndex == pageIndex {
                guard let rect = PageTextMap.bounds(of: statement.start.location, on: page) else { continue }
                let local = view.convert(rect, from: page)
                guard view.bounds.intersects(local) else { continue }
                // Views are not flipped: the topmost head has the largest y.
                if best == nil || local.maxY > best!.y { best = (statement, local.maxY) }
            }
        }
        return best?.statement
    }

    /// Puts the ruler on the line holding a point of the text.
    func placeRuler(at point: TextPoint, before: Bool = false) {
        guard let page = document?.page(at: point.pageIndex) else { return }
        if let rect = PageTextMap.bounds(of: point.location, on: page) {
            reader.placeRuler(at: CGPoint(x: rect.midX, y: before ? rect.maxY + 4 : rect.midY), pageIndex: point.pageIndex)
        } else {
            reader.placeRuler(at: CGPoint(x: page.bounds(for: .cropBox).midX, y: page.bounds(for: .cropBox).maxY - 60), pageIndex: point.pageIndex)
        }
        reader.revealRuler()
    }

    private func proofEnd(of key: ReferenceKey?) -> TextPoint? {
        guard let key, let proof = analysis?.structure.proof(of: key) else { return nil }
        return proof.end
    }

    private func checkEndOfProof() {
        guard let line = reader.rulerLine, let end = proofEnd(of: debug?.top.key), debug?.finished == false else { return }
        if point(of: line) >= end { debug?.finished = true; offerUnderstood() }
    }

    private func offerUnderstood() {
        guard let session = debug, let key = session.top.key else { return }
        var actions: [LemmaNotification.Action] = []
        if !isUnderstood(key) { actions.append(.init(title: "Mark as Understood", primary: true) { [weak self] in self?.toggleUnderstood(key) }) }
        if session.frames.count > 1 { actions.append(.init(title: "Step Out", primary: false) { [weak self] in self?.debugStepOut() }) }
        else { actions.append(.init(title: "Stop", primary: false) { [weak self] in self?.stopDebugging() }) }
        notify("End of the proof of \(key.title).", source: "Run and Debug", actions: actions, timeout: 10)
    }

    private func hasQuestionMark(on line: ReaderController.RulerLine) -> Bool {
        (workspace?.notes ?? []).contains { $0.isQuickMark && $0.anchor.pageIndex == line.pageIndex && $0.anchor.region.rect.insetBy(dx: -1, dy: -2).intersects(line.rect) }
    }

    /// The first statement, equation or figure the line cites · through the book's labels, or through a PDF link's
    /// destination (books made with hyperref) · with where to go.
    private func citedTarget(on line: ReaderController.RulerLine) -> (key: ReferenceKey?, label: String, pageIndex: Int, point: CGPoint, region: CGRect?)? {
        guard let index = references else { return nil }
        let mentions = index.mentions(onPage: line.pageIndex)
            .filter { !$0.isDefinition && $0.rects.contains { $0.intersects(line.rect.insetBy(dx: 0, dy: 1)) } }
            .sorted { ($0.rects.first?.minX ?? 0) < ($1.rects.first?.minX ?? 0) }
        for mention in mentions where mention.key.kind != .citation {
            if mention.key.kind != .link, let target = analysis?.target(for: mention.key) ?? index.knownTarget(mention.key) {
                return (mention.key, mention.key.spokenTitle, target.pageIndex, CGPoint(x: target.anchor.rect.midX, y: target.region.rect.maxY - 2), target.region.rect)
            }
            if let destination = mention.destination, let page = document?.page(at: destination.pageIndex) {
                let box = page.bounds(for: .cropBox)
                let point = destination.point ?? CGPoint(x: box.midX, y: box.maxY - 72)
                // The statement that starts at the link's destination names the frame.
                let statement = analysis?.structure.statements.first { statement in
                    guard statement.start.pageIndex == destination.pageIndex, let rect = PageTextMap.bounds(of: statement.start.location, on: page) else { return false }
                    return abs(rect.maxY - point.y) < 30
                }
                let label = statement?.key.title ?? mention.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return (statement?.key, label.isEmpty ? "Link" : label, destination.pageIndex, CGPoint(x: point.x + 20, y: point.y - 6), nil)
            }
        }
        return nil
    }

    /// A region of the original page as an image, drawn once by CoreGraphics. (Drawing it through PDFKit meant switching
    /// the reader's page theme off and on around a drawing that could run at any time, and redrawing at every refresh.)
    func renderRegion(page: PDFPage, rect: CGRect, maxHeight: CGFloat) -> NSImage? {
        guard rect.width > 1, rect.height > 1, let reference = page.pageRef else { return nil }
        let cacheKey = "\(ObjectIdentifier(page).hashValue):\(rect.debugDescription):\(maxHeight)"
        if let cached = regionImages.object(forKey: cacheKey as NSString) { return cached }
        let scale = min(2.5, max(1, maxHeight * 2 / rect.height)) * 2
        let width = Int(ceil(rect.width * scale)), height = Int(ceil(rect.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        context.clip(to: reference.getBoxRect(.cropBox))
        context.drawPDFPage(reference)
        guard let rendered = context.makeImage() else { return nil }
        let image = NSImage(cgImage: rendered, size: NSSize(width: rect.width * scale / 2, height: rect.height * scale / 2))
        regionImages.setObject(image, forKey: cacheKey as NSString)
        return image
    }
}

// MARK: - The Run and Debug view

/// VS Code's Run and Debug view for a proof: Variables, Watch, Call Stack and Breakpoints.
struct DebugSidebar: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme
    @State private var newWatch = ""
    @State private var addingWatch = false

    var body: some View {
        if store.debug == nil {
            VSWelcomeView(message: store.document == nil
                          ? "Open a book to step through its proofs."
                          : "Step through a proof as through code: the reading line is the current line, F10 steps over it, F11 steps into the result it cites, ⇧F11 returns. Variables shows the statement being proved and the symbols in scope.") {
                Button("Run and Debug") { store.startDebugging() }.buttonStyle(.vsPrimary).disabled(store.document == nil)
                    .help("Start debugging the statement in view (F5)")
                if store.analysis?.analysis == nil && store.document != nil {
                    Text("Lemma is still reading the book; statements and symbols appear when it is done.").font(.ui(12)).foregroundStyle(theme[.descriptionForeground])
                }
                breakpointsList.padding(.top, 8)
            }
        } else {
            ResizableSidebarPanes(store: store, panes: [
                SidebarPane(id: "debug.variables", title: "Variables", preferredHeight: 260),
                SidebarPane(id: "debug.watch", title: "Watch", preferredHeight: 130, count: store.watchExpressions.count),
                SidebarPane(id: "debug.stack", title: "Call Stack", preferredHeight: 90, count: store.debug?.frames.count),
                SidebarPane(id: "debug.breakpoints", title: "Breakpoints", preferredHeight: 140, count: store.breakpoints.count + store.openMarks.count)
            ], fill: "debug.variables") { pane in
                switch pane.id {
                case "debug.watch":
                    VSIconButton(icon: "add", help: "Add Expression", size: 16) { addingWatch = true }
                    VSIconButton(icon: "close-all", help: "Remove All Expressions", size: 16) { store.watchExpressions = []; store.saveWorkbench() }
                case "debug.breakpoints":
                    VSIconButton(icon: "debug-breakpoint", help: "Toggle Breakpoint on the Line (F9)", size: 16) { store.toggleBreakpoint() }
                    VSIconButton(icon: "close-all", help: "Remove All Breakpoints", size: 16) { store.breakpoints = []; store.saveWorkbench() }
                default: EmptyView()
                }
            } content: { pane in
                switch pane.id {
                case "debug.variables": ScrollView { variables }
                case "debug.watch": watch
                case "debug.stack": ScrollView { callStack }
                default: ScrollView { breakpointsList }
                }
            }
        }
    }

    @ViewBuilder private var variables: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if let goal = store.debugGoal() {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Codicon("target", size: 14).foregroundStyle(theme[.debugTokenExpressionName])
                        Text("Goal").font(.ui(12, weight: .semibold)).foregroundStyle(theme[.debugTokenExpressionName])
                        Text(goal.title).font(.ui(12)).lineLimit(1)
                        Spacer(minLength: 0)
                        if let target = goal.target { VSIconButton(icon: "go-to-file", help: "Go to the Statement", size: 14) { store.goToReference(target) } }
                    }
                    if let image = goal.image {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 130, alignment: .leading)
                            .padding(4).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 3))
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(theme.border(.widgetBorder), lineWidth: 1))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            ForEach(store.debugScopes(), id: \.scope) { scope in
                DebugScopeView(store: store, title: scope.scope, variables: scope.variables)
            }
        }
    }

    private var watch: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if addingWatch {
                    VSTextField(placeholder: "Expression to watch: λ, (3.41), Theorem 2.3, a term", text: $newWatch) {
                        store.addWatch(newWatch); newWatch = ""; addingWatch = false
                    }.padding(.horizontal, 10).padding(.vertical, 4)
                }
                ForEach(store.watchExpressions, id: \.self) { expression in
                    let value = store.evaluateWatch(expression)
                    VariableRow(store: store, variable: value, depth: 1) {
                        Button("Remove Expression") { store.removeWatch(expression) }
                    }
                }
                if store.watchExpressions.isEmpty && !addingWatch {
                    Text("Add a symbol, a label such as (3.41) or a term to follow its meaning as you step.").font(.ui(12))
                        .foregroundStyle(theme[.descriptionForeground]).padding(.horizontal, 20).padding(.vertical, 6)
                }
            }
        }
    }

    private var callStack: some View {
        VStack(spacing: 0) {
            ForEach(Array((store.debug?.frames ?? []).enumerated().reversed()), id: \.element.id) { offset, frame in
                let top = offset == (store.debug?.frames.count ?? 1) - 1
                let line = top ? store.reader.rulerLine : frame.saved
                VSRow(selected: top, action: {
                    if let line { store.reader.rulerLine = line; store.reader.revealRuler() }
                }) {
                    Codicon(top ? "debug-stackframe" : "debug-stackframe-dot", size: 16)
                        .foregroundStyle(top ? theme[.debugIconBreakpointCurrentStackframeForeground] : theme[.descriptionForeground])
                        .padding(.leading, 12).padding(.trailing, 6)
                    Text(store.frameTitle(frame, line: line)).font(.ui(13)).lineLimit(1)
                    Spacer(minLength: 6)
                    if let line {
                        Text("\(store.shortPageText(line.pageIndex)):\(line.index + 1)").font(.ui(12)).monospacedDigit()
                            .foregroundStyle(top ? theme[.listActiveSelectionForeground].opacity(0.8) : theme[.descriptionForeground])
                    }
                }
            }
            if store.debug?.finished == true {
                Text("Reached the end of the proof.").font(.ui(12)).foregroundStyle(theme[.descriptionForeground]).padding(.vertical, 4)
            }
        }
    }

    private var breakpointsList: some View {
        LazyVStack(spacing: 0) {
            ForEach(store.breakpoints) { breakpoint in
                VSRow(action: { store.goToBreakpoint(breakpoint) }) {
                    VSCheckbox(isOn: Binding(get: { breakpoint.enabled }, set: { value in
                        if let index = store.breakpoints.firstIndex(where: { $0.id == breakpoint.id }) { store.breakpoints[index].enabled = value; store.saveWorkbench() }
                    })).scaleEffect(0.8).padding(.leading, 10)
                    Circle().fill(breakpoint.enabled ? theme[.debugIconBreakpointForeground] : theme[.debugIconBreakpointDisabledForeground])
                        .frame(width: 9, height: 9).padding(.horizontal, 5)
                    Text(breakpoint.text.isEmpty ? "Line" : breakpoint.text).font(.ui(13)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(store.shortPageText(breakpoint.pageIndex)).font(.ui(12)).monospacedDigit().foregroundStyle(theme[.descriptionForeground])
                }
                .contextMenu {
                    Button("Remove Breakpoint") { store.breakpoints.removeAll { $0.id == breakpoint.id }; store.saveWorkbench() }
                }
            }
            ForEach(store.openMarks) { mark in
                VSRow(action: { store.reader.go(to: mark.anchor) }) {
                    Codicon("question", size: 14).foregroundStyle(theme[.editorWarningForeground]).padding(.leading, 34).padding(.trailing, 6)
                    Text(String(mark.anchor.quote.replacingOccurrences(of: "\n", with: " ").prefix(70))).font(.ui(13)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text("p. \(mark.anchor.pageLabel)").font(.ui(12)).monospacedDigit().foregroundStyle(theme[.descriptionForeground])
                }
                .help("A “?” mark: Continue (F5) stops here")
            }
            if store.breakpoints.isEmpty && store.openMarks.isEmpty {
                Text("No breakpoints. Press F9 on a line, or mark a passage with “?” (⌥⌘/): Continue stops there.").font(.ui(12))
                    .foregroundStyle(theme[.descriptionForeground]).padding(.horizontal, 20).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct DebugScopeView: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme
    let title: String
    let variables: [DebugVariable]
    @State private var expanded = true
    var body: some View {
        VStack(spacing: 0) {
            VSRow(action: { expanded.toggle() }) {
                VSTwistie(expandable: true, expanded: expanded) { expanded.toggle() }
                Text(title).font(.ui(13)).lineLimit(1)
                Spacer(minLength: 0)
                if variables.isEmpty { Text("none").font(.ui(12)).foregroundStyle(theme[.descriptionForeground]) }
            }
            if expanded {
                ForEach(variables) { variable in VariableRow(store: store, variable: variable, depth: 2) { EmptyView() } }
            }
        }
    }
}

private struct VariableRow<Menu: View>: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme
    let variable: DebugVariable
    let depth: Int
    @ViewBuilder var menu: Menu
    var body: some View {
        VSRow(depth: depth, action: open) {
            Group {
                if variable.italicName { Text(variable.name).font(.system(size: 13.5, design: .serif).italic()) }
                else { Text(variable.name).font(.ui(13)) }
            }
            .foregroundStyle(theme[.debugTokenExpressionName])
            Text(": ").font(.ui(13)).foregroundStyle(theme[.descriptionForeground])
            Text(variable.value).font(.ui(13)).foregroundStyle(theme[.debugTokenExpressionValue]).lineLimit(1)
            Spacer(minLength: 6)
            if !variable.detail.isEmpty { Text(variable.detail).font(.ui(12)).monospacedDigit().foregroundStyle(theme[.descriptionForeground]).lineLimit(1) }
        }
        .help("\(variable.name): \(variable.value)\(variable.detail.isEmpty ? "" : " · \(variable.detail)")")
        .contextMenu {
            Button("Add to Watch") { store.addWatch(variable.name) }
            Button("Copy Value") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(variable.name): \(variable.value)", forType: .string) }
            menu
        }
    }

    private func open() {
        if let target = variable.target { store.goToReference(target) }
        else if let definition = variable.definition { store.goToSymbolDefinition(definition) }
    }
}

/// VS Code's floating debug toolbar, at the top of the editor while a proof is being debugged.
struct DebugToolbar: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: 2) {
            Codicon("gripper", size: 16).foregroundStyle(theme[.descriptionForeground]).frame(width: 14)
            VSIconButton(icon: "debug-continue", help: "Continue to the Next Breakpoint (F5)", tint: theme[.debugIconContinueForeground]) { store.debugContinue() }
            VSIconButton(icon: "debug-step-back", help: "Step Back (⇧F10)", tint: theme[.debugIconStepBackForeground]) { store.debugStepBack() }
            VSIconButton(icon: "debug-step-over", help: "Step Over: Next Line (F10)", tint: theme[.debugIconStepOverForeground]) { store.debugStepOver() }
            VSIconButton(icon: "debug-step-into", help: "Step Into the Cited Result (F11)", tint: theme[.debugIconStepIntoForeground]) { store.debugStepInto() }
            VSIconButton(icon: "debug-step-out", help: "Step Out (⇧F11)", tint: theme[.debugIconStepOutForeground]) { store.debugStepOut() }
            VSIconButton(icon: "debug-restart", help: "Restart (⇧⌘F5)", tint: theme[.debugIconRestartForeground]) { store.debugRestart() }
            VSIconButton(icon: "debug-stop", help: "Stop (⇧F5)", tint: theme[.debugIconStopForeground]) { store.stopDebugging() }
        }
        .padding(.horizontal, 4).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 4).fill(theme[.debugToolBarBackground]))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.border(.debugToolBarBorder), lineWidth: 1))
        .vsWidgetShadow(theme)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Debug toolbar")
    }
}
