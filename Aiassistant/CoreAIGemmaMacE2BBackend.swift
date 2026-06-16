import CoreAI
import CoreAIShared
import Foundation
import Tokenizers

@MainActor
final class CoreAIGemmaMacE2BBackend {
    private static let hiddenSize = 1536
    private static let perLayerCount = 35
    private static let perLayerWidth = 256
    private static let vocabSize = 262144
    private static let slidingHeadSize = 256
    private static let fullHeadSize = 512
    private static let slidingSlotCount = 12
    private static let fullSlotCount = 3
    private static let slidingWindow = 512
    private static let maskNegative = Float16(-1e4)

    private let modelDirectory: URL
    private var contextLength = 512
    private var gather: CoreAIGemmaMacE2BGather?
    private var coreModel: AIModel?
    private var headModel: AIModel?
    private var coreDescriptor: InferenceFunctionDescriptor?
    private var headDescriptor: InferenceFunctionDescriptor?
    private var coreFunction: InferenceFunction?
    private var headFunction: InferenceFunction?
    private var tokenizer: Tokenizer?
    private var slidingKeys: [Float16] = []
    private var slidingValues: [Float16] = []
    private var fullKeys: [Float16] = []
    private var fullValues: [Float16] = []

    init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    var isLoaded: Bool {
        coreFunction != nil && headFunction != nil && tokenizer != nil
    }

    static func generate(prompt: String, modelDirectory: URL, maxTokens: Int = 384) async throws -> String {
        let backend = CoreAIGemmaMacE2BBackend(modelDirectory: modelDirectory)
        return try await backend.generate(prompt: prompt, maxTokens: maxTokens)
    }

    func generate(
        prompt: String,
        maxTokens: Int = 384,
        onUpdate: ((String) -> Void)? = nil
    ) async throws -> String {
        let requestStarted = Date()
        let wasLoaded = isLoaded
        try await loadIfNeeded()
        let loadedAt = Date()
        guard let tokenizer else {
            throw CoreAIGemmaProviderError.invalidModelBundle(.gemma4E2BSmall)
        }
        let promptTokens = try promptTokenIDs(for: prompt, tokenizer: tokenizer)
        guard promptTokens.count < contextLength - 1 else {
            throw CoreAIGemmaProviderError.promptTooLong(promptTokens.count, contextLength)
        }

        reset()
        var lastToken = 0
        for (position, token) in promptTokens.enumerated() {
            try Task.checkCancellation()
            lastToken = try await step(token, position: position, needsToken: true)
        }
        let prefillFinishedAt = Date()

        let eosToken = tokenizer.eosTokenId ?? 106
        var generatedTokens: [Int] = []
        var position = promptTokens.count
        var stoppedNaturally = false
        while generatedTokens.count < maxTokens, position < contextLength {
            try Task.checkCancellation()
            if lastToken == eosToken || lastToken == 106 {
                stoppedNaturally = true
                break
            }
            generatedTokens.append(lastToken)
            if generatedTokens.count == 1 || generatedTokens.count.isMultiple(of: 4) {
                onUpdate?(Self.cleanDecodedText(tokenizer.decode(tokens: generatedTokens, skipSpecialTokens: true)))
            }
            lastToken = try await step(Int32(lastToken), position: position, needsToken: true)
            position += 1
        }

        var text = Self.cleanDecodedText(tokenizer.decode(tokens: generatedTokens, skipSpecialTokens: true))
        let finishedAt = Date()
        print(
            String(
                format: "CoreAIGemmaMacE2B timing cached=%@ load=%.2fs promptTokens=%d prefill=%.2fs outputTokens=%d decode=%.2fs total=%.2fs",
                wasLoaded ? "yes" : "no",
                loadedAt.timeIntervalSince(requestStarted),
                promptTokens.count,
                prefillFinishedAt.timeIntervalSince(loadedAt),
                generatedTokens.count,
                finishedAt.timeIntervalSince(prefillFinishedAt),
                finishedAt.timeIntervalSince(requestStarted)
            )
        )
        if !stoppedNaturally, !text.isEmpty {
            let reason = position >= contextLength ? "context limit" : "response length limit"
            text += "\n\n[Stopped at the Small E2B \(reason). Ask for a shorter answer or switch to a larger Gemma model for longer responses.]"
        }
        onUpdate?(text)
        return text
    }

