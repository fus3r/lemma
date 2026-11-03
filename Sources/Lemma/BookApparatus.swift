import SwiftUI
import AppKit
import PDFKit
import LemmaCore

@MainActor
extension StudyStore {
    /// The physical page of a printed page label from the book's index or a citation.
    func pageIndex(forPrinted label: String) -> Int? {
        if let numbering = analysis?.numbering, let index = numbering.pageIndex(forLabel: label) { return index }
        guard let number = Int(label), number >= 1, number <= (document?.pageCount ?? 0) else { return nil }
        return number - 1
    }

    /// Lists an index entry's pages in the References panel and goes to the first one, with the term selected.
    func openIndexEntry(_ entry: BookIndexEntry) {
        var entry = entry
        if entry.locators.isEmpty, let see = entry.see.first, let target = analysis?.analysis?.index.first(where: { $0.title.caseInsensitiveCompare(see) == .orderedSame || $0.term.caseInsensitiveCompare(see) == .orderedSame }) {
            entry = target
        }
        showReferences(.indexEntry(entry))
        if let first = entry.locators.first, let page = pageIndex(forPrinted: first.first) { goToTerm(entry.term, onPage: page) }
    }

    /// Moves to a page and selects the first occurrence of a term there, keeping Back available.
    func goToTerm(_ term: String, onPage pageIndex: Int, inSplit: Bool = false) {
        guard let page = document?.page(at: pageIndex) else { return }
        if inSplit { openToSide(page: pageIndex, title: term); return }
        if let range = Self.occurrence(of: term, in: page.string ?? ""), let selection = page.selection(for: range) {
            reader.view?.go(to: selection)
            reader.view?.setCurrentSelection(selection, animate: true)
            reader.flash(selection.bounds(for: page).insetBy(dx: -3, dy: -2), onPage: pageIndex)
        } else {
            reader.goToPage(pageIndex + 1)
        }
    }

    /// The first place a term occurs in a page's text, tolerating case, accents, hyphenation and plurals.
    static func occurrence(of term: String, in text: String) -> NSRange? {
        let string = text as NSString
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let cleaned = TextRepair.repaired(term).replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        var candidates = [cleaned]
        if cleaned.hasSuffix("s") { candidates.append(String(cleaned.dropLast())) }
        if let first = cleaned.split(separator: " ").first(where: { $0.count >= 4 }) { candidates.append(String(first)) }
        for candidate in candidates where !candidate.isEmpty {
            let words = candidate.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = words.joined(separator: #"[\s\-‐–]*"#)
            if let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: string.length)) { return match.range }
            let range = string.range(of: candidate, options: options)
            if range.location != NSNotFound { return range }
        }
        return nil
    }

    /// Goes to the place the book introduces a term, selected and briefly outlined (Back returns), or opens it beside the page.
    func goToDefinedTerm(_ term: DefinedTerm, side: Bool = false) {
        if side { openToSide(page: term.pageIndex, title: term.surface); return }
        guard let page = document?.page(at: term.pageIndex) else { return }
        if let range = term.locate(in: page.string ?? "") { goToMention(pageIndex: term.pageIndex, range: range) }
        else { goToTerm(term.surface, onPage: term.pageIndex) }
    }

    /// Terms the book introduces on a page.
    func definedTerms(onPage pageIndex: Int) -> [DefinedTerm] {
        (analysis?.analysis?.terms ?? []).filter { $0.pageIndex == pageIndex }
    }

    /// Goes to a mention found by the analysis and selects it. When `expected` is given and the reader's text no longer
    /// has it at that range (PDFKit can order a page's text differently in another document instance), the nearest
    /// occurrence of the expected words is selected instead.
    func goToMention(pageIndex: Int, range: NSRange, expected: String? = nil) {
        guard let page = document?.page(at: pageIndex) else { return }
        var range = range
        if let expected, !expected.isEmpty, let text = page.string {
            let probe = DefinedTerm(term: expected, surface: expected, pageIndex: pageIndex, range: range, before: "", after: "",
                                    definitional: false, inIndex: false, occurrences: 1)
            if let located = probe.locate(in: text) { range = located }
        }
        if let selection = page.selection(for: range) {
            reader.view?.go(to: selection)
            reader.view?.setCurrentSelection(selection, animate: true)
            reader.flash(selection.bounds(for: page).insetBy(dx: -3, dy: -2), onPage: pageIndex)
        } else { reader.goToPage(pageIndex + 1) }
    }

    // MARK: Exercises

    func exerciseStatus(_ number: String) -> ExerciseStatus { workspace?.exercise(number)?.status ?? .todo }

    func setExercise(_ number: String, status: ExerciseStatus) {
        guard workspace != nil else { return }
        if let index = workspace?.exercises.firstIndex(where: { $0.number == number }) {
            workspace?.exercises[index].status = status; workspace?.exercises[index].updatedAt = .now
        } else {
            workspace?.exercises.append(ExerciseRecord(number: number, status: status))
        }
        scheduleSave()
    }

    /// Opens the reader's working note for an exercise, creating it from the exercise's text on first use.
    func workOnExercise(_ target: ReferenceTarget) {
        guard let workspace, let document, let page = document.page(at: target.pageIndex) else { return }
        let number = target.key.number
        if let id = workspace.exercise(number)?.noteID, workspace.notes.contains(where: { $0.id == id }) {
            selectNote(id); reader.go(to: workspace.notes.first { $0.id == id }!.anchor); return
        }
        do {
            let data = try PDFRegionRenderer.png(page: page, region: target.region)
            let name = "\(UUID().uuidString).png"
            try repository.saveImage(data, workspaceID: workspace.id, name: name)
            let anchor = SourceAnchor(pageIndex: target.pageIndex, pageLabel: printedLabel(for: target.pageIndex) ?? page.label ?? String(target.pageIndex + 1),
                                      region: target.region, quote: page.selection(for: target.region.rect)?.string ?? "", imageName: name)
            let note = StudyNote(anchor: anchor, question: "Exercise \(number)")
            self.workspace?.notes.insert(note, at: 0)
            if let bookID = self.workspace?.id { registerNoteCreationUndo(note, bookID: bookID) }
            if let index = self.workspace?.exercises.firstIndex(where: { $0.number == number }) {
                self.workspace?.exercises[index].noteID = note.id
                if self.workspace?.exercises[index].status == .todo { self.workspace?.exercises[index].status = .attempted }
            } else {
                self.workspace?.exercises.append(ExerciseRecord(number: number, status: .attempted, noteID: note.id))
            }
            selectedNoteID = note.id
            revealStudy(); studySection = .notes
            flush()
            status = "Exercise \(number): write your attempt in the notebook."
        } catch { self.error = "Could not start a note for Exercise \(number): \(error.localizedDescription)" }
    }
}

