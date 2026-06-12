import SwiftUI
import AppKit
import Foundation

// Predefined Quick Actions
enum QuickAction: String, CaseIterable, Identifiable {
    case summarize = "Summarize" // Text, URL, PDF
    case keyPoints = "Key Points" // Text, URL, PDF
    case simplify = "Simplify" // Text only
    case translateToSpanish = "Translate to Spanish" // Text only
    case describeImage = "Describe Image" // Image only
    case describeVideo = "Describe Video" // Video only (if model supports)
    // Add more actions here

    var id: String { self.rawValue }

    // Get the core instruction text for the action
    var instructionText: String {
        switch self {
        case .summarize:
            return "Summarize the following content concisely:"
        case .keyPoints:
            return "Extract the key points from the following content as a bulleted list:"
        case .simplify:
            return "Simplify the following text, making it easier to understand:"
        case .translateToSpanish:
            return "Translate the following text into Spanish:"
        case .describeImage:
            return "Describe the attached image in detail:"
        case .describeVideo:
            return "Describe the key frames or content of the attached video:"
        }
    }

    // Determine if the action is enabled for the given context type
    func isEnabled(for context: ClipboardContentType) -> Bool {
        switch self {
        case .summarize, .keyPoints:
            // Enable if there's *any* content (text derived from URL/PDF counts)
            return context != .none
        case .simplify, .translateToSpanish:
            // Strictly text-based actions
            return context == .text || context == .url || context == .pdf
        case .describeImage:
            return context == .image
        case .describeVideo:
            // Enable only if a video is detected (model support varies)
             return context == .video
        }
    }
}

// Define a type to represent either a predefined or custom action
enum ActionType: Identifiable {
    case predefined(QuickAction)
    case custom(String)

    var id: String {
        switch self {
        case .predefined(let action): return action.rawValue
        case .custom(let prompt): return "custom_\(prompt)"
        }
    }

    var displayName: String {
        switch self {
        case .predefined(let action): return action.rawValue
        case .custom(let prompt): return prompt // Display the custom prompt text directly
        }
    }
}

struct QuickActionsView: View {
    @ObservedObject var appState: AppState
    @StateObject private var settings = AppSettings.shared // Access shared settings
    var onComplete: () -> Void // Closure to close the window
    var onPromptSelected: ((String) -> Void)? = nil // Optional: called when a prompt is selected
    var promptSelectionOnly: Bool = false // If true, only select prompt, don't execute
    var inlineReplacementMode: Bool = false // If true, text actions replace the original selection

    @State private var isProcessing: Bool = false
    @State private var processingError: String? = nil
    @State private var contextPreview: String = ""
    @State private var contextType: ClipboardContentType = .none // Store the detected type
    @State private var selectedActionType: ActionType? = nil // Track selected action (predefined or custom)
    @State private var processingStatus: String? = nil // State for status message

    // State for adding custom prompts
    @State private var showingAddPromptAlert = false
    @State private var newPromptText: String = ""

    @AppStorage("theme_style") private var themeStyle: String = "standard"
    @AppStorage("glass_variant") private var glassVariantRaw: Int = 11
    var useGradient: Bool { themeStyle == "gradient" }

    private var appDelegate: AppDelegate? {
        NSApplication.shared.delegate as? AppDelegate
    }

    // Filter available predefined actions based on the current context
    private var availablePredefinedActions: [ActionType] {
        QuickAction.allCases
            .filter { $0.isEnabled(for: contextType) }
            .map { ActionType.predefined($0) }
    }

    // Get custom actions directly from settings
    private var customActions: [ActionType] {
        settings.customQuickActions.map { ActionType.custom($0) }
    }
    
    // Use the same translucent material background as in response window
    var messageBackground: some View {
        Group {
            if themeStyle == "glass" {
                LiquidGlassBackground(
                    variant: GlassVariant(rawValue: glassVariantRaw) ?? .v11,
                    cornerRadius: 12
                ) {
                    Color.clear
                }
            } else {
                Color.black.opacity(0.15)
                    .overlay(.ultraThinMaterial.opacity(0.7))
                    .overlay(Color.black.opacity(0.05))
            }
        }
    }

