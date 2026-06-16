import Accelerate
import Foundation

final class CoreAIGemmaMacE2BGather {
    struct Meta: Decodable {
        let V: Int
        let D: Int
        let PLD: Int
        let L: Int
        let ld: Int
        let embed_scale_main: Float
        let embed_scale_pl: Float
        let proj_scale: Float
        let input_scale: Float
        let rms_eps: Float
    }

    let meta: Meta
    private let qEmbed: UnsafePointer<Int8>
    private let qPerLayer: UnsafePointer<Int8>
    private let embedScale: [Float]
    private let perLayerScale: [Float]
    private let projWeights: [Float]
    private let normWeights: [Float]

    init(directory: URL) throws {
        func floats(_ name: String) throws -> [Float] {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }

        meta = try JSONDecoder().decode(
            Meta.self,
            from: try Data(contentsOf: directory.appendingPathComponent("meta.json"))
        )
        qEmbed = try Self.mmapInt8(
            directory.appendingPathComponent("embed_tokens.i8"),
            expectedByteCount: meta.V * meta.D
        )
        qPerLayer = try Self.mmapInt8(
            directory.appendingPathComponent("embed_per_layer.i8"),
            expectedByteCount: meta.V * meta.PLD
        )
        embedScale = try floats("embed_tokens.scale.f32")
        perLayerScale = try floats("embed_per_layer.scale.f32")
        projWeights = try floats("proj.f32")
        normWeights = try floats("proj_norm.f32")
    }

    func gather(_ tokenIDs: [Int32]) -> (inputsEmbeds: [Float], perLayerInputs: [Float]) {
        let sequenceLength = tokenIDs.count
        let hiddenSize = meta.D
        let perLayerSize = meta.PLD
        let layerCount = meta.L
        let layerWidth = meta.ld

        var inputsEmbeds = [Float](repeating: 0, count: sequenceLength * hiddenSize)
        var tokenRows = [Float](repeating: 0, count: sequenceLength * perLayerSize)

        for (index, tokenID) in tokenIDs.enumerated() {
            let row = Int(tokenID)
            let embedMultiplier = embedScale[row] * meta.embed_scale_main
            let embedBase = row * hiddenSize
            let embedOut = index * hiddenSize
            for column in 0..<hiddenSize {
                inputsEmbeds[embedOut + column] = Float(qEmbed[embedBase + column]) * embedMultiplier
            }

            let perLayerMultiplier = perLayerScale[row] * meta.embed_scale_pl
            let perLayerBase = row * perLayerSize
            let perLayerOut = index * perLayerSize
            for column in 0..<perLayerSize {
                tokenRows[perLayerOut + column] = Float(qPerLayer[perLayerBase + column]) * perLayerMultiplier
            }
        }

        var projected = [Float](repeating: 0, count: sequenceLength * perLayerSize)
        inputsEmbeds.withUnsafeBufferPointer { inputPointer in
            projWeights.withUnsafeBufferPointer { weightPointer in
                projected.withUnsafeMutableBufferPointer { outputPointer in
                    cblas_sgemm(
                        CblasRowMajor,
                        CblasNoTrans,
                        CblasTrans,
                        Int32(sequenceLength),
                        Int32(perLayerSize),
                        Int32(hiddenSize),
                        meta.proj_scale,
                        inputPointer.baseAddress,
                        Int32(hiddenSize),
                        weightPointer.baseAddress,
                        Int32(hiddenSize),
                        0,
                        outputPointer.baseAddress,
                        Int32(perLayerSize)
                    )
                }
            }
        }

        var perLayerInputs = [Float](repeating: 0, count: sequenceLength * perLayerSize)
        for tokenIndex in 0..<sequenceLength {
            for layer in 0..<layerCount {
                let offset = tokenIndex * perLayerSize + layer * layerWidth
                var squaredSum: Float = 0
                for column in 0..<layerWidth {
                    let value = projected[offset + column]
                    squaredSum += value * value
                }
                let inverseRMS = 1 / (squaredSum / Float(layerWidth) + meta.rms_eps).squareRoot()
                for column in 0..<layerWidth {
                    perLayerInputs[offset + column] = (
                        projected[offset + column] * inverseRMS * normWeights[column]
                        + tokenRows[offset + column]
                    ) * meta.input_scale
                }
            }
        }
        return (inputsEmbeds, perLayerInputs)
    }

    private static func mmapInt8(_ url: URL, expectedByteCount: Int) throws -> UnsafePointer<Int8> {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw CoreAIGemmaProviderError.missingSupportFile(url.lastPathComponent)
        }
        defer { close(fd) }

        var statInfo = Darwin.stat()
        guard fstat(fd, &statInfo) == 0, Int(statInfo.st_size) == expectedByteCount else {
            throw CoreAIGemmaProviderError.staticBufferAllocationFailed(url.lastPathComponent)
        }
        guard let pointer = mmap(nil, expectedByteCount, PROT_READ, MAP_PRIVATE, fd, 0),
              pointer != MAP_FAILED else {
            throw CoreAIGemmaProviderError.staticBufferAllocationFailed(url.lastPathComponent)
        }
        madvise(pointer, expectedByteCount, MADV_RANDOM)
        return UnsafeRawPointer(pointer).assumingMemoryBound(to: Int8.self)
    }
}
