import AppKit
import PDFKit
import LemmaCore

/// Context the reader may add to a question about one passage. Nothing here is sent unless selected.
struct QuestionContextCandidates {
    var sourceText = ""
    var section: String?
    var cited: [CitedReference] = []
    var glossary: [StudyNote] = []
    var links: [LinkedContext] = []
    var pins: [ContextPin] = []
}

struct CitedReference: Identifiable {
    var id: ReferenceKey { target.key }
    let target: ReferenceTarget
    let png: Data
    let pageLabel: String
}

struct LinkedContext: Identifiable {
    var id: UUID { link.id }
    let link: NoteLink
    let note: StudyNote
}

/// The reader's choices. Book material defaults on; reader-created links stay opt-in.
struct ContextSelection: Equatable {
    static let maximumImages = 8
    var sourceText = true
    var section = true
    var cited: Set<ReferenceKey> = []
    var glossary: Set<UUID> = []
    var links: Set<UUID> = []
    var pins: Set<UUID> = []

    var imageCount: Int { 1 + cited.count + links.count + pins.count }

    static func defaults(for candidates: QuestionContextCandidates) -> ContextSelection {
        let preferences = LemmaPreferences.self
        var selection = ContextSelection(sourceText: preferences.flag(preferences.contextText) && !candidates.sourceText.isEmpty,
            section: preferences.flag(preferences.contextSection) && candidates.section != nil,
            cited: preferences.flag(preferences.contextCited) ? Set(candidates.cited.prefix(3).map(\.id)) : [],
            glossary: preferences.flag(preferences.contextGlossary) ? Set(candidates.glossary.map(\.id)) : [], links: [],
            pins: preferences.flag(preferences.contextPins) ? Set(candidates.pins.map(\.id)) : [])
        // Keep within the attachment limit, preferring cited material over older pins.
        while selection.imageCount > maximumImages, let pin = candidates.pins.last(where: { selection.pins.contains($0.id) })?.id { selection.pins.remove(pin) }
        return selection
    }
}

struct QuestionContent {
    var prompt: String
    var images: [(label: String, data: Data)]
}

struct QuickAskRequest: Identifiable, Equatable {
    let id = UUID()
    let workspaceID: String
    let pageIndex: Int
    let region: CGRect
    let quote: String
    static func == (lhs: QuickAskRequest, rhs: QuickAskRequest) -> Bool { lhs.id == rhs.id }
}

/// The context and help style a quick question carries into the full draft.
struct QuestionPreset {
    let noteID: UUID
    let style: QuestionStyle
    let candidates: QuestionContextCandidates
    let selection: ContextSelection
    /// A draft written for the reader (the Lab's failing cell), shown instead of the composed one.
    var prompt: String? = nil
}

@MainActor
extension StudyStore {
    /// Candidates for a passage, which need not be a saved note yet.
    func contextCandidates(pageIndex: Int, region: PageRegion, quote: String, noteID: UUID?) async -> QuestionContextCandidates {
        var candidates = QuestionContextCandidates()
        guard let workspace, let document else { return candidates }
        let workspaceID = workspace.id
        candidates.sourceText = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = references {
            candidates.section = OutlineMap.section(containing: pageIndex, y: region.y + region.height, in: index.outline)?.title
        }
        candidates.glossary = GlossaryMatcher.entries(mentionedIn: quote, from: workspace.notes, near: pageIndex, excluding: noteID)
        if let noteID {
            candidates.links = workspace.outgoingLinks(from: noteID).compactMap { link in
                workspace.notes.first { $0.id == link.targetNoteID }.map { LinkedContext(link: link, note: $0) }
            }
        }
        candidates.pins = workspace.pins
        guard let index = references else { return candidates }
        var seen = Set<ReferenceKey>()
        for mention in ReferenceScanner.mentions(in: quote) where seen.insert(mention.key).inserted {
            guard let target = await index.resolve(mention.key, from: pageIndex), self.workspace?.id == workspaceID else { continue }
            // A selected equation contains its own label; that is the source, not a citation.
            if target.pageIndex == pageIndex, target.region.rect.intersects(region.rect) { continue }
            guard let page = document.page(at: target.pageIndex), let png = try? PDFRegionRenderer.png(page: page, region: target.region) else { continue }
            candidates.cited.append(CitedReference(target: target, png: png, pageLabel: printedLabel(for: target.pageIndex) ?? ""))
            if candidates.cited.count >= 6 { break }
        }
        return candidates
    }

