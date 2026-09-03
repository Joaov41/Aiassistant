import Foundation

struct AIResponse {
    let text: String
    let images: [Data]
    let providerName: String

    init(
        text: String,
        images: [Data] = [],
        providerName: String = AIProviderKind.localAppleFoundation.fullDisplayName
    ) {
        self.text = Self.sanitizeDisplayText(text)
        self.images = images
        self.providerName = providerName
    }

    static func sanitizeDisplayText(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .filter { line in
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmedLine != "****" && trimmedLine != #""""#
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

protocol AIProvider: ObservableObject {
    var isProcessing: Bool { get set }
    func processText(systemPrompt: String?, userPrompt: String, images: [Data], videos: [Data]?) async throws -> AIResponse
    func cancel()
}
