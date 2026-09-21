import Foundation

enum AIProviderKind: String, CaseIterable, Identifiable {
    case localAppleFoundation = "local_apple_foundation"
    case appleCloud = "apple_cloud"
    case coreAIGemma = "core_ai_gemma"
    case localOpenAI = "local_openai"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localAppleFoundation:
            return "Local"
        case .appleCloud:
            return "Apple Cloud"
        case .coreAIGemma:
            return "Local MLX"
        case .localOpenAI:
            return "Local OpenAI"
        }
    }

    var fullDisplayName: String {
        switch self {
        case .localAppleFoundation:
            return "Apple Foundation Model (On-Device)"
        case .appleCloud:
            return "Apple Private Cloud Compute"
        case .coreAIGemma:
            return "Local MLX Gemma"
        case .localOpenAI:
            return "Local OpenAI-Compatible Server"
        }
    }

    var description: String {
        switch self {
        case .localAppleFoundation:
            return "Runs locally via Apple Intelligence. No API key needed, and your data stays on this Mac."
        case .appleCloud:
            return "Uses Apple's direct Private Cloud Compute model through FoundationModels. No gateway is needed."
        case .coreAIGemma:
            return "Uses a local MLX server on this Mac. Full document context is sent to the local endpoint."
        case .localOpenAI:
            return "Connects to any OpenAI-compatible local server you run yourself. The app never starts this server."
        }
    }
}

// A singleton for app-wide settings that wraps UserDefaults access
class AppSettings: ObservableObject {
    nonisolated(unsafe) static let shared = AppSettings()
    
    private let defaults: UserDefaults
    private let credentialStore: any LocalServerCredentialStore

    // MARK: - Published Settings
    @Published var shortcutText: String {
        didSet { defaults.set(shortcutText, forKey: "shortcut") }
    }
    
    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: "has_completed_onboarding") }
    }
    
    @Published var useGradientTheme: Bool {
        didSet { defaults.set(useGradientTheme, forKey: "use_gradient_theme") }
    }

    @Published var selectedAIProvider: AIProviderKind {
        didSet { defaults.set(selectedAIProvider.rawValue, forKey: "selected_ai_provider") }
    }

    @Published var selectedCoreAIGemmaModel: CoreAIGemmaModel {
        didSet { defaults.set(selectedCoreAIGemmaModel.rawValue, forKey: "selected_core_ai_gemma_model") }
    }

    @Published var localOpenAIBaseURL: String {
        didSet { defaults.set(localOpenAIBaseURL, forKey: "local_openai_base_url") }
    }

    @Published var localOpenAIModelID: String {
        didSet { defaults.set(localOpenAIModelID, forKey: "local_openai_model_id") }
    }

    @Published var localOpenAIAPIKey: String {
        didSet {
            do {
                try credentialStore.write(localOpenAIAPIKey)
                defaults.removeObject(forKey: "local_openai_api_key")
                localOpenAICredentialError = nil
            } catch {
                localOpenAICredentialError = "API key could not be saved to Keychain: \(error.localizedDescription)"
            }
        }
    }

    @Published private(set) var localOpenAICredentialError: String?

    @Published var localOpenAIMaxTokens: Int {
        didSet {
            let validValue = Self.validOutputTokenLimit(localOpenAIMaxTokens)
            guard localOpenAIMaxTokens == validValue else {
                localOpenAIMaxTokens = validValue
                return
            }
            defaults.set(validValue, forKey: "local_openai_max_tokens")
        }
    }

    static func validOutputTokenLimit(_ value: Int) -> Int { min(131_072, max(1, value)) }

    @Published var localOpenAIDisableThinking: Bool {
        didSet { defaults.set(localOpenAIDisableThinking, forKey: "local_openai_disable_thinking") }
    }

    // Custom Quick Actions
    @Published var customQuickActions: [String] {
        didSet { defaults.set(customQuickActions, forKey: "custom_quick_actions") }
    }

    // MARK: - HotKey data
    @Published var hotKeyCode: Int {
        didSet { defaults.set(hotKeyCode, forKey: "hotKey_keyCode") }
    }
    @Published var hotKeyModifiers: Int {
        didSet { defaults.set(hotKeyModifiers, forKey: "hotKey_modifiers") }
    }

    // MARK: - Init
    init(defaults: UserDefaults = .standard, credentialStore: any LocalServerCredentialStore = KeychainLocalServerCredentialStore()) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        let storedProvider = defaults.string(forKey: "selected_ai_provider") ?? ""
        let selectedProvider = storedProvider == "apple_pcc"
            ? AIProviderKind.appleCloud
            : AIProviderKind(rawValue: storedProvider) ?? .localAppleFoundation
        
        // Load or set defaults
        self.shortcutText = defaults.string(forKey: "shortcut") ?? "⌥ Space"
        self.hasCompletedOnboarding = defaults.bool(forKey: "has_completed_onboarding")
        self.useGradientTheme = defaults.bool(forKey: "use_gradient_theme")
        self.selectedAIProvider = selectedProvider
        self.selectedCoreAIGemmaModel = CoreAIGemmaModel(
            rawValue: defaults.string(forKey: "selected_core_ai_gemma_model") ?? ""
        ) ?? .gemma4_12B
        self.localOpenAIBaseURL = defaults.string(forKey: "local_openai_base_url") ?? LocalOpenAIEndpoint.defaultBaseURL
        self.localOpenAIModelID = defaults.string(forKey: "local_openai_model_id") ?? "local-model"
        let legacyKey = defaults.string(forKey: "local_openai_api_key") ?? ""
        do {
            if let storedKey = try credentialStore.read() {
                self.localOpenAIAPIKey = storedKey
                defaults.removeObject(forKey: "local_openai_api_key")
            } else {
                self.localOpenAIAPIKey = legacyKey
                if !legacyKey.isEmpty {
                    try credentialStore.write(legacyKey)
                    defaults.removeObject(forKey: "local_openai_api_key")
                }
            }
        } catch {
            self.localOpenAIAPIKey = legacyKey
            self.localOpenAICredentialError = "API key migration to Keychain is pending: \(error.localizedDescription)"
        }
        let tokenLimit = defaults.object(forKey: "local_openai_max_tokens") as? Int ?? 1024
        self.localOpenAIMaxTokens = Self.validOutputTokenLimit(tokenLimit)
        self.localOpenAIDisableThinking = defaults.bool(forKey: "local_openai_disable_thinking")
        self.customQuickActions = defaults.stringArray(forKey: "custom_quick_actions") ?? []

        // HotKey
        self.hotKeyCode = defaults.integer(forKey: "hotKey_keyCode")
        self.hotKeyModifiers = defaults.integer(forKey: "hotKey_modifiers")

        if storedProvider == "apple_pcc" {
            defaults.set(selectedProvider.rawValue, forKey: "selected_ai_provider")
        }
    }
    
    // MARK: - Convenience
    func resetAll() {
        localOpenAIAPIKey = ""
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
    }
}
