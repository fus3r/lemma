import XCTest
import AppKit
import PDFKit
import LemmaCore
@testable import Lemma

final class LinkedReferenceTests: XCTestCase {
    @MainActor
    func testNumberedStatementLinksUseTheirDestinationToNameThePeek() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = DocumentIndexRepository(root: root)
        let document = try Self.document()
        let page = try XCTUnwrap(document.page(at: 0))
        let statement = ReferenceKey(kind: .theorem, number: "3.21", name: "Result")
        let equation = ReferenceKey(kind: .equation, number: "3.21")
        var analysis = BookAnalysis(pageCount: document.pageCount)
        analysis.itemsByNumber = true
        analysis.definitions = [ReferenceTarget(key: statement, pageIndex: 1,
            anchor: PageRegion(x: 72, y: 500, width: 25, height: 18),
            region: PageRegion(x: 72, y: 500, width: 300, height: 18), origin: .text)]
        let raw = PageReferenceAnalyzer.mentions(on: page, in: document).sorted { $0.rects[0].minY > $1.rects[0].minY }
        XCTAssertEqual(raw.count, 3)
        // Like Axler's (3.21), the link is a parenthesized number, pointing just above the numbered statement.
        for (mention, destination) in zip(raw, [(1, CGPoint(x: 72, y: 552)), (1, CGPoint(x: 72, y: 120)), (2, CGPoint(x: 72, y: 552))]) {
            let link = PDFAnnotation(bounds: mention.rects[0], forType: .link, withProperties: nil)
            link.destination = PDFDestination(page: try XCTUnwrap(document.page(at: destination.0)), at: destination.1)
            page.addAnnotation(link)
        }
        try repository.save(analysis, id: "statements")
        let model = BookAnalysisModel(workspaceID: "statements", repository: repository)
        defer { model.cancel() }
        for _ in 0..<100 where model.isLoadingCache { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(model.analysis)
        let index = ReferenceIndex(workspaceID: "statements", document: document, outline: [], repository: repository)
        defer { index.saveIfNeeded() }
        index.analysis = model
        let mentions = index.mentions(onPage: 0).sorted { $0.rects[0].minY > $1.rects[0].minY }
        XCTAssertEqual(mentions.map(\.key), [statement, equation, equation],
                       "Only a link whose destination confirms the statement is renamed; distant and other-page links stay unchanged.")
        let target = await index.resolve(mentions[0], from: 0)
        XCTAssertEqual(target?.key, statement)
        XCTAssertEqual(target?.pageIndex, 1)
        XCTAssertEqual(target?.origin, .link)

        // A book with a real equation of this number must not globally reinterpret it as the statement.
        analysis.definitions.append(ReferenceTarget(key: equation, pageIndex: 2,
            anchor: PageRegion(x: 500, y: 500, width: 25, height: 18),
            region: PageRegion(x: 72, y: 500, width: 450, height: 18), origin: .text))
        try repository.save(analysis, id: "both")
        let both = BookAnalysisModel(workspaceID: "both", repository: repository)
        defer { both.cancel() }
        for _ in 0..<100 where both.isLoadingCache { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(both.analysis)
        index.analysis = both; index.invalidateMentions()
        XCTAssertTrue(index.mentions(onPage: 0).allSatisfy { $0.key == equation })
    }

    @MainActor
    private static func document() throws -> PDFDocument {
        let bytes = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: bytes)), mediaBox: &box, nil))
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black]
        for lines in [[("By (3.21) we obtain the result.", 700), ("Compare (3.21) below.", 650), ("See also (3.21).", 600)],
                      [("3.21 The dimension formula", 500)], [("Other page", 500)]] {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            for (text, y) in lines { (text as NSString).draw(at: CGPoint(x: 72, y: y), withAttributes: attributes) }
            NSGraphicsContext.restoreGraphicsState(); context.endPDFPage()
        }
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: bytes as Data))
    }
}
