import AppKit
import Darwin
import Foundation

enum CoreAIGemmaProviderError: LocalizedError {
    case modelNotInstalled(CoreAIGemmaModel)
    case invalidModelBundle(CoreAIGemmaModel)
    case cancelled
    case promptTooLong(Int, Int)
    case metalUnavailable
    case missingSupportFile(String)
    case staticBufferAllocationFailed(String)
    case mlxServerUnavailable(URL)
    case mlxServerCommandMissing
    case mlxServerStartTimedOut(String)
    case mlxInvalidResponse
    case mlxServerError(String)

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let model):
            return "\(model.fullDisplayName) is not installed for the old Core AI backend. Start the local MLX server for \(model.fullDisplayName) instead."
        case .invalidModelBundle(let model):
            return "\(model.fullDisplayName) does not look like a valid Core AI bundle."
        case .cancelled:
            return "Local MLX Gemma request was cancelled."
        case .promptTooLong(let tokenCount, let contextLength):
            return "The prompt is too long for this local model (\(tokenCount) tokens, context limit \(contextLength))."
        case .metalUnavailable:
            return "Local Gemma requires a Metal-capable Apple GPU."
        case .missingSupportFile(let path):
            return "Missing required support file: \(path)."
        case .staticBufferAllocationFailed(let file):
            return "Could not load the required support table: \(file)."
        case .mlxServerUnavailable(let url):
            return "Local MLX server is not reachable at \(url.absoluteString). The app tried to start it automatically."
        case .mlxServerCommandMissing:
            return "mlx_lm.server was not found. Install MLX-LM with pip install mlx-lm, or add mlx_lm.server to PATH."
        case .mlxServerStartTimedOut(let modelID):
            return "Local MLX server did not finish starting \(modelID). Check /tmp/aiassistant-mlx-server.log."
        case .mlxInvalidResponse:
            return "Local MLX server returned an invalid response."
        case .mlxServerError(let message):
            return "Local MLX server error: \(message)"
        }
    }
}

final class CoreAIGemmaProvider: ObservableObject, AIProvider {
    @Published var isProcessing = false

    private let baseURL = URL(string: "http://127.0.0.1:8080/v1")!
    private let visionBaseURL = URL(string: "http://127.0.0.1:8081/v1")!
    private var currentTask: Task<String, Error>?

    var selectedModel: CoreAIGemmaModel {
        AppSettings.shared.selectedCoreAIGemmaModel
    }

    var isAvailable: Bool {
        true
    }

    var availabilityDescription: String {
        Self.availabilityDescription(for: selectedModel)
    }

    @MainActor
    var isSelectedModelLoaded: Bool {
        true
    }

    static func availabilityDescription(for model: CoreAIGemmaModel) -> String {
        "Uses local MLX servers. Text uses \(model.mlxModelID); images use \(model.mlxVisionModelID)."
    }

    func startServerIfNeeded() async throws {
        let model = selectedModel
        LocalMLXLaunchLog.write("warming text and image servers for \(model.rawValue)")
        async let textServer: Void = LocalMLXServerLauncher.shared.ensureRunning(model: model, baseURL: baseURL)
        async let visionServer: Void = LocalMLXVLMServerLauncher.shared.ensureRunning(model: model, baseURL: visionBaseURL)
        _ = try await (textServer, visionServer)
    }

    func stopServers() async {
        await LocalMLXServerLauncher.shared.stopRunningServer()
        await LocalMLXVLMServerLauncher.shared.stopRunningServer()
        LocalMLXPortCleaner.terminateStaleServer(on: 8080, executableName: "mlx_lm.server")
        LocalMLXPortCleaner.terminateStaleServer(on: 8081, executableName: "mlx_vlm.server")
    }

    func processText(systemPrompt: String?, userPrompt: String, images: [Data], videos: [Data]?) async throws -> AIResponse {
        try await processText(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            images: images,
            videos: videos,
            streamingUpdate: nil
        )
    }

    func processText(
        systemPrompt: String?,
        userPrompt: String,
        images: [Data],
        videos: [Data]?,
        onUpdate: (@MainActor @escaping (String) -> Void)
    ) async throws -> AIResponse {
        try await processText(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            images: images,
            videos: videos,
            streamingUpdate: onUpdate
        )
    }