    var body: some View {
        ZStack {
            // Background - use liquid glass if theme is set
            Group {
                if themeStyle == "glass" {
                    LiquidGlassBackground(
                        variant: GlassVariant(rawValue: glassVariantRaw) ?? .v11,
                        cornerRadius: 0
                    ) {
                        Color.clear
                    }
                    .ignoresSafeArea()
                } else {
                    // Background gradient to match the response window
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color(red: 0.1, green: 0.12, blue: 0.15),
                            Color(red: 0.15, green: 0.18, blue: 0.22)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .opacity(0.9)
                    .ignoresSafeArea()
                }
            }
            
            // Main content
            VStack(spacing: 0) {
                // Content Area
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Context preview at the top
                        contextPreviewView
                            .padding(.top, 12)

                        // --- Predefined Actions Section ---
                        if !availablePredefinedActions.isEmpty {
                            Section(header: Text("Standard Actions").foregroundColor(.gray).font(.caption).padding(.top)) {
                                ForEach(availablePredefinedActions) { actionType in
                                    Button {
                                        performAction(actionType)
                                    } label: {
                                        HStack {
                                            Text(actionType.displayName)
                                                .fontWeight(.medium)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.caption)
                                                .foregroundColor(.gray)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .glassButtonStyle(variant: .v8)
                                    .disabled(isProcessing)
                                }
                            }
                        }

                         // --- Custom Actions Section (with Delete) ---
                        Text("Custom Actions")
                            .foregroundColor(.gray)
                            .font(.caption)
                            .padding(.top, availablePredefinedActions.isEmpty ? 0 : 8)
                        
                        if settings.customQuickActions.isEmpty {
                            Text("No custom actions added yet.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            VStack(spacing: 10) {
                                ForEach(settings.customQuickActions.indices, id: \.self) { index in
                                    let prompt = settings.customQuickActions[index]
                                    let actionType = ActionType.custom(prompt)
                                    
                                    HStack(spacing: 8) {
                                        Button {
                                            performAction(actionType)
                                        } label: {
                                            HStack(spacing: 8) {
                                                Text(actionType.displayName)
                                                    .fontWeight(.bold)
                                                    .lineLimit(2)
                                                    .truncationMode(.tail)
                                                Spacer()
                                                Image(systemName: "chevron.right")
                                                    .font(.caption)
                                                    .foregroundColor(.gray)
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .glassButtonStyle(variant: .v8)
                                        .disabled(isProcessing)
                                        
                                        Button {
                                            deleteCustomAction(at: IndexSet(integer: index))
                                        } label: {
                                            Image(systemName: "trash")
                                                .foregroundColor(.red)
                                                .padding(8)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                    }
                                }
                            }
                        }

                        // --- Add Custom Prompt Button ---
                        // Moved outside the sections but still within the ScrollView content
                        Button {
                            showingAddPromptAlert = true
                            newPromptText = "" // Clear previous input
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                Text("Add Custom Prompt")
                                    .fontWeight(.bold)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .glassButtonStyle(variant: .v8)
                        .disabled(isProcessing)
                        .padding(.top, 10) // Add some space above
                        .padding(.bottom, 12) // Add padding below the button

                    }
                    .padding(.horizontal)
                }
                // Alert for adding a new custom prompt
                .alert("Add Custom Quick Action", isPresented: $showingAddPromptAlert) {
                    TextField("Enter your prompt instruction", text: $newPromptText)
                    Button("Cancel", role: .cancel) { }
                    Button("Add") {
                        addCustomPrompt()
                    }
                } message: {
                    Text("Enter the instruction you want the AI to follow for this custom action (e.g., 'Explain this like I'm five').")
                }
                
                // Bottom controls
                VStack(spacing: 0) {
                    Divider()
                        .background(Color.gray.opacity(0.3))
                    
                    // Status/Progress section
                    if isProcessing {
                        HStack {
                            Spacer()
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.8)
                                .tint(Color.white.opacity(0.8))
                            if let status = processingStatus { // Display status next to spinner
                                Text(status)
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                    .padding(.leading, 4)
                            }
                            Spacer()
                        }
                        .frame(height: 30)
                        .padding(.vertical, 4)
                    } else if let error = processingError { // Only show error if not processing
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.vertical, 8)
                    }
                    
                    // Bottom input area to match main UI
                    HStack {
                        // Add a simple title to replace the segmented control
                        Text("Quick Actions")
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundColor(.white.opacity(0.8))
                        
                        Spacer()
                        
                        // --- ADDED CLEAR CLIPBOARD BUTTON ---
                        Button {
                            clearClipboard()
                        } label: {
                            Label("Clear", systemImage: "trash") // Using Label for icon + text
                        }
                        .glassButtonStyle(variant: .v8)
                        .help("Clear all current clipboard content")
                        // --- END ADDED CLEAR CLIPBOARD BUTTON ---
                        
                        Button("Close") {
                            onComplete()
                        }
                        .glassButtonStyle(variant: .v8)
                        .keyboardShortcut(.cancelAction)
                        .foregroundColor(.white.opacity(0.9)) // Ensure text is visible
                    }
                    .padding()
                    .background(Color.black.opacity(0.15))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 5)
        }
        .frame(minWidth: 400, minHeight: 350)
        .preferredColorScheme(.dark)
        .onAppear(perform: setupContext)
        .onReceive(appState.$lastClipboardType) { _ in
            setupContext()
        }
        .onReceive(appState.$selectedText) { _ in
            setupContext()
        }
    }
    
    // Context preview view based on content type
    private var contextPreviewView: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch contextType {
            case .text:
                Text("Using selected text:")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundColor(.white.opacity(0.8))
                
                Text(contextPreview.isEmpty ? "(No text detected)" : contextPreview)
                    .font(.system(size: 13))
                    .lineLimit(4)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(messageBackground)
                    .cornerRadius(12)
                
            case .url:
                Text("Using content from URL:")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundColor(.white.opacity(0.8))
                
                Text(contextPreview.isEmpty ? "(Fetching...)" : contextPreview)
                    .font(.system(size: 13))
                    .lineLimit(4)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(messageBackground)
                    .cornerRadius(12)
                
            case .pdf:
                Text("Using text from PDF:")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundColor(.white.opacity(0.8))
                
                Text(contextPreview.isEmpty ? "(No text extracted)" : contextPreview)
                    .font(.system(size: 13))
                    .lineLimit(4)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(messageBackground)
                    .cornerRadius(12)
                
            case .image:
                HStack {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundColor(.white.opacity(0.8))
                    
                    VStack(alignment: .leading) {
                        Text("Using image from clipboard")
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundColor(.white.opacity(0.8))
                        
                        Text("An image is ready for processing")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    
                    Spacer()
                }
                .padding(10)
                .background(messageBackground)
                .cornerRadius(12)
                
            case .video:
                HStack {
                    Image(systemName: "video")
                        .font(.title2)
                        .foregroundColor(.white.opacity(0.8))
                    
                    VStack(alignment: .leading) {
                        Text("Using video from clipboard")
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundColor(.white.opacity(0.8))
                        
                        Text("A video is ready for processing")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    
                    Spacer()
                }
                .padding(10)
                .background(messageBackground)
                .cornerRadius(12)
                
            case .none:
                Text("No content detected on clipboard.") // Updated message
                    .font(.subheadline)
                    .foregroundColor(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(messageBackground)
                    .cornerRadius(12)
            }
        }
    }

    // Set up the context preview and type on appear
    private func setupContext() {
        DispatchQueue.main.async {
            self.contextType = appState.lastClipboardType
            // Always use selectedText from appState, as it holds extracted text for URL/PDF too
            self.contextPreview = appState.selectedText
            
            // Truncate very long preview text
            if self.contextPreview.count > 500 {
                self.contextPreview = String(self.contextPreview.prefix(500)) + "..."
            }
            
            print("QuickActionsView context setup: Type=\(String(describing: self.contextType)), Text Preview Length=\(self.contextPreview.count)")
        }
    }

    // Add the new prompt to settings
    private func addCustomPrompt() {
        let trimmedPrompt = newPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty && !settings.customQuickActions.contains(trimmedPrompt) {
            settings.customQuickActions.append(trimmedPrompt)
            print("Added custom prompt: \(trimmedPrompt)")
        }
        newPromptText = "" // Clear field
    }

    // Delete a custom prompt at the specified offsets
    private func deleteCustomAction(at offsets: IndexSet) {
        settings.customQuickActions.remove(atOffsets: offsets)
        print("Deleted custom prompts at indices: \(offsets)")
    }

    private func isSpreadsheetApplication(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier?.contains("excel") == true ||
        app.bundleIdentifier?.contains("numbers") == true ||
        app.bundleIdentifier?.contains("sheets") == true ||
        app.localizedName?.lowercased().contains("excel") == true ||
        app.localizedName?.lowercased().contains("numbers") == true ||
        app.localizedName?.lowercased().contains("sheets") == true
    }

    // Perform the selected quick action (predefined or custom)
    private func performAction(_ actionType: ActionType) {
        // --- ADDED: Explicit check and log for promptSelectionOnly ---
        print("DEBUG (QuickActionsView.performAction): Started. promptSelectionOnly = \(promptSelectionOnly)")

        // If promptSelectionOnly is true, always use onPromptSelected for both custom and predefined actions
        if promptSelectionOnly, let onPromptSelected = onPromptSelected {
            print("DEBUG (QuickActionsView.performAction): promptSelectionOnly is TRUE. Calling onPromptSelected and returning.")
            switch actionType {
            case .custom(let customPrompt):
                onPromptSelected(customPrompt)
                onComplete() // Calls the closure to close the sheet
                return       // Exit immediately
            case .predefined(let predefinedAction):
                onPromptSelected(predefinedAction.instructionText)
                onComplete() // Calls the closure to close the sheet
                return       // Exit immediately
            }
        }

        // --- ADDED: Log if execution continues past the check ---
        print("DEBUG (QuickActionsView.performAction): Execution CONTINUED past promptSelectionOnly check.")

        // Basic check - ensure some context exists unless it's a custom action that doesn't need it
        // Custom actions still need context to operate on.

        // Only read state here initially
        guard !isProcessing else {
            print("Action already in progress, ignoring new request.")
            return
        }

        print("Queueing action: \(actionType.displayName) on context: \(contextType)")

        // Start main async task for processing
        Task {
            // --- Update State on Main Thread FIRST ---
            await MainActor.run {
                // Now modify state safely
                self.selectedActionType = actionType
                self.isProcessing = true
                self.processingError = nil
                self.processingStatus = "Preparing action..." // Initial status
                print("DEBUG (QuickActionsView): Set isProcessing = true for action: \(actionType.displayName)")
            }
            
            // Capture context type on main thread *after* setting isProcessing
            let currentContextType = await MainActor.run { self.contextType }

            // Determine action details immediately
            let actionName: String
            let instructionText: String
            switch actionType {
            case .predefined(let predefinedAction):
                actionName = predefinedAction.rawValue.capitalized
                instructionText = predefinedAction.instructionText
            case .custom(let customInstruction):
                actionName = "Custom Action"
                instructionText = customInstruction
            }
            let writingOption: WritingOption = .general // Or determine based on action

            // Start main async task for processing
            // --- Capture text for inline replacement, or wait for URL content if applicable ---
            var finalInputText: String
            var inlineTargetApplication: NSRunningApplication?
            let initialText = await appState.selectedText // Get text available *now*

            if inlineReplacementMode && currentContextType == .text {
                await MainActor.run { self.processingStatus = "Reading selected text..." }

                let currentApp = NSWorkspace.shared.frontmostApplication
                let targetApp = currentApp?.bundleIdentifier != Bundle.main.bundleIdentifier
                    ? currentApp
                    : await appState.previousApplication

                guard let targetApp = targetApp,
                      !targetApp.isTerminated,
                      targetApp.bundleIdentifier != Bundle.main.bundleIdentifier else {
                    print("QuickActions inline replacement failed: no external target app.")
                    await MainActor.run {
                        self.processingError = "Select text in another app first."
                        self.isProcessing = false
                        self.selectedActionType = nil
                        self.processingStatus = nil
                    }
                    return
                }

                inlineTargetApplication = targetApp
                targetApp.activate(options: .activateIgnoringOtherApps)
                try? await Task.sleep(nanoseconds: 300_000_000)

                guard let externalText = AccessibilityHelper.copyTextFromFocusedElement(targetApplication: targetApp),
                      !externalText.isEmpty else {
                    print("QuickActions inline replacement failed: could not copy selected text.")
                    await MainActor.run {
                        self.processingError = "No selected text found in \(targetApp.localizedName ?? "the target app")."
                        self.isProcessing = false
                        self.selectedActionType = nil
                        self.processingStatus = nil
                    }
                    return
                }

                finalInputText = externalText
                await MainActor.run {
                    appState.previousApplication = targetApp
                    appState.selectedText = externalText
                    appState.lastClipboardType = .text
                }
            } else if currentContextType == .url {
                print("DEBUG (QuickActionsView): Context is URL, entering wait loop...")
                await MainActor.run { self.processingStatus = "Extracting URL content..." } // Set URL extraction status
                let startTime = Date()
                let timeout: TimeInterval = 15.0 // 15 second timeout
                var textHasContent = false
                var currentText = initialText

                while Date().timeIntervalSince(startTime) < timeout {
                    currentText = await appState.selectedText // Re-fetch in loop
                    if currentText.contains("\n\nContent:") {
                        textHasContent = true
                        print("DEBUG (QuickActionsView): URL content found in selectedText after waiting.")
                        break
                    }
                    // Log progress to see if loop is running
                    // print("DEBUG (QuickActionsView): Waiting... Time elapsed: \(Date().timeIntervalSince(startTime))")
                    try? await Task.sleep(nanoseconds: 250_000_000) // 0.25 seconds
                }

                if !textHasContent {
                    print("WARN (QuickActionsView): Timeout waiting for URL content. Proceeding with current text (length: \(currentText.count)).")
                    // Log snippet if timed out
                    if currentText.count > 100 {
                        print("WARN (QuickActionsView): Current text at timeout (snippet): \(currentText.prefix(100))...")
                    } else {
                        print("WARN (QuickActionsView): Current text at timeout: \(currentText)")
                    }
                }
                finalInputText = currentText // Use the text obtained after waiting (full or URL-only)
            } else {
                // Not a URL context, use the initial text directly
                finalInputText = initialText
            }

            // Update status before calling LLM
            await MainActor.run { self.processingStatus = "Processing with AI..." }

            // --- Execute Action ---
            let userPrompt: String
            if let inlineTargetApplication {
                let formatInstructions = isSpreadsheetApplication(inlineTargetApplication) ?
                    "Important: Preserve the table structure exactly. Maintain all tabs, commas, and line breaks in their original positions. If this is spreadsheet data, ensure each cell's content is modified while keeping the overall format intact." :
                    ""

                userPrompt = """
                Follow instructions of the user. Return only the resulting replacement text, with no disclaimers or explanation.

                \(formatInstructions)

                Instructions: \(instructionText)

                Original Text:
                \(finalInputText)
                """
            } else {
                userPrompt = "\(instructionText)\n\n\(finalInputText)"
            }
            print("Final prompt (text part length: \(userPrompt.count))")
            if userPrompt.count > 200 { // Log snippet for long prompts
                 print("Final prompt snippet: \(userPrompt.prefix(100))...\(userPrompt.suffix(100))")
            }

            do {
                let response = try await appState.activeProvider.processText(
                    systemPrompt: writingOption.systemPrompt,
                    userPrompt: userPrompt,
                    images: currentContextType == .image ? await appState.selectedImages : [],
                    videos: currentContextType == .video ? await appState.selectedVideos : []
                )

                if let inlineTargetApplication, response.images.isEmpty {
                    await MainActor.run {
                        print("Action '\(actionName)' completed. Replacing selected text inline.")

                        if inlineTargetApplication.isTerminated {
                            print("Target application was closed. Copying result to clipboard instead.")
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(response.text, forType: .string)
                        } else {
                            if isSpreadsheetApplication(inlineTargetApplication) {
                                Thread.sleep(forTimeInterval: 0.2)
                            }
                            AccessibilityHelper.replaceTextInFocusedElement(
                                with: response.text,
                                targetApplication: inlineTargetApplication
                            )
                        }

                        self.isProcessing = false
                        self.selectedActionType = nil
                        self.processingStatus = nil
                        self.onComplete()
                    }
                    return
                }

                // --- Show Response Window (on Main Thread) ---
                await MainActor.run {
                    print("Action '\(actionName)' completed. Showing response window.")
                    
                    // Pass the text that was ACTUALLY used in the prompt to ResponseView
                    let responseView = ResponseView(
                        content: response.text,
                        selectedText: finalInputText,
                        option: writingOption,
                        images: response.images,
                        providerName: response.providerName,
                        pccTranscriptName: response.pccTranscriptName,
                        contentTopInset: 0
                    )

                    let window = ResponseWindow(
                        with: responseView,
                        title: "Result: \(actionName)",
                        hasImages: !response.images.isEmpty
                    )

                    WindowManager.shared.addResponseWindow(window)
                    self.isProcessing = false // Use self here
                    self.selectedActionType = nil
                    self.processingStatus = nil // Clear status on success
                    self.onComplete() // Close Quick Actions window
                }

            } catch {
                // --- Handle LLM Error (on Main Thread) ---
                print("ERROR (QuickActionsView): LLM processing failed: \(error)")
                await MainActor.run {
                    self.processingError = "Error: \(error.localizedDescription)" // Show error in QuickActionsView
                    self.isProcessing = false
                    self.selectedActionType = nil
                    self.processingStatus = nil // Clear status on error
                    // Optionally call self.onComplete() here too, or let user see error and close manually
                }
            }
        }
    }

    /// Clears the clipboard content and resets the context
    private func clearClipboard() {
        appState.clearClipboardData()

        // Refresh context preview in this view
        setupContext()
        
        print("QuickActionsView: Clipboard content cleared and context refreshed.")
    }
}
