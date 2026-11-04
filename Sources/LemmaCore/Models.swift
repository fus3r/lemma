import Foundation

public struct PageRegion: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct SourceAnchor: Codable, Equatable, Sendable {
    public var pageIndex: Int
    public var pageLabel: String
    public var region: PageRegion
    public var quote: String
    public var imageName: String
    public init(pageIndex: Int, pageLabel: String, region: PageRegion, quote: String, imageName: String) {
        self.pageIndex = pageIndex; self.pageLabel = pageLabel
        self.region = region; self.quote = quote; self.imageName = imageName
    }
}

public struct SavedExplanation: Codable, Equatable, Sendable {
    public var body: String
    public var conversationURL: String?
    public var provider: QuestionProvider?
    public var model: String?
    public var savedAt: Date
    public init(body: String, conversationURL: String? = nil, savedAt: Date = .now, provider: QuestionProvider? = nil, model: String? = nil) {
        self.body = body; self.conversationURL = conversationURL; self.savedAt = savedAt
        self.provider = provider; self.model = model
    }

    private enum CodingKeys: String, CodingKey { case body, conversationURL, provider, model, savedAt, service }

    /// Lemma 2.x decodes `provider` with only its three providers and rejects any other value, which would make the
    /// whole book unreadable after a downgrade. Providers added later are written under `service`, which older
    /// versions ignore; an unknown value in either key reads as “no provider” instead of failing.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        body = try container.decode(String.self, forKey: .body)
        conversationURL = try container.decodeIfPresent(String.self, forKey: .conversationURL)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        let raw = try container.decodeIfPresent(String.self, forKey: .service) ?? container.decodeIfPresent(String.self, forKey: .provider)
        provider = raw.flatMap(QuestionProvider.init(rawValue:))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(body, forKey: .body)
        try container.encodeIfPresent(conversationURL, forKey: .conversationURL)
        if let provider { try container.encode(provider.rawValue, forKey: provider.kind == .api ? .service : .provider) }
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(savedAt, forKey: .savedAt)
    }
}

