import AppKit
import LemmaCore

@MainActor
extension StudyStore {
    /// Use the native window's stack so Edit > Undo/Redo and their standard shortcuts work from the reader.
    var pdfUndoManager: UndoManager { mainWindow?.undoManager ?? reader.view?.undoManager ?? fallbackUndoManager }

    func registerPDFUndo(_ name: String, manager: UndoManager, _ inverse: @escaping @MainActor (StudyStore) -> Void) {
        let group = !manager.groupsByEvent && manager.groupingLevel == 0 && !manager.isUndoing && !manager.isRedoing
        if group { manager.beginUndoGrouping() }
        manager.registerUndo(withTarget: self) { store in MainActor.assumeIsolated { inverse(store) } }
        manager.setActionName(name)
        if group { manager.endUndoGrouping() }
    }

    /// Undo retains the original book's identity. Switching tabs cannot apply a note or highlight to another PDF.
    @discardableResult
    func editAnnotations(in bookID: String, _ edit: (inout StudyWorkspace) -> Void) -> Bool {
        if let showing = app.windows.first(where: { $0.workspace?.id == bookID }) {
            guard var book = showing.workspace else { return false }
            edit(&book)
            showing.workspace = book
            for store in app.windows where store.workspace?.id == bookID {
                if let selected = store.selectedNoteID, !book.notes.contains(where: { $0.id == selected }) {
                    store.selectedNoteID = book.notes.first?.id
                }
            }
            showing.flush()
            return true
        }
        do {
            guard var book = try repository.load(id: bookID) else { return false }
            edit(&book)
            try repository.save(book)
            if let index = library.firstIndex(where: { $0.id == bookID }) { library[index] = book }
            return true
        } catch { self.error = "Could not save the annotation change: \(error.localizedDescription)"; return false }
    }

    func registerNoteCreationUndo(_ note: StudyNote, bookID: String) {
        let manager = pdfUndoManager
        registerPDFUndo("Add Note", manager: manager) { store in
            store.removeNote(id: note.id, undoManager: manager, bookID: bookID, actionName: "Add Note")
        }
    }

    /// The inverse captures the note as it is now, so redo retains text and saved answers added since its creation.
    func removeNote(id: UUID, undoManager: UndoManager?, bookID requestedBookID: String? = nil, actionName: String = "Delete Note") {
        guard let bookID = requestedBookID ?? workspace?.id,
              let book = app.currentWorkspace(bookID) ?? (try? repository.load(id: bookID)),
              let index = book.notes.firstIndex(where: { $0.id == id }) else { return }
        var note = book.notes[index]
        if let request = note.pendingRequestID { questions.cancel(request); note.pendingRequestID = nil }
        let links = book.noteLinks.filter { $0.sourceNoteID == id || $0.targetNoteID == id }
        guard editAnnotations(in: bookID, { book in
            book.notes.removeAll { $0.id == id }
            book.noteLinks.removeAll { $0.sourceNoteID == id || $0.targetNoteID == id }
        }) else { return }
        if let manager = undoManager {
            registerPDFUndo(actionName, manager: manager) { store in
                store.restoreNote(note, links: links, at: index, bookID: bookID, manager: manager, actionName: actionName)
            }
        }
    }

    private func restoreNote(_ note: StudyNote, links: [NoteLink], at index: Int, bookID: String, manager: UndoManager, actionName: String) {
        guard editAnnotations(in: bookID, { book in
            guard !book.notes.contains(where: { $0.id == note.id }) else { return }
            book.notes.insert(note, at: min(index, book.notes.count))
            let noteIDs = Set(book.notes.map(\.id)), linkIDs = Set(book.noteLinks.map(\.id))
            book.noteLinks.append(contentsOf: links.filter { !linkIDs.contains($0.id) && noteIDs.contains($0.sourceNoteID) && noteIDs.contains($0.targetNoteID) })
        }) else { return }
        if workspace?.id == bookID { selectedNoteID = note.id }
        registerPDFUndo(actionName, manager: manager) { store in
            store.removeNote(id: note.id, undoManager: manager, bookID: bookID, actionName: actionName)
        }
    }

    func registerHighlightCreationUndo(_ highlight: StudyHighlight, bookID: String) {
        let name = highlight.style == .underline ? "Underline" : "Highlight", manager = pdfUndoManager
        registerPDFUndo(name, manager: manager) { store in
            store.removeHighlight(id: highlight.id, bookID: bookID, manager: manager, actionName: name)
        }
    }

