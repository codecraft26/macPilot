import AppKit
import XCTest
@testable import MacPilot

final class ConvertPickerTests: XCTestCase {
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    func testSinglePDF() {
        let tools = ConversionTool.matching([url("Report.pdf")])
        XCTAssertTrue(tools.contains(.pdfToWord))
        XCTAssertTrue(tools.contains(.compressPDF))
        XCTAssertTrue(tools.contains(.ocrToText))
        XCTAssertFalse(tools.contains(.mergePDF), "merging needs two or more PDFs")
        XCTAssertFalse(tools.contains(.convertImages))
    }

    func testSeveralPDFsCanMerge() {
        let tools = ConversionTool.matching([url("a.pdf"), url("b.PDF")])
        XCTAssertTrue(tools.contains(.mergePDF))
        XCTAssertTrue(tools.contains(.splitPDF), "per-file tools work on many files")
    }

    func testImages() {
        let tools = ConversionTool.matching([url("IMG_1.HEIC"), url("photo.jpg"), url("scan.png")])
        XCTAssertEqual(Set(tools), [.imagesToPDF, .convertImages, .resizeImages, .ocrToText])
    }

    func testMixedSelectionOnlySharedTools() {
        XCTAssertEqual(ConversionTool.matching([url("scan.png"), url("doc.pdf")]), [.ocrToText])
        XCTAssertTrue(ConversionTool.matching([url("movie.mov"), url("doc.pdf")]).isEmpty)
    }

    func testDocumentsAndMarkdown() {
        let word = ConversionTool.matching([url("Letter.docx")])
        XCTAssertTrue(word.contains(.wordToPDF))
        XCTAssertTrue(word.contains(.documentConvert))
        XCTAssertFalse(word.contains(.markdownExport))
        let markdown = ConversionTool.matching([url("README.md")])
        XCTAssertEqual(markdown, [.markdownExport], "Markdown gets its own export, not the plain-text tools")
        let text = ConversionTool.matching([url("notes.txt")])
        XCTAssertTrue(text.contains(.wordToPDF))
        XCTAssertFalse(text.contains(.markdownExport))
    }

    func testMedia() {
        XCTAssertEqual(Set(ConversionTool.matching([url("clip.mov")])), [.videoToMP4, .extractAudio])
    }

    func testUnsupported() {
        XCTAssertTrue(ConversionTool.matching([url("archive.zip")]).isEmpty)
        XCTAssertTrue(ConversionTool.matching([url("noextension")]).isEmpty)
        XCTAssertTrue(ConversionTool.matching([]).isEmpty)
        XCTAssertTrue(ConversionTool.matching([URL(string: "https://example.com/a.pdf")!]).isEmpty, "only files")
    }

    func testServicePasteboardReadsFileURLs() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("macpilot.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([url("a.pdf") as NSURL, url("b.png") as NSURL])
        XCTAssertEqual(FinderServiceProvider.fileURLs(from: pasteboard).map(\.lastPathComponent), ["a.pdf", "b.png"])

        pasteboard.clearContents()
        pasteboard.setPropertyList(["/tmp/legacy.pdf"], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        XCTAssertEqual(FinderServiceProvider.fileURLs(from: pasteboard).map(\.path), ["/tmp/legacy.pdf"])
        pasteboard.releaseGlobally()
    }

    @MainActor
    func testInfoPlistDeclaresFinderService() throws {
        let plistURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: plistURL) as? [String: Any])
        let services = try XCTUnwrap(plist["NSServices"] as? [[String: Any]])
        let service = try XCTUnwrap(services.first)
        XCTAssertEqual(service["NSMessage"] as? String, "convertWithMacPilot")
        XCTAssertEqual((service["NSMenuItem"] as? [String: String])?["default"], "Convert with MacPilot")
        XCTAssertNotNil(service["NSRequiredContext"])
        XCTAssertTrue((service["NSSendTypes"] as? [String] ?? []).contains("public.file-url"))
        XCTAssertTrue(FinderServiceProvider.shared.responds(to: NSSelectorFromString("convertWithMacPilot:userData:error:")))
    }
}
