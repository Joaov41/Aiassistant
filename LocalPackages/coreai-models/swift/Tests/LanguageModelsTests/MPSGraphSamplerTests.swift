// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import Foundation
import Metal
import TestUtilities
import Testing

@testable import CoreAILanguageModels

/// MPSGraphArgmaxSampler Tests - validates the MPSGraph-based argmax used in V2 pipelined inference.
///
/// Essential coverage:
/// 1. Basic correctness - finds max at arbitrary position
/// 2. Large vocab (150K) - production scenario
/// 3. Offset handling - prefill scenario with queryLength > 1
/// 4. Performance - ensures sampler stays under 1ms
@Suite("MPSGraph Argmax Sampler Tests", .enabled(if: !CIEnvironment.isVM))
struct MPSGraphArgmaxSamplerTests {
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    static let vocabSize32K = 32000
    static let vocabSize150K = 151936  // Qwen vocab size

    @Test("Argmax finds correct maximum")
    func argmaxCorrectness() async throws {
        let device = try #require(Self.device)
        let sampler = try MPSGraphArgmaxSampler(device: device, vocabSize: Self.vocabSize32K)

        let targetIndex = 12345
        let logitsBuffer = try #require(device.makeBuffer(length: Self.vocabSize32K * 2, options: .storageModeShared))
        let outputBuffer = try #require(device.makeBuffer(length: 4, options: .storageModeShared))

        let logitsPtr = logitsBuffer.contents().assumingMemoryBound(to: Float16.self)
        for i in 0..<Self.vocabSize32K {
            logitsPtr[i] = Float16(i == targetIndex ? 100.0 : Float.random(in: -10.0..<10.0))
        }

        let queue = try #require(device.makeCommandQueue())

        await withCheckedContinuation { continuation in
            sampler.encode(
                to: queue,
                logitsBuffer: logitsBuffer,
                logitsOffset: 0,
                outputBuffer: outputBuffer,
                outputOffset: 0,
                completion: { _ in
                    continuation.resume()
                }
            )
        }

        let result = outputBuffer.contents().assumingMemoryBound(to: Int32.self).pointee
        #expect(result == Int32(targetIndex), "Expected \(targetIndex), got \(result)")
    }

    @Test("Argmax with large vocabulary (150K tokens)")
    func argmaxLargeVocab() async throws {
        let device = try #require(Self.device)
        let sampler = try MPSGraphArgmaxSampler(device: device, vocabSize: Self.vocabSize150K)

        let targetIndex = 100000
        let logitsBuffer = try #require(device.makeBuffer(length: Self.vocabSize150K * 2, options: .storageModeShared))
        let outputBuffer = try #require(device.makeBuffer(length: 4, options: .storageModeShared))

        let logitsPtr = logitsBuffer.contents().assumingMemoryBound(to: Float16.self)
        for i in 0..<Self.vocabSize150K {
            logitsPtr[i] = Float16(i == targetIndex ? 50.0 : -50.0)
        }

        let queue = try #require(device.makeCommandQueue())

        await withCheckedContinuation { continuation in
            sampler.encode(
                to: queue,
                logitsBuffer: logitsBuffer,
                logitsOffset: 0,
                outputBuffer: outputBuffer,
                outputOffset: 0,
                completion: { _ in
                    continuation.resume()
                }
            )
        }

        let result = outputBuffer.contents().assumingMemoryBound(to: Int32.self).pointee
        #expect(result == Int32(targetIndex), "Expected \(targetIndex), got \(result)")
    }

    @Test("Argmax with slice (prefill scenario)")
    func argmaxWithSlice() async throws {
        let device = try #require(Self.device)
        let sampler = try MPSGraphArgmaxSampler(device: device, vocabSize: Self.vocabSize32K)

        let queryLength = 128  // Typical prefill length
        let targetIndex = 15000
        let totalElements = queryLength * Self.vocabSize32K
        let logitsBuffer = try #require(device.makeBuffer(length: totalElements * 2, options: .storageModeShared))
        let outputBuffer = try #require(device.makeBuffer(length: 4, options: .storageModeShared))

        let logitsPtr = logitsBuffer.contents().assumingMemoryBound(to: Float16.self)
        for i in 0..<totalElements {
            logitsPtr[i] = Float16(-100.0)
        }
        // Set max in LAST token's logits (that's what we sample from)
        let lastTokenOffset = (queryLength - 1) * Self.vocabSize32K
        logitsPtr[lastTokenOffset + targetIndex] = Float16(100.0)

        let queue = try #require(device.makeCommandQueue())

        await withCheckedContinuation { continuation in
            sampler.encodeWithSlice(
                to: queue,
                logitsBuffer: logitsBuffer,
                queryLength: queryLength,
                outputBuffer: outputBuffer,
                outputOffset: 0,
                completion: { _ in
                    continuation.resume()
                }
            )
        }

        let result = outputBuffer.contents().assumingMemoryBound(to: Int32.self).pointee
        #expect(result == Int32(targetIndex), "Expected \(targetIndex), got \(result)")
    }

