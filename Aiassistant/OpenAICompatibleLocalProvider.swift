import AppKit
import Foundation

enum LocalOpenAIEndpoint {
    static let defaultBaseURL = "http://127.0.0.1:8080/v1"

    static func normalizedBaseURL(from rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenAICompatibleLocalProviderError.invalidBaseURL(rawValue)
        }

        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false else {
            throw OpenAICompatibleLocalProviderError.invalidBaseURL(rawValue)
        }

        var pathParts = components.path
            .split(separator: "/")
            .map(String.init)
        while pathParts.count >= 2,
              pathParts[pathParts.count - 2].lowercased() == "chat",
              pathParts[pathParts.count - 1].lowercased() == "completions" {
            pathParts.removeLast(2)
        }
        if pathParts.last?.lowercased() == "models" {
            pathParts.removeLast()
        }

        components.scheme = scheme
        components.path = pathParts.isEmpty ? "" : "/" + pathParts.joined(separator: "/")
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw OpenAICompatibleLocalProviderError.invalidBaseURL(rawValue)
        }
        return url
    }

    static func chatCompletionsURL(from rawValue: String) throws -> URL {
        append("chat/completions", to: try normalizedBaseURL(from: rawValue))
    }

    static func modelsURL(from rawValue: String) throws -> URL {
        append("models", to: try normalizedBaseURL(from: rawValue))
    }

    private static func append(_ suffix: String, to baseURL: URL) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL.appendingPathComponent(suffix)
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffixPath = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = ([basePath, suffixPath]
            .filter { !$0.isEmpty }
            .joined(separator: "/"))
        if !components.path.hasPrefix("/") {
            components.path = "/" + components.path
        }
        return components.url ?? baseURL.appendingPathComponent(suffix)
    }
}

enum OpenAICompatibleLocalProviderError: LocalizedError {
    case invalidBaseURL(String)
    case missingModelID
    case invalidImage(Int)
    case serverUnavailable(URL)
    case httpError(Int, String)
    case decodingFailed(String)
    case emptyResponse
    case cancelled
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let value):
            return "Local OpenAI base URL is invalid: \(value)"
        case .missingModelID:
            return "Local OpenAI model ID is empty. Set the model ID in Settings."
        case .invalidImage(let index):
            return "Image \(index + 1) could not be prepared for Local OpenAI."
        case .serverUnavailable(let url):
            return "Local OpenAI server is not reachable at \(url.absoluteString). Start or fix your local server, then try again."
        case .httpError(let statusCode, let message):
            return "Local OpenAI server returned HTTP \(statusCode): \(message)"
        case .decodingFailed(let message):
            return "Local OpenAI response could not be decoded: \(message)"
        case .emptyResponse:
            return "Local OpenAI server returned an empty response."
        case .cancelled:
            return "Local OpenAI request was cancelled."
        case .requestFailed(let message):
            return "Local OpenAI request failed: \(message)"
        }
    }
}

final class OpenAICompatibleLocalProvider: ObservableObject, AIProvider {
    @Published var isProcessing = false

