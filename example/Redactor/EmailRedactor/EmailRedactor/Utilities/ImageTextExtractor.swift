import Foundation
import Vision
import ImageIO
import OSLog

enum ImageTextExtractor {
    static func extractText(from url: URL) -> String {
        guard let cgImage = makeCGImage(from: url) else {
            AppLogger.document.error("ImageTextExtractor failed to create CGImage for \(url.lastPathComponent, privacy: .public)")
            return ""
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            guard let observations = request.results else { return "" }
            let text = observations
                .flatMap { observation in
                    observation.topCandidates(1).map(\.string)
                }
                .joined(separator: "\n")
            return text
        } catch {
            AppLogger.document.error("ImageTextExtractor error: \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }

    private static func makeCGImage(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