    @Test("Argmax latency under 1ms for 150K vocab")
    func argmaxPerformance() async throws {
        let device = try #require(Self.device)
        let sampler = try MPSGraphArgmaxSampler(device: device, vocabSize: Self.vocabSize150K)

        let logitsBuffer = try #require(device.makeBuffer(length: Self.vocabSize150K * 2, options: .storageModeShared))
        let outputBuffer = try #require(device.makeBuffer(length: 4, options: .storageModeShared))

        let queue = try #require(device.makeCommandQueue())

        // Warm up
        for _ in 0..<10 {
            await withCheckedContinuation { continuation in
                sampler.encode(
                    to: queue,
                    logitsBuffer: logitsBuffer,
                    logitsOffset: 0,
                    outputBuffer: outputBuffer,
                    outputOffset: 0,
                    completion: { _ in
                        continuation.resume()
                    }
                )
            }
        }

        // Measure
        let iterations = 100
        let start = SuspendingClock().now
        for _ in 0..<iterations {
            await withCheckedContinuation { continuation in
                sampler.encode(
                    to: queue,
                    logitsBuffer: logitsBuffer,
                    logitsOffset: 0,
                    outputBuffer: outputBuffer,
                    outputOffset: 0,
                    completion: { _ in
                        continuation.resume()
                    }
                )
            }
        }
        let avgLatencyMs = (SuspendingClock().now - start).inMilliseconds / Double(iterations)

        print("MPSGraph Argmax latency: \(String(format: "%.3f", avgLatencyMs)) ms")

        // Use higher threshold on VM due to virtualization overhead
        let threshold = CIEnvironment.isVM ? 100.0 : 1.0
        #expect(
            avgLatencyMs < threshold,
            "Argmax too slow: \(avgLatencyMs) ms (threshold: \(threshold) ms, VM: \(CIEnvironment.isVM))")
    }

    @Test("Argmax handles edge cases - first and last index")
    func argmaxEdgeCases() async throws {
        let device = try #require(Self.device)
        let sampler = try MPSGraphArgmaxSampler(device: device, vocabSize: Self.vocabSize32K)

        let logitsBuffer = try #require(device.makeBuffer(length: Self.vocabSize32K * 2, options: .storageModeShared))
        let outputBuffer = try #require(device.makeBuffer(length: 4, options: .storageModeShared))
        let queue = try #require(device.makeCommandQueue())

        // Test first index (0)
        let logitsPtr = logitsBuffer.contents().assumingMemoryBound(to: Float16.self)
        for i in 0..<Self.vocabSize32K {
            logitsPtr[i] = Float16(i == 0 ? 100.0 : -100.0)
        }

        await withCheckedContinuation { continuation in
            sampler.encode(
                to: queue,
                logitsBuffer: logitsBuffer,
                logitsOffset: 0,
                outputBuffer: outputBuffer,
                outputOffset: 0,
                completion: { _ in
                    continuation.resume()
                }
            )
        }

        var result = outputBuffer.contents().assumingMemoryBound(to: Int32.self).pointee
        #expect(result == 0, "Expected 0, got \(result)")

        // Test last index (vocabSize - 1)
        for i in 0..<Self.vocabSize32K {
            logitsPtr[i] = Float16(i == Self.vocabSize32K - 1 ? 100.0 : -100.0)
        }

        await withCheckedContinuation { continuation in
            sampler.encode(
                to: queue,
                logitsBuffer: logitsBuffer,
                logitsOffset: 0,
                outputBuffer: outputBuffer,
                outputOffset: 0,
                completion: { _ in
                    continuation.resume()
                }
            )
        }

        result = outputBuffer.contents().assumingMemoryBound(to: Int32.self).pointee
        #expect(result == Int32(Self.vocabSize32K - 1), "Expected \(Self.vocabSize32K - 1), got \(result)")
    }
}

// MARK: - MPSGraph Top-K Sampler Tests

@Suite("MPSGraph Top-K Sampler Tests", .enabled(if: !CIEnvironment.isVM))
struct MPSGraphTopKSamplerTests {
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    static let vocabSize = 32000
    static let k = 40