    func composition(note: StudyNote, style: QuestionStyle, candidates: QuestionContextCandidates, selection: ContextSelection) -> QuestionComposition {
        var composition = QuestionComposition(bookTitle: questionBookTitle, section: selection.section ? candidates.section : nil,
                                              note: note, sourceText: selection.sourceText ? candidates.sourceText : nil, style: style)
        composition.bookAuthors = bookAuthors
        // Printed numbers come from the book's analysis or the PDF's labels; none means the PDF's numbering is the book's.
        composition.printedPage = printedLabel(for: note.anchor.pageIndex) ?? ""
        composition.cited = candidates.cited.filter { selection.cited.contains($0.id) }.map {
            .init(title: $0.target.key.spokenTitle, pageIndex: $0.target.pageIndex, pageLabel: $0.pageLabel)
        }
        composition.glossary = candidates.glossary.filter { selection.glossary.contains($0.id) }.map(QuestionComposition.GlossaryEntry.init)
        composition.linked = candidates.links.filter { selection.links.contains($0.id) }.map {
            .init(title: "\($0.link.kind.label): \($0.note.title)", pageIndex: $0.note.anchor.pageIndex,
                  pageLabel: printedLabel(for: $0.note.anchor.pageIndex) ?? "", note: $0.link.usage)
        }
        composition.pins = candidates.pins.filter { selection.pins.contains($0.id) }.map {
            .init(title: $0.label, pageIndex: $0.anchor.pageIndex, pageLabel: printedLabel(for: $0.anchor.pageIndex) ?? "")
        }
        return composition
    }

    /// The book as a question names it: its title in Lemma, without a file extension, and the title in the PDF's
    /// metadata when that says more (“ISLP (An Introduction to Statistical Learning)”).
    var questionBookTitle: String {
        guard let workspace else { return "" }
        var title = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.lowercased().hasSuffix(".pdf") { title = String(title.dropLast(4)) }
        let metadata = DocumentTitle.fromMetadata(document?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
                                                  fileName: URL(fileURLWithPath: workspace.sourcePath).lastPathComponent)
        if let metadata, metadata.range(of: title, options: [.caseInsensitive, .diacriticInsensitive]) == nil,
           title.range(of: metadata, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
            return title.isEmpty ? metadata : "\(title) (\(metadata))"
        }
        return title
    }

    /// The authors named in the PDF's metadata, unless the field holds a tool's or an account's name.
    var bookAuthors: String? {
        guard let raw = document?.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String else { return nil }
        let authors = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = authors.lowercased()
        let placeholders: Set<String> = ["user", "admin", "administrator", "owner", "unknown", "author", "authors", "anonymous", "none"]
        guard (3...160).contains(authors.count), authors.contains(where: \.isLetter), !placeholders.contains(lower),
              !["\\", "{", "@", ".tex", "latex", "microsoft", "acrobat", "http"].contains(where: { lower.contains($0) }) else { return nil }
        return authors
    }

    /// Reads the chosen images in the order the composition lists them.
    func questionContent(note: StudyNote, style: QuestionStyle, candidates: QuestionContextCandidates, selection: ContextSelection, prompt: String? = nil) throws -> QuestionContent {
        guard let workspace else { throw BridgeError.invalidImage }
        let composition = composition(note: note, style: style, candidates: candidates, selection: selection)
        func asset(_ anchor: SourceAnchor) throws -> Data { try Data(contentsOf: repository.assetURL(workspaceID: workspace.id, name: anchor.imageName)) }
        var images: [Data] = [try asset(note.anchor)]
        images += candidates.cited.filter { selection.cited.contains($0.id) }.map(\.png)
        images += try candidates.links.filter { selection.links.contains($0.id) }.map { try asset($0.note.anchor) }
        images += try candidates.pins.filter { selection.pins.contains($0.id) }.map { try asset($0.anchor) }
        return QuestionContent(prompt: prompt ?? composition.prompt, images: Array(zip(composition.imageLabels, images)).map { ($0.0, $0.1) })
    }

