import Foundation
import OSLog

final class RemoteLLMService {
    enum ServiceError: Error {
        case missingAPIKey
        case invalidResponse
        case network(Error)
        case decoding(Error)
    }

    private let settings: SettingsStore
    private let session: URLSession

    init(settings: SettingsStore, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    func streamSummary(for text: String) -> AsyncThrowingStream<LLMChunk, Error> {
        let prompt = Self.summaryPrompt(for: text)
        let history = [ChatMessage(role: .user, content: prompt)]
        return streamResponse(messages: history)
    }

    func streamFollowUp(history: [ChatMessage], question: String) -> AsyncThrowingStream<LLMChunk, Error> {
        var updated = history
        updated.append(ChatMessage(role: .user, content: question))
        return streamResponse(messages: updated)
    }

    private func streamResponse(messages: [ChatMessage]) -> AsyncThrowingStream<LLMChunk, Error> {
        let model = settings.selectedModel
        let openAIKey = settings.openAIAPIKey
        let geminiKey = settings.geminiAPIKey

        switch model.provider {
        case .openAI:
            return streamOpenAI(messages: messages, model: model, apiKey: openAIKey)
        case .gemini:
            return streamGemini(messages: messages, model: model, apiKey: geminiKey)
        }
    }

    private func streamOpenAI(messages: [ChatMessage], model: LLMModel, apiKey: String) -> AsyncThrowingStream<LLMChunk, Error> {
        guard !apiKey.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: ServiceError.missingAPIKey) }
        }

        let payloadMessages = messages.map { message in
            [
                "role": message.role.rawValue,
                "content": message.content
            ]
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model.apiIdentifier,
            "stream": true,
            "messages": payloadMessages
        ]
        if model.apiIdentifier.lowercased().contains("gpt-5") {
            body["max_completion_tokens"] = 4096
        } else {
            body["max_tokens"] = 4096
            body["temperature"] = 0.2
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let requestID = UUID()
        AppLogger.llm.info("OpenAI stream start id=\(requestID.uuidString, privacy: .public) model=\(model.apiIdentifier, privacy: .public) messages=\(messages.count, privacy: .public)")
        let urlSession = session
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var cancelled = false
                do {
                    let (bytes, response) = try await urlSession.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse,
                          200..<300 ~= httpResponse.statusCode else {
                        continuation.finish(throwing: ServiceError.invalidResponse)
                        return
                    }
                    continuation.yield(LLMChunk(kind: .status("AI is processing your request...")))
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" {
                            break
                        }
                        guard let data = payload.data(using: .utf8) else { continue }
                        do {
                            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let choices = json["choices"] as? [[String: Any]] {
                                for choice in choices {
                                    if let delta = choice["delta"] as? [String: Any],
                                       let content = delta["content"] as? String,
                                       !content.isEmpty {
                                        continuation.yield(LLMChunk(kind: .token(content)))
                                    }
                                }
                            }
                        } catch {
                            continuation.finish(throwing: ServiceError.decoding(error))
                            return
                        }
                    }
                    continuation.finish()
                    AppLogger.llm.info("OpenAI stream completed id=\(requestID.uuidString, privacy: .public)")
                } catch {
                    AppLogger.llm.error("OpenAI stream failed id=\(requestID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    continuation.finish(throwing: ServiceError.network(error))
                }
            }
            continuation.onTermination = { termination in
                task.cancel()
                switch termination {
                case .cancelled:
                    AppLogger.llm.info("OpenAI stream cancelled id=\(requestID.uuidString, privacy: .public)")
                case .finished:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    private func streamGemini(messages: [ChatMessage], model: LLMModel, apiKey: String) -> AsyncThrowingStream<LLMChunk, Error> {
        guard !apiKey.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: ServiceError.missingAPIKey) }
        }

        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model.apiIdentifier):streamGenerateContent?alt=sse&key=\(apiKey)"
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.addValue("keep-alive", forHTTPHeaderField: "Connection")

        let contents = messages.map { message in
            [
                "role": message.role == .user ? "user" : "model",
                "parts": [["text": message.content]]
            ]
        }
        let body = ["contents": contents]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let requestID = UUID()
        AppLogger.llm.info("Gemini stream start id=\(requestID.uuidString, privacy: .public) model=\(model.apiIdentifier, privacy: .public) messages=\(messages.count, privacy: .public)")
        let urlSession = session
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var accumulated = ""
                do {
                    let (bytes, response) = try await urlSession.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse,
                          200..<300 ~= httpResponse.statusCode else {
                        continuation.finish(throwing: ServiceError.invalidResponse)
                        return
                    }
                    continuation.yield(LLMChunk(kind: .status("AI is generating a response...")))

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" || payload.isEmpty {
                            break
                        }
                        guard let data = payload.data(using: .utf8) else { continue }

                        do {
                            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                if let errorDict = json["error"] as? [String: Any],
                                   let message = errorDict["message"] as? String {
                                    AppLogger.llm.error("Gemini stream error id=\(requestID.uuidString, privacy: .public): \(message, privacy: .public)")
                                    continuation.finish(throwing: ServiceError.invalidResponse)
                                    return
                                }

                                var yieldedToken = false
                                if let candidates = json["candidates"] as? [[String: Any]] {
                                    for candidate in candidates {
                                        if let content = candidate["content"] as? [String: Any] {
                                            if let emitted = Self.emitGeminiParts(from: content, accumulated: &accumulated, continuation: continuation) {
                                                yieldedToken = yieldedToken || emitted
                                            }
                                        }
                                        if let delta = candidate["delta"] as? [String: Any] {
                                            if let emitted = Self.emitGeminiParts(from: delta, accumulated: &accumulated, continuation: continuation) {
                                                yieldedToken = yieldedToken || emitted
                                            }
                                        }
                                        if let finishReason = candidate["finishReason"] as? String,
                                           finishReason.lowercased() != "unspecified" {
                                            // Model signalled completion.
                                            break
                                        }
                                    }
                                }

                                if !yieldedToken,
                                   let text = json["text"] as? String,
                                   !text.isEmpty {
                                    accumulated.append(text)
                                    continuation.yield(LLMChunk(kind: .token(text)))
                                }
                            }
                        } catch {
                            continuation.finish(throwing: ServiceError.decoding(error))
                            AppLogger.llm.error("Gemini stream decode failed id=\(requestID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                            return
                        }
                    }

                    continuation.yield(LLMChunk(kind: .final(accumulated)))
                    continuation.finish()
                    AppLogger.llm.info("Gemini stream completed id=\(requestID.uuidString, privacy: .public)")
                } catch {
                    AppLogger.llm.error("Gemini stream failed id=\(requestID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    continuation.finish(throwing: ServiceError.network(error))
                }
            }
            continuation.onTermination = { termination in
                task.cancel()
                switch termination {
                case .cancelled:
                    AppLogger.llm.info("Gemini stream cancelled id=\(requestID.uuidString, privacy: .public)")
                case .finished:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    private static func extractGeminiErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errorDict = json["error"] as? [String: Any] else { return nil }
        return errorDict["message"] as? String
    }

    private static func emitGeminiParts(from container: [String: Any], accumulated: inout String, continuation: AsyncThrowingStream<LLMChunk, Error>.Continuation) -> Bool? {
        guard let parts = container["parts"] as? [[String: Any]] else { return nil }
        var emitted = false
        for part in parts {
            if let text = part["text"] as? String, !text.isEmpty {
                accumulated.append(text)
                continuation.yield(LLMChunk(kind: .token(text)))
                emitted = true
            }
        }
        return emitted
    }

    private static func summaryPrompt(for text: String) -> String {
        """
        You are an AI assistant specialized in summarizing email conversations.
        Your primary goal is to extract all critical information from the substantive parts of the messages, while ignoring boilerplate.

        IMPORTANT INPUT STRUCTURE: The email content below has the most recent message at the top. Older messages follow below it.

        CORE TASK: Summarize the following email content clearly, concisely, and completely.

        EMAIL CONTENT:
        \(text)

        REQUIRED SUMMARY OUTPUT:
        1. TLDR: One sentence summarizing the latest outcome.
        2. Key Information & Decisions (Latest): Bullet points covering all significant items from the newest message(s).
        3. Relevant Older Context: Brief context from earlier messages if needed, otherwise "None".
        4. Open Questions / Next Steps (Latest): Outstanding questions or next actions from the latest messages, otherwise "None".
        5. Action Items/Deadlines (Latest): Specific actions or deadlines from the latest messages, otherwise "None".
        """
    }
}

extension RemoteLLMService.ServiceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key configured for the selected model."
        case .invalidResponse:
            return "The LLM returned an unexpected response."
        case .network(let error):
            return "Network error: \(error.localizedDescription)"
        case .decoding(let error):
            return "Failed to parse LLM response: \(error.localizedDescription)"
        }
    }
}
