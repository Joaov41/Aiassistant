import PDFKit
import UniformTypeIdentifiers
import Vision

class PDFHandler {
    static func extractText(from pdfData: Data) -> String {
        guard let pdfDocument = PDFDocument(data: pdfData) else { return "" }
        var pageTexts: [String] = []
        
        for i in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: i) else { continue }
            let embeddedText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if embeddedText.isEmpty {
                let ocrText = extractTextWithOCR(from: page)
                if !ocrText.isEmpty {
                    pageTexts.append(ocrText)
                }
            } else {
                pageTexts.append(embeddedText)
            }
        }
        
        return pageTexts.joined(separator: "\n\n")
    }

    private static func extractTextWithOCR(from page: PDFPage) -> String {
        guard let cgImage = renderImage(for: page) else { return "" }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            print("PDFHandler OCR failed: \(error.localizedDescription)")
            return ""
        }

        guard let observations = request.results else { return "" }
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func renderImage(for page: PDFPage) -> CGImage? {
        guard let cgPDFPage = page.pageRef else { return nil }

        let pageBounds = cgPDFPage.getBoxRect(.mediaBox)
        guard pageBounds.width > 0, pageBounds.height > 0 else { return nil }

        let maxRenderedDimension: CGFloat = 2400
        let longestSide = max(pageBounds.width, pageBounds.height)
        let scale = max(1, min(3, maxRenderedDimension / longestSide))
        let width = Int((pageBounds.width * scale).rounded(.up))
        let height = Int((pageBounds.height * scale).rounded(.up))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -pageBounds.origin.x, y: pageBounds.height + pageBounds.origin.y)
        context.scaleBy(x: 1, y: -1)
        context.drawPDFPage(cgPDFPage)
        context.restoreGState()

        return context.makeImage()
    }
}
