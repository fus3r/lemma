import XCTest
import AppKit
import PDFKit
import SwiftUI
import LemmaCore
@testable import Lemma

final class ReferenceFlowTests: XCTestCase {
    @MainActor
    func testClickingACitationPeeksInPlaceThenGoToKeepsBack() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let store = fixture.store, view = fixture.view
        store.reader.goToPage(3); store.reader.updatePage()
        XCTAssertEqual(store.reader.pageNumber, 3)
        let index = try XCTUnwrap(store.references)
        let mention = try XCTUnwrap(index.mentions(onPage: 2).first { $0.key == ReferenceKey(kind: .equation, number: "1.1") })
        XCTAssertFalse(mention.isDefinition)
        let point = fixture.point(in: mention, onPage: 2)
        // Dispatch an actual click so hitTest sees a mouse event, rather than a prior window/scroll event.
        fixture.window.orderFront(nil)
        NSApp.sendEvent(try fixture.event(.leftMouseDown, at: point))
        NSApp.sendEvent(try fixture.event(.leftMouseUp, at: point))
        let request = try XCTUnwrap(store.referencePeek)
        XCTAssertEqual(request.mention.key.spokenTitle, "Equation (1.1)")
        XCTAssertEqual(request.pageIndex, 2)
        XCTAssertEqual(store.reader.pageNumber, 3, "Peeking leaves the reader on its page.")
        XCTAssertFalse(store.reader.hasSelection)