public struct StudyNote: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var anchor: SourceAnchor
    public var question: String
    public var body: String
    public var explanation: SavedExplanation?
    public var pendingRequestID: UUID?
    public var createdAt: Date
    public var kind: NoteKind
    public var state: NoteState
    public var assumptions: String
    public var notation: String
    public var scope: String
    public var lookupTerms: String = ""
    public var reviewAnswer: String
    public var reviewCount: Int
    public var lastReviewedAt: Date?
    public var sourceTextOrigin: SourceTextOrigin?
    public var experiments: [ExperimentRecord] = []
    /// Present while the note is in the review deck.
    public var review: ReviewSchedule?
    /// An optional question to answer from memory, such as “Why does the optimum lie on an axis?”.
    public var recallPrompt: String = ""
    /// Parts of the source hidden during recall (cloze), in PDF page coordinates inside the anchor.
    public var masks: [PageRegion] = []
    /// An image shown with the note in the margin, such as a figure made in the Lab (schema 8).
    public var figureName: String?
    public init(id: UUID = UUID(), anchor: SourceAnchor, question: String = "", body: String = "", kind: NoteKind = .question) {
        self.id = id; self.anchor = anchor; self.question = question; self.body = body
        self.createdAt = .now
        self.kind = kind; self.state = .open; self.assumptions = ""; self.notation = ""; self.scope = ""
        self.reviewAnswer = ""; self.reviewCount = 0
    }

    /// A “?” mark: a passage saved as not understood, to come back to; its question starts with this prefix.
    public static let quickMarkPrefix = "?"
    public var isQuickMark: Bool { question.trimmingCharacters(in: .whitespaces) == Self.quickMarkPrefix }

    public var title: String {
        if isQuickMark {
            let quote = anchor.quote.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return "? " + (quote.isEmpty ? "page \(anchor.pageLabel)" : String(quote.prefix(80)))
        }
        if !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return question }
        // A margin note is titled by its first line, as a pencilled remark would be read.
        if kind == .comment, let line = body.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) {
            return String(line.prefix(90))
        }
        return "\(kind.label) · page \(anchor.pageLabel)"
    }
    public func matches(_ query: String) -> Bool {
        let text = [question, body, anchor.quote, explanation?.body ?? "", assumptions, notation, scope, lookupTerms, recallPrompt].joined(separator: "\n")
        return query.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace)
            .allSatisfy { text.localizedStandardContains(String($0)) }
    }
    private enum CodingKeys: String, CodingKey {
        case id, anchor, question, body, explanation, pendingRequestID, createdAt, kind, state, assumptions, notation, scope, lookupTerms, reviewAnswer, reviewCount, lastReviewedAt, sourceTextOrigin, experiments, review, recallPrompt, masks, figureName
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); anchor = try c.decode(SourceAnchor.self, forKey: .anchor)
        question = try c.decode(String.self, forKey: .question); body = try c.decode(String.self, forKey: .body)
        explanation = try c.decodeIfPresent(SavedExplanation.self, forKey: .explanation)
        pendingRequestID = try c.decodeIfPresent(UUID.self, forKey: .pendingRequestID)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        kind = try c.decodeIfPresent(NoteKind.self, forKey: .kind) ?? .question
        state = try c.decodeIfPresent(NoteState.self, forKey: .state) ?? .open
        assumptions = try c.decodeIfPresent(String.self, forKey: .assumptions) ?? ""
        notation = try c.decodeIfPresent(String.self, forKey: .notation) ?? ""
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? ""
        lookupTerms = try c.decodeIfPresent(String.self, forKey: .lookupTerms) ?? ""
        reviewAnswer = try c.decodeIfPresent(String.self, forKey: .reviewAnswer) ?? ""
        reviewCount = try c.decodeIfPresent(Int.self, forKey: .reviewCount) ?? 0
        lastReviewedAt = try c.decodeIfPresent(Date.self, forKey: .lastReviewedAt)
        sourceTextOrigin = try c.decodeIfPresent(SourceTextOrigin.self, forKey: .sourceTextOrigin)
        experiments = try c.decodeIfPresent([ExperimentRecord].self, forKey: .experiments) ?? []
        review = try c.decodeIfPresent(ReviewSchedule.self, forKey: .review)
        recallPrompt = try c.decodeIfPresent(String.self, forKey: .recallPrompt) ?? ""
        masks = try c.decodeIfPresent([PageRegion].self, forKey: .masks) ?? []
        figureName = try c.decodeIfPresent(String.self, forKey: .figureName)
    }
}

public enum NoteKind: String, Codable, CaseIterable, Sendable {
    case question, definition, notation, theorem, comment
    public var label: String {
        switch self {
        case .question: "Question"; case .definition: "Definition"; case .notation: "Notation"; case .theorem: "Theorem"; case .comment: "Margin note"
        }
    }
    public var symbol: String {
        switch self {
        case .question: "questionmark.bubble"; case .definition: "text.book.closed"; case .notation: "function"; case .theorem: "checkmark.seal"
        case .comment: "note.text"
        }
    }
    /// Definitions, notation and theorems form the reader's glossary; questions and margin notes do not.
    public var isGlossary: Bool { self == .definition || self == .notation || self == .theorem }
}

public enum NoteState: String, Codable, CaseIterable, Sendable {
    case open, understood, revisit
    public var label: String { switch self { case .open: "Open"; case .understood: "Understood"; case .revisit: "Revisit" } }
    public var symbol: String { switch self { case .open: "circle"; case .understood: "checkmark.circle.fill"; case .revisit: "arrow.clockwise.circle" } }
}

public enum ReadingLayout: String, Codable, CaseIterable, Sendable {
    case singlePage, continuous, twoPages, twoPagesContinuous
    public var label: String {
        switch self { case .singlePage: "Single Page"; case .continuous: "Continuous"; case .twoPages: "Two Pages"; case .twoPagesContinuous: "Two Pages Continuous" }
    }
    /// Books the reader has not set a layout for scroll continuously, as an editor does.
    public static let standard: ReadingLayout = .continuous
}

public struct ReadingBookmark: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var pageIndex: Int
    public var pageLabel: String
    public var title: String
    public var positionX: Double?
    public var positionY: Double?
    public init(id: UUID = UUID(), pageIndex: Int, pageLabel: String, title: String, positionX: Double? = nil, positionY: Double? = nil) {
        self.id = id; self.pageIndex = pageIndex; self.pageLabel = pageLabel; self.title = title
        self.positionX = positionX; self.positionY = positionY
    }
}

