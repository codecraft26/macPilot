import AppKit
import PDFKit
import XCTest
@testable import MacPilot

@MainActor
final class FileToolsTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacPilotToolsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeDocx(_ name: String, text: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let data = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                       documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        try data.write(to: url)
        return url
    }

    func testNamingAndPageRanges() {
        let input = URL(fileURLWithPath: "/tmp/Report.pdf")
        XCTAssertEqual(ConversionNaming.outputURL(for: input, extension: "docx", exists: { _ in false }).lastPathComponent, "Report.docx")
        var taken: Set<String> = ["Report.docx", "Report (2).docx"]
        let next = ConversionNaming.outputURL(for: input, extension: "docx", exists: { taken.contains($0.lastPathComponent) })
        XCTAssertEqual(next.lastPathComponent, "Report (3).docx")
        taken = []
        XCTAssertEqual(ConversionNaming.pageGroups("1-3, 5, 8-", pageCount: 9), [[1, 2, 3], [5], [8, 9]])
        XCTAssertEqual(ConversionNaming.pageGroups("", pageCount: 3), [[1], [2], [3]])
        XCTAssertEqual(ConversionNaming.pageGroups("7, 0, 99", pageCount: 5), [])
    }

    func testWordToPDFToWordRoundTrip() async throws {
        let docx = try makeDocx("Memo.docx", text: "Quarterly plan\nShip the clipboard manager and the notch.")
        let pdf = try FileConverter.documentToPDF(docx)
        XCTAssertEqual(pdf.url.pathExtension, "pdf")
        let document = try XCTUnwrap(PDFDocument(url: pdf.url))
        XCTAssertGreaterThanOrEqual(document.pageCount, 1)
        XCTAssertTrue(document.string?.contains("Quarterly plan") ?? false)

        let back = try await FileConverter.pdfToWord(pdf.url)
        XCTAssertEqual(back.url.lastPathComponent, "Memo (2).docx") // Memo.docx already exists
        let text = try NSAttributedString(url: back.url, options: [:], documentAttributes: nil).string
        XCTAssertTrue(text.contains("clipboard manager"))
    }

    func testMergeSplitCompressProtect() throws {
        let a = try FileConverter.documentToPDF(try makeDocx("A.docx", text: "First")).url
        let b = try FileConverter.documentToPDF(try makeDocx("B.docx", text: "Second")).url
        let merged = try FileConverter.mergePDFs([a, b])
        XCTAssertEqual(PDFDocument(url: merged.url)?.pageCount, 2)

        let parts = try FileConverter.splitPDF(merged.url, ranges: "")
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(PDFDocument(url: parts[1].url)?.string?.contains("Second") ?? false)

        XCTAssertTrue(FileManager.default.fileExists(atPath: try FileConverter.compressPDF(merged.url).url.path))

        let locked = try FileConverter.protectPDF(merged.url, password: "secret1")
        XCTAssertTrue(PDFDocument(url: locked.url)?.isLocked ?? false)
        XCTAssertThrowsError(try FileConverter.protectPDF(merged.url, password: "ab"))
    }

    func testDocumentFormatsAndMarkdown() throws {
        let docx = try makeDocx("Note.docx", text: "Hello formats")
        for format in [ConversionOptions.DocumentFormat.rtf, .html, .txt, .odt] {
            let result = try FileConverter.convertDocument(docx, to: format)
            XCTAssertEqual(result.url.pathExtension, format.fileExtension)
            XCTAssertTrue(try NSAttributedString(url: result.url, options: [:], documentAttributes: nil).string.contains("Hello formats"))
        }
        let md = folder.appendingPathComponent("Readme.md")
        try "# Title\n\nSome **bold** text and `code`.".write(to: md, atomically: true, encoding: .utf8)
        let word = try FileConverter.markdown(md, to: .docx)
        let text = try NSAttributedString(url: word.url, options: [:], documentAttributes: nil)
        XCTAssertTrue(text.string.contains("Title"))
        XCTAssertTrue(text.string.contains("bold"))
        XCTAssertFalse(text.string.contains("**"))
    }

    private func documentDocumentAttributes() -> AutoreleasingUnsafeMutablePointer<NSDictionary?>? { nil }

    func testImagesConvertResizeAndPDF() throws {
        let image = NSImage(size: NSSize(width: 400, height: 200))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 400, height: 200).fill()
        image.unlockFocus()
        let png = folder.appendingPathComponent("Shot.png")
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: png)

        let jpeg = try FileConverter.convertImage(png, format: .jpeg, quality: 0.8, maxPixels: 0)
        XCTAssertEqual(jpeg.url.pathExtension, "jpg")
        let resized = try FileConverter.convertImage(png, format: .png, quality: 1, maxPixels: 100)
        XCTAssertEqual(NSImage(contentsOf: resized.url).map { Int($0.representations.first?.pixelsWide ?? 0) }, 100)
        let pdf = try FileConverter.imagesToPDF([png, jpeg.url])
        XCTAssertEqual(PDFDocument(url: pdf.url)?.pageCount, 2)
        let pages = try FileConverter.pdfToImages(pdf.url, format: .png, quality: 1)
        XCTAssertEqual(pages.count, 2)
    }

    func testOCRReadsRenderedText() async throws {
        let pdf = try FileConverter.documentToPDF(try makeDocx("Scan.docx", text: "INVOICE 4821 TOTAL 99"))
        // Render page to an image so OCR has to read pixels.
        let page = try XCTUnwrap(PDFDocument(url: pdf.url)?.page(at: 0))
        let image = try XCTUnwrap(FileConverter.render(page, scale: 3))
        let text = try await FileConverter.recognizeText(in: image)
        XCTAssertTrue(text.contains("INVOICE"), text)
    }
}