    func replaceHighlight(_ highlight: StudyHighlight, bookID: String, manager requestedManager: UndoManager? = nil, actionName: String = "Change Highlight") {
        guard let book = app.currentWorkspace(bookID) ?? (try? repository.load(id: bookID)),
              let index = book.highlights.firstIndex(where: { $0.id == highlight.id }) else { return }
        let previous = book.highlights[index], manager = requestedManager ?? pdfUndoManager
        guard previous != highlight, editAnnotations(in: bookID, { $0.highlights[index] = highlight }) else { return }
        registerPDFUndo(actionName, manager: manager) { store in
            store.replaceHighlight(previous, bookID: bookID, manager: manager, actionName: actionName)
        }
    }

    func removeHighlight(id: UUID, bookID requestedBookID: String? = nil, manager requestedManager: UndoManager? = nil, actionName: String = "Delete Highlight") {
        guard let bookID = requestedBookID ?? workspace?.id,
              let book = app.currentWorkspace(bookID) ?? (try? repository.load(id: bookID)),
              let index = book.highlights.firstIndex(where: { $0.id == id }) else { return }
        let highlight = book.highlights[index], manager = requestedManager ?? pdfUndoManager
        guard editAnnotations(in: bookID, { $0.highlights.removeAll { $0.id == id } }) else { return }
        registerPDFUndo(actionName, manager: manager) { store in
            guard store.editAnnotations(in: bookID, { book in
                guard !book.highlights.contains(where: { $0.id == id }) else { return }
                book.highlights.insert(highlight, at: min(index, book.highlights.count))
            }) else { return }
            store.registerPDFUndo(actionName, manager: manager) { target in
                target.removeHighlight(id: id, bookID: bookID, manager: manager, actionName: actionName)
            }
        }
    }

    func addShape(_ shape: PageShape, bookID requestedBookID: String? = nil, at index: Int? = nil, manager requestedManager: UndoManager? = nil) {
        guard shape.isValid, let bookID = requestedBookID ?? workspace?.id,
              let book = app.currentWorkspace(bookID) ?? (try? repository.load(id: bookID)),
              shape.pageIndex < (book.pageCount ?? 0), !book.shapes.contains(where: { $0.id == shape.id }) else { return }
        let manager = requestedManager ?? pdfUndoManager
        guard editAnnotations(in: bookID, { $0.shapes.insert(shape, at: min(index ?? $0.shapes.count, $0.shapes.count)) }) else { return }
        syncShapeReaders(bookID)
        registerPDFUndo("Draw \(shape.kind.label)", manager: manager) { store in
            store.removeShape(id: shape.id, bookID: bookID, manager: manager)
        }
    }

    func replaceShape(_ shape: PageShape, bookID: String, manager requestedManager: UndoManager? = nil, actionName: String = "Change Shape") {
        guard shape.isValid, let book = app.currentWorkspace(bookID) ?? (try? repository.load(id: bookID)),
              let index = book.shapes.firstIndex(where: { $0.id == shape.id }), book.shapes[index] != shape else { return }
        let previous = book.shapes[index], manager = requestedManager ?? pdfUndoManager
        guard editAnnotations(in: bookID, { $0.shapes[index] = shape }) else { return }
        syncShapeReaders(bookID)
        registerPDFUndo(actionName, manager: manager) { store in
            store.replaceShape(previous, bookID: bookID, manager: manager, actionName: actionName)
        }
    }

    func removeShape(id: UUID, bookID requestedBookID: String? = nil, manager requestedManager: UndoManager? = nil) {
        guard let bookID = requestedBookID ?? workspace?.id,
              let book = app.currentWorkspace(bookID) ?? (try? repository.load(id: bookID)),
              let index = book.shapes.firstIndex(where: { $0.id == id }) else { return }
        let shape = book.shapes[index], manager = requestedManager ?? pdfUndoManager
        guard editAnnotations(in: bookID, { $0.shapes.removeAll { $0.id == id } }) else { return }
        syncShapeReaders(bookID)
        registerPDFUndo("Delete \(shape.kind.label)", manager: manager) { store in
            store.addShape(shape, bookID: bookID, at: index, manager: manager)
        }
    }

    private func syncShapeReaders(_ bookID: String) {
        for store in app.windows where store.workspace?.id == bookID {
            if let document = store.document { store.reader.syncShapes(store.workspace?.shapes ?? [], in: document) }
        }
    }
}
