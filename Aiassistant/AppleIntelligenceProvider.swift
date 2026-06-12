import Foundation
import AppKit
import CoreGraphics
import FoundationModels

/// AI provider backed by Apple's on-device Foundation Model (FoundationModels framework, macOS 27 API).
/// Runs entirely locally via Apple Intelligence — no API key, no network calls.
class AppleIntelligenceProvider: ObservableObject, AIProvider {
    @Published var isProcessing = false

    private let model = SystemLanguageModel.default
    private var currentTask: Task<Void, Never>?

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

        // The on-device model understands images (macOS 27 multimodal prompts) but not video.
        var promptText = Self.truncateIfNeeded(userPrompt)
        if let videos, !videos.isEmpty {
            promptText += "\n\n(Note: the user attached \(videos.count) video file(s), but video analysis isn't supported by the on-device model. Answer based on the text and any images, and mention this limitation if relevant.)"
        }

        let attachments = images.compactMap { Self.imageAttachment(from: $0) }
        if attachments.count < images.count {
            print("AppleIntelligenceProvider: \(images.count - attachments.count) image(s) could not be decoded and were skipped.")
        }

        let session = LanguageModelSession(model: model, instructions: systemPrompt)

        let prompt = Prompt {
            promptText
            for attachment in attachments {
                attachment
            }
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

    /// Keep prompts comfortably inside the on-device model's context window.
    /// Web pages and PDFs can be huge; trim the middle to preserve the head and tail.
    private static func truncateIfNeeded(_ text: String, maxCharacters: Int = 24_000) -> String {
        guard text.count > maxCharacters else { return text }
        let headCount = maxCharacters * 3 / 4
        let tailCount = maxCharacters - headCount
        let head = text.prefix(headCount)
        let tail = text.suffix(tailCount)
        return "\(head)\n\n[... content truncated to fit the on-device model's context window ...]\n\n\(tail)"
    }

    private static func imageAttachment(from data: Data) -> Attachment<ImageAttachmentContent>? {
        guard let nsImage = NSImage(data: data),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return Attachment(cgImage)
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