    private func loadIfNeeded() async throws {
        if isLoaded {
            return
        }

        gather = try CoreAIGemmaMacE2BGather(
            directory: modelDirectory.appendingPathComponent("gemma4_gather_raw", isDirectory: true)
        )

        var options = SpecializationOptions(preferredComputeUnitKind: .gpu)
        options.expectFrequentReshapes = false

        let coreURL = modelDirectory.appendingPathComponent("gemma4_e2b_metal_int8v3_L35.aimodel", isDirectory: true)
        let loadedCoreModel = try await AIModel(contentsOf: coreURL, options: options)
        guard let loadedCoreDescriptor = loadedCoreModel.functionDescriptor(for: "main"),
              let loadedCoreFunction = try loadedCoreModel.loadFunction(named: "main") else {
            throw CoreAIGemmaProviderError.invalidModelBundle(.gemma4E2BSmall)
        }
        coreModel = loadedCoreModel
        coreDescriptor = loadedCoreDescriptor
        coreFunction = loadedCoreFunction

        if case .ndArray(let descriptor)? = loadedCoreDescriptor.inputDescriptor(of: "causal_mask_full"),
           let lastDimension = descriptor.shape.last {
            contextLength = (lastDimension < 0 ? 512 : lastDimension) - 1
        }

        let headURL = modelDirectory.appendingPathComponent("gemma4_e2b_head_argmax_kernel.aimodel", isDirectory: true)
        let loadedHeadModel = try await AIModel(contentsOf: headURL, options: options)
        guard let loadedHeadDescriptor = loadedHeadModel.functionDescriptor(for: "main"),
              let loadedHeadFunction = try loadedHeadModel.loadFunction(named: "main") else {
            throw CoreAIGemmaProviderError.invalidModelBundle(.gemma4E2BSmall)
        }
        headModel = loadedHeadModel
        headDescriptor = loadedHeadDescriptor
        headFunction = loadedHeadFunction
        tokenizer = try await AutoTokenizer.from(
            modelFolder: modelDirectory.appendingPathComponent("tokenizer", isDirectory: true),
            strict: false
        )
        reset()
    }

    private func reset() {
        slidingKeys = [Float16](repeating: 0, count: Self.slidingSlotCount * contextLength * Self.slidingHeadSize)
        slidingValues = [Float16](repeating: 0, count: Self.slidingSlotCount * contextLength * Self.slidingHeadSize)
        fullKeys = [Float16](repeating: 0, count: Self.fullSlotCount * contextLength * Self.fullHeadSize)
        fullValues = [Float16](repeating: 0, count: Self.fullSlotCount * contextLength * Self.fullHeadSize)
    }

    private func step(_ token: Int32, position: Int, needsToken: Bool) async throws -> Int {
        guard let gather,
              let coreDescriptor,
              let coreFunction,
              let headDescriptor,
              let headFunction else {
            throw CoreAIGemmaProviderError.invalidModelBundle(.gemma4E2BSmall)
        }

        let gathered = gather.gather([token])
        let inputs: [String: NDArray] = [
            "inputs_embeds": fill(
                coreDescriptor,
                "inputs_embeds",
                [1, 1, Self.hiddenSize],
                gathered.inputsEmbeds.map(Float16.init)
            ),
            "per_layer_inputs": fill(
                coreDescriptor,
                "per_layer_inputs",
                [1, 1, Self.perLayerCount, Self.perLayerWidth],
                gathered.perLayerInputs.map(Float16.init)
            ),
            "position_ids": int32(coreDescriptor, "position_ids", position),
            "causal_mask_full": fill(coreDescriptor, "causal_mask_full", [1, 1, 1, contextLength + 1], fullMask(position)),
            "causal_mask_sliding": fill(coreDescriptor, "causal_mask_sliding", [1, 1, 1, contextLength + 1], slidingMask(position)),
            "sliding_k": fill(coreDescriptor, "sliding_k", [Self.slidingSlotCount, 1, 1, contextLength, Self.slidingHeadSize], slidingKeys),
            "sliding_v": fill(coreDescriptor, "sliding_v", [Self.slidingSlotCount, 1, 1, contextLength, Self.slidingHeadSize], slidingValues),
            "full_k": fill(coreDescriptor, "full_k", [Self.fullSlotCount, 1, 1, contextLength, Self.fullHeadSize], fullKeys),
            "full_v": fill(coreDescriptor, "full_v", [Self.fullSlotCount, 1, 1, contextLength, Self.fullHeadSize], fullValues)
        ]

        var output = try await coreFunction.run(inputs: inputs)
        var nextToken = -1
        var hidden: [Float] = []
        if needsToken {
            guard let hiddenValue = output.remove("hidden"),
                  let hiddenArray = hiddenValue.ndArray else {
                throw CoreAIGemmaProviderError.invalidModelBundle(.gemma4E2BSmall)
            }
            hidden = flattenAsFloat(hiddenArray)
        }

        if let value = output.remove("sliding_k_cur"), let array = value.ndArray {
            writeCurrent(&slidingKeys, flattenAsFloat(array), slotCount: Self.slidingSlotCount, width: Self.slidingHeadSize, position: position)
        }
        if let value = output.remove("sliding_v_cur"), let array = value.ndArray {
            writeCurrent(&slidingValues, flattenAsFloat(array), slotCount: Self.slidingSlotCount, width: Self.slidingHeadSize, position: position)
        }
        if let value = output.remove("full_k_cur"), let array = value.ndArray {
            writeCurrent(&fullKeys, flattenAsFloat(array), slotCount: Self.fullSlotCount, width: Self.fullHeadSize, position: position)
        }
        if let value = output.remove("full_v_cur"), let array = value.ndArray {
            writeCurrent(&fullValues, flattenAsFloat(array), slotCount: Self.fullSlotCount, width: Self.fullHeadSize, position: position)
        }

        if needsToken {
            let hiddenInput = fill(headDescriptor, "hidden", [1, 1, Self.hiddenSize], hidden.map(Float16.init))
            var headOutput = try await headFunction.run(inputs: ["hidden": hiddenInput])
            guard let partialValues = headOutput.remove("partial_values")?.ndArray,
                  let partialIndices = headOutput.remove("partial_indices")?.ndArray else {
                throw CoreAIGemmaProviderError.invalidModelBundle(.gemma4E2BSmall)
            }
            nextToken = reducePartials(partialValues, partialIndices)
        }

        return nextToken
    }

