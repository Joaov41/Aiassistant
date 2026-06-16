// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import CoreAI
import CoreAIShared
import Foundation
import Metal
import MetalPerformanceShaders
import Synchronization
import os

// MARK: - Timing

private func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = ContinuousClock.now - start
    let (secs, attoseconds) = duration.components
    return (Double(secs) + Double(attoseconds) / 1e18) * 1000.0
}

// MARK: - Constants

private let averageExpectedPromptSize = 256
private let temperatureTolerance: Double = 0.001

// MARK: - Core AI Pipelined Engine (Public Wrapper)

/// GPU-pipelined inference engine using Core AI's encode API.
///
/// Key features:
/// - Non-blocking GPU encoding via `InferenceFunction.encode`
/// - GPU-direct token sampling (argmax/topK) via MPSGraph compute shaders
/// - Double-buffered cache positions for CPU/GPU overlap
/// - Growing KV cache with pipelined expansion
/// - All tensors are owned MTLBuffers — Core AI never allocates/frees them
final class CoreAIPipelinedEngine: InferenceEngine, Sendable {
    typealias ConfigType = ModelConfig

    nonisolated(unsafe) private var engine: EngineImpl
    private let engineInUse = Atomic<Bool>(false)
    let config: ModelConfig

    // Generation lifecycle
    private let _activeToken = Mutex<GenerationToken?>(nil)
    private let _generationTask = Mutex<Task<Void, Never>?>(nil)

    var isBusy: Bool { _activeToken.withLock { $0 != nil } }

    init(
        config: ModelConfig,
        preparedModel: PreparedModel,
        options: EngineOptions = EngineOptions()
    ) async throws {
        let engine = try await EngineImpl(
            config: config, preparedModel: preparedModel, options: options)
        self.engine = engine
        self.config = config
    }

    /// Atomically claim exclusive use of `engine`.
    ///
    /// Traps on contention. Callers must guarantee single-ownership.
    private func acquireEngine() {
        let (exchanged, _) = engineInUse.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiring
        )
        guard exchanged else {
            fatalError("Trying to acquire engine when it's already in use")
        }
    }

    /// Try to claim exclusive use of `engine` without trapping.
    ///
    /// Returns `true` if the caller now holds it (and must call `releaseEngine`), `false` if
    /// another caller holds it.
    private func tryAcquireEngine() -> Bool {
        let (exchanged, _) = engineInUse.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiring
        )
        return exchanged
    }

    private func releaseEngine() {
        engineInUse.store(false, ordering: .releasing)
    }

    func generate(
        with input: [TokenId],
        samplingConfiguration: SamplingConfiguration,
        inferenceOptions: InferenceOptions
    ) throws -> GenerationSequence {
        if inferenceOptions.includeLogits {
            throw InferenceRuntimeError.invalidArgument(
                "CoreAI pipelined engine does not support logits (GPU-side sampling). "
                    + "Use a sequential engine for constrained generation or evaluation."
            )
        }
        if inferenceOptions.forcedContinuation != nil {
            throw InferenceRuntimeError.invalidArgument(
                "CoreAI pipelined engine does not support forcedContinuation (GPU-side sampling). "
                    + "Use a sequential engine for evaluation."
            )
        }
        let maxTokens = inferenceOptions.maxTokens
        let stopReasonStore = StopReasonStore()
        let (base, outputContinuation) =
            AsyncThrowingStream<InferenceOutput, any Error>.makeStream()

        let token = GenerationToken()
        _activeToken.withLock { $0 = token }

        let task = Task {
            self.acquireEngine()
            defer {
                self.releaseEngine()
                // Only clear if this generation still owns both slots
                if self._activeToken.withLock({ $0 === token }) {
                    self._activeToken.withLock { $0 = nil }
                    self._generationTask.withLock { $0 = nil }
                }
            }
            do {
                let (tokenStream, tokenContinuation) =
                    AsyncThrowingStream<InferenceEngine.TokenId, any Error>.makeStream()

                async let forwarding: Void = {
                    do {
                        for try await token in tokenStream {
                            outputContinuation.yield(InferenceOutput(tokenId: token))
                        }
                    } catch {
                        outputContinuation.finish(throwing: error)
                    }
                }()

                try await self.engine.runCompletion(
                    prompt: input,
                    sampler: samplingConfiguration,
                    maxTokens: maxTokens,
                    yieldingTo: tokenContinuation
                )
                tokenContinuation.finish()
                await forwarding
                stopReasonStore.setIfUnset(.maxTokens)
                outputContinuation.finish()
            } catch is CancellationError {
                stopReasonStore.set(.cancelled)
                outputContinuation.finish()
            } catch {
                stopReasonStore.set(.error)
                outputContinuation.finish(throwing: error)
            }
        }
        _generationTask.withLock { $0 = task }
        return GenerationSequence(base: base, stopReasonStore: stopReasonStore)
    }

    /// Wait for any in-flight generate() Task to return the engine.
    private func drain() {
        var attempts = 0
        while engineInUse.load(ordering: .acquiring) {
            attempts += 1
            if attempts > 5000 {
                fatalError("Engine not returned after drain() — tokenSequence Task stuck?")
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    func cancel() async throws {
        let task: Task<Void, Never>? = _generationTask.withLock { task in
            task?.cancel()
            defer { task = nil }
            return task
        }
        _activeToken.withLock {
            $0?.cancel()
            $0 = nil
        }
        await task?.value
    }

    func reset() {
        drain()
        _activeToken.withLock {
            $0?.cancel()
            $0 = nil
        }
        _generationTask.withLock { $0 = nil }
        guard tryAcquireEngine() else { return }
        defer { releaseEngine() }
        engine.reset()
    }

    func cleanup() async throws {
        let cleanupSpan = InstrumentsProfiler.beginCleanup(engine: "CoreAI-Pipelined")
        if tryAcquireEngine() {
            let stream = engine.computeStream
            releaseEngine()
            await stream.currentWorkCompleted()
        }
        cleanupSpan.end()
    }

    func validateSamplingStrategy(_ config: SamplingConfiguration) throws {
        guard config.temperature > 0 else { return }
        if config.topP != nil {
            throw InferenceRuntimeError.invalidArgument(
                "CoreAI pipelined GPU sampler does not support topP. "
                    + "Only greedy (temperature=0) and temperature+topK are supported."
            )
        }
    }

    func warmup(queryLength: Int, sampling: SamplingConfiguration?) async throws {
        acquireEngine()
        defer { releaseEngine() }
        try await engine.performWarmup(queryLength: queryLength, samplingConfig: sampling)
    }
}

// MARK: - Pipeline Depth Gate

/// Bounds in-flight encode calls so MPSGraph's per-encode scratch
/// (sized by the graph's max shape — multiple GB on large models) can't accumulate.
///
/// Without this, the decode loop submits encodes (~220/s) faster than the
/// sampler callback drains them (~70/s); depth grows until
/// `MPSCommandBufferImageCache` fails to allocate another private MTLBuffer.
///
/// Capacity 3 covers {logits encode + sampler commit + optional KV-cache grow};
/// deeper queues only cost memory.
///
/// Class, not actor: `release()` runs synchronously from the Metal callback —
/// an actor would force `Task { await release() }` with ordering ambiguity.
/// `internal` (not `private`) so `PipelineGateTests` can reach it.
final class PipelineGate: Sendable {
    private struct State: Sendable {
        var inFlight: Int = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let capacity: Int
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// Take a slot; suspend if all slots are busy.
    func acquire() async {
        // Fast path: take a slot without suspending.
        let takenImmediately = state.withLock { state -> Bool in
            guard state.inFlight < capacity else { return false }
            state.inFlight += 1
            return true
        }
        if takenImmediately { return }

        // Slow path: enqueue a waiter. Re-check under the lock in case a slot
        // opened between the fast path and now.
        await withCheckedContinuation { cont in
            let runImmediately = state.withLock { state -> Bool in
                if state.inFlight < capacity {
                    state.inFlight += 1
                    return true
                }
                state.waiters.append(cont)
                return false
            }
            if runImmediately { cont.resume() }
        }
    }

    /// Give back a slot. Called from the sampler's GPU-completion callback on a
    /// Metal callback thread; resumes any pending waiter (slot transferred
    /// directly without decrementing `inFlight`) or decrements the count.
    ///
    /// The waiter is resumed *outside* the lock so a rescheduled task can't
    /// re-enter `acquire` while we still hold it.
    func release() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            if !state.waiters.isEmpty {
                // Slot transferred to the woken waiter — inFlight count unchanged.
                return state.waiters.removeFirst()
            }
            state.inFlight -= 1
            return nil
        }
        waiter?.resume()
    }

    // Test-only introspection. Kept as underscored names to discourage
    // production use; exercised by PipelineGateTests.

    var _inFlightForTesting: Int {
        state.withLock { $0.inFlight }
    }

    var _waitersForTesting: Int {
        state.withLock { $0.waiters.count }
    }
}

// MARK: - Extra Fixed-Shape States

/// A model state beyond the KV cache pair — e.g. the SSM conv/recurrent states of
/// hybrid-attention models (Qwen3.5 GatedDeltaNet). Unlike the KV cache these are
/// fixed-shape (they don't grow with context), so one owned buffer is bound to every
/// encode and zeroed on reset to start a fresh sequence.
private struct PipelinedExtraState {
    let name: String
    let buffer: MTLBuffer
    let scalarType: NDArray.ScalarType
    let shape: [Int]
    let strides: [Int]
}

// MARK: - Per-Token Inputs

/// A model input beyond `input_ids`/`position_ids` whose value depends on the token id of
/// the step being encoded — e.g. Gemma's per-layer-embedding rows, gathered by token id from
/// a host-side mmap table too large to live in the graph. The engine owns one buffer holding
/// `maxContextLength` per-step slots (slot index = token position, so in-flight prefill steps
/// each read a distinct region and host writes never race the GPU), fills the step's slot via
/// `EngineOptions.perTokenInputProvider`, and binds it as an additional input on every encode.
private struct PipelinedPerTokenInput {
    let name: String
    let buffer: MTLBuffer
    let scalarType: NDArray.ScalarType
    let shape: [Int]
    let strides: [Int]
    let stepByteCount: Int
}

// MARK: - Static Inputs

/// A model input bound to the SAME host buffer on every encode — e.g. a giant quantized
/// embedding table mmap'd from disk that the graph gathers from in-graph by token id
/// (Gemma 4's per-layer-embedding table as `ple_table`/`ple_scale` inputs). The buffer is
/// supplied by `EngineOptions.staticInputBuffers`, is never written, and imposes no per-step
/// host work — unlike per-token inputs there is no S=1 constraint and no decode-loop wait on
/// the sampled token, so the full pipeline depth survives.
private struct PipelinedStaticInput {
    let name: String
    let buffer: MTLBuffer
    let scalarType: NDArray.ScalarType
    let shape: [Int]
    let strides: [Int]
}

/// One-shot rendezvous between the sampler's GPU-completion callback (which learns the
/// sampled token on a Metal callback thread) and the decode loop (which must know that token
/// BEFORE it can gather per-token inputs for the next step). Either side may arrive first;
/// strict deliver/take alternation lets one instance be reused across steps.
final class TokenRendezvous: Sendable {
    private enum State {
        case idle
        case token(Int32)
        case waiter(CheckedContinuation<Int32, Never>)
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: .idle)

    /// Called from the sampler completion callback with the sampled token.
    func deliver(_ token: Int32) {
        let waiter = state.withLock { state -> CheckedContinuation<Int32, Never>? in
            switch state {
            case .waiter(let continuation):
                state = .idle
                return continuation
            default:
                state = .token(token)
                return nil
            }
        }
        waiter?.resume(returning: token)
    }

    /// Awaited by the encode loop after submitting the sampler for a step.
    func take() async -> Int32 {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Int32? in
                switch state {
                case .token(let token):
                    state = .idle
                    return token
                default:
                    state = .waiter(continuation)
                    return nil
                }
            }
            if let token = ready { continuation.resume(returning: token) }
        }
    }
}

