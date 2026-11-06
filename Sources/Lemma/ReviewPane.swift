import SwiftUI
import AppKit
import LemmaCore

/// Spaced recall from the reader's own notes: attempt, reveal, then grade. Masked parts of the
/// source (cloze) stay hidden in the notebook and on the page until revealed.
struct ReviewPane: View {
    @Bindable var store: StudyStore
    @State private var noteID: UUID?
    @State private var revealed = false
    @State private var practising = false

    private var due: [StudyNote] { store.reviewNotes }
    private var later: [StudyNote] {
        store.reviewDeck.filter { !$0.isDue() }.sorted { ($0.reviewDueAt ?? .distantFuture) < ($1.reviewDueAt ?? .distantFuture) }
    }
    private var note: StudyNote? {
        guard let noteID, let note = store.workspace?.notes.first(where: { $0.id == noteID }), note.isInReview else { return nil }
        return note.isDue() || practising ? note : nil
    }

    var body: some View {
        Group {
            if let note { card(note) } else { overview }
        }
        .onAppear { if noteID == nil { noteID = due.first?.id }; syncMask() }
        .onChange(of: due.map(\.id)) { _, _ in
            guard note == nil else { return }
            practising = false; revealed = false
            noteID = due.first?.id
        }
        .onChange(of: noteID) { _, _ in revealed = false; syncMask() }
        .onChange(of: note?.id) { _, _ in syncMask() }
        .onChange(of: note?.masks) { _, _ in syncMask() }
        .onChange(of: revealed) { _, _ in syncMask() }
        .onChange(of: store.workspace?.id) { _, _ in noteID = due.first?.id; practising = false; revealed = false }
        .onDisappear { store.reader.recallMask = nil; store.reader.recallMaskRegions = [] }
    }

    private func card(_ note: StudyNote) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label(practising && !note.isDue() ? "Practice" : "Recall", systemImage: "arrow.clockwise").font(.headline)
                    Spacer()
                    Text("\(due.count) due · \(later.count) later").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(note.kind.label) · PDF page \(note.anchor.pageIndex + 1)").font(.caption).foregroundStyle(.secondary)
                    Text(note.recallQuestion).font(.system(size: 18, weight: .semibold)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if !note.masks.isEmpty, let image = store.image(for: note.anchor) {
                    MaskedSourceImage(image: image, region: note.anchor.region, masks: note.masks, revealed: revealed)
                        .frame(maxWidth: .infinity, maxHeight: 220)
                    if !revealed { Text("Fill in the hidden parts before revealing them.").font(.caption).foregroundStyle(.secondary) }
                } else if !revealed {
                    Text("Explain the idea or justify the step before looking at the source and your saved work.").font(.callout).foregroundStyle(.secondary).lineSpacing(3)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("My recall attempt").font(.headline)
                    TextEditor(text: Binding(get: { store.workspace?.notes.first { $0.id == note.id }?.reviewAnswer ?? "" }, set: { value in store.updateNote(id: note.id) { $0.reviewAnswer = value } }))
                        .font(.body).frame(minHeight: 120).padding(6).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6)).accessibilityLabel("Recall attempt")
                }
                if !revealed {
                    Button { revealed = true } label: { Label("Reveal", systemImage: "eye") }.buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command).help("Reveal the source and your saved work · ⌘↩")
                } else {
                    Divider()
                    if note.masks.isEmpty, let image = store.image(for: note.anchor) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 200).padding(6).background(.white, in: RoundedRectangle(cornerRadius: 5))
                    }
                    if !note.body.isEmpty { Text("My saved reasoning").font(.headline); MathPreview(text: note.body) }
                    if let explanation = note.explanation { Text("Saved explanation").font(.headline); MathPreview(text: explanation.body) }
                    grades(note)
                }
                Button("Remove from review") { store.removeFromReview(id: note.id); advance(from: note) }
                    .buttonStyle(.link).font(.caption)
            }.padding(20)
        }
    }

    private func grades(_ note: StudyNote) -> some View {
        let schedule = note.review ?? ReviewSchedule(dueAt: .now)
        let delays = ReviewScheduler.delays(for: schedule)
        return VStack(alignment: .leading, spacing: 8) {
            Text("How well did you recall it?").font(.headline)
            HStack(spacing: 8) {
                ForEach(ReviewGrade.allCases, id: \.self) { grade in
                    Button { store.grade(id: note.id, grade); advance(from: note) } label: {
                        VStack(spacing: 2) {
                            Text(grade.label).font(.callout.weight(.medium))
                            Text(ReviewScheduler.describe(delays[grade] ?? 0)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).help("\(grade.meaning) · ⌘\(ReviewGrade.allCases.firstIndex(of: grade)! + 1)")
                        .keyboardShortcut(KeyEquivalent(Character("\(ReviewGrade.allCases.firstIndex(of: grade)! + 1)")), modifiers: .command)
                }
            }
            Text("Your own assessment schedules the next recall · ⌘1–⌘4.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PaneEmptyState(symbol: "arrow.clockwise.circle",
                               title: store.reviewDeck.isEmpty ? "Revisit what matters" : "Nothing due right now",
                               message: store.reviewDeck.isEmpty
                               ? "Add a note to review to practise explaining it. Hide parts of its source as cloze masks; they stay hidden until you reveal them."
                               : "Each recall you grade schedules the next one. Notes return sooner when recall is hard.")
                    .frame(height: 170)
                if !later.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Coming up").font(.headline)
                        ForEach(later.prefix(8)) { item in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.recallQuestion).font(.callout).lineLimit(2)
                                    Text("PDF page \(item.anchor.pageIndex + 1)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(dueText(item)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Button("Practise") { practising = true; noteID = item.id }.buttonStyle(.link).font(.caption)
                            }
                            Divider()
                        }
                    }.padding(.horizontal, 20)
                }
                if let current = store.currentNote, !current.isInReview {
                    Button("Add current note to review") { store.addToReview(id: current.id); practising = false; noteID = current.id }
                        .buttonStyle(.borderedProminent).padding(.horizontal, 20)
                }
            }.padding(.bottom, 20)
        }
    }

    private func dueText(_ note: StudyNote) -> String {
        guard let date = note.reviewDueAt else { return "" }
        return "in " + ReviewScheduler.describe(max(60, date.timeIntervalSinceNow))
    }

    private func advance(from note: StudyNote) {
        practising = false
        revealed = false
        noteID = due.first { $0.id != note.id }?.id
    }

    /// Masks the recalled region on the page until reveal; cloze masks hide only their parts.
    private func syncMask() {
        guard let note, !revealed else { store.reader.recallMask = nil; store.reader.recallMaskRegions = []; return }
        store.reader.recallMaskRegions = note.masks
        store.reader.recallMask = note.anchor
    }
}

