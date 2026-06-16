// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import Foundation
import Testing
import Tokenizers

@testable import CoreAILanguageModels

// MARK: - InferenceOutput Tests

@Suite("InferenceOutput")
struct InferenceOutputTests {
    @Test("Init with token only")
    func initTokenOnly() {
        let output = InferenceOutput(tokenId: 42)
        #expect(output.tokenId == 42)
        #expect(output.logits == nil)
    }

    @Test("Init with token and logits")
    func initWithLogits() {
        let logits: [Float16] = [1.0, 2.0, 3.0]
        let output = InferenceOutput(tokenId: 7, logits: logits)
        #expect(output.tokenId == 7)
        #expect(output.logits?.count == 3)
    }
}

// MARK: - InferenceOptions Tests

@Suite("InferenceOptions")
struct InferenceOptionsTests {
    @Test("Default options: no maxTokens, no logits")
    func defaultOptions() {
        let opts = InferenceOptions()
        #expect(opts.maxTokens == nil)
        #expect(opts.includeLogits == false)
    }

    @Test("Custom options")
    func customOptions() {
        let opts = InferenceOptions(maxTokens: 50, includeLogits: true)
        #expect(opts.maxTokens == 50)
        #expect(opts.includeLogits == true)
    }
}

// MARK: - generate() Default Extension Tests

@Suite("InferenceEngine.generate() default extension")
struct GenerateDefaultExtensionTests {
    @Test("generate() yields correct number of tokens via maxTokens")
    func generatesCorrectTokenCount() async throws {
        let engine = MockEngine(tokens: [10, 20, 30])

        var outputs: [InferenceOutput] = []
        let generation = InferenceOptions(maxTokens: 5)
        for try await output in try engine.generate(
            with: [1, 2, 3],
            samplingConfiguration: SamplingConfiguration.greedy,
            inferenceOptions: generation
        ) {
            outputs.append(output)
        }

        #expect(outputs.count == 5)
        // Tokens cycle: 10, 20, 30, 10, 20
        #expect(outputs[0].tokenId == 10)
        #expect(outputs[1].tokenId == 20)
        #expect(outputs[2].tokenId == 30)
        #expect(outputs[3].tokenId == 10)
        #expect(outputs[4].tokenId == 20)
    }

    @Test("generate() returns nil logits when includeLogits is false")
    func noLogitsWhenNotRequested() async throws {
        let engine = MockEngine(tokens: [42])

        let generation = InferenceOptions(maxTokens: 1, includeLogits: false)
        for try await output in try engine.generate(
            with: [1],
            samplingConfiguration: SamplingConfiguration.greedy,
            inferenceOptions: generation
        ) {
            #expect(output.logits == nil)
        }
    }

    @Test("generate() returns logits when includeLogits is true")
    func logitsWhenRequested() async throws {
        let engine = MockEngine(tokens: [42], vocabSize: 50)

        let generation = InferenceOptions(maxTokens: 1, includeLogits: true)
        for try await output in try engine.generate(
            with: [1],
            samplingConfiguration: SamplingConfiguration.greedy,
            inferenceOptions: generation
        ) {
            #expect(output.logits != nil)
            #expect(output.logits?.count == 50)
        }
    }

    @Test("generate() logits have high probability on target token")
    func logitsHighProbOnTarget() async throws {
        let engine = MockEngine(tokens: [5], vocabSize: 10)

        let generation = InferenceOptions(maxTokens: 1, includeLogits: true)
        for try await output in try engine.generate(
            with: [1],
            samplingConfiguration: SamplingConfiguration.greedy,
            inferenceOptions: generation
        ) {
            guard let logits = output.logits else {
                Issue.record("Expected logits")
                return
            }
            // Token 5 should have the highest logit value
            let maxIdx = logits.enumerated().max(by: { $0.element < $1.element })?.offset
            #expect(maxIdx == 5)
        }
    }

    @Test("generate() returns nil logits when vocabSize is nil")
    func noLogitsWhenVocabSizeNil() async throws {
        let engine = MockEngine(tokens: [42], vocabSize: nil)

        let generation = InferenceOptions(maxTokens: 1, includeLogits: true)
        for try await output in try engine.generate(
            with: [1],
            samplingConfiguration: SamplingConfiguration.greedy,
            inferenceOptions: generation
        ) {
            #expect(output.logits == nil)
        }
    }

