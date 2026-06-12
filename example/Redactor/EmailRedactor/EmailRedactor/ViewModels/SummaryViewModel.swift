import Foundation
import Combine
import OSLog

@MainActor
final class SummaryViewModel: ObservableObject {
    @Published var summaryText: String = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

    var llmService: RemoteLLMService?

    private var summarizeTask: Task<Void, Never>?
    private var currentSummaryID: UUID?

    func summarize(text: String) {
        guard !text.isEmpty else { return }
        guard let service = llmService else {
            errorMessage = "LLM service not configured"
            return
        }
        if let previousID = currentSummaryID {
            AppLogger.llm.info("Cancelling in-flight summary request id=\(previousID.uuidString, privacy: .public)")
        }
        summarizeTask?.cancel()
        summaryText = ""
        errorMessage = nil
        isLoading = true
        let requestID = UUID()
        currentSummaryID = requestID
        AppLogger.llm.info("Starting summary request id=\(requestID.uuidString, privacy: .public) length=\(text.count, privacy: .public)")

        let stream = service.streamSummary(for: text)
        summarizeTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var cancelled = false
            do {
                for try await chunk in stream {
                    if Task.isCancelled {
                        cancelled = true
                        break
                    }
                    await MainActor.run {
                        guard self.currentSummaryID == requestID else { return }
                        self.apply(chunk: chunk)
                    }
                }
            } catch {
                AppLogger.llm.error("Summary request id=\(requestID.uuidString, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    guard self.currentSummaryID == requestID else { return }
                    self.errorMessage = error.localizedDescription
                }
            }
            if cancelled {
                AppLogger.llm.info("Summary request id=\(requestID.uuidString, privacy: .public) cancelled")
            } else {
                AppLogger.llm.info("Summary request id=\(requestID.uuidString, privacy: .public) completed")
            }
            await MainActor.run {
                guard self.currentSummaryID == requestID else { return }
                self.isLoading = false
                self.currentSummaryID = nil
            }
        }
    }

    deinit {
        summarizeTask?.cancel()
        if let id = currentSummaryID {
            AppLogger.llm.info("SummaryViewModel deinitialized while request id=\(id.uuidString, privacy: .public) was active")
        }
    }

    private func apply(chunk: LLMChunk) {
        switch chunk.kind {
        case .status(let status):
            summaryText = status
        case .token(let token):
            summaryText.append(token)
        case .final(let final):
            summaryText = final
            AppLogger.llm.info("Summary final chunk length=\(final.count, privacy: .public)")
        }
    }
}
