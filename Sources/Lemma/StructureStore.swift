import AppKit
import PDFKit
import LemmaCore

/// Which way the Hierarchy panel looks from an object: what its text uses, or what uses it.
enum HierarchyDirection: String, Codable, CaseIterable, Identifiable {
    case uses, usedBy
    var id: String { rawValue }
    var title: String { self == .uses ? "Uses" : "Used By" }
    var symbol: String { self == .uses ? "arrow.up.right" : "arrow.down.left" }
}

/// The statement under the reading position (see `StudyStore.readingStatement()`).
struct ReadingStatement: Equatable {
    let statement: StatementInfo
    let inProof: Bool
    let headVisible: Bool
    var label: String { (inProof ? "Proof of " : "") + statement.key.title }
}

/// What the dependency map shows: a chapter's statements (or sections), or one statement with what it rests on.
struct MapRequest: Codable, Equatable, Identifiable {
    enum Scope: Codable, Equatable { case chapter(String), prerequisites(ReferenceKey) }
    var id = UUID()
    var scope: Scope
}

@MainActor
extension StudyStore {
    // MARK: Proofs

    var proofs: [ProofBlock] { analysis?.structure.proofs ?? [] }
    var allProofsFolded: Bool {
        let folded = Set(workspace?.foldedProofs ?? [])
        return !proofs.isEmpty && proofs.allSatisfy { folded.contains($0.stableID) }
    }

    func isFolded(_ proof: ProofBlock) -> Bool { workspace?.foldedProofs.contains(proof.stableID) == true }

    /// Folds or unfolds one proof, as an editor folds a block.
    func toggleProof(_ id: String) {
        guard workspace != nil else { return }
        if let index = workspace?.foldedProofs.firstIndex(of: id) { workspace?.foldedProofs.remove(at: index) }
        else { workspace?.foldedProofs.append(id) }
        scheduleSave()
    }

    /// Folds every proof in the book: read the statements, try each proof first. Unfolds them all when every one is folded.
    func toggleAllProofs() {
        guard workspace != nil, !proofs.isEmpty else { return }
        // Read before writing: `allProofsFolded` reads the workspace, which the assignment is modifying.
        let fold = !allProofsFolded
        let ids = fold ? proofs.map(\.stableID) : []
        workspace?.foldedProofs = ids
        status = fold ? "Proofs folded: read each statement and try its proof first. Click a folded proof to open it." : "Proofs unfolded."
        scheduleSave()
    }

    // MARK: Questions for later

    /// Open “?” marks: questions saved without asking, to come back to · an editor's TODO list for reading.
    var openMarks: [StudyNote] {
        (workspace?.notes ?? []).filter { $0.kind == .question && $0.state == .open && $0.explanation == nil && $0.pendingRequestID == nil && $0.isQuickMark }
            .sorted { $0.anchor.pageIndex == $1.anchor.pageIndex ? $0.anchor.region.y > $1.anchor.region.y : $0.anchor.pageIndex < $1.anchor.pageIndex }
    }

    /// Marks the ruler's line, or the selection, as not understood and keeps reading: a question note without a question yet.
    func markUnclear() {
        if reader.rulerMode, let line = reader.rulerLine, let page = document?.page(at: line.pageIndex), !reader.hasSelection {
            let region = line.rect.insetBy(dx: -4, dy: -3).intersection(page.bounds(for: .cropBox))
            reader.selection = (line.pageIndex, region, page.selection(for: region)?.string ?? "")
            reader.hasSelection = true
        }
        guard reader.hasSelection, let anchor = try? capture() else { status = "Select a passage, or put the ruler on a line, to mark it."; return }
        var note = StudyNote(anchor: anchor, question: StudyNote.quickMarkPrefix, kind: .question)
        note.body = ""
        workspace?.notes.insert(note, at: 0)
        if let bookID = self.workspace?.id { registerNoteCreationUndo(note, bookID: bookID) }
        reader.selection = nil; reader.hasSelection = false
        reader.view?.clearSelection()
        flush()
        status = "Marked “?” on \(shortPageText(anchor.pageIndex)) · \(openMarks.count) open. Keep reading; ⌥⌘J goes back to the first."
    }

    /// Goes to the earliest open “?” mark.
    func resumeAtFirstMark() {
        guard let first = openMarks.first else { status = "No open “?” marks."; return }
        if activeFileName != nil || activeSpecial != nil || panelMaximized, let id = workspace?.id {
            panelMaximized = false; openBook(id, atPage: first.anchor.pageIndex)
            whenShowing(id) { store in
                store.reader.go(to: first.anchor)
                store.reader.flash(first.anchor.region.rect, onPage: first.anchor.pageIndex)
            }
            return
        }
        reader.go(to: first.anchor)
        reader.flash(first.anchor.region.rect, onPage: first.anchor.pageIndex)
    }

