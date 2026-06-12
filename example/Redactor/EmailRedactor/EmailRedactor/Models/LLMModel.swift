import Foundation

enum LLMProvider: String, CaseIterable, Identifiable, Codable {
    case openAI
    case gemini

    var id: String { rawValue }
}

struct LLMModel: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let displayName: String
    let provider: LLMProvider
    let apiIdentifier: String

    init(id: String? = nil, displayName: String, provider: LLMProvider, apiIdentifier: String) {
        self.id = id ?? apiIdentifier
        self.displayName = displayName
        self.provider = provider
        self.apiIdentifier = apiIdentifier
    }

    static let defaults: [LLMModel] = [
        LLMModel(displayName: "GPT-4o", provider: .openAI, apiIdentifier: "gpt-4o"),
        LLMModel(displayName: "GPT-4.1 Mini (2025-04-14)", provider: .openAI, apiIdentifier: "gpt-4.1-mini-2025-04-14"),
        LLMModel(displayName: "GPT-4.5 Preview (2025-02-27)", provider: .openAI, apiIdentifier: "gpt-4.5-preview-2025-02-27"),
        LLMModel(displayName: "GPT-4.1 (2025-04-14)", provider: .openAI, apiIdentifier: "gpt-4.1-2025-04-14"),
        LLMModel(displayName: "GPT-4.1 Nano (2025-04-14)", provider: .openAI, apiIdentifier: "gpt-4.1-nano-2025-04-14"),
        LLMModel(displayName: "GPT-5 (2025-08-07)", provider: .openAI, apiIdentifier: "gpt-5-2025-08-07"),
        LLMModel(displayName: "GPT-5 Mini (2025-08-07)", provider: .openAI, apiIdentifier: "gpt-5-mini-2025-08-07"),
        LLMModel(displayName: "GPT-5 Nano (2025-08-07)", provider: .openAI, apiIdentifier: "gpt-5-nano-2025-08-07"),
        LLMModel(displayName: "Gemini 3", provider: .gemini, apiIdentifier: "gemini-3-pro-preview"),
        LLMModel(displayName: "Gemini 2.5 Flash", provider: .gemini, apiIdentifier: "gemini-flash-latest")
    ]
}
