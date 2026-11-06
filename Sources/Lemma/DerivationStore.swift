import AppKit
import PDFKit
import LemmaCore

/// Derivations in the store: kept with the book, opened as side tabs, checked in the background as they are edited.
@MainActor
extension StudyStore {
    func derivation(_ id: UUID) -> Derivation? { workspace?.derivations.first { $0.id == id } }

    /// Starts a derivation, from a passage when one is given, and opens it beside the page.
    @discardableResult
    func newDerivation(title: String? = nil, origin: LabSource? = nil, source: String? = nil) -> UUID? {
        guard workspace != nil else { return nil }
        let derivation = Derivation(title: title ?? origin?.label ?? "Derivation", source: source ?? derivationTemplate(for: origin), origin: origin)
        workspace?.derivations.insert(derivation, at: 0)
        flush()
        openDerivation(derivation.id)
        // The caret goes to the first empty line, ready for the first step.
        let lines = derivation.source.components(separatedBy: "\n")
        derivationFocus = (derivation.id, lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? lines.count - 1, UUID())
        status = "Write one step per line; Lemma checks each step as you type."
        return derivation.id
    }

    func openDerivation(_ id: UUID) {
        if focusMode { toggleFocus() }
        openDerivationID = id
        fitPageIfOverflowing()
        if derivationReports[id] == nil { checkDerivation(id, delay: 0) }
    }

    func updateDerivation(_ id: UUID, _ edit: (inout Derivation) -> Void) {
        guard let index = workspace?.derivations.firstIndex(where: { $0.id == id }) else { return }
        let before = workspace!.derivations[index].source
        edit(&workspace!.derivations[index])
        workspace!.derivations[index].updatedAt = .now
        scheduleSave()
        if workspace!.derivations[index].source != before {
            // The source is shared; a successful verdict in another window must not survive a changed equation.
            for window in app.windows { window.checkDerivation(id) }
        }
    }

    func deleteDerivation(_ id: UUID) {
        workspace?.derivations.removeAll { $0.id == id }
        closeSideEditor("derivation:\(id)")
        derivationReports[id] = nil
        derivationChecks[id]?.cancel(); derivationChecks[id] = nil
        flush()
    }