public enum HighlightColor: String, Codable, CaseIterable, Sendable {
    case yellow, green, blue, rose
    public var label: String { rawValue.capitalized }
}

/// How a mark is drawn: a highlighter stroke over the line, or a pencil line under it.
public enum HighlightStyle: String, Codable, CaseIterable, Sendable {
    case highlight, underline
    public var label: String { self == .highlight ? "Highlight" : "Underline" }
}

public struct StudyHighlight: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var pageIndex: Int
    public var regions: [PageRegion]
    public var quote: String
    public var color: HighlightColor
    /// A custom sRGB color, saved beside the original preset so older versions can still open the workspace.
    public var colorHex: String?
    public var style: HighlightStyle = .highlight
    public init(id: UUID = UUID(), pageIndex: Int, regions: [PageRegion], quote: String, color: HighlightColor = .yellow, style: HighlightStyle = .highlight, colorHex: String? = nil) {
        self.id = id; self.pageIndex = pageIndex; self.regions = regions; self.quote = quote; self.color = color; self.style = style
        self.colorHex = colorHex
    }
    private enum CodingKeys: String, CodingKey { case id, pageIndex, regions, quote, color, style, colorHex }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); pageIndex = try c.decode(Int.self, forKey: .pageIndex)
        regions = try c.decode([PageRegion].self, forKey: .regions); quote = try c.decode(String.self, forKey: .quote)
        color = try c.decode(HighlightColor.self, forKey: .color)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        style = try c.decodeIfPresent(HighlightStyle.self, forKey: .style) ?? .highlight
    }
}

/// Progress on one of the book's exercises, such as “Ex. 2.8”.
public enum ExerciseStatus: String, Codable, CaseIterable, Sendable {
    case todo, attempted, solved
    public var label: String { switch self { case .todo: "To do"; case .attempted: "Attempted"; case .solved: "Solved" } }
    public var symbol: String { switch self { case .todo: "circle"; case .attempted: "circle.lefthalf.filled"; case .solved: "checkmark.circle.fill" } }
    /// The next state when the reader clicks the status: to do → attempted → solved → to do.
    public var next: ExerciseStatus { switch self { case .todo: .attempted; case .attempted: .solved; case .solved: .todo } }
}

public struct ExerciseRecord: Codable, Equatable, Sendable {
    public var number: String
    public var status: ExerciseStatus
    /// The reader's working note for this exercise, when one was started.
    public var noteID: UUID?
    public var updatedAt: Date
    public init(number: String, status: ExerciseStatus = .todo, noteID: UUID? = nil, updatedAt: Date = .now) {
        self.number = number; self.status = status; self.noteID = noteID; self.updatedAt = updatedAt
    }
}

public struct ContextPin: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var anchor: SourceAnchor
    public init(id: UUID = UUID(), label: String, anchor: SourceAnchor) {
        self.id = id; self.label = label; self.anchor = anchor
    }
}

public struct ReadingState: Codable, Equatable, Sendable {
    public var pageIndex: Int = 0
    public var scale: Double = 1
    public var returnNote: String = ""
    public var positionX: Double?
    public var positionY: Double?
    public var layout: ReadingLayout?
    public init() {}

    // Lemma 3.3.0 and older refuse a workspace naming a layout they do not know: Two Pages Continuous is written as Two
    // Pages plus a flag they ignore, so they still open the book, side by side. A layout from a newer version reads as none.
    private enum CodingKeys: String, CodingKey { case pageIndex, scale, returnNote, positionX, positionY, layout, twoPagesContinuous }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pageIndex = try c.decode(Int.self, forKey: .pageIndex); scale = try c.decode(Double.self, forKey: .scale)
        returnNote = try c.decode(String.self, forKey: .returnNote)
        positionX = try c.decodeIfPresent(Double.self, forKey: .positionX); positionY = try c.decodeIfPresent(Double.self, forKey: .positionY)
        layout = try c.decodeIfPresent(String.self, forKey: .layout).flatMap(ReadingLayout.init(rawValue:))
        if layout == .twoPages, try c.decodeIfPresent(Bool.self, forKey: .twoPagesContinuous) == true { layout = .twoPagesContinuous }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pageIndex, forKey: .pageIndex); try c.encode(scale, forKey: .scale); try c.encode(returnNote, forKey: .returnNote)
        try c.encodeIfPresent(positionX, forKey: .positionX); try c.encodeIfPresent(positionY, forKey: .positionY)
        try c.encodeIfPresent(layout == .twoPagesContinuous ? ReadingLayout.twoPages : layout, forKey: .layout)
        if layout == .twoPagesContinuous { try c.encode(true, forKey: .twoPagesContinuous) }
    }
}