    private func processText(
        systemPrompt: String?,
        userPrompt: String,
        images: [Data],
        videos: [Data]?,
        streamingUpdate: (@MainActor (String) -> Void)?
    ) async throws -> AIResponse {
        isProcessing = true
        defer { isProcessing = false }

        if Task.isCancelled {
            throw CoreAIGemmaProviderError.cancelled
        }

        let prompt = Self.promptText(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            images: images,
            videos: videos
        )
        let model = selectedModel
        let generationTask = Task {
            if images.isEmpty {
                try await LocalMLXServerLauncher.shared.ensureRunning(model: model, baseURL: self.baseURL)
                return try await self.generate(prompt: prompt, model: model, streamingUpdate: streamingUpdate)
            } else {
                try await LocalMLXVLMServerLauncher.shared.ensureRunning(model: model, baseURL: self.visionBaseURL)
                return try await self.generateVision(prompt: prompt, model: model, images: images, streamingUpdate: streamingUpdate)
            }
        }
        currentTask = generationTask
        defer { currentTask = nil }

        let response = try await withTaskCancellationHandler {
            try await generationTask.value
        } onCancel: {
            generationTask.cancel()
        }

        return AIResponse(
            text: response,
            providerName: "\(AIProviderKind.coreAIGemma.fullDisplayName) (\(model.fullDisplayName))"
        )
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isProcessing = false
    }

    static func promptText(systemPrompt: String?, userPrompt: String, images: [Data], videos: [Data]?) -> String {
        var pieces: [String] = []
        if let systemPrompt = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !systemPrompt.isEmpty {
            pieces.append(systemPrompt)
        }
        pieces.append(userPrompt)

        var limitations: [String] = []
        if let videos, !videos.isEmpty {
            limitations.append("\(videos.count) video attachment(s)")
        }
        if !limitations.isEmpty {
            pieces.append(
                "Note: Local MLX Gemma can analyze images, but \(limitations.joined(separator: " and ")) cannot be analyzed yet."
            )
        }
        return pieces.joined(separator: "\n\n")
    }

    private func generateVision(
        prompt: String,
        model: CoreAIGemmaModel,
        images: [Data],
        streamingUpdate: (@MainActor (String) -> Void)?
    ) async throws -> String {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Aiassistant-MLX-Vision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let imageURLs = try images.enumerated().map { index, data in
            let imageURL = tempDirectory.appendingPathComponent("image-\(index + 1).png")
            guard let pngData = Self.pngData(from: data) ?? Self.validImageData(data) else {
                throw CoreAIGemmaProviderError.mlxInvalidResponse
            }
            try pngData.write(to: imageURL, options: .atomic)
            return imageURL
        }

        var request = URLRequest(url: visionBaseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600

        var contentParts = [VisionContentPart.text(prompt)]
        contentParts += imageURLs.map { VisionContentPart.inputImage(path: $0.path) }

        let body = VisionChatCompletionRequest(
            model: model.mlxVisionModelID,
            messages: [
                VisionChatMessage(role: "user", content: contentParts)
            ],
            temperature: 0,
            maxTokens: 1024,
            stream: streamingUpdate != nil,
            enableThinking: false
        )
        request.httpBody = try JSONEncoder().encode(body)

        if streamingUpdate != nil {
            return try await streamCompletion(request: request, streamingUpdate: streamingUpdate)
        }
        return try await nonStreamingCompletion(request: request)
    }

    private func generate(
        prompt: String,
        model: CoreAIGemmaModel,
        streamingUpdate: (@MainActor (String) -> Void)?
    ) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body = ChatCompletionRequest(
            model: model.mlxModelID,
            messages: [
                MLXChatMessage(role: "user", content: prompt)
            ],
            temperature: 0,
            maxTokens: 1024,
            stream: streamingUpdate != nil
        )
        request.httpBody = try JSONEncoder().encode(body)

        if streamingUpdate != nil {
            return try await streamCompletion(request: request, streamingUpdate: streamingUpdate)
        }
        return try await nonStreamingCompletion(request: request)
    }

