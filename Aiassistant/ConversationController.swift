import SwiftUI

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: String
    var content: String
    var images: [Data]
    let providerName: String?
    let timestamp: Date
    var isTruncated: Bool

    init(id: UUID = UUID(), role: String, content: String, images: [Data] = [], providerName: String? = nil, isTruncated: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.images = images
        self.providerName = providerName
        self.timestamp = Date()
        self.isTruncated = isTruncated
    }

    init(id: UUID = UUID(), message: String, images: [Data] = []) {
        if message.hasPrefix("User: ") {
            self.init(id: id, role: "user", content: String(message.dropFirst(6)), images: images)
        } else if message.hasPrefix("Assistant: ") {
            self.init(id: id, role: "assistant", content: String(message.dropFirst(11)), images: images)
        } else if message.hasPrefix("Error: ") {
            self.init(id: id, role: "error", content: String(message.dropFirst(7)), images: images)
        } else {
            self.init(id: id, role: "status", content: message, images: images)
        }
    }

    var displayContent: String {
        isTruncated ? content + "\n\n_Response stopped at the output-token limit._" : content
    }

    var message: String {
        switch role {
        case "user": return "User: " + displayContent
        case "assistant": return "Assistant: " + displayContent
        case "error": return "Error: " + content
        default: return content
        }
    }

    var conversationTurn: AIConversationTurn? {
        guard let role = AIConversationTurn.Role(rawValue: role) else { return nil }
        return AIConversationTurn(role: role, content: content)
    }
}

struct ConversationContext {
    var text: String = ""
    var isDocument = false
    var images: [Data] = []
    var videos: [Data] = []

    func request(for prompt: String, systemPrompt: String? = nil) -> AIConversationRequest {
        let context = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = isDocument ? """
        You are a precise document extraction assistant. Use the provided context and conversation.
        If an amount, currency, date, or field is not explicitly present, say it is not found.
        Do not infer subtotals, taxes, totals, conversions, or missing values unless explicitly asked to calculate from listed amounts.
        When answering extraction questions, quote the exact label and amount from the context.
        """ : systemPrompt
        let userPrompt = context.isEmpty ? prompt : """
        Use this context if it is relevant to the user's message. Resolve follow-up references from the conversation.

        Context:
        ---
        \(context)
        ---

        User says: \(prompt)
        """
        return AIConversationRequest(systemPrompt: instructions, userPrompt: userPrompt, images: images, videos: videos)
    }
}

@MainActor
class ConversationController: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published private(set) var isProcessing = false
    private var requestTask: Task<Void, Never>?
    private var requestID: UUID?
    private var partialMessageID: UUID?

    deinit { requestTask?.cancel() }

    func isCurrent(_ id: UUID) -> Bool { requestID == id && !Task.isCancelled }

    func perform(_ operation: @escaping @MainActor (UUID) async -> Void) {
        guard !isProcessing else { return }
        let id = UUID()
        requestID = id
        isProcessing = true
        requestTask = Task { [weak self] in
            await operation(id)
            guard let self, self.requestID == id else { return }
            self.requestTask = nil
            self.requestID = nil
            self.partialMessageID = nil
            self.isProcessing = false
        }
    }

    func send(
        _ prompt: String,
        provider: any AIProvider,
        prepareRequest: @escaping @MainActor () async throws -> AIConversationRequest,
        onResponse: (@MainActor (AIResponse) -> Void)? = nil
    ) {
        guard !isProcessing, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let history = messages.compactMap(\.conversationTurn)
        messages.append(ChatMessage(role: "user", content: prompt))
        let messageID = UUID()
        perform { [weak self] id in
            guard let self else { return }
            do {
                var request = try await prepareRequest()
                guard self.isCurrent(id) else { return }
                request.history = history
                let response = try await provider.processConversation(request, onUpdate: { [weak self] text in
                    guard let self, self.isCurrent(id), !text.isEmpty else { return }
                    self.partialMessageID = messageID
                    self.setAssistantMessage(id: messageID, response: AIResponse(text: text))
                })
                guard self.isCurrent(id) else { return }
                self.setAssistantMessage(id: messageID, response: response)
                onResponse?(response)
            } catch {
                guard self.isCurrent(id) else { return }
                self.messages.removeAll { $0.id == messageID }
                self.messages.append(ChatMessage(role: "error", content: error.localizedDescription))
            }
        }
    }

    private func setAssistantMessage(id: UUID, response: AIResponse) {
        let message = ChatMessage(id: id, role: "assistant", content: response.text,
                                  images: response.images, providerName: response.providerName,
                                  isTruncated: response.isTruncated)
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }

    func cancel() {
        requestID = nil
        requestTask?.cancel()
        requestTask = nil
        isProcessing = false
        if let partialMessageID { messages.removeAll { $0.id == partialMessageID } }
        partialMessageID = nil
    }

    func reset(keeping messages: [ChatMessage] = []) {
        cancel()
        self.messages = messages
    }

    func waitForCurrentRequest() async { await requestTask?.value }
}
