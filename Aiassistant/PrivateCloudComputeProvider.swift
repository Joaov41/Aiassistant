import Foundation
import ImageIO
import Security

#if canImport(FoundationModels)
import FoundationModels
#endif

enum PrivateCloudComputeProviderError: LocalizedError {
    case unsupportedOS
    case frameworkUnavailable
    case missingEntitlement
    case modelUnavailable(String)
    case emptyResponse
    case cancelled
    case visionUnavailable
    case invalidImage(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "Apple Cloud requires macOS 27 or later."
        case .frameworkUnavailable:
            return "Apple Cloud is unavailable because FoundationModels is not present in this build."
        case .missingEntitlement:
            return "Apple Cloud requires Apple's managed Private Cloud Compute entitlement in this app's signing profile."
        case .modelUnavailable(let reason):
            return "Apple Private Cloud Compute is unavailable: \(reason)"
        case .emptyResponse:
            return "Apple Private Cloud Compute returned an empty response."
        case .cancelled:
            return "Apple Private Cloud Compute request was cancelled."
        case .visionUnavailable:
            return "Apple Private Cloud Compute does not report image-understanding capability on this Mac."
        case .invalidImage(let index):
            return "Image \(index + 1) could not be decoded for Apple Private Cloud Compute."
        }
    }
}

@MainActor
final class PrivateCloudComputeProvider: ObservableObject, AIProvider {
    @Published var isProcessing = false

    static var hasRequiredEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.private-cloud-compute" as CFString,
                nil
              ) else {
            return false
        }
        return (value as? Bool) == true
    }

    var availabilityDescription: String {
        guard #available(macOS 27.0, *) else {
            return "Requires macOS 27 or later."
        }
        guard Self.hasRequiredEntitlement else {
            return "Managed Private Cloud Compute entitlement is missing from this app's signature."
        }

        let model = PrivateCloudComputeLanguageModel()
        if model.isAvailable {
            return "Available. The direct Private Cloud Compute model is ready."
        }
        return "Unavailable: \(model.availability)"
    }

    private let tasks = ProviderTaskRegistry<AIResponse>()

    func processText(
        systemPrompt: String?,
        userPrompt: String,
        images: [Data],
        videos: [Data]?
    ) async throws -> AIResponse {
        isProcessing = true
        defer { isProcessing = !tasks.isEmpty }
        return try await tasks.run {
            let promptText = Self.makePromptText(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                videoCount: videos?.count ?? 0
            )
            let output = try await Self.respond(to: promptText, images: images)
            try Task.checkCancellation()
            return AIResponse(text: output, providerName: AIProviderKind.appleCloud.fullDisplayName)
        }
    }

    func cancel() {
        tasks.cancelAll()
        isProcessing = false
    }

    private static func makePromptText(
        systemPrompt: String?,
        userPrompt: String,
        videoCount: Int
    ) -> String {
        var sections: [String] = []
        if let systemPrompt = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !systemPrompt.isEmpty {
            sections.append("Instructions:\n\(systemPrompt)")
        }
        sections.append(userPrompt)
        if videoCount > 0 {
            sections.append("Note: \(videoCount) video(s) were attached, but Apple Cloud currently accepts still-image attachments only. Mention this limitation if the answer depends on a video.")
        }
        return sections.joined(separator: "\n\n")
    }

    private static func respond(to promptText: String, images: [Data]) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 27.0, *) else {
            throw PrivateCloudComputeProviderError.unsupportedOS
        }
        guard hasRequiredEntitlement else {
            throw PrivateCloudComputeProviderError.missingEntitlement
        }

        let model = PrivateCloudComputeLanguageModel()
        guard model.isAvailable else {
            throw PrivateCloudComputeProviderError.modelUnavailable(String(describing: model.availability))
        }

        if !images.isEmpty, !model.capabilities.contains(.vision) {
            throw PrivateCloudComputeProviderError.visionUnavailable
        }

        let imageAttachments: [Attachment<ImageAttachmentContent>] = try images.enumerated().map { index, data in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw PrivateCloudComputeProviderError.invalidImage(index)
            }
            return Attachment(image).label("image-\(index + 1)")
        }

        let prompt = Prompt {
            promptText
            for image in imageAttachments {
                image
            }
        }

        let session = LanguageModelSession(model: model)
        let response = try await session.respond(
            to: prompt,
            contextOptions: ContextOptions(reasoningLevel: .moderate)
        )
        let output = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            throw PrivateCloudComputeProviderError.emptyResponse
        }
        return output
        #else
        throw PrivateCloudComputeProviderError.frameworkUnavailable
        #endif
    }
}