    // MARK: Understanding

    func isUnderstood(_ key: ReferenceKey) -> Bool { workspace?.understood.contains(key) == true }

    func toggleUnderstood(_ key: ReferenceKey) {
        guard workspace != nil else { return }
        if let index = workspace?.understood.firstIndex(of: key) { workspace?.understood.remove(at: index) }
        else { workspace?.understood.append(key) }
        scheduleSave()
    }

    // MARK: Statements

    /// Lines of a page's text with their rectangles, kept for the pages read most recently.
    func pageTextMap(_ pageIndex: Int) -> PageTextMap? {
        guard let page = document?.page(at: pageIndex), let id = workspace?.id else { return nil }
        let key = "\(id)#\(pageIndex)"
        if let cached = PageTextMaps.shared.value(for: key) { return cached }
        let map = PageTextMap(page: page)
        PageTextMaps.shared.insert(map, for: key)
        return map
    }

    /// Where the text at the reading position starts on its page: the offset that statements and proofs are found by.
    private func focusTextPoint() -> TextPoint? {
        guard let page = document?.page(at: reader.focusPageIndex) else { return nil }
        let y = reader.focusY ?? page.bounds(for: .cropBox).maxY
        guard let location = pageTextMap(reader.focusPageIndex)?.firstLine(atOrBelow: y)?.range.location else { return nil }
        return TextPoint(pageIndex: reader.focusPageIndex, location: location)
    }

    /// The statement whose text or proof contains the reading position, if any.
    func statementAtFocus() -> StatementInfo? {
        guard !reader.isScrubbing, analysis?.analysis?.structure.statements.isEmpty == false, let point = focusTextPoint() else { return nil }
        return statement(containing: point)
    }

    /// The statement a point of the text belongs to, through its proof when the point is in one.
    func statement(containing point: TextPoint) -> StatementInfo? {
        guard let structure = analysis?.analysis?.structure else { return nil }
        if let proof = structure.proofs.last(where: { $0.start <= point && point < $0.end }), let key = proof.statement {
            return structure.statement(key)
        }
        return structure.statements.last { $0.start <= point && point < $0.end }
    }

    /// The statement being read, whether the reading position is in its proof, and whether its label is on screen:
    /// for the breadcrumb and for the sticky header that keeps a long proof's statement in view. The statement depends
    /// only on the text line at the reading position and is cached per line; whether its label is on screen changes as
    /// the page scrolls and is measured on each call (one rectangle conversion).
    func readingStatement() -> ReadingStatement? {
        guard !reader.isScrubbing, analysis?.analysis?.structure.statements.isEmpty == false, let point = focusTextPoint() else { return nil }
        let cacheKey = "\(workspace?.id ?? "")|\(point.pageIndex)|\(point.location)|\(analysis?.analysis?.analyzedAt.timeIntervalSince1970 ?? 0)"
        let found: (statement: StatementInfo, inProof: Bool)?
        if let cache = readingStatementCache, cache.key == cacheKey {
            found = cache.value.map { ($0.statement, $0.inProof) }
        } else {
            found = statement(containing: point).map { statement in
                let proof = statement.proof.flatMap { id in analysis?.structure.proofs.first { $0.id == id } }
                return (statement, proof.map { $0.start <= point && point < $0.end } ?? false)
            }
            readingStatementCache = (cacheKey, found.map { ReadingStatement(statement: $0.statement, inProof: $0.inProof, headVisible: false) })
        }
        guard let found else { return nil }
        var headVisible = false
        if let target = analysis?.target(for: found.statement.key), let view = reader.view, let page = document?.page(at: target.pageIndex),
           reader.visiblePageRange?.contains(target.pageIndex) ?? view.visiblePages.contains(page) {
            headVisible = view.bounds.intersects(view.convert(target.anchor.rect, from: page))
        }
        return ReadingStatement(statement: found.statement, inProof: found.inProof, headVisible: headVisible)
    }

    /// Publishes the outline path and the statement at the reading position on the reader when they change, paced by the
    /// reader with its line. Asked for after each viewport update, and again whenever the outline, the analysis or the
    /// book changes under a still page.
    func refreshReadingFocus() {
        reader.publishFocus()
        watchFocusInputs()
    }

