import SwiftUI
import AppKit
import LemmaCore

struct NoteLinksPane: View {
    @Bindable var store: StudyStore
    let noteID: UUID
    @Environment(\.undoManager) private var undoManager
    @State private var showComposer = false
    @State private var linkKind: NoteLinkKind = .definition
    @State private var linkQuery = ""
    @State private var linkUsage = ""
    @State private var targetID: UUID?
    @State private var previewLinkID: UUID?
    @State private var inspectedImage: StudyImagePreview?

    private var outgoing: [NoteLink] { store.workspace?.outgoingLinks(from: noteID) ?? [] }
    private var incoming: [NoteLink] { store.workspace?.incomingLinks(to: noteID) ?? [] }
    private var candidates: [StudyNote] {
        (store.workspace?.notes ?? []).filter { candidate in
            candidate.id != noteID && candidate.matches(linkQuery) && !outgoing.contains { $0.targetNoteID == candidate.id && $0.kind == linkKind }
        }.sorted { $0.anchor.pageIndex == $1.anchor.pageIndex ? $0.createdAt > $1.createdAt : $0.anchor.pageIndex < $1.anchor.pageIndex }
    }
    private var selectedTarget: StudyNote? {
        guard let targetID else { return nil }
        return candidates.first { $0.id == targetID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Linked notes", systemImage: "link").font(.headline)
                Spacer()
                Button("Map…") { store.showDependencyMap = true }.workbenchLinkStyle().font(.caption).disabled(outgoing.isEmpty && incoming.isEmpty)
                if !showComposer {
                    Button("Add link…") { showComposer = true }.workbenchLinkStyle().font(.caption)
                        .disabled((store.workspace?.notes.count ?? 0) < 2)
                }
            }
            if outgoing.isEmpty && incoming.isEmpty && !showComposer {
                Text((store.workspace?.notes.count ?? 0) < 2
                     ? "Capture another note, then link its definition or assumption here."
                     : "Link a definition, an assumption, or a related note from this document. Inspect it here while keeping your place.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if showComposer { composer }
            ForEach(outgoing) { link in
                if let target = store.linkedNote(id: link.targetNoteID) { linkRow(link, note: target, isIncoming: false) }
            }
            if !incoming.isEmpty {
                Text("Referenced by").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                ForEach(incoming) { link in
                    if let source = store.linkedNote(id: link.sourceNoteID) { linkRow(link, note: source, isIncoming: true) }
                }
            }
        }
        .onChange(of: noteID) { _, _ in reset() }
        .onChange(of: store.workspace?.id) { _, _ in reset() }
        .onChange(of: linkQuery) { _, _ in if selectedTarget == nil { targetID = nil } }
        .onChange(of: linkKind) { _, _ in if selectedTarget == nil { targetID = nil } }
        .sheet(item: $inspectedImage) { preview in
            VStack(alignment: .leading, spacing: 16) {
                Text(preview.title).font(.headline)
                Image(nsImage: preview.image).resizable().scaledToFit().frame(maxWidth: 1000, maxHeight: 700)
                HStack { Spacer(); Button("Done") { inspectedImage = nil }.keyboardShortcut(.cancelAction) }
            }.padding(24).frame(minWidth: 500, minHeight: 240)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Relationship", selection: $linkKind) {
                ForEach(NoteLinkKind.allCases, id: \.self) { kind in Text(kind.label).tag(kind) }
            }.pickerStyle(.menu)
            searchField("Find a note in this document", text: $linkQuery)
            if candidates.isEmpty {
                Text(linkQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "No other notes available for this relationship."
                     : "No matching notes. Try another term.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(candidates) { candidate in
                            Button { targetID = candidate.id } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: targetID == candidate.id ? "checkmark.circle.fill" : candidate.kind.symbol)
                                        .foregroundStyle(targetID == candidate.id ? Color.lemmaOlive : Color.secondary).frame(width: 16)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(candidate.title).font(.callout).lineLimit(2).multilineTextAlignment(.leading)
                                        Text("\(candidate.kind.label) · PDF page \(candidate.anchor.pageIndex + 1)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(targetID == candidate.id ? Color.lemmaOlive.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                            }.buttonStyle(.plain).accessibilityLabel("Link to \(candidate.title), PDF page \(candidate.anchor.pageIndex + 1)")
                        }
                    }
                }.frame(height: min(CGFloat(candidates.count) * 64, 170))
            }
            TextField("How it is used here (optional)", text: $linkUsage, axis: .vertical)
                .lineLimit(1...3).textFieldStyle(.roundedBorder).accessibilityLabel("Reader supplied link usage")
            HStack {
                Button("Cancel") { closeComposer() }.buttonStyle(.borderless)
                Spacer()
                Button("Add link") {
                    guard let target = selectedTarget,
                          store.addNoteLink(from: noteID, to: target.id, kind: linkKind, usage: linkUsage) != nil else { return }
                    closeComposer()
                }.buttonStyle(.borderedProminent).disabled(selectedTarget == nil)
            }
            Text("You choose the relationship and how it applies.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func linkRow(_ link: NoteLink, note: StudyNote, isIncoming: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: link.kind.symbol).font(.callout).foregroundStyle(.secondary).frame(width: 18).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(link.kind.label).font(.caption).foregroundStyle(.secondary)
                    Button {
                        previewLinkID = previewLinkID == link.id ? nil : link.id
                    } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Text(note.title).font(.callout.weight(.medium)).multilineTextAlignment(.leading).lineLimit(3)
                            Image(systemName: previewLinkID == link.id ? "chevron.up" : "chevron.down").font(.caption2).padding(.top, 4)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).accessibilityLabel("\(previewLinkID == link.id ? "Close" : "Inspect") linked note: \(note.title)")
                    Text("PDF page \(note.anchor.pageIndex + 1)").font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    store.removeNoteLink(id: link.id, undoManager: undoManager)
                } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).font(.caption)
                    .help("Remove link (Undo available)").accessibilityLabel("Remove link \(isIncoming ? "from" : "to") \(note.title)")
            }
            if isIncoming {
                if !link.usage.isEmpty { Text(link.usage).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            } else {
                TextField("How it is used here (optional)", text: Binding(
                    get: { store.workspace?.noteLinks.first { $0.id == link.id }?.usage ?? "" },
                    set: { store.updateNoteLinkUsage(id: link.id, usage: $0) }), axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.plain).font(.callout).accessibilityLabel("Usage of linked note \(note.title)")
            }
            if previewLinkID == link.id { preview(note) }
        }.padding(.vertical, 4)
    }

    private func preview(_ note: StudyNote) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(note.kind.label) · \(note.state.label)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open note") { store.openLinkedNote(note.id) }.workbenchLinkStyle().font(.caption)
            }
            if let workspace = store.workspace,
               let image = NSImage(contentsOf: store.repository.assetURL(workspaceID: workspace.id, name: note.anchor.imageName)) {
                Button { inspectedImage = StudyImagePreview(title: "\(note.title) · PDF page \(note.anchor.pageIndex + 1)", image: image) } label: {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 180)
                        .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain).help("Inspect the linked source crop").accessibilityLabel("Inspect source crop of \(note.title)")
            }
            if !note.anchor.quote.isEmpty {
                DisclosureGroup(note.sourceTextOrigin == .ocr ? "Recognized source text · OCR" : "Source text") {
                    Text(note.anchor.quote).font(.callout).textSelection(.enabled).padding(.top, 6)
                }
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !note.notation.isEmpty { previewText("Notation & dimensions", text: note.notation) }
            if !note.scope.isEmpty { previewText("Local scope", text: note.scope) }
            if !note.assumptions.isEmpty { previewText("Reader assumptions", text: note.assumptions) }
            if !note.body.isEmpty {
                Text("My saved reasoning").font(.callout.weight(.medium))
                MathPreview(text: note.body)
            }
            if let explanation = note.explanation {
                DisclosureGroup("Saved explanation") { MathPreview(text: explanation.body).padding(.top, 6) }
                    .font(.callout.weight(.medium))
            }
            Button("Go to source · PDF page \(note.anchor.pageIndex + 1)") { store.reader.go(to: note.anchor) }
                .workbenchLinkStyle().font(.caption)
        }.padding(.top, 6)
    }

    private func previewText(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func closeComposer() {
        showComposer = false; targetID = nil; linkQuery = ""; linkUsage = ""
    }
    private func reset() { closeComposer(); linkKind = .definition; previewLinkID = nil; inspectedImage = nil }
}

