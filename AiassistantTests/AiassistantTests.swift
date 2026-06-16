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

struct AiassistantTests {

    @Test func localContextWindowErrorRoutesToPCC() async throws {
        let error = LanguageModelError.contextSizeExceeded(
            LanguageModelError.ContextSizeExceeded(
                contextSize: 10,
                tokenCount: 20,
                debugDescription: "Test context overflow"
            )
        )

        #expect(AppleIntelligenceProvider.shouldRouteToPCCGateway(for: error))
    }

    @Test func legacyLocalContextWindowErrorRoutesToPCC() async throws {
        let error = LanguageModelSession.GenerationError.exceededContextWindowSize(
            LanguageModelSession.GenerationError.Context(debugDescription: "Test context overflow")
        )

        #expect(AppleIntelligenceProvider.shouldRouteToPCCGateway(for: error))
    }

    @Test func unrelatedLocalErrorDoesNotRouteToPCC() async throws {
        let error = NSError(
            domain: "AppleIntelligenceTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The on-device model declined this request."]
        )

        #expect(!AppleIntelligenceProvider.shouldRouteToPCCGateway(for: error))
    }

    @Test func contextStyleErrorMessageRoutesToPCC() async throws {
        let error = NSError(
            domain: "AppleIntelligenceTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Prompt context window exceeded for this request."]
        )

        #expect(AppleIntelligenceProvider.shouldRouteToPCCGateway(for: error))
    }

    @Test func coreAIGemmaProviderKindPersists() async throws {
        let settings = AppSettings.shared
        let oldProvider = settings.selectedAIProvider
        defer { settings.selectedAIProvider = oldProvider }

        settings.selectedAIProvider = .coreAIGemma

        #expect(UserDefaults.standard.string(forKey: "selected_ai_provider") == AIProviderKind.coreAIGemma.rawValue)
    }

    @Test func coreAIGemmaModelPersistsAndDefaultIsTwelveB() async throws {
        let settings = AppSettings.shared
        let oldModel = settings.selectedCoreAIGemmaModel
        defer { settings.selectedCoreAIGemmaModel = oldModel }

        settings.selectedCoreAIGemmaModel = .gemma4E2BSmall
        #expect(UserDefaults.standard.string(forKey: "selected_core_ai_gemma_model") == CoreAIGemmaModel.gemma4E2BSmall.rawValue)
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
        #expect(CoreAIGemmaModel.gemma4E2BSmall.mlxModelID == "mlx-community/gemma-4-e2b-it-4bit")
        #expect(CoreAIGemmaModel.gemma3_4BSmall.mlxModelID == "mlx-community/gemma-4-e4b-it-4bit")
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
        #expect(prompt.contains("text-only"))
        #expect(prompt.contains("1 image attachment"))
        #expect(prompt.contains("1 video attachment"))
    }

    @Test func appStateRoutesCoreAIGemmaProvider() async throws {
        let settings = AppSettings.shared
        let oldProvider = settings.selectedAIProvider
        defer { settings.selectedAIProvider = oldProvider }

        settings.selectedAIProvider = .coreAIGemma

        #expect(AppState.shared.activeProvider is CoreAIGemmaProvider)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AiassistantTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