        let resolved = await index.resolve(request.mention, from: request.pageIndex)
        let target = try XCTUnwrap(resolved)
        XCTAssertEqual(target.pageIndex, 0)
        XCTAssertEqual(target.origin, .text)
        store.referencePeek = nil
        store.goToReference(target)
        store.reader.updatePage()
        XCTAssertEqual(store.reader.pageNumber, 1)
        XCTAssertNotNil(store.reader.flash, "The destination is briefly outlined.")
        XCTAssertTrue(view.canGoBack)
        store.reader.back(); store.reader.updatePage()
        XCTAssertEqual(store.reader.pageNumber, 3, "Back returns to the citing page.")
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.originalBytes)
    }

    /// The hover and the peek promise it: ⌥-click on a reference keeps it in the side editor, without a peek.
    @MainActor
    func testOptionClickingAReferenceOpensItInTheSideEditor() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let store = fixture.store, view = fixture.view
        store.reader.goToPage(3); store.reader.updatePage()
        let index = try XCTUnwrap(store.references)
        let mention = try XCTUnwrap(index.mentions(onPage: 2).first { $0.key == ReferenceKey(kind: .equation, number: "1.1") })
        let point = fixture.point(in: mention, onPage: 2)
        view.mouseDown(with: try fixture.event(.leftMouseDown, at: point, modifiers: .option))
        view.mouseUp(with: try fixture.event(.leftMouseUp, at: point, modifiers: .option))
        XCTAssertNil(store.referencePeek, "⌥-click opens the reference beside the page instead of peeking.")
        for _ in 0..<40 where store.split == nil { try await Task.sleep(for: .milliseconds(25)) }
        let split = try XCTUnwrap(store.split)
        XCTAssertEqual(split.pageIndex, 0)
        XCTAssertEqual(split.target?.key, ReferenceKey(kind: .equation, number: "1.1"))
        XCTAssertEqual(store.reader.pageNumber, 3, "The reader stays on its page.")
    }

    @MainActor
    func testDraggingFromACitationSelectsTextAndDefinitionsStayOrdinaryText() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let store = fixture.store, view = fixture.view
        store.reader.goToPage(3); store.reader.updatePage()
        let index = try XCTUnwrap(store.references)
        let mention = try XCTUnwrap(index.mentions(onPage: 2).first { $0.key.kind == .equation })
        let start = fixture.point(in: mention, onPage: 2)
        let end = CGPoint(x: start.x + 120, y: start.y)
        view.mouseDown(with: try fixture.event(.leftMouseDown, at: start))
        view.mouseDragged(with: try fixture.event(.leftMouseDragged, at: end))
        view.mouseUp(with: try fixture.event(.leftMouseUp, at: end))
        XCTAssertNil(store.referencePeek, "A drag selects text instead of opening the peek.")
        XCTAssertFalse((view.currentSelection?.string ?? "").isEmpty)

        store.reader.goToPage(1); store.reader.updatePage()
        let label = try XCTUnwrap(index.mentions(onPage: 0).first { $0.key.kind == .equation })
        XCTAssertTrue(label.isDefinition, "The equation's own label is recognised as its definition.")
        XCTAssertNil(view.referenceHit(at: fixture.point(in: label, onPage: 0)), "Clicking a defining label keeps ordinary text behaviour.")

        store.reader.goToPage(3); store.reader.updatePage()
        store.reader.showReferenceLinks = false
        XCTAssertNil(view.referenceHit(at: start))
        XCTAssertFalse(view.hitTest(view.convert(start, to: view.superview)) === view, "Disabled reference links leave clicks to PDFKit.")
    }

    @MainActor
    func testPinningAndFindingMentionsOfAReference() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let store = fixture.store
        let index = try XCTUnwrap(store.references)
        let resolvedFigure = await index.resolve(ReferenceKey(kind: .figure, number: "1.1"), from: 2)
        let figure = try XCTUnwrap(resolvedFigure)
        XCTAssertEqual(figure.pageIndex, 1)

        store.pinReference(figure)
        let pin = try XCTUnwrap(store.workspace?.pins.first)
        XCTAssertEqual(pin.label, "Figure 1.1 · page 2")
        XCTAssertEqual(pin.anchor.region, figure.region)
        let png = try Data(contentsOf: store.repository.assetURL(workspaceID: try XCTUnwrap(store.workspace?.id), name: pin.anchor.imageName))
        XCTAssertNotNil(NSBitmapImageRep(data: png))
        store.pinReference(figure)
        XCTAssertEqual(store.workspace?.pins.count, 1, "Pinning the same reference twice keeps one pin.")
        XCTAssertEqual(store.studySection, .references)

        store.toggleFocus()
        store.findMentions(of: ReferenceKey(kind: .equation, number: "1.1"))
        XCTAssertFalse(store.focusMode)
        XCTAssertEqual(store.navigatorSection, .search)
        XCTAssertEqual(store.reader.searchText, "(1.1)")
        let deadline = Date.now.addingTimeInterval(3)
        while store.reader.isSearching && Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.reader.searchResults.count, 2, "The defining label and the citation are listed.")
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.originalBytes)
    }

    @MainActor
    func testResolvedDefinitionsPersistForTheNextOpening() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let key = ReferenceKey(kind: .equation, number: "1.1")
        let resolved = await fixture.store.references?.resolve(key, from: 2)
        XCTAssertNotNil(resolved)
        let reopened = StudyStore(root: fixture.support)
        reopened.open(fixture.source)
        XCTAssertNotNil(reopened.references?.knownTarget(key), "A book's analysis is reused rather than repeated.")
        XCTAssertGreaterThan(reopened.references?.scannedPageCount ?? 0, 0)
    }

    @MainActor
    func testHostedReaderPresentsAndClosesTheReferencePeek() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(hosted: true)
        defer { fixture.close() }
        let store = fixture.store
        try await Task.sleep(for: .milliseconds(150))
        let index = try XCTUnwrap(store.references)
        store.reader.goToPage(3); store.reader.updatePage()
        let mention = try XCTUnwrap(index.mentions(onPage: 2).first { $0.key.kind == .figure })
        let visible = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
        store.peekReference(mention, pageIndex: 2)
        try await Task.sleep(for: .milliseconds(400))
        let popup = NSApp.windows.first { $0.isVisible && !visible.contains($0.windowNumber) }
        XCTAssertNotNil(popup, "The reader must present an actual peek window.")
        XCTAssertTrue(store.reader.view?.referencePopover?.isShown == true)
        // VS Code style: a peek view in a child window; Classic: the 1.1 popover. Either way closing it clears the request.
        if ThemeManager.shared.style == .vscode { XCTAssertTrue(store.reader.view?.referencePopover?.panel.isShown == true) }
        store.reader.view?.referencePopover?.close()
        XCTAssertNil(store.referencePeek, "Native dismissal clears the request so the same citation can reopen.")
        XCTAssertEqual(store.reader.pageNumber, 3)
    }

    /// A Shift-click opens a peek beside the one open, and both stay open (#remarks: two movable previews at once);
    /// a plain click replaces only the peek that was not kept; the reader leaving its window closes them all.
    @MainActor
    func testShiftClickedPeeksStayOpenBesideEachOther() async throws {
        _ = NSApplication.shared
        let previous = ThemeManager.shared.style
        ThemeManager.shared.style = .vscode
        defer { ThemeManager.shared.style = previous }
        let fixture = try Fixture(hosted: true)
        defer { fixture.close() }
        let store = fixture.store
        try await Task.sleep(for: .milliseconds(150))
        let index = try XCTUnwrap(store.references)
        store.reader.goToPage(3); store.reader.updatePage()
        var seen = Set<ReferenceKey>()
        let mentions = index.mentions(onPage: 2).filter { !$0.isDefinition && seen.insert($0.key).inserted }
        XCTAssertGreaterThanOrEqual(mentions.count, 2, "The sample page cites at least two references.")
        let view = try XCTUnwrap(store.reader.view)

        store.peekReference(mentions[0], pageIndex: 2)
        try await Task.sleep(for: .milliseconds(300))
        let first = try XCTUnwrap(view.referencePopover)
        XCTAssertFalse(first.isKept)
        store.peekReference(mentions[1], pageIndex: 2, keep: true)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(view.referencePopover, "Both peeks are kept: none is the passing one.")
        XCTAssertEqual(view.keptReferencePeeks.map(\.key), [mentions[0].key, mentions[1].key])
        XCTAssertTrue(view.keptReferencePeeks.allSatisfy { $0.isShown && $0.isKept && $0.panel.isKept })
        XCTAssertNil(store.referencePeek, "No passing peek is open.")
        let frames = view.keptReferencePeeks.compactMap(\.panel.frame)
        XCTAssertEqual(frames.count, 2)
        XCTAssertFalse(frames[1].intersects(frames[0]) && abs(frames[1].maxY - frames[0].maxY) < 20,
                       "The second peek opens beside the first, or at least below its title bar: \(frames)")

        // Shift-clicking a reference already open brings its peek forward instead of opening it twice.
        store.peekReference(mentions[1], pageIndex: 2, keep: true)
        XCTAssertEqual(view.keptReferencePeeks.count, 2)

        // A plain click opens a passing peek; what clears it (another popup, Escape) leaves the kept ones.
        store.peekReference(mentions[0], pageIndex: 2)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(view.referencePopover?.isShown == true)
        store.referencePeek = nil
        XCTAssertNil(view.referencePopover)
        XCTAssertEqual(view.keptReferencePeeks.filter(\.isShown).count, 2, "Kept peeks outlive the passing one.")

        // Moved by its title bar, a passing peek becomes a kept one where the reader put it.
        store.peekReference(mentions[0], pageIndex: 2)
        try await Task.sleep(for: .milliseconds(300))
        let moved = try XCTUnwrap(view.referencePopover)
        let before = try XCTUnwrap(moved.panel.frame)
        moved.autoPlace = nil; moved.panel.move(by: CGSize(width: 40, height: -30)); moved.keep()
        XCTAssertNil(view.referencePopover)
        XCTAssertEqual(view.keptReferencePeeks.count, 3)
        // Narrower, so that the screen's edge does not push it back: on a CI runner's 1024-point screen the peek opens
        // against the window's right edge, and widened past the screen's edge, it would rightly move left.
        moved.panel.fit(CGSize(width: before.width - 50, height: before.height + 20))
        let after = try XCTUnwrap(moved.panel.frame)
        XCTAssertEqual(after.minX, before.minX + 40, accuracy: 0.5, "Resized, a kept peek keeps its left edge… \(before) → \(after)")
        XCTAssertEqual(after.maxY, before.maxY - 30, accuracy: 0.5, "…and its top edge, where the reader put it: \(before) → \(after)")

        // Its own close button closes one kept peek.
        moved.frame.close()
        XCTAssertEqual(view.keptReferencePeeks.count, 2)
        XCTAssertFalse(moved.isShown)

        // Peeks are the reader's window's: the reader leaving it closes them.
        fixture.window.contentView = NSView()
        XCTAssertTrue(view.keptReferencePeeks.isEmpty)
        XCTAssertEqual(NSApp.windows.filter { $0.isVisible && $0.parent === fixture.window }.count, 0, "No peek is left behind.")
    }

    @MainActor
    func testClassicPopoverStaysOpenBesideAShiftClickedOne() async throws {
        _ = NSApplication.shared
        let previous = ThemeManager.shared.style
        ThemeManager.shared.style = .classic
        defer { ThemeManager.shared.style = previous }
        let fixture = try Fixture(hosted: true)
        defer { fixture.close() }
        let store = fixture.store
        try await Task.sleep(for: .milliseconds(150))
        let index = try XCTUnwrap(store.references)
        store.reader.goToPage(3); store.reader.updatePage()
        var seen = Set<ReferenceKey>()
        let mentions = index.mentions(onPage: 2).filter { !$0.isDefinition && seen.insert($0.key).inserted }
        let view = try XCTUnwrap(store.reader.view)
        store.peekReference(mentions[0], pageIndex: 2)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(view.referencePopover?.popover.behavior, .applicationDefined, "It closes itself, so a Shift-click can keep it.")
        store.peekReference(mentions[1], pageIndex: 2, keep: true)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(view.keptReferencePeeks.count, 2)
        XCTAssertTrue(view.keptReferencePeeks.allSatisfy { $0.popover.isShown }, "Both popovers are open, each at its mention.")
        view.keptReferencePeeks.last?.frame.close()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(view.keptReferencePeeks.count, 1)
        view.closeKeptReferencePeeks()
        XCTAssertTrue(view.keptReferencePeeks.isEmpty)
    }

    @MainActor
    func testClassicStyleKeepsTheReferencePopover() async throws {
        _ = NSApplication.shared
        let previous = ThemeManager.shared.style
        ThemeManager.shared.style = .classic
        defer { ThemeManager.shared.style = previous }
        let fixture = try Fixture(hosted: true)
        defer { fixture.close() }
        let store = fixture.store
        try await Task.sleep(for: .milliseconds(150))
        let index = try XCTUnwrap(store.references)
        store.reader.goToPage(3); store.reader.updatePage()
        let mention = try XCTUnwrap(index.mentions(onPage: 2).first { $0.key.kind == .figure })
        store.peekReference(mention, pageIndex: 2)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(store.reader.view?.referencePopover?.popover.isShown == true, "Classic keeps 1.1's popover.")
        store.reader.view?.referencePopover?.popover.close()
        XCTAssertNil(store.referencePeek)
    }

    @MainActor
    func testPeekViewShowsThePageWidthAtTheReferencedRegion() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let index = try XCTUnwrap(fixture.store.references)
        let resolved = await index.resolve(ReferenceKey(kind: .equation, number: "1.1"), from: 2)
        let target = try XCTUnwrap(resolved)
        let peek = PeekPDFView(frame: CGRect(x: 0, y: 0, width: 556, height: 160))
        peek.displayMode = .singlePageContinuous; peek.autoScales = false
        peek.document = fixture.store.document
        let window = NSWindow(contentRect: peek.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = peek
        defer { window.close() }
        peek.target = target
        peek.layoutSubtreeIfNeeded(); peek.layout()
        let page = try XCTUnwrap(fixture.store.document?.page(at: target.pageIndex))
        let label = peek.convert(target.anchor.rect, from: page)
        XCTAssertTrue(peek.bounds.insetBy(dx: -1, dy: -1).contains(label), "The label \(label) must be visible in the peek \(peek.bounds).")
        XCTAssertEqual(peek.scaleFactor, peek.scaleFactorForSizeToFit, accuracy: 0.001, "The page's width fills the peek, as in the reader.")
        peek.largestScale = 0.5
        peek.target = nil; peek.target = target
        peek.layoutSubtreeIfNeeded(); peek.layout()
        XCTAssertEqual(peek.scaleFactor, 0.5, accuracy: 0.001, "The page opens no larger than the peek's zoom.")
        XCTAssertTrue(peek.highlightedSelections?.isEmpty ?? true, "Nothing is selected: a misaligned text layer would mark the wrong glyphs.")
    }

    @MainActor
    func testPeekOpensJustBelowTheReadersZoomWithinTheWindow() {
        let roomy = PeekSizing(scale: 1.5, opening: CGSize(width: 1200, height: 600), largest: CGSize(width: 1400, height: 800))
        XCTAssertEqual(roomy.width(forPage: 612), 612 * 1.5 * PeekSizing.share + PeekSizing.sides, accuracy: 0.5,
                       "The page opens a little smaller than the reader shows it.")
        let narrow = PeekSizing(scale: 1.5, opening: CGSize(width: 700, height: 600), largest: CGSize(width: 1400, height: 800))
        XCTAssertEqual(narrow.width(forPage: 612), 700, "Within 70% of the window, the page is fitted rather than cut off.")
        XCTAssertEqual(narrow.zoom(forPage: 612, width: 700), (700 - PeekSizing.sides) / 612, accuracy: 0.001)
        let zoomedOut = PeekSizing(scale: 0.6, opening: CGSize(width: 1200, height: 600), largest: CGSize(width: 1400, height: 800))
        XCTAssertEqual(zoomedOut.width(forPage: 612), 612 * 0.6 * PeekSizing.share + PeekSizing.sides, accuracy: 0.5,
                       "Read zoomed out, the peek narrows with the page.")
        let tiny = PeekSizing(scale: 0.2, opening: CGSize(width: 1200, height: 600), largest: CGSize(width: 1400, height: 800))
        XCTAssertEqual(tiny.width(forPage: 612), PeekSizing.smallest.width)
        XCTAssertEqual(tiny.zoom(forPage: 612, width: PeekSizing.smallest.width), 0.2 * PeekSizing.share, accuracy: 0.001,
                       "A page narrower than the peek is centred at the peek's zoom, never enlarged.")

        let start = CGSize(width: 600, height: 300)
        XCTAssertEqual(roomy.resized(start, by: CGSize(width: 100, height: 50)), CGSize(width: 700, height: 350), "The corner follows the pointer.")
        XCTAssertEqual(roomy.resized(start, by: CGSize(width: 100, height: 0), widthGain: 2).width, 800, "A centred popover widens on both sides.")
        XCTAssertEqual(roomy.resized(start, by: CGSize(width: -1000, height: -1000)), PeekSizing.smallest)
        XCTAssertEqual(roomy.resized(start, by: CGSize(width: 5000, height: 5000)), CGSize(width: 1400, height: 800))
    }

    @MainActor
    func testPeekIsResizedByTheEdgesThatMove() {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let area = PeekResizeAreaView(frame: host.bounds)
        host.addSubview(area)
        XCTAssertNil(area.hitTest(CGPoint(x: 395, y: 150)), "Still loading, the peek has no edges to drag.")
        area.active = true
        // The host is not flipped: y counts up from the bottom edge.
        XCTAssertTrue(area.hitTest(CGPoint(x: 396, y: 150)) === area, "The right edge")
        XCTAssertTrue(area.hitTest(CGPoint(x: 200, y: 4)) === area, "The bottom edge")
        XCTAssertTrue(area.hitTest(CGPoint(x: 385, y: 15)) === area, "The bottom-right corner")
        XCTAssertNil(area.hitTest(CGPoint(x: 200, y: 150)), "Clicks inside reach the peek")
        XCTAssertNil(area.hitTest(CGPoint(x: 200, y: 296)), "Below its mention, the top edge stays the peek's own")
        XCTAssertNil(area.hitTest(CGPoint(x: 4, y: 150)), "The left edge stays the peek's own")

        // Above its mention, the bottom edge stays by the mention, and the top edge is the one that moves.
        area.fromTop = true
        XCTAssertTrue(area.hitTest(CGPoint(x: 200, y: 296)) === area, "The top edge")
        XCTAssertTrue(area.hitTest(CGPoint(x: 385, y: 296)) === area, "The top-right corner, along the top")
        XCTAssertTrue(area.hitTest(CGPoint(x: 396, y: 285)) === area, "The top-right corner, along the side")
        XCTAssertNil(area.hitTest(CGPoint(x: 385, y: 285)), "The close button in the title bar's corner stays clickable")
        XCTAssertTrue(area.hitTest(CGPoint(x: 396, y: 30)) === area, "The right edge, down to the bottom")
        XCTAssertNil(area.hitTest(CGPoint(x: 200, y: 4)), "The bottom edge stays the peek's own")
        XCTAssertEqual(area.edges, [.topRight, .right, .top])

        var drags: [CGSize] = []
        area.onDrag = { drags.append($0) }
        area.drag(.right, by: CGSize(width: 30, height: 20))
        area.drag(.bottom, by: CGSize(width: 30, height: 20))
        area.drag(.bottomRight, by: CGSize(width: 30, height: 20))
        area.drag(.top, by: CGSize(width: 30, height: -20))
        area.drag(.topRight, by: CGSize(width: 30, height: -20))
        XCTAssertEqual(drags, [CGSize(width: 30, height: 0), CGSize(width: 0, height: 20), CGSize(width: 30, height: 20),
                               CGSize(width: 0, height: 20), CGSize(width: 30, height: 20)],
                       "The side edge follows the pointer across, the bottom down, the top up, a corner both ways.")

        let frame = PeekPreviewFrame()
        let sizing = PeekSizing(scale: 1, opening: CGSize(width: 800, height: 400), largest: CGSize(width: 1000, height: 600))
        frame.natural = CGSize(width: 500, height: 200)
        frame.widthGain = { 2 }
        frame.drag(by: CGSize(width: 10, height: 0), sizing: sizing)
        frame.drag(by: CGSize(width: 40, height: 30), sizing: sizing)
        XCTAssertEqual(frame.size, CGSize(width: 580, height: 230), "Each step of a drag counts from where the drag began.")
        frame.endDrag()
        frame.drag(by: CGSize(width: 0, height: 10), sizing: sizing)
        XCTAssertEqual(frame.size, CGSize(width: 580, height: 240), "The next drag begins at the size the last one left.")
    }

    @MainActor
    func testPeekViewKeepsItsLeftEdgeAsItIsResized() throws {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame { window.setFrameOrigin(CGPoint(x: screen.minX + 20, y: screen.minY + 20)) }
        defer { window.close() }
        let panel = VSFloatingPanel()
        defer { panel.close() }
        panel.show(Color.clear.frame(width: 300, height: 100), anchor: CGRect(x: 400, y: 300, width: 1, height: 10), in: view,
                   placement: .below, interactive: true, maxWidth: .greatestFiniteMagnitude, resizable: true)
        let shown = try XCTUnwrap(window.childWindows?.first)
        let right = window.frame.maxX - 4
        // Its preview loaded wider than the room right of its line, the peek view is pushed in from the window's edge.
        panel.fit(CGSize(width: 700, height: 100))
        XCTAssertEqual(shown.frame.maxX, right, accuracy: 0.5)
        panel.fit(CGSize(width: 500, height: 100))
        XCTAssertEqual(shown.frame.minX, right - 700, accuracy: 0.5, "Narrowed, it keeps its left edge and its right edge follows the pointer.")
        panel.fit(CGSize(width: 750, height: 100))
        XCTAssertEqual(shown.frame.maxX, right, accuracy: 0.5, "Widened past the window, it moves left as far as it must to stay inside.")
    }

    @MainActor
    func testResizedPeekFitsThePageToItsNewWidth() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let index = try XCTUnwrap(fixture.store.references)
        let resolved = await index.resolve(ReferenceKey(kind: .equation, number: "1.1"), from: 2)
        let target = try XCTUnwrap(resolved)
        let peek = PeekPDFView(frame: CGRect(x: 0, y: 0, width: 556, height: 300))
        peek.displayMode = .singlePageContinuous; peek.autoScales = false
        peek.document = fixture.store.document
        let window = NSWindow(contentRect: peek.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = peek
        defer { window.close() }
        peek.target = target
        peek.layoutSubtreeIfNeeded(); peek.layout()
        let narrow = peek.scaleFactor
        let page = try XCTUnwrap(fixture.store.document?.page(at: target.pageIndex))
        window.setContentSize(CGSize(width: 1000, height: 300))
        peek.layoutSubtreeIfNeeded(); peek.layout()
        XCTAssertEqual(peek.scaleFactor, peek.scaleFactorForSizeToFit, accuracy: 0.001, "Widened, the page fills the new width.")
        XCTAssertGreaterThan(peek.scaleFactor, narrow * 1.5)
        let label = peek.convert(target.anchor.rect, from: page)
        XCTAssertTrue(peek.bounds.insetBy(dx: -1, dy: -1).intersects(label), "The referenced item stays in view: \(label) in \(peek.bounds).")
    }

    @MainActor
    func testContextMenuOffersReferenceAndSelectionActions() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let store = fixture.store, view = fixture.view
        store.reader.goToPage(3); store.reader.updatePage()
        let mention = try XCTUnwrap(store.references?.mentions(onPage: 2).first { $0.key.kind == .equation })
        let point = fixture.point(in: mention, onPage: 2)
        let menu = try XCTUnwrap(view.menu(for: try fixture.event(.rightMouseDown, at: point)))
        XCTAssertEqual(Array(menu.items.prefix(5).map(\.title)), ["Peek at (1.1)", "Go to (1.1)", "Open (1.1) to the Side", "Pin (1.1)", "Find All References to (1.1)"])
        let goTo = menu.items[1]
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(goTo.action), to: goTo.target, from: goTo))
        let deadline = Date.now.addingTimeInterval(3)
        while store.reader.pageNumber != 1 && Date.now < deadline { try await Task.sleep(for: .milliseconds(20)); store.reader.updatePage() }
        XCTAssertEqual(store.reader.pageNumber, 1, "Go to resolves the reference, then moves the reader.")

        store.reader.goToPage(3); store.reader.updatePage()
        store.reader.selection = (2, CGRect(x: 70, y: 596, width: 300, height: 18), "Returning to the general case")
        store.reader.hasSelection = true
        let blank = view.convert(CGPoint(x: 500, y: 300), from: try XCTUnwrap(store.document?.page(at: 2)))
        let selectionMenu = try XCTUnwrap(view.menu(for: try fixture.event(.rightMouseDown, at: blank)))
        let titles = selectionMenu.items.map(\.title)
        for expected in ["Ask About Selection…", "New Note from Selection", "Highlight", "Pin Selection", "Bookmark Page"] {
            XCTAssertTrue(titles.contains(expected), expected)
        }
        XCTAssertFalse(titles.contains { $0.hasPrefix("Peek") }, "Reference actions appear only over a reference.")
        let pin = try XCTUnwrap(selectionMenu.items.first { $0.title == "Pin Selection" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(pin.action), to: pin.target, from: pin))
        XCTAssertEqual(store.workspace?.pins.count, 1)
    }

    @MainActor
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source: URL
        let support: URL
        let originalBytes: Data
        let store: StudyStore
        let view: RegionPDFView
        let window: NSWindow
        private let previous = UserDefaults.standard.object(forKey: "lastWorkspaceID")
        private var coordinator: PDFReaderSurface.Coordinator?

        init(hosted: Bool = false) throws {
            _ = NSApplication.shared
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            source = root.appendingPathComponent("references.pdf")
            support = root.appendingPathComponent("support")
            originalBytes = try Self.pdf()
            try originalBytes.write(to: source)
            store = StudyStore(root: support)
            store.open(source)
            if hosted {
                window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: .titled, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = NSHostingView(rootView: ReaderWindow(store: store))
                window.orderFront(nil)
                window.contentView?.layoutSubtreeIfNeeded()
                view = store.reader.view ?? RegionPDFView()
            } else {
                view = RegionPDFView(frame: CGRect(x: 0, y: 0, width: 640, height: 820))
                view.controller = store.reader; store.reader.view = view
                view.document = store.document
                view.displayMode = .singlePage; view.autoScales = true
                window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = view
                let coordinator = PDFReaderSurface.Coordinator(controller: store.reader)
                coordinator.observe(view); self.coordinator = coordinator
                view.layoutDocumentView(); view.layoutSubtreeIfNeeded()
            }
        }

        func close() {
            store.referencePeek = nil
            coordinator?.stop()
            window.close()
            UserDefaults.standard.set(previous, forKey: "lastWorkspaceID")
            try? FileManager.default.removeItem(at: root)
        }

        func point(in mention: PageMention, onPage index: Int) -> CGPoint {
            let page = store.document!.page(at: index)!
            let rect = mention.rects[0]
            return view.convert(CGPoint(x: rect.midX, y: rect.midY), from: page)
        }

        func event(_ type: NSEvent.EventType, at point: CGPoint, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: modifiers, timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }

        static func pdf() throws -> Data {
            let bytes = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: bytes)), mediaBox: &box, nil))
            let font = NSFont(name: "Times New Roman", size: 12) ?? NSFont.systemFont(ofSize: 12)
            func page(_ draw: () -> Void) {
                context.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                NSColor.white.setFill(); box.fill()
                draw()
                NSGraphicsContext.restoreGraphicsState(); context.endPDFPage()
            }
            func text(_ string: String, _ x: Double, _ y: Double, right: Bool = false) {
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
                let width = (string as NSString).size(withAttributes: attributes).width
                (string as NSString).draw(at: CGPoint(x: right ? x - width : x, y: y), withAttributes: attributes)
            }
            page {
                text("Linear models describe the response as a weighted sum of the inputs, and", 72, 580)
                text("we estimate the weights by least squares. The model is written as", 72, 564)
                text("y = Xβ + ε,", 250, 505)
                text("(1.1)", 540, 505, right: true)
                text("where the noise has mean zero and the inputs are measured without error", 72, 450)
            }
            page {
                NSColor.darkGray.setStroke()
                NSBezierPath(rect: CGRect(x: 150, y: 420, width: 300, height: 220)).stroke()
                text("FIGURE 1.1. A fitted line through simulated data. The line is the least", 72, 390)
                text("squares fit of the response on a single input.", 72, 376)
            }
            page {
                text("Returning to the general case, the model (1.1) is linear in its coefficients", 72, 600)
                text("and Figure 1.1 shows a fitted example, which we revisit in the exercises", 72, 584)
            }
            context.closePDF()
            return bytes as Data
        }
    }
}
