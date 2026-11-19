import XCTest
import AppKit
import PDFKit
@testable import LemmaCore

final class ReferenceTests: XCTestCase {
    func testScannerRecognizesBookAndPaperNumbering() {
        func keys(_ text: String) -> [String] { ReferenceScanner.mentions(in: text).map { $0.key.spokenTitle } }
        XCTAssertEqual(keys("then fit by averaging as in (2.8). The predicted"), ["Equation (2.8)"])
        XCTAssertEqual(keys("evaluate f(2.5) and g (0.5) at the mean"), [], "Function values and decimals are not equation labels.")
        XCTAssertEqual(keys("Figures 2.1, 2.2 and 2.3 use the same data"), ["Figure 2.1", "Figure 2.2", "Figure 2.3"])
        XCTAssertEqual(keys("as in Figure 2.1 and 15 nearest neighbours"), ["Figure 2.1"], "List items must share the first item's numbering shape.")
        XCTAssertEqual(keys("See Section 2.3.3. In Chapter 4 that changes"), ["Section 2.3.3", "Chapter 4"])
        XCTAssertEqual(keys("Ex. 2.8 Compare, then Exercise 3.3 and Exercises 3.4–3.5"), ["Exercise 2.8", "Exercise 3.3", "Exercise 3.4", "Exercise 3.5"])
        XCTAssertEqual(keys("Algorithm 3.2 with the lasso modification Algorithm 3.2a"), ["Algorithm 3.2", "Algorithm 3.2a"])
        XCTAssertEqual(keys("By Theorem 4.2 (Gauss–Markov), Lemma 1 and Cor. 3"), ["Theorem 4.2", "Lemma 1", "Corollary 3"])
        XCTAssertEqual(keys("Eqs. (3) and (4) imply equation (12); Derive equation (2.24)."), ["Equation (3)", "Equation (4)", "Equation (12)", "Equation (2.24)"])
        XCTAssertEqual(keys("an interval [0, 1] and (1) the first case"), [], "Bare single numbers stay ambiguous without a word.")

        let mentions = ReferenceScanner.mentions(in: "Figures 2.1, 2.2")
        XCTAssertEqual(mentions.map(\.text), ["Figures 2.1", "2.2"])
        XCTAssertEqual(mentions.map(\.hasHead), [true, false])
        XCTAssertEqual(ReferenceKey(kind: .equation, number: "2.3").chapter, 2)
        XCTAssertEqual(ReferenceKey(kind: .chapter, number: "4").chapter, 4)
        XCTAssertNil(ReferenceKey(kind: .theorem, number: "1", name: "Lemma").chapter)
        XCTAssertEqual(ReferenceKey(kind: .equation, number: "2.3").searchText, "(2.3)")
        XCTAssertEqual(ReferenceKey(kind: .theorem, number: "4.2", name: "Lemma").title, "Lemma 4.2")
    }

    func testHeadingsAreShortNumberedLines() {
        let text = "2.3.3 From Least Squares to Nearest Neighbors\n2.5 times larger than before, which continues\n3.1 Introduction\n"
        XCTAssertEqual(ReferenceScanner.headings(in: text).map(\.key.number), ["2.3.3", "3.1"])
    }

