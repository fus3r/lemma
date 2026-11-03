import SwiftUI
import LemmaCore

@MainActor
extension StudyStore {
    /// A question sent to an assistant still waits for its answer, in the book in front or in another one.
    var hasPendingQuestion: Bool {
        if let workspace, collectsResponses(for: workspace.id), workspace.notes.contains(where: { $0.pendingRequestID != nil }) { return true }
        let current = workspace?.id
        return library.contains { book in book.id != current && collectsResponses(for: book.id) && book.notes.contains { $0.pendingRequestID != nil } }
    }
}

/// Collects assistant answers while a question waits for one, every two seconds. With no question out, nothing runs:
/// the window used to wake every second for this (and to read the page index's progress, which the indexing helper
/// now reports itself).
struct QuestionPoller: View {
    let store: StudyStore

    var body: some View {
        let pending = store.hasPendingQuestion
        Color.clear.frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: pending) {
                guard pending else { return }
                while !Task.isCancelled {
                    store.pollBrowser()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
    }
}