    private func promptTokenIDs(for prompt: String, tokenizer: Tokenizer) throws -> [Int32] {
        if let tokens = try? tokenizer.applyChatTemplate(messages: [["role": "user", "content": prompt]]) {
            return tokens.map(Int32.init)
        }
        let text = "<bos><start_of_turn>user\n\(prompt)<end_of_turn>\n<start_of_turn>model\n"
        return tokenizer.encode(text: text).map(Int32.init)
    }

    private static func cleanDecodedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<end_of_turn>", with: "")
            .replacingOccurrences(of: "<start_of_turn>model", with: "")
            .replacingOccurrences(of: "<start_of_turn>user", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeCurrent(_ cache: inout [Float16], _ current: [Float], slotCount: Int, width: Int, position: Int) {
        for slot in 0..<slotCount {
            let destination = slot * contextLength * width + position * width
            let source = slot * width
            for column in 0..<width {
                cache[destination + column] = Float16(current[source + column])
            }
        }
    }

    private func fullMask(_ position: Int) -> [Float16] {
        var mask = [Float16](repeating: Self.maskNegative, count: contextLength + 1)
        let clippedPosition = min(max(position, 0), contextLength - 1)
        if clippedPosition > 0 {
            for index in 0..<clippedPosition {
                mask[index] = 0
            }
        }
        mask[contextLength] = 0
        return mask
    }

    private func slidingMask(_ position: Int) -> [Float16] {
        var mask = [Float16](repeating: Self.maskNegative, count: contextLength + 1)
        let clippedPosition = min(max(position, 0), contextLength - 1)
        let lowerBound = max(0, clippedPosition - Self.slidingWindow + 1)
        if lowerBound < clippedPosition {
            for index in lowerBound..<clippedPosition {
                mask[index] = 0
            }
        }
        mask[contextLength] = 0
        return mask
    }

    private func readInt32(_ array: NDArray) -> Int32 {
        var value: Int32 = 0
        array.view(as: Int32.self).withUnsafePointer { pointer, _, _ in
            value = pointer[0]
        }
        return value
    }

    private func reducePartials(_ partialValues: NDArray, _ partialIndices: NDArray) -> Int {
        let values = flattenAsFloat(partialValues)
        guard !values.isEmpty else {
            return -1
        }
        var indices = [Int32](repeating: 0, count: values.count)
        partialIndices.view(as: Int32.self).withUnsafePointer { pointer, _, _ in
            for index in 0..<indices.count {
                indices[index] = pointer[index]
            }
        }
        var bestIndex = 0
        var bestValue = values[0]
        for index in 1..<values.count where values[index] > bestValue {
            bestValue = values[index]
            bestIndex = index
        }
        return Int(indices[bestIndex])
    }

    private func fill(
        _ descriptor: InferenceFunctionDescriptor,
        _ name: String,
        _ shape: [Int],
        _ data: [Float16]
    ) -> NDArray {
        var array = allocate(descriptor, name, shape, kind: "input")
        fillNDArray(&array, as: Float16.self, with: data)
        return array
    }

    private func int32(_ descriptor: InferenceFunctionDescriptor, _ name: String, _ value: Int) -> NDArray {
        var array = allocate(descriptor, name, [1, 1], kind: "input")
        fillNDArray(&array, as: Int32.self, with: [Int32(value)])
        return array
    }

    private func allocate(
        _ descriptor: InferenceFunctionDescriptor,
        _ name: String,
        _ shape: [Int],
        kind: String
    ) -> NDArray {
        let ioDescriptor = kind == "input" ? descriptor.inputDescriptor(of: name) : descriptor.outputDescriptor(of: name)
        guard case .ndArray(let arrayDescriptor)? = ioDescriptor else {
            fatalError("\(name) is not an NDArray")
        }
        return NDArray(descriptor: arrayDescriptor.resolvingDynamicDimensions(shape))
    }
}
