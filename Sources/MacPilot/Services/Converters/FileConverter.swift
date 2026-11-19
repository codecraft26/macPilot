import AppKit
import AVFoundation
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@preconcurrency import Vision

/// Everything in File Tools runs on this Mac; nothing is uploaded.
enum ConversionTool: String, CaseIterable, Identifiable {
    case pdfToWord, wordToPDF, documentConvert, markdownExport
    case mergePDF, splitPDF, compressPDF, protectPDF, pdfToImages
    case imagesToPDF, convertImages, resizeImages, ocrToText
    case videoToMP4, extractAudio

    var id: String { rawValue }

    enum Category: String, CaseIterable {
        case pdf = "PDF", documents = "Documents", images = "Images", media = "Audio & Video"
    }

    var category: Category {
        switch self {
        case .pdfToWord, .mergePDF, .splitPDF, .compressPDF, .protectPDF, .pdfToImages: return .pdf
        case .wordToPDF, .documentConvert, .markdownExport: return .documents
        case .imagesToPDF, .convertImages, .resizeImages, .ocrToText: return .images
        case .videoToMP4, .extractAudio: return .media
        }
    }

    var title: String {
        switch self {
        case .pdfToWord: return "PDF to Word"
        case .wordToPDF: return "Word to PDF"
        case .documentConvert: return "Convert document"
        case .markdownExport: return "Markdown to Word / PDF"
        case .mergePDF: return "Merge PDFs"
        case .splitPDF: return "Split PDF"
        case .compressPDF: return "Compress PDF"
        case .protectPDF: return "Password-protect PDF"
        case .pdfToImages: return "PDF to images"
        case .imagesToPDF: return "Images to PDF"
        case .convertImages: return "Convert images"
        case .resizeImages: return "Resize images"
        case .ocrToText: return "Extract text (OCR)"
        case .videoToMP4: return "Video to MP4"
        case .extractAudio: return "Extract audio"
        }
    }

    var subtitle: String {
        switch self {
        case .pdfToWord: return "Editable .docx; scanned pages are read with OCR"
        case .wordToPDF: return "DOCX, DOC, RTF, ODT, HTML or TXT to PDF"
        case .documentConvert: return "Between DOCX, RTF, HTML, ODT and plain text"
        case .markdownExport: return ".md to a formatted .docx or PDF"
        case .mergePDF: return "Combine several PDFs in the order you choose"
        case .splitPDF: return "Every page, or ranges like 1-3, 5"
        case .compressPDF: return "Smaller files for email and sharing"
        case .protectPDF: return "Require a password to open"
        case .pdfToImages: return "Each page as PNG or JPEG"
        case .imagesToPDF: return "Photos and scans into one PDF"
        case .convertImages: return "HEIC, JPEG, PNG, TIFF, GIF, BMP"
        case .resizeImages: return "Fit within a size, keep the aspect ratio"
        case .ocrToText: return "Text from images and scanned PDFs"
        case .videoToMP4: return "MOV and others to MP4, 720p / 1080p / original"
        case .extractAudio: return "Soundtrack as M4A"
        }
    }

    var systemImage: String {
        switch self {
        case .pdfToWord: return "doc.richtext"
        case .wordToPDF: return "doc.text"
        case .documentConvert: return "arrow.triangle.2.circlepath.doc.on.clipboard"
        case .markdownExport: return "number"
        case .mergePDF: return "rectangle.stack.badge.plus"
        case .splitPDF: return "scissors"
        case .compressPDF: return "arrow.down.right.and.arrow.up.left"
        case .protectPDF: return "lock.doc"
        case .pdfToImages: return "photo.on.rectangle"
        case .imagesToPDF: return "doc.on.doc"
        case .convertImages: return "photo"
        case .resizeImages: return "arrow.up.left.and.down.right.magnifyingglass"
        case .ocrToText: return "text.viewfinder"
        case .videoToMP4: return "film"
        case .extractAudio: return "waveform"
        }
    }