    @MainActor
    func testReportChartsAndBookmarkedReferences() throws {
        let document = try reportDocument()
        let outline = [
            OutlineItem(title: "Overview", pageIndex: 0, level: 0),
            OutlineItem(title: "Box 1 First group of charts", pageIndex: 1, level: 0, point: CGPoint(x: 72, y: 728)),
            OutlineItem(title: "Box 2 Second group of charts", pageIndex: 2, level: 0, point: CGPoint(x: 72, y: 728)),
            OutlineItem(title: "Conclusions", pageIndex: 2, level: 0, point: CGPoint(x: 72, y: 342)),
            OutlineItem(title: "Special features", pageIndex: 3, level: 0),
            OutlineItem(title: "A An appendix with charts", pageIndex: 3, level: 1, point: CGPoint(x: 72, y: 728))
        ]
        let analysis = try XCTUnwrap(BookAnalyzer.analyze(document: document, outline: outline))
        let targets = analysis.definitionsByKey()
        let first = ReferenceKey(kind: .chart, number: "A", name: "Box 1")
        let second = ReferenceKey(kind: .chart, number: "A", name: "Box 2")
        XCTAssertEqual(targets[first]?.pageIndex, 1)
        XCTAssertEqual(targets[second]?.pageIndex, 2)
        XCTAssertEqual(analysis.mentions.filter { $0.key == first }.map(\.pageIndex), [1])
        XCTAssertEqual(analysis.mentions.filter { $0.key == second }.map(\.pageIndex), [2])
        XCTAssertNil(targets[ReferenceKey(kind: .chart, number: "99")], "Running text that begins with a chart mention is not a caption.")

        let chart = try XCTUnwrap(targets[ReferenceKey(kind: .chart, number: "1")])
        XCTAssertTrue(chart.region.rect.contains(CGRect(x: 90, y: 430, width: 390, height: 125)))
        XCTAssertGreaterThan(chart.region.y, 365, "The body paragraph below the chart is outside the preview.")
        for (kind, number, page) in [(ReferenceKind.chart, "A.1", 3), (.box, "2", 2), (.specialFeature, "A", 3)] {
            let key = ReferenceKey(kind: kind, number: number)
            XCTAssertEqual(targets[key]?.pageIndex, page)
            XCTAssertTrue(analysis.mentions.contains { $0.key == key && $0.pageIndex == 0 })
        }
    }

