import SwiftUI

enum ExplorerPane: String, CaseIterable, Identifiable {
    case open, files, library, outline, timeline, pages
    var id: String { "explorer.\(rawValue)" }
    var title: String {
        switch self {
        case .open: "Open Editors"; case .library: "Library"; case .outline: "Outline"
        case .timeline: "Timeline"; case .pages: "Pages"
        case .files: "Workspace Files"
        }
    }
    var initiallyExpanded: Bool { self == .library || self == .outline || self == .files }
}

struct SidebarPane: Identifiable {
    let id: String
    let title: String
    var initiallyExpanded = true
    var preferredHeight: Double = 180
    var count: Int? = nil
}

/// A drag transfers height between two open neighbours; headers and handles retain their own space.
struct SidebarPaneLayout {
    let expanded: [String]
    let minimum: CGFloat
    private(set) var heights: [String: Double] = [:]

    init(height: CGFloat, panes: [String], expanded: [String], fill: String,
         preferred: [String: Double]?, defaults: [String: Double]) {
        self.expanded = expanded
        let room = max(0, height - CGFloat(panes.count) * VSMetrics.paneHeaderHeight
                       - CGFloat(max(0, expanded.count - 1)) * ResizeSashView.thickness)
        minimum = min(VSMetrics.rowHeight, room / CGFloat(max(1, expanded.count)))
        guard let fill = expanded.contains(fill) ? fill : expanded.first else { return }
        for pane in expanded { heights[pane] = max(minimum, preferred?[pane] ?? defaults[pane] ?? minimum) }
        let difference = room - heights.values.reduce(0, +)
        if difference >= 0 { heights[fill, default: 0] += difference; return }
        var excess = -difference
        let taken = min(excess, heights[fill, default: minimum] - minimum)
        heights[fill, default: minimum] -= taken; excess -= taken
        let others = expanded.filter { $0 != fill }
        let capacity = others.reduce(0) { $0 + (heights[$1, default: minimum] - minimum) }
        if excess > 0, capacity > 0 {
            for pane in others {
                heights[pane, default: minimum] -= excess * (heights[pane, default: minimum] - minimum) / capacity
            }
        }
    }

    func height(of pane: String) -> CGFloat { heights[pane] ?? 0 }

    func resizing(_ above: String, _ below: String, by delta: CGFloat, using current: [String: Double]? = nil) -> [String: Double] {
        var result = current ?? heights
        let upper = result[above] ?? 0, lower = result[below] ?? 0
        let delta = min(lower - minimum, max(minimum - upper, delta))
        result[above] = upper + delta
        result[below] = lower - delta
        return result
    }
}

/// Used by every multi-pane side bar, with independent scrolling, collapse and durable heights.
struct ResizableSidebarPanes<Actions: View, Content: View>: View {
    @Bindable var store: StudyStore
    let panes: [SidebarPane]
    let fill: String
    @ViewBuilder let actions: (SidebarPane) -> Actions
    @ViewBuilder let content: (SidebarPane) -> Content
    @State private var draggingHeights: [String: Double]?

    var body: some View {
        GeometryReader { geometry in
            let expanded = panes.filter { store.paneExpanded[$0.id] ?? $0.initiallyExpanded }
            let layout = SidebarPaneLayout(height: geometry.size.height, panes: panes.map(\.id), expanded: expanded.map(\.id),
                                           fill: fill, preferred: draggingHeights ?? store.workbenchLayout.explorerHeights,
                                           defaults: Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0.preferredHeight) }))
            VStack(spacing: 0) {
                ForEach(panes) { pane in
                    if let index = expanded.firstIndex(where: { $0.id == pane.id }), index > 0 {
                        separator(above: expanded[index - 1], below: pane, layout: layout)
                    }
                    VSPane(title: pane.title, expanded: store.paneBinding(pane.id, default: pane.initiallyExpanded),
                           count: pane.count, showsTopBorder: pane.id != panes.first?.id) {
                        actions(pane)
                    } content: {
                        content(pane).frame(height: layout.height(of: pane.id)).clipped()
                    }
                }
                if expanded.isEmpty { Spacer(minLength: 0) }
            }
        }
    }

    private func separator(above: SidebarPane, below: SidebarPane, layout: SidebarPaneLayout) -> some View {
        VSSash(axis: .horizontal,
               onDrag: { draggingHeights = layout.resizing(above.id, below.id, by: $0, using: draggingHeights) },
               onEnd: saveHeights,
               onDoubleClick: {
                   let delta = above.id == fill ? layout.height(of: below.id) - below.preferredHeight
                       : above.preferredHeight - layout.height(of: above.id)
                   draggingHeights = layout.resizing(above.id, below.id, by: delta); saveHeights()
               })
            .accessibilityElement()
            .accessibilityLabel("\(above.title) and \(below.title) heights")
            .accessibilityValue("\(Int(layout.height(of: above.id))) / \(Int(layout.height(of: below.id))) points")
            .accessibilityAdjustableAction { direction in
                draggingHeights = layout.resizing(above.id, below.id, by: direction == .increment ? 20 : -20); saveHeights()
            }
            .help("Drag to resize \(above.title) and \(below.title); double-click to reset their heights")
    }
    private func saveHeights() {
        guard let draggingHeights else { return }
        store.workbenchLayout.explorerHeights = (store.workbenchLayout.explorerHeights ?? [:]).merging(draggingHeights) { _, new in new }
        self.draggingHeights = nil
        store.saveWorkbench()
    }
}