public struct StudyWorkspace: Codable, Identifiable, Equatable, Sendable {
    public var schemaVersion: Int = 10
    public var id: String
    public var title: String
    public var sourcePath: String
    public var sourceBookmark: Data?
    public var fingerprint: String
    public var notes: [StudyNote] = []
    public var pins: [ContextPin] = []
    public var reading = ReadingState()
    public var lastOpenedAt: Date = .now
    public var bookmarks: [ReadingBookmark] = []
    public var highlights: [StudyHighlight] = []
    public var noteLinks: [NoteLink] = []
    public var inkStrokes: [InkStroke] = []
    public var shapes: [PageShape] = []
    /// Recorded when the PDF is opened, for reading progress in the library.
    public var pageCount: Int?
    /// The reader's progress on the book's exercises, by number.
    public var exercises: [ExerciseRecord] = []
    /// Executable notebooks kept with this book (schema 8).
    public var labs: [LabNotebook] = []
    /// Reading time per page and per day (schema 8).
    public var readingLog = ReadingLog()
    /// Proofs the reader folded away to try first, by where they start (“page:offset”, schema 9).
    public var foldedProofs: [String] = []
    /// Statements the reader marked as understood (schema 9).
    public var understood: [ReferenceKey] = []
    /// Derivations worked through beside the book, checked step by step (schema 10).
    public var derivations: [Derivation] = []
    public init(id: String, title: String, sourcePath: String, sourceBookmark: Data?, fingerprint: String) {
        self.id = id; self.title = title; self.sourcePath = sourcePath
        self.sourceBookmark = sourceBookmark; self.fingerprint = fingerprint
    }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, title, sourcePath, sourceBookmark, fingerprint, notes, pins, reading, lastOpenedAt, bookmarks, highlights, noteLinks, inkStrokes, shapes, pageCount, exercises, labs, readingLog, foldedProofs, understood, derivations
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = try c.decode(String.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        sourcePath = try c.decode(String.self, forKey: .sourcePath)
        sourceBookmark = try c.decodeIfPresent(Data.self, forKey: .sourceBookmark)
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        notes = try c.decode([StudyNote].self, forKey: .notes); pins = try c.decode([ContextPin].self, forKey: .pins)
        reading = try c.decode(ReadingState.self, forKey: .reading); lastOpenedAt = try c.decode(Date.self, forKey: .lastOpenedAt)
        bookmarks = try c.decodeIfPresent([ReadingBookmark].self, forKey: .bookmarks) ?? []
        highlights = try c.decodeIfPresent([StudyHighlight].self, forKey: .highlights) ?? []
        noteLinks = try c.decodeIfPresent([NoteLink].self, forKey: .noteLinks) ?? []
        inkStrokes = try c.decodeIfPresent([InkStroke].self, forKey: .inkStrokes) ?? []
        shapes = try c.decodeIfPresent([PageShape].self, forKey: .shapes) ?? []
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount)
        exercises = try c.decodeIfPresent([ExerciseRecord].self, forKey: .exercises) ?? []
        labs = try c.decodeIfPresent([LabNotebook].self, forKey: .labs) ?? []
        readingLog = try c.decodeIfPresent(ReadingLog.self, forKey: .readingLog) ?? ReadingLog()
        foldedProofs = try c.decodeIfPresent([String].self, forKey: .foldedProofs) ?? []
        understood = try c.decodeIfPresent([ReferenceKey].self, forKey: .understood) ?? []
        derivations = try c.decodeIfPresent([Derivation].self, forKey: .derivations) ?? []
    }

    public func exercise(_ number: String) -> ExerciseRecord? { exercises.first { $0.number == number } }

    /// Fraction of the document read, from the saved reading position.
    public var progress: Double? {
        guard let pageCount, pageCount > 0 else { return nil }
        return min(1, Double(reading.pageIndex + 1) / Double(pageCount))
    }

    /// Fraction of pages actually read (from the reading log), when reading has been recorded.
    public var readFraction: Double? {
        guard let pageCount, pageCount > 0, !readingLog.pageSeconds.isEmpty else { return nil }
        return min(1, Double(readingLog.pagesRead) / Double(pageCount))
    }
}

