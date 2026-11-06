import XCTest
import AppKit
import PDFKit
import LemmaCore
@testable import Lemma

final class HighlightGeometryTests: XCTestCase {
    @MainActor
    func testInflatedMathMetricsDoNotHighlightTheUnselectedNeighbour() throws {
        let document = try document()
        let page = try XCTUnwrap(document.page(at: 0))
        let selected = try selection("First, the distance", through: "sizing the experiment.", on: page)
        let neighbour = try selection("This neighbouring line", through: "highlighting.", on: page).bounds(for: page)
        let regions = selected.selectionsByLine().map { PageRegion($0.bounds(for: page)) }
        XCTAssertEqual(regions.count, 2)
        XCTAssertTrue(regions[1].rect.intersects(neighbour), "The fixture must reproduce PDFKit's inflated math metrics")
        let mark = StudyHighlight(pageIndex: 0, regions: regions, quote: selected.string ?? "")
        let renderer = ReaderController()
        renderer.syncHighlights([mark], in: document)
        let annotations = page.annotations
        XCTAssertEqual(annotations.count, 2)
        XCTAssertEqual(annotations[0].bounds, regions[0].rect, "Ordinary line geometry stays unchanged")
        XCTAssertFalse(annotations[1].bounds.intersects(neighbour), "A tall font box must not paint the next line")
        XCTAssertEqual(mark.regions, regions, "Repairing old marks must not rewrite stored annotations")
        renderer.syncHighlights([mark], in: document)
        XCTAssertTrue(page.annotations[1] === annotations[1], "Unchanged updates reuse the existing annotation")
        let exported = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(document.dataRepresentation())))
        let exportedPage = try XCTUnwrap(exported.page(at: 0))
        XCTAssertFalse(exportedPage.annotations[1].bounds.intersects(neighbour), "The correction also survives PDF export")
    }

    @MainActor
    func testConsecutiveHighlightsDoNotStackAtAnyPageRotation() throws {
        for rotation in [0, 90, 180, 270] {
            let document = try document()
            let page = try XCTUnwrap(document.page(at: 0))
            page.rotation = rotation
            let selected = try selection("Three comparisons", through: "highlighting.", on: page)
            let regions = selected.selectionsByLine().map { PageRegion($0.bounds(for: page)) }
            let renderer = ReaderController()
            // Separate marks must share the same bands, just like lines in one mark.
            let marks = regions.map { StudyHighlight(pageIndex: 0, regions: [$0], quote: "") }
            renderer.syncHighlights(marks, in: document)
            let rects = page.annotations.map(\.bounds)
            XCTAssertEqual(rects.count, 3)
            for (index, rect) in rects.enumerated() {
                for other in rects.dropFirst(index + 1) {
                    XCTAssertFalse(rect.intersects(other), "Separate lines must not double the highlight opacity (rotation \(rotation))")
                }
            }
            renderer.showAnnotations = false
            renderer.syncHighlights(marks, in: document)
            XCTAssertTrue(page.annotations.isEmpty)
            renderer.showAnnotations = true
            renderer.syncHighlights(marks, in: document)
            XCTAssertEqual(page.annotations.map(\.bounds), rects)

            let formulas = try selection("Consecutive math line", through: "raised exponent.", on: page)
            let formulaMark = StudyHighlight(pageIndex: 0, regions: formulas.selectionsByLine().map { PageRegion($0.bounds(for: page)) }, quote: formulas.string ?? "")
            renderer.syncHighlights([formulaMark], in: document)
            let formulaRects = page.annotations.map(\.bounds)
            XCTAssertGreaterThanOrEqual(formulaRects.count, 2)
            for (index, rect) in formulaRects.enumerated() {
                for other in formulaRects.dropFirst(index + 1) { XCTAssertFalse(rect.intersects(other)) }
            }
        }
    }

    @MainActor
    func testColumnsMixedFontSizesAndCapturedAreas() throws {
        let document = try document()
        let page = try XCTUnwrap(document.page(at: 0))
        let geometry = HighlightGeometry(page: page, fonts: InkFontCache())
        for (first, last) in [("Left column", "lected."), ("Small text above", "Small text below a larger line.")] {
            let selected = try selection(first, through: last, on: page)
            let rects = geometry.rects(for: selected.selectionsByLine().map { $0.bounds(for: page) })
            for (index, rect) in rects.enumerated() {
                XCTAssertGreaterThan(rect.height, 0)
                for other in rects.dropFirst(index + 1) where rect.minX < other.maxX && rect.maxX > other.minX {
                    XCTAssertFalse(rect.intersects(other), "Column text and mixed font sizes must get distinct bands")
                }
            }
        }
        let right = try selection("Right column", through: "A third line in the right column.", on: page)
        for line in right.selectionsByLine() {
            XCTAssertEqual(geometry.bounds(for: line.bounds(for: page)), line.bounds(for: page), "A separate column must not constrain this one")
        }
        let area = CGRect(x: 55, y: 720, width: 400, height: 65)
        XCTAssertEqual(geometry.bounds(for: area), area, "A deliberate captured area remains an area")

        let text = (page.string ?? "") as NSString
        let mathStart = NSMaxRange(text.range(of: "limits:"))
        let math = try XCTUnwrap(page.selection(for: NSRange(location: mathStart, length: text.length - mathStart)))
        let rawMathRects = math.selectionsByLine().map { $0.bounds(for: page) }
        let mathRects = geometry.rects(for: rawMathRects)
        for glyph in PageInkScanner.scan(page).glyphs {
            let center = CGPoint(x: glyph.midX, y: glyph.y + glyph.size * 0.25)
            if rawMathRects.contains(where: { $0.contains(center) }) {
                XCTAssertTrue(mathRects.contains { $0.contains(center) }, "Displayed fractions and limits must stay covered")
            }
        }

        // A new document with the same page number must not reuse the previous PDF's line layout.
        let renderer = ReaderController()
        let mark = StudyHighlight(pageIndex: 0, regions: [PageRegion(area)], quote: "Captured area")
        renderer.syncHighlights([mark], in: document)
        let second = try self.document()
        renderer.syncHighlights([mark], in: second)
        XCTAssertTrue(page.annotations.isEmpty)
        XCTAssertEqual(second.page(at: 0)?.annotations.first?.bounds, area)
    }

    @MainActor
    func testSelectingAnAdjacentFormulaDoesNotTargetTheWrongHighlight() throws {
        let fixture = try WorkbenchFixture()
        let store = fixture.store
        defer { store.app.prepareForTermination(); fixture.close() }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "tight-highlights", withExtension: "pdf", subdirectory: "Fixtures"))
        store.open(url)
        let page = try XCTUnwrap(store.document?.page(at: 0))
        let neighbour = try selection("This neighbouring line", through: "highlighting.", on: page)
        store.workspace?.highlights = [StudyHighlight(pageIndex: 0,
            regions: neighbour.selectionsByLine().map { PageRegion($0.bounds(for: page)) }, quote: neighbour.string ?? "")]
        let view = RegionPDFView()
        view.controller = store.reader; view.document = store.document; store.reader.view = view
        let formula = try selection("We retain", through: "sizing the experiment.", on: page)
        view.setCurrentSelection(formula, animate: false)
        store.reader.updateSelection()
        XCTAssertTrue(store.reader.hasSelection)
        XCTAssertNil(store.activeHighlight, "Oversized formula metrics must not recolor or remove the mark on the next line")
    }

    private func document() throws -> PDFDocument {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "tight-highlights", withExtension: "pdf", subdirectory: "Fixtures"))
        return try XCTUnwrap(PDFDocument(url: url))
    }

    private func selection(_ first: String, through last: String, on page: PDFPage) throws -> PDFSelection {
        let text = (page.string ?? "") as NSString
        let start = text.range(of: first)
        XCTAssertNotEqual(start.location, NSNotFound)
        let end = text.range(of: last, range: NSRange(location: start.location, length: text.length - start.location))
        XCTAssertNotEqual(end.location, NSNotFound)
        return try XCTUnwrap(page.selection(for: NSRange(location: start.location, length: NSMaxRange(end) - start.location)))
    }
}
