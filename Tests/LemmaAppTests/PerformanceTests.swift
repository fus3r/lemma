import XCTest
import AppKit
import PDFKit
import SwiftUI
import LemmaCore
import Observation
import os
@testable import Lemma

/// Opt-in measurements on a real book, in a disposable copy of its support folder.
/// Run with LEMMA_PERF_SUPPORT, LEMMA_PERF_PDF and LEMMA_PERF_OUTPUT, using `swift test -c release`.
final class PerformanceTests: XCTestCase {
    @MainActor
    func testMeasureMinimapDrag() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let support = env["LEMMA_PERF_SUPPORT"], let pdf = env["LEMMA_PERF_PDF"], let output = env["LEMMA_PERF_OUTPUT"] else {
            throw XCTSkip("Opt-in real-book minimap measurements.")
        }
        _ = NSApplication.shared
        let previous = UserDefaults.standard.object(forKey: "lastWorkspaceID")
        let previousTabs = UserDefaults.standard.object(forKey: "openTabs")
        let store = StudyStore(root: URL(fileURLWithPath: support))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 796, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentLayoutRect)
        let view = RegionPDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 700))
        let minimap = MinimapView(frame: CGRect(x: 700, y: 0, width: 96, height: 700))
        window.contentView = content; content.addSubview(view); content.addSubview(minimap)
        defer {
            store.analysis?.cancel(); window.close()
            UserDefaults.standard.set(previous, forKey: "lastWorkspaceID")
            UserDefaults.standard.set(previousTabs, forKey: "openTabs")
        }
        let opened = await withCheckedContinuation { continuation in
            store.openFile(URL(fileURLWithPath: pdf), then: { continuation.resume(returning: $0) })
        }
        XCTAssertTrue(opened, "The PDF must finish opening before its minimap is measured")
        let document = try XCTUnwrap(store.document)
        view.controller = store.reader; store.reader.view = view
        view.displayMode = .singlePageContinuous; view.displayDirection = .vertical; view.document = document
        view.autoScales = false; view.scaleFactor = 1.2
        minimap.controller = store.reader; minimap.colors = ThemeManager.shared.colors; minimap.attach()
        let coordinator = PDFReaderSurface.Coordinator(controller: store.reader)
        coordinator.observe(view)
        defer { coordinator.stop() }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        view.layoutDocumentView(); store.reader.updatePage()
        var pages: [Int] = []
        let saveReading = store.reader.onReadingChanged
        store.reader.onReadingChanged = { page, scale in pages.append(page); saveReading?(page, scale) }
        func event(_ type: NSEvent.EventType, y: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: minimap.convert(CGPoint(x: 48, y: y), to: nil),
                                           modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        minimap.mouseDown(with: try event(.leftMouseDown, y: 3))
        var burst: [Double] = []
        for step in 1...120 {
            let input = try event(.leftMouseDragged, y: 3 + CGFloat(step) * 4)
            burst.append(timed { minimap.mouseDragged(with: input) })
        }
        let release = try event(.leftMouseUp, y: 483)
        let releaseMS = timed { minimap.mouseUp(with: release) }
        try await Task.sleep(for: .milliseconds(300))
        var paced: [Double] = []
        minimap.mouseDown(with: try event(.leftMouseDown, y: 100))
        for step in 1...36 {
            let input = try event(.leftMouseDragged, y: 100 + CGFloat(step) * 10)
            paced.append(timed { minimap.mouseDragged(with: input) })
            try await Task.sleep(for: .milliseconds(8))
        }
        minimap.mouseUp(with: try event(.leftMouseUp, y: 460))
        try await Task.sleep(for: .milliseconds(350))
        store.flush()
        let visible = view.visiblePages.map { store.document!.index(for: $0) }
        XCTAssertTrue(visible.contains(store.workspace!.reading.pageIndex),
                      "Saved page \(store.workspace!.reading.pageIndex), visible pages \(visible), reader page \(store.reader.pageNumber), destination \(view.currentDestination?.page.map { store.document!.index(for: $0) } ?? -1)")
        try JSONSerialization.data(withJSONObject: ["burst_input_ms": burst, "release_ms": releaseMS,
            "paced_input_ms": paced, "reading_callbacks": pages.count, "distinct_pages": Set(pages).count,
            "final_page": store.reader.pageNumber, "visible_pages": visible, "saved_page": store.workspace!.reading.pageIndex],
            options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }

    /// Cold page metadata is part of scrolling even when the PDF tiles themselves are already warm.
    @MainActor
    func testMeasureColdPageMetadata() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let support = env["LEMMA_PERF_SUPPORT"], let pdf = env["LEMMA_PERF_PDF"], let output = env["LEMMA_PERF_OUTPUT"] else {
            throw XCTSkip("Opt-in real-book scroll measurements.")
        }
        _ = NSApplication.shared
        let previous = UserDefaults.standard.object(forKey: "lastWorkspaceID")
        let previousTabs = UserDefaults.standard.object(forKey: "openTabs")
        let store = StudyStore(root: URL(fileURLWithPath: support))
        defer {
            store.analysis?.cancel()
            UserDefaults.standard.set(previous, forKey: "lastWorkspaceID")
            UserDefaults.standard.set(previousTabs, forKey: "openTabs")
        }
        let opened = await withCheckedContinuation { continuation in
            store.openFile(URL(fileURLWithPath: pdf), then: { continuation.resume(returning: $0) })
        }
        XCTAssertTrue(opened, "The PDF must finish opening before its page metadata is measured")
        let document = try XCTUnwrap(store.document)
        let view = RegionPDFView(frame: CGRect(x: 0, y: 0, width: 640, height: 760))
        view.controller = store.reader; store.reader.view = view; view.document = document
        var samples: [[String: Any]] = []
        for index in [28, 30, 38, 41, 62, 68, 92, 108, 128, 162, 181, 182, 190, 200, 240, 300, 350, 400, 500, 600] where index < document.pageCount {
            let page = try XCTUnwrap(document.page(at: index))
            let start = CACurrentMediaTime()
            let lines = store.reader.readingLines(onPage: index)
            let afterLines = CACurrentMediaTime()
            let mentions = store.references?.mentions(onPage: index) ?? []
            let afterMentions = CACurrentMediaTime()
            samples.append(["pageIndex": index, "lines": lines.count, "mentions": mentions.count,
                            "line_ms": (afterLines - start) * 1000, "reference_ms": (afterMentions - afterLines) * 1000,
                            "copy_ms": timed { _ = page.copy() }])
        }
        try JSONSerialization.data(withJSONObject: ["cold_pages": samples], options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
    }

    @MainActor private func timed(_ operation: () -> Void) -> Double {
        let start = CACurrentMediaTime(); operation(); return (CACurrentMediaTime() - start) * 1000
    }

    @MainActor
    func testMeasureReaderAndEditor() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let support = env["LEMMA_PERF_SUPPORT"], let pdf = env["LEMMA_PERF_PDF"], let output = env["LEMMA_PERF_OUTPUT"] else {
            throw XCTSkip("Opt-in real-book performance measurements.")
        }
        _ = NSApplication.shared
        let previous = UserDefaults.standard.object(forKey: "lastWorkspaceID")
        let previousTabs = UserDefaults.standard.object(forKey: "openTabs")
        let store = StudyStore(root: URL(fileURLWithPath: support))
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 1300, height: 860), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            store.flush(); store.analysis?.cancel(); window.close()
            UserDefaults.standard.set(previous, forKey: "lastWorkspaceID")
            UserDefaults.standard.set(previousTabs, forKey: "openTabs")
        }
        var metrics: [String: Any] = [:]
        let start = CACurrentMediaTime()
        let opened = await withCheckedContinuation { continuation in
            store.openFile(URL(fileURLWithPath: pdf), then: { continuation.resume(returning: $0) })
        }
        XCTAssertTrue(opened, "The PDF must finish opening before its reader and editor are measured")
        metrics["open_ms"] = (CACurrentMediaTime() - start) * 1000
        let document = try XCTUnwrap(store.document)
        metrics["pages"] = document.pageCount
        metrics["thumbnail_batch_ms"] = (0..<8).map { batch in
            let start = CACurrentMediaTime()
            for index in (100 + batch * 6)..<(106 + batch * 6) {
                autoreleasepool { _ = document.page(at: index)?.thumbnail(of: CGSize(width: 168, height: 224), for: .cropBox) }
            }
            return (CACurrentMediaTime() - start) * 1000
        }
        metrics["page_copy_ms"] = (150..<160).map { index in
            let start = CACurrentMediaTime(); _ = document.page(at: index)?.copy()
            return (CACurrentMediaTime() - start) * 1000
        }
        metrics["page_copy_class"] = String(describing: type(of: document.page(at: 150)!.copy()))
        window.contentView = NSHostingView(rootView: ReaderWindow(store: store))
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(600))
        let view = try XCTUnwrap(store.reader.view)
        store.reader.goToPage(min(42, document.pageCount))
        try await Task.sleep(for: .milliseconds(400))
        metrics["overlay_refresh_ms"] = (0..<50).map { _ in
            let start = CACurrentMediaTime(); view.refreshCaptureOverlay()
            return (CACurrentMediaTime() - start) * 1000
        }
        metrics["save_ms"] = (0..<20).map { _ in
            let start = CACurrentMediaTime(); store.flush()
            return (CACurrentMediaTime() - start) * 1000
        }
        let workspaceChanges = OSAllocatedUnfairLock(initialState: 0)
        let savingChanges = OSAllocatedUnfairLock(initialState: 0)
        let pageIndex = store.workspace!.reading.pageIndex, scale = store.workspace!.reading.scale
        metrics["scroll_notification_ms"] = (0..<200).map { _ in
            withObservationTracking { _ = store.workspace } onChange: { workspaceChanges.withLock { $0 += 1 } }
            withObservationTracking { _ = store.isSaving } onChange: { savingChanges.withLock { $0 += 1 } }
            let start = CACurrentMediaTime(); store.reader.onReadingChanged?(pageIndex, scale)
            return (CACurrentMediaTime() - start) * 1000
        }
        metrics["scroll_workspace_changes"] = workspaceChanges.withLock { $0 }
        metrics["scroll_saving_changes"] = savingChanges.withLock { $0 }
        let editor = LabTextView(usingTextLayoutManager: false)
        editor.font = LabCodeStyle.font
        editor.string = String(repeating: "    prediction = model.predict(X_test)  # compare the result\n", count: 200)
        LabCodeStyle.highlight(try XCTUnwrap(editor.textStorage))
        metrics["editor_height_ms"] = (0..<30).map { _ in
            let start = CACurrentMediaTime(); _ = editor.height(forWidth: 420)
            return (CACurrentMediaTime() - start) * 1000
        }
        // Each jump exposes cold miniatures; a 5 ms heartbeat reveals stalls on the main actor.
        try "ready".write(to: URL(fileURLWithPath: output + ".ready"), atomically: true, encoding: .utf8)
        var heartbeat: [Double] = []
        let monitor = Task { @MainActor in
            var previous = CACurrentMediaTime()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                let now = CACurrentMediaTime(); heartbeat.append((now - previous) * 1000); previous = now
            }
        }
        for page in [200, 400, 600, 300, 500, 700] where page <= document.pageCount {
            store.reader.goToPage(page)
            try await Task.sleep(for: .milliseconds(200))
        }
        monitor.cancel()
        metrics["jump_heartbeat_ms"] = heartbeat
        metrics["view_size"] = [view.bounds.width, view.bounds.height]
        try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
}