    private func nonStreamingCompletion(request: URLRequest) async throws -> String {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validateHTTPResponse(response, data: data)
            let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            let rawText = decoded.choices.first?.message?.content ?? decoded.choices.first?.message?.reasoning
            guard let text = rawText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                throw CoreAIGemmaProviderError.mlxInvalidResponse
            }
            return text
        } catch let error as CoreAIGemmaProviderError {
            throw error
        } catch {
            throw CoreAIGemmaProviderError.mlxServerUnavailable(baseURL)
        }
    }

    private func streamCompletion(
        request: URLRequest,
        streamingUpdate: (@MainActor (String) -> Void)?
    ) async throws -> String {
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            try validateHTTPResponse(response, data: nil)

            var accumulated = ""
            for try await rawLine in bytes.lines {
                try Task.checkCancellation()
                guard rawLine.hasPrefix("data: ") else {
                    continue
                }
                let payload = String(rawLine.dropFirst("data: ".count))
                if payload == "[DONE]" {
                    break
                }
                guard let data = payload.data(using: .utf8) else {
                    continue
                }
                let chunk = try JSONDecoder().decode(ChatCompletionChunk.self, from: data)
                guard let delta = chunk.choices.first?.delta?.content ?? chunk.choices.first?.delta?.reasoning,
                      !delta.isEmpty else {
                    continue
                }
                accumulated += delta
                await streamingUpdate?(accumulated)
            }
            let trimmed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw CoreAIGemmaProviderError.mlxInvalidResponse
            }
            return trimmed
        } catch let error as CoreAIGemmaProviderError {
            throw error
        } catch is CancellationError {
            throw CoreAIGemmaProviderError.cancelled
        } catch {
            throw CoreAIGemmaProviderError.mlxServerUnavailable(baseURL)
        }
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data?) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CoreAIGemmaProviderError.mlxInvalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? "HTTP \(httpResponse.statusCode)"
            throw CoreAIGemmaProviderError.mlxServerError(message)
        }
    }

    private static func pngData(from data: Data) -> Data? {
        guard let image = NSImage(data: data),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func validImageData(_ data: Data) -> Data? {
        NSImage(data: data) == nil ? nil : data
    }
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [MLXChatMessage]
    let temperature: Double
    let maxTokens: Int
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case stream
    }
}

private struct MLXChatMessage: Codable {
    let role: String
    let content: String?
    let reasoning: String?

    init(role: String, content: String?, reasoning: String? = nil) {
        self.role = role
        self.content = content
        self.reasoning = reasoning
    }
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: MLXChatMessage?
    }
}

private struct ChatCompletionChunk: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let delta: MLXChatMessage?
    }
}

private struct VisionChatCompletionRequest: Encodable {
    let model: String
    let messages: [VisionChatMessage]
    let temperature: Double
    let maxTokens: Int
    let stream: Bool
    let enableThinking: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case stream
        case enableThinking = "enable_thinking"
    }
}

private struct VisionChatMessage: Encodable {
    let role: String
    let content: [VisionContentPart]
}

private struct VisionContentPart: Encodable {
    let type: String
    let text: String?
    let imageURL: String?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }

    static func text(_ text: String) -> VisionContentPart {
        VisionContentPart(type: "text", text: text, imageURL: nil)
    }

    static func inputImage(path: String) -> VisionContentPart {
        VisionContentPart(type: "input_image", text: nil, imageURL: path)
    }
}

