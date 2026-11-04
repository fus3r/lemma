import SwiftUI
import AppKit
import PDFKit
import LemmaCore

/// What the book says about the page in view, like an IDE's quick-help inspector: where it sits, what it defines,
/// what it refers to, which works it cites, the book's index terms for it, and the reader's own marks. It is redrawn when
/// the page in view or its section changes (not on every scroll step), and what it reads from the page's text is cached.
struct PageInspector: View {
    @Bindable var store: StudyStore
    @Environment(\.undoManager) private var undoManager
    @Environment(\.theme) private var theme

    /// The page the reader settled on: a fast scroll does not rebuild the inspector for every page it passes.
    private var pageIndex: Int { store.reader.settledPageIndex }

    var body: some View {
        let _ = QAPerf.tick("PageInspector")
        if store.document == nil {
            PaneEmptyState(symbol: "doc.text.magnifyingglass", title: "The page in view", message: "Open a book to see what each page defines, refers to and cites.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    actions
                    if store.analysis?.analysis == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(store.analysis?.isAnalyzing == true ? "Reading the book…" : "The book has not been read yet.").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        defined
                        terms
                        notation
                        refersTo
                        cited
                        indexTerms
                    }
                    marks
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(store.printedLabel(for: pageIndex).map { "Page \($0)" } ?? "Page \(pageIndex + 1)").font(.system(size: 17, weight: .semibold))
                if store.printedLabel(for: pageIndex) != nil {
                    Text("PDF \(pageIndex + 1)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                let seconds = store.workspace?.readingLog.seconds(onPage: pageIndex) ?? 0
                if seconds >= 4 {
                    Label(ReadingLog.describe(seconds), systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                        .help("Time spent on this page")
                }
            }
            // Its own view: the path changes with the section being read, which must not rebuild the whole inspector.
            InspectorPath(reader: store.reader)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { store.askAboutPage(pageIndex) } label: { Label("Ask about this page", systemImage: "text.bubble") }
                .help("Ask an assistant about the whole page, with its context · or select a passage and press ⌘K")
            Button { store.newLab(source: store.pageSource(pageIndex)) } label: { Label("Lab", systemImage: "flask") }
                .help("Start a Python notebook from this page")
            Button { store.newDerivation(origin: store.pageSource(pageIndex)) } label: { Label("Derive", systemImage: "function") }
                .help("Start a derivation from this page, with the sizes its notation gives")
            Spacer(minLength: 0)
        }
        .buttonStyle(.bordered).controlSize(.small)
    }

    // MARK: Book

    @ViewBuilder private var defined: some View {
        let targets = (store.analysis?.definitionsByPage[pageIndex] ?? []).filter { $0.key.kind != .section }
        if !targets.isEmpty {
            section("Defined here", count: targets.count) {
                ForEach(Array(targets.enumerated()), id: \.offset) { _, target in
                    let count = store.analysis?.mentionCounts[target.key] ?? 0
                    VStack(alignment: .leading, spacing: 4) {
                        row(symbol: target.key.kind.symbol, title: target.key.spokenTitle, detail: caption(target),
                            trailing: count > 0 ? "\(count) \(count == 1 ? "ref" : "refs")" : nil) {
                            store.showReferences(to: target.key)
                        }
                        if target.key.kind == .equation { RegionThumbnail(store: store, target: target, maxHeight: 54).padding(.leading, 24) }
                    }
                    .contextMenu {
                        Button("Find All References") { store.showReferences(to: target.key) }
                        Button("Go There") { store.goToReference(target) }
                        Button("Send to Lab") { store.sendTargetToLab(target) }
                        Button("Pin") { store.pinReference(target) }
                    }
                    .help("Click to list the places that refer to \(target.key.spokenTitle)")
                }
            }
        }
    }

    /// The symbols this page uses and what they stand for at this point of the book: an editor's watch list for notation.
    @ViewBuilder private var notation: some View {
        if let index = store.analysis?.notation, !index.isEmpty {
            let symbols = store.symbolsUsed(onPage: pageIndex)
            if !symbols.isEmpty {
                section("Notation", count: symbols.count) {
                    ForEach(Array(symbols.prefix(16).enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.symbol).font(.system(size: 15, design: .serif)).italic().frame(width: 22, alignment: .center)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.definition.meaning).font(.system(size: 11.5)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                Text((item.later ? "defined later · " : item.definition.explicit ? "" : "named · ") + store.shortPageText(item.definition.pageIndex))
                                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { store.goToSymbolDefinition(item.definition) }
                        .help("Go to where the book says what \(item.symbol) is · the meaning in force on this page")
                    }
                }
            }
        }
    }

    @ViewBuilder private var terms: some View {
        let terms = store.definedTerms(onPage: pageIndex)
        if !terms.isEmpty {
            section("Terms introduced", count: terms.count) {
                FlowLayout(spacing: 6) {
                    ForEach(terms) { term in
                        Button { store.goToDefinedTerm(term) } label: {
                            Text(term.surface).italic().font(.system(size: 11.5))
                        }
                        .buttonStyle(ChipStyle(selected: false))
                        .help((term.definitional ? "Defined here" : "Indexed term emphasised here") + " · …\(term.before)\(term.surface)\(term.after)…")
                        .contextMenu {
                            Button("Select on the Page") { store.goToDefinedTerm(term) }
                            Button("Find in the Book") { store.reader.searchText = term.surface; store.reader.find(); store.reveal(.search) }
                            Button("Look Up") { store.lookupDefinition(term.surface, pageIndex: term.pageIndex, region: nil) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var refersTo: some View {
        let references = store.referencesMade(onPage: pageIndex)
        let keys = references.map(\.key)
        if !keys.isEmpty {
            section("Refers to", count: keys.count) {
                FlowLayout(spacing: 6) {
                    ForEach(references, id: \.key) { reference in
                        let key = reference.key, times = reference.times
                        Button { open(key, side: !NSEvent.modifierFlags.contains(.option)) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: key.kind.symbol).font(.system(size: 9))
                                Text(key.kind == .equation ? "(\(key.number))" : key.title).font(.system(size: 11))
                                if times > 1 { Text("×\(times)").font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.secondary) }
                            }
                        }
                        .buttonStyle(ChipStyle(selected: false))
                        .help("Open \(key.spokenTitle) beside the page · ⌥-click to go there")
                    }
                }
            }
        }
    }

    @ViewBuilder private var cited: some View {
        let records = store.analysis?.citationsByPage[pageIndex] ?? []
        let ids = orderedUnique(records.flatMap(\.entryIDs))
        let entries = ids.compactMap { id in store.analysis?.analysis?.bibliography.first { $0.id == id } }
        if !entries.isEmpty {
            section("Cited works", count: entries.count) {
                ForEach(entries, id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.shortTitle).font(.system(size: 12, weight: .medium))
                        Text(entry.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { store.showReferences(.object(ReferenceKey(kind: .citation, number: String(entry.id), name: entry.shortTitle))) }
                    .contextMenu {
                        Button("Find Citations") { store.showReferences(.object(ReferenceKey(kind: .citation, number: String(entry.id), name: entry.shortTitle))) }
                        Button("Copy Reference") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.text, forType: .string) }
                    }
                    .help("Click to list where the book cites this work")
                }
            }
        }
    }

    @ViewBuilder private var indexTerms: some View {
        let entries = store.indexEntries(onPage: pageIndex)
        if !entries.isEmpty {
            section("In the book's index", count: entries.count) {
                FlowLayout(spacing: 6) {
                    ForEach(entries.prefix(30)) { entry in
                        Button(entry.title) { store.openIndexEntry(entry) }
                            .buttonStyle(ChipStyle(selected: false))
                            .help("Index: \(entry.title) · pages \(entry.locators.map(\.text).joined(separator: ", "))")
                    }
                }
            }
        }
    }

    // MARK: Reader

    @ViewBuilder private var marks: some View {
        let notes = (store.workspace?.notes ?? []).filter { $0.anchor.pageIndex == pageIndex }
        let highlights = (store.workspace?.highlights ?? []).filter { $0.pageIndex == pageIndex }
        let labs = (store.workspace?.labs ?? []).filter { $0.source?.pageIndex == pageIndex }
        let shapes = (store.workspace?.shapes ?? []).filter { $0.pageIndex == pageIndex }
        let bookmarked = store.workspace?.bookmarks.contains { $0.pageIndex == pageIndex } == true
        if notes.isEmpty && highlights.isEmpty && labs.isEmpty && shapes.isEmpty && !bookmarked {
            section("Your work", count: 0) {
                Text("Nothing yet on this page. Select a passage to ask, note, mark or try it in the Lab; double-click the margin to write beside a line.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            section("Your work", count: notes.count + highlights.count + labs.count + shapes.count) {
                if bookmarked { row(symbol: "bookmark.fill", title: "Bookmarked", detail: nil, trailing: nil) { store.reveal(.bookmarks) } }
                ForEach(notes) { note in
                    HStack(spacing: 4) {
                        row(symbol: note.kind.symbol, title: note.title, detail: note.kind.label, trailing: note.isDue() ? "due" : nil) {
                            if note.kind == .comment { store.editMarginNote(note.id) } else { store.selectNote(note.id); store.studySection = note.kind.isGlossary ? .glossary : .notes }
                        }
                        .accessibilityLabel("Open note: \(note.title)")
                        Button(role: .destructive) { store.removeNote(id: note.id, undoManager: undoManager) } label: {
                            Image(systemName: "trash").foregroundStyle(theme[.iconForeground])
                                .frame(width: 24, height: 24).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(note.pendingRequestID != nil)
                        .help(note.pendingRequestID == nil ? "Delete note · Undo with ⌘Z" : "Cancel the pending question before deleting this note")
                        .accessibilityLabel("Delete note: \(note.title)")
                    }
                    .contextMenu {
                        Button("Go to source") { store.reader.go(to: note.anchor) }
                        Button("Pin as context") { store.pinNote(note) }
                        Divider()
                        Button("Delete note", role: .destructive) { store.removeNote(id: note.id, undoManager: undoManager) }
                            .disabled(note.pendingRequestID != nil)
                    }
                }
                ForEach(labs) { notebook in
                    row(symbol: "flask", title: notebook.title, detail: "\(notebook.cells.count) cells", trailing: nil) { store.openLabNotebook(notebook.id) }
                }
                ForEach(shapes) { shape in
                    HStack(spacing: 4) {
                        row(symbol: shape.kind.symbol, title: shape.kind.label, detail: "\(shape.width.formatted()) pt\(shape.dashed ? " · dashed" : "")", trailing: nil) {
                            store.reader.goToPage(shape.pageIndex + 1)
                            store.reader.selectShape(shape)
                        }
                        Button(role: .destructive) { store.removeShape(id: shape.id) } label: { Image(systemName: "trash").frame(width: 24, height: 24) }
                            .buttonStyle(.plain).help("Delete \(shape.kind.label.lowercased()) · Undo with ⌘Z")
                            .accessibilityLabel("Delete \(shape.kind.label.lowercased())")
                    }
                }
                ForEach(highlights) { mark in
                    row(symbol: mark.style == .underline ? "underline" : "highlighter", title: mark.quote.isEmpty ? "Selected region" : mark.quote,
                        detail: mark.style.label, trailing: nil) { store.reveal(.bookmarks) }
                }
            }
        }
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).kerning(0.4)
                if count > 0 { Text("\(count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary) }
            }
            content()
        }
    }

    private func row(symbol: String, title: String, detail: String?, trailing: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Color.lemmaOlive).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.leading)
                    if let detail, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 4)
                if let trailing { Text(trailing).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func caption(_ target: ReferenceTarget) -> String? {
        guard [.figure, .table, .algorithm].contains(target.key.kind), let page = store.document?.page(at: target.pageIndex) else { return nil }
        let text = page.selection(for: target.anchor.rect.insetBy(dx: -1, dy: -1).union(CGRect(x: target.anchor.x, y: target.anchor.y - 20, width: 400, height: 20)))?.string ?? ""
        let cleaned = TextRepair.repaired(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return cleaned.isEmpty ? nil : String(cleaned.prefix(90))
    }

    private func open(_ key: ReferenceKey, side: Bool) {
        guard let target = store.references?.knownTarget(key) else { store.showReferences(to: key); return }
        if side { store.openToSide(target) } else { store.goToReference(target) }
    }

    private func orderedUnique<T: Hashable>(_ items: [T]) -> [T] {
        var seen = Set<T>()
        return items.filter { seen.insert($0).inserted }
    }
}

/// The outline path of the reading position, under the inspector's title.
private struct InspectorPath: View {
    let reader: ReaderController

    var body: some View {
        let path = reader.focusPath
        if !path.isEmpty {
            Text(path.map(\.title).joined(separator: " › ")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// An object a page refers to, and how many times.
struct PageReference: Hashable {
    let key: ReferenceKey
    let times: Int
}

/// What the inspector reads from a page's text and the book's mentions, kept for the pages seen most recently.
@MainActor
private enum PageInspectorCache {
    static let symbols = RecentCache<String, [(symbol: String, definition: SymbolDefinition, later: Bool)]>(capacity: 24)
    static let references = RecentCache<String, [PageReference]>(capacity: 24)
}

@MainActor
extension StudyStore {
    private func inspectorKey(_ pageIndex: Int) -> String {
        "\(workspace?.id ?? "")|\(analysis?.analysis?.analyzedAt.timeIntervalSince1970 ?? 0)|\(pageIndex)"
    }

    /// The symbols a page uses and what they stand for there (scanning the page's text once per page).
    func symbolsUsed(onPage pageIndex: Int) -> [(symbol: String, definition: SymbolDefinition, later: Bool)] {
        guard let notation = analysis?.notation, !notation.isEmpty, let page = document?.page(at: pageIndex) else { return [] }
        return PageInspectorCache.symbols.value(for: inspectorKey(pageIndex)) { page.string.map { notation.symbols(usedIn: $0, pageIndex: pageIndex) } ?? [] }
    }

    /// The objects a page refers to (not those it defines), in reading order, with how many times each is mentioned.
    func referencesMade(onPage pageIndex: Int) -> [PageReference] {
        guard let analysis, let mentions = analysis.analysis?.mentions else { return [] }
        return PageInspectorCache.references.value(for: inspectorKey(pageIndex)) {
            let onPage = mentions.filter { $0.pageIndex == pageIndex }
            let defined = Set((analysis.definitionsByPage[pageIndex] ?? []).map(\.key))
            var counts: [ReferenceKey: Int] = [:], order: [ReferenceKey] = []
            for mention in onPage where !defined.contains(mention.key) {
                if counts[mention.key] == nil { order.append(mention.key) }
                counts[mention.key, default: 0] += 1
            }
            return order.map { PageReference(key: $0, times: counts[$0] ?? 0) }
        }
    }

    /// Index entries whose page numbers include this page.
    func indexEntries(onPage pageIndex: Int) -> [BookIndexEntry] {
        guard let index = analysis?.analysis?.index, let label = printedLabel(for: pageIndex) ?? Optional(String(pageIndex + 1)), let page = Int(label) else { return [] }
        return index.filter { entry in
            entry.locators.contains { span in
                guard let first = Int(span.first.filter(\.isNumber)) else { return false }
                let last = span.last.flatMap { Int($0.filter(\.isNumber)) } ?? first
                return first <= page && page <= max(first, last)
            }
        }
    }

    /// The whole page as a source, for asking about it or starting a notebook.
    func pageSource(_ pageIndex: Int) -> LabSource? {
        guard let page = document?.page(at: pageIndex) else { return nil }
        let box = page.bounds(for: .cropBox)
        let section = references.flatMap { OutlineMap.section(containing: pageIndex, in: $0.outline)?.title }.map(repairedTitle)
        return LabSource(pageIndex: pageIndex, region: PageRegion(box), label: section ?? "Page \(printedLabel(for: pageIndex) ?? String(pageIndex + 1))",
                         quote: String((page.string ?? "").prefix(1500)))
    }

    /// A quick question about the whole page: its image, text and the objects it cites.
    func askAboutPage(_ pageIndex: Int) {
        guard let workspace, let page = document?.page(at: pageIndex) else { return }
        let box = page.bounds(for: .cropBox)
        let text = page.selection(for: box)
        let region = (text?.bounds(for: page) ?? box).insetBy(dx: -6, dy: -6).intersection(box)
        reader.selection = (pageIndex, region, page.string ?? "")
        reader.hasSelection = true
        definitionLookup = nil; referencePeek = nil
        quickAsk = QuickAskRequest(workspaceID: workspace.id, pageIndex: pageIndex, region: region, quote: page.string ?? "")
        if let quickAsk { reader.view?.presentQuickAsk(quickAsk, store: self) }
    }
}

/// A small rendering of a numbered object from its page, cached by the store.
struct RegionThumbnail: View {
    @Bindable var store: StudyStore
    let target: ReferenceTarget
    var maxHeight: CGFloat = 60

    var body: some View {
        // Rendered once and cached; small enough to draw synchronously.
        if let image = store.thumbnail(for: target) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                .frame(maxWidth: min(image.size.width, 330), maxHeight: min(image.size.height, maxHeight), alignment: .leading)
                .padding(5).background(Color.white, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .accessibilityLabel("\(target.key.spokenTitle) as printed")
        }
    }
}

@MainActor
extension StudyStore {
    /// The object's region rendered at 2×, without its label column, cached for the session.
    func thumbnail(for target: ReferenceTarget) -> NSImage? {
        let key = "\(workspace?.id ?? "")/\(target.pageIndex)/\(target.region.x)/\(target.region.y)" as NSString
        if let cached = lab.images.object(forKey: key) { return cached }
        guard let page = document?.page(at: target.pageIndex) else { return nil }
        var region = target.region.rect
        // An equation's label sits at the right edge of its region; the inspector names it already.
        if target.key.kind == .equation, target.anchor.rect.minX > region.midX { region.size.width = max(20, target.anchor.rect.minX - region.minX - 4) }
        // Drawn at the region's size (not the whole page) and kept as an image: no PNG round trip in the view's body.
        guard let image = try? PDFRegionRenderer.nsImage(page: page, region: PageRegion(region), scale: 2) else { return nil }
        lab.images.setObject(image, forKey: key)
        return image
    }
}