    @MainActor
    private func reportDocument() throws -> PDFDocument {
        let bytes = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: bytes)), mediaBox: &box, nil))
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        bitmap.setFillColor(NSColor.gray.cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let artwork = try XCTUnwrap(bitmap.makeImage())
        for (heading, mention, chart) in [
            ("Overview", "See Chart 1, Chart A.1, Box 2 and Special Feature A for more details.", "Chart 1"),
            ("Box 1", "The two indicators are shown together in Chart A, panel a.", "Chart A"),
            ("Box 2", "The next set of indicators is shown in Chart A, panel b.", "Chart A"),
            ("A An appendix with charts", "See Chart A.1 for the final results.", "Chart A.1")
        ] {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            func draw(_ text: String, at y: CGFloat, size: CGFloat = 12) {
                (text as NSString).draw(at: CGPoint(x: 72, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size)])
            }
            draw(heading, at: 710, size: 14)
            draw(mention, at: 665)
            draw(chart, at: 620)
            draw("Results from two independent surveys and a comparison with the baseline", at: 598)
            draw("Survey estimates, percentages", at: 580, size: 9)
            context.draw(artwork, in: CGRect(x: 90, y: 430, width: 390, height: 125))
            draw("Sources: two independent surveys and the survey methodology.", at: 412, size: 8)
            draw("The analysis continues with results for the full population and its subgroups.", at: 365)
            if heading == "Box 2" {
                draw("Conclusions", at: 320, size: 14)
                draw("Chart A, panel a, is outside the box here.", at: 285)
                draw("Chart 99, as referenced in an earlier edition, is unavailable.", at: 269)
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: bytes as Data))
    }

    func testEquationRegionCoversTheDisplayAndStopsAtBodyText() {
        // Geometry of ESL equation (2.3) and its neighbours, as reported by PDFKit.
        let page = CGRect(x: 72, y: 72, width: 450, height: 648)
        let fragments = [
            fragment("many different methods, but by far the most popular is the method of", 133.8, 536.2, 322.8, 10),
            fragment("least squares. In this approach, we pick the coefficients β to minimize the", 133.8, 524.2, 322.8, 10),
            fragment("residual sum of squares", 133.8, 512.3, 101.6, 10),
            fragment("RSS(β) =", 238.4, 485.1, 42.8, 10), fragment("N", 287.7, 467.6, 10.7, 37.7),
            fragment("(yi−xT", 298.4, 478.0, 34.6, 18.9), fragment("i β)2", 328.4, 483.4, 20.3, 13.5),
            fragment(". (2.3)", 349.1, 485.1, 107.4, 10), fragment("i=1", 284.8, 474.1, 12.9, 7),
            fragment("RSS(β) is a quadratic function of the parameters, and hence its minimum", 133.8, 457.8, 322.8, 10),
            fragment("always exists, but may not be unique. The solution is easiest to characterize", 133.8, 445.9, 322.8, 10)
        ]
        let label = CGRect(x: 436.1, y: 485.1, width: 20.5, height: 10)
        let region = ReferenceLayout.equationRegion(label: label, fragments: fragments, page: page)
        XCTAssertEqual(region.minY, 467.6 - 1.5, accuracy: 0.01)
        XCTAssertEqual(region.maxY, 505.3 + 1.5, accuracy: 0.01)
        XCTAssertEqual(region.minX, 133.8 - 4, accuracy: 0.01)
        XCTAssertEqual(region.maxX, 456.6 + 4, accuracy: 0.1)
    }

    func testNumberOnlyLinksAreNamedFromTheWordsAroundThem() throws {
        // Lemma's sample book is typeset with hyperref, which links only “1.3” in “Theorem 1.3” and “2.1” in “(2.1)”.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Lemma/Resources/Sample/Least Squares in Twelve Pages.pdf")
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 5))
        let keys = PageReferenceAnalyzer.mentions(on: page, in: document).filter { $0.destination != nil }.map(\.key)
        XCTAssertTrue(keys.contains(ReferenceKey(kind: .theorem, number: "1.3", name: "Theorem")), "\(keys)")
        XCTAssertTrue(keys.contains(ReferenceKey(kind: .equation, number: "2.1")), "\(keys)")
        XCTAssertFalse(keys.contains { $0.kind == .link && ["1.3", "2.1"].contains($0.number) }, "\(keys)")
    }

    func testEquationRegionStopsAtAParagraphIndentedAsIn11PointLaTeX() {
        // Lemma's sample book, equation (2.4): an 11 pt book, whose paragraphs are indented by 17 pt, and a fraction
        // whose numerator PDFKit reports as a line of its own.
        let page = CGRect(x: 0, y: 0, width: 432, height: 648)
        let fragments = [
            fragment("Hy. Multiplying Xˆ", 54.0, 188.4, 104.8, 12.6),
            fragment("β= X(XT X)−1XT y on the left by XT gives", 151.8, 186.9, 226.2, 13.8),
            fragment("(2.2); conversely, (2.2) gives (2.3), and then Xˆ", 54.0, 174.9, 228.3, 12.6),
            fragment("β= Hy by (1.2).", 275.3, 174.9, 81.2, 10.9),
            fragment("The same equations come from calculus: the gradient of (2.1) is", 70.9, 152.4, 305.7, 10.9),
            fragment("∂ RSS", 155.7, 130.1, 28.4, 9.7),
            fragment("∂β", 163.3, 115.3, 12.5, 9.7),
            fragment("=−2XT (y− Xβ), (2.4)", 188.3, 114.4, 189.7, 20.5),
            fragment("and setting it to zero gives (2.2). The fitted values areˆ", 54.0, 90.7, 260.0, 10.9),
            fragment("y= Xˆ", 307.8, 90.7, 37.2, 12.6),
            fragment("β= Hy,", 338.0, 90.7, 40.0, 10.9)
        ]
        let region = ReferenceLayout.equationRegion(label: CGRect(x: 355.6, y: 114.4, width: 22.4, height: 20.5), fragments: fragments, page: page)
        XCTAssertEqual(region.maxY, 139.8 + 1.5, accuracy: 0.2, "The paragraph's indented first line above is not part of the display.")
        XCTAssertEqual(region.minY, 114.4 - 1.5, accuracy: 0.2)
    }

    func testEquationRegionStopsAtAJustifiedLineOfMathematicalProse() {
        // A line that fills the column from its left edge ends the display even without three words in a row.
        let page = CGRect(x: 0, y: 0, width: 432, height: 648)
        let fragments = [
            fragment("Since the columns are independent, write the projection with the matrix of the data", 54, 200, 324, 10.9),
            fragment("(2.2); conversely, (2.2) gives (2.3), and then Xβ = Hy by (1.2), where H = X(XTX)−1XT", 54, 186, 324, 10.9),
            fragment("H2 = H, (2.5)", 180, 166, 198, 10.9),
            fragment("and the fitted values are the projection of y onto the column space of the matrix.", 54, 146, 324, 10.9)
        ]
        let region = ReferenceLayout.equationRegion(label: CGRect(x: 356, y: 166, width: 22, height: 10.9), fragments: fragments, page: page)
        XCTAssertEqual(region.maxY, 176.9 + 1.5, accuracy: 0.2)
        XCTAssertEqual(region.minY, 166 - 1.5, accuracy: 0.2)
    }

    func testEquationRegionStopsAtTheJustifiedLineThatFollowsIt() {
        // The sample book's equation (3.5), in a proof: the paragraph goes on below it with one word of prose.
        let page = CGRect(x: 0, y: 0, width: 432, height: 648)
        let fragments = [
            fragment("Proof. Substitute (3.3) into (3.2). Since V T V= I and U T U= I,", 54.0, 515.4, 310.3, 11.6),
            fragment("XT X + λI= V D2V T + λV V T", 85.8, 493.2, 146.7, 12.2),
            fragment("= V (D2 + λI)V T", 237.2, 493.2, 81.9, 12.2),
            fragment(". (3.5)", 320.8, 493.2, 57.2, 10.9),
            fragment("Hence, by (3.5) and (3.2),ˆ", 54.0, 470.9, 132.2, 12.6),
            fragment("βλ = V (D2 + λI)−1V T V DU T y= V (D2 +", 179.2, 469.4, 198.8, 13.8),
            fragment("λI)−1DU T y. Then", 54.0, 455.9, 90.6, 13.8),
            fragment("Xˆ", 68.7, 435.2, 16.9, 12.6),
            fragment("βλ = U DV T V (D2 + λI)−1DU T y= U D(D2 + λI)−1D U T y,", 78.6, 433.9, 284.7, 14.0),
            fragment("and since the matrices in the middle are diagonal this is (3.4).", 54.0, 412.9, 297.3, 10.9)
        ]
        let region = ReferenceLayout.equationRegion(label: CGRect(x: 355.6, y: 493.2, width: 22.4, height: 10.9), fragments: fragments, page: page)
        XCTAssertEqual(region.minY, 493.2 - 1.5, accuracy: 0.2, "The paragraph that resumes below the display is not part of it.")
        XCTAssertEqual(region.maxY, 505.4 + 1.5, accuracy: 0.2)
    }

    func testFigureRegionClimbsToBodyTextAndIgnoresRotatedAxisLabels() {
        let page = CGRect(x: 72, y: 72, width: 450, height: 648)
        var fragments = [
            fragment("2.3 Least Squares and Nearest Neighbors 13", 336.9, 692.9, 119.7, 9),
            fragment("This paragraph sits above the figure and runs across the full column", 133.8, 640, 322.8, 10),
            fragment("so the figure should start just below this line of ordinary prose.", 133.8, 628, 322.8, 10),
            fragment("Coefficients", 136.8, 420.6, 7.9, 41.2),
            fragment("−0.2 0.0 0.2 0.4 0.6", 155.7, 329.4, 7.9, 221.3),
            fragment("lcavol lweight svi", 380, 560, 60, 8),
            fragment("FIGURE 3.8. Profiles of ridge coefficients for the prostate cancer example,", 133.8, 239.0, 322.8, 9),
            fragment("as the tuning parameter is varied. Coefficients are plotted versus df.", 133.8, 228.0, 322.8, 9),
            fragment("The next paragraph begins after a gap and is not part of the caption at all.", 133.8, 200, 322.8, 10)
        ]
        for step in 0..<20 { fragments.append(fragment("•", 240 + Double(step) * 8, 300 + Double(step) * 12, 2.7, 7.9)) }
        let region = ReferenceLayout.figureRegion(caption: CGRect(x: 133.8, y: 239, width: 59.5, height: 9), fragments: fragments, page: page)
        XCTAssertEqual(region.maxY, 628 - 3 + 1.5, accuracy: 0.01, "The figure extends up to the paragraph above, despite the rotated tick labels.")
        XCTAssertEqual(region.minY, 228 - 1.5, accuracy: 0.01, "Both caption lines are included; the following paragraph is not.")
    }

    func testTwoColumnPagesUseTheLabelsOwnColumn() {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        var fragments: [LayoutFragment] = []
        for row in 0..<12 {
            let y = 700 - Double(row) * 12
            fragments.append(fragment("Left column prose continues with several words in each line", 54, y, 240, 10))
            if row != 5 { fragments.append(fragment("Right column prose also has several words on each line here", 318, y, 240, 10)) }
        }
        fragments.append(fragment("y = Xβ + ε", 400, 640, 60, 10))
        fragments.append(fragment("(4)", 543, 640, 15, 10))
        let column = ReferenceLayout.column(containing: 550, near: 645, fragments: fragments, page: page)
        XCTAssertEqual(column.lowerBound, 318, accuracy: 0.01)
        XCTAssertEqual(column.upperBound, 558, accuracy: 0.01)
        let region = ReferenceLayout.equationRegion(label: CGRect(x: 543, y: 640, width: 15, height: 10), fragments: fragments, page: page)
        XCTAssertGreaterThanOrEqual(region.minX, 313)
        XCTAssertEqual(region.minY, 640 - 1.5, accuracy: 0.01)
        XCTAssertEqual(region.maxY, 650 + 1.5, accuracy: 0.01)
    }

    func testLinkedFootnoteUsesItsOwnColumn() throws {
        let fragments = [
            fragment("The main text of a wide inset box", 56, 161, 419, 11),
            fragment("11", 181, 140, 6, 9),
            fragment("The first line of the linked footnote", 195, 140, 335, 9),
            fragment("The continuation of the linked footnote", 195, 131, 340, 9),
            fragment("12", 181, 118, 6, 9),
            fragment("A different footnote on the same page", 195, 118, 320, 9)
        ]
        let note = try XCTUnwrap(ReferenceLayout.footnoteRegion(linkText: ".11", at: CGPoint(x: 179, y: 149), fragments: fragments,
                                                               page: CGRect(x: 0, y: 0, width: 595, height: 842)))
        XCTAssertEqual(note.anchor, fragments[1].bounds)
        XCTAssertTrue(note.region.contains(fragments[3].bounds))
        XCTAssertFalse(note.region.intersects(fragments[5].bounds))
    }

    func testOutlineChaptersSectionsAndCurrentPosition() {
        let items = [
            OutlineItem(title: "Preface", pageIndex: 3, level: 0),
            OutlineItem(title: "2 Overview of Supervised Learning", pageIndex: 27, level: 0),
            OutlineItem(title: "2.3 Two Simple Approaches", pageIndex: 29, level: 1),
            OutlineItem(title: "2.3.2 Nearest-Neighbor Methods", pageIndex: 32, level: 2, point: CGPoint(x: 133, y: 520)),
            OutlineItem(title: "3 Linear Methods for Regression", pageIndex: 61, level: 0),
            OutlineItem(title: "3.4.1Ridge Regression", pageIndex: 79, level: 2)
        ]
        XCTAssertEqual(OutlineMap.chapterRange(2, in: items, pageCount: 764), 27..<62)
        XCTAssertEqual(OutlineMap.chapterRange(3, in: items, pageCount: 764), 61..<764)
        XCTAssertNil(OutlineMap.chapterRange(9, in: items, pageCount: 764))
        XCTAssertEqual(OutlineMap.section("3.4.1", in: items)?.pageIndex, 79)
        XCTAssertEqual(OutlineMap.section(containing: 32, y: 600, in: items)?.title, "2.3 Two Simple Approaches", "A heading lower on the page has not started yet.")
        XCTAssertEqual(OutlineMap.section(containing: 32, y: 400, in: items)?.title, "2.3.2 Nearest-Neighbor Methods")
        XCTAssertEqual(OutlineMap.section(containing: 40, in: items)?.title, "2.3.2 Nearest-Neighbor Methods")
        XCTAssertNil(OutlineMap.section(containing: 1, in: items))
    }

    @MainActor
    func testPDFAnalysisFindsDefinitionsSeparatelyFromMentions() throws {
        let document = try XCTUnwrap(PDFDocument(data: try Self.bookPDF()))
        let first = try XCTUnwrap(document.page(at: 0)), second = try XCTUnwrap(document.page(at: 1)), third = try XCTUnwrap(document.page(at: 2))

        let equations = PageReferenceAnalyzer.definitions(on: first, pageIndex: 0)
        XCTAssertEqual(equations.map(\.key.spokenTitle), ["Equation (1.1)"], "Only the right-aligned label defines (1.1).")
        let equation = try XCTUnwrap(equations.first)
        XCTAssertTrue(equation.region.rect.contains(CGPoint(x: 250, y: 505)), "The display formula belongs to the region.")
        XCTAssertLessThan(equation.region.rect.maxY, 540, "Prose above the display is excluded.")
        XCTAssertGreaterThan(equation.region.rect.minY, 470, "Prose below the display is excluded.")
        let mentions = PageReferenceAnalyzer.mentions(on: first, in: document)
        XCTAssertEqual(mentions.map(\.key.spokenTitle).sorted(), ["Equation (1.1)", "Equation (1.1)", "Equation (1.1)", "Figure 1.1"],
                       "The label itself and the three citations; PDFKit's text order decides their sequence.")

        let figures = PageReferenceAnalyzer.definitions(on: second, pageIndex: 1)
        XCTAssertEqual(figures.map(\.key.spokenTitle), ["Figure 1.1"], "“Figure 1.1 shows” starts a sentence, not a caption.")
        XCTAssertGreaterThan(try XCTUnwrap(figures.first).region.rect.maxY, 600, "The drawing above the caption is part of the figure.")

        let exercises = PageReferenceAnalyzer.definitions(on: third, pageIndex: 2)
        XCTAssertEqual(exercises.map(\.key.spokenTitle), ["Exercise 1.2"], "A running head such as “Exercises 7” is not a definition.")
        XCTAssertFalse(PageReferenceAnalyzer.mentions(on: third, in: document).contains { $0.key.number == "7" })
    }

    @MainActor
    func testInternalPDFLinksBecomeExactMentions() throws {
        let document = try XCTUnwrap(PDFDocument(data: try Self.bookPDF()))
        let first = try XCTUnwrap(document.page(at: 0)), second = try XCTUnwrap(document.page(at: 1))
        let citation = try XCTUnwrap(PageReferenceAnalyzer.mentions(on: first, in: document).first { $0.key.kind == .figure })
        let link = PDFAnnotation(bounds: try XCTUnwrap(citation.rects.first).insetBy(dx: -1, dy: -1), forType: .link, withProperties: nil)
        link.destination = PDFDestination(page: second, at: CGPoint(x: 72, y: 650))
        first.addAnnotation(link)
        let external = PDFAnnotation(bounds: CGRect(x: 72, y: 560, width: 60, height: 14), forType: .link, withProperties: nil)
        external.url = URL(string: "https://hastie.su.domains")
        first.addAnnotation(external)
        let reloaded = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(document.dataRepresentation())))
        let page = try XCTUnwrap(reloaded.page(at: 0))
        let mentions = PageReferenceAnalyzer.mentions(on: page, in: reloaded)
        let linked = try XCTUnwrap(mentions.first { $0.destination != nil })
        XCTAssertEqual(linked.key, ReferenceKey(kind: .figure, number: "1.1"), "The link's own text names what it points to.")
        XCTAssertEqual(linked.destination?.pageIndex, 1)
        XCTAssertEqual(mentions.filter { $0.key.kind == .figure }.count, 1, "Text under a link is not reported twice.")
        XCTAssertEqual(mentions.filter { $0.destination != nil }.count, 1, "External web links stay with PDFKit.")
        let target = try XCTUnwrap(PageReferenceAnalyzer.target(for: try XCTUnwrap(linked.destination), key: linked.key, in: reloaded, origin: .link))
        XCTAssertEqual(target.origin, .link)
        XCTAssertEqual(target.pageIndex, 1)
        XCTAssertGreaterThan(target.region.rect.maxY, 600, "A matching caption on the destination page supplies the figure region.")
    }

    func testReferenceCacheRoundTripsAndRejectsOtherVersions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = DocumentIndexRepository(root: root)
        var cache = ReferenceCache()
        cache.scannedPages = [0, 4]
        cache.targets = [ReferenceTarget(key: ReferenceKey(kind: .figure, number: "2.1"), pageIndex: 4,
            anchor: PageRegion(x: 1, y: 2, width: 3, height: 4), region: PageRegion(x: 0, y: 0, width: 10, height: 10), origin: .text)]
        try repository.save(cache, id: "book")
        XCTAssertEqual(repository.referenceCache("book")?.targets, cache.targets)
        XCTAssertEqual(repository.referenceCache("book")?.scannedPages, [0, 4])
        cache.version = ReferenceCache.currentVersion + 1
        try repository.save(cache, id: "book")
        XCTAssertNil(repository.referenceCache("book"), "Changed heuristics invalidate an older analysis.")
    }

    private func fragment(_ text: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> LayoutFragment {
        LayoutFragment(text: text, bounds: CGRect(x: x, y: y, width: width, height: height))
    }

    /// Three pages: a numbered display with prose that cites it, a figure with its caption, and exercises under a running head.
    @MainActor
    static func bookPDF() throws -> Data {
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
            text("where the noise has mean zero. The model (1.1) is linear in its coefficients", 72, 450)
            text("and Figure 1.1 shows a fitted example; we return to (1.1) later on in this book.", 72, 434)
        }
        page {
            NSColor.darkGray.setStroke()
            let frame = NSBezierPath(rect: CGRect(x: 150, y: 420, width: 300, height: 220)); frame.lineWidth = 1; frame.stroke()
            text("o o o", 200, 560); text("o o", 300, 480)
            text("FIGURE 1.1. A fitted line through simulated data. The line is the least", 72, 390)
            text("squares fit of the response on a single input.", 72, 376)
            text("Figure 1.1 shows the fit; the residuals are small compared with the signal here.", 72, 330)
            text("We now turn to the question of uniqueness of the least squares solution.", 72, 314)
        }
        page {
            text("Exercises 7", 540, 770, right: true)
            text("Ex. 1.2 Show that the least squares estimate solves the normal equations,", 72, 600)
            text("and explain when the solution is unique.", 72, 584)
        }
        context.closePDF()
        return bytes as Data
    }
}
