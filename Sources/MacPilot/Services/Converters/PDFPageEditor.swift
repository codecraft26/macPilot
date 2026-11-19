import AppKit
import Foundation
import PDFKit

/// One page in the editor: which page of the original it is and how much it was turned.
struct PDFPageItem: Identifiable, Hashable {
    var id = UUID()
    var sourceIndex: Int
    /// Extra clockwise rotation in degrees (multiple of 90).
    var rotation = 0
}

/// Page numbers and a text watermark stamped onto every page.
struct PDFStamp: Equatable {
    enum NumberPosition: String, CaseIterable, Identifiable {
        case bottomCenter = "Bottom center", bottomRight = "Bottom right", topRight = "Top right"
        var id: String { rawValue }
    }

    var pageNumbers = false
    var numberPosition: NumberPosition = .bottomCenter
    var numberFormat = "{n} / {total}"
    var firstNumber = 1
    var watermark = ""
    var watermarkOpacity = 0.15

    var isEmpty: Bool { !pageNumbers && watermark.trimmingCharacters(in: .whitespaces).isEmpty }

    func label(forPage index: Int, total: Int) -> String {
        numberFormat
            .replacingOccurrences(of: "{n}", with: String(firstNumber + index))
            .replacingOccurrences(of: "{total}", with: String(firstNumber + total - 1))
    }
}

/// Builds a new PDF from the edited page list: reordered, rotated, deleted, stamped.
enum PDFPageEditor {
    static func normalized(_ degrees: Int) -> Int { ((degrees % 360) + 360) % 360 }

    /// Turns the chosen pages; `clockwise` false turns left.
    static func rotate(_ pages: [PDFPageItem], ids: Set<UUID>, clockwise: Bool) -> [PDFPageItem] {
        pages.map { page in
            guard ids.contains(page.id) else { return page }
            var turned = page
            turned.rotation = normalized(page.rotation + (clockwise ? 90 : -90))
            return turned
        }
    }

    /// Moves the chosen pages one step earlier (-1) or later (+1), keeping their order.
    static func shift(_ pages: [PDFPageItem], ids: Set<UUID>, by offset: Int) -> [PDFPageItem] {
        var result = pages
        let indices = result.indices.filter { ids.contains(result[$0].id) }
        let ordered = offset < 0 ? indices : indices.reversed()
        for index in ordered {
            let target = index + offset
            guard result.indices.contains(target), !ids.contains(result[target].id) else { continue }
            result.swapAt(index, target)
        }
        return result
    }

    /// Moves `dragged` pages to sit before the page with id `before` (or to the end when nil).
    static func move(_ pages: [PDFPageItem], ids: [UUID], before target: UUID?) -> [PDFPageItem] {
        let moving = pages.filter { ids.contains($0.id) }
        guard !moving.isEmpty, !(target.map(ids.contains) ?? false) else { return pages }
        var rest = pages.filter { !ids.contains($0.id) }
        let insertAt = target.flatMap { id in rest.firstIndex { $0.id == id } } ?? rest.endIndex
        rest.insert(contentsOf: moving, at: insertAt)
        return rest
    }

    static func build(from source: PDFDocument, pages: [PDFPageItem], stamp: PDFStamp) throws -> PDFDocument {
        guard !pages.isEmpty else { throw ConversionError.nothingToDo("Keep at least one page.") }
        guard !source.isLocked else { throw ConversionError.nothingToDo("This PDF is password protected. Unlock it in Preview first.") }
        let output = PDFDocument()
        for item in pages {
            guard let original = source.page(at: item.sourceIndex), let page = original.copy() as? PDFPage else { continue }
            page.rotation = normalized(original.rotation + item.rotation)
            output.insert(page, at: output.pageCount)
        }
        guard !stamp.isEmpty else { return output }
        return try stamped(output, stamp: stamp)
    }

    /// Redraws every page with the stamp on top. Page content stays vector (text remains selectable).
    static func stamped(_ document: PDFDocument, stamp: PDFStamp) throws -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw ConversionError.failed("Couldn't create the PDF.")
        }
        let total = document.pageCount
        for index in 0..<total {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let quarter = page.rotation % 180 != 0
            var box = CGRect(x: 0, y: 0, width: quarter ? bounds.height : bounds.width, height: quarter ? bounds.width : bounds.height)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            context.beginPDFPage(info)
            context.saveGState()
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            drawStamp(stamp, in: box, index: index, total: total, context: context)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        guard let result = PDFDocument(data: data as Data) else { throw ConversionError.failed("Couldn't create the PDF.") }
        return result
    }

    private static func drawStamp(_ stamp: PDFStamp, in box: CGRect, index: Int, total: Int, context: CGContext) {
        let watermark = stamp.watermark.trimmingCharacters(in: .whitespaces)
        if !watermark.isEmpty {
            let size = max(24, min(box.width, box.height) / CGFloat(max(4, watermark.count)) * 1.6)
            let text = NSAttributedString(string: watermark, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .bold),
                .foregroundColor: NSColor.gray.withAlphaComponent(stamp.watermarkOpacity)
            ])
            let textSize = text.size()
            context.saveGState()
            context.translateBy(x: box.midX, y: box.midY)
            context.rotate(by: atan2(box.height, box.width))
            text.draw(at: NSPoint(x: -textSize.width / 2, y: -textSize.height / 2))
            context.restoreGState()
        }
        if stamp.pageNumbers {
            let text = NSAttributedString(string: stamp.label(forPage: index, total: total), attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.darkGray
            ])
            let size = text.size()
            let margin: CGFloat = 24
            let point: NSPoint
            switch stamp.numberPosition {
            case .bottomCenter: point = NSPoint(x: box.midX - size.width / 2, y: margin)
            case .bottomRight: point = NSPoint(x: box.maxX - margin - size.width, y: margin)
            case .topRight: point = NSPoint(x: box.maxX - margin - size.width, y: box.maxY - margin - size.height)
            }
            text.draw(at: point)
        }
    }
}
