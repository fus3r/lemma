import SwiftUI
import AppKit
import LemmaCore

/// A statement's kind as an editor shows a symbol's: a small coloured square with a letter.
struct KindBadge: View {
    let key: ReferenceKey
    var size: CGFloat = 15

    var body: some View {
        Text(Self.letter(for: key))
            .font(.system(size: size * 0.62, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Self.color(for: key), in: RoundedRectangle(cornerRadius: size * 0.27))
            .accessibilityHidden(true)
    }

    static func letter(for key: ReferenceKey) -> String {
        switch key.kind {
        case .equation: "E"; case .figure: "F"; case .chart: "C"; case .table: "T"; case .box: "B"
        case .section, .chapter, .specialFeature: "§"; case .exercise: "X"
        case .algorithm: "A"; case .citation: "R"; case .link: "L"
        case .theorem:
            switch key.name ?? "" {
            case "Definition": "D"; case "Theorem": "T"; case "Lemma": "L"; case "Proposition": "P"; case "Corollary": "C"
            case "Example": "E"; case "Remark": "R"; case "Claim": "C"; case "Assumption": "A"; case "Conjecture": "?"
            case "Result": "R"; case "Fact": "F"; case "Property": "P"; case "Notation": "N"
            default: String((key.name ?? "S").prefix(1))
            }
        }
    }

    static func color(for key: ReferenceKey) -> Color {
        switch key.kind {
        case .equation: Color(nsColor: .systemTeal)
        case .figure, .chart: Color(nsColor: .systemOrange)
        case .table, .box: Color(nsColor: .systemBrown)
        case .section, .chapter, .specialFeature: Color(nsColor: .systemGray)
        case .exercise: Color(nsColor: .systemIndigo)
        case .algorithm: Color(nsColor: .systemGreen)
        case .citation, .link: Color(nsColor: .systemGray)
        case .theorem:
            switch key.name ?? "" {
            case "Definition", "Notation": Color(nsColor: .systemBlue)
            case "Theorem", "Result": Color(nsColor: .systemPurple)
            case "Lemma", "Claim", "Fact": Color(nsColor: .systemTeal)
            case "Proposition", "Property": Color(nsColor: .systemIndigo)
            case "Corollary": Color(nsColor: .systemPink)
            case "Example": Color(nsColor: .systemOrange)
            case "Assumption", "Conjecture": Color(nsColor: .systemRed)
            default: Color(nsColor: .systemGray)
            }
        }
    }
}

/// The Results view: the book's definitions, theorems, lemmas and examples by chapter, with their proofs, what they
/// use and what uses them · an editor's symbol outline for mathematics. Proofs can be folded to read statements only.
struct ResultsSidebar: View {
    @Bindable var store: StudyStore
    @State private var filter = ""
    @State private var kind: ResultFilter = .all
    @State private var expanded: Set<String> = []