    var inputTypes: [UTType] {
        switch self {
        case .pdfToWord, .mergePDF, .splitPDF, .compressPDF, .protectPDF, .pdfToImages: return [.pdf]
        case .wordToPDF, .documentConvert:
            return [UTType(filenameExtension: "docx"), UTType(filenameExtension: "doc"), .rtf, .html, .plainText,
                    UTType(filenameExtension: "odt"), .rtfd].compactMap { $0 }
        case .markdownExport: return [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown"), .plainText].compactMap { $0 }
        case .imagesToPDF, .convertImages, .resizeImages: return [.image]
        case .ocrToText: return [.image, .pdf]
        case .videoToMP4, .extractAudio: return [.movie, .video, .audiovisualContent]
        }
    }

    /// Tools that take several files and make one output.
    var combinesInputs: Bool { self == .mergePDF || self == .imagesToPDF }
}

/// Options shown for each tool.
struct ConversionOptions: Equatable {
    enum ImageFormat: String, CaseIterable, Identifiable {
        case jpeg = "JPEG", png = "PNG", heic = "HEIC", tiff = "TIFF"
        var id: String { rawValue }
        var type: UTType {
            switch self {
            case .jpeg: return .jpeg
            case .png: return .png
            case .heic: return .heic
            case .tiff: return .tiff
            }
        }
        var fileExtension: String { self == .jpeg ? "jpg" : rawValue.lowercased() }
    }

    enum DocumentFormat: String, CaseIterable, Identifiable {
        case docx = "Word (.docx)", pdf = "PDF", rtf = "Rich Text (.rtf)", html = "Web page (.html)", odt = "OpenDocument (.odt)", txt = "Plain text (.txt)"
        var id: String { rawValue }
        var fileExtension: String {
            switch self {
            case .docx: return "docx"
            case .pdf: return "pdf"
            case .rtf: return "rtf"
            case .html: return "html"
            case .odt: return "odt"
            case .txt: return "txt"
            }
        }
    }

    enum VideoQuality: String, CaseIterable, Identifiable {
        case p720 = "720p", p1080 = "1080p", original = "Original"
        var id: String { rawValue }
        var preset: String {
            switch self {
            case .p720: return AVAssetExportPreset1280x720
            case .p1080: return AVAssetExportPreset1920x1080
            case .original: return AVAssetExportPresetHighestQuality
            }
        }
    }

    var imageFormat: ImageFormat = .jpeg
    var quality: Double = 0.85
    var maxPixels: Int = 1920
    var pageRanges = ""
    var password = ""
    var documentFormat: DocumentFormat = .docx
    var videoQuality: VideoQuality = .p1080
}

struct ConversionResult: Identifiable, Equatable {
    var id = UUID()
    var url: URL
    var note: String
}

enum ConversionError: LocalizedError {
    case unreadable(String)
    case nothingToDo(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "Couldn't open \(name)."
        case .nothingToDo(let reason): return reason
        case .failed(let reason): return reason
        }
    }
}

// MARK: - Helpers (pure)