// MARK: - Engine Implementation

private struct EngineImpl: ~Copyable {
    var vocabSize: Int { config.vocabSize }

    let config: ModelConfig
    let options: EngineOptions
    let function: InferenceFunction
    let pipelineQueue: MTLCommandQueue
    let computeStream: ComputeStream
    let device: MTLDevice

    // Descriptor metadata
    let inputIdsName: String
    let positionIdsName: String
    let keyCacheName: String
    let valueCacheName: String
    let logitsOutputName: String
    let keyCacheScalarType: NDArray.ScalarType
    let valueCacheScalarType: NDArray.ScalarType

    // Base descriptors for shape resolution (preferredStrides, not contiguous)
    let inputIdsBaseDesc: NDArrayDescriptor
    let positionIdsBaseDesc: NDArrayDescriptor
    let logitsBaseDesc: NDArrayDescriptor

    // Owned MTLBuffers
    var inputTokensBuffer: MTLBuffer
    var cachePositionBuffers: (MTLBuffer, MTLBuffer)

    // KV cache — reuses CoreAIKVCache protocol from KVCache+CoreAI.swift
    var kvCache: any CoreAIKVCache

    // Fixed-shape states beyond the KV pair (SSM conv/recurrent for hybrid models)
    let extraStates: [PipelinedExtraState]

    // Per-token inputs beyond input_ids/position_ids (host-gathered, e.g. Gemma PLE rows)
    let perTokenInputs: [PipelinedPerTokenInput]
    let perTokenInputProvider: PerTokenInputProvider?
    let sampledTokenRendezvous = TokenRendezvous()

    // Static inputs beyond input_ids/position_ids (same buffer every encode, e.g. mmap'd
    // gather tables — see PipelinedStaticInput)
    let staticInputs: [PipelinedStaticInput]

    // Logits — reuses GrowingLogitsBuffer from TensorStorage+CoreAI.swift
    var logits: GrowingLogitsBuffer

    // GPU sampler — reuses MPSGraphSampler from MPSGraphSamplers.swift
    var cachedSampler: (any MPSGraphSampler)?
    var cachedSamplerTemperature: Double?

    // State
    var processedTokenCount: Int = 0
    var step: Int = 0
    // Last GPU-sampled token, mirrored to the CPU only when per-token inputs need it
    // (the decode loop must gather the next step's rows for this token).
    var lastSampledToken: Int32? = nil

    // Backpressure gate — see PipelineGate doc-comment for the failure mode it prevents.
    // Capacity 3 covers {encode logits + sampler commit + optional KV-cache grow} in flight.
    let inFlightGate = PipelineGate(capacity: 3)

    // MARK: - Init