    enum ResultFilter: String, CaseIterable, Identifiable {
        case all, definitions, results, examples
        var id: String { rawValue }
        var title: String { switch self { case .all: "All"; case .definitions: "Definitions"; case .results: "Results"; case .examples: "Examples" } }
        func includes(_ key: ReferenceKey) -> Bool {
            let name = key.name ?? ""
            switch self {
            case .all: return true
            case .definitions: return ["Definition", "Notation", "Assumption"].contains(name)
            case .results: return StructureAnalyzer.provedNames.contains(name)
            case .examples: return ["Example", "Remark"].contains(name)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField("Filter: 2.3, lemma, Jensen…", text: $filter).padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
            HStack(spacing: 4) {
                ForEach(ResultFilter.allCases) { item in
                    chip(item.title, selected: kind == item) { kind = item }
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).padding(.bottom, 6)
            summary.padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            content
        }
        .onAppear(perform: expandCurrentChapter)
        .onChange(of: store.workspace?.id) { _, _ in expanded = []; expandCurrentChapter() }
    }

    @ViewBuilder private var summary: some View {
        let statements = store.analysis?.structure.statements ?? []
        if !statements.isEmpty {
            let understood = statements.filter { store.isUnderstood($0.key) }.count
            HStack(spacing: 8) {
                ProgressRing(value: Double(understood) / Double(max(statements.count, 1))).frame(width: 13, height: 13)
                Text("\(understood) of \(statements.count) understood").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if !store.proofs.isEmpty {
                    Button { store.toggleAllProofs() } label: {
                        Label(store.allProofsFolded ? "Unfold Proofs" : "Fold Proofs", systemImage: store.allProofsFolded ? "chevron.down.square" : "chevron.right.square")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help(store.allProofsFolded ? "Show every proof again" : "Hide every proof behind a fold: read the statements, try each proof first")
                }
                Menu {
                    let visible = chapterGroups().filter { expanded.contains($0.id) }.flatMap(\.statements)
                    Button("Add Shown Definitions to Review") { store.addStatementsToReview(visible.filter { $0.key.name == "Definition" }.map(\.key)) }
                        .disabled(!visible.contains { $0.key.name == "Definition" })
                    Button("Add Shown Results to Review") { store.addStatementsToReview(visible.filter { StructureAnalyzer.provedNames.contains($0.key.name ?? "") }.map(\.key)) }
                        .disabled(!visible.contains { StructureAnalyzer.provedNames.contains($0.key.name ?? "") })
                    Divider()
                    Button("Map This Chapter") { store.showMap() }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("Review cards and the chapter map")
            }
        }
    }

    @ViewBuilder private var content: some View {
        if store.document == nil {
            PaneEmptyState(symbol: "checkmark.seal", title: "The book's results", message: "Open a book: Lemma lists its definitions, theorems, lemmas and examples with their proofs.")
        } else if store.analysis?.analysis != nil {
            let groups = chapterGroups()
            if groups.isEmpty {
                PaneEmptyState(symbol: "checkmark.seal", title: filter.isEmpty ? "No numbered statements" : "No matches",
                               message: filter.isEmpty ? "Lemma recognises statements such as “Theorem 2.3”, “Lemma 4.1 (Hoeffding)” or “2.35 definition:”. This book may number equations and figures instead. See Symbols." : "Try a number such as 2.3, or a word from a title.")
            } else {
                List {
                    ForEach(groups, id: \.id) { group in
                        DisclosureGroup(isExpanded: binding(for: group.id)) {
                            ForEach(group.statements, id: \.key) { statement in row(statement) }
                        } label: {
                            HStack {
                                Text(group.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 4)
                                let done = group.statements.filter { store.isUnderstood($0.key) }.count
                                Text(done > 0 ? "\(done)/\(group.statements.count)" : "\(group.statements.count)")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden).environment(\.defaultMinListRowHeight, 24)
            }
        } else if let progress = store.analysis?.progress {
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0)
                Text(progress.total > 0 ? "Reading page \(progress.done) of \(progress.total)…" : "Reading the book…").font(.callout)
                Spacer()
            }.padding(16)
        } else {
            PaneEmptyState(symbol: "exclamationmark.triangle", title: "Not read yet", message: store.analysis?.failure ?? "Lemma could not read this book's text layer.")
        }
    }

    private struct ChapterGroup { let id: String; let title: String; let statements: [StatementInfo] }

    private func chapterGroups() -> [ChapterGroup] {
        let structure = store.analysis?.structure ?? DocumentStructure()
        let chapters = store.outline.compactMap { entry in entry.pageIndex.map { (entry, $0) } }
        let query = filter.trimmingCharacters(in: .whitespaces)
        let statements = structure.statements.filter { statement in
            guard kind.includes(statement.key) else { return false }
            guard !query.isEmpty else { return true }
            return PaletteProvider.score(statement.key.title + " " + (statement.title ?? ""), query) != nil
        }
        var groups: [ChapterGroup] = []
        var current: (id: String, title: String, statements: [StatementInfo])?
        for statement in statements {
            let chapter = chapters.last { $0.1 <= statement.start.pageIndex }
            let number = statement.key.number.split(separator: ".").first.map(String.init)
            let id = chapter?.0.id ?? "chapter-\(number ?? "0")"
            let title = chapter?.0.title ?? (number.map { "Chapter \($0)" } ?? "Statements")
            if current?.id != id {
                if let current { groups.append(ChapterGroup(id: current.id, title: current.title, statements: current.statements)) }
                current = (id, title, [])
            }
            current?.statements.append(statement)
        }
        if let current { groups.append(ChapterGroup(id: current.id, title: current.title, statements: current.statements)) }
        return groups
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { !filter.isEmpty || expanded.contains(id) }, set: { value in if value { expanded.insert(id) } else { expanded.remove(id) } })
    }

    private func expandCurrentChapter() {
        if let chapter = store.breadcrumb().first { expanded.insert(chapter.id) }
        if expanded.isEmpty, let first = chapterGroups().first { expanded.insert(first.id) }
    }

    private func row(_ statement: StatementInfo) -> some View {
        let key = statement.key
        let usedBy = store.analysis?.usedBy(key).count ?? 0
        let proof = statement.proof.flatMap { id in store.proofs.first { $0.id == id } }
        let understood = store.isUnderstood(key)
        let here = statement.start.pageIndex == store.reader.focusPageIndex
        return HStack(spacing: 6) {
            KindBadge(key: key)
            Text(key.title).font(.system(size: 12, weight: here ? .semibold : .regular)).monospacedDigit().lineLimit(1).layoutPriority(1)
            if let title = statement.title {
                Text(title).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if usedBy > 0 {
                Text("\(usedBy)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                    .help("Used by \(usedBy) \(usedBy == 1 ? "statement or section" : "statements and sections")")
            }
            if let proof {
                Button { store.toggleProof(proof.stableID) } label: {
                    Image(systemName: store.isFolded(proof) ? "chevron.right.square.fill" : "chevron.down.square")
                        .font(.system(size: 11)).foregroundStyle(store.isFolded(proof) ? Color.lemmaOlive : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(store.isFolded(proof) ? "Unfold the proof (\(proof.lineCount) lines)" : "Fold the proof (\(proof.lineCount) lines): try it yourself first")
                .accessibilityLabel(store.isFolded(proof) ? "Unfold proof of \(key.title)" : "Fold proof of \(key.title)")
            }
            Button { store.toggleUnderstood(key) } label: {
                Image(systemName: understood ? "checkmark.circle.fill" : "circle").font(.system(size: 11))
                    .foregroundStyle(understood ? Color(nsColor: .systemGreen) : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help(understood ? "Understood · click to clear" : "Mark as understood")
            .accessibilityLabel(understood ? "\(key.title) understood" : "Mark \(key.title) as understood")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.option) { store.openKeyToTheSide(key) } else { store.goToKey(key) }
        }
        .contextMenu { StatementMenu(store: store, key: key) }
        .help([key.title, statement.title].compactMap { $0 }.joined(separator: " · ") + " · click to go there, ⌥-click to open beside the page")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 6).frame(height: 20)
                .background(selected ? Color.lemmaOlive.opacity(0.18) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(selected ? Color.lemmaOlive : Color.secondary)
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The actions offered on a statement wherever it appears: in Results, the Hierarchy panel and the map.
struct StatementMenu: View {
    let store: StudyStore
    let key: ReferenceKey

    var body: some View {
        Button("Go There") { store.goToKey(key) }
        Button("Open to the Side") { store.openKeyToTheSide(key) }
        Button("Run and Debug (F5)") { store.startDebugging(at: key) }
        Divider()
        Button("Show What It Uses") { store.showHierarchy(key, direction: .uses) }
        Button("Show What Uses It") { store.showHierarchy(key, direction: .usedBy) }
        Button("Show Prerequisites Map") { store.showMap(for: key) }
        Button("Find All References") { store.showReferences(to: key) }
        Divider()
        if let proof = store.analysis?.structure.proof(of: key) {
            Button(store.isFolded(proof) ? "Unfold Proof" : "Fold Proof") { store.toggleProof(proof.stableID) }
        }
        Button(store.isUnderstood(key) ? "Mark as Not Understood" : "Mark as Understood") { store.toggleUnderstood(key) }
        Button("Add to Review") { store.addStatementToReview(key) }
        Divider()
        Button("Copy Link") { store.copyLink(to: key) }
    }
}
