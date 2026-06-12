import Foundation
import PDFKit

struct PDFTextExtractor {
    static func extractText(from url: URL) -> String {
        guard let document = PDFDocument(url: url) else {
            return ""
        }
        var fullText = ""
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            if let pageText = page.string {
                fullText.append(pageText)
                fullText.append("\n")
            }
        }
        return fullText
    }
}