    /// Hands the chosen context to the selected provider; the answer returns to this source note.
    func askWeb(mode: WebQuestionMode, content: QuestionContent, noteID: UUID, provider: QuestionProvider? = nil) {
        guard let note = workspace?.notes.first(where: { $0.id == noteID }), note.pendingRequestID == nil,
              !note.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard content.images.count <= ContextSelection.maximumImages else {
            error = "Choose at most \(ContextSelection.maximumImages) images for one question."; return
        }
        var images: [BrowserImage] = []
        var data: [String: Data] = [:]
        for (index, image) in content.images.enumerated() {
            let name = "source-\(index + 1).png"
            data[name] = image.data
            images.append(BrowserImage(name: name, label: image.label, byteCount: image.data.count))
        }
        let selected = provider ?? questions.provider
        handOff(BrowserPacket(noteID: noteID, mode: selected == .chatGPTWeb ? mode : .askAndSave, prompt: content.prompt, images: images, provider: selected, workspaceID: workspace?.id), imageData: data)
    }

    func prepareQuickAsk() {
        guard let workspace, let (pageIndex, region, quote) = reader.selection, reader.hasSelection else {
            error = "Select text or capture a region first, then ask about it."; return
        }
        definitionLookup = nil; referencePeek = nil
        quickAsk = QuickAskRequest(workspaceID: workspace.id, pageIndex: pageIndex, region: region, quote: quote)
        if let quickAsk { reader.view?.presentQuickAsk(quickAsk, store: self) }
    }

    /// Saves the passage as a question note. Quick questions keep the reader's layout.
    @discardableResult
    func createQuestionNote(from request: QuickAskRequest, question: String) -> StudyNote? {
        guard workspace?.id == request.workspaceID, let document, let page = document.page(at: request.pageIndex) else { return nil }
        do {
            let region = PageRegion(request.region)
            let data = try PDFRegionRenderer.png(page: page, region: region)
            let name = "\(UUID().uuidString).png"
            try repository.saveImage(data, workspaceID: request.workspaceID, name: name)
            let anchor = SourceAnchor(pageIndex: request.pageIndex, pageLabel: page.label ?? String(request.pageIndex + 1), region: region, quote: request.quote, imageName: name)
            let note = StudyNote(anchor: anchor, question: question)
            workspace?.notes.insert(note, at: 0)
            if let bookID = self.workspace?.id { registerNoteCreationUndo(note, bookID: bookID) }
            selectedNoteID = note.id
            if showStudy { studySection = .notes }
            noteQuery = ""; noteFilter = .all
            flush()
            return saveFailed ? nil : note
        } catch {
            self.error = "Could not save this passage: \(error.localizedDescription)"
            return nil
        }
    }

    func sendQuickAsk(_ request: QuickAskRequest, question: String, style: QuestionStyle, candidates: QuestionContextCandidates, selection: ContextSelection, mode: WebQuestionMode, provider: QuestionProvider? = nil) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let note = createQuestionNote(from: request, question: text.isEmpty ? style.defaultQuestion : text) else { return }
        quickAsk = nil
        do { askWeb(mode: mode, content: try questionContent(note: note, style: style, candidates: candidates, selection: selection), noteID: note.id, provider: provider) }
        catch { self.error = "Could not prepare the question: \(error.localizedDescription)" }
    }

    func openFullDraft(_ request: QuickAskRequest, question: String, style: QuestionStyle, candidates: QuestionContextCandidates, selection: ContextSelection) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let note = createQuestionNote(from: request, question: text.isEmpty ? style.defaultQuestion : text) else { return }
        quickAsk = nil
        questionPreset = QuestionPreset(noteID: note.id, style: style, candidates: candidates, selection: selection)
        showQuestion = true
    }
}
