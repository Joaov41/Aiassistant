import Foundation
import FoundationModels

/// AI provider backed by Apple's on-device Foundation Model (FoundationModels framework, macOS 27 API).
/// Runs entirely locally via Apple Intelligence — no API key, no network calls.
class AppleIntelligenceProvider: ObservableObject, AIProvider {
    @Published var isProcessing = false

    private let model = SystemLanguageModel.default
    private let pccFallbackProvider: FMPCCProvider?
    private var currentTask: Task<Void, Never>?

    init(pccFallbackProvider: FMPCCProvider? = nil) {
        self.pccFallbackProvider = pccFallbackProvider
    }

    // MARK: - Availability

    var isAvailable: Bool {
        if case .available = model.availability { return true }
        return false
    }

    var availabilityDescription: String {
        switch model.availability {
        case .available:
            return "Apple Intelligence is available. The on-device foundation model is ready."
        case .unavailable(let reason):
            return Self.describe(unavailableReason: reason)
        }
    }

    private static func describe(unavailableReason reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac doesn't support Apple Intelligence, so the on-device model can't be used."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is turned off. Enable it in System Settings > Apple Intelligence & Siri."
        case .modelNotReady:
            return "The on-device model is still downloading or preparing. Try again in a few minutes."
        @unknown default:
            return "The on-device model is currently unavailable."
        }
    }

    // MARK: - AIProvider

    func processText(systemPrompt: String?, userPrompt: String, images: [Data], videos: [Data]?) async throws -> AIResponse {
        isProcessing = true
        defer { isProcessing = false }

        guard case .available = model.availability else {
            throw NSError(
                domain: "AppleIntelligence",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: availabilityDescription]
            )
        }

        let promptText = Self.localPromptText(from: userPrompt, images: images, videos: videos)
        if !images.isEmpty {
            print("AppleIntelligenceProvider: skipped \(images.count) image attachment(s) because this FoundationModels runtime does not expose the image attachment API.")
        }

        let session = LanguageModelSession(model: model, instructions: systemPrompt)

        let prompt = Prompt {
            promptText
        }

        do {
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(temperature: 0.7)
            )
            print("AppleIntelligenceProvider: responded using \(response.usage.totalTokenCount) tokens (input: \(response.usage.input.totalTokenCount), output: \(response.usage.output.totalTokenCount))")
            // The local foundation model is text-only on output; it never returns generated images.
            return AIResponse(text: response.content, providerName: AIProviderKind.localAppleFoundation.fullDisplayName)
        } catch {
            if Self.shouldRouteToPCCGateway(for: error), let pccFallbackProvider {
                let fallbackResponse = try await pccFallbackProvider.processText(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    images: images,
                    videos: videos
                )
                return AIResponse(
                    text: "\(Self.pccFallbackNotice)\n\n\(fallbackResponse.text)",
                    images: fallbackResponse.images,
                    providerName: fallbackResponse.providerName,
                    pccTranscriptName: fallbackResponse.pccTranscriptName
                )
            }

            throw NSError(
                domain: "AppleIntelligence",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: Self.friendlyMessage(for: error)]
            )
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isProcessing = false
    }

    // MARK: - Helpers

    static let pccFallbackNotice = "Local model context limit reached. Switched to Apple PCC."

    private static func localPromptText(from userPrompt: String, images: [Data], videos: [Data]?) -> String {
        var notes: [String] = []
        if !images.isEmpty {
            notes.append("the user attached \(images.count) image file(s), but image analysis is temporarily disabled for the on-device model on this FoundationModels runtime")
        }
        if let videos, !videos.isEmpty {
            notes.append("the user attached \(videos.count) video file(s), but video analysis isn't supported by the on-device model")
        }
        guard !notes.isEmpty else { return userPrompt }
        return "\(userPrompt)\n\n(Note: \(notes.joined(separator: "; ")). Answer based on the text, and mention this limitation if relevant.)"
    }

    static func shouldRouteToPCCGateway(for error: Error) -> Bool {
        if let languageModelError = error as? LanguageModelError {
            if case .contextSizeExceeded = languageModelError {
                return true
            }
        }

        if let generationError = error as? LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = generationError {
                return true
            }
        }

        let message = (error as NSError).localizedDescription.lowercased()
        return message.contains("context")
            && (message.contains("exceeded")
                || message.contains("too large")
                || message.contains("window"))
    }

    private static func friendlyMessage(for error: Error) -> String {
        if let generationError = error as? LanguageModelSession.GenerationError {
            switch generationError {
            case .exceededContextWindowSize:
                return "The request is too long for the on-device model. Try a shorter selection or fewer attachments."
            case .guardrailViolation:
                return "The on-device model declined this request due to its safety guardrails. Try rephrasing your request."
            case .refusal:
                return "The on-device model declined to answer this request. Try rephrasing it."
            case .rateLimited:
                return "The on-device model is busy. Please try again in a moment."
            case .assetsUnavailable:
                return "The on-device model assets aren't available right now. Make sure Apple Intelligence has finished downloading."
            case .unsupportedLanguageOrLocale:
                return "The on-device model doesn't support this language yet."
            default:
                return generationError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