@MainActor
extension StudyStore {
    func linkedNote(id: UUID) -> StudyNote? { workspace?.notes.first { $0.id == id } }

    @discardableResult
    func addNoteLink(from sourceID: UUID, to targetID: UUID, kind: NoteLinkKind, usage: String = "") -> NoteLink? {
        guard var workspace, let link = workspace.addNoteLink(from: sourceID, to: targetID, kind: kind, usage: usage) else { return nil }
        self.workspace = workspace
        flush()
        if !saveFailed { status = "Link saved." }
        return link
    }

    func updateNoteLinkUsage(id: UUID, usage: String) {
        guard let index = workspace?.noteLinks.firstIndex(where: { $0.id == id }) else { return }
        workspace?.noteLinks[index].usage = usage
        scheduleSave()
    }

    func removeNoteLink(id: UUID, undoManager: UndoManager?, bookID requestedBookID: String? = nil) {
        guard let workspaceID = requestedBookID ?? workspace?.id,
              let book = app.currentWorkspace(workspaceID) ?? (try? repository.load(id: workspaceID)),
              let index = book.noteLinks.firstIndex(where: { $0.id == id }) else { return }
        let link = book.noteLinks[index]
        guard editAnnotations(in: workspaceID, { $0.noteLinks.removeAll { $0.id == id } }) else { return }
        if let undoManager {
            registerPDFUndo("Delete Link", manager: undoManager) { target in
                target.restoreNoteLink(link, at: index, workspaceID: workspaceID, undoManager: undoManager)
            }
        }
    }

    private func restoreNoteLink(_ link: NoteLink, at index: Int, workspaceID: String, undoManager: UndoManager?) {
        guard let book = app.currentWorkspace(workspaceID) ?? (try? repository.load(id: workspaceID)),
              book.notes.contains(where: { $0.id == link.sourceNoteID }), book.notes.contains(where: { $0.id == link.targetNoteID }),
              !book.noteLinks.contains(where: { $0.id == link.id || ($0.sourceNoteID == link.sourceNoteID && $0.targetNoteID == link.targetNoteID && $0.kind == link.kind) }) else { return }
        guard editAnnotations(in: workspaceID, { $0.noteLinks.insert(link, at: min(index, $0.noteLinks.count)) }) else { return }
        if let undoManager {
            registerPDFUndo("Delete Link", manager: undoManager) { target in
                target.removeNoteLink(id: link.id, undoManager: undoManager, bookID: workspaceID)
            }
        }
    }

    /// Selecting a linked note is explicit; it leaves the PDF at the current place.
    func openLinkedNote(_ id: UUID) {
        guard linkedNote(id: id) != nil else { return }
        noteQuery = ""; noteFilter = .all
        selectNote(id)
    }
}