enum ConversionNaming {
    /// "Report.pdf" → "Report.docx" next to it, or "Report (2).docx" if that exists.
    static func outputURL(for input: URL, extension ext: String, suffix: String = "", in folder: URL? = nil,
                          exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let directory = folder ?? input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent + suffix
        var candidate = directory.appendingPathComponent(base).appendingPathExtension(ext)
        var counter = 2
        while exists(candidate) {
            candidate = directory.appendingPathComponent("\(base) (\(counter))").appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }

    /// "1-3, 5, 8-" → [[1,2,3],[5],[8…last]]; empty → one group per page.
    static func pageGroups(_ text: String, pageCount: Int) -> [[Int]] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return (1...max(1, pageCount)).map { [$0] } }
        var groups: [[Int]] = []
        for part in trimmed.split(separator: ",") {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if bounds.count == 1, let page = Int(bounds[0]), (1...pageCount).contains(page) {
                groups.append([page])
            } else if bounds.count == 2 {
                let start = Int(bounds[0]) ?? 1
                let end = bounds[1].isEmpty ? pageCount : (Int(bounds[1]) ?? pageCount)
                let low = max(1, min(start, end)), high = min(pageCount, max(start, end))
                if low <= high { groups.append(Array(low...high)) }
            }
        }
        return groups
    }

    static func sizeString(_ url: URL) -> String {
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Engine

@MainActor
enum FileConverter {
    static func run(_ tool: ConversionTool, inputs: [URL], options: ConversionOptions,
                    progress: @escaping (Double) -> Void) async throws -> [ConversionResult] {
        guard !inputs.isEmpty else { throw ConversionError.nothingToDo("Add at least one file.") }
        if tool.combinesInputs {
            progress(0.1)
            let result = tool == .mergePDF ? try mergePDFs(inputs) : try imagesToPDF(inputs)
            progress(1)
            return [result]
        }
        var results: [ConversionResult] = []
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            results += try await convert(tool, input: input, options: options)
            progress(Double(index + 1) / Double(inputs.count))
        }
        return results
    }

    private static func convert(_ tool: ConversionTool, input: URL, options: ConversionOptions) async throws -> [ConversionResult] {
        switch tool {
        case .pdfToWord: return [try await pdfToWord(input)]
        case .wordToPDF: return [try documentToPDF(input)]
        case .documentConvert: return [try convertDocument(input, to: options.documentFormat)]
        case .markdownExport: return [try markdown(input, to: options.documentFormat == .pdf ? .pdf : .docx)]
        case .splitPDF: return try splitPDF(input, ranges: options.pageRanges)
        case .compressPDF: return [try compressPDF(input)]
        case .protectPDF: return [try protectPDF(input, password: options.password)]
        case .pdfToImages: return try pdfToImages(input, format: options.imageFormat == .png ? .png : .jpeg, quality: options.quality)
        case .convertImages: return [try convertImage(input, format: options.imageFormat, quality: options.quality, maxPixels: 0)]
        case .resizeImages: return [try convertImage(input, format: options.imageFormat, quality: options.quality, maxPixels: options.maxPixels)]
        case .ocrToText: return [try await ocr(input)]
        case .videoToMP4: return [try await exportMedia(input, preset: options.videoQuality.preset, type: .mp4, ext: "mp4")]
        case .extractAudio: return [try await exportMedia(input, preset: AVAssetExportPresetAppleM4A, type: .m4a, ext: "m4a")]
        case .mergePDF, .imagesToPDF: return []
        }
    }

    // MARK: PDF

    private static func openPDF(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw ConversionError.unreadable(url.lastPathComponent) }
        if document.isLocked { throw ConversionError.failed("\(url.lastPathComponent) is password-protected. Unlock it first.") }
        return document
    }

    static func pdfToWord(_ input: URL) async throws -> ConversionResult {
        let document = try openPDF(input)
        let output = NSMutableAttributedString()
        var ocrPages = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            if let text = page.attributedString, !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output.append(text)
            } else if let image = render(page, scale: 2) {
                // Scanned page: read it with OCR.
                let text = try await recognizeText(in: image)
                output.append(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)]))
                ocrPages += 1
            }
            if index < document.pageCount - 1 { output.append(NSAttributedString(string: "\u{0C}")) } // page break
        }
        guard !output.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionError.nothingToDo("No text found in \(input.lastPathComponent).")
        }
        let url = ConversionNaming.outputURL(for: input, extension: "docx")
        let data = try output.data(from: NSRange(location: 0, length: output.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        try data.write(to: url, options: .atomic)
        let note = "\(document.pageCount) page\(document.pageCount == 1 ? "" : "s")" + (ocrPages > 0 ? ", \(ocrPages) read with OCR" : "")
        return ConversionResult(url: url, note: note)
    }

    static func mergePDFs(_ inputs: [URL]) throws -> ConversionResult {
        let merged = PDFDocument()
        for input in inputs {
            let document = try openPDF(input)
            for index in 0..<document.pageCount {
                if let page = document.page(at: index) { merged.insert(page, at: merged.pageCount) }
            }
        }
        let url = ConversionNaming.outputURL(for: inputs[0], extension: "pdf", suffix: " merged")
        guard merged.write(to: url) else { throw ConversionError.failed("Couldn't save the merged PDF.") }
        return ConversionResult(url: url, note: "\(merged.pageCount) pages from \(inputs.count) files")
    }

    static func splitPDF(_ input: URL, ranges: String) throws -> [ConversionResult] {
        let document = try openPDF(input)
        let groups = ConversionNaming.pageGroups(ranges, pageCount: document.pageCount)
        guard !groups.isEmpty else { throw ConversionError.nothingToDo("No valid pages in “\(ranges)”. Use for example 1-3, 5.") }
        return try groups.map { pages in
            let part = PDFDocument()
            for number in pages { if let page = document.page(at: number - 1) { part.insert(page, at: part.pageCount) } }
            let label = pages.count == 1 ? " p\(pages[0])" : " p\(pages.first!)-\(pages.last!)"
            let url = ConversionNaming.outputURL(for: input, extension: "pdf", suffix: label)
            guard part.write(to: url) else { throw ConversionError.failed("Couldn't save \(url.lastPathComponent).") }
            return ConversionResult(url: url, note: "\(pages.count) page\(pages.count == 1 ? "" : "s")")
        }
    }

    static func compressPDF(_ input: URL) throws -> ConversionResult {
        let document = try openPDF(input)
        let url = ConversionNaming.outputURL(for: input, extension: "pdf", suffix: " compressed")
        let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
        guard document.write(to: url, withOptions: options) else { throw ConversionError.failed("Couldn't save the compressed PDF.") }
        return ConversionResult(url: url, note: "\(ConversionNaming.sizeString(input)) → \(ConversionNaming.sizeString(url))")
    }

    static func protectPDF(_ input: URL, password: String) throws -> ConversionResult {
        guard password.count >= 4 else { throw ConversionError.nothingToDo("Enter a password of at least 4 characters.") }
        let document = try openPDF(input)
        let url = ConversionNaming.outputURL(for: input, extension: "pdf", suffix: " protected")
        let options: [PDFDocumentWriteOption: Any] = [.userPasswordOption: password, .ownerPasswordOption: password]
        guard document.write(to: url, withOptions: options) else { throw ConversionError.failed("Couldn't save the protected PDF.") }
        return ConversionResult(url: url, note: "Opens only with the password")
    }

    static func pdfToImages(_ input: URL, format: ConversionOptions.ImageFormat, quality: Double) throws -> [ConversionResult] {
        let document = try openPDF(input)
        let folder = input.deletingLastPathComponent().appendingPathComponent(input.deletingPathExtension().lastPathComponent + " pages")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var results: [ConversionResult] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let image = render(page, scale: 2) else { continue }
            let url = ConversionNaming.outputURL(for: folder.appendingPathComponent("Page \(index + 1)"), extension: format.fileExtension, in: folder)
            try write(image, to: url, format: format, quality: quality)
            results.append(ConversionResult(url: url, note: "\(image.width)×\(image.height)"))
        }
        return results
    }

    static func render(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    // MARK: Documents

    private static func readDocument(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        if ext == "md" || ext == "markdown" { return try markdownAttributed(String(contentsOf: url, encoding: .utf8)) }
        do {
            return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        } catch {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
    }

    static func markdownAttributed(_ markdown: String) throws -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        let parsed = try AttributedString(markdown: markdown, options: options)
        // Turn Markdown structure (headings, lists, code) into fonts Word and PDF understand.
        let output = NSMutableAttributedString()
        for run in parsed.runs {
            var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
            let text = String(parsed[run.range].characters)
            if let intent = run.presentationIntent {
                for component in intent.components {
                    switch component.kind {
                    case .header(let level): attributes[.font] = NSFont.boldSystemFont(ofSize: [24, 20, 16, 14, 13, 12][min(5, level - 1)])
                    case .codeBlock: attributes[.font] = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
                    default: break
                    }
                }
            }
            if let inline = run.inlinePresentationIntent {
                let base = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 12)
                if inline.contains(.code) { attributes[.font] = NSFont.monospacedSystemFont(ofSize: base.pointSize - 1, weight: .regular) }
                var traits: NSFontDescriptor.SymbolicTraits = []
                if inline.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if inline.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty, let font = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: base.pointSize) {
                    attributes[.font] = font
                }
            }
            if let link = run.link { attributes[.link] = link }
            output.append(NSAttributedString(string: text, attributes: attributes))
            // Paragraph breaks between blocks.
            if run.presentationIntent != nil, run.range.upperBound < parsed.endIndex,
               parsed.runs[run.range.upperBound].presentationIntent != run.presentationIntent {
                output.append(NSAttributedString(string: "\n\n"))
            }
        }
        return output
    }

    static func documentToPDF(_ input: URL) throws -> ConversionResult {
        let text = try readDocument(input)
        let url = ConversionNaming.outputURL(for: input, extension: "pdf")
        try writePDF(text, to: url)
        let pages = PDFDocument(url: url)?.pageCount ?? 0
        return ConversionResult(url: url, note: "\(pages) page\(pages == 1 ? "" : "s")")
    }

    static func convertDocument(_ input: URL, to format: ConversionOptions.DocumentFormat) throws -> ConversionResult {
        if format == .pdf { return try documentToPDF(input) }
        let text = try readDocument(input)
        let url = ConversionNaming.outputURL(for: input, extension: format.fileExtension)
        try writeDocument(text, to: url, format: format)
        return ConversionResult(url: url, note: format.rawValue)
    }

    static func markdown(_ input: URL, to format: ConversionOptions.DocumentFormat) throws -> ConversionResult {
        let text = try readDocument(input)
        let url = ConversionNaming.outputURL(for: input, extension: format.fileExtension)
        if format == .pdf { try writePDF(text, to: url) } else { try writeDocument(text, to: url, format: format) }
        return ConversionResult(url: url, note: format.rawValue)
    }

    static func writeDocument(_ text: NSAttributedString, to url: URL, format: ConversionOptions.DocumentFormat) throws {
        let range = NSRange(location: 0, length: text.length)
        let data: Data
        switch format {
        case .txt: data = Data(text.string.utf8)
        case .docx: data = try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        case .rtf: data = try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        case .html: data = try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
        case .odt: data = try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.openDocument])
        case .pdf: try writePDF(text, to: url); return
        }
        try data.write(to: url, options: .atomic)
    }

    /// Lays text out on A4 pages with 2 cm margins.
    static func writePDF(_ text: NSAttributedString, to url: URL) throws {
        let paper = CGSize(width: 595, height: 842)
        let margin: CGFloat = 56
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var mediaBox = CGRect(origin: .zero, size: paper)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw ConversionError.failed("Couldn't create the PDF.") }
        var pages = 0
        while true {
            let container = NSTextContainer(size: CGSize(width: paper.width - margin * 2, height: paper.height - margin * 2))
            layout.addTextContainer(container)
            let glyphs = layout.glyphRange(for: container)
            if glyphs.length == 0 && pages > 0 { break }
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            context.translateBy(x: 0, y: paper.height)
            context.scaleBy(x: 1, y: -1)
            layout.drawBackground(forGlyphRange: glyphs, at: CGPoint(x: margin, y: margin))
            layout.drawGlyphs(forGlyphRange: glyphs, at: CGPoint(x: margin, y: margin))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
            pages += 1
            if NSMaxRange(glyphs) >= layout.numberOfGlyphs || pages > 2000 { break }
        }
        context.closePDF()
    }

    // MARK: Images

    static func imagesToPDF(_ inputs: [URL]) throws -> ConversionResult {
        let document = PDFDocument()
        for input in inputs {
            guard let image = NSImage(contentsOf: input), let page = PDFPage(image: image) else {
                throw ConversionError.unreadable(input.lastPathComponent)
            }
            document.insert(page, at: document.pageCount)
        }
        let url = ConversionNaming.outputURL(for: inputs[0], extension: "pdf", suffix: inputs.count > 1 ? " and \(inputs.count - 1) more" : "")
        guard document.write(to: url) else { throw ConversionError.failed("Couldn't save the PDF.") }
        return ConversionResult(url: url, note: "\(document.pageCount) page\(document.pageCount == 1 ? "" : "s")")
    }

    static func convertImage(_ input: URL, format: ConversionOptions.ImageFormat, quality: Double, maxPixels: Int) throws -> ConversionResult {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else { throw ConversionError.unreadable(input.lastPathComponent) }
        var options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true]
        if maxPixels > 0 {
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPixels
        } else if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let w = properties[kCGImagePropertyPixelWidth] as? Int ?? 0, h = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            options[kCGImageSourceThumbnailMaxPixelSize] = max(w, h)
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ConversionError.unreadable(input.lastPathComponent)
        }
        let suffix = maxPixels > 0 ? " \(image.width)x\(image.height)" : ""
        let url = ConversionNaming.outputURL(for: input, extension: format.fileExtension, suffix: suffix)
        try write(image, to: url, format: format, quality: quality)
        return ConversionResult(url: url, note: "\(image.width)×\(image.height) · \(ConversionNaming.sizeString(url))")
    }

    static func write(_ image: CGImage, to url: URL, format: ConversionOptions.ImageFormat, quality: Double) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw ConversionError.failed("\(format.rawValue) isn't supported on this Mac.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.failed("Couldn't save \(url.lastPathComponent).") }
    }

    // MARK: OCR

    static func ocr(_ input: URL) async throws -> ConversionResult {
        var pages: [String] = []
        if input.pathExtension.lowercased() == "pdf" {
            let document = try openPDF(input)
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index), let image = render(page, scale: 2) else { continue }
                pages.append(try await recognizeText(in: image))
            }
        } else {
            guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ConversionError.unreadable(input.lastPathComponent) }
            pages.append(try await recognizeText(in: image))
        }
        let text = pages.joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConversionError.nothingToDo("No text found in \(input.lastPathComponent).") }
        let url = ConversionNaming.outputURL(for: input, extension: "txt")
        try Data(text.utf8).write(to: url, options: .atomic)
        return ConversionResult(url: url, note: "\(text.split(whereSeparator: \.isWhitespace).count) words")
    }

    static func recognizeText(in image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let lines = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try VNImageRequestHandler(cgImage: image).perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Media

    static func exportMedia(_ input: URL, preset: String, type: AVFileType, ext: String) async throws -> ConversionResult {
        let asset = AVURLAsset(url: input)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError.failed("\(input.lastPathComponent) can't be converted with this setting.")
        }
        let url = ConversionNaming.outputURL(for: input, extension: ext, suffix: ext == "mp4" && input.pathExtension.lowercased() == "mp4" ? " converted" : "")
        if #available(macOS 15, *) {
            try await session.export(to: url, as: type)
        } else {
            session.outputURL = url
            session.outputFileType = type
            await session.export()
            if session.status != .completed { throw session.error ?? ConversionError.failed("Export failed.") }
        }
        return ConversionResult(url: url, note: "\(ConversionNaming.sizeString(input)) → \(ConversionNaming.sizeString(url))")
    }
}
