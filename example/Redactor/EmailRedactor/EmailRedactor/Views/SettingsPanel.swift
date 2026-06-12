import SwiftUI
import UniformTypeIdentifiers

struct SettingsPanel: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedModel: LLMModel = LLMModel.defaults.first!
    @State private var openAIKey: String = ""
    @State private var geminiKey: String = ""
    @State private var autoApplyRedactions = true
    @State private var preferredLanguage = "en"
    @State private var forceDarkMode = false
    @State private var showImporter = false
    @State private var importMessage: String?
    @State private var showImportAlert = false

    private var settings: SettingsStore { appState.settings }

    var body: some View {
        let availableModels = models
        let sqliteType = UTType(filenameExtension: "sqlite") ?? .data

        Form {
            Section(header: Text("LLM Selection")) {
                Picker("Model", selection: $selectedModel) {
                    ForEach(availableModels) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .onChange(of: selectedModel) { newValue in
                    settings.selectedModel = newValue
                }
            }

            Section(header: Text("API Keys")) {
                SecureField("OpenAI API Key", text: $openAIKey)
                    .textInputAutocapitalization(.never)
                    .onChange(of: openAIKey) { newValue in
                        settings.openAIAPIKey = newValue
                    }
                SecureField("Gemini API Key", text: $geminiKey)
                    .textInputAutocapitalization(.never)
                    .onChange(of: geminiKey) { newValue in
                        settings.geminiAPIKey = newValue
                    }
            }

            Section(header: Text("General")) {
                Toggle("Auto-apply stored redactions", isOn: $autoApplyRedactions)
                    .onChange(of: autoApplyRedactions) { newValue in
                        settings.autoApplyStoredRedactions = newValue
                    }
                Picker("Preferred Language", selection: $preferredLanguage) {
                    Text("English").tag("en")
                    Text("Portuguese").tag("pt")
                }
                .onChange(of: preferredLanguage) { newValue in
                    settings.preferredLanguage = newValue
                }
                Toggle("Force Dark Mode", isOn: $forceDarkMode)
                    .onChange(of: forceDarkMode) { newValue in
                        settings.forceDarkMode = newValue
                    }
            }

            Section(header: Text("Redaction History"), footer: Text("Merges entries from another redactions database into this app's history.")) {
                Button {
                    showImporter = true
                } label: {
                    Label("Import Redaction History", systemImage: "arrow.down.doc")
                }
            }
        }
        .onAppear {
            selectedModel = settings.selectedModel
            openAIKey = settings.openAIAPIKey
            geminiKey = settings.geminiAPIKey
            autoApplyRedactions = settings.autoApplyStoredRedactions
            preferredLanguage = settings.preferredLanguage
            forceDarkMode = settings.forceDarkMode
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [sqliteType, .data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    do {
                        let count = try await appState.importRedactions(from: url)
                        importMessage = "Imported \(count) redaction entries from \(url.lastPathComponent)."
                    } catch {
                        importMessage = "Import failed: \(error.localizedDescription)"
                    }
                    showImportAlert = true
                }
            case .failure(let error):
                importMessage = "Import failed: \(error.localizedDescription)"
                showImportAlert = true
            }
        }
        .alert(isPresented: $showImportAlert) {
            Alert(title: Text("Redaction Import"), message: Text(importMessage ?? "Unknown result"), dismissButton: .default(Text("OK")))
        }
    }

    private var models: [LLMModel] {
        var defaults = LLMModel.defaults
        if !defaults.contains(settings.selectedModel) {
            defaults.append(settings.selectedModel)
        }
        return defaults
    }
}