    /// Checks a derivation off the main thread; a newer edit cancels an older check.
    func checkDerivation(_ id: UUID, delay: Int = 180) {
        derivationChecks[id]?.cancel()
        derivationChecks[id] = nil
        derivationReports[id] = nil
        guard let source = derivation(id)?.source else { return }
        derivationChecks[id] = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            guard !Task.isCancelled else { return }
            let report = await Task.detached(priority: .userInitiated) { DerivationChecker.check(source) }.value
            guard !Task.isCancelled, let self, self.derivation(id)?.source == source else { return }
            self.derivationReports[id] = report
            self.derivationChecks[id] = nil
        }
    }

    /// Starts a derivation from the selection (or the ruler's line): named after the equation it covers, with
    /// declarations the book's notation suggests for the symbols on that page.
    func deriveSelection() {
        guard let document else { return }
        if let (pageIndex, rectangle, quote) = reader.selection, let page = document.page(at: pageIndex) {
            let label = labLabel(pageIndex: pageIndex, region: rectangle, page: page)
            newDerivation(origin: LabSource(pageIndex: pageIndex, region: PageRegion(rectangle), label: label, quote: quote))
        } else if let line = reader.rulerLine, let page = document.page(at: line.pageIndex) {
            let quote = page.selection(for: line.rect)?.string ?? ""
            newDerivation(origin: LabSource(pageIndex: line.pageIndex, region: PageRegion(line.rect.insetBy(dx: -2, dy: -3)), label: "Line \(line.index + 1) of \(shortPageText(line.pageIndex))", quote: quote))
        } else {
            newDerivation()
        }
    }

    /// The opening lines of a new derivation: what it works on, how to write it, and the sizes the book gives.
    func derivationTemplate(for origin: LabSource?) -> String {
        var lines: [String] = []
        if let origin {
            lines.append("% \(origin.label), \(shortPageText(origin.pageIndex)): one step per line, checked as you type.")
        } else {
            lines.append("% One step per line, checked as you type. A line starting with “=” continues the previous one.")
        }
        lines.append(contentsOf: notationDeclarations(near: origin?.pageIndex ?? (reader.pageNumber - 1), quote: origin?.quote))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Declarations for the symbols of a passage (or of its page) whose meaning in the book gives a size
    /// (“the N × p input matrix X”).
    func notationDeclarations(near pageIndex: Int, quote: String? = nil) -> [String] {
        guard let notation = analysis?.notation, !notation.isEmpty, let page = document?.page(at: pageIndex)?.string else { return [] }
        // The passage's own symbols when it has some the notation knows, otherwise the page's.
        let inQuote = quote.map { notation.symbols(usedIn: $0, pageIndex: pageIndex) } ?? []
        let used = inQuote.contains { DerivationTemplate.declaration(symbol: $0.symbol, meaning: $0.definition.meaning) != nil } ? inQuote : notation.symbols(usedIn: page, pageIndex: pageIndex)
        var lines: [String] = []
        var seen = Set<String>()
        for (symbol, definition, _) in used where !seen.contains(symbol) {
            seen.insert(symbol)
            guard let declaration = DerivationTemplate.declaration(symbol: symbol, meaning: definition.meaning) else { continue }
            lines.append("% \(symbol): \(definition.meaning) (\(shortPageText(definition.pageIndex)))")
            lines.append(declaration)
            if lines.count >= 8 { break }
        }
        return lines
    }

    /// Opens the displayed steps of a note's saved answer as a derivation, to check them line by line.
    func checkAnswerSteps(noteID: UUID) {
        guard let note = workspace?.notes.first(where: { $0.id == noteID }), let explanation = note.explanation else { return }
        let steps = DerivationTemplate.steps(fromAnswer: explanation.body)
        guard !steps.isEmpty else { status = "This answer has no displayed equations to check."; return }
        let origin = LabSource(pageIndex: note.anchor.pageIndex, region: note.anchor.region, label: note.title, quote: note.anchor.quote)
        var lines = ["% Steps of the saved answer to “\(note.title)”, \(explanation.savedAt.formatted(date: .abbreviated, time: .omitted)).",
                     "% Declare sizes (X \\in \\mathbb{R}^{N\\times p}) or assumptions (\\lambda > 0) above the steps if Lemma guesses wrong."]
        lines.append(contentsOf: notationDeclarations(near: note.anchor.pageIndex, quote: note.anchor.quote))
        lines.append("")
        lines.append(contentsOf: steps)
        newDerivation(title: "Check: \(note.title)", origin: origin, source: lines.joined(separator: "\n"))
    }

    /// Problems across the book's derivations, for the Problems panel and the status bar.
    var derivationProblems: [(derivation: Derivation, line: DerivationLineReport)] {
        (workspace?.derivations ?? []).flatMap { derivation in
            (derivationReports[derivation.id]?.lines ?? []).filter(\.status.isProblem).map { (derivation, $0) }
        }
    }

    /// Checks every derivation of the book once (when it opens), so the Problems panel is complete.
    func checkAllDerivations() {
        for derivation in workspace?.derivations ?? [] where derivationReports[derivation.id] == nil { checkDerivation(derivation.id, delay: 0) }
    }

    /// The derivation as Markdown for export: each step with its verdict.
    func derivationMarkdown(_ derivation: Derivation) -> String {
        let report = derivationReports[derivation.id] ?? DerivationChecker.check(derivation.source)
        var out = "# \(derivation.title)\n\n"
        if let origin = derivation.origin { out += "From \(origin.label), \(pageText(origin.pageIndex)).\n\n" }
        let lines = derivation.source.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { out += "\n"; continue }
            if trimmed.hasPrefix("%") { out += "> " + trimmed.dropFirst().trimmingCharacters(in: .whitespaces) + "\n\n"; continue }
            let verdict = report.status(ofLine: index)
            let mark: String = switch verdict {
            case .holds?: "✓"
            case .fails?, .error?: "✗"
            case .unchecked?: "?"
            default: "·"
            }
            let message = report.lines.first { $0.line == index && !$0.message.isEmpty }?.message ?? ""
            out += "\(mark) $$\(trimmed.replacingOccurrences(of: "&", with: ""))$$\n"
            if !message.isEmpty, verdict != .declaration { out += "  *\(message)*\n" }
            out += "\n"
        }
        return out
    }
}