    @Test("Top-K samples from high-probability tokens")
    func topKSamplesCorrectly() async throws {
        let device = try #require(Self.device)
        // Create sampler with temperature=1.0 (neutral)
        let sampler = try MPSGraphTopKSampler(device: device, vocabSize: Self.vocabSize, k: Self.k, temperature: 1.0)

        let logitsBuffer = try #require(device.makeBuffer(length: Self.vocabSize * 2, options: .storageModeShared))
        let outputBuffer = try #require(device.makeBuffer(length: 4, options: .storageModeShared))

        // Create logits where only a few tokens have high probability
        let logitsPtr = logitsBuffer.contents().assumingMemoryBound(to: Float16.self)
        for i in 0..<Self.vocabSize {
            logitsPtr[i] = Float16(-100.0)  // Very low probability
        }

        // Set a few high-probability tokens (these should be selected)
        let highProbTokens = [100, 200, 300, 400, 500]
        for token in highProbTokens {
            logitsPtr[token] = Float16(10.0)
        }

        let queue = try #require(device.makeCommandQueue())

        // Sample multiple times and verify we only get high-prob tokens
        var sampledTokens = Set<Int32>()
        for _ in 0..<20 {
            await withCheckedContinuation { continuation in
                sampler.encode(
                    to: queue,
                    logitsBuffer: logitsBuffer,
                    logitsOffset: 0,
                    outputBuffer: outputBuffer,
                    outputOffset: 0,
                    completion: { _ in
                        continuation.resume()
                    }
                )
            }

            let result = outputBuffer.contents().assumingMemoryBound(to: Int32.self).pointee
            sampledTokens.insert(result)
        }

        // All sampled tokens should be from the high-probability set
        for token in sampledTokens {
            #expect(highProbTokens.contains(Int(token)), "Unexpected token \(token) sampled")
        }
    }

    @Test("Top-K with low temperature concentrates probability (deterministic)")
    func topKLowTemperature() async throws {
        let device = try #require(Self.device)
        // Create sampler with very low temperature (0.1) - concentrates probability
        let sampler = try MPSGraphTopKSampler(device: device, vocabSize: Self.vocabSize, k: Self.k, temperature: 0.1)

        let logitsBuffer = try #require(device.makeBuffer(length: Self.vocabSize * 2, options: .storageModeShared))
        let outputBuffer = try #require(device.makeBuffer(length: 4, options: .storageModeShared))

        let logitsPtr = logitsBuffer.contents().assumingMemoryBound(to: Float16.self)
        for i in 0..<Self.vocabSize {
            logitsPtr[i] = Float16(-100.0)
        }

        // One token is much higher than others
        let topToken = 12345
        logitsPtr[topToken] = Float16(100.0)
        logitsPtr[topToken + 1] = Float16(9.9)  // Much lower
        logitsPtr[topToken + 2] = Float16(9.8)

        let queue = try #require(device.makeCommandQueue())

        // Use deterministic random = 0.5 (middle of distribution)
        // With low temperature and dominant logit, cumsum should exceed 0.5 at first token
        sampler.testingOnlyRandomOverride = 0.5

        await withCheckedContinuation { continuation in
            sampler.encode(
                to: queue,
                logitsBuffer: logitsBuffer,
                logitsOffset: 0,
                outputBuffer: outputBuffer,
                outputOffset: 0,
                completion: { _ in
                    continuation.resume()
                }
            )
        }

        let result = outputBuffer.contents().assumingMemoryBound(to: Int32.self).pointee
        #expect(result == Int32(topToken), "Low temperature with dominant logit should pick top token, got \(result)")

        // Reset for other tests
        sampler.testingOnlyRandomOverride = nil
    }

    @Test("Top-K with different random values selects different tokens (deterministic)")
    func topKHighTemperature() async throws {
        let device = try #require(Self.device)
        // Create sampler with neutral temperature (1.0)
        let sampler = try MPSGraphTopKSampler(device: device, vocabSize: Self.vocabSize, k: Self.k, temperature: 1.0)

        let logitsBuffer = try #require(device.makeBuffer(length: Self.vocabSize * 2, options: .storageModeShared))
        let outputBuffer = try #require(device.makeBuffer(length: 4, options: .storageModeShared))

        let logitsPtr = logitsBuffer.contents().assumingMemoryBound(to: Float16.self)
        for i in 0..<Self.vocabSize {
            logitsPtr[i] = Float16(-100.0)
        }

        // Several tokens with similar probabilities
        let similarTokens = [100, 101, 102, 103, 104, 105, 106, 107, 108, 109]
        for token in similarTokens {
            logitsPtr[token] = Float16(10.0)
        }

        let queue = try #require(device.makeCommandQueue())

        // Test with deterministic random values across the distribution
        var sampledTokens = Set<Int32>()
        let randomValues: [Float] = [0.05, 0.15, 0.25, 0.35, 0.45, 0.55, 0.65, 0.75, 0.85, 0.95]

        for randomValue in randomValues {
            sampler.testingOnlyRandomOverride = randomValue

            await withCheckedContinuation { continuation in
                sampler.encode(
                    to: queue,
                    logitsBuffer: logitsBuffer,
                    logitsOffset: 0,
                    outputBuffer: outputBuffer,
                    outputOffset: 0,
                    completion: { _ in
                        continuation.resume()
                    }
                )
            }

            let result = outputBuffer.contents().assumingMemoryBound(to: Int32.self).pointee
            sampledTokens.insert(result)
        }

        // With 10 equal-probability tokens and 10 evenly spaced random values,
        // we should get multiple different tokens
        #expect(
            sampledTokens.count >= 3,
            "Different random values should produce different tokens, got \(sampledTokens.count) unique")

