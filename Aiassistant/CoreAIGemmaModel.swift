import Foundation

enum CoreAIGemmaModel: String, CaseIterable, Identifiable {
    case gemma4E2BSmall = "gemma4_e2b_small"
    case gemma3_4BSmall = "gemma3_4b_small"
    case gemma4_12B = "gemma4_12b"
    case gemma4_31B = "gemma4_31b"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemma4E2BSmall:
            return "Small E2B"
        case .gemma3_4BSmall:
            return "Small 4B"
        case .gemma4_12B:
            return "12B"
        case .gemma4_31B:
            return "31B"
        }
    }

    var fullDisplayName: String {
        switch self {
        case .gemma4E2BSmall:
            return "Gemma 4 E2B Small"
        case .gemma3_4BSmall:
            return "Gemma 3 4B IT Small"
        case .gemma4_12B:
            return "Gemma 4 12B"
        case .gemma4_31B:
            return "Gemma 4 31B"
        }
    }

    var detail: String {
        switch self {
        case .gemma4E2BSmall:
            return "Fast lower-resource Gemma 4 model served by local MLX."
        case .gemma3_4BSmall:
            return "Small Gemma 4 E4B model served by local MLX."
        case .gemma4_12B:
            return "Larger Gemma 4 MLX model; default Gemma choice."
        case .gemma4_31B:
            return "High-memory Gemma 4 MLX model."
        }
    }

    var mlxModelID: String {
        switch self {
        case .gemma4E2BSmall:
            return "mlx-community/gemma-4-e2b-it-4bit"
        case .gemma3_4BSmall:
            return "mlx-community/gemma-4-e4b-it-4bit"
        case .gemma4_12B:
            return "mlx-community/gemma-4-12B-it-4bit"
        case .gemma4_31B:
            return "mlx-community/gemma-4-31b-it-4bit"
        }
    }

    var mlxVisionModelID: String {
        "mlx-community/gemma-4-E2B-it-qat-4bit"
    }

    var repo: String {
        switch self {
        case .gemma4E2BSmall:
            return "https://huggingface.co/mlboydaisuke/gemma-4-E2B-CoreAI"
        case .gemma3_4BSmall:
            return "https://huggingface.co/mlboydaisuke/gemma-3-4b-it-CoreAI-official"
        case .gemma4_12B:
            return "https://huggingface.co/mlboydaisuke/Gemma-4-12B-CoreAI"
        case .gemma4_31B:
            return "https://huggingface.co/mlboydaisuke/Gemma-4-31B-CoreAI"
        }
    }

    var remotePath: String {
        switch self {
        case .gemma4E2BSmall:
            return "macos"
        case .gemma3_4BSmall:
            return "macos"
        case .gemma4_12B:
            return "gpu-pipelined/gemma4_12b_qat_decode_int8lin_msdpa_g8"
        case .gemma4_31B:
            return "gpu-pipelined/gemma4_31b_qat_decode_int4linsym_msdpa_g8"
        }
    }

    var supportDownloads: [CoreAIGemmaSupportDownload] {
        switch self {
        case .gemma4E2BSmall:
            return [
                CoreAIGemmaSupportDownload(
                    remotePath: "ios-frontend/gemma4_gather_raw",
                    localDirectoryName: "gemma4_gather_raw",
                    requiredFiles: [
                        "embed_tokens.i8",
                        "embed_tokens.scale.f32",
                        "embed_per_layer.i8",
                        "embed_per_layer.scale.f32",
                        "meta.json",
                        "proj.f32",
                        "proj_norm.f32"
                    ]
                ),
                CoreAIGemmaSupportDownload(
                    remotePath: "gpu-pipelined/gemma4_e2b_decode_int4lin_tbl/tokenizer",
                    localDirectoryName: "tokenizer",
                    requiredFiles: [
                        "tokenizer.json",
                        "tokenizer_config.json"
                    ]
                )
            ]
        case .gemma3_4BSmall, .gemma4_12B, .gemma4_31B:
            return []
        }
    }

    var staticInputFiles: [String: String] {
        switch self {
        case .gemma4E2BSmall:
            return [:]
        case .gemma3_4BSmall, .gemma4_12B, .gemma4_31B:
            return [:]
        }
    }

    var requiredModelPaths: [String] {
        switch self {
        case .gemma4E2BSmall:
            return [
                "gemma4_e2b_metal_int8v3_L35.aimodel",
                "gemma4_e2b_head_argmax_kernel.aimodel"
            ]
        case .gemma3_4BSmall, .gemma4_12B, .gemma4_31B:
            return []
        }
    }

    var downloadedModelPathPrefixes: [String] {
        switch self {
        case .gemma4E2BSmall:
            return [
                "gemma4_e2b_metal_int8v3_L35.aimodel",
                "gemma4_e2b_head_argmax_kernel.aimodel"
            ]
        case .gemma3_4BSmall, .gemma4_12B, .gemma4_31B:
            return []
        }
    }

    var requiresBundleMetadata: Bool {
        switch self {
        case .gemma4E2BSmall:
            return false
        case .gemma3_4BSmall, .gemma4_12B, .gemma4_31B:
            return true
        }
    }

    var localDirectoryName: String {
        switch self {
        case .gemma4E2BSmall:
            return rawValue
        case .gemma3_4BSmall:
            return "gemma_3_4b_it_official"
        case .gemma4_12B, .gemma4_31B:
            return rawValue
        }
    }

    var approximateSizeDescription: String {
        switch self {
        case .gemma4E2BSmall:
            return "downloaded by MLX on first server start"
        case .gemma3_4BSmall:
            return "downloaded by MLX on first server start"
        case .gemma4_12B:
            return "downloaded by MLX on first server start"
        case .gemma4_31B:
            return "downloaded by MLX on first server start"
        }
    }

    var engineVariant: String? {
        switch self {
        case .gemma4E2BSmall:
            return nil
        case .gemma3_4BSmall, .gemma4_12B, .gemma4_31B:
            return "coreai-sequential"
        }
    }

    var fallbackChatTemplate: String? {
        switch self {
        case .gemma4E2BSmall:
            return "<bos><start_of_turn>user\n%@<end_of_turn>\n<start_of_turn>model\n"
        case .gemma3_4BSmall, .gemma4_12B, .gemma4_31B:
            return nil
        }
    }
}

