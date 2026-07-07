import Foundation

enum AIProviderKind: String, CaseIterable, Identifiable {
    case localAppleFoundation = "local_apple_foundation"
    case applePCC = "apple_pcc"
    case coreAIGemma = "core_ai_gemma"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localAppleFoundation:
            return "Local"
        case .applePCC:
            return "Apple PCC"
        case .coreAIGemma:
            return "Local MLX"
        }
    }

    var fullDisplayName: String {
        switch self {
        case .localAppleFoundation:
            return "Apple Foundation Model (On-Device)"
        case .applePCC:
            return "Apple PCC"
        case .coreAIGemma:
            return "Local MLX Gemma"
        }
    }

    var description: String {
        switch self {
        case .localAppleFoundation:
            return "Runs locally via Apple Intelligence. No API key needed, and your data stays on this Mac."
        case .applePCC:
            return "Uses Apple PCC. No gateway is needed for this Mac app."
        case .coreAIGemma:
            return "Uses a local MLX server on this Mac. Full document context is sent to the local endpoint."
        }
    }
}

// A singleton for app-wide settings that wraps UserDefaults access
class AppSettings: ObservableObject {
    nonisolated(unsafe) static let shared = AppSettings()
    
    private let defaults = UserDefaults.standard

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
    private init() {
        let defaults = UserDefaults.standard
        
        // Load or set defaults
        self.shortcutText = defaults.string(forKey: "shortcut") ?? "⌥ Space"
        self.hasCompletedOnboarding = defaults.bool(forKey: "has_completed_onboarding")
        self.useGradientTheme = defaults.bool(forKey: "use_gradient_theme")
        self.selectedAIProvider = AIProviderKind(
            rawValue: defaults.string(forKey: "selected_ai_provider") ?? ""
        ) ?? .localAppleFoundation
        self.selectedCoreAIGemmaModel = CoreAIGemmaModel(
            rawValue: defaults.string(forKey: "selected_core_ai_gemma_model") ?? ""
        ) ?? .gemma4_12B
        self.customQuickActions = defaults.stringArray(forKey: "custom_quick_actions") ?? []

        // HotKey
        self.hotKeyCode = defaults.integer(forKey: "hotKey_keyCode")
        self.hotKeyModifiers = defaults.integer(forKey: "hotKey_modifiers")
    }
    
    // MARK: - Convenience
    func resetAll() {
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
    }
}