public enum QuestionStyle: String, CaseIterable, Identifiable, Sendable {
    case explanation, hint, nextStep, assumptions, intuition, example, counterexample, recreateFigure, code
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .explanation: "Explain"; case .hint: "Give a hint"; case .nextStep: "Next step"; case .assumptions: "Check assumptions"
        case .intuition: "Build intuition"; case .example: "Worked example"; case .counterexample: "Counterexample"; case .recreateFigure: "Recreate figure"
        case .code: "Turn into code"
        }
    }
    public var instruction: String {
        switch self {
        case .explanation: "Explain it step by step: what each step does and why it holds, filling in any step the book leaves out (“it is not hard to show”, “one can show”)."
        case .hint: "Give one useful hint and a question to help me proceed. Do not reveal the full solution."
        case .nextStep: "Show only the next missing step in the derivation, explain why it is valid, and let me try the rest."
        case .assumptions: "Identify the assumptions needed for this step. Distinguish explicit source assumptions from additional assumptions and explain what fails without them."
        case .intuition: "Explain the mathematical intuition for this specific step, then connect it to the formal argument. Distinguish an analogy from a proof."
        case .example: "Give a small worked numerical example of this claim with explicit dimensions and conventions. Let me check the intermediate calculations."
        case .counterexample: "Test this claim by removing one stated assumption. If a counterexample exists, give it explicitly and verify that it satisfies the remaining assumptions. Do not invent a counterexample if the claim still holds."
        case .recreateFigure: "Identify what can be established from this figure and the selected context: axes, equations, parameters, and data provenance. Provide a reproducible Python script if enough information is available. If the original data or method is missing, clearly label any toy illustration and list the missing information. Do not claim an exact reproduction. No generated code is executed by Lemma."
        case .code: "Translate this passage into one short, runnable Python 3 cell using NumPy and Matplotlib (SciPy or scikit-learn only if essential). Define every symbol with small synthetic data and fixed random seeds, print the key quantities, and plot when it helps. Put all code in a single ```python block, then explain in a few lines how each variable maps to the book's notation and which conventions you assumed. I will run the cell myself in a local notebook; it must not read files or use the network."
        }
    }
}

public enum WebQuestionMode: String, Codable, Sendable {
    case draft, askAndSave
}

public struct BrowserImage: Codable, Equatable, Sendable {
    public var name: String
    public var label: String
    public var byteCount: Int
    public init(name: String, label: String, byteCount: Int) {
        self.name = name; self.label = label; self.byteCount = byteCount
    }
}

public struct BrowserPacket: Codable, Sendable {
    public var id: UUID
    public var noteID: UUID
    public var mode: WebQuestionMode
    public var prompt: String
    public var images: [BrowserImage]
    public var createdAt: Date
    public var provider: QuestionProvider?
    public var workspaceID: String?
    public init(id: UUID = UUID(), noteID: UUID, mode: WebQuestionMode, prompt: String, images: [BrowserImage], provider: QuestionProvider? = nil, workspaceID: String? = nil) {
        self.id = id; self.noteID = noteID; self.mode = mode; self.prompt = prompt
        self.images = images; self.createdAt = .now
        self.provider = provider; self.workspaceID = workspaceID
    }
}

public struct BrowserResult: Codable, Sendable {
    public var requestID: UUID
    public var status: String
    public var answer: String?
    public var conversationURL: String?
    public var message: String?
    public var model: String?
    public var createdAt: Date
    public init(requestID: UUID, status: String, answer: String? = nil, conversationURL: String? = nil, message: String? = nil, model: String? = nil) {
        self.requestID = requestID; self.status = status; self.answer = answer
        self.conversationURL = conversationURL; self.message = message; self.createdAt = .now
        self.model = model
    }
}
