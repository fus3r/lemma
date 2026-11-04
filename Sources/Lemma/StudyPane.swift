import SwiftUI
import AppKit
import LemmaCore

struct StudyPane: View {
    @Bindable var store: StudyStore
    @Environment(\.undoManager) private var undoManager
    @State private var inspectedImage: StudyImagePreview?
    @State private var comparison: StudyComparison?
    @State private var previewReasoning = true
    @State private var editExplanation = false
    @State private var showAssumptions = false
    @State private var showRecall = false
    @State private var experimentSession: StudyExperimentSession?

    var body: some View {
        VStack(spacing: 0) {
            if ThemeManager.shared.style == .classic {
            HStack(spacing: 8) {
                Picker("Notebook section", selection: $store.studySection) {
                    ForEach(StudySection.allCases) { section in
                        let due = section == .review ? store.reviewNotes.count : 0
                        Text(due > 0 ? "\(section.title) \(due)" : section.title).tag(section)
                    }
                }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
                Menu {
                    ForEach(NoteKind.allCases, id: \.self) { kind in
                        Button { store.addNote(kind: kind) } label: { Label("New \(kind.label.lowercased())", systemImage: kind.symbol) }.disabled(!store.reader.hasSelection)
                    }
                    Divider()
                    Button("Export study notes…", action: store.exportNotes)
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22).accessibilityLabel("Notebook actions")
                Button(action: store.toggleStudy) { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    .help("Hide notebook · ⌥⌘I").accessibilityLabel("Hide notebook")
            }.padding(.horizontal, 12).frame(height: 46)
            Divider()
            } else {
            HStack(spacing: 0) {
                ForEach(StudySection.allCases) { section in
                    InspectorTitleTab(title: section.title, count: section == .review ? store.reviewNotes.count : nil,
                                      active: store.studySection == section) { store.studySection = section }
                }
                Spacer(minLength: 4)
                VSMenuButton(icon: "ellipsis", help: "Notebook Actions") {
                    NoteKind.allCases.map { kind in .action("New \(kind.label.lowercased())", enabled: store.reader.hasSelection) { store.addNote(kind: kind) } }
                        + [.separator, .action("Export Study Notes…") { store.exportNotes() }, .action("Hide Secondary Side Bar", shortcut: "⌥⌘B") { store.toggleStudy() }]
                }
                VSIconButton(icon: "close", help: "Hide Secondary Side Bar (⌥⌘B)") { store.toggleStudy() }
            }
            .padding(.leading, 8).padding(.trailing, 6)
            .frame(height: VSMetrics.viewTitleHeight)
            }
            switch store.studySection {
            case .page: PageInspector(store: store)
            case .notes, .glossary: notes
            case .references: references
            case .review: ReviewPane(store: store)
            }
        }
        .background(Color.lemmaSidebar)
        .vsBorder(.leading, .sideBarBorder, theme: ThemeManager.shared.colors)
        .sheet(item: $inspectedImage) { preview in
            VStack(alignment: .leading, spacing: 16) {
                Text(preview.title).font(.headline)
                Image(nsImage: preview.image).resizable().scaledToFit().frame(maxWidth: 1000, maxHeight: 700)
                HStack { Spacer(); Button("Done") { inspectedImage = nil }.keyboardShortcut(.cancelAction) }
            }.padding(24).frame(minWidth: 500, minHeight: 240)
        }
        .sheet(item: $comparison) { item in
            VStack(alignment: .leading, spacing: 18) {
                Text("Compare source passages").font(.title2.weight(.semibold))
                Text("Keep the reader’s place while checking the two expressions.").foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 24) {
                    ForEach(item.images) { preview in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(preview.title).font(.headline).lineLimit(3)
                            Image(nsImage: preview.image).resizable().scaledToFit()
                                .frame(width: 422, height: min(420, 422 * preview.image.size.height / max(preview.image.size.width, 1)))
                        }.frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                HStack { Spacer(); Button("Done") { comparison = nil }.keyboardShortcut(.cancelAction) }
            }.padding(26).frame(width: 920)
        }
        .sheet(item: $experimentSession) { session in
            if session.kind == .nearestNeighbors {
                NeighborsExperimentPane(noteID: session.note.id, noteTitle: session.note.title, source: session.note.anchor,
                    storedRecord: session.record, onSave: { store.saveExperiment($0, workspaceID: session.workspaceID) })
                    .tint(.lemmaOlive)
            } else {
                ExperimentPane(noteID: session.note.id, noteTitle: session.note.title, source: session.note.anchor, kind: session.kind,
                    storedRecord: session.record, onSave: { store.saveExperiment($0, workspaceID: session.workspaceID) })
                    .tint(.lemmaOlive)
            }
        }
        .onChange(of: store.noteQuery) { _, _ in selectVisibleNoteIfNeeded() }
        .onChange(of: store.noteFilter) { _, _ in selectVisibleNoteIfNeeded() }
        .onChange(of: store.studySection) { _, section in if section == .notes || section == .glossary { selectVisibleNoteIfNeeded() } }
        .onChange(of: store.selectedNoteID) { _, _ in previewReasoning = true; editExplanation = false; showAssumptions = false; showRecall = false }
    }
    private var notes: some View {
        // Filtered and sorted once per redraw: typing in a note redraws the pane on every keystroke.
        let visible = store.visibleNotes
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                searchField(store.studySection == .glossary ? "Find a term or symbol" : "Search these notes", text: $store.noteQuery)
                Menu {
                    Picker("Note state", selection: $store.noteFilter) { ForEach(NoteFilter.allCases) { filter in Text(filter.title).tag(filter) } }
                } label: { Image(systemName: store.noteFilter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill") }
                    .menuStyle(.borderlessButton).frame(width: 22).accessibilityLabel("Filter notes").help("Filter by Open, Understood, or Revisit")
            }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            ResizablePair(store: store, id: "inspector." + store.studySection.rawValue, axis: .horizontal,
                          minimumFirst: 44, minimumSecond: 140,
                          preferredFirst: min(CGFloat(visible.count) * 76 + 8, 190), showsSecond: !visible.isEmpty) {
                if visible.isEmpty { noteDetail }
                else { ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(visible) { note in
                            Button { store.selectNote(note.id) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: note.kind.symbol).frame(width: 18).foregroundStyle(note.id == store.selectedNoteID ? Color.lemmaOlive : Color.secondary).padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(note.title).font(.callout.weight(note.id == store.selectedNoteID ? .semibold : .regular)).lineLimit(2).multilineTextAlignment(.leading)
                                        HStack(spacing: 7) {
                                            Text("p. \(note.anchor.pageIndex + 1)").monospacedDigit()
                                            Label(note.state.label, systemImage: note.state.symbol)
                                            if note.pendingRequestID != nil { Image(systemName: "clock") }
                                        }.font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(note.id == store.selectedNoteID ? Color.lemmaOliveSelection : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain).contextMenu {
                                Button("Go to source") { store.reader.go(to: note.anchor) }
                                Button("Pin as context") { store.pinNote(note) }
                                Menu("Collect Source in Project") {
                                    ForEach(store.activeProjects) { project in Button(project.title) { store.collectNote(note, projectID: project.id) } }
                                    Button("New Project…") { if let id = store.newProject() { store.collectNote(note, projectID: id) } }
                                }
                                if note.isInReview { Button("Remove from review") { store.removeFromReview(id: note.id) } }
                                else { Button("Add to review") { store.addToReview(id: note.id) } }
                                Divider()
                                Button("Delete note", role: .destructive) { store.removeNote(id: note.id, undoManager: undoManager) }.disabled(note.pendingRequestID != nil)
                            }
                        }
                    }.padding(.horizontal, 8).padding(.bottom, 8)
                } }
            } second: { noteDetail }
        }
    }
    @ViewBuilder private var noteDetail: some View {
            if let note = store.currentNote, (store.studySection != .glossary || note.kind.isGlossary) {
                ScrollView {
                    noteEditor(note).padding(20)
                }
            } else {
                PaneEmptyState(symbol: store.studySection == .glossary ? "text.book.closed" : "square.and.pencil",
                    title: store.noteQuery.isEmpty ? (store.studySection == .glossary ? "Build your local glossary" : "Work through the difficult step") : "No matching notes",
                    message: store.noteQuery.isEmpty ? (store.studySection == .glossary ? "Capture a definition, notation, or theorem from the page. Name it and record its dimensions or local convention." : "Select a passage or draw a region, then add a question. Keep your own attempt beside its source.") : "Try another term or change the state filter.")
            }
    }
    private func noteEditor(_ note: StudyNote) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(NoteKind.allCases, id: \.self) { kind in Button(kind.label) { store.updateNote(id: note.id) { $0.kind = kind } } }
                } label: { Label(note.kind.label, systemImage: note.kind.symbol).font(.caption.weight(.medium)) }.menuStyle(.borderlessButton).fixedSize()
                Spacer()
                let understanding = Binding(get: { store.workspace?.notes.first { $0.id == note.id }?.state ?? .open }, set: { value in store.updateNote(id: note.id) { $0.state = value } })
                if ThemeManager.shared.style == .vscode {
                    // The theme's dropdown: a native pop-up takes the accent as its fill.
                    VSDropdown(options: NoteState.allCases.map { ($0, $0.label) }, selection: understanding, width: 120)
                        .accessibilityLabel("Note understanding state")
                } else {
                    Picker("Understanding", selection: understanding) {
                        ForEach(NoteState.allCases, id: \.self) { state in Text(state.label).tag(state) }
                    }.labelsHidden().fixedSize().accessibilityLabel("Note understanding state").font(.caption)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Source · PDF page \(note.anchor.pageIndex + 1)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Go to source") { store.reader.go(to: note.anchor) }.workbenchLinkStyle().font(.caption)
                }
                if let image = image(for: note.anchor) {
                    Button { inspectedImage = StudyImagePreview(title: "\(note.kind.label) · PDF page \(note.anchor.pageIndex + 1)", image: image) } label: {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 140).padding(8).background(.white, in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain).help("Inspect the source crop").accessibilityLabel("Inspect source crop")
                }
                if let figure = note.figureName, let workspaceID = store.workspace?.id,
                   let image = store.lab.image(named: figure, workspaceID: workspaceID, repository: store.repository) {
                    Text("Figure in the margin").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Button { inspectedImage = StudyImagePreview(title: note.title, image: image) } label: {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 220)
                            .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain).help("Inspect the figure").accessibilityLabel("Inspect the margin figure")
                }
                if !note.anchor.quote.isEmpty {
                    DisclosureGroup(note.sourceTextOrigin == .ocr ? "Recognized source text · OCR" : "Extracted source text") {
                        Text(note.anchor.quote).font(.callout).textSelection(.enabled).padding(.top, 6)
                        if note.sourceTextOrigin == .ocr { Text("Saved from local text recognition. Use the crop to check symbols and reading order.").font(.caption).foregroundStyle(.secondary) }
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(note.kind.isGlossary ? "Term or title" : note.kind == .comment ? "Title (optional)" : "Question").font(.headline)
                TextField(note.kind.isGlossary ? "Name the term, symbol, or claim" : note.kind == .comment ? "By default, the first line of the note" : "What needs explaining?", text: binding(note, \.question), axis: .vertical)
                    .lineLimit(2...6).textFieldStyle(.plain).font(.system(size: 15, weight: .medium)).padding(10)
                    .workbenchInputBox().accessibilityLabel("Study question or title")
            }
            if note.kind.isGlossary {
                input("Lookup names", placeholder: "One term or symbol per line, as it appears in the PDF", text: binding(note, \.lookupTerms))
            }
            if note.kind == .notation || !note.notation.isEmpty {
                input("Notation & dimensions", placeholder: "For example: X ∈ ℝⁿˣᵖ, observations in rows", text: binding(note, \.notation))
            }
            if note.kind.isGlossary || !note.scope.isEmpty {
                input("Local scope", placeholder: "Where does this convention apply?", text: binding(note, \.scope))
            }
            DisclosureGroup("Assumptions to check", isExpanded: $showAssumptions) {
                TextField("State the assumptions in your own words", text: binding(note, \.assumptions), axis: .vertical).lineLimit(2...6).textFieldStyle(.roundedBorder).padding(.top, 8).accessibilityLabel("Reader supplied assumptions")
            }.font(.callout.weight(.medium))
            NoteLinksPane(store: store, noteID: note.id)
            recallSection(note)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(note.kind == .definition || note.kind == .notation ? "My understanding" : "My reasoning").font(.headline)
                    Spacer()
                    Button(previewReasoning ? "Edit" : "Preview") { previewReasoning.toggle() }.workbenchLinkStyle().font(.caption)
                        .accessibilityIdentifier("note.reasoning.mode")
                }
                if previewReasoning {
                    if note.body.isEmpty { Text("No reasoning yet. Choose Edit to add your notes.").font(.callout).foregroundStyle(.secondary) }
                    else { MathPreview(text: note.body) }
                }
                else {
                    TextEditor(text: binding(note, \.body)).font(.body).frame(minHeight: 110, maxHeight: 230).scrollContentBackground(.hidden)
                        .padding(6).workbenchInputBox().accessibilityLabel("My reasoning")
                    Text("Markdown and LaTeX supported").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Button { store.showQuestion = true } label: { Label("Get help…", systemImage: "text.bubble") }.workbenchButton(.primary)
                    .disabled(note.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || note.pendingRequestID != nil)
                Button { store.pinNote(note) } label: { Image(systemName: "pin") }.help("Use this note’s source as context").buttonStyle(.borderless)
                Spacer()
                Button(role: .destructive) { store.removeNote(id: note.id, undoManager: undoManager) } label: {
                    Image(systemName: "trash").foregroundStyle(.primary).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .disabled(note.pendingRequestID != nil)
                    .help(note.pendingRequestID == nil ? "Delete note · Undo with ⌘Z" : "Cancel the pending question before deleting this note")
                    .accessibilityLabel("Delete note: \(note.title)")
                Menu {
                    if showsStatisticsExperiments(note) {
                        Button("Run ridge experiment…") { openExperiment(for: note) }
                        Button("Run Lasso experiment…") { openExperiment(for: note, kind: .lasso) }
                        Button("Least squares vs nearest neighbours (ESL 2.3)…") { openExperiment(for: note, kind: .nearestNeighbors) }
                    }
                    Button("Paste explanation", action: store.pasteExplanation)
                    Button("Copy source image", action: store.copySource)
                    Button("Copy question", action: store.copyPrompt)
                    Button("Review this note") { store.addToReview(id: note.id); store.studySection = .review }
                    if note.pendingRequestID != nil {
                        Button("Cancel question") { store.cancelQuestion(noteID: note.id) }
                    }
                    Divider()
                    Button("Delete note", role: .destructive) { store.removeNote(id: note.id, undoManager: undoManager) }.disabled(note.pendingRequestID != nil)
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22).accessibilityLabel("Note actions")
            }
            if note.pendingRequestID != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(store.browserStatus.isEmpty ? "Waiting for the assistant…" : store.browserStatus)
                    Button("Show") { store.questions.selectedID = note.pendingRequestID; store.questions.panel = "requests"; store.showBrowserSetup = true }
                        .workbenchButton(compact: true)
                    Button("Cancel") { store.cancelQuestion(noteID: note.id) }.workbenchButton(compact: true)
                }.font(.caption).foregroundStyle(.secondary)
            }
            if showsStatisticsExperiments(note) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Experiments", systemImage: "slider.horizontal.3").font(.callout.weight(.medium))
                        Spacer()
                        Button("Try ridge…") { openExperiment(for: note) }.workbenchLinkStyle().font(.caption)
                        Button("Lasso…") { openExperiment(for: note, kind: .lasso) }.workbenchLinkStyle().font(.caption)
                        Button("k-NN…") { openExperiment(for: note, kind: .nearestNeighbors) }.workbenchLinkStyle().font(.caption)
                            .help("Least squares and nearest neighbours on ESL’s simulated mixture (Figures 2.1–2.5)")
                        Button("Lab…") {
                            store.newLab(source: LabSource(pageIndex: note.anchor.pageIndex, region: note.anchor.region, label: note.title, quote: note.anchor.quote))
                        }.workbenchLinkStyle().font(.caption).help("A Python notebook from this note's source")
                    }
                    if note.experiments.isEmpty {
                        Text("Predict, then explore: shrinkage with correlated predictors, or least squares against nearest neighbours. Record the result with this source.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(note.experiments) { record in
                            Button { openExperiment(for: note, record: record) } label: {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(record.kind == .nearestNeighbors ? "\(record.kind.label) · \(record.neighbors?.summary ?? "")"
                                             : "\(record.kind.label) · λ = \(record.parameters.lambda.formatted(.number.precision(.fractionLength(0...3))))").font(.callout)
                                        Text(record.prediction).font(.caption).lineLimit(2).multilineTextAlignment(.leading).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).accessibilityLabel("Open saved \(record.kind.label) experiment")
                        }
                    }
                }
            } else {
                // Every book can try a passage in Python; the statistics experiments are for statistical learning books.
                HStack {
                    Label("Try it", systemImage: "slider.horizontal.3").font(.callout.weight(.medium))
                    Spacer()
                    Button("Open in the Lab…") {
                        store.newLab(source: LabSource(pageIndex: note.anchor.pageIndex, region: note.anchor.region, label: note.title, quote: note.anchor.quote))
                    }.workbenchLinkStyle().font(.caption).help("A Python notebook from this note's source")
                }
            }
            Divider()
            if let explanation = note.explanation {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Saved explanation", systemImage: "text.bubble").font(.headline)
                        Spacer()
                        Button(editExplanation ? "Done" : "Edit") { editExplanation.toggle() }.workbenchLinkStyle().font(.caption)
                    }
                    if editExplanation {
                        TextEditor(text: Binding(get: { store.workspace?.notes.first { $0.id == note.id }?.explanation?.body ?? "" }, set: { value in store.updateNote(id: note.id) { $0.explanation?.body = value } }))
                            .font(.body).frame(minHeight: 250).accessibilityLabel("Saved explanation source")
                    } else { MathPreview(text: explanation.body) }
                    HStack {
                        Text(explanation.savedAt.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                        if let provider = explanation.provider { Text(provider.label + (explanation.model.map { " · \($0)" } ?? "")) }
                        Spacer()
                        // Parsed once per text, not on every redraw of the note.
                        let summary = store.explanationSummary(noteID: note.id, body: explanation.body)
                        let steps = summary.steps
                        if steps > 0 {
                            Button { store.checkAnswerSteps(noteID: note.id) } label: {
                                Label("Check \(steps) \(steps == 1 ? "step" : "steps")", systemImage: "checkmark.seal")
                            }.workbenchLinkStyle().help("Open the answer's displayed equations as a derivation: Lemma tests every step on random values, on this Mac.")
                        }
                        let blocks = summary.codeBlocks
                        if blocks > 0 {
                            Button { store.openExplanationCode(noteID: note.id) } label: {
                                Label(blocks == 1 ? "Open code in Lab" : "Open \(blocks) code blocks in Lab", systemImage: "flask")
                            }.workbenchLinkStyle().help("Copy the answer's Python into a notebook beside the page. Nothing runs until you run a cell.")
                        }
                        if let raw = explanation.conversationURL, let url = URL(string: raw) {
                            Button("Conversation") { store.questions.showConversation(url); store.showBrowserSetup = true }.workbenchLinkStyle().disabled(store.questions.webBusy)
                        }
                    }.font(.caption)
                }
            } else {
                HStack(spacing: 8) { Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary); Button("Paste a copied explanation", action: store.pasteExplanation).workbenchLinkStyle().font(.callout) }
            }
        }
    }
    private func recallSection(_ note: StudyNote) -> some View {
        DisclosureGroup(isExpanded: $showRecall) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if note.isInReview {
                        Label(note.isDue() ? "Due now" : "Next recall in \(ReviewScheduler.describe(max(60, (note.reviewDueAt ?? .now).timeIntervalSinceNow)))", systemImage: "calendar")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove") { store.removeFromReview(id: note.id) }.workbenchLinkStyle().font(.caption)
                    } else {
                        Text("Not in review").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Add to review") { store.addToReview(id: note.id) }.workbenchLinkStyle().font(.caption)
                    }
                }
                TextField("Recall prompt, e.g. “Why does the optimum lie on an axis?”", text: binding(note, \.recallPrompt), axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.roundedBorder).accessibilityLabel("Recall prompt")
                if let image = image(for: note.anchor) {
                    MaskEditor(image: image, region: note.anchor.region, masks: Binding(
                        get: { store.workspace?.notes.first { $0.id == note.id }?.masks ?? [] },
                        set: { value in store.updateNote(id: note.id) { $0.masks = value } }))
                }
            }.padding(.top, 8)
        } label: {
            Label(note.masks.isEmpty ? "Recall" : "Recall · \(note.masks.count) hidden", systemImage: "arrow.clockwise").font(.callout.weight(.medium))
        }
    }

    private var references: some View {
        Group {
            if store.workspace?.pins.isEmpty != false {
                PaneEmptyState(symbol: "pin", title: "Keep the earlier line close", message: "Select a definition, equation, or figure and pin it. Inspect it here without moving the reader, or compare it with your note’s source.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Choose the references to include when preparing a question.").font(.callout).foregroundStyle(.secondary).lineSpacing(3)
                        ForEach(store.workspace?.pins ?? []) { pin in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(Color.lemmaOlive).padding(.top, 3)
                                    TextField("Reference name", text: Binding(get: { store.workspace?.pins.first { $0.id == pin.id }?.label ?? "" }, set: { store.updatePin(id: pin.id, label: $0) }), axis: .vertical).lineLimit(1...3).textFieldStyle(.plain).font(.callout.weight(.semibold))
                                    Menu {
                                        Button("Compare with current source") { compare(pin) }.disabled(store.currentNote == nil)
                                        Button("Remove reference") { store.removePin(id: pin.id) }
                                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 18).accessibilityLabel("Reference actions")
                                }
                                if let image = image(for: pin.anchor) {
                                    Button { inspectedImage = StudyImagePreview(title: pin.label, image: image) } label: {
                                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 180).padding(8).background(.white, in: RoundedRectangle(cornerRadius: 5))
                                    }.buttonStyle(.plain).accessibilityLabel("Inspect \(pin.label)")
                                }
                                HStack {
                                    Button("PDF page \(pin.anchor.pageIndex + 1) ↗") { store.reader.go(to: pin.anchor) }.buttonStyle(.link)
                                    Spacer()
                                    Button("Compare") { compare(pin) }.buttonStyle(.borderless).disabled(store.currentNote == nil)
                                }.font(.caption)
                            }
                            Divider()
                        }
                    }.padding(20)
                }
            }
        }
    }
    private func input(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.callout.weight(.medium)); TextField(placeholder, text: text, axis: .vertical).lineLimit(1...4).textFieldStyle(.roundedBorder).accessibilityLabel(title) }
    }
    private func binding(_ note: StudyNote, _ path: WritableKeyPath<StudyNote, String>) -> Binding<String> {
        Binding(get: { store.workspace?.notes.first { $0.id == note.id }?[keyPath: path] ?? "" }, set: { value in store.updateNote(id: note.id) { $0[keyPath: path] = value } })
    }
    /// The source crop, decoded once (not read from disk on every redraw).
    private func image(for anchor: SourceAnchor) -> NSImage? {
        guard let book = store.workspace else { return nil }
        return store.assetImage(workspaceID: book.id, name: anchor.imageName)
    }
    private func compare(_ pin: ContextPin) {
        guard let note = store.currentNote, let source = image(for: note.anchor), let reference = image(for: pin.anchor) else { return }
        comparison = StudyComparison(images: [StudyImagePreview(title: "Current source · PDF page \(note.anchor.pageIndex + 1)", image: source), StudyImagePreview(title: "\(pin.label) · PDF page \(pin.anchor.pageIndex + 1)", image: reference)])
    }
    /// Ridge, Lasso and ESL §2.3's nearest-neighbour simulation belong to statistical learning books (ESL, ISL and their
    /// relatives); elsewhere they would only be noise. A note that already holds an experiment keeps showing them.
    private func showsStatisticsExperiments(_ note: StudyNote) -> Bool {
        if !note.experiments.isEmpty { return true }
        let title = (store.workspace?.title ?? "").lowercased()
        return ["statistical learning", "elements of statistical", "learning with sparsity", "computer age statistical"].contains { title.contains($0) }
    }

    private func openExperiment(for note: StudyNote, record: ExperimentRecord? = nil, kind: ExperimentKind = .ridge) {
        guard let workspaceID = store.workspace?.id else { return }
        experimentSession = StudyExperimentSession(workspaceID: workspaceID, note: note, record: record, kind: record?.kind ?? kind)
    }
    private func selectVisibleNoteIfNeeded() {
        let visible = store.visibleNotes
        if !visible.contains(where: { $0.id == store.selectedNoteID }) { store.selectedNoteID = visible.first?.id }
    }
}

struct StudyImagePreview: Identifiable { let id = UUID(); let title: String; let image: NSImage }
struct StudyComparison: Identifiable { let id = UUID(); let images: [StudyImagePreview] }
struct StudyExperimentSession: Identifiable {
    let id = UUID()
    let workspaceID: String
    let note: StudyNote
    let record: ExperimentRecord?
    let kind: ExperimentKind
}

/// A title in the secondary side bar's composite bar: uppercase, underlined in the accent when active.
struct InspectorTitleTab: View {
    @Environment(\.theme) private var theme
    let title: String
    var count: Int? = nil
    let active: Bool
    let select: () -> Void
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 4) {
            Text(title.uppercased()).font(.ui(11)).lineLimit(1)
            if let count, count > 0 { VSBadge(count: count) }
        }
        .foregroundStyle(theme[active || hovering ? .panelTitleActiveForeground : .panelTitleInactiveForeground])
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) { if active { Rectangle().fill(theme[.panelTitleActiveBorder]).frame(height: 1).padding(.bottom, 6) } }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
    }
}
