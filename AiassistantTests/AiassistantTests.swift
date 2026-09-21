//
//  AiassistantTests.swift
//  AiassistantTests
//
//  Created by john val on 2/11/25.
//

import Testing
import Foundation
import FoundationModels
@testable import Aiassistant

@Suite(.serialized)
@MainActor
struct AiassistantTests {

    @Test func windowPlacementKeepsQuickActionsVisibleNearBottomEdge() async throws {
        let visibleFrame = NSRect(x: 0, y: 40, width: 1440, height: 860)
        let windowSize = NSSize(width: 400, height: 350)
        let origin = WindowPlacement.origin(
            centeredOn: NSPoint(x: 720, y: 45),
            windowSize: windowSize,
            visibleFrame: visibleFrame
        )
        let positionedFrame = NSRect(origin: origin, size: windowSize)

        #expect(positionedFrame.minY == visibleFrame.minY + 12)
        #expect(positionedFrame.maxY <= visibleFrame.maxY - 12)
        #expect(positionedFrame.minX >= visibleFrame.minX + 12)
        #expect(positionedFrame.maxX <= visibleFrame.maxX - 12)
    }

    @Test func localContextWindowErrorRoutesToPrivateCloud() async throws {
        let error = LanguageModelError.contextSizeExceeded(
            LanguageModelError.ContextSizeExceeded(
                contextSize: 10,
                tokenCount: 20,
                debugDescription: "Test context overflow"
            )
        )

        #expect(AppleIntelligenceProvider.shouldRouteToPrivateCloud(for: error))
    }

    @Test func legacyLocalContextWindowErrorRoutesToPrivateCloud() async throws {
        let error = LanguageModelSession.GenerationError.exceededContextWindowSize(
            LanguageModelSession.GenerationError.Context(debugDescription: "Test context overflow")
        )

        #expect(AppleIntelligenceProvider.shouldRouteToPrivateCloud(for: error))
    }

    @Test func unrelatedLocalErrorDoesNotRouteToPrivateCloud() async throws {
        let error = NSError(
            domain: "AppleIntelligenceTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The on-device model declined this request."]
        )

