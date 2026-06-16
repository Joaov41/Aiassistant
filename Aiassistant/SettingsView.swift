import SwiftUI
import Carbon.HIToolbox
import KeyboardShortcuts // Ensure this package is included

// Ensure KeyboardShortcuts.Name extension is defined if needed, or remove if not used
/*
extension KeyboardShortcuts.Name {
    static let showPopup = Self("showPopup")
}
*/

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage("theme_style") private var themeStyle: String = "standard"
    @AppStorage("glass_variant") private var glassVariant: Int = 11
    @State private var pccAvailabilityDescription = "Checking PCC availability..."
    @State private var isCheckingPCCAvailability = false
    @State private var pccAvailabilityTask: Task<Void, Never>?
    @State private var gemmaStatusDescription = ""

    init(appState: AppState, showOnlyApiSetup: Bool = false) {
        self._appState = ObservedObject(wrappedValue: appState)
        self.showOnlyApiSetup = showOnlyApiSetup
    }

    let showOnlyApiSetup: Bool

    var body: some View {
        ZStack {
            // Background - exact same as PopupView
            Group {
                if themeStyle == "glass" {
                    LiquidGlassBackground(
                        variant: GlassVariant(rawValue: glassVariant) ?? .v11,
                        cornerRadius: 0
                    ) {
                        Color.clear
                    }
                    .ignoresSafeArea()
                } else {
                    ZStack {
                        // Add a blur layer first
                        Color.black
                            .opacity(0.4)
                            .blur(radius: 20)
                            .ignoresSafeArea()
                        
                        Color(.windowBackgroundColor)
                            .opacity(1.0) // Full opacity for settings
                            .ignoresSafeArea()
                            .blur(radius: 1) // Slight blur on the background
                        
                        // Subtle gradient background
                        LinearGradient(
                            colors: [
                                Color.purple.opacity(0.08), // Even more visible gradient
                                Color.blue.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .ignoresSafeArea()
                    }
                }
            }
            
            VStack(alignment: .leading, spacing: 20) {
            if !showOnlyApiSetup {
                // Shortcut section (Updated for double-tap shift)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Keyboard Shortcut")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(.white.opacity(0.9))

                    Text("Activation: Double-tap Left Shift key quickly.")
                        .foregroundColor(.white.opacity(0.7))
                        .fontWeight(.medium)
                    // Remove the old KeyboardShortcuts.Recorder if not used
                    // KeyboardShortcuts.Recorder("Legacy Shortcut:", name: .showPopup)
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Appearance")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(.white.opacity(0.9))
                    
                    Text("Theme")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(.white.opacity(0.9))
                    
                    Picker("Theme", selection: $themeStyle) {
                        Text("Standard").tag("standard")
                        Text("Gradient").tag("gradient")
                        Text("Glass").tag("glass")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .background(Color.black.opacity(0.15)
                        .overlay(.ultraThinMaterial.opacity(0.7))
                        .overlay(Color.black.opacity(0.05)))
                    .cornerRadius(8)
                    
                    Text("Glass theme provides a modern translucent effect")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                        .fontWeight(.medium)
                    
                    if themeStyle == "glass" {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Glass Variant")
                                .font(.headline)
                                .fontWeight(.bold)
                                .foregroundColor(.white.opacity(0.9))
                                .padding(.top, 10)
                            
                            HStack {
                                Text("Style:")
                                    .fontWeight(.medium)
                                    .foregroundColor(.white.opacity(0.8))
                                Slider(value: Binding(
                                    get: { Double(glassVariant) },
                                    set: { glassVariant = Int($0) }
                                ), in: 0...19, step: 1)
                                Text("\(glassVariant)")
                                    .frame(width: 30)
                                    .monospacedDigit()
                                    .fontWeight(.medium)
                                    .foregroundColor(.white.opacity(0.8))
                            }
                            
                            Text("Experiment with different glass variants (0-19)")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.6))
                                .fontWeight(.medium)
                        }
                    }
                }

                Divider()

            } else {
                 Text("Your AI Model")
                     .font(.title)
                     .fontWeight(.bold)
                     .foregroundColor(.white.opacity(0.9))
                     .padding(.bottom)
            }

            // AI provider selection and model status
            VStack(alignment: .leading, spacing: 12) {
                Text("AI Model")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.white.opacity(0.9))

                Picker("AI Provider", selection: $settings.selectedAIProvider) {
                    ForEach(AIProviderKind.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .background(Color.black.opacity(0.15)
                    .overlay(.ultraThinMaterial.opacity(0.7))
                    .overlay(Color.black.opacity(0.05)))
                .cornerRadius(8)

                HStack(spacing: 10) {
                    Image(systemName: selectedProviderIcon)
                        .font(.title2)
                        .foregroundColor(.white.opacity(0.9))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.selectedAIProvider.fullDisplayName)
                            .fontWeight(.semibold)
                            .foregroundColor(.white.opacity(0.9))
                        Text(settings.selectedAIProvider.description)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                            .fontWeight(.medium)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.15)
                    .overlay(.ultraThinMaterial.opacity(0.7))
                    .overlay(Color.black.opacity(0.05)))
                .cornerRadius(8)

                if settings.selectedAIProvider == .coreAIGemma {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Gemma Model", selection: $settings.selectedCoreAIGemmaModel) {
                            ForEach(CoreAIGemmaModel.allCases) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .background(Color.black.opacity(0.15)
                            .overlay(.ultraThinMaterial.opacity(0.7))
                            .overlay(Color.black.opacity(0.05)))
                        .cornerRadius(8)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(settings.selectedCoreAIGemmaModel.fullDisplayName)
                                .fontWeight(.semibold)
                                .foregroundColor(.white.opacity(0.9))
                            Text(settings.selectedCoreAIGemmaModel.detail)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.6))
                                .fontWeight(.medium)
                            Text(settings.selectedCoreAIGemmaModel.mlxModelID)
                                .font(.caption)
                                .monospaced()
                                .foregroundColor(.white.opacity(0.75))
                                .textSelection(.enabled)
                        }

                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                            Text(gemmaStatusDescription)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                                .fontWeight(.medium)
                        }

                        Text("Fallback command: mlx_lm.server --model \(settings.selectedCoreAIGemmaModel.mlxModelID) --port 8080")
                            .font(.caption)
                            .monospaced()
                            .foregroundColor(.white.opacity(0.65))
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.15)
                        .overlay(.ultraThinMaterial.opacity(0.7))
                        .overlay(Color.black.opacity(0.05)))
                    .cornerRadius(8)
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(appState.appleProvider.isAvailable ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text("Local: \(appState.appleProvider.availabilityDescription)")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                        .fontWeight(.medium)
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(isPCCAvailableStatus ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text("PCC: \(pccAvailabilityDescription)")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                        .fontWeight(.medium)
                    Spacer()
                    Button(isCheckingPCCAvailability ? "Checking..." : "Check PCC") {
                        checkPCCAvailability()
                    }
                    .glassButtonStyle(variant: .v8)
                    .disabled(isCheckingPCCAvailability)
                }

                if settings.selectedAIProvider == .coreAIGemma {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("MLX: \(CoreAIGemmaProvider.availabilityDescription(for: settings.selectedCoreAIGemmaModel))")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                            .fontWeight(.medium)
                    }
                }

                if !appState.appleProvider.isAvailable {
                    Button("Open Apple Intelligence Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
                    }
                    .glassButtonStyle(variant: .v8)
                }
            }

            Spacer() // Push save button to bottom

            HStack {
                 Spacer() // Push button right
                 Button(showOnlyApiSetup ? "Complete Setup" : "Save & Close") {
                     saveSettings()
                 }
                 .glassButtonStyle(variant: .v8)
                 .scaleEffect(1.1)
            }

        }
        .padding()
        .background(Color.black.opacity(0.1)) // Add subtle background to content
        .frame(minWidth: 500, idealWidth: 550) // Set min width
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 5)
        .preferredColorScheme(.dark)
        .onAppear {
            checkPCCAvailability()
            refreshGemmaStatus()
            startGemmaServerIfNeeded()
        }
        .onChange(of: settings.selectedAIProvider) { _, _ in
            if settings.selectedAIProvider == .applePCC {
                checkPCCAvailability()
            }
            refreshGemmaStatus()
            startGemmaServerIfNeeded()
        }
        .onChange(of: settings.selectedCoreAIGemmaModel) { _, _ in
            refreshGemmaStatus()
            startGemmaServerIfNeeded()
        }
        .onDisappear {
            cancelPCCAvailabilityCheck()
        }
    }

    private var selectedProviderIcon: String {
        switch settings.selectedAIProvider {
        case .localAppleFoundation:
            return "apple.intelligence"
        case .applePCC:
            return "cloud"
        case .coreAIGemma:
            return "cpu"
        }
    }

    private var isPCCAvailableStatus: Bool {
        let normalized = pccAvailabilityDescription.lowercased()
        guard normalized.contains("available") else { return false }
        return !normalized.contains("not available")
            && !normalized.contains("unavailable")
            && !normalized.contains("not found")
            && !normalized.contains("error")
            && !normalized.contains("failed")
    }

    private func checkPCCAvailability() {
        guard !isCheckingPCCAvailability else { return }
        isCheckingPCCAvailability = true
        pccAvailabilityDescription = "Checking PCC availability..."
        pccAvailabilityTask = Task {
            let description = await FMPCCProvider.availabilityDescription()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.pccAvailabilityDescription = description
                self.isCheckingPCCAvailability = false
                self.pccAvailabilityTask = nil
            }
        }
    }

    private func cancelPCCAvailabilityCheck() {
        pccAvailabilityTask?.cancel()
        pccAvailabilityTask = nil
        isCheckingPCCAvailability = false
    }

    private func refreshGemmaStatus() {
        let model = settings.selectedCoreAIGemmaModel
        gemmaStatusDescription = "App starts local MLX text and image servers automatically for \(model.displayName)."
    }

    private func startGemmaServerIfNeeded() {
        guard settings.selectedAIProvider == .coreAIGemma else {
            return
        }
        Task {
            do {
                try await appState.coreAIGemmaProvider.startServerIfNeeded()
                await MainActor.run {
                    refreshGemmaStatus()
                }
            } catch {
                await MainActor.run {
                    gemmaStatusDescription = error.localizedDescription
                }
            }
        }
    }

    private func saveSettings() {
        cancelPCCAvailabilityCheck()
        // The on-device Apple foundation model needs no configuration to save.
        // Close windows safely
        DispatchQueue.main.async {
            if self.showOnlyApiSetup {
                // Onboarding complete: Mark as done and close *all* setup windows
                AppSettings.shared.hasCompletedOnboarding = true // Mark onboarding as done
                print("Onboarding setup complete. Closing setup windows.")
                // **CORRECTED CALL:** Use the correct method name
                WindowManager.shared.cleanupAllWindows() // Close all managed windows
            } else {
                // Just close the settings window itself
                print("Settings saved. Closing settings window.")
                WindowManager.shared.closeSettingsWindow(
                    appState: self.appState,
                    showOnlyApiSetup: self.showOnlyApiSetup
                )
            }
        }
    }
}
