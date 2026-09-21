import Foundation

struct AIResponse {
    let text: String
    let images: [Data]
    let providerName: String
    let isTruncated: Bool

    init(
        text: String,
        images: [Data] = [],
        providerName: String = AIProviderKind.localAppleFoundation.fullDisplayName,
        isTruncated: Bool = false
    ) {
        self.text = Self.sanitizeDisplayText(text)
        self.images = images
        self.providerName = providerName
        self.isTruncated = isTruncated
    }

    var displayText: String {
        isTruncated ? text + "\n\n_Response stopped at the output-token limit._" : text
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

@MainActor
protocol AIProvider: ObservableObject {
    var isProcessing: Bool { get set }
    func processText(systemPrompt: String?, userPrompt: String, images: [Data], videos: [Data]?) async throws -> AIResponse
    func processConversation(_ request: AIConversationRequest, onUpdate: (@MainActor (String) -> Void)?) async throws -> AIResponse
    func cancel()
}

extension AIProvider {
    func processConversation(_ request: AIConversationRequest, onUpdate: (@MainActor (String) -> Void)? = nil) async throws -> AIResponse {
        try Task.checkCancellation()
        let response = try await processText(
            systemPrompt: request.systemPrompt,
            userPrompt: request.promptWithHistory,
            images: request.images,
            videos: request.videos
        )
        try Task.checkCancellation()
        return response
    }
}