    private let session: URLSession
    private let requestState = LocalOpenAIRequestState()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func processText(systemPrompt: String?, userPrompt: String, images: [Data], videos: [Data]?) async throws -> AIResponse {
        let settings = AppSettings.shared
        let modelID = settings.localOpenAIModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else {
            throw OpenAICompatibleLocalProviderError.missingModelID
        }

        isProcessing = true
        defer { isProcessing = false }

        let baseURL = settings.localOpenAIBaseURL
        var request = URLRequest(url: try LocalOpenAIEndpoint.chatCompletionsURL(from: baseURL))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthorizationHeader(to: &request, apiKey: settings.localOpenAIAPIKey)

        let imageDataURLs = try images.enumerated().map { index, data in
            try Self.imageDataURL(from: data, index: index)
        }
        let body = LocalOpenAIChatCompletionRequest(
            model: modelID,
            messages: Self.chatMessages(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                imageDataURLs: imageDataURLs,
                videos: videos
            ),
            temperature: 0,
            maxTokens: 1024,
            stream: false,
            chatTemplateKwargs: settings.localOpenAIDisableThinking
                ? LocalOpenAIChatTemplateKwargs(enableThinking: false)
                : nil
        )
        request.httpBody = try JSONEncoder().encode(body)

        do {
            let (data, response) = try await performDataRequest(request)
            try Self.validateHTTPResponse(response, data: data, serverName: "Local OpenAI")
            let decoded: LocalOpenAIChatCompletionResponse
            do {
                decoded = try JSONDecoder().decode(LocalOpenAIChatCompletionResponse.self, from: data)
            } catch {
                throw OpenAICompatibleLocalProviderError.decodingFailed(Self.unreadableResponseMessage(from: data, decodingError: error))
            }
            guard let text = decoded.assistantText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                throw OpenAICompatibleLocalProviderError.emptyResponse
            }
            return AIResponse(
                text: text,
                providerName: "\(AIProviderKind.localOpenAI.fullDisplayName) (\(modelID))"
            )
        } catch let error as OpenAICompatibleLocalProviderError {
            throw error
        } catch let error as URLError {
            throw Self.transportError(from: error, baseURL: try LocalOpenAIEndpoint.normalizedBaseURL(from: baseURL))
        } catch is CancellationError {
            throw OpenAICompatibleLocalProviderError.cancelled
        } catch {
            throw OpenAICompatibleLocalProviderError.requestFailed(error.localizedDescription)
        }
    }

    func cancel() {
        requestState.cancel()
        isProcessing = false
    }

    func testConnection() async throws -> LocalOpenAIConnectionResult {
        let settings = AppSettings.shared
        let modelID = settings.localOpenAIModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: try LocalOpenAIEndpoint.modelsURL(from: settings.localOpenAIBaseURL))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        applyAuthorizationHeader(to: &request, apiKey: settings.localOpenAIAPIKey)

        do {
            let (data, response) = try await session.data(for: request)
            try Self.validateHTTPResponse(response, data: data, serverName: "Local OpenAI")
            let modelIDs = Self.modelIDs(fromModelsResponse: data)
            let status: String
            if !modelID.isEmpty, modelIDs.contains(modelID) {
                status = "Connected. Model \(modelID) is available."
            } else if modelIDs.isEmpty {
                status = "Connected. /models returned no model IDs."
            } else {
                status = "Connected. \(modelIDs.count) model(s) returned; choose one below."
            }
            return LocalOpenAIConnectionResult(status: status, modelIDs: modelIDs)
        } catch let error as OpenAICompatibleLocalProviderError {
            throw error
        } catch let error as URLError {
            throw Self.transportError(from: error, baseURL: try LocalOpenAIEndpoint.normalizedBaseURL(from: settings.localOpenAIBaseURL))
        } catch is CancellationError {
            throw OpenAICompatibleLocalProviderError.cancelled
        } catch {
            throw OpenAICompatibleLocalProviderError.requestFailed(error.localizedDescription)
        }
    }

    static func modelIDs(fromModelsResponse data: Data) -> [String] {
        guard let models = try? JSONDecoder().decode(LocalOpenAIModelsResponse.self, from: data) else {
            return []
        }

        var seen = Set<String>()
        return (models.data ?? []).compactMap { model in
            guard let id = model.id?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty,
                  seen.insert(id).inserted else {
                return nil
            }
            return id
        }
    }

    static func chatMessages(
        systemPrompt: String?,
        userPrompt: String,
        imageDataURLs: [String],
        videos: [Data]?
    ) -> [LocalOpenAIChatMessage] {
        var messages: [LocalOpenAIChatMessage] = []
        if let systemPrompt = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !systemPrompt.isEmpty {
            messages.append(LocalOpenAIChatMessage(role: "system", content: .text(systemPrompt)))
        }

        var prompt = userPrompt
        if let videos, !videos.isEmpty {
            prompt += "\n\n(Note: \(videos.count) video attachment(s) are not sent to this OpenAI-compatible local provider yet. Answer from the text and images available.)"
        }

        if imageDataURLs.isEmpty {
            messages.append(LocalOpenAIChatMessage(role: "user", content: .text(prompt)))
        } else {
            var contentParts: [LocalOpenAIContentPart] = []
            let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPrompt.isEmpty {
                contentParts.append(.text(trimmedPrompt))
            }
            contentParts += imageDataURLs.map { .imageURL($0) }
            messages.append(LocalOpenAIChatMessage(role: "user", content: .parts(contentParts)))
        }

        return messages
    }

    private func applyAuthorizationHeader(to request: inout URLRequest, apiKey: String) {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty else { return }
        request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
    }

    private func performDataRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) { data, response, error in
                    self.requestState.clear()
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let data, let response else {
                        continuation.resume(throwing: OpenAICompatibleLocalProviderError.requestFailed("No response data was returned."))
                        return
                    }
                    continuation.resume(returning: (data, response))
                }
                requestState.set(task)
                task.resume()
            }
        } onCancel: {
            self.requestState.cancel()
        }
    }

    private static func validateHTTPResponse(_ response: URLResponse, data: Data, serverName: String) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAICompatibleLocalProviderError.decodingFailed("\(serverName) did not return an HTTP response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OpenAICompatibleLocalProviderError.httpError(
                httpResponse.statusCode,
                serverErrorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"
            )
        }
    }

    private static func transportError(from error: URLError, baseURL: URL) -> OpenAICompatibleLocalProviderError {
        switch error.code {
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .requestFailed("The local server timed out. It may still be loading the model.")
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
            return .serverUnavailable(baseURL)
        default:
            return .requestFailed(error.localizedDescription)
        }
    }

    private static func imageDataURL(from data: Data, index: Int) throws -> String {
        if let pngData = pngData(from: data) {
            return "data:image/png;base64,\(pngData.base64EncodedString())"
        }
        guard let mimeType = imageMimeType(for: data),
              NSImage(data: data) != nil else {
            throw OpenAICompatibleLocalProviderError.invalidImage(index)
        }
        return "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    private static func pngData(from data: Data) -> Data? {
        guard let image = NSImage(data: data),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func imageMimeType(for data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "image/png"
        }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        }
        if bytes.starts(with: [0x47, 0x49, 0x46]) {
            return "image/gif"
        }
        if bytes.count >= 12,
           String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
           String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" {
            return "image/webp"
        }
        return nil
    }

    private static func serverErrorMessage(from data: Data) -> String? {
        if let decoded = try? JSONDecoder().decode(LocalOpenAIErrorResponse.self, from: data),
           let message = decoded.error?.message?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return message
        }

        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else {
            return nil
        }
        return raw.count > 500 ? String(raw.prefix(500)) + "..." : raw
    }

    private static func unreadableResponseMessage(from data: Data, decodingError: Error) -> String {
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw, !raw.isEmpty {
            let snippet = raw.count > 500 ? String(raw.prefix(500)) + "..." : raw
            return "\(snippet) (\(decodingError.localizedDescription))"
        }
        return decodingError.localizedDescription
    }
}

