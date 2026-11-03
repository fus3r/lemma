import Foundation
import CryptoKit

/// A saved workspace that could not be read: its folder, its title when the file still says it, and why.
public struct WorkspaceLoadFailure: Error, Sendable, Equatable {
    public var id: String
    public var title: String?
    public var message: String
    public var label: String { title.map { "“\($0)”" } ?? "a book saved as \(id.prefix(10))…" }
}

/// Every workspace that could be read, and those that could not (which stay on disk untouched).
public struct WorkspaceListing: Sendable {
    public var workspaces: [StudyWorkspace] = []
    public var failures: [WorkspaceLoadFailure] = []
}

/// One result per workspace folder, each written by one decoding thread only.
private struct ListingSlots: @unchecked Sendable {
    let buffer: UnsafeMutableBufferPointer<Result<StudyWorkspace, WorkspaceLoadFailure>?>
}

/// `reading.json`: where the reader is in the book, when it was last opened and the reading time, which change while
/// reading and are saved without the rest of the workspace (notes, ink, notebooks). A full save folds them back in.
struct ReadingSidecar: Codable {
    var reading: ReadingState
    var lastOpenedAt: Date?
    var readingLog: ReadingLog?
}

public struct WorkspaceRepository: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lemma", isDirectory: true)
    }

    /// The SHA-256 of the file's bytes, which names its workspace. Reads the whole file: see `SourceFingerprint` for
    /// the cached and coordinated way to get it.
    public static func fingerprint(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Saves of this support folder, in order, off the main thread.
    public var writer: WorkspaceWriter { WorkspaceWriter.shared(for: root) }

    public func directory(for id: String) -> URL {
        root.appendingPathComponent("Workspaces", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    public func assetURL(workspaceID: String, name: String) -> URL {
        directory(for: workspaceID).appendingPathComponent("assets", isDirectory: true).appendingPathComponent(name)
    }

    private func manifestURL(_ id: String) -> URL { directory(for: id).appendingPathComponent("workspace.json") }
    /// The reading position alone, saved while scrolling so the whole workspace (notes, ink…) is not rewritten each time.
    /// It is newer than the position inside workspace.json whenever it exists: a full save removes it.
    private func readingURL(_ id: String) -> URL { directory(for: id).appendingPathComponent("reading.json") }

    /// The saved workspace, with the latest reading position. Waits for this folder's pending saves; an unchanged file
    /// is not decoded again.
    public func load(id: String) throws -> StudyWorkspace? {
        writer.waitUntilIdle()
        let url = manifestURL(id)
        guard let stamp = FileStamp(url) else {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return withReading(try Self.decoder.decode(StudyWorkspace.self, from: Data(contentsOf: url)))
        }
        if let cached = WorkspaceCache.lookup(url, stamp: stamp) { return withReading(cached) }
        let workspace = try Self.decoder.decode(StudyWorkspace.self, from: Data(contentsOf: url))
        WorkspaceCache.store(workspace, url: url, stamp: stamp)
        return withReading(workspace)
    }

    /// The readable workspaces, most recently opened first. One unreadable file never hides the others.
    public func list() throws -> [StudyWorkspace] { try listing().workspaces }

    /// Every workspace folder, read in parallel; files unchanged since they were last read or saved are not decoded again.
    /// A workspace that cannot be read is reported and left on disk as it is. Throws only when the folder cannot be listed.
    public func listing() throws -> WorkspaceListing {
        writer.waitUntilIdle()
        let directory = root.appendingPathComponent("Workspaces", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return WorkspaceListing() }
        let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var results = [Result<StudyWorkspace, WorkspaceLoadFailure>?](repeating: nil, count: folders.count)
        results.withUnsafeMutableBufferPointer { buffer in
            // Each folder fills its own slot, so the decoding threads never share a value.
            let slots = ListingSlots(buffer: buffer)
            let repository = self
            let read: @Sendable (Int) -> Void = { index in slots.buffer[index] = repository.readManifest(in: folders[index]) }
            if folders.count > 1 { DispatchQueue.concurrentPerform(iterations: folders.count, execute: read) }
            else { folders.indices.forEach(read) }
        }
        var listing = WorkspaceListing()
        for result in results.compactMap({ $0 }) {
            switch result {
            case let .success(workspace): listing.workspaces.append(withReading(workspace))
            case let .failure(failure): listing.failures.append(failure)
            }
        }
        listing.workspaces.sort { $0.lastOpenedAt > $1.lastOpenedAt }
        return listing
    }

    /// One folder's workspace: from the cache while its file is unchanged, decoded otherwise; nil when it has none.
    private func readManifest(in folder: URL) -> Result<StudyWorkspace, WorkspaceLoadFailure>? {
        let manifest = folder.appendingPathComponent("workspace.json")
        guard let stamp = FileStamp(manifest) else { return nil }
        if let cached = WorkspaceCache.lookup(manifest, stamp: stamp) { return .success(cached) }
        let id = folder.lastPathComponent
        do {
            let data = try Data(contentsOf: manifest)
            do {
                let workspace = try Self.decoder.decode(StudyWorkspace.self, from: data)
                WorkspaceCache.store(workspace, url: manifest, stamp: stamp)
                return .success(workspace)
            } catch {
                // The title, if the file still says it, names the book in the report.
                let title = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["title"] as? String
                return .failure(WorkspaceLoadFailure(id: id, title: title, message: Self.describe(error)))
            }
        } catch { return .failure(WorkspaceLoadFailure(id: id, title: nil, message: error.localizedDescription)) }
    }

    /// Saves the whole workspace and waits until it is on disk, after any save queued before it.
    public func save(_ workspace: StudyWorkspace) throws {
        try writer.sync { try write(workspace) }
    }

    /// Queues a save of the whole workspace and returns at once; `completion` runs on the writer's queue.
    public func saveLater(_ workspace: StudyWorkspace, completion: @escaping @Sendable (Error?) -> Void = { _ in }) {
        let repository = self
        writer.enqueue {
            do { try repository.write(workspace); completion(nil) } catch { completion(error) }
        }
    }

    /// Queues a save of what changes while reading alone (the position, the time opened and the reading time: a few
    /// kilobytes), for scrolling, switching tabs and the reading clock: the notes, ink and notebooks are not written again.
    public func saveReadingLater(_ reading: ReadingState, lastOpenedAt: Date, readingLog: ReadingLog, id: String,
                                 completion: @escaping @Sendable (Error?) -> Void = { _ in }) {
        let repository = self
        writer.enqueue {
            do {
                let folder = repository.directory(for: id)
                // A book whose folder is gone (never saved) keeps its position in its next full save instead.
                guard FileManager.default.fileExists(atPath: repository.manifestURL(id).path) else { completion(nil); return }
                let sidecar = ReadingSidecar(reading: reading, lastOpenedAt: lastOpenedAt, readingLog: readingLog)
                try repository.writeFile(repository.writer.encode(sidecar), to: repository.readingURL(id), folder: folder)
                completion(nil)
            } catch { completion(error) }
        }
    }

    /// Derived data made from a PDF's bytes (analysis, reference and page-text caches, the search index, the cover),
    /// for a workspace that now follows different bytes. The reader's own notes are never touched.
    public func discardDerivedData(id: String) {
        writer.sync {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("Indexes", isDirectory: true).appendingPathComponent(id, isDirectory: true))
            try? FileManager.default.removeItem(at: root.appendingPathComponent("Covers", isDirectory: true).appendingPathComponent("\(id).png"))
        }
    }

    // MARK: On the writer's queue

    private func write(_ workspace: StudyWorkspace) throws {
        let folder = directory(for: workspace.id)
        try writer.ensureFolder(folder.appendingPathComponent("assets", isDirectory: true))
        let url = manifestURL(workspace.id)
        try writeFile(writer.encode(workspace), to: url, folder: folder)
        // The position inside the workspace is now the latest one.
        try? FileManager.default.removeItem(at: readingURL(workspace.id))
        // The next read decodes the file as written (dates keep whole seconds there), as it would after a relaunch.
        WorkspaceCache.remove(url)
    }

    /// Writes atomically; a folder removed since it was created is made again once.
    private func writeFile(_ data: Data, to url: URL, folder: URL) throws {
        do { try data.write(to: url, options: .atomic) }
        catch where !FileManager.default.fileExists(atPath: folder.path) {
            writer.forgetFolder(folder); writer.forgetFolder(folder.appendingPathComponent("assets", isDirectory: true))
            try writer.ensureFolder(folder)
            try data.write(to: url, options: .atomic)
        }
    }

    private func withReading(_ workspace: StudyWorkspace) -> StudyWorkspace {
        guard let data = try? Data(contentsOf: readingURL(workspace.id)),
              let sidecar = try? Self.decoder.decode(ReadingSidecar.self, from: data) else { return workspace }
        var workspace = workspace
        workspace.reading = sidecar.reading
        if let opened = sidecar.lastOpenedAt { workspace.lastOpenedAt = opened }
        if let log = sidecar.readingLog { workspace.readingLog = log }
        return workspace
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let context): return "the file is damaged (\(context.debugDescription))"
        case DecodingError.keyNotFound(let key, _): return "the file lacks “\(key.stringValue)”"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            return "unexpected content at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        default: return error.localizedDescription
        }
    }

    public func saveImage(_ data: Data, workspaceID: String, name: String) throws {
        let url = assetURL(workspaceID: workspaceID, name: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func export(_ workspace: StudyWorkspace, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let assets = destination.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let imageNames = Set(workspace.notes.map(\.anchor.imageName) + workspace.notes.compactMap(\.figureName) + workspace.pins.map(\.anchor.imageName))
        for name in imageNames {
            let source = assetURL(workspaceID: workspace.id, name: name)
            let data = try Data(contentsOf: source)
            try data.write(to: assets.appendingPathComponent(name), options: .atomic)
        }
        for page in Set(workspace.inkStrokes.map(\.pageIndex)).sorted() {
            try InkExport.svg(strokes: workspace.inkStrokes.filter { $0.pageIndex == page })
                .write(to: assets.appendingPathComponent("ink-page-\(page + 1).svg"), atomically: true, encoding: .utf8)
        }
        for record in workspace.notes.flatMap(\.experiments) {
            try ExperimentExport.write(record, to: destination.appendingPathComponent("experiments"))
        }
        if !workspace.labs.isEmpty {
            let labs = destination.appendingPathComponent("labs", isDirectory: true)
            try FileManager.default.createDirectory(at: labs, withIntermediateDirectories: true)
            for (notebook, stem) in zip(workspace.labs, Self.labExportStems(workspace.labs)) {
                let data = try LabExport.ipynb(notebook) { name in try? Data(contentsOf: assetURL(workspaceID: workspace.id, name: name)) }
                try data.write(to: labs.appendingPathComponent(stem + ".ipynb"), options: .atomic)
                try LabExport.python(notebook, bookTitle: workspace.title).write(to: labs.appendingPathComponent(stem + ".py"), atomically: true, encoding: .utf8)
            }
        }
        try Self.encoder.encode(workspace).write(to: destination.appendingPathComponent("workspace.json"), options: .atomic)
        try markdown(for: workspace).write(to: destination.appendingPathComponent("Study notes.md"), atomically: true, encoding: .utf8)
    }

    /// The files and Markdown links use the same collision handling, including on case-insensitive disks.
    private static func labExportStems(_ notebooks: [LabNotebook]) -> [String] {
        var used = Set<String>()
        return notebooks.map { notebook in
            var stem = (LabExport.fileName(for: notebook, extension: "ipynb") as NSString).deletingPathExtension
            while !used.insert(stem.lowercased()).inserted { stem += "-2" }
            return stem
        }
    }

    public func markdown(for workspace: StudyWorkspace) -> String {
        var output = "# \(workspace.title)\n\nSource fingerprint: `\(workspace.fingerprint)`\n\n"
        if !workspace.reading.returnNote.isEmpty { output += "## Next time\n\n\(workspace.reading.returnNote)\n\n" }
        if !workspace.bookmarks.isEmpty {
            output += "## Bookmarks\n\n"
            for bookmark in workspace.bookmarks { output += "- \(bookmark.title) · PDF page \(bookmark.pageIndex + 1), label \(bookmark.pageLabel).\n" }
            output += "\n"
        }
        if !workspace.highlights.isEmpty {
            output += "## Highlights\n\n"
            for highlight in workspace.highlights {
                output += "### PDF page \(highlight.pageIndex + 1) · \(highlight.colorHex ?? highlight.color.label)\n\n"
                output += highlight.quote.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n") + "\n\n"
            }
        }
        if !workspace.inkStrokes.isEmpty {
            output += "## Handwritten annotations\n\nStrokes use original PDF coordinates in workspace.json. These previews contain the personal ink only.\n\n"
            for page in Set(workspace.inkStrokes.map(\.pageIndex)).sorted() {
                output += "### PDF page \(page + 1)\n\n![Handwritten annotations](assets/ink-page-\(page + 1).svg)\n\n"
            }
        }
        if !workspace.labs.isEmpty {
            output += "## Lab notebooks\n\nExported beside this file as Jupyter notebooks (with outputs) and Python scripts.\n\n"
            for (notebook, stem) in zip(workspace.labs, Self.labExportStems(workspace.labs)) {
                let link = stem.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stem
                output += "- [\(notebook.title)](labs/\(link).ipynb)"
                if let source = notebook.source { output += " · \(source.label), PDF page \(source.pageIndex + 1)" }
                output += " · \(notebook.cells.count) cells\n"
            }
            output += "\n"
        }
        if workspace.readingLog.totalSeconds > 0 {
            output += "## Reading time\n\n\(ReadingLog.describe(workspace.readingLog.totalSeconds)) over \(workspace.readingLog.daySeconds.count) days; \(workspace.readingLog.pagesRead) pages read.\n\n"
        }
        for pin in workspace.pins {
            output += "## Reference: \(pin.label)\n\nPDF page \(pin.anchor.pageIndex + 1), label \(pin.anchor.pageLabel).\n\n![Source region](assets/\(pin.anchor.imageName))\n\n"
        }
        for note in workspace.notes {
            let title = note.title
            output += "<a id=\"\(note.markdownAnchor)\"></a>\n\n"
            output += "## \(title)\n\nPDF page \(note.anchor.pageIndex + 1), label \(note.anchor.pageLabel).\n\n![Source region](assets/\(note.anchor.imageName))\n\n\(note.body)\n\n"
            if let figure = note.figureName { output += "![Figure in the margin](assets/\(figure))\n\n" }
            output += "Type: \(note.kind.label) · State: \(note.state.label)\n\n"
            if note.sourceTextOrigin == .ocr {
                output += "### Recognized source text (local OCR)\n\n\(note.anchor.quote)\n\n"
            }
            output += workspace.markdownLinks(for: note)
            if !note.lookupTerms.isEmpty { output += "### Lookup names\n\n\(note.lookupTerms)\n\n" }
            if !note.notation.isEmpty { output += "### Reader notation and dimensions\n\n\(note.notation)\n\n" }
            if !note.scope.isEmpty { output += "Local scope: \(note.scope)\n\n" }
            if !note.assumptions.isEmpty { output += "### Reader assumptions to check\n\n\(note.assumptions)\n\n" }
            if let explanation = note.explanation {
                output += "### Saved explanation\n\n\(explanation.body)\n\n"
                if let provider = explanation.provider { output += "Assistant: \(provider.label)\(explanation.model.map { " (\($0))" } ?? "")\n\n" }
                if let url = explanation.conversationURL { output += "Conversation: \(url)\n\n" }
            }
            if !note.reviewAnswer.isEmpty { output += "### Recall attempt\n\n\(note.reviewAnswer)\n\n" }
            if note.isInReview {
                output += "### Review\n\n"
                let prompt = note.recallPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !prompt.isEmpty { output += "Recall prompt: \(prompt)\n\n" }
                if let review = note.review {
                    output += "Next review: \(review.dueAt.formatted(.iso8601)) · interval \(Int(review.interval)) d · \(review.repetitions) successful recalls in a row, \(review.lapses) lapses.\n\n"
                } else { output += "Marked Revisit; not yet scheduled.\n\n" }
                if !note.masks.isEmpty { output += "\(note.masks.count) \(note.masks.count == 1 ? "part" : "parts") of the source hidden during recall (PDF coordinates in workspace.json).\n\n" }
            }
            for experiment in note.experiments where experiment.kind == .nearestNeighbors {
                let model = NeighborsExperiment.model(seed: experiment.parameters.seed, gridSize: 2)
                let settings = experiment.neighbors ?? NeighborsSettings()
                let stem = ExperimentExport.stem(experiment)
                output += "### Least squares vs nearest neighbours · ESL §2.3 simulation\n\n\(NeighborsExperiment.description) Random draw \(experiment.parameters.seed).\n\n"
                if let start = experiment.startingNeighbors { output += "Starting view: \(start.summary).\n\n" }
                output += "Saved view: \(settings.summary)\(settings.showBayes ? ", with the Bayes boundary" : "").\n\n"
                output += "Prediction (\(experiment.predictedAt.formatted(.iso8601))):\n\n\(experiment.prediction)\n\n"
                output += "Observation (\(experiment.savedAt.formatted(.iso8601))):\n\n\(experiment.observation)\n\n"
                if settings.classifier == .neighbors, let point = model.errors(k: settings.k) {
                    output += "\(settings.k)-nearest neighbours: training error \(point.trainingError), test error \(point.testError) on 10,000 test points.\n\n"
                }
                output += "Linear regression: training error \(model.linearTrainingError), test error \(model.linearTestError). Bayes rule test error: \(model.bayesTestError).\n\n"
                output += "Recreate the plots: [Python script](experiments/\(stem).py), [training data](experiments/\(stem)-training.csv), [error curves](experiments/\(stem)-errors.csv). Run manually with Python and matplotlib.\n\n"
            }
            for experiment in note.experiments where experiment.kind != .nearestNeighbors {
                output += "### \(experiment.kind == .ridge ? "Ridge" : "Lasso") experiment · synthetic illustration\n\n"
                output += "Dataset version: \(experiment.datasetVersion). Seed: \(experiment.parameters.seed). Samples: \(experiment.parameters.sampleCount).\n\n"
                output += "Objective: \(experiment.kind == .ridge ? RidgeExperiment.objectiveDescription : LassoExperiment.objectiveDescription)\n\n\(RidgeExperiment.dataDescription)\n\nThis is a synthetic illustration, not a reproduction of the source's data.\n\n"
                output += "Starting parameters: λ = \(experiment.startingParameters.lambda), correlation = \(experiment.startingParameters.correlation).\n\n"
                output += "Saved parameters: λ = \(experiment.parameters.lambda), correlation = \(experiment.parameters.correlation).\n\n"
                output += "Prediction (\(experiment.predictedAt.formatted(.iso8601))):\n\n\(experiment.prediction)\n\n"
                output += "Observation (\(experiment.savedAt.formatted(.iso8601))):\n\n\(experiment.observation)\n\n"
                let result = experiment.kind == .ridge ? RidgeExperiment.run(parameters: experiment.parameters) : LassoExperiment.run(parameters: experiment.parameters)
                output += "Saved result: β₀ = \(result.intercept), β₁ = \(result.beta1), β₂ = \(result.beta2), training RSS = \(result.residualSumOfSquares), training MSE = \(result.trainingMSE).\n\n"
                if result.isRankDeficient && experiment.parameters.lambda == 0 {
                    output += "The design is rank deficient. These are minimum-norm least-squares coefficients; the coefficient minimizer is not unique.\n\n"
                }
                let stem = ExperimentExport.stem(experiment)
                output += "Recreate this local illustration: [Python plot script](experiments/\(stem).py), [sample data](experiments/\(stem)-samples.csv), [coefficient path](experiments/\(stem)-path.csv). Run manually with Python and matplotlib; no generated code is run by Lemma.\n\n"
            }
        }
        return output
    }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