    @Test("generate() respects maxContextLength")
    func respectsMaxContextLength() async throws {
        // Engine with maxContextLength=5, prompt of 3 tokens → can generate max 2
        let engine = MockEngine(tokens: [10, 20, 30], maxContextLength: 5)

        var count = 0
        let generation = InferenceOptions(maxTokens: 100)  // Request way more than available
        for try await _ in try engine.generate(
            with: [1, 2, 3],  // 3 tokens prompt
            samplingConfiguration: SamplingConfiguration.greedy,
            inferenceOptions: generation
        ) {
            count += 1
        }

        #expect(count == 2)  // Only 2 slots left (5 - 3)
    }

    @Test("generate() with nil maxTokens uses maxContextLength")
    func nilMaxTokensUsesContextLength() async throws {
        let engine = MockEngine(tokens: [10], maxContextLength: 6)

        var count = 0
        let generation = InferenceOptions()  // nil maxTokens
        for try await _ in try engine.generate(
            with: [1, 2, 3],  // 3 tokens prompt
            samplingConfiguration: SamplingConfiguration.greedy,
            inferenceOptions: generation
        ) {
            count += 1
        }

        #expect(count == 3)  // 6 - 3 = 3 available slots
    }

    @Test("reset() clears state")
    func resetClearsState() async throws {
        let engine = MockEngine(tokens: [10])

        // Generate a token to advance state
        for try await _ in try engine.generate(
            with: [1],
            samplingConfiguration: SamplingConfiguration.greedy,
            inferenceOptions: InferenceOptions(maxTokens: 1)
        ) {}

        #expect(engine.inferenceCallCount == 1)

        try await engine.reset()
        #expect(engine.resetCalled == true)
        #expect(engine.inferenceCallCount == 0)
    }
}

// MARK: - Multi-turn + Guided Generation Pattern Tests

@Suite("generate() multi-call patterns")
struct GenerateMultiCallTests {
    @Test("Multi-turn: repeated generate(maxTokens:1) with growing input doesn't deadlock")
    func multiTurnSingleTokenCalls() async throws {
        let engine = MockEngine(tokens: [10, 20, 30, 40, 50], maxContextLength: 100)

        var tokens: [Int32] = [1, 2, 3]  // initial prompt

        // Simulate guided-generation pattern: call generate(maxTokens:1) repeatedly
        for _ in 0..<20 {
            var got: InferenceOutput?
            for try await output in try engine.generate(
                with: tokens,
                samplingConfiguration: .greedy,
                inferenceOptions: InferenceOptions(maxTokens: 1, includeLogits: true)
            ) {
                got = output
                break  // Only consume 1 token (GG pattern)
            }
            guard let output = got else { break }
            tokens.append(output.tokenId)
        }

        // Should have generated 20 tokens without deadlock/crash
        #expect(tokens.count == 23)  // 3 prompt + 20 generated
    }

    @Test("Multi-turn: generate → reset → generate cycle")
    func multiTurnWithReset() async throws {
        let engine = MockEngine(tokens: [10, 20, 30], maxContextLength: 50)

        // Turn 1
        var count1 = 0
        for try await _ in try engine.generate(
            with: [1, 2, 3],
            samplingConfiguration: .greedy,
            inferenceOptions: InferenceOptions(maxTokens: 5)
        ) {
            count1 += 1
        }
        #expect(count1 == 5)

        // Reset between turns
        try await engine.reset()

        // Turn 2
        var count2 = 0
        for try await _ in try engine.generate(
            with: [4, 5, 6],
            samplingConfiguration: .greedy,
            inferenceOptions: InferenceOptions(maxTokens: 3)
        ) {
            count2 += 1
        }
        #expect(count2 == 3)
    }

    @Test("forcedContinuation: produces exact forced tokens with logits")
    func forcedContinuationWithLogits() async throws {
        let engine = MockEngine(tokens: [99, 99, 99], vocabSize: 50)
        let forced: [Int32] = [7, 8, 9]

        var outputs: [InferenceOutput] = []
        for try await output in try engine.generate(
            with: [1, 2, 3],
            samplingConfiguration: .greedy,
            inferenceOptions: InferenceOptions(
                includeLogits: true,
                forcedContinuation: forced
            )
        ) {
            outputs.append(output)
        }

        #expect(outputs.count == 3)
        #expect(outputs.map(\.tokenId) == forced)
        #expect(outputs.allSatisfy { $0.logits != nil })
    }

    @Test("forcedContinuation: empty array produces zero tokens")
    func forcedContinuationEmpty() async throws {
        let engine = MockEngine(tokens: [10, 20])

        var count = 0
        for try await _ in try engine.generate(
            with: [1],
            samplingConfiguration: .greedy,
            inferenceOptions: InferenceOptions(forcedContinuation: [])
        ) {
            count += 1
        }
        #expect(count == 0)
    }
}