private actor LocalMLXServerLauncher {
    static let shared = LocalMLXServerLauncher()

    private var process: Process?
    private var runningModelID: String?
    private let port = 8080
    private let logURL = URL(fileURLWithPath: "/tmp/aiassistant-mlx-server.log")

    func ensureRunning(model: CoreAIGemmaModel, baseURL: URL) async throws {
        if await isServerReachable(baseURL: baseURL) {
            if process?.isRunning == true,
               let runningModelID,
               runningModelID != model.mlxModelID {
                stopServer()
            } else {
                return
            }
        }

        if process?.isRunning == true,
           runningModelID != model.mlxModelID {
            stopServer()
        }

        if process?.isRunning != true {
            LocalMLXLaunchLog.write("text server not running; starting \(model.mlxModelID) on port \(port)")
            Self.terminateStaleServerIfNeeded(on: port)
            try startServer(model: model)
        }

        try await waitForServer(model: model, baseURL: baseURL)
    }

    private func startServer(model: CoreAIGemmaModel) throws {
        guard let executableURL = Self.findServerExecutable() else {
            throw CoreAIGemmaProviderError.mlxServerCommandMissing
        }

        let serverProcess = Process()
        serverProcess.executableURL = executableURL
        serverProcess.arguments = [
            "--model",
            model.mlxModelID,
            "--port",
            "\(port)",
            "--use-default-chat-template",
            "--chat-template-args",
            #"{"enable_thinking":false}"#
        ]

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        LocalMLXHuggingFaceEnvironment.configure(&environment)
        serverProcess.environment = environment

        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let logHandle = try? FileHandle(forWritingTo: logURL) {
            logHandle.seekToEndOfFile()
            serverProcess.standardOutput = logHandle
            serverProcess.standardError = logHandle
            serverProcess.terminationHandler = { _ in
                try? logHandle.close()
            }
        }

        do {
            LocalMLXLaunchLog.write("launching text server \(executableURL.path)")
            try serverProcess.run()
        } catch {
            LocalMLXLaunchLog.write("failed to launch text server: \(error.localizedDescription)")
            throw error
        }
        process = serverProcess
        runningModelID = model.mlxModelID
    }

    private func stopServer() {
        process?.terminate()
        process = nil
        runningModelID = nil
    }

    func stopRunningServer() {
        stopServer()
    }

    private func waitForServer(model: CoreAIGemmaModel, baseURL: URL) async throws {
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            try Task.checkCancellation()
            if await isServerReachable(baseURL: baseURL) {
                return
            }
            if let process, !process.isRunning {
                throw CoreAIGemmaProviderError.mlxServerUnavailable(baseURL)
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw CoreAIGemmaProviderError.mlxServerStartTimedOut(model.mlxModelID)
    }

    private func isServerReachable(baseURL: URL) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return (200..<500).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    private static func findServerExecutable() -> URL? {
        let candidates = [
            "\(NSHomeDirectory())/Library/Application Support/Aiassistant/mlx-venv/bin/mlx_lm.server",
            "/opt/anaconda3/bin/mlx_lm.server",
            "/opt/homebrew/bin/mlx_lm.server",
            "/usr/local/bin/mlx_lm.server",
            "\(NSHomeDirectory())/.local/bin/mlx_lm.server"
        ]

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for directory in pathDirectories {
            let path = "\(directory)/mlx_lm.server"
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        return nil
    }

    private static func terminateStaleServerIfNeeded(on port: Int) {
        LocalMLXPortCleaner.terminateStaleServer(on: port, executableName: "mlx_lm.server")
    }
}

private actor LocalMLXVLMServerLauncher {
    static let shared = LocalMLXVLMServerLauncher()

    private var process: Process?
    private var runningModelID: String?
    private let port = 8081
    private let logURL = URL(fileURLWithPath: "/tmp/aiassistant-mlx-vlm-server.log")

    func ensureRunning(model: CoreAIGemmaModel, baseURL: URL) async throws {
        if await isServerReachable(baseURL: baseURL) {
            if process?.isRunning == true,
               let runningModelID,
               runningModelID != model.mlxVisionModelID {
                stopServer()
            } else {
                return
            }
        }

        if process?.isRunning == true,
           runningModelID != model.mlxVisionModelID {
            stopServer()
        }

        if process?.isRunning != true {
            LocalMLXLaunchLog.write("image server not running; starting \(model.mlxVisionModelID) on port \(port)")
            Self.terminateStaleServerIfNeeded(on: port)
            try startServer(model: model)
        }

        try await waitForServer(model: model, baseURL: baseURL)
    }

    private func startServer(model: CoreAIGemmaModel) throws {
        guard let executableURL = Self.findServerExecutable() else {
            throw CoreAIGemmaProviderError.mlxServerCommandMissing
        }

        let serverProcess = Process()
        serverProcess.executableURL = executableURL
        serverProcess.arguments = [
            "--model",
            model.mlxVisionModelID,
            "--host",
            "127.0.0.1",
            "--port",
            "\(port)",
            "--max-tokens",
            "1024"
        ]

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        LocalMLXHuggingFaceEnvironment.configure(&environment)
        serverProcess.environment = environment

        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let logHandle = try? FileHandle(forWritingTo: logURL) {
            logHandle.seekToEndOfFile()
            serverProcess.standardOutput = logHandle
            serverProcess.standardError = logHandle
            serverProcess.terminationHandler = { _ in
                try? logHandle.close()
            }
        }

        do {
            LocalMLXLaunchLog.write("launching image server \(executableURL.path)")
            try serverProcess.run()
        } catch {
            LocalMLXLaunchLog.write("failed to launch image server: \(error.localizedDescription)")
            throw error
        }
        process = serverProcess
        runningModelID = model.mlxVisionModelID
    }

    private func stopServer() {
        process?.terminate()
        process = nil
        runningModelID = nil
    }

    func stopRunningServer() {
        stopServer()
    }

    private func waitForServer(model: CoreAIGemmaModel, baseURL: URL) async throws {
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            try Task.checkCancellation()
            if await isServerReachable(baseURL: baseURL) {
                return
            }
            if let process, !process.isRunning {
                throw CoreAIGemmaProviderError.mlxServerUnavailable(baseURL)
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw CoreAIGemmaProviderError.mlxServerStartTimedOut(model.mlxVisionModelID)
    }

    private func isServerReachable(baseURL: URL) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return (200..<500).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    private static func findServerExecutable() -> URL? {
        let candidates = [
            "\(NSHomeDirectory())/Library/Application Support/Aiassistant/mlx-vlm-venv/bin/mlx_vlm.server",
            "\(NSHomeDirectory())/Library/Application Support/Aiassistant/mlx-venv/bin/mlx_vlm.server",
            "/opt/anaconda3/bin/mlx_vlm.server",
            "/opt/homebrew/bin/mlx_vlm.server",
            "/usr/local/bin/mlx_vlm.server",
            "\(NSHomeDirectory())/.local/bin/mlx_vlm.server"
        ]

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for directory in pathDirectories {
            let path = "\(directory)/mlx_vlm.server"
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        return nil
    }

    private static func terminateStaleServerIfNeeded(on port: Int) {
        LocalMLXPortCleaner.terminateStaleServer(on: port, executableName: "mlx_vlm.server")
    }
}

private enum LocalMLXPortCleaner {
    static func terminateStaleServer(on port: Int, executableName: String) {
        let pids = listeningPIDs(on: port)
        guard !pids.isEmpty else {
            return
        }

        var terminatedPIDs: [pid_t] = []
        for pid in pids {
            guard commandLine(for: pid).contains(executableName) else {
                continue
            }
            Darwin.kill(pid, SIGTERM)
            terminatedPIDs.append(pid)
        }

        guard !terminatedPIDs.isEmpty else {
            return
        }

        Thread.sleep(forTimeInterval: 0.75)
        for pid in terminatedPIDs where isProcessRunning(pid) {
            Darwin.kill(pid, SIGKILL)
        }
    }

    private static func listeningPIDs(on port: Int) -> [pid_t] {
        let output = runCommand(
            executablePath: "/usr/sbin/lsof",
            arguments: ["-tiTCP:\(port)", "-sTCP:LISTEN"]
        )
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .map { pid_t($0) }
    }

    private static func commandLine(for pid: pid_t) -> String {
        runCommand(
            executablePath: "/bin/ps",
            arguments: ["-p", "\(pid)", "-ww", "-o", "command="]
        )
    }

    private static func isProcessRunning(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == 0
    }

    private static func runCommand(executablePath: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}

private enum LocalMLXHuggingFaceEnvironment {
    static func configure(_ environment: inout [String: String]) {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support")
        let cacheURL = applicationSupport
            .appendingPathComponent("Aiassistant", isDirectory: true)
            .appendingPathComponent("huggingface-token", isDirectory: true)

        try? FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        environment["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
        environment["HF_TOKEN_PATH"] = cacheURL.appendingPathComponent("token").path
    }
}

private enum LocalMLXLaunchLog {
    private static let logURL = URL(fileURLWithPath: "/tmp/aiassistant-mlx-launcher.log")

    static func write(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        guard let data = line.data(using: .utf8) else {
            return
        }

        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: logURL) else {
            return
        }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        try? handle.write(contentsOf: data)
    }
}