struct LocalOpenAIConnectionResult {
    let status: String
    let modelIDs: [String]
}

struct LocalOpenAIChatCompletionRequest: Encodable {
    let model: String
    let messages: [LocalOpenAIChatMessage]
    let temperature: Double
    let maxTokens: Int
    let stream: Bool
    let chatTemplateKwargs: LocalOpenAIChatTemplateKwargs?

    init(
        model: String,
        messages: [LocalOpenAIChatMessage],
        temperature: Double,
        maxTokens: Int,
        stream: Bool,
        chatTemplateKwargs: LocalOpenAIChatTemplateKwargs? = nil
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stream = stream
        self.chatTemplateKwargs = chatTemplateKwargs
    }

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case stream
        case chatTemplateKwargs = "chat_template_kwargs"
    }
}

struct LocalOpenAIChatTemplateKwargs: Encodable {
    let enableThinking: Bool

    enum CodingKeys: String, CodingKey {
        case enableThinking = "enable_thinking"
    }
}

struct LocalOpenAIChatMessage: Encodable {
    let role: String
    let content: LocalOpenAIMessageContent
}

enum LocalOpenAIMessageContent: Encodable {
    case text(String)
    case parts([LocalOpenAIContentPart])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .parts(let parts):
            try container.encode(parts)
        }
    }
}

struct LocalOpenAIContentPart: Encodable {
    let type: String
    let text: String?
    let imageURL: LocalOpenAIImageURL?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }

    static func text(_ text: String) -> LocalOpenAIContentPart {
        LocalOpenAIContentPart(type: "text", text: text, imageURL: nil)
    }

    static func imageURL(_ url: String) -> LocalOpenAIContentPart {
        LocalOpenAIContentPart(type: "image_url", text: nil, imageURL: LocalOpenAIImageURL(url: url))
    }
}

struct LocalOpenAIImageURL: Encodable {
    let url: String
}

private struct LocalOpenAIChatCompletionResponse: Decodable {
    let choices: [Choice]

    var assistantText: String? {
        for choice in choices {
            if let content = choice.message?.content?.text,
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return content
            }
            if let reasoning = choice.message?.reasoningContent,
               !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return reasoning
            }
            if let text = choice.text,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    struct Choice: Decodable {
        let message: Message?
        let text: String?
    }

    struct Message: Decodable {
        let content: LocalOpenAIResponseContent?
        let reasoningContent: String?

        enum CodingKeys: String, CodingKey {
            case content
            case reasoningContent = "reasoning_content"
        }
    }
}

private enum LocalOpenAIResponseContent: Decodable {
    case text(String)
    case parts([Part])

    var text: String {
        switch self {
        case .text(let text):
            return text
        case .parts(let parts):
            return parts
                .compactMap(\.text)
                .joined(separator: "\n")
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
            return
        }
        self = .parts(try container.decode([Part].self))
    }

    struct Part: Decodable {
        let text: String?
    }
}

private struct LocalOpenAIModelsResponse: Decodable {
    let data: [Model]?

    struct Model: Decodable {
        let id: String?
    }
}

private struct LocalOpenAIErrorResponse: Decodable {
    let error: ErrorBody?

    struct ErrorBody: Decodable {
        let message: String?
    }
}

private final class LocalOpenAIRequestState {
    private let lock = NSLock()
    private var currentTask: URLSessionDataTask?

    func set(_ task: URLSessionDataTask) {
        lock.lock()
        currentTask = task
        lock.unlock()
    }

    func clear() {
        lock.lock()
        currentTask = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = currentTask
        currentTask = nil
        lock.unlock()
        task?.cancel()
    }
}
