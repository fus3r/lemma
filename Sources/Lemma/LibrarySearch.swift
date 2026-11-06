import Foundation
import AppKit
import PDFKit
import LemmaCore

enum PageSearchScope: String, CaseIterable, Identifiable {
    case current, project, library
    var id: String { rawValue }
    var label: String { switch self { case .current: "This PDF"; case .project: "Project"; case .library: "Library" } }
}

@MainActor
extension StudyStore {
    var indexRepository: DocumentIndexRepository { DocumentIndexRepository(root: repository.root) }

    func searchNoteMeaning() {
        noteMeaningTask?.cancel(); noteMeaningHits = []; noteSemanticAvailable = false
        let query = libraryNoteQuery, books = booksForSearch(noteSearchScope)
        isSearchingNoteMeaning = noteSearchByMeaning && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard isSearchingNoteMeaning else { return }
        noteMeaningTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .utility) {
                (NoteSearch.find(query, in: books, byMeaning: true), SemanticText.embed(query) != nil)
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, let self else { return }
            self.noteMeaningHits = result.0; self.noteSemanticAvailable = result.1; self.isSearchingNoteMeaning = false
        }
    }

    /// Reads the current book's index progress: when a book comes to the front, and when its indexing starts or ends.
    /// (Pages done while it runs come from the indexing helper itself; nothing is polled.)
    func refreshIndex() {
        guard let id = workspace?.id else { return }
        do {
            var progress = try indexRepository.progress(id)
            // A run this Lemma is not running ended with an earlier session (Lemma quit or stopped meanwhile).
            if var stale = progress, stale.status == .running, !PageIndexer.shared.isRunning(id, root: repository.root) {
                stale.status = .cancelled; stale.updatedAt = .now
                stale.message = "Indexing stopped. Completed pages are available; resume to finish."
                try? indexRepository.save(stale, id: id)
                progress = stale
            }
            if indexProgress?.completedPages != progress?.completedPages || indexedWorkspaceID != id {
                indexedWorkspaceID = id
                if !pageSearchQuery.isEmpty { searchIndexedPages() }
            }
            if indexProgress != progress { indexProgress = progress }
        } catch { self.error = "Could not read the local search index: \(error.localizedDescription)" }
    }

    /// Indexes the book in front in the bundled helper, at utility priority; it pauses on battery and when the Mac is hot.
    func startIndexing() {
        guard let workspace, let document, !isLaunchingIndex else { return }
        let id = workspace.id, source = workspace.sourcePath, total = document.pageCount, root = repository.root
        guard !PageIndexer.shared.isRunning(id, root: root) else { refreshIndex(); return }
        guard let helper = PageIndexer.helperURL else {
            error = "Could not start page indexing: build and open Lemma.app to use its indexing worker."
            return
        }
        isLaunchingIndex = true
        defer { isLaunchingIndex = false }
        let name = "lemma-index-\(UUID().uuidString.prefix(8).lowercased())"
        let progress = IndexProgress(status: .running, completedPages: indexRepository.pageCount(id), totalPages: total, jobName: name)
        do {
            try indexRepository.save(progress, id: id)
            try PageIndexer.shared.start(id: id, source: source, root: root, jobName: name, helper: helper,
                onProgress: { [weak self] done, total in self?.indexAdvanced(id, done: done, total: total) },
                onExit: { [weak self] outcome in self?.indexEnded(id, outcome) })
        } catch {
            var failed = progress; failed.status = .failed; failed.message = error.localizedDescription
            try? indexRepository.save(failed, id: id)
            self.error = "Could not start page indexing: \(error.localizedDescription)"
        }
        if self.workspace?.id == id { refreshIndex() }
    }

    func stopIndexing() {
        guard let id = workspace?.id, let progress = indexProgress, progress.status == .running else { return }
        if PageIndexer.shared.isRunning(id, root: repository.root) {
            // The helper's end is reported back (`indexEnded`), which records the stop.
            PageIndexer.shared.stop(id, root: repository.root)
        } else {
            refreshIndex()
        }
    }

    /// Pages done, as the helper reports them while it runs.
    private func indexAdvanced(_ id: String, done: Int, total: Int) {
        guard workspace?.id == id, var progress = indexProgress, progress.status == .running else { return }
        progress.completedPages = done; progress.totalPages = total
        if indexProgress != progress { indexProgress = progress }
    }

    /// The helper ended: finished (it recorded so), stopped by the reader, or failed.
    private func indexEnded(_ id: String, _ outcome: PageIndexOutcome) {
        if var latest = try? indexRepository.progress(id), latest.status == .running {
            switch outcome {
            case .finished: break
            case .stopped:
                latest.status = .cancelled; latest.message = "Indexing stopped. Completed pages are available; resume to finish."
            case let .failed(message):
                latest.status = .failed; latest.message = message
            }
            latest.updatedAt = .now
            try? indexRepository.save(latest, id: id)
        }
        if workspace?.id == id {
            refreshIndex()
            // Results catch up with the pages indexed meanwhile.
            if !pageSearchQuery.isEmpty { searchIndexedPages() }
        }
    }

    func searchIndexedPages() {
        pageSearchTask?.cancel()
        let query = pageSearchQuery, byMeaning = searchByMeaning
        let ids = booksForSearch(pageSearchScope).map(\.id)
        let repository = indexRepository
        isSearchingPages = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        pageSearchResults = []; semanticSearchAvailable = false
        guard isSearchingPages else { return }
        pageSearchTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                let indexes = ids.map { ($0, (try? repository.pages($0)) ?? []) }
                return (PassageSearch.find(query, in: indexes, byMeaning: byMeaning), !byMeaning || SemanticText.embed(query) != nil)
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, let self else { return }
            self.pageSearchResults = result.0; self.semanticSearchAvailable = result.1; self.isSearchingPages = false
        }
    }

    func openPageResult(_ result: PassageSearchResult) {
        openBook(result.workspaceID, atPage: result.pageIndex)
    }

    func prepareIndexReview(_ result: PassageSearchResult) {
        do {
            guard let page = try indexRepository.pages(result.workspaceID).first(where: { $0.pageIndex == result.pageIndex }),
                  let book = library.first(where: { $0.id == result.workspaceID }),
                  let pdf = result.workspaceID == workspace?.id ? document : PDFDocument(url: URL(fileURLWithPath: book.sourcePath)),
                  let source = pdf.page(at: page.pageIndex) else { throw CocoaError(.fileReadNoSuchFile) }
            let box = source.bounds(for: .cropBox)
            let region = PageRegion(x: box.minX, y: box.minY, width: box.width, height: box.height)
            let png = try PDFRegionRenderer.png(page: source, region: region, scale: 2)
            ocrCapture = OCRCapture(workspaceID: book.id, anchor: SourceAnchor(pageIndex: page.pageIndex, pageLabel: page.pageLabel,
                region: region, quote: "", imageName: "unused.png"), pngData: png, sourceLabel: book.title, indexedPage: page)
        } catch { self.error = "Could not open the indexed source for review: \(error.localizedDescription)" }
    }

    func saveIndexReview(_ capture: OCRCapture, text: String) {
        guard var page = capture.indexedPage else { return }
        page.text = text; page.passages = SemanticText.passages(text); page.reviewedAt = .now
        do {
            try indexRepository.save(page, id: capture.workspaceID)
            ocrCapture = nil; searchIndexedPages(); status = "Corrected OCR saved in the local search index."
        } catch { self.error = "Could not save the corrected index: \(error.localizedDescription)" }
    }

    func exportMyEdition() {
        guard workspace != nil else { return }
        flush()
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(workspace?.title ?? "Study") · My edition.pdf"
        panel.message = "Save a copy with your handwriting, highlights, and source-linked text notes."
        if panel.runModal() == .OK, let url = panel.url {
            // Replacing the original would violate the reader's source-fidelity contract.
            guard url.standardizedFileURL != URL(fileURLWithPath: workspace!.sourcePath).standardizedFileURL else {
                error = "Choose a different filename to keep the original PDF intact."; return
            }
            do { try exportPersonalPDF(to: url); status = "My edition exported as a new PDF." }
            catch { self.error = "Could not export your edition: \(error.localizedDescription)" }
        }
    }
}