struct CoreAIGemmaSupportDownload: Equatable {
    let remotePath: String
    let localDirectoryName: String
    let requiredFiles: [String]
}

enum CoreAIGemmaModelStore {
    static let applicationSupportFolderName = "Aiassistant/CoreAIModels"

    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(applicationSupportFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func directory(for model: CoreAIGemmaModel, in baseDirectory: URL = modelsDirectory) -> URL {
        baseDirectory.appendingPathComponent(model.localDirectoryName, isDirectory: true)
    }

    static func stagingDirectory(for model: CoreAIGemmaModel, in baseDirectory: URL = modelsDirectory) -> URL {
        baseDirectory.appendingPathComponent(".staging-\(model.localDirectoryName)", isDirectory: true)
    }

    static func isInstalled(_ model: CoreAIGemmaModel, in baseDirectory: URL = modelsDirectory) -> Bool {
        let directory = directory(for: model, in: baseDirectory)
        return isCompleteInstallation(for: model, in: directory)
    }

    static func isCompleteInstallation(for model: CoreAIGemmaModel, in directory: URL) -> Bool {
        if model.requiresBundleMetadata,
           !FileManager.default.fileExists(atPath: directory.appendingPathComponent("metadata.json").path) {
            return false
        }
        guard requiredModelFilesExist(for: model, in: directory) else {
            return false
        }
        guard containsAimodelBundle(at: directory) else {
            return false
        }
        return requiredSupportFilesExist(for: model, in: directory)
    }

    static func requiredModelFilesExist(for model: CoreAIGemmaModel, in directory: URL) -> Bool {
        model.requiredModelPaths.allSatisfy { relativePath in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(relativePath).path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
        }
    }

    static func requiredSupportFilesExist(for model: CoreAIGemmaModel, in directory: URL) -> Bool {
        model.supportDownloads.allSatisfy { download in
            download.requiredFiles.allSatisfy { file in
                FileManager.default.fileExists(
                    atPath: directory
                        .appendingPathComponent(download.localDirectoryName, isDirectory: true)
                        .appendingPathComponent(file)
                        .path
                )
            }
        }
    }

    static func containsAimodelBundle(at directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for case let url as URL in enumerator {
            if url.pathExtension == "aimodel" || url.pathExtension == "aimodelc" {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    return true
                }
            }
        }
        return false
    }
}
