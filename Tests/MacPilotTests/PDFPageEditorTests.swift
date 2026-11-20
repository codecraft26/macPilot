import AppKit
import PDFKit
import XCTest
@testable import MacPilot

final class PDFPageEditorTests: XCTestCase {
    /// Three 300×200 pages that say "Page 1", "Page 2", "Page 3".
    private func makeDocument() -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        for number in 1...3 {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSAttributedString(string: "Page \(number)", attributes: [.font: NSFont.systemFont(ofSize: 20)]).draw(at: NSPoint(x: 20, y: 100))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return PDFDocument(data: data as Data)!
    }

    private func items(_ count: Int) -> [PDFPageItem] { (0..<count).map { PDFPageItem(sourceIndex: $0) } }

    func testReorderDeleteRotate() throws {
        var pages = items(3)
        pages = PDFPageEditor.move(pages, ids: [pages[2].id], before: pages[0].id)
        pages.removeAll { $0.sourceIndex == 1 }
        pages = PDFPageEditor.rotate(pages, ids: [pages[0].id], clockwise: true)
        let output = try PDFPageEditor.build(from: makeDocument(), pages: pages, stamp: PDFStamp())
        XCTAssertEqual(output.pageCount, 2)
        XCTAssertTrue(output.page(at: 0)?.string?.contains("Page 3") ?? false)
        XCTAssertEqual(output.page(at: 0)?.rotation, 90)
        XCTAssertTrue(output.page(at: 1)?.string?.contains("Page 1") ?? false)
    }

    func testStampKeepsTextAndAddsNumbers() throws {
        var pages = items(3)
        pages = PDFPageEditor.rotate(pages, ids: [pages[1].id], clockwise: false)
        let stamp = PDFStamp(pageNumbers: true, watermark: "DRAFT")
        let output = try PDFPageEditor.build(from: makeDocument(), pages: pages, stamp: stamp)
        XCTAssertEqual(output.pageCount, 3)
        let text = output.page(at: 2)?.string ?? ""
        XCTAssertTrue(text.contains("Page 3"), text)
        XCTAssertTrue(text.contains("3 / 3"), text)
        XCTAssertTrue(text.contains("DRAFT"), text)
        // The left-turned page is now portrait.
        let rotatedBox = output.page(at: 1)!.bounds(for: .mediaBox)
        XCTAssertEqual(rotatedBox.width, 200, accuracy: 0.5)
        XCTAssertEqual(rotatedBox.height, 300, accuracy: 0.5)
    }

    func testShiftAndLabels() {
        let pages = items(4)
        let shifted = PDFPageEditor.shift(pages, ids: [pages[0].id, pages[1].id], by: 1)
        XCTAssertEqual(shifted.map(\.sourceIndex), [2, 0, 1, 3])
        XCTAssertEqual(PDFPageEditor.shift(pages, ids: [pages[0].id], by: -1).map(\.sourceIndex), [0, 1, 2, 3])
        XCTAssertEqual(PDFStamp(numberFormat: "Page {n}", firstNumber: 5).label(forPage: 1, total: 3), "Page 6")
        XCTAssertThrowsError(try PDFPageEditor.build(from: makeDocument(), pages: [], stamp: PDFStamp()))
    }
}

extension PDFPageEditorTests {
    /// Writes PNGs of stamped pages for a visual check when SNAPSHOT_DIR is set.
    func testStampSnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] else { throw XCTSkip("SNAPSHOT_DIR not set") }
        var pages = (0..<3).map { PDFPageItem(sourceIndex: $0) }
        pages = PDFPageEditor.rotate(pages, ids: [pages[1].id], clockwise: true)
        let output = try PDFPageEditor.build(from: makeDocumentForSnapshot(), pages: pages,
                                             stamp: PDFStamp(pageNumbers: true, numberPosition: .bottomRight, watermark: "CONFIDENTIAL", watermarkOpacity: 0.3))
        for index in 0..<output.pageCount {
            let image = output.page(at: index)!.thumbnail(of: NSSize(width: 600, height: 600), for: .mediaBox)
            let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("pdf-page-\(index + 1).png"))
        }
    }

    private func makeDocumentForSnapshot() -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        for number in 1...3 {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(box)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSAttributedString(string: "Page \(number) — top left", attributes: [.font: NSFont.systemFont(ofSize: 18)]).draw(at: NSPoint(x: 12, y: 170))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return PDFDocument(data: data as Data)!
    }
}