        #expect(!AppleIntelligenceProvider.shouldRouteToPrivateCloud(for: error))
    }

    @Test func contextStyleErrorMessageRoutesToPrivateCloud() async throws {
        let error = NSError(
            domain: "AppleIntelligenceTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Prompt context window exceeded for this request."]
        )

        #expect(AppleIntelligenceProvider.shouldRouteToPrivateCloud(for: error))
    }

    @Test func legacyCLIProviderValueIsNoLongerSelectable() async throws {
        #expect(AIProviderKind(rawValue: "apple_pcc") == nil)
    }

    @Test func emptyMarkdownArtifactsAreRemovedFromAIResponseText() async throws {
        let response = AIResponse(text: """
        ****
        The actual answer.
        ""
        """)

        #expect(response.text == "The actual answer.")
    }

    @Test func coreAIGemmaProviderKindPersists() async throws {
        let fixture = SettingsFixture()
        let settings = fixture.settings

        settings.selectedAIProvider = .coreAIGemma

        #expect(fixture.defaults.string(forKey: "selected_ai_provider") == AIProviderKind.coreAIGemma.rawValue)
    }

    @Test func coreAIGemmaModelPersistsAndDefaultIsTwelveB() async throws {
        let fixture = SettingsFixture()
        let settings = fixture.settings

        settings.selectedCoreAIGemmaModel = .gemma4E2BSmall
        #expect(fixture.defaults.string(forKey: "selected_core_ai_gemma_model") == CoreAIGemmaModel.gemma4E2BSmall.rawValue)
        #expect(CoreAIGemmaModel(rawValue: "") ?? .gemma4_12B == .gemma4_12B)
    }

    @Test func coreAIGemmaInstalledDetectionRequiresFinalBundle() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CoreAIGemmaModel.gemma4_12B

        let finalDirectory = CoreAIGemmaModelStore.directory(for: model, in: root)
        try FileManager.default.createDirectory(
            at: finalDirectory.appendingPathComponent("gemma.aimodel"),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: finalDirectory.appendingPathComponent("metadata.json"))

        #expect(CoreAIGemmaModelStore.isInstalled(model, in: root))
    }

    @Test func coreAIGemmaE2BInstalledDetectionRequiresStaticTables() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CoreAIGemmaModel.gemma4E2BSmall

        let finalDirectory = CoreAIGemmaModelStore.directory(for: model, in: root)
        try FileManager.default.createDirectory(at: finalDirectory, withIntermediateDirectories: true)

        #expect(!CoreAIGemmaModelStore.isInstalled(model, in: root))

        for modelPath in model.requiredModelPaths {
            try FileManager.default.createDirectory(
                at: finalDirectory.appendingPathComponent(modelPath, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Data("{}".utf8).write(to: finalDirectory.appendingPathComponent("metadata.json"))

        #expect(!CoreAIGemmaModelStore.isInstalled(model, in: root))

        let tableDirectory = finalDirectory.appendingPathComponent("gemma4_gather_raw", isDirectory: true)
        try FileManager.default.createDirectory(at: tableDirectory, withIntermediateDirectories: true)
        try Data([1]).write(to: tableDirectory.appendingPathComponent("embed_tokens.i8"))
        try Data([1]).write(to: tableDirectory.appendingPathComponent("embed_tokens.scale.f32"))
        try Data([1]).write(to: tableDirectory.appendingPathComponent("embed_per_layer.i8"))
        try Data([1]).write(to: tableDirectory.appendingPathComponent("embed_per_layer.scale.f32"))
        try Data([1]).write(to: tableDirectory.appendingPathComponent("meta.json"))
        try Data([1]).write(to: tableDirectory.appendingPathComponent("proj.f32"))

        #expect(!CoreAIGemmaModelStore.isInstalled(model, in: root))

        try Data([1]).write(to: tableDirectory.appendingPathComponent("proj_norm.f32"))
        let tokenizerDirectory = finalDirectory.appendingPathComponent("tokenizer", isDirectory: true)
        try FileManager.default.createDirectory(at: tokenizerDirectory, withIntermediateDirectories: true)
        try Data([1]).write(to: tokenizerDirectory.appendingPathComponent("tokenizer.json"))

        #expect(!CoreAIGemmaModelStore.isInstalled(model, in: root))

        try Data([1]).write(to: tokenizerDirectory.appendingPathComponent("tokenizer_config.json"))

        #expect(CoreAIGemmaModelStore.isInstalled(model, in: root))
    }

    @Test func coreAIGemmaModelsMapToMLXModelIDs() async throws {
        #expect(CoreAIGemmaModel.gemma4E2BSmall.mlxModelID.contains("gemma-4-e2b-it-4bit"))
        #expect(CoreAIGemmaModel.gemma3_4BSmall.mlxModelID == "mlx-community/gemma-4-e4b-it-4bit")
        #expect(CoreAIGemmaModel.gemma3_4BSmall.mlxVisionModelID == "mlx-community/gemma-4-e4b-it-4bit")
        #expect(CoreAIGemmaModel.gemma3_4BSmall.usesVLMForText)
        #expect(CoreAIGemmaModel.gemma3_4BSmall.fallbackServerCommand.hasPrefix("mlx_vlm.server"))
        #expect(CoreAIGemmaModel.gemma4_12B.mlxModelID == "mlx-community/gemma-4-12B-it-4bit")
        #expect(CoreAIGemmaModel.gemma4_31B.mlxModelID == "mlx-community/gemma-4-31b-it-4bit")
    }

    @Test func coreAIGemmaStagingFolderIsNotInstalled() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CoreAIGemmaModel.gemma4_12B

        let stagingDirectory = CoreAIGemmaModelStore.stagingDirectory(for: model, in: root)
        try FileManager.default.createDirectory(
            at: stagingDirectory.appendingPathComponent("gemma.aimodel"),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: stagingDirectory.appendingPathComponent("metadata.json"))

        #expect(!CoreAIGemmaModelStore.isInstalled(model, in: root))
    }

    @Test func coreAIGemmaPromptMentionsAttachmentLimitations() async throws {
        let prompt = CoreAIGemmaProvider.promptText(
            systemPrompt: "Be concise.",
            userPrompt: "What is in this file?",
            images: [Data([1, 2, 3])],
            videos: [Data([4, 5, 6])]
        )

        #expect(!prompt.contains("User:"))
        #expect(!prompt.contains("text-only"))
        #expect(!prompt.contains("1 image attachment"))
        #expect(prompt.contains("1 video attachment"))
    }

    @Test func appStateRoutesCoreAIGemmaProvider() async throws {
        let fixture = SettingsFixture()
        let settings = fixture.settings

        settings.selectedAIProvider = .coreAIGemma
        let state = AppState(settings: settings, checkModelAvailability: false)

        #expect(state.activeProvider is CoreAIGemmaProvider)
    }

    @Test func localOpenAIEndpointDoesNotDuplicateV1OrChatCompletions() async throws {
        let chatURL = try LocalOpenAIEndpoint.chatCompletionsURL(
            from: "http://127.0.0.1:8080/v1/chat/completions"
        )
        let modelsURL = try LocalOpenAIEndpoint.modelsURL(
            from: "127.0.0.1:8080/v1/models"
        )

        #expect(chatURL.absoluteString == "http://127.0.0.1:8080/v1/chat/completions")
        #expect(modelsURL.absoluteString == "http://127.0.0.1:8080/v1/models")
    }

    @Test func localOpenAIRequestUsesOpenAIImageDataURLParts() async throws {
        let messages = OpenAICompatibleLocalProvider.chatMessages(
            systemPrompt: "Be concise.",
            userPrompt: "Describe this.",
            imageDataURLs: ["data:image/png;base64,AAAA"],
            videos: nil
        )
        let request = LocalOpenAIChatCompletionRequest(
            model: "test-model",
            messages: messages,
            temperature: 0,
            maxTokens: 1024,
            stream: false
        )
        let data = try JSONEncoder().encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedMessages = try #require(json["messages"] as? [[String: Any]])
        let systemMessage = try #require(encodedMessages.first)
        let userMessage = try #require(encodedMessages.last)
        let userContent = try #require(userMessage["content"] as? [[String: Any]])
        let imagePart = try #require(userContent.last)
        let imageURL = try #require(imagePart["image_url"] as? [String: Any])

        #expect(json["model"] as? String == "test-model")
        #expect(systemMessage["content"] as? String == "Be concise.")
        #expect(userContent.first?["type"] as? String == "text")
        #expect(userContent.first?["text"] as? String == "Describe this.")
        #expect(imagePart["type"] as? String == "image_url")
        #expect(imageURL["url"] as? String == "data:image/png;base64,AAAA")
    }

    @Test func localOpenAIRequestCanDisableModelThinking() throws {
        let request = LocalOpenAIChatCompletionRequest(
            model: "thinking-model",
            messages: [LocalOpenAIChatMessage(role: "user", content: .text("Answer directly."))],
            temperature: 0,
            maxTokens: 1024,
            stream: false,
            chatTemplateKwargs: LocalOpenAIChatTemplateKwargs(enableThinking: false)
        )
        let data = try JSONEncoder().encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let templateArguments = try #require(json["chat_template_kwargs"] as? [String: Any])

        #expect(templateArguments["enable_thinking"] as? Bool == false)
    }

    @Test func localOpenAIModelsResponseProducesUniqueNonEmptyModelIDs() throws {
        let data = try #require("""
        {
          "object": "list",
          "data": [
            {"id": "model-a"},
            {"id": "model-b"},
            {"id": "model-a"},
            {"id": "  "}
          ]
        }
        """.data(using: .utf8))

        #expect(OpenAICompatibleLocalProvider.modelIDs(fromModelsResponse: data) == ["model-a", "model-b"])
    }

    @Test func localOpenAISettingsPersist() async throws {
        let fixture = SettingsFixture()
        let settings = fixture.settings

        settings.selectedAIProvider = .localOpenAI
        settings.localOpenAIBaseURL = "http://localhost:1234/v1"
        settings.localOpenAIModelID = "custom-model"
        settings.localOpenAIAPIKey = "local-key"
        settings.localOpenAIMaxTokens = 4096

        #expect(fixture.defaults.string(forKey: "selected_ai_provider") == AIProviderKind.localOpenAI.rawValue)
        #expect(fixture.defaults.string(forKey: "local_openai_base_url") == "http://localhost:1234/v1")
        #expect(fixture.defaults.string(forKey: "local_openai_model_id") == "custom-model")
        #expect(fixture.defaults.integer(forKey: "local_openai_max_tokens") == 4096)
        #expect(fixture.defaults.object(forKey: "local_openai_api_key") == nil)
        #expect(fixture.credentialStore.value == "local-key")
    }

    @Test func appStateRoutesLocalOpenAIProvider() async throws {
        let fixture = SettingsFixture()
        let settings = fixture.settings

        settings.selectedAIProvider = .localOpenAI
        let state = AppState(settings: settings, checkModelAvailability: false)

        #expect(state.activeProvider is OpenAICompatibleLocalProvider)
    }

    @Test func localOpenAIConversationPreservesRoleHistory() throws {
        let messages = OpenAICompatibleLocalProvider.chatMessages(
            systemPrompt: "Be concise.",
            userPrompt: "Second question",
            imageDataURLs: [],
            videos: nil,
            history: [
                AIConversationTurn(role: .user, content: "First question"),
                AIConversationTurn(role: .assistant, content: "First answer")
            ]
        )
        let data = try JSONEncoder().encode(messages)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        #expect(json.compactMap { $0["role"] as? String } == ["system", "user", "assistant", "user"])
        #expect(json[1]["content"] as? String == "First question")
        #expect(json[2]["content"] as? String == "First answer")
        #expect(json[3]["content"] as? String == "Second question")
    }

    @Test func conversationControllerRejectsLateResultAfterReset() async throws {
        let provider = RecordingProvider(delay: .milliseconds(100), ignoresCancellation: true)
        let controller = ConversationController()

        controller.send("Old request", provider: provider) {
            AIConversationRequest(userPrompt: "Old request")
        }
        controller.reset()
        try await Task.sleep(for: .milliseconds(150))

        #expect(controller.messages.isEmpty)
        #expect(!controller.isProcessing)
    }

    @Test func conversationControllerPassesCompleteHistoryToProvider() async {
        let provider = RecordingProvider()
        let controller = ConversationController()
        controller.messages = [
            ChatMessage(role: "user", content: "First question"),
            ChatMessage(role: "assistant", content: "First answer")
        ]

        controller.send("Follow up", provider: provider) {
            AIConversationRequest(userPrompt: "Follow up")
        }
        await controller.waitForCurrentRequest()

        #expect(provider.requests.first?.history == [
            AIConversationTurn(role: .user, content: "First question"),
            AIConversationTurn(role: .assistant, content: "First answer")
        ])
        #expect(controller.messages.last?.content == "Recorded answer")
    }

    @Test func replacingImageWithTextClearsEveryImageReference() {
        let fixture = SettingsFixture()
        let state = AppState(settings: fixture.settings, checkModelAvailability: false)
        state.handleDroppedImageData(Data([1, 2, 3]), fileName: "old.png")

        state.handleDroppedText("new text", sourceName: "new.txt")

        #expect(state.selectedImages.isEmpty)
        #expect(state.capturedImageForConversation == nil)
        #expect(state.capturedScreenshotData == nil)
        #expect(state.conversationContext.images.isEmpty)
        #expect(state.selectedText.contains("new text"))
    }

    @Test func staleAttachmentImportCannotReplaceNewerAttachment() {
        let fixture = SettingsFixture()
        let state = AppState(settings: fixture.settings, checkModelAvailability: false)
        let staleRevision = state.beginAttachmentImport(name: "old.txt")
        let currentRevision = state.beginAttachmentImport(name: "new.txt")

        state.applyImportedAttachment(
            .document("old content", "old.txt", "Text File"),
            expectedRevision: staleRevision
        )

        #expect(state.attachedContentName == "new.txt")
        #expect(state.selectedText.isEmpty)
        #expect(state.isAttachmentLoading)

        state.applyImportedAttachment(
            .document("new content", "new.txt", "Text File"),
            expectedRevision: currentRevision
        )
        #expect(state.selectedText.contains("new content"))
        #expect(!state.isAttachmentLoading)
    }

    @Test func droppedSourceFileIsPreservedByDefault() async throws {
        let fixture = SettingsFixture()
        let state = AppState(settings: fixture.settings, checkModelAvailability: false)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.txt")
        try Data("source contents".utf8).write(to: source)

        state.handleDroppedFile(url: source)
        for _ in 0..<100 where state.isAttachmentLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(state.selectedText.contains("source contents"))
    }

    @Test func inlineReplacementFingerprintDetectsSelectionChanges() {
        let original = TextSelectionFingerprint(
            selectedText: "selected text",
            selectedRange: CFRange(location: 10, length: 13),
            elementValue: "before selected text after"
        )

        #expect(original == TextSelectionFingerprint(
            selectedText: "selected text",
            selectedRange: CFRange(location: 10, length: 13),
            elementValue: "before selected text after"
        ))
        #expect(original != TextSelectionFingerprint(
            selectedText: "other text",
            selectedRange: CFRange(location: 10, length: 10),
            elementValue: "before other text after"
        ))
    }

    @Test func localOpenAICompletionMarksOutputLimitAsTruncated() throws {
        let data = try #require(#"{"choices":[{"message":{"content":"Partial answer"},"finish_reason":"length"}]}"#.data(using: .utf8))
        let response = try OpenAICompatibleLocalProvider.decodeCompletion(data)

        #expect(response.text == "Partial answer")
        #expect(response.isTruncated)
        #expect(response.displayText.contains("output-token limit"))
    }

    @Test func localOpenAIReasoningWithoutAnswerIsReportedClearly() throws {
        let data = try #require(#"{"choices":[{"message":{"content":"","reasoning_content":"internal work"},"finish_reason":"stop"}]}"#.data(using: .utf8))
        var receivedExpectedError = false
        do {
            _ = try OpenAICompatibleLocalProvider.decodeCompletion(data)
        } catch let error as OpenAICompatibleLocalProviderError {
            if case .reasoningOnly = error { receivedExpectedError = true }
        }

        #expect(receivedExpectedError)
    }

    @Test func localOpenAIAPIKeyIsOnlyAnOptionalBearerCredential() {
        #expect(OpenAICompatibleLocalProvider.authorizationHeaderValue(apiKey: "") == nil)
        #expect(OpenAICompatibleLocalProvider.authorizationHeaderValue(apiKey: "  local-secret  ") == "Bearer local-secret")
    }

    @Test func legacyLocalOpenAIAPIKeyMigratesOutOfUserDefaults() {
        let fixture = SettingsFixture(defaultValues: ["local_openai_api_key": "legacy-secret"])

        #expect(fixture.settings.localOpenAIAPIKey == "legacy-secret")
        #expect(fixture.credentialStore.value == "legacy-secret")
        #expect(fixture.defaults.object(forKey: "local_openai_api_key") == nil)
    }

    @Test func localOpenAIOutputLimitIsConfigurableAndClamped() {
        let fixture = SettingsFixture()
        fixture.settings.localOpenAIMaxTokens = 4096
        #expect(fixture.settings.localOpenAIMaxTokens == 4096)
        #expect(fixture.defaults.integer(forKey: "local_openai_max_tokens") == 4096)

        fixture.settings.localOpenAIMaxTokens = 1_000_000
        #expect(fixture.settings.localOpenAIMaxTokens == 131_072)
        #expect(fixture.defaults.integer(forKey: "local_openai_max_tokens") == 131_072)
    }

    @Test func mlxHTTPErrorBodyCanTriggerContextFallback() {
        let error = CoreAIGemmaProvider.serverHTTPError(
            statusCode: 400,
            data: Data("maximum context length exceeded".utf8)
        )

        #expect(error.localizedDescription.contains("maximum context length exceeded"))
        #expect(CoreAIGemmaProvider.shouldRouteToPrivateCloud(for: error))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AiassistantTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class MemoryCredentialStore: LocalServerCredentialStore {
    var value: String?

    init(value: String? = nil) {
        self.value = value
    }

    func read() throws -> String? { value }

    func write(_ value: String) throws {
        self.value = value.isEmpty ? nil : value
    }
}

private final class SettingsFixture {
    let suiteName: String
    let defaults: UserDefaults
    let credentialStore: MemoryCredentialStore
    let settings: AppSettings

    init(defaultValues: [String: Any] = [:], credential: String? = nil) {
        suiteName = "AiassistantTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        for (key, value) in defaultValues { defaults.set(value, forKey: key) }
        credentialStore = MemoryCredentialStore(value: credential)
        settings = AppSettings(defaults: defaults, credentialStore: credentialStore)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private final class RecordingProvider: ObservableObject, AIProvider {
    @Published var isProcessing = false
    private let delay: Duration
    private let ignoresCancellation: Bool
    var requests: [AIConversationRequest] = []

    init(delay: Duration = .zero, ignoresCancellation: Bool = false) {
        self.delay = delay
        self.ignoresCancellation = ignoresCancellation
    }

    func processText(
        systemPrompt: String?,
        userPrompt: String,
        images: [Data],
        videos: [Data]?
    ) async throws -> AIResponse {
        try await processConversation(
            AIConversationRequest(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                images: images,
                videos: videos ?? []
            ),
            onUpdate: nil
        )
    }

    func processConversation(
        _ request: AIConversationRequest,
        onUpdate: (@MainActor (String) -> Void)?
    ) async throws -> AIResponse {
        requests.append(request)
        if delay != .zero {
            if ignoresCancellation {
                try? await Task.sleep(for: delay)
            } else {
                try await Task.sleep(for: delay)
            }
        }
        return AIResponse(text: "Recorded answer", providerName: "Test Provider")
    }

    func cancel() {}
}