    func publishReadingFocus() {
        let path = document == nil ? [] : breadcrumb()
        if path.map(\.id) != reader.focusPath.map(\.id) || path.map(\.title) != reader.focusPath.map(\.title) { reader.focusPath = path; QAPerf.tick("publish.focusPath") }
        let statement = analysis?.analysis == nil ? nil : readingStatement()
        let published = statement.map { ReadingStatement(statement: $0.statement, inProof: $0.inProof, headVisible: false) }
        if published != reader.focusStatement { reader.focusStatement = published; QAPerf.tick("publish.focusStatement") }
        if (statement?.headVisible ?? false) != reader.focusLabelVisible { reader.focusLabelVisible = statement?.headVisible ?? false; QAPerf.tick("publish.focusLabelVisible") }
    }

    /// Re-publishes the focus when what it is computed from changes without a scroll (an outline built by the analysis,
    /// the analysis finishing, another book). The observation fires once; it is renewed by the refresh it schedules.
    func watchFocusInputs() {
        guard !reader.watchesFocusInputs else { return }
        reader.watchesFocusInputs = true
        withObservationTracking {
            _ = outline.count
            _ = analysis?.analysis?.analyzedAt
            _ = document
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reader.watchesFocusInputs = false
                self.refreshReadingFocus()
            }
        }
    }

    /// Opens the Hierarchy panel on an object: what its statement and proof use, or what uses it.
    func showHierarchy(_ key: ReferenceKey, direction: HierarchyDirection? = nil) {
        if focusMode { toggleFocus() }
        hierarchyKey = key
        if let direction { hierarchyDirection = direction }
        panelTab = .hierarchy
        showPanel = true
    }

    /// The reading position's statement, or the current section, in the Hierarchy panel.
    func showHierarchyAtFocus() {
        if let statement = statementAtFocus() { showHierarchy(statement.key); return }
        if let section = breadcrumb().last.flatMap({ OutlineMap.numberPrefix(of: $0.title) }) {
            showHierarchy(ReferenceKey(kind: section.contains(".") ? .section : .chapter, number: section), direction: .uses)
            return
        }
        status = "Place the reading position inside a numbered statement or section to see what it uses."
    }

    /// Goes to a statement, equation, figure or section, with Back available.
    func goToKey(_ key: ReferenceKey) {
        if let target = analysis?.target(for: key) ?? references?.knownTarget(key) { goToReference(target); return }
        if key.kind == .section || key.kind == .chapter, let entry = outline.flatMap(\.flattened).first(where: { OutlineMap.numberPrefix(of: $0.title) == key.number }),
           let pageIndex = entry.pageIndex, let id = workspace?.id {
            panelMaximized = false
            openBook(id, atPage: pageIndex)
        }
    }

    /// Opens a target to the side of the page.
    func openKeyToTheSide(_ key: ReferenceKey) {
        if let target = analysis?.target(for: key) ?? references?.knownTarget(key) { openToSide(target) }
    }

    /// The dependency map for the current chapter, or for one statement's prerequisites.
    func showMap(for key: ReferenceKey? = nil) {
        guard document != nil else { return }
        if let key { openMap = MapRequest(scope: .prerequisites(key)); return }
        let chapter = breadcrumb().first.flatMap { OutlineMap.numberPrefix(of: $0.title) } ?? currentChapterNumber() ?? "1"
        openMap = MapRequest(scope: .chapter(chapter))
    }

    /// The chapter number of the page in view, from numbered statements and sections when the outline has no numbers.
    func currentChapterNumber() -> String? {
        let page = reader.focusPageIndex
        guard let definitions = analysis?.analysis?.definitions else { return nil }
        let before = definitions.filter { $0.pageIndex <= page && $0.key.number.contains(".") && [.theorem, .section, .equation].contains($0.key.kind) }
        return before.max { $0.pageIndex < $1.pageIndex }.map { String($0.key.number.prefix { $0 != "." }) }
    }

    func closeMap() { openMap = nil }

    /// Recall cards for several statements at once (a chapter's definitions, say), skipping those already in Review.
    func addStatementsToReview(_ keys: [ReferenceKey]) {
        let existing = Set((workspace?.notes ?? []).filter(\.isInReview).map(\.question))
        var added = 0
        for key in keys {
            let title = analysis?.structure.statement(key)?.title
            let question = key.title + (title.map { " (\($0))" } ?? "")
            guard !existing.contains(question) else { continue }
            addStatementToReview(key, quietly: true)
            added += 1
        }
        flush()
        status = added == 0 ? "Those statements are already in Review." : "\(added) \(added == 1 ? "statement" : "statements") added to Review · ⇧⌘R to recall them."
    }

    /// A recall note for a statement: its region as the source, “State Theorem 2.3 (Gauss–Markov)” as the prompt.
    func addStatementToReview(_ key: ReferenceKey, quietly: Bool = false) {
        guard let target = analysis?.target(for: key), let document, let page = document.page(at: target.pageIndex), let workspace else { return }
        do {
            let region = target.region
            let data = try PDFRegionRenderer.png(page: page, region: region)
            let name = "\(UUID().uuidString).png"
            try repository.saveImage(data, workspaceID: workspace.id, name: name)
            let quote = page.selection(for: region.rect)?.string ?? ""
            let title = analysis?.structure.statement(key)?.title
            let anchor = SourceAnchor(pageIndex: target.pageIndex, pageLabel: page.label ?? String(target.pageIndex + 1), region: region, quote: quote, imageName: name)
            var note = StudyNote(anchor: anchor, question: key.title + (title.map { " (\($0))" } ?? ""),
                                 kind: key.name == "Definition" ? .definition : .theorem)
            note.recallPrompt = key.name == "Definition" ? "State the definition: \(key.title)\(title.map { " · \($0)" } ?? "")."
                : "State \(key.title)\(title.map { " (\($0))" } ?? "") and its hypotheses."
            note.review = ReviewSchedule(dueAt: .now)
            self.workspace?.notes.insert(note, at: 0)
            if let bookID = self.workspace?.id { registerNoteCreationUndo(note, bookID: bookID) }
            if quietly { return }
            selectedNoteID = note.id
            flush()
            status = "\(key.title) added to Review."
        } catch { self.error = "Could not add \(key.title) to Review: \(error.localizedDescription)" }
    }

    /// Goes to the sentence that says what a symbol stands for, outlined briefly, with Back available.
    func goToSymbolDefinition(_ definition: SymbolDefinition) {
        guard let page = document?.page(at: definition.pageIndex) else { return }
        if activeFileName != nil || activeSpecial != nil || panelMaximized, let id = workspace?.id {
            panelMaximized = false; openBook(id, atPage: definition.pageIndex)
            whenShowing(id) { $0.goToSymbolDefinition(definition) }
            return
        }
        let length = min(80, max(1, ((page.string ?? "") as NSString).length - definition.location))
        guard let selection = page.selection(for: NSRange(location: definition.location, length: length)) else { reader.goToPage(definition.pageIndex + 1); return }
        let rect = selection.selectionsByLine().first?.bounds(for: page) ?? selection.bounds(for: page)
        reader.view?.go(to: PDFDestination(page: page, at: CGPoint(x: rect.minX, y: min(rect.maxY + 60, page.bounds(for: .cropBox).maxY))))
        reader.flash(rect.insetBy(dx: -3, dy: -2), onPage: definition.pageIndex)
    }

    /// Opens a `lemma://open?book=…&ref=…` or `&page=…` link: the book in its tab, then the object or page.
    func openLink(_ url: URL) {
        // PDFs opened from Finder, dropped on the Dock icon or sent by another app ("Open With").
        if url.isFileURL {
            guard url.pathExtension.lowercased() == "pdf" else { return }
            if restored { open(url) } else { pendingFileOpens.append(url) }
            return
        }
        guard url.scheme == "lemma", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let items = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        if components.host == "arxiv" {
            guard let id = items["id"], ArxivIdentifier.parse(id) == id else { error = "This arXiv link has an invalid identifier."; return }
            openArxiv(id); return
        }
        guard let book = items["book"], let saved = library.first(where: { $0.id == book }) else {
            error = "This link names a book that is not in your Lemma library on this Mac."; return
        }
        if workspace?.id != book { reopen(saved) }
        let reference = items["ref"]
        let page = items["page"].flatMap(Int.init)
        // Once the book is in front and its page view shows it (after its open, however long the file takes to read);
        // nothing moves when it could not be opened or another book took its place.
        whenShowing(book) { store in
            guard let reference, let key = ReferenceScanner.mentions(in: reference).first?.key else {
                if let page { store.reader.goToPage(page) }
                return
            }
            Task { @MainActor [weak store] in
                // An object needs the book's analysis: read from its cache in a moment, or made on first opening.
                for _ in 0..<200 {
                    guard let store, store.workspace?.id == book else { return }
                    if store.analysis?.analysis != nil || store.analysis?.isAnalyzing == false && store.analysis?.isLoadingCache == false { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard let store, store.workspace?.id == book else { return }
                store.goToKey(store.analysis?.resolver.resolve(key) ?? key)
            }
        }
    }

    /// A `lemma://` link to an object of this book, for notes in other apps.
    func copyLink(to key: ReferenceKey) {
        guard let workspace else { return }
        var components = URLComponents()
        components.scheme = "lemma"; components.host = "open"
        components.queryItems = [URLQueryItem(name: "book", value: workspace.id), URLQueryItem(name: "ref", value: key.kind == .equation ? "Eq. \(key.title)" : key.title)]
        guard let url = components.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        status = "Link to \(key.title) copied."
    }
}