    init(
        config: ModelConfig,
        preparedModel: PreparedModel,
        options: EngineOptions = EngineOptions()
    ) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw InferenceRuntimeError.genericError("Failed to create Metal device")
        }

        let model = preparedModel.model

        // Get function descriptor
        guard let descriptor = model.functionDescriptor(for: config.function) else {
            throw InferenceRuntimeError.genericError(
                "Cannot find function '\(config.function)' in model")
        }

        // Validate: 2+ inputs (input_ids, position_ids, plus optional host-gathered
        // per-token inputs), 1+ output, 2+ states (KV cache pair, plus optional
        // fixed-shape extras such as the SSM conv/recurrent states of hybrid models)
        guard descriptor.inputNames.count >= 2 else {
            throw InferenceRuntimeError.invalidInputType(
                "Expected at least 2 inputs, got \(descriptor.inputNames.count): \(descriptor.inputNames)")
        }
        // Inputs beyond the first two are static (a buffer was supplied for the name in
        // EngineOptions.staticInputBuffers) or per-token (filled by the provider per step).
        let extraInputNames = Array(descriptor.inputNames.dropFirst(2))
        let staticInputNames = extraInputNames.filter { options.staticInputBuffers[$0] != nil }
        let perTokenInputNames = extraInputNames.filter { options.staticInputBuffers[$0] == nil }
        guard perTokenInputNames.count <= Self.maxPerTokenInputs else {
            throw InferenceRuntimeError.invalidInputType(
                "At most \(Self.maxPerTokenInputs) per-token inputs beyond input_ids/position_ids "
                    + "are supported, got \(perTokenInputNames.count): \(perTokenInputNames) "
                    + "(constant inputs can ride EngineOptions.staticInputBuffers instead)")
        }
        guard staticInputNames.count <= Self.maxStaticInputs else {
            throw InferenceRuntimeError.invalidInputType(
                "At most \(Self.maxStaticInputs) static inputs are supported, "
                    + "got \(staticInputNames.count): \(staticInputNames)")
        }
        guard descriptor.outputNames.count >= 1 else {
            throw InferenceRuntimeError.invalidOutputType(
                "Expected at least 1 output, got \(descriptor.outputNames.count)")
        }
        guard descriptor.stateNames.count >= 2 else {
            throw InferenceRuntimeError.invalidOutputType(
                "Expected at least 2 states (KV cache), got \(descriptor.stateNames.count): \(descriptor.stateNames)")
        }
        guard descriptor.stateNames.count - 2 <= Self.maxExtraStates else {
            throw InferenceRuntimeError.invalidOutputType(
                "At most \(Self.maxExtraStates) extra states beyond the KV pair are supported, "
                    + "got \(descriptor.stateNames.count - 2): \(descriptor.stateNames.dropFirst(2))")
        }

        // Extract names
        let inputIdsName = descriptor.inputNames[0]
        let positionIdsName = descriptor.inputNames[1]
        let keyCacheName = descriptor.stateNames[0]
        let valueCacheName = descriptor.stateNames[1]
        let logitsOutputName = descriptor.outputNames[0]

        // States beyond the KV pair must be fixed-shape; allocate one owned
        // zero-filled buffer each (they persist across steps, zeroed on reset).
        var extraStatesLocal: [PipelinedExtraState] = []
        for name in descriptor.stateNames.dropFirst(2) {
            guard case .ndArray(let desc) = descriptor.stateDescriptor(of: name) else {
                throw InferenceRuntimeError.invalidOutputType(
                    "Cannot get descriptor for extra state '\(name)'")
            }
            guard !desc.shape.contains(where: { $0 < 0 }) else {
                throw InferenceRuntimeError.invalidOutputType(
                    "Extra state '\(name)' has dynamic dims \(desc.shape) — only the first two "
                        + "states (KV cache) may be dynamic in the pipelined engine")
            }
            let resolved = desc.resolvingDynamicDimensions(desc.shape)
            let byteCount = resolved.minimumByteCount
            guard let buf = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
                throw InferenceRuntimeError.bufferAllocationFailed(
                    "extra state '\(name)' (\(byteCount) bytes)")
            }
            memset(buf.contents(), 0, byteCount)
            extraStatesLocal.append(
                PipelinedExtraState(
                    name: name,
                    buffer: buf,
                    scalarType: desc.scalarType,
                    shape: desc.shape,
                    strides: resolved.preferredStrides
                ))
        }
        if !extraStatesLocal.isEmpty {
            CLILogger.log(
                "Pipelined engine carrying \(extraStatesLocal.count) fixed-shape extra state(s): "
                    + extraStatesLocal.map(\.name).joined(separator: ", "))
        }

        // Static inputs: the caller-supplied buffer is bound unchanged on every encode.
        var staticInputsLocal: [PipelinedStaticInput] = []
        for name in staticInputNames {
            guard case .ndArray(let desc) = descriptor.inputDescriptor(of: name) else {
                throw InferenceRuntimeError.invalidInputType(
                    "Cannot get descriptor for static input '\(name)'")
            }
            guard !desc.shape.contains(where: { $0 < 0 }) else {
                throw InferenceRuntimeError.invalidInputType(
                    "Static input '\(name)' has dynamic dims \(desc.shape) — static inputs "
                        + "must be fixed-shape")
            }
            let resolved = desc.resolvingDynamicDimensions(desc.shape)
            let buffer = options.staticInputBuffers[name]!.buffer
            guard buffer.length >= resolved.minimumByteCount else {
                throw InferenceRuntimeError.invalidInputType(
                    "Static input '\(name)' needs \(resolved.minimumByteCount) bytes but the "
                        + "supplied buffer holds \(buffer.length)")
            }
            staticInputsLocal.append(
                PipelinedStaticInput(
                    name: name,
                    buffer: buffer,
                    scalarType: desc.scalarType,
                    shape: desc.shape,
                    strides: resolved.preferredStrides
                ))
        }
        if !staticInputsLocal.isEmpty {
            let fmt = ByteCountFormatter()
            fmt.countStyle = .memory
            let total = staticInputsLocal.reduce(0) { $0 + $1.buffer.length }
            CLILogger.log(
                "Pipelined engine carrying \(staticInputsLocal.count) static input(s): "
                    + staticInputsLocal.map(\.name).joined(separator: ", ")
                    + " (\(fmt.string(fromByteCount: Int64(total))) bound per encode)")
        }

        // Per-token inputs: fixed-shape, filled by the host provider once per step.
        // One owned buffer holds maxContextLength slots (slot = token position) so
        // in-flight steps read disjoint regions.
        var perTokenInputsLocal: [PipelinedPerTokenInput] = []
        for name in perTokenInputNames {
            guard case .ndArray(let desc) = descriptor.inputDescriptor(of: name) else {
                throw InferenceRuntimeError.invalidInputType(
                    "Cannot get descriptor for per-token input '\(name)'")
            }
            guard !desc.shape.contains(where: { $0 < 0 }) else {
                throw InferenceRuntimeError.invalidInputType(
                    "Per-token input '\(name)' has dynamic dims \(desc.shape) — per-token inputs "
                        + "must be fixed-shape (S=1)")
            }
            let resolved = desc.resolvingDynamicDimensions(desc.shape)
            let stepByteCount = resolved.minimumByteCount
            let byteCount = config.maxContextLength * stepByteCount
            guard let buf = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
                throw InferenceRuntimeError.bufferAllocationFailed(
                    "per-token input '\(name)' (\(byteCount) bytes)")
            }
            memset(buf.contents(), 0, byteCount)
            perTokenInputsLocal.append(
                PipelinedPerTokenInput(
                    name: name,
                    buffer: buf,
                    scalarType: desc.scalarType,
                    shape: desc.shape,
                    strides: resolved.preferredStrides,
                    stepByteCount: stepByteCount
                ))
        }
        if !perTokenInputsLocal.isEmpty {
            guard options.perTokenInputProvider != nil else {
                throw InferenceRuntimeError.invalidInputType(
                    "Model declares per-token input(s) "
                        + perTokenInputsLocal.map(\.name).joined(separator: ", ")
                        + " but EngineOptions.perTokenInputProvider is nil — set a provider "
                        + "that gathers the rows for each token id")
            }
            let fmt = ByteCountFormatter()
            fmt.countStyle = .memory
            let total = perTokenInputsLocal.reduce(0) { $0 + $1.buffer.length }
            CLILogger.log(
                "Pipelined engine carrying \(perTokenInputsLocal.count) per-token input(s): "
                    + perTokenInputsLocal.map(\.name).joined(separator: ", ")
                    + " (\(fmt.string(fromByteCount: Int64(total))) slots)")
        }

        // Extract state descriptors for KV cache shape/type
        guard case .ndArray(let keyCacheDesc) = descriptor.stateDescriptor(of: keyCacheName),
            case .ndArray(let valueCacheDesc) = descriptor.stateDescriptor(of: valueCacheName)
        else {
            throw InferenceRuntimeError.invalidOutputType("Cannot get KV cache state descriptors")
        }

        // Extract input descriptors
        guard case .ndArray(let inputIdsDesc) = descriptor.inputDescriptor(of: inputIdsName) else {
            throw InferenceRuntimeError.invalidInputType("Cannot get descriptor for '\(inputIdsName)'")
        }
        guard case .ndArray(let posIdsDesc) = descriptor.inputDescriptor(of: positionIdsName) else {
            throw InferenceRuntimeError.invalidInputType("Cannot get descriptor for '\(positionIdsName)'")
        }

        // Extract logits descriptor
        guard case .ndArray(let logitsDesc) = descriptor.outputDescriptor(of: logitsOutputName) else {
            throw InferenceRuntimeError.invalidOutputType("Cannot get descriptor for '\(logitsOutputName)'")
        }
        guard logitsDesc.scalarType == .float16 else {
            throw InferenceRuntimeError.unsupportedLogitsType(
                "Only float16 logits supported, got \(logitsDesc.scalarType)")
        }

        // Allocate inputTokens MTLBuffer
        let inputTokensByteCount = config.maxContextLength * inputIdsDesc.scalarType.byteSize
        guard let inputTokensBuf = device.makeBuffer(length: inputTokensByteCount, options: .storageModeShared) else {
            throw InferenceRuntimeError.bufferAllocationFailed("inputTokens (\(inputTokensByteCount) bytes)")
        }

        // Allocate double-buffered cache positions
        let cachePosSize = config.maxContextLength * posIdsDesc.scalarType.byteSize
        guard let cachePosBuf0 = device.makeBuffer(length: cachePosSize, options: .storageModeShared),
            let cachePosBuf1 = device.makeBuffer(length: cachePosSize, options: .storageModeShared)
        else {
            throw InferenceRuntimeError.bufferAllocationFailed("cachePositions (\(cachePosSize * 2) bytes)")
        }

        // Pre-populate cache positions with [0, 1, ..., maxCtx-1]
        for buf in [cachePosBuf0, cachePosBuf1] {
            let ptr = buf.contents().bindMemory(to: Int32.self, capacity: config.maxContextLength)
            for i in 0..<config.maxContextLength {
                ptr[i] = Int32(i)
            }
        }

        // Create KV cache using factory — pass original descriptors (with -1 dynamic dims intact)
        // so the factory can correctly detect growing vs static support via isDynamicKVCache().
        let kvCacheLocal = try KVCacheFactory.make(
            options: options,
            device: device,
            keyReqs: keyCacheDesc,
            valueReqs: valueCacheDesc,
            maxContextLength: config.maxContextLength
        )

        let resolvedSize = options.resolvedKVCacheSize(maxContextLength: config.maxContextLength)
        CLILogger.log("Created \(options.kvCacheStrategy) KV cache with size \(resolvedSize, default: "nil")")

        // Create growing logits buffer (reuses TensorStorage+CoreAI.swift).
        // A fully static logits output (e.g. a decode-only S=1 graph: [1, 1, vocab])
        // can't be resolved at a larger capacity — size the buffer to its static
        // sequence length instead of the prompt-sized default.
        let logitsSeqIsStatic = logitsDesc.shape.count >= 2 && logitsDesc.shape[1] > 0
        let logitsRef = try GrowingLogitsBuffer(
            device: device,
            descriptor: descriptor,
            name: logitsOutputName,
            vocabSize: config.vocabSize,
            maxCapacity: logitsSeqIsStatic ? logitsDesc.shape[1] : config.maxContextLength,
            initialCapacity: logitsSeqIsStatic ? logitsDesc.shape[1] : averageExpectedPromptSize
        )

        // Load inference function
        guard let fn = try model.loadFunction(named: config.function) else {
            throw InferenceRuntimeError.genericError(
                "Cannot load function '\(config.function)'")
        }

        guard let pipelineQueue = device.makeCommandQueue() else {
            throw InferenceRuntimeError.invalidState(
                "Failed to allocate MTLCommandQueue for CoreAIPipelinedEngine")
        }
        pipelineQueue.label = "CoreAIPipelinedEngine.queue"
        let computeStream = ComputeStream(commandQueue: pipelineQueue)

        // Assign
        self.config = config
        self.options = options
        self.function = fn
        self.pipelineQueue = pipelineQueue
        self.computeStream = computeStream
        self.device = device
        self.inputIdsName = inputIdsName
        self.positionIdsName = positionIdsName
        self.keyCacheName = keyCacheName
        self.valueCacheName = valueCacheName
        self.logitsOutputName = logitsOutputName
        self.keyCacheScalarType = keyCacheDesc.scalarType
        self.valueCacheScalarType = valueCacheDesc.scalarType
        self.inputIdsBaseDesc = inputIdsDesc
        self.positionIdsBaseDesc = posIdsDesc
        self.logitsBaseDesc = logitsDesc
        self.inputTokensBuffer = inputTokensBuf
        self.cachePositionBuffers = (cachePosBuf0, cachePosBuf1)
        self.kvCache = kvCacheLocal
        self.extraStates = extraStatesLocal
        self.perTokenInputs = perTokenInputsLocal
        self.perTokenInputProvider = options.perTokenInputProvider
        self.staticInputs = staticInputsLocal
        self.logits = logitsRef
        self.cachedSampler = nil
        self.cachedSamplerTemperature = nil

        CLILogger.log("CoreAI pipelined engine initialized — Vocab: \(config.vocabSize)")
    }

    // MARK: - Extra State Binding

    /// Maximum number of extra states beyond the KV pair. AsyncMutableViews'
    /// lifetime is tied to each inserted value VARIABLE (`@_lifetime(self: &value)`),
    /// so binding must be unrolled per arity with insert + encode in one scope —
    /// see the `switch extraStates.count` at the encode sites.
    static let maxExtraStates = 2

    /// Build a bindable view over extra state `i` (caller guarantees `i < extraStates.count`).
    private func extraStateValue(_ i: Int) -> InferenceFunction.AsyncMutableValue {
        let extra = extraStates[i]
        return unsafe InferenceFunction.AsyncMutableValue(
            unsafeBuffer: extra.buffer,
            byteOffset: 0,
            scalarType: extra.scalarType,
            shape: extra.shape,
            strides: extra.strides
        )
    }

    // MARK: - Per-Token Input Binding

    /// Maximum number of per-token inputs beyond input_ids/position_ids.
    static let maxPerTokenInputs = 2

    /// Maximum number of static inputs (gather tables and the like).
    static let maxStaticInputs = 4

    /// Fill each per-token input's slot for `position` with rows for `token` (via the
    /// provider) and merge the slot bindings into `inputs`. Slot = position keeps in-flight
    /// steps on disjoint buffer regions.
    private func bindPerTokenInputs(
        token: Int32, position: Int,
        into inputs: inout [String: InferenceFunction.AsyncValue]
    ) throws {
        guard let provider = perTokenInputProvider else {
            throw InferenceRuntimeError.invalidState(
                "Per-token inputs present but no provider — engine init should have rejected this")
        }
        for perToken in perTokenInputs {
            let byteOffset = position * perToken.stepByteCount
            provider(
                perToken.name, token, position,
                perToken.buffer.contents() + byteOffset, perToken.stepByteCount)
            inputs[perToken.name] = unsafe InferenceFunction.AsyncValue(
                unsafeBuffer: perToken.buffer,
                byteOffset: byteOffset,
                scalarType: perToken.scalarType,
                shape: perToken.shape,
                strides: perToken.strides
            )
        }
    }

    /// Per-token inputs constrain the engine to S=1 steps: each step's rows are gathered for
    /// exactly one token. Run with `COREAI_CHUNK_THRESHOLD=1` so prefill chunks are S=1 too.
    private func requireSingleTokenStep(_ queryLength: Int) throws {
        guard queryLength == 1 else {
            throw InferenceRuntimeError.invalidArgument(
                "Model has per-token inputs — only S=1 steps are supported, got query length "
                    + "\(queryLength). Set COREAI_CHUNK_THRESHOLD=1 so prefill runs as S=1 steps.")
        }
    }

    // MARK: - Sampler

    private mutating func getOrCreateSampler(for config: SamplingConfiguration) throws -> any MPSGraphSampler {
        let temperature = config.temperature

        if let existingSampler = cachedSampler, let existingTemp = cachedSamplerTemperature {
            let existingIsGreedy = existingTemp == 0
            let requestedIsGreedy = temperature == 0

            if existingIsGreedy != requestedIsGreedy {
                throw InferenceRuntimeError.genericError(
                    "Sampling configuration changed mid-generation. Call reset() first.")
            }
            if !existingIsGreedy && !requestedIsGreedy
                && abs(existingTemp - temperature) > temperatureTolerance
            {
                throw InferenceRuntimeError.genericError(
                    "Temperature changed mid-generation (\(existingTemp) -> \(temperature)). Call reset() first.")
            }
            return existingSampler
        }

        let newSampler = try MPSGraphSamplerFactory.makeSampler(
            device: device,
            vocabSize: self.config.vocabSize,
            temperature: temperature
        )
        cachedSampler = newSampler
        cachedSamplerTemperature = temperature
        return newSampler
    }

    // MARK: - Core Encode Step

    /// Encodes inference + GPU sampling for one step.
    ///
    /// 1. Construct RawView/MutableRawView from MTLBuffers with current shapes
    /// 2. Encode to ComputeStream (non-blocking)
    /// 3. withMetal3Queue: encode GPU argmax/topK (writes directly to inputTokensBuffer)
    /// 4. Callback yields token
    private mutating func _encodeNextStepGPU(
        tokens: some Collection<Int32>,
        gpuSampler: any MPSGraphSampler,
        yieldingTo continuation: AsyncThrowingStream<InferenceEngine.TokenId, Error>.Continuation
    ) async throws {
        let currentStep = processedTokenCount

        let actualTokenCount = tokens.isEmpty ? 1 : tokens.count
        let queryLength = actualTokenCount

        // Per-token inputs: resolve this step's token id (prompt token during prefill;
        // the previous GPU-sampled token during decode, mirrored via the rendezvous).
        var perTokenStepToken: Int32? = nil
        if !perTokenInputs.isEmpty {
            try requireSingleTokenStep(queryLength)
            if let promptToken = tokens.first {
                perTokenStepToken = promptToken
            } else if let sampled = lastSampledToken {
                perTokenStepToken = sampled
            } else {
                throw InferenceRuntimeError.invalidState(
                    "Decode step with per-token inputs before any sampled token")
            }
        }

        defer {
            processedTokenCount += actualTokenCount
            step += 1
        }

        let encodeStepID = InstrumentsProfiler.beginCustomInterval(
            name: "CoreAIPipelinedEncodeNextStep",
            details: "step=\(currentStep) qLen=\(queryLength)"
        )

        // PrepareStep: write tokens + build views
        let prepareSpan = InstrumentsProfiler.beginPrepareStep(
            step: currentStep, operation: "write+build", engine: "CoreAI-Pipelined")

        // Prefill: write tokens at their natural position so this step's region is disjoint
        // from any prior chunk's region still in-flight on the GPU (encode holds a live
        // MTLBuffer reference; no encodeWriteOperands serialization available in Core AI).
        // Decode: token is already at offset 0 via GPU-direct argmax write — no CPU write needed.
        let tokenByteOffset = processedTokenCount * MemoryLayout<Int32>.size
        if !tokens.isEmpty {
            let ptr = inputTokensBuffer.contents().bindMemory(
                to: Int32.self, capacity: processedTokenCount + queryLength)
            for (i, token) in tokens.enumerated() {
                ptr[processedTokenCount + i] = token
            }
        }

        // Select cache position buffer for this step (double-buffered)
        let cachePosBuffer = step % 2 == 0 ? cachePositionBuffers.0 : cachePositionBuffers.1
        let posLength = processedTokenCount + queryLength

        // Build Inputs as AsyncValue (from MTLBuffers)
        let tokenShape = [1, queryLength]
        let tokenStrides = try resolvedStrides(descriptor: inputIdsBaseDesc, shape: tokenShape)
        let tokenValue = unsafe InferenceFunction.AsyncValue(
            unsafeBuffer: inputTokensBuffer,
            byteOffset: tokens.isEmpty ? 0 : tokenByteOffset,
            scalarType: .int32,
            shape: tokenShape,
            strides: tokenStrides
        )
        let posShape = [1, posLength]
        let posStrides = try resolvedStrides(descriptor: positionIdsBaseDesc, shape: posShape)
        let posValue = unsafe InferenceFunction.AsyncValue(
            unsafeBuffer: cachePosBuffer,
            byteOffset: 0,
            scalarType: .int32,
            shape: posShape,
            strides: posStrides
        )

        var asyncInputs: [String: InferenceFunction.AsyncValue] = [
            inputIdsName: tokenValue,
            positionIdsName: posValue,
        ]
        if let stepToken = perTokenStepToken {
            try bindPerTokenInputs(token: stepToken, position: currentStep, into: &asyncInputs)
        }
        // Static inputs: same caller-owned buffer every step, nothing to fill.
        for staticInput in staticInputs {
            asyncInputs[staticInput.name] = unsafe InferenceFunction.AsyncValue(
                unsafeBuffer: staticInput.buffer,
                byteOffset: 0,
                scalarType: staticInput.scalarType,
                shape: staticInput.shape,
                strides: staticInput.strides
            )
        }

        // Build States as AsyncMutableValue (KV cache, in-place update)
        let keyBuffer = kvCache.keyBinding.metalBuffer
        let keyShape = kvCache.keyBinding.layout.shape
        let keyStrides = kvCache.keyBinding.layout.strides
        var keyState = unsafe InferenceFunction.AsyncMutableValue(
            unsafeBuffer: keyBuffer,
            byteOffset: 0,
            scalarType: keyCacheScalarType,
            shape: keyShape,
            strides: keyStrides
        )
        let valBuffer = kvCache.valueBinding.metalBuffer
        let valShape = kvCache.valueBinding.layout.shape
        let valStrides = kvCache.valueBinding.layout.strides
        var valState = unsafe InferenceFunction.AsyncMutableValue(
            unsafeBuffer: valBuffer,
            byteOffset: 0,
            scalarType: valueCacheScalarType,
            shape: valShape,
            strides: valStrides
        )

        var asyncStates = InferenceFunction.AsyncMutableViews()
        asyncStates.insert(&keyState, for: keyCacheName)
        asyncStates.insert(&valState, for: valueCacheName)

        // Build Output as AsyncMutableValue (logits)
        let logitsBuffer = logits.metalBuffer
        let logitsShape = [1, queryLength, vocabSize]
        let logitsStrides = try resolvedStrides(descriptor: logitsBaseDesc, shape: logitsShape)
        var logitsOutput = unsafe InferenceFunction.AsyncMutableValue(
            unsafeBuffer: logitsBuffer,
            byteOffset: 0,
            scalarType: .float16,
            shape: logitsShape,
            strides: logitsStrides
        )

        var asyncOutputs = InferenceFunction.AsyncMutableViews()
        asyncOutputs.insert(&logitsOutput, for: logitsOutputName)

        prepareSpan.end()

        // Backpressure: cap outstanding encode calls
        await inFlightGate.acquire()

        // Encode inference using the public encode() API.
        // This commits + uses runAfterSyncPoint (no stream wait) — enables true pipelining.
        // Extra fixed-shape states (SSM conv/rec) are inserted in the same scope as the
        // consuming encode call — the views' lifetime is tied to each inserted value
        // variable, so insert and encode can't be separated by a scope boundary.
        let logitsSpan = InstrumentsProfiler.beginLogitsInference(
            step: currentStep, tokens: queryLength, engine: "CoreAI-Pipelined")
        switch extraStates.count {
        case 0:
            let _ = try function.encode(
                inputs: asyncInputs,
                states: consume asyncStates,
                outputViews: consume asyncOutputs,
                to: computeStream
            )
        case 1:
            var extraValue0 = extraStateValue(0)
            asyncStates.insert(&extraValue0, for: extraStates[0].name)
            let _ = try function.encode(
                inputs: asyncInputs,
                states: consume asyncStates,
                outputViews: consume asyncOutputs,
                to: computeStream
            )
        default:  // 2 — init caps extra states at maxExtraStates
            var extraValue0 = extraStateValue(0)
            var extraValue1 = extraStateValue(1)
            asyncStates.insert(&extraValue0, for: extraStates[0].name)
            asyncStates.insert(&extraValue1, for: extraStates[1].name)
            let _ = try function.encode(
                inputs: asyncInputs,
                states: consume asyncStates,
                outputViews: consume asyncOutputs,
                to: computeStream
            )
        }
        logitsSpan.end()

        // GPU sampling via Metal queue
        let localGPUSampler = gpuSampler
        let outputBuffer = inputTokensBuffer
        let logitsOffset = (actualTokenCount - 1) * vocabSize * MemoryLayout<UInt16>.size
        let samplerStrategy = gpuSampler is MPSGraphArgmaxSampler ? "GPU-argmax" : "GPU-topK"
        let samplerTemperature = cachedSamplerTemperature ?? 0.0

        let sampleSpan = InstrumentsProfiler.beginSampleEncoding(
            step: currentStep, strategy: samplerStrategy, temperature: samplerTemperature)

        do {
            let queue = pipelineQueue
            let localInFlightGate = inFlightGate
            let localRendezvous = perTokenInputs.isEmpty ? nil : sampledTokenRendezvous
            let completionCallback: (Int32) -> Void = { nextToken in
                // Release the pipeline slot acquired before encode. Happens on
                // Metal's callback thread — PipelineGate.release() is thread-safe.
                localInFlightGate.release()
                // Mirror the sampled token to the CPU so the next step can gather
                // its per-token inputs (no-op for models without them).
                localRendezvous?.deliver(nextToken)
                InstrumentsProfiler.endCustomInterval(
                    name: "CoreAIPipelinedEncodeNextStep",
                    signpostID: encodeStepID,
                    details: "token=\(nextToken)"
                )
                continuation.yield(nextToken)
            }

            if queryLength == 1 {
                localGPUSampler.encode(
                    to: queue,
                    logitsBuffer: logitsBuffer,
                    logitsOffset: logitsOffset,
                    outputBuffer: outputBuffer,
                    outputOffset: 0,
                    completion: completionCallback
                )
            } else {
                localGPUSampler.encodeWithSlice(
                    to: queue,
                    logitsBuffer: logitsBuffer,
                    queryLength: actualTokenCount,
                    outputBuffer: outputBuffer,
                    outputOffset: 0,
                    completion: completionCallback
                )
            }
        }

        sampleSpan.end()

        // With per-token inputs, the next step's gather needs THIS step's sampled token on
        // the CPU — wait for the sampler completion here. This serializes the GPU pipeline
        // (the win over a hand-rolled loop is the on-GPU argmax + on-device KV, not depth).
        if !perTokenInputs.isEmpty {
            lastSampledToken = await sampledTokenRendezvous.take()
        }
    }

    // MARK: - Token Generation

    private mutating func generateTokenBatch(
        count: Int,
        gpuSampler: any MPSGraphSampler,
        yieldingTo continuation: AsyncThrowingStream<InferenceEngine.TokenId, Error>.Continuation,
        isCancelled: borrowing Atomic<Bool>
    ) async throws {
        for _ in 0..<count {
            guard !isCancelled.load(ordering: .relaxed) else { return }
            try await _encodeNextStepGPU(
                tokens: [],
                gpuSampler: gpuSampler,
                yieldingTo: continuation
            )
        }
    }

    // MARK: - KV Cache Growth

    private mutating func growKVCacheAndRebind(neededCapacity: Int) async throws {
        let cacheSpan = InstrumentsProfiler.beginCacheManagement(
            step: processedTokenCount, operation: "grow", engine: "CoreAI-Pipelined")

        do {
            do {
                let queue = pipelineQueue
                guard let cmdBuf = queue.makeCommandBuffer() else {
                    throw KVCacheError.allocationFailed(0)
                }

                if (try kvCache.encodePipelinedExpansion(
                    forContextLength: neededCapacity,
                    commandBuffer: cmdBuf)) != nil
                {
                    CLILogger.log("KV cache grew (pipelined) to \(kvCache.currentCapacity)")
                } else {
                    throw KVCacheError.capacityExceeded(
                        needed: neededCapacity, available: kvCache.currentCapacity)
                }
            }
        } catch {
            cacheSpan.end()
            throw error
        }
        cacheSpan.end()
    }

    // MARK: - Run Completion

    mutating func runCompletion(
        prompt: [InferenceEngine.TokenId],
        sampler: SamplingConfiguration,
        maxTokens: Int?,
        yieldingTo continuation: AsyncThrowingStream<InferenceEngine.TokenId, Error>.Continuation
    ) async throws {
        let gpuSampler = try getOrCreateSampler(for: sampler)

        let isCancelled = Atomic<Bool>(false)
        continuation.onTermination = { _ in
            isCancelled.store(true, ordering: .relaxed)
        }

        let contextLeftAfterPrompt = config.maxContextLength - processedTokenCount - prompt.count
        guard contextLeftAfterPrompt >= 1 else {
            throw InferenceRuntimeError.contextLengthExceeded(
                processedTokenCount, config.maxContextLength)
        }
        let totalMaxTokens = min(maxTokens ?? Int.max, contextLeftAfterPrompt)

        // Pre-grow KV cache for prompt
        let promptCapacityNeeded = min(
            processedTokenCount + prompt.count + totalMaxTokens, config.maxContextLength)
        if promptCapacityNeeded > kvCache.currentCapacity {
            do {
                let queue = pipelineQueue
                let grew = try kvCache.ensureCapacity(
                    forContextLength: promptCapacityNeeded, queue: queue)
                if grew {
                    CLILogger.log(
                        "KV cache grew to \(kvCache.currentCapacity) for prompt (\(prompt.count) tokens)"
                    )
                }
            }
        }

        // Split prompt into chunks when it exceeds the chunk threshold.
        let prefillTokens: ArraySlice<Int32>
        if prompt.count > config.chunkThreshold {
            prefillTokens = try await processChunkedInput(tokens: prompt)
        } else {
            let prefillCapacity = max(1, prompt.count)
            if try logits.ensureCapacity(forContextLength: prefillCapacity) {
                let fmt = ByteCountFormatter()
                fmt.countStyle = .memory
                CLILogger.log(
                    "Logits buffer grew to capacity \(logits.currentCapacity) (\(fmt.string(fromByteCount: Int64(logits.currentByteCount))))"
                )
            }
            prefillTokens = prompt[...]
        }

        // Process prompt with sampling
        try await _encodeNextStepGPU(
            tokens: prefillTokens,
            gpuSampler: gpuSampler,
            yieldingTo: continuation
        )

        // Generate-Grow-Continue loop
        var remainingTokens = totalMaxTokens - 1

        while remainingTokens > 0 {
            guard !isCancelled.load(ordering: .relaxed) else { break }

            let availableSlots = kvCache.currentCapacity - processedTokenCount
            let tokensThisRound = min(remainingTokens, availableSlots)

            if tokensThisRound > 0 {
                try await generateTokenBatch(
                    count: tokensThisRound,
                    gpuSampler: gpuSampler,
                    yieldingTo: continuation,
                    isCancelled: isCancelled
                )
                remainingTokens -= tokensThisRound
            }

            if remainingTokens > 0 {
                let neededCapacity = processedTokenCount + remainingTokens
                try await growKVCacheAndRebind(neededCapacity: neededCapacity)
            }
        }

        // Sentinel: submit an empty command buffer on the same serial queue.
        // Its addCompletedHandler fires after all real sampler callbacks (serial
        // queue FIFO ordering via MTLDispatchListApply), guaranteeing every
        // continuation.yield has returned before the caller calls finish().
        // We use a bare command buffer instead of the sampler to avoid the shared
        // MPSGraphExecutableExecutionDescriptor issue in MPSGraphTopKSampler.
        await withCheckedContinuation { (sentinelCont: CheckedContinuation<Void, Never>) in
            do {
                let queue = pipelineQueue
                guard let cmdBuf = queue.makeCommandBuffer() else {
                    sentinelCont.resume()
                    return
                }
                cmdBuf.addCompletedHandler { _ in sentinelCont.resume() }
                cmdBuf.commit()
            }
        }
    }

    // MARK: - Chunked Prefill

    mutating func processChunkedInput(tokens: [Int32]) async throws -> ArraySlice<Int32> {
        let chunkSize = config.prefillChunkSize
        var remainingTokens = tokens[...]

        try logits.ensureCapacity(forContextLength: chunkSize)

        while remainingTokens.count > chunkSize {
            let chunk = Array(remainingTokens.prefix(chunkSize))
            try await _encodeChunk(tokens: chunk)
            remainingTokens = remainingTokens.dropFirst(chunkSize)
        }

        return remainingTokens
    }

    private mutating func _encodeChunk(tokens: [Int32]) async throws {
        let queryLength = tokens.count
        let currentStep = processedTokenCount
        if !perTokenInputs.isEmpty {
            try requireSingleTokenStep(queryLength)
        }

        let chunkID = InstrumentsProfiler.beginCustomInterval(
            name: "CoreAIPipelinedChunk",
            details: "step=\(currentStep) qLen=\(queryLength)"
        )

        // Write at the chunk's natural position so each chunk occupies a disjoint
        // region of inputTokensBuffer. Encode holds a live MTLBuffer reference — writing
        // all chunks at offset 0 would race with the GPU reading the previous chunk.
        let ptr = inputTokensBuffer.contents().bindMemory(
            to: Int32.self, capacity: processedTokenCount + queryLength)
        for (i, token) in tokens.enumerated() {
            ptr[processedTokenCount + i] = token
        }

        let cachePosBuffer = step % 2 == 0 ? cachePositionBuffers.0 : cachePositionBuffers.1
        let posLength = processedTokenCount + queryLength

        // Build async values and encode
        let tokenShape = [1, queryLength]
        let tokenStrides = try resolvedStrides(descriptor: inputIdsBaseDesc, shape: tokenShape)
        let posShape = [1, posLength]
        let posStrides = try resolvedStrides(descriptor: positionIdsBaseDesc, shape: posShape)

        let tokenValue = unsafe InferenceFunction.AsyncValue(
            unsafeBuffer: inputTokensBuffer,
            byteOffset: processedTokenCount * MemoryLayout<Int32>.size,
            scalarType: .int32, shape: tokenShape, strides: tokenStrides)
        let posValue = unsafe InferenceFunction.AsyncValue(
            unsafeBuffer: cachePosBuffer, byteOffset: 0,
            scalarType: .int32, shape: posShape, strides: posStrides)

        var asyncInputs: [String: InferenceFunction.AsyncValue] = [
            inputIdsName: tokenValue, positionIdsName: posValue,
        ]
        if !perTokenInputs.isEmpty, let chunkToken = tokens.first {
            try bindPerTokenInputs(token: chunkToken, position: currentStep, into: &asyncInputs)
        }
        // Static inputs: same caller-owned buffer every step, nothing to fill.
        for staticInput in staticInputs {
            asyncInputs[staticInput.name] = unsafe InferenceFunction.AsyncValue(
                unsafeBuffer: staticInput.buffer,
                byteOffset: 0,
                scalarType: staticInput.scalarType,
                shape: staticInput.shape,
                strides: staticInput.strides
            )
        }

        let keyBuffer = kvCache.keyBinding.metalBuffer
        let keyShape = kvCache.keyBinding.layout.shape
        let keyStrides = kvCache.keyBinding.layout.strides
        let valBuffer = kvCache.valueBinding.metalBuffer
        let valShape = kvCache.valueBinding.layout.shape
        let valStrides = kvCache.valueBinding.layout.strides
        var keyState = unsafe InferenceFunction.AsyncMutableValue(
            unsafeBuffer: keyBuffer, byteOffset: 0,
            scalarType: keyCacheScalarType, shape: keyShape, strides: keyStrides)
        var valState = unsafe InferenceFunction.AsyncMutableValue(
            unsafeBuffer: valBuffer, byteOffset: 0,
            scalarType: valueCacheScalarType, shape: valShape, strides: valStrides)
        var asyncStates = InferenceFunction.AsyncMutableViews()
        asyncStates.insert(&keyState, for: keyCacheName)
        asyncStates.insert(&valState, for: valueCacheName)

        let logitsShape = [1, queryLength, vocabSize]
        let logitsStrides = try resolvedStrides(descriptor: logitsBaseDesc, shape: logitsShape)
        var logitsOutput = unsafe InferenceFunction.AsyncMutableValue(
            unsafeBuffer: logits.metalBuffer, byteOffset: 0,
            scalarType: .float16, shape: logitsShape, strides: logitsStrides)
        var asyncOutputs = InferenceFunction.AsyncMutableViews()
        asyncOutputs.insert(&logitsOutput, for: logitsOutputName)

        switch extraStates.count {
        case 0:
            let _ = try function.encode(
                inputs: asyncInputs,
                states: consume asyncStates,
                outputViews: consume asyncOutputs,
                to: computeStream
            )
        case 1:
            var extraValue0 = extraStateValue(0)
            asyncStates.insert(&extraValue0, for: extraStates[0].name)
            let _ = try function.encode(
                inputs: asyncInputs,
                states: consume asyncStates,
                outputViews: consume asyncOutputs,
                to: computeStream
            )
        default:  // 2 — init caps extra states at maxExtraStates
            var extraValue0 = extraStateValue(0)
            var extraValue1 = extraStateValue(1)
            asyncStates.insert(&extraValue0, for: extraStates[0].name)
            asyncStates.insert(&extraValue1, for: extraStates[1].name)
            let _ = try function.encode(
                inputs: asyncInputs,
                states: consume asyncStates,
                outputViews: consume asyncOutputs,
                to: computeStream
            )
        }

        processedTokenCount += queryLength
        step += 1
        InstrumentsProfiler.endCustomInterval(name: "CoreAIPipelinedChunk", signpostID: chunkID)
    }

    mutating func reset() {
        let span = InstrumentsProfiler.beginReset(engine: "CoreAI-Pipelined")
        processedTokenCount = 0
        step = 0
        cachedSampler = nil
        cachedSamplerTemperature = nil
        lastSampledToken = nil
        // Fresh sequence: SSM-style extra states must restart from zero. The KV pair
        // needs no clearing — attention only reads positions below the new offset.
        // Per-token input slots need no clearing either: each step's slot is fully
        // rewritten by the provider before it is bound.
        for extra in extraStates {
            memset(extra.buffer.contents(), 0, extra.buffer.length)
        }
        span.end()
    }

    // MARK: - Warmup

    mutating func performWarmup(queryLength: Int, samplingConfig: SamplingConfiguration?) async throws {
        let warmupStart = ContinuousClock.now
        let warmupSpan = InstrumentsProfiler.beginWarmup()

        // A single warmup at any shape primes the framework's internal caches
        // (reshape, kernel compilation, state pool). Benchmarks show no benefit
        // from warming every bucket shape — the jump from none→any is what matters.
        let defaultWarmupLength = 256

        var shapesToWarm: [Int]
        if queryLength > 0 {
            shapesToWarm = [queryLength]
        } else {
            shapesToWarm = [1, defaultWarmupLength]
        }
        if !perTokenInputs.isEmpty {
            // Per-token-input graphs are S=1 static — larger warmup shapes would be rejected.
            shapesToWarm = [1]
        }

        CLILogger.log("Running warmup for \(shapesToWarm.count) shape(s)")

        let maxShape = shapesToWarm.last ?? 1
        try logits.ensureCapacity(forContextLength: maxShape)

        do {
            let queue = pipelineQueue
            if try kvCache.ensureCapacity(forContextLength: maxShape, queue: queue) {
                CLILogger.log("KV cache grew to \(kvCache.currentCapacity) for warmup")
            }
        }

        let warmupSampler = try MPSGraphSamplerFactory.makeSampler(
            device: device,
            vocabSize: config.vocabSize,
            temperature: samplingConfig?.temperature ?? 0
        )

        for shape in shapesToWarm {
            // Write dummy tokens
            let ptr = inputTokensBuffer.contents().bindMemory(to: Int32.self, capacity: shape)
            for i in 0..<shape { ptr[i] = 1 }

            let cachePosBuffer = step % 2 == 0 ? cachePositionBuffers.0 : cachePositionBuffers.1
            let posLength = processedTokenCount + shape

            let tShape = [1, shape]
            let tStrides = try resolvedStrides(descriptor: inputIdsBaseDesc, shape: tShape)
            let pShape = [1, posLength]
            let pStrides = try resolvedStrides(descriptor: positionIdsBaseDesc, shape: pShape)

            let tokenValue = unsafe InferenceFunction.AsyncValue(
                unsafeBuffer: inputTokensBuffer, byteOffset: 0,
                scalarType: .int32, shape: tShape, strides: tStrides)
            let posValue = unsafe InferenceFunction.AsyncValue(
                unsafeBuffer: cachePosBuffer, byteOffset: 0,
                scalarType: .int32, shape: pShape, strides: pStrides)
            var asyncInputs: [String: InferenceFunction.AsyncValue] = [
                inputIdsName: tokenValue, positionIdsName: posValue,
            ]
            if !perTokenInputs.isEmpty {
                // Warm with the same dummy token the ids buffer holds, at position 0.
                try bindPerTokenInputs(token: 1, position: 0, into: &asyncInputs)
            }
            // Static inputs: same caller-owned buffer every step, nothing to fill.
            for staticInput in staticInputs {
                asyncInputs[staticInput.name] = unsafe InferenceFunction.AsyncValue(
                    unsafeBuffer: staticInput.buffer,
                    byteOffset: 0,
                    scalarType: staticInput.scalarType,
                    shape: staticInput.shape,
                    strides: staticInput.strides
                )
            }

            let keyBuffer = kvCache.keyBinding.metalBuffer
            let kShape = kvCache.keyBinding.layout.shape
            let kStrides = kvCache.keyBinding.layout.strides
            let valBuffer = kvCache.valueBinding.metalBuffer
            let vShape = kvCache.valueBinding.layout.shape
            let vStrides = kvCache.valueBinding.layout.strides
            var keyState = unsafe InferenceFunction.AsyncMutableValue(
                unsafeBuffer: keyBuffer, byteOffset: 0,
                scalarType: keyCacheScalarType, shape: kShape, strides: kStrides)
            var valState = unsafe InferenceFunction.AsyncMutableValue(
                unsafeBuffer: valBuffer, byteOffset: 0,
                scalarType: valueCacheScalarType, shape: vShape, strides: vStrides)
            var asyncStates = InferenceFunction.AsyncMutableViews()
            asyncStates.insert(&keyState, for: keyCacheName)
            asyncStates.insert(&valState, for: valueCacheName)

            let lShape = [1, shape, vocabSize]
            let lStrides = try resolvedStrides(descriptor: logitsBaseDesc, shape: lShape)
            var logitsOutput = unsafe InferenceFunction.AsyncMutableValue(
                unsafeBuffer: logits.metalBuffer, byteOffset: 0,
                scalarType: .float16, shape: lShape, strides: lStrides)
            var asyncOutputs = InferenceFunction.AsyncMutableViews()
            asyncOutputs.insert(&logitsOutput, for: logitsOutputName)

            switch extraStates.count {
            case 0:
                let _ = try function.encode(
                    inputs: asyncInputs,
                    states: consume asyncStates,
                    outputViews: consume asyncOutputs,
                    to: computeStream
                )
            case 1:
                var extraValue0 = extraStateValue(0)
                asyncStates.insert(&extraValue0, for: extraStates[0].name)
                let _ = try function.encode(
                    inputs: asyncInputs,
                    states: consume asyncStates,
                    outputViews: consume asyncOutputs,
                    to: computeStream
                )
            default:  // 2 — init caps extra states at maxExtraStates
                var extraValue0 = extraStateValue(0)
                var extraValue1 = extraStateValue(1)
                asyncStates.insert(&extraValue0, for: extraStates[0].name)
                asyncStates.insert(&extraValue1, for: extraStates[1].name)
                let _ = try function.encode(
                    inputs: asyncInputs,
                    states: consume asyncStates,
                    outputViews: consume asyncOutputs,
                    to: computeStream
                )
            }

            // Warm up argmax kernel
            let logitsBuffer = logits.metalBuffer
            let outputBuffer = inputTokensBuffer
            let logitsOffset = (shape - 1) * vocabSize * MemoryLayout<UInt16>.size

            do {
                let queue = pipelineQueue
                warmupSampler.encode(
                    to: queue,
                    logitsBuffer: logitsBuffer,
                    logitsOffset: logitsOffset,
                    outputBuffer: outputBuffer,
                    outputOffset: 0,
                    completion: { _ in }
                )
            }

            step += 1
        }

        await computeStream.currentWorkCompleted()
        reset()

        warmupSpan.end()
        let warmupElapsed = milliseconds(since: warmupStart)
        CLILogger.log(
            "CoreAI pipelined warmup complete (\(shapesToWarm.count) shapes): \(String(format: "%.2f", warmupElapsed))ms"
        )
    }
}

