import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    @Published var selectedModel: LLMModel
    @Published var openAIAPIKey: String {
        didSet { persistAPIKey(openAIAPIKey, key: Self.openAIStorageKey) }
    }
    @Published var geminiAPIKey: String {
        didSet { persistAPIKey(geminiAPIKey, key: Self.geminiStorageKey) }
    }
    @Published var autoApplyStoredRedactions: Bool {
        didSet { UserDefaults.standard.set(autoApplyStoredRedactions, forKey: Self.autoRedactionKey) }
    }
    @Published var preferredLanguage: String {
        didSet { UserDefaults.standard.set(preferredLanguage, forKey: Self.languageKey) }
    }
    @Published var forceDarkMode: Bool {
        didSet { UserDefaults.standard.set(forceDarkMode, forKey: Self.darkModeKey) }
    }

    private static let selectedModelKey = "settings.selectedModel"
    private static let openAIStorageKey = "settings.openai"
    private static let geminiStorageKey = "settings.gemini"
    private static let autoRedactionKey = "settings.autoRedactions"
    private static let languageKey = "settings.language"
    private static let darkModeKey = "settings.darkMode"

    init() {
        if let storedModelData = UserDefaults.standard.data(forKey: Self.selectedModelKey),
           let model = try? JSONDecoder().decode(LLMModel.self, from: storedModelData) {
            selectedModel = model
        } else {
            selectedModel = LLMModel.defaults.first ?? LLMModel(displayName: "GPT-4o", provider: .openAI, apiIdentifier: "gpt-4o")
        }
        openAIAPIKey = Self.retrieveAPIKey(for: Self.openAIStorageKey)
        geminiAPIKey = Self.retrieveAPIKey(for: Self.geminiStorageKey)
        autoApplyStoredRedactions = UserDefaults.standard.object(forKey: Self.autoRedactionKey) as? Bool ?? true
        preferredLanguage = UserDefaults.standard.string(forKey: Self.languageKey) ?? "en"
        forceDarkMode = UserDefaults.standard.object(forKey: Self.darkModeKey) as? Bool ?? false

        $selectedModel
            .sink { model in
                if let data = try? JSONEncoder().encode(model) {
                    UserDefaults.standard.set(data, forKey: Self.selectedModelKey)
                }
            }
            .store(in: &cancellables)
    }

    private var cancellables: Set<AnyCancellable> = []

    static func retrieveAPIKey(for key: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? ""
    }

    private func persistAPIKey(_ keyValue: String, key: String) {
        UserDefaults.standard.set(keyValue, forKey: key)
    }
}
