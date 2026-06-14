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

}
