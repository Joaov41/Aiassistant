import Foundation
import Combine
import OSLog

@MainActor
final class FollowUpViewModel: ObservableObject {
    @Published var currentResponse: String = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

    var llmService: RemoteLLMService?

    private var followUpTask: Task<Void, Never>?
    private var currentRequestID: UUID?

    func ask(question: String, document: DocumentViewModel) {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let service = llmService else {
            errorMessage = "LLM service not configured"
            return
        }
        if let previousID = currentRequestID {
            AppLogger.llm.info("Cancelling in-flight follow-up request id=\(previousID.uuidString, privacy: .public)")
        }
        followUpTask?.cancel()
        errorMessage = nil
        currentResponse = ""
        isLoading = true
        let requestID = UUID()
        currentRequestID = requestID

        let history = document.conversationHistory
        AppLogger.llm.info("Starting follow-up request id=\(requestID.uuidString, privacy: .public) historyCount=\(history.count, privacy: .public)")

        followUpTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var cancelled = false
            do {
                var accumulated = ""
                for try await chunk in service.streamFollowUp(history: history, question: question) {
                    if Task.isCancelled {
                        cancelled = true
                        break
                    }
                    await MainActor.run {
                        guard self.currentRequestID == requestID else { return }
                        switch chunk.kind {
                        case .status(let status):
                            AppLogger.llm.info("Follow-up status chunk id=\(requestID.uuidString, privacy: .public)")
                            self.currentResponse = status
                        case .token(let token):
                            accumulated.append(token)
                            AppLogger.llm.debug("Follow-up token chunk id=\(requestID.uuidString, privacy: .public) len=\(accumulated.count, privacy: .public)")
                            self.currentResponse = accumulated
                        case .final(let final):
                            accumulated = final
                            self.currentResponse = final
                            AppLogger.llm.info("Follow-up final chunk id=\(requestID.uuidString, privacy: .public) length=\(final.count, privacy: .public)")
                        }
                    }
                }
                if !cancelled {
                    AppLogger.llm.info("Follow-up request id=\(requestID.uuidString, privacy: .public) completed")
                    await MainActor.run {
                        guard self.currentRequestID == requestID else { return }
                        let userMessage = ChatMessage(role: .user, content: question)
                        let assistantMessage = ChatMessage(role: .assistant, content: self.currentResponse)
                        document.updateConversation(with: userMessage)
                        document.updateConversation(with: assistantMessage)
                    }
                } else {
                    AppLogger.llm.info("Follow-up request id=\(requestID.uuidString, privacy: .public) cancelled")
                }
            } catch {
                AppLogger.llm.error("Follow-up request id=\(requestID.uuidString, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    guard self.currentRequestID == requestID else { return }
                    self.errorMessage = error.localizedDescription
                }
            }
            await MainActor.run {
                guard self.currentRequestID == requestID else { return }
                self.isLoading = false
                if cancelled {
                    self.currentResponse = ""
                }
                self.currentRequestID = nil
            }
        }
    }

    func clear(document: DocumentViewModel) {
        if let id = currentRequestID {
            AppLogger.llm.info("Clearing follow-up cancelling request id=\(id.uuidString, privacy: .public)")
        }
        followUpTask?.cancel()
        followUpTask = nil
        currentRequestID = nil
        currentResponse = ""
        errorMessage = nil
        isLoading = false
        document.resetConversationHistory()
    }

    deinit {
        followUpTask?.cancel()
        if let id = currentRequestID {
            AppLogger.llm.info("FollowUpViewModel deinitialized while request id=\(id.uuidString, privacy: .public) was active")
        }
    }
}