/// Equations, figures, tables, algorithms, exercises and statements by chapter, from the whole-book analysis.
struct SymbolsSidebar: View {
    @Bindable var store: StudyStore
    @State private var filter = ""
    @State private var kind: ReferenceKind? = nil
    @State private var expanded: Set<String> = []
    @State private var captions: [ReferenceKey: String] = [:]

    private static let kinds: [ReferenceKind] = [.equation, .figure, .table, .algorithm, .exercise, .theorem]

    var body: some View {
        VStack(spacing: 0) {
            searchField("Filter: 3.4, figure, ridge…", text: $filter).padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
            kindPicker.padding(.horizontal, 10).padding(.bottom, 8)
            Divider()
            content
        }
        .onAppear(perform: expandCurrentChapter)
        .onChange(of: store.workspace?.id) { _, _ in expanded = []; captions = [:]; expandCurrentChapter() }
    }

    private var kindPicker: some View {
        HStack(spacing: 4) {
            chip("All", selected: kind == nil) { kind = nil }
            ForEach(Self.kinds, id: \.self) { item in
                chip(short(item), selected: kind == item) { kind = kind == item ? nil : item }.help(item.label + "s")
            }
        }
    }

    private func short(_ kind: ReferenceKind) -> String {
        switch kind { case .equation: "Eq"; case .figure: "Fig"; case .table: "Tab"; case .algorithm: "Alg"; case .exercise: "Ex"; case .theorem: "Thm"; default: kind.label }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 6).frame(height: 20)
                .background(selected ? Color.lemmaOlive.opacity(0.18) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(selected ? Color.lemmaOlive : Color.secondary)
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var content: some View {
        if store.document == nil {
            PaneEmptyState(symbol: "function", title: "The book's numbered objects", message: "Open a book: Lemma lists its equations, figures, tables, algorithms and exercises by chapter.")
        } else if let analysis = store.analysis?.analysis {
            let groups = chapterGroups(analysis)
            if groups.isEmpty {
                PaneEmptyState(symbol: "function", title: filter.isEmpty ? "No numbered objects" : "No matches",
                               message: filter.isEmpty ? "Lemma recognises labels such as “(2.3)”, “FIGURE 2.1”, “Algorithm 3.1” or “Ex. 2.8”. This document may number them differently." : "Try a number such as 3.4, or a kind such as figure.")
            } else {
                if kind == .exercise { exerciseSummary(groups.flatMap(\.targets)).padding(.horizontal, 12).padding(.vertical, 6); Divider() }
                List {
                    ForEach(groups, id: \.id) { group in
                        DisclosureGroup(isExpanded: binding(for: group.id)) {
                            ForEach(group.targets, id: \.key) { target in row(target) }
                        } label: {
                            HStack {
                                Text(group.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(group.targets.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden).environment(\.defaultMinListRowHeight, 22)
            }
        } else if let progress = store.analysis?.progress {
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0)
                Text(progress.total > 0 ? "Reading page \(progress.done) of \(progress.total)…" : "Reading the book…").font(.callout)
                Text("Lemma reads the book once on this Mac. Symbols, the index and references appear when it finishes.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(16)
        } else {
            PaneEmptyState(symbol: "exclamationmark.triangle", title: "Not read yet", message: "Lemma could not read this book's text layer. Scanned pages need OCR first.")
        }
    }

    private struct ChapterGroup { let id: String; let title: String; let targets: [ReferenceTarget] }

    private func chapterGroups(_ analysis: BookAnalysis) -> [ChapterGroup] {
        let chapters = store.outline.compactMap { entry in entry.pageIndex.map { (entry, $0) } }
        var seen = Set<ReferenceKey>()
        let query = filter.trimmingCharacters(in: .whitespaces)
        let targets = analysis.definitions.filter { target in
            guard Self.kinds.contains(target.key.kind), kind == nil || target.key.kind == kind, seen.insert(target.key).inserted else { return false }
            guard !query.isEmpty else { return true }
            return PaletteProvider.score(target.key.spokenTitle + " " + (caption(target) ?? ""), query) != nil
        }.sorted { $0.pageIndex == $1.pageIndex ? $0.anchor.y > $1.anchor.y : $0.pageIndex < $1.pageIndex }
        var groups: [ChapterGroup] = []
        var current: (id: String, title: String, targets: [ReferenceTarget])?
        for target in targets {
            let chapter = chapters.last { $0.1 <= target.pageIndex }
            let id = chapter?.0.id ?? "front", title = chapter?.0.title ?? "Front matter"
            if current?.id != id {
                if let current { groups.append(ChapterGroup(id: current.id, title: current.title, targets: current.targets)) }
                current = (id, title, [])
            }
            current?.targets.append(target)
        }
        if let current { groups.append(ChapterGroup(id: current.id, title: current.title, targets: current.targets)) }
        return groups
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { !filter.isEmpty || expanded.contains(id) }, set: { value in if value { expanded.insert(id) } else { expanded.remove(id) } })
    }

    private func expandCurrentChapter() {
        if let chapter = store.breadcrumb().first { expanded.insert(chapter.id) }
    }

    private func row(_ target: ReferenceTarget) -> some View {
        let count = store.analysis?.mentionCounts[target.key] ?? 0
        let onPage = target.pageIndex == store.reader.focusPageIndex
        return HStack(spacing: 6) {
            if target.key.kind == .exercise {
                let status = store.exerciseStatus(target.key.number)
                Button { store.setExercise(target.key.number, status: status.next) } label: {
                    Image(systemName: status.symbol).foregroundStyle(status == .todo ? Color.secondary : Color.lemmaOlive)
                }.buttonStyle(.plain).help("\(status.label) · click for \(status.next.label.lowercased())").accessibilityLabel("Exercise \(target.key.number): \(status.label)")
            } else {
                Image(systemName: target.key.kind.symbol).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(target.key.kind == .equation ? target.key.title : target.key.spokenTitle)
                    .font(target.key.kind == .equation ? .system(size: 12).monospaced() : .system(size: 12, weight: onPage ? .semibold : .regular))
                if let caption = caption(target), target.key.kind != .equation {
                    Text(caption).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 4).background(Color.primary.opacity(0.07), in: Capsule()).help("\(count) references in the text")
            }
            Text(store.printedLabel(for: target.pageIndex) ?? String(target.pageIndex + 1)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.option) { store.openToSide(target) } else { store.goToReference(target) }
        }
        .contextMenu {
            Button("Go to \(target.key.title)") { store.goToReference(target) }
            Button("Open to the Side") { store.openToSide(target) }
            Button("Find All References") { store.showReferences(.object(target.key)) }.disabled(count == 0)
            Button("Pin to Context") { store.pinReference(target) }
            if target.key.kind == .equation {
                Button("Read Formula as LaTeX…") { store.readFormula(target) }
            }
            if target.key.kind == .exercise {
                Divider()
                Button("Work on This Exercise") { store.workOnExercise(target) }
                ForEach(ExerciseStatus.allCases, id: \.self) { status in
                    Button("Mark \(status.label)") { store.setExercise(target.key.number, status: status) }
                }
            }
        }
        .help("\(target.key.spokenTitle) · \(store.pageText(target.pageIndex)) · ⌥-click opens it to the side")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func caption(_ target: ReferenceTarget) -> String? {
        guard [.figure, .table, .algorithm, .exercise, .theorem].contains(target.key.kind) else { return nil }
        if let cached = captions[target.key] { return cached.isEmpty ? nil : cached }
        guard let page = store.document?.page(at: target.pageIndex) else { return nil }
        let line = CGRect(x: target.anchor.x, y: target.anchor.y - 1, width: max(target.region.width, target.anchor.width), height: target.anchor.height + 2)
        var text = TextRepair.repaired(page.selection(for: line)?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let label = target.key.spokenTitle
        for prefix in [label.uppercased() + ".", label + ".", label.uppercased(), label, "Ex. \(target.key.number)", "Algorithm \(target.key.number)"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " .:"))
            break
        }
        DispatchQueue.main.async { captions[target.key] = text }
        return text.isEmpty ? nil : text
    }

    private func exerciseSummary(_ targets: [ReferenceTarget]) -> some View {
        let statuses = targets.map { store.exerciseStatus($0.key.number) }
        let solved = statuses.filter { $0 == .solved }.count, attempted = statuses.filter { $0 == .attempted }.count
        return VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: targets.isEmpty ? 0 : Double(solved) / Double(targets.count)).tint(.lemmaOlive)
            Text("\(solved) solved · \(attempted) attempted · \(targets.count) exercises").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The book's back-of-book index, searchable. Choosing a term lists its pages with the term in context.
struct BookIndexSidebar: View {
    @Bindable var store: StudyStore
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            searchField("Find a term in the book's index", text: $query).padding(10)
            Divider()
            content
        }
    }

    @ViewBuilder private var content: some View {
        if store.document == nil {
            PaneEmptyState(symbol: "character.book.closed", title: "The book's own index", message: "Open a book with an index at the back: its terms become searchable and every page reference opens in place.")
        } else if let analysis = store.analysis?.analysis {
            if analysis.index.isEmpty {
                PaneEmptyState(symbol: "character.book.closed", title: "No back-of-book index found",
                               message: "Lemma looks for an outline entry named “Index”. Papers rarely have one; ⌘F and the Search view still find any word, and ⌘-click looks a term up in your glossary.")
            } else {
                let entries = query.trimmingCharacters(in: .whitespaces).isEmpty ? analysis.index : BookIndexSearch.find(query, in: analysis.index, limit: 300).map(\.entry)
                if entries.isEmpty {
                    PaneEmptyState(symbol: "magnifyingglass", title: "Not in the index", message: "Try a shorter form of the term, or search the text with ⌘F.")
                } else {
                    List(entries) { entry in row(entry, searching: !query.isEmpty) }
                        .listStyle(.sidebar).scrollContentBackground(.hidden).environment(\.defaultMinListRowHeight, 22)
                }
            }
        } else if let progress = store.analysis?.progress {
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0)
                Text("Reading the book… the index appears when Lemma reaches it.").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }.padding(16)
        } else {
            PaneEmptyState(symbol: "character.book.closed", title: "Index unavailable", message: "This book's text could not be read.")
        }
    }

    private func pageChip(_ span: PageSpan, entry: BookIndexEntry) -> some View {
        Button(span.text) {
            if let page = store.pageIndex(forPrinted: span.first) { store.goToTerm(entry.term, onPage: page, inSplit: NSEvent.modifierFlags.contains(.option)) }
        }
        .buttonStyle(.plain).font(.system(size: 10.5).monospacedDigit())
        .padding(.horizontal, 5).frame(height: 17)
        .background(Color.lemmaOlive.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
        .foregroundStyle(Color.lemmaOlive)
        .help("Printed page \(span.text) · ⌥-click opens it to the side")
    }

    private func row(_ entry: BookIndexEntry, searching: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            FlowLayout(spacing: 5) {
                Text(searching ? entry.title : entry.term).font(.system(size: 12, weight: entry.parent == nil ? .medium : .regular)).lineLimit(2)
                ForEach(entry.locators, id: \.self) { span in pageChip(span, entry: entry) }
            }
            if !entry.see.isEmpty {
                HStack(spacing: 4) {
                    Text("see").italic().foregroundStyle(.secondary)
                    ForEach(entry.see, id: \.self) { target in
                        Button(target) { query = target }.buttonStyle(.link)
                    }
                }.font(.system(size: 11))
            }
        }
        .padding(.leading, !searching && entry.parent != nil ? 14 : 0)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { store.openIndexEntry(entry) }
        .contextMenu {
            Button("Show All Pages") { store.openIndexEntry(entry) }
            if let first = entry.locators.first, let page = store.pageIndex(forPrinted: first.first) {
                Button("Open First Page to the Side") { store.openToSide(page: page, title: entry.term) }
            }
            Button("Look Up in My Glossary") { store.lookupDefinition(entry.term, pageIndex: store.reader.pageNumber - 1, region: nil) }
        }
        .accessibilityElement(children: .combine)
    }
}