        // All sampled tokens should be from our high-probability set
        for token in sampledTokens {
            #expect(similarTokens.contains(Int(token)), "Unexpected token \(token) not in high-probability set")
        }

        // Reset
        sampler.testingOnlyRandomOverride = nil
    }

    @Test("Top-K latency under 2ms for 32K vocab")
    func topKPerformance() async throws {
        let device = try #require(Self.device)
        // Create sampler with temperature=1.0
        let sampler = try MPSGraphTopKSampler(device: device, vocabSize: Self.vocabSize, k: Self.k, temperature: 1.0)

        let logitsBuffer = try #require(device.makeBuffer(length: Self.vocabSize * 2, options: .storageModeShared))
        let outputBuffer = try #require(device.makeBuffer(length: 4, options: .storageModeShared))

        let queue = try #require(device.makeCommandQueue())

        // Warm up
        for _ in 0..<10 {
            await withCheckedContinuation { continuation in
                sampler.encode(
                    to: queue,
                    logitsBuffer: logitsBuffer,
                    logitsOffset: 0,
                    outputBuffer: outputBuffer,
                    outputOffset: 0,
                    completion: { _ in
                        continuation.resume()
                    }
                )
            }
        }

        // Measure
        let iterations = 100
        let start = SuspendingClock().now
        for _ in 0..<iterations {
            await withCheckedContinuation { continuation in
                sampler.encode(
                    to: queue,
                    logitsBuffer: logitsBuffer,
                    logitsOffset: 0,
                    outputBuffer: outputBuffer,
                    outputOffset: 0,
                    completion: { _ in
                        continuation.resume()
                    }
                )
            }
        }
        let avgLatencyMs = (SuspendingClock().now - start).inMilliseconds / Double(iterations)

        print("MPSGraph Top-K latency: \(String(format: "%.3f", avgLatencyMs)) ms")

        // Use higher threshold on VM due to virtualization overhead
        let threshold = CIEnvironment.isVM ? 100.0 : 2.0
        #expect(
            avgLatencyMs < threshold,
            "Top-K too slow: \(avgLatencyMs) ms (threshold: \(threshold) ms, VM: \(CIEnvironment.isVM))")
    }

    @Test("Top-K with slice (prefill scenario)")
    func topKWithSlice() async throws {
        let device = try #require(Self.device)
        let sampler = try MPSGraphTopKSampler(device: device, vocabSize: Self.vocabSize, k: Self.k, temperature: 1.0)

        let queryLength = 128  // Typical prefill length
        let targetToken = 15000
        let totalElements = queryLength * Self.vocabSize
        let logitsBuffer = try #require(device.makeBuffer(length: totalElements * 2, options: .storageModeShared))
        let outputBuffer = try #require(device.makeBuffer(length: 4, options: .storageModeShared))

        let logitsPtr = logitsBuffer.contents().assumingMemoryBound(to: Float16.self)
        // Fill with very low values
        for i in 0..<totalElements {
            logitsPtr[i] = Float16(-100.0)
        }
        // Set very high value in LAST token's logits at targetToken position
        let lastTokenOffset = (queryLength - 1) * Self.vocabSize
        logitsPtr[lastTokenOffset + targetToken] = Float16(100.0)

        let queue = try #require(device.makeCommandQueue())

        // Use deterministic random value that should select the dominant token
        sampler.testingOnlyRandomOverride = 0.5

        await withCheckedContinuation { continuation in
            sampler.encodeWithSlice(
                to: queue,
                logitsBuffer: logitsBuffer,
                queryLength: queryLength,
                outputBuffer: outputBuffer,
                outputOffset: 0,
                completion: { _ in
                    continuation.resume()
                }
            )
        }

        let result = outputBuffer.contents().assumingMemoryBound(to: Int32.self).pointee
        #expect(result == Int32(targetToken), "Expected \(targetToken), got \(result)")

        sampler.testingOnlyRandomOverride = nil
    }
}
