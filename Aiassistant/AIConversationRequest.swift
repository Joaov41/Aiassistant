import Foundation

struct AIConversationTurn: Equatable {
    enum Role: String { case user, assistant }
    let role: Role
    let content: String
}

struct AIConversationRequest {
    var systemPrompt: String?
    var userPrompt: String
    var history: [AIConversationTurn] = []
    var images: [Data] = []
    var videos: [Data] = []

    // Keep the same recent-turn bound for every provider, without clipping document context.
    var recentHistory: [AIConversationTurn] { Array(history.suffix(12)) }

    var promptWithHistory: String {
        guard !recentHistory.isEmpty else { return userPrompt }
        let transcript = recentHistory.map { "\($0.role.rawValue.capitalized): \($0.content)" }
            .joined(separator: "\n\n")
        return """
        Use the recent conversation to resolve follow-up questions, then answer the latest user message.

        Recent conversation:
        ---
        \(transcript)
        ---

        Latest user message and context:
        \(userPrompt)
        """
    }
}