extension CoreAIPipelinedEngine {
    /// Async sequence of `InferenceOutput` produced by `generate()`.
    ///
    /// Unlike the CPU engines, the pipelined engine samples on-device and drives
    /// output from a producer `Task`, so this sequence forwards an underlying
    /// `AsyncThrowingStream`. The producer records the `stopReason` directly.
    public struct GenerationSequence: InferenceOutputSequence {
        public typealias Element = InferenceOutput
        public typealias Failure = Error

        let base: AsyncThrowingStream<InferenceOutput, any Error>
        let stopReasonStore: StopReasonStore

        public var stopReason: StopReason? { stopReasonStore.stopReason }

        public func setStopReason(_ reason: StopReason) {
            stopReasonStore.set(reason)
        }

        public func makeAsyncIterator() -> Iterator {
            Iterator(base: base.makeAsyncIterator(), stopReasonStore: stopReasonStore)
        }
    }
}

extension CoreAIPipelinedEngine.GenerationSequence {
    public struct Iterator: AsyncIteratorProtocol {
        public typealias Element = InferenceOutput
        public typealias Failure = Error

        var base: AsyncThrowingStream<InferenceOutput, any Error>.AsyncIterator
        let stopReasonStore: StopReasonStore

        public mutating func next() async throws -> InferenceOutput? {
            do {
                return try await base.next()
            } catch is CancellationError {
                // The producer Task is independent and won't observe the
                // consumer's cancellation, so record it from the consumer side.
                stopReasonStore.set(.cancelled)
                throw CancellationError()
            } catch {
                stopReasonStore.set(.error)
                throw error
            }
        }
    }
}
