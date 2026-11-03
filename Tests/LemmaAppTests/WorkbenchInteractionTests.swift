import XCTest
import AppKit
import SwiftUI
@testable import Lemma

final class WorkbenchInteractionTests: XCTestCase {
    @MainActor private func explorerLayout(height: CGFloat, expanded: [ExplorerPane], preferred: [String: Double]?, defaults: [String: Double]) -> SidebarPaneLayout {
        SidebarPaneLayout(height: height, panes: ExplorerPane.allCases.map(\.id), expanded: expanded.map(\.id),
                          fill: ExplorerPane.outline.id, preferred: preferred, defaults: defaults)
    }

    @MainActor
    func testHostedLibrarySashReceivesEdgeHitsAndSavesPointerTravel() async throws {
        let previousStyle = ThemeManager.shared.style
        let previousPanes = UserDefaults.standard.object(forKey: "workbench.panes")
        defer {
            ThemeManager.shared.style = previousStyle
            UserDefaults.standard.set(previousPanes, forKey: "workbench.panes")
        }
        ThemeManager.shared.style = .vscode
        let fixture = try WorkbenchFixture(hosted: true)
        defer { fixture.close() }
        let store = fixture.store
        store.open(fixture.book)
        store.navigatorSection = .library
        store.showLibrary = true
        store.paneExpanded = ["explorer.open": false, "explorer.files": false, "explorer.library": true, "explorer.outline": true,
                              "explorer.timeline": false, "explorer.pages": false]
        try await fixture.settle(350)
        func handles(_ view: NSView) -> [ResizeSashView] {
            var result = (view as? ResizeSashView).map { [$0] } ?? []
            for child in view.subviews { result += handles(child) }
            return result
        }
        let content = try XCTUnwrap(fixture.window.contentView)
        let handle = try XCTUnwrap(handles(content).first { $0.bounds.width > 100 && $0.bounds.height == ResizeSashView.thickness })
        let point = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY + 4), to: nil)
        let hit = content.hitTest(content.superview!.convert(point, from: nil))
        XCTAssertTrue(hit === handle, "A hit four points off the line reached \(hit.map { String(describing: type(of: $0)) } ?? "nil").")
        func event(_ type: NSEvent.EventType, dy: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x, y: point.y + dy),
                                           modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        handle.mouseDown(with: try event(.leftMouseDown, dy: 0))
        handle.mouseDragged(with: try event(.leftMouseDragged, dy: -60))
        handle.mouseUp(with: try event(.leftMouseUp, dy: -60))
        XCTAssertEqual(store.workbenchLayout.explorerHeights?["explorer.library"], 280, "The 220-point default grows by the 60-point drag.")
        let saved = try JSONDecoder().decode(WorkbenchSession.self, from: Data(contentsOf: store.sessionURL))
        XCTAssertEqual(saved.layout.explorerHeights?["explorer.library"], 280)
    }

    @MainActor
    func testStructureAndDebugShareHeightTransferWithoutChangingOtherViews() {
        for ids in [["structure.results", "structure.symbols", "structure.index"],
                    ["debug.variables", "debug.watch", "debug.stack", "debug.breakpoints"]] {
            let layout = SidebarPaneLayout(height: 700, panes: ids, expanded: ids, fill: ids[0],
                                           preferred: ["explorer.library": 240], defaults: [ids[1]: 180])
            let resized = layout.resizing(ids[0], ids[1], by: 60)
            XCTAssertEqual(resized[ids[1]], 120)
            XCTAssertEqual(resized.values.reduce(0, +) + CGFloat(ids.count) * 22 + CGFloat(ids.count - 1) * ResizeSashView.thickness, 700)
            XCTAssertNil(resized["explorer.library"], "Each container only changes its own pane heights.")
        }
    }

    @MainActor
    func testNativeSashCanBeGrabbedOffTheLineAndTracksMovingDividers() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let sash = ResizeSashView(frame: NSRect(x: 80, y: 20, width: ResizeSashView.thickness, height: 240))
        window.contentView!.addSubview(sash)
        let point = sash.convert(CGPoint(x: sash.bounds.midX + 4, y: 90), to: nil)
        XCTAssertTrue(window.contentView?.hitTest(point) === sash, "The pointer can be four points away from the thin line.")
        var deltas: [CGFloat] = [], ended = 0, reset = 0
        sash.onDrag = { deltas.append($0); sash.frame.origin.x += $0 }
        sash.onEnd = { ended += 1 }; sash.onDoubleClick = { reset += 1 }
        func event(_ type: NSEvent.EventType, dx: CGFloat, clicks: Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x + dx, y: point.y),
                                           modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
        }
        sash.mouseDown(with: try event(.leftMouseDown, dx: 0))
        sash.mouseDragged(with: try event(.leftMouseDragged, dx: 30))
        sash.mouseDragged(with: try event(.leftMouseDragged, dx: 45))
        sash.mouseUp(with: try event(.leftMouseUp, dx: 45))
        XCTAssertEqual(deltas, [30, 15]); XCTAssertEqual(ended, 1)
        sash.mouseDown(with: try event(.leftMouseDown, dx: 45, clicks: 2))
        sash.mouseUp(with: try event(.leftMouseUp, dx: 45, clicks: 2))
        XCTAssertEqual(reset, 1); XCTAssertEqual(ended, 1)

        sash.axis = .horizontal
        sash.frame = NSRect(x: 20, y: 80, width: 240, height: ResizeSashView.thickness)
        var horizontal: CGFloat = 0
        sash.onDrag = { horizontal += $0 }
        let start = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 60, y: 84), modifierFlags: [],
                                      timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: CGPoint(x: 60, y: 24), modifierFlags: [],
                                     timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        sash.mouseDown(with: start); sash.mouseDragged(with: drag); sash.mouseUp(with: drag)
        XCTAssertEqual(horizontal, 60, "Downward pointer travel transfers height to the upper pane.")
    }

    @MainActor
    func testExplorerDragTransfersHeightAndCollapseRestoresIt() {
        let defaults: [String: Double] = ["explorer.library": 26, "explorer.timeline": 200, "explorer.pages": 260]
        let expanded: [ExplorerPane] = [.library, .outline, .timeline]
        let layout = explorerLayout(height: 750, expanded: expanded, preferred: nil, defaults: defaults)
        let resized = layout.resizing(ExplorerPane.outline.id, ExplorerPane.timeline.id, by: -75)
        XCTAssertEqual(resized["explorer.timeline"], 275)
        XCTAssertEqual(resized["explorer.library"], 26, "Unrelated sections keep their height.")
        XCTAssertEqual(resized.values.reduce(0, +), 750 - Double(ExplorerPane.allCases.count) * 22 - 2 * ResizeSashView.thickness)
        let nextEvent = layout.resizing(ExplorerPane.outline.id, ExplorerPane.timeline.id, by: -5, using: resized)
        XCTAssertEqual(nextEvent["explorer.timeline"], 280, "Mouse events between two view updates must accumulate.")

        let collapsed = explorerLayout(height: 750, expanded: [.library, .outline], preferred: resized, defaults: defaults)
        XCTAssertEqual(collapsed.height(of: ExplorerPane.outline.id), layout.height(of: ExplorerPane.outline.id) + 200 + ResizeSashView.thickness)
        let reopened = explorerLayout(height: 750, expanded: expanded, preferred: resized, defaults: defaults)
        XCTAssertEqual(reopened.heights, resized)

        let small = explorerLayout(height: 480, expanded: ExplorerPane.allCases, preferred: resized, defaults: defaults)
        let count = Double(ExplorerPane.allCases.count)
        XCTAssertEqual(small.heights.values.reduce(0, +) + count * 22 + (count - 1) * ResizeSashView.thickness, 480, accuracy: 0.001)
        XCTAssertTrue(small.heights.values.allSatisfy { $0 >= 22 }, "All headers and at least one row stay reachable.")
        let clamped = small.resizing(ExplorerPane.outline.id, ExplorerPane.timeline.id, by: 1000)
        XCTAssertEqual(clamped["explorer.timeline"], 22)
    }

    @MainActor
    func testExplorerHeightsPersistAndOlderSessionsStillLoad() throws {
        let oldLayout = Data(#"{"sidebarPosition":"left","activityBar":true,"sidebarWidth":264,"inspectorWidth":370}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(WorkbenchLayout.self, from: oldLayout).explorerHeights)
        let fixture = try WorkbenchFixture()
        defer { fixture.close() }
        fixture.store.open(fixture.book)
        let heights = ["explorer.outline": 320.0, "explorer.timeline": 180.0, "explorer.pages": 150.0, "structure.results": 250.0, "debug.watch": 170.0]
        fixture.store.workbenchLayout.explorerHeights = heights
        fixture.store.saveWorkbench()
        let restarted = StudyStore(root: fixture.store.repository.root)
        restarted.restore()
        XCTAssertEqual(restarted.workbenchLayout.explorerHeights, heights)
    }

    @MainActor
    func testTallPanelKeepsTheReaderVisibleInASmallWindow() async throws {
        let previous = UserDefaults.standard.object(forKey: "panelHeight")
        let previousStyle = ThemeManager.shared.style
        defer { UserDefaults.standard.set(previous, forKey: "panelHeight"); ThemeManager.shared.style = previousStyle }
        ThemeManager.shared.style = .vscode
        UserDefaults.standard.set(800, forKey: "panelHeight")
        let fixture = try WorkbenchFixture(hosted: true)
        defer { fixture.close() }
        fixture.store.open(fixture.book)
        fixture.store.showPanel = true
        fixture.window.setContentSize(CGSize(width: 960, height: 640))
        try await fixture.settle(350)
        let reader = try XCTUnwrap(fixture.store.reader.view)
        XCTAssertGreaterThan(reader.visibleRect.height, 60, "A remembered tall panel must leave room to read and resize it.")
        let rect = reader.convert(reader.bounds, to: fixture.window.contentView)
        XCTAssertTrue(fixture.window.contentView!.bounds.insetBy(dx: -1, dy: -1).contains(rect))
    }

    @MainActor
    func testConstrainedSidebarsKeepTheirMinimumsInASupportedWindow() async throws {
        let previousStyle = ThemeManager.shared.style
        defer { ThemeManager.shared.style = previousStyle }
        ThemeManager.shared.style = .vscode
        let fixture = try WorkbenchFixture(hosted: true)
        defer { fixture.close() }
        fixture.store.open(fixture.book)
        fixture.store.workbenchLayout.sidebarWidth = 180
        fixture.store.workbenchLayout.inspectorWidth = 500
        fixture.window.setContentSize(CGSize(width: 960, height: 640))
        try await fixture.settle(350)
        let reader = try XCTUnwrap(fixture.store.reader.view)
        let rect = reader.convert(reader.bounds, to: fixture.window.contentView)
        XCTAssertGreaterThanOrEqual(rect.minX, VSMetrics.activityBarWidth + 180 + 4 - 1,
                                    "Fitting the window must retain the Explorer's supported minimum width.")
    }
}