/// A source crop with cloze masks drawn over it.
struct MaskedSourceImage: View {
    let image: NSImage
    let region: PageRegion
    let masks: [PageRegion]
    let revealed: Bool

    var body: some View {
        Image(nsImage: image).resizable().scaledToFit()
            .overlay {
                GeometryReader { geometry in
                    ForEach(Array(masks.enumerated()), id: \.offset) { _, mask in
                        let frame = MaskGeometry.viewRect(for: mask, in: region, size: geometry.size)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(revealed ? Color.lemmaOlive.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.lemmaOlive.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: revealed ? [3, 2] : [])))
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
            }
            .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel(revealed ? "Source with revealed cloze parts" : "Source with \(masks.count) hidden parts")
    }
}

/// Drag across the source crop to hide a part during recall; click a mask to remove it.
struct MaskEditor: View {
    let image: NSImage
    let region: PageRegion
    @Binding var masks: [PageRegion]
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(nsImage: image).resizable().scaledToFit()
                .overlay {
                    GeometryReader { geometry in
                        ZStack(alignment: .topLeading) {
                            Color.white.opacity(0.001)
                                .gesture(DragGesture(minimumDistance: 2)
                                    .onChanged { value in dragStart = value.startLocation; dragCurrent = value.location }
                                    .onEnded { value in
                                        let rect = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
                                                          width: abs(value.location.x - value.startLocation.x), height: abs(value.location.y - value.startLocation.y))
                                        if rect.width > 4, rect.height > 4 { masks.append(MaskGeometry.pageRegion(for: rect, in: region, size: geometry.size)) }
                                        dragStart = nil; dragCurrent = nil
                                    })
                            ForEach(Array(masks.enumerated()), id: \.offset) { index, mask in
                                let frame = MaskGeometry.viewRect(for: mask, in: region, size: geometry.size)
                                Button { masks.remove(at: index) } label: {
                                    RoundedRectangle(cornerRadius: 3).fill(Color.lemmaOlive.opacity(0.35))
                                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.lemmaOlive))
                                }.buttonStyle(.plain).frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY)
                                    .help("Remove this mask").accessibilityLabel("Remove recall mask \(index + 1)")
                            }
                            if let dragStart, let dragCurrent {
                                Rectangle().stroke(Color.lemmaOlive, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                                    .frame(width: abs(dragCurrent.x - dragStart.x), height: abs(dragCurrent.y - dragStart.y))
                                    .position(x: (dragStart.x + dragCurrent.x) / 2, y: (dragStart.y + dragCurrent.y) / 2)
                            }
                        }
                    }
                }
                .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 5))
                .frame(maxHeight: 180)
            HStack {
                Text(masks.isEmpty ? "Drag across a part of the source to hide it during recall." : "\(masks.count) hidden \(masks.count == 1 ? "part" : "parts") · click one to remove it")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !masks.isEmpty { Button("Clear") { masks = [] }.buttonStyle(.link).font(.caption) }
            }
        }
    }
}

/// Converts between a crop's displayed size (top-left origin) and PDF page space (bottom-left origin).
enum MaskGeometry {
    static func pageRegion(for rect: CGRect, in region: PageRegion, size: CGSize) -> PageRegion {
        guard size.width > 0, size.height > 0 else { return region }
        let clipped = rect.intersection(CGRect(origin: .zero, size: size))
        let x = region.x + clipped.minX / size.width * region.width
        let width = clipped.width / size.width * region.width
        let height = clipped.height / size.height * region.height
        let y = region.y + region.height - clipped.maxY / size.height * region.height
        return PageRegion(x: x, y: y, width: width, height: height)
    }

    static func viewRect(for mask: PageRegion, in region: PageRegion, size: CGSize) -> CGRect {
        guard region.width > 0, region.height > 0 else { return .zero }
        let x = (mask.x - region.x) / region.width * size.width
        let width = mask.width / region.width * size.width
        let height = mask.height / region.height * size.height
        let y = (region.y + region.height - mask.y - mask.height) / region.height * size.height
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
